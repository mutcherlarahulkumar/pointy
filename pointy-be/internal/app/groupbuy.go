package app

import (
	"context"
	"log"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/ai"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
)

// The group shopping agent. Someone on a trip says what the group needs;
// the agent searches the shops (Channel3), and the AI picks up to three
// products with a reason each. A pick becomes a group purchase split
// equally over the trip. Each person says yes with their trip share (held
// in the ledger) or with PayPal (an AUTHORIZE order: the money is only
// held on their PayPal). When everyone is in, the PayPal holds are
// captured and the purchase is paid; if anyone says no, or 48 hours pass,
// every hold is let go and nobody pays anything.

const groupBuyWindow = 48 * time.Hour

// Ways to put in a share.
const (
	ViaWallet = "wallet"
	ViaPayPal = "paypal"
)

// ModeGroupBuy is the expense written when a group purchase is paid.
const ModeGroupBuy = "group_buy"

// AgentPick is one product the agent suggests.
type AgentPick struct {
	Index    int             `json:"index"`
	Item     domain.ShopItem `json:"item"`
	Why      string          `json:"why"`
	Each     Paise           `json:"each_paise"`
	FitsPlan bool            `json:"fits_budget"`
}

// AgentAnswer is the agent's reply to a shopping request. Nothing is
// bought: the person proposes a pick to the group with SearchID and Index.
type AgentAnswer struct {
	SearchID string      `json:"search_id"`
	Query    string      `json:"query"`
	Budget   Paise       `json:"budget_paise"`
	People   int         `json:"people"`
	Reply    string      `json:"reply"`
	Picks    []AgentPick `json:"picks"`
	Source   string      `json:"source"` // ai or rules
}

// agentSearch keeps what the shops answered, so a proposal uses the price
// the server saw, never one sent by the phone.
type agentSearch struct {
	tripID, userID, request, query string
	items                          []domain.ShopItem
	at                             time.Time
}

// ShopForTrip runs the agent for a trip.
func (s *Service) ShopForTrip(ctx context.Context, tripID, userID, text string) (AgentAnswer, error) {
	text = strings.Join(strings.Fields(text), " ")
	s.mu.Lock()
	t, err := s.openTripL(tripID, userID)
	if err != nil {
		s.mu.Unlock()
		return AgentAnswer{}, err
	}
	people := len(t.Members)
	walletLeft := s.ledger.Held(domain.ClearingAccount(tripID))
	tripName, place := t.Name, t.Place
	assistant := s.ai
	s.mu.Unlock()

	query, budget := shopRules(text)
	if query == "" || len(text) > 200 {
		return AgentAnswer{}, domain.Invalid("say what the group needs, for example: a speaker for the beach under 3000")
	}
	items, err := s.Shop(ctx, query, budget)
	if err != nil {
		return AgentAnswer{}, err
	}
	ans := AgentAnswer{Query: query, Budget: budget, People: people, Source: "rules"}
	if len(items) == 0 {
		ans.Reply = "I found nothing in stock for “" + query + "”. Try other words or a higher budget."
		return ans, nil
	}
	each := func(p Paise) Paise { return (p + Paise(people) - 1) / Paise(people) }
	fits := func(p Paise) bool { return budget <= 0 || p <= budget }

	var picks []AgentPick
	if assistant != nil {
		in := ai.PickInput{Request: text, TripName: tripName, TripPlace: place, People: people, WalletLeft: INR(walletLeft)}
		if budget > 0 {
			in.Budget = INR(budget)
		}
		for i, it := range items {
			c := ai.PickCandidate{Index: i, Title: it.Title, Brand: it.Brand, Shop: it.Merchant, Price: INR(it.Price), EachPays: INR(each(it.Price)), FitsMoney: fits(it.Price)}
			if it.WasPrice > it.Price {
				c.WasPrice = INR(it.WasPrice)
			}
			in.Candidates = append(in.Candidates, c)
		}
		cctx, cancel := context.WithTimeout(ctx, aiTimeout)
		out, err := assistant.PickProducts(cctx, in)
		cancel()
		if err != nil {
			log.Printf("shop agent: %v", err)
		} else {
			seen := map[int]bool{}
			for _, p := range out.Picks {
				if p.Index < 0 || p.Index >= len(items) || seen[p.Index] || strings.TrimSpace(p.Why) == "" || len(picks) == 3 {
					continue
				}
				seen[p.Index] = true
				it := items[p.Index]
				picks = append(picks, AgentPick{Index: p.Index, Item: it, Why: strings.TrimSpace(p.Why), Each: each(it.Price), FitsPlan: fits(it.Price)})
			}
			if len(picks) > 0 {
				ans.Source, ans.Reply = "ai", strings.TrimSpace(out.Reply)
			}
		}
	}
	if len(picks) == 0 {
		picks = rulePicks(items, people, each, fits)
	}
	if ans.Reply == "" {
		ans.Reply = "Here " + map[bool]string{true: "is the best pick", false: "are " + strconv.Itoa(len(picks)) + " picks"}[len(picks) == 1] +
			" for " + strconv.Itoa(people) + " " + map[bool]string{true: "person", false: "people"}[people == 1] + ". Propose one and everyone says yes or no."
	}
	ans.Picks = picks

	s.mu.Lock()
	ans.SearchID = newID("srch")
	if s.searches == nil {
		s.searches = map[string]*agentSearch{}
	}
	for id, old := range s.searches { // keep the map small
		if s.now().Sub(old.at) > 2*time.Hour {
			delete(s.searches, id)
		}
	}
	s.searches[ans.SearchID] = &agentSearch{tripID: tripID, userID: userID, request: text, query: query, items: items, at: s.now()}
	s.mu.Unlock()
	return ans, nil
}

// rulePicks chooses without a model: the shop's best matches, keeping
// their order, with anything over the budget moved to the end.
func rulePicks(items []domain.ShopItem, people int, each func(Paise) Paise, fits func(Paise) bool) []AgentPick {
	idx := make([]int, len(items))
	for i := range idx {
		idx[i] = i
	}
	sort.SliceStable(idx, func(a, b int) bool {
		x, y := items[idx[a]], items[idx[b]]
		return fits(x.Price) && !fits(y.Price)
	})
	var out []AgentPick
	for _, i := range idx {
		if len(out) == 3 {
			break
		}
		it := items[i]
		why := INR(each(it.Price)) + " each for the " + strconv.Itoa(people) + " of you"
		if people == 1 {
			why = INR(it.Price) + " for you"
		}
		if it.WasPrice > it.Price {
			why += ", " + INR(it.WasPrice-it.Price) + " off right now"
		}
		if it.Merchant != "" {
			why += ", from " + it.Merchant
		}
		out = append(out, AgentPick{Index: i, Item: it, Why: why + ".", Each: each(it.Price), FitsPlan: fits(it.Price)})
	}
	return out
}

// ProposeGroupBuy turns one of the agent's picks into a purchase the whole
// trip decides on. The person who proposes still says yes with their own
// share, like everyone else.
func (s *Service) ProposeGroupBuy(tripID, userID, searchID string, index int, why string) (*domain.GroupBuy, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	t, err := s.openTripL(tripID, userID)
	if err != nil {
		return nil, err
	}
	sr := s.searches[searchID]
	if sr == nil || sr.tripID != tripID || sr.userID != userID {
		return nil, domain.Conflict("search_expired", "these picks are old; ask the agent again", nil)
	}
	if index < 0 || index >= len(sr.items) {
		return nil, domain.Invalid("choose one of the picks")
	}
	item := sr.items[index]
	parts := make([]domain.SplitInput, 0, len(t.Members))
	for _, m := range t.Members {
		parts = append(parts, domain.SplitInput{UserID: m, Weight: 1})
	}
	shares, err := domain.Split(item.Price, domain.SplitEqual, parts)
	if err != nil {
		return nil, err
	}
	now := s.now()
	g := &domain.GroupBuy{ID: s.idL("gb"), TripID: tripID, ProposedBy: userID, Request: sr.request, Why: strings.TrimSpace(why),
		Item: item, Category: guessCategory(sr.query), Amount: item.Price, Status: "open", Deadline: now.Add(groupBuyWindow), CreatedAt: now}
	if len(g.Why) > 300 {
		g.Why = g.Why[:300]
	}
	for _, sh := range shares {
		g.Shares = append(g.Shares, domain.GroupBuyShare{UserID: sh.UserID, Amount: sh.Amount, Status: "waiting"})
	}
	s.groupBuys = append(s.groupBuys, g)
	s.track(g)
	s.alertL(tripID, "", "group_buy", s.name(userID)+" wants to buy "+shortTitle(item.Title)+" together",
		INR(item.Price)+" for the group. Say yes with your share, or no, before "+formatWhen(g.Deadline)+".")
	if err := s.commitL(); err != nil {
		return nil, err
	}
	return g, nil
}

// GroupBuys lists a trip's purchases, newest first.
func (s *Service) GroupBuys(ctx context.Context, tripID, userID string) ([]*domain.GroupBuy, error) {
	s.expireDue(ctx)
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, err := s.tripL(tripID, userID); err != nil {
		return nil, err
	}
	out := []*domain.GroupBuy{}
	for i := len(s.groupBuys) - 1; i >= 0; i-- {
		if s.groupBuys[i].TripID == tripID {
			out = append(out, s.groupBuys[i])
		}
	}
	return out, nil
}

// GroupBuy returns one purchase to a member of its trip.
func (s *Service) GroupBuy(ctx context.Context, id, userID string) (*domain.GroupBuy, error) {
	s.expireDue(ctx)
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.groupBuyL(id, userID)
}

func (s *Service) groupBuyL(id, userID string) (*domain.GroupBuy, error) {
	for _, g := range s.groupBuys {
		if g.ID == id {
			if _, err := s.tripL(g.TripID, userID); err != nil {
				return nil, err
			}
			return g, nil
		}
	}
	return nil, domain.NotFound("group purchase")
}

func shareOf(g *domain.GroupBuy, userID string) *domain.GroupBuyShare {
	for i := range g.Shares {
		if g.Shares[i].UserID == userID {
			return &g.Shares[i]
		}
	}
	return nil
}

// overdueL says whether an open purchase ran out of time: people say yes
// before the deadline, so at the deadline it is too late. It is closed by
// expireDue; until then it holds nothing and blocks nothing.
func (s *Service) overdueL(g *domain.GroupBuy) bool {
	return g.Status == "open" && !s.now().Before(g.Deadline)
}

// heldForBuysL is trip-share money promised to open group purchases, so it
// cannot be spent twice. It is worked out from stored purchases, so it
// survives a restart.
func (s *Service) heldForBuysL(account string) (sum Paise) {
	for _, g := range s.groupBuys {
		if (g.Status != "open" && g.Status != "paying") || s.overdueL(g) {
			continue
		}
		for _, sh := range g.Shares {
			if sh.Status == "in" && sh.Via == ViaWallet && domain.ShareAccount(g.TripID, sh.UserID) == account {
				sum += sh.Amount
			}
		}
	}
	return sum
}

// openBuysOnTripL says whether a trip still has purchases being decided.
func (s *Service) openBuysOnTripL(tripID string) bool {
	for _, g := range s.groupBuys {
		if g.TripID == tripID && (g.Status == "open" || g.Status == "paying") && !s.overdueL(g) {
			return true
		}
	}
	return false
}

// JoinGroupBuy says yes with the person's share: from their trip share
// (held at once) or with PayPal (answers with the PayPal page to approve).
func (s *Service) JoinGroupBuy(ctx context.Context, id, userID, via string) (*domain.GroupBuy, error) {
	s.expireDue(ctx)
	s.mu.Lock()
	g, err := s.groupBuyL(id, userID)
	if err == nil && g.Status != "open" {
		err = domain.Conflict("group_buy_closed", "this purchase is "+g.Status, nil)
	}
	var sh *domain.GroupBuyShare
	if err == nil {
		if sh = shareOf(g, userID); sh == nil {
			err = domain.Forbidden("you are not part of this purchase")
		} else if sh.Status == "in" {
			s.mu.Unlock()
			return g, nil // already in: a retry
		}
	}
	if err != nil {
		s.mu.Unlock()
		return nil, err
	}
	switch via {
	case ViaWallet:
		acc := domain.ShareAccount(g.TripID, userID)
		if avail := s.availL(acc); avail < sh.Amount {
			s.mu.Unlock()
			return nil, domain.Conflict("insufficient_share", "your trip share has "+INR(avail)+" free but your part is "+INR(sh.Amount)+". Put money in, or say yes with PayPal.",
				map[string]any{"available_paise": avail, "needed_paise": sh.Amount})
		}
		now := s.now()
		sh.Status, sh.Via, sh.CommittedAt = "in", ViaWallet, &now
		s.track(g)
		s.alertL(g.TripID, "", "group_buy", s.name(userID)+" is in for "+shortTitle(g.Item.Title), s.groupBuyProgressL(g))
		err := s.commitL()
		s.mu.Unlock()
		if err != nil {
			return nil, err
		}
		return s.maybeFinish(ctx, id)
	case ViaPayPal:
		if sh.OrderID != "" && sh.ApproveURL != "" {
			s.mu.Unlock()
			return g, nil // an approval page is already waiting
		}
		amount, desc := sh.Amount, "Your part of "+shortTitle(g.Item.Title)
		s.mu.Unlock()
		o, err := s.pp.CreateAuthOrder(ctx, g.ID+"-"+userID, amount, desc)
		if err != nil {
			return nil, paypalErr(err)
		}
		s.mu.Lock()
		defer s.mu.Unlock()
		if g.Status != "open" {
			return nil, domain.Conflict("group_buy_closed", "this purchase is "+g.Status, nil)
		}
		sh.Via, sh.OrderID, sh.ApproveURL = ViaPayPal, o.ID, o.ApproveURL
		s.track(g)
		if err := s.commitL(); err != nil {
			return nil, err
		}
		return g, nil
	}
	s.mu.Unlock()
	return nil, domain.Invalid("say yes with %q or %q", ViaWallet, ViaPayPal)
}

// AuthorizeGroupBuyOrder places the PayPal hold once the person approved.
// userID is empty when PayPal's return page calls it.
func (s *Service) AuthorizeGroupBuyOrder(ctx context.Context, orderID, userID string) (*domain.GroupBuy, error) {
	s.expireDue(ctx)
	s.mu.Lock()
	g, sh := s.findOrderL(orderID)
	if g == nil || (userID != "" && sh.UserID != userID) {
		s.mu.Unlock()
		return nil, domain.NotFound("PayPal approval")
	}
	if sh.Status == "in" {
		s.mu.Unlock()
		return g, nil
	}
	s.mu.Unlock()

	authID, err := s.pp.AuthorizeOrder(ctx, orderID)
	if err != nil {
		return nil, domain.Conflict("not_approved", "PayPal has not approved this yet. Approve it on PayPal, then try again.", nil)
	}

	s.mu.Lock()
	if g.Status != "open" || s.overdueL(g) {
		s.mu.Unlock()
		s.expireDue(ctx)
		// Too late (someone said no, or time ran out): let the hold go.
		if err := s.pp.VoidAuthorization(ctx, authID); err != nil {
			log.Printf("group buy %s: void late authorization: %v", g.ID, err)
		}
		s.mu.Lock()
		status := g.Status
		s.mu.Unlock()
		return nil, domain.Conflict("group_buy_closed", "this purchase is "+status+"; nothing was charged", nil)
	}
	now := s.now()
	sh.Status, sh.AuthID, sh.ApproveURL, sh.CommittedAt = "in", authID, "", &now
	s.track(g)
	s.alertL(g.TripID, "", "group_buy", s.name(sh.UserID)+" is in for "+shortTitle(g.Item.Title), s.groupBuyProgressL(g))
	err = s.commitL()
	s.mu.Unlock()
	if err != nil {
		return nil, err
	}
	return s.maybeFinish(ctx, g.ID)
}

// IsGroupBuyOrder says whether a PayPal order belongs to a group purchase.
func (s *Service) IsGroupBuyOrder(orderID string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	g, _ := s.findOrderL(orderID)
	return g != nil
}

func (s *Service) findOrderL(orderID string) (*domain.GroupBuy, *domain.GroupBuyShare) {
	if orderID == "" {
		return nil, nil
	}
	for _, g := range s.groupBuys {
		for i := range g.Shares {
			if g.Shares[i].OrderID == orderID {
				return g, &g.Shares[i]
			}
		}
	}
	return nil, nil
}

// DeclineGroupBuy says no. One no is enough: the purchase is called off,
// every hold is let go and nobody pays. The proposer can call it off too.
func (s *Service) DeclineGroupBuy(ctx context.Context, id, userID string) (*domain.GroupBuy, error) {
	s.expireDue(ctx)
	s.mu.Lock()
	g, err := s.groupBuyL(id, userID)
	if err == nil && shareOf(g, userID) == nil {
		err = domain.Forbidden("you are not part of this purchase")
	}
	if err == nil && g.Status != "open" {
		err = domain.Conflict("group_buy_closed", "this purchase is "+g.Status, nil)
	}
	if err != nil {
		s.mu.Unlock()
		return nil, err
	}
	if sh := shareOf(g, userID); sh != nil {
		sh.Status = "declined"
	}
	note := s.name(userID) + " said no"
	if userID == g.ProposedBy {
		note = s.name(userID) + " called it off"
	}
	s.mu.Unlock()
	return s.closeGroupBuy(ctx, g, "cancelled", note)
}

// expireDue calls off purchases whose time ran out.
func (s *Service) expireDue(ctx context.Context) {
	s.mu.Lock()
	var due []*domain.GroupBuy
	for _, g := range s.groupBuys {
		if s.overdueL(g) {
			due = append(due, g)
		}
	}
	s.mu.Unlock()
	for _, g := range due {
		if _, err := s.closeGroupBuy(ctx, g, "expired", "not everyone said yes in time"); err != nil {
			log.Printf("group buy %s: expire: %v", g.ID, err)
		}
	}
}

// closeGroupBuy ends an open purchase without paying: wallet holds go back
// at once (they are worked out from open purchases) and PayPal holds are
// voided.
func (s *Service) closeGroupBuy(ctx context.Context, g *domain.GroupBuy, status, note string) (*domain.GroupBuy, error) {
	s.mu.Lock()
	if g.Status != "open" {
		s.mu.Unlock()
		return g, nil
	}
	now := s.now()
	g.Status, g.Note, g.DoneAt = status, note, &now
	var auths []string
	for _, sh := range g.Shares {
		if sh.AuthID != "" {
			auths = append(auths, sh.AuthID)
		}
	}
	s.track(g)
	s.alertL(g.TripID, "", "group_buy", shortTitle(g.Item.Title)+" is off", titleCase(note)+". Nobody was charged.")
	err := s.commitL()
	s.mu.Unlock()
	for _, a := range auths {
		if verr := s.pp.VoidAuthorization(ctx, a); verr != nil {
			log.Printf("group buy %s: void %s: %v", g.ID, a, verr)
		}
	}
	return g, err
}

// maybeFinish pays a purchase once everyone is in: it captures the PayPal
// holds, then moves every share out of the trip wallet to the shop in one
// ledger entry and writes the expense. If PayPal refuses a capture, the
// purchase fails: money already captured becomes that person's trip share,
// the other holds are voided, and nothing is bought.
func (s *Service) maybeFinish(ctx context.Context, id string) (*domain.GroupBuy, error) {
	s.mu.Lock()
	var g *domain.GroupBuy
	for _, x := range s.groupBuys {
		if x.ID == id {
			g = x
		}
	}
	if g == nil || g.Status != "open" {
		s.mu.Unlock()
		return g, nil
	}
	if s.overdueL(g) {
		s.mu.Unlock()
		return s.closeGroupBuy(ctx, g, "expired", "not everyone said yes in time")
	}
	for _, sh := range g.Shares {
		if sh.Status != "in" {
			s.mu.Unlock()
			return g, nil // still waiting for someone
		}
	}
	g.Status = "paying" // nobody else starts the captures
	type capture struct {
		userID, authID string
		amount         Paise
	}
	var todo []capture
	for _, sh := range g.Shares {
		if sh.Via == ViaPayPal {
			todo = append(todo, capture{sh.UserID, sh.AuthID, sh.Amount})
		}
	}
	s.mu.Unlock()

	var captured []capture
	var failed error
	for _, c := range todo {
		cctx, cancel := context.WithTimeout(ctx, 30*time.Second)
		err := s.pp.CaptureAuthorization(cctx, c.authID)
		cancel()
		if err != nil {
			log.Printf("group buy %s: capture %s: %v", g.ID, c.authID, err)
			failed = err
			break
		}
		captured = append(captured, c)
	}

	s.mu.Lock()
	now := s.now()
	t := s.trips[g.TripID]
	// PayPal money that was taken becomes the person's trip share, as if
	// they had put it in with PayPal.
	for _, c := range captured {
		if err := s.postL(domain.Entry{ID: s.idL("je"), Kind: "deposit", TripID: g.TripID, Ref: "paypal:" + g.ID, At: now, Postings: []domain.Posting{
			{Account: domain.ClearingAccount(g.TripID), Debit: c.amount}, {Account: domain.ShareAccount(g.TripID, c.userID), Credit: c.amount},
		}}); err != nil {
			s.mu.Unlock()
			return nil, err
		}
	}
	if failed != nil {
		g.Status, g.Note, g.DoneAt = "failed", "PayPal did not take one of the payments", &now
		s.track(g)
		s.alertL(g.TripID, "", "group_buy", shortTitle(g.Item.Title)+" was not bought", "PayPal did not take one payment. Anything PayPal already took is in that person's trip share.")
		var rest []string
		for _, c := range todo[len(captured):] {
			rest = append(rest, c.authID)
		}
		err := s.commitL()
		s.mu.Unlock()
		for _, a := range rest {
			if verr := s.pp.VoidAuthorization(ctx, a); verr != nil {
				log.Printf("group buy %s: void %s: %v", g.ID, a, verr)
			}
		}
		if err != nil {
			return nil, err
		}
		return g, paypalErr(failed)
	}

	// Everyone's share leaves the trip wallet for the shop.
	expID := s.idL("exp")
	postings := []domain.Posting{}
	shares := []domain.Share{}
	for _, sh := range g.Shares {
		postings = append(postings, domain.Posting{Account: domain.ShareAccount(g.TripID, sh.UserID), Debit: sh.Amount})
		shares = append(shares, domain.Share{UserID: sh.UserID, Amount: sh.Amount})
	}
	postings = append(postings, domain.Posting{Account: domain.ClearingAccount(g.TripID), Credit: g.Amount})
	if err := s.postL(domain.Entry{ID: s.idL("je"), Kind: "spend", TripID: g.TripID, Ref: expID, At: now, Postings: postings}); err != nil {
		g.Status = "open"
		s.mu.Unlock()
		return nil, err
	}
	e := &domain.Expense{ID: expID, TripID: g.TripID, PaidBy: g.ProposedBy, Description: shortTitle(g.Item.Title), Category: g.Category,
		Amount: g.Amount, Mode: ModeGroupBuy, Payee: firstNonEmpty(g.Item.Merchant, "the shop"), Shares: shares, At: now}
	s.expenses = append(s.expenses, e)
	s.track(e)
	g.Status, g.ExpenseID, g.DoneAt = "paid", expID, &now
	s.track(g)
	name := "the trip"
	if t != nil {
		name = t.Name
	}
	s.alertL(g.TripID, "", "group_buy", "Bought: "+shortTitle(g.Item.Title), "Everyone said yes. "+INR(g.Amount)+" paid from the "+name+" wallet.")
	err := s.commitL()
	s.mu.Unlock()
	if err != nil {
		return nil, err
	}
	return g, nil
}

// groupBuyProgressL is "2 of 3 are in · waiting for Dev".
func (s *Service) groupBuyProgressL(g *domain.GroupBuy) string {
	in, waiting := 0, []string{}
	for _, sh := range g.Shares {
		if sh.Status == "in" {
			in++
		} else {
			waiting = append(waiting, s.name(sh.UserID))
		}
	}
	out := strconv.Itoa(in) + " of " + strconv.Itoa(len(g.Shares)) + " are in"
	if len(waiting) > 0 {
		out += " · waiting for " + strings.Join(waiting, ", ")
	}
	return out
}

func paypalErr(err error) error {
	log.Printf("paypal: %v", err)
	return &domain.Error{Status: http.StatusBadGateway, Code: "paypal_error", Message: "PayPal did not answer as expected. Nothing was charged; try again."}
}

// shortTitle keeps product titles readable in alerts and lists.
func shortTitle(t string) string {
	t = strings.TrimSpace(t)
	if i := strings.IndexAny(t, ",|("); i > 12 {
		t = strings.TrimSpace(t[:i])
	}
	if r := []rune(t); len(r) > 48 {
		t = strings.TrimSpace(string(r[:47])) + "…"
	}
	return t
}

func formatWhen(t time.Time) string { return t.In(IST).Format("Mon 2 Jan, 3:04 pm") }

// guessCategory files a purchase under a trip budget from the words used.
func guessCategory(query string) domain.Category {
	q := " " + strings.ToLower(query) + " "
	for _, w := range []string{" snack", " food", " drink", " water", " beer", " fruit", " coffee", " tea "} {
		if strings.Contains(q, w) {
			return domain.Food
		}
	}
	for _, w := range []string{" tent", " sleeping", " room", " stay"} {
		if strings.Contains(q, w) {
			return domain.Stay
		}
	}
	for _, w := range []string{" fuel", " ticket", " cab", " helmet", " bike"} {
		if strings.Contains(q, w) {
			return domain.Transport
		}
	}
	return domain.Other
}
