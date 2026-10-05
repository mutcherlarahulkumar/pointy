package app

import (
	"sort"
	"strings"
	"time"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
)

// ---------------------------------------------------------------- people

// LookupPhone finds the Pointy user with this number.
func (s *Service) LookupPhone(raw string) (domain.PublicUser, error) {
	phone, err := NormalizePhone(raw)
	if err != nil {
		return domain.PublicUser{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	id, ok := s.phones[phone]
	if !ok {
		return domain.PublicUser{}, &domain.Error{Status: 404, Code: "not_found", Message: "no one on Pointy uses this number yet; ask them to join"}
	}
	return s.users[id].Public(), nil
}

// PublicProfile is what a scanned Pointy QR code resolves to.
func (s *Service) PublicProfile(id string) (domain.PublicUser, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	u, ok := s.users[id]
	if !ok {
		return domain.PublicUser{}, domain.NotFound("user")
	}
	return u.Public(), nil
}

// Contacts are the people you have shared a trip, a payment or a request
// with, most recent first.
func (s *Service) Contacts(userID string) []domain.PublicUser {
	s.mu.Lock()
	defer s.mu.Unlock()
	last := map[string]time.Time{}
	see := func(id string, at time.Time) {
		if id != userID && id != "" && at.After(last[id]) {
			last[id] = at
		}
	}
	for _, t := range s.trips {
		if t.HasMember(userID) {
			for _, m := range t.Members {
				see(m, t.CreatedAt)
			}
		}
	}
	for _, e := range s.expenses {
		if e.PaidBy == userID {
			see(e.PayeeUserID, e.At)
		}
		if e.PayeeUserID == userID {
			see(e.PaidBy, e.At)
		}
	}
	for _, r := range s.moneyRequests {
		if r.RequesterID == userID {
			see(r.PayerID, r.CreatedAt)
		}
		if r.PayerID == userID {
			see(r.RequesterID, r.CreatedAt)
		}
	}
	out := []domain.PublicUser{}
	for id := range last {
		out = append(out, s.users[id].Public())
	}
	sort.Slice(out, func(i, j int) bool { return last[out[i].ID].After(last[out[j].ID]) })
	return out
}

// ---------------------------------------------------------------- money requests

type MoneyRequestView struct {
	*domain.MoneyRequest
	Requester domain.PublicUser `json:"requester"`
	Payer     domain.PublicUser `json:"payer"`
	Direction string            `json:"direction"` // incoming (you are asked to pay) or outgoing
}

func (s *Service) mrViewL(r *domain.MoneyRequest, userID string) MoneyRequestView {
	v := MoneyRequestView{MoneyRequest: r, Requester: s.users[r.RequesterID].Public(), Payer: s.users[r.PayerID].Public(), Direction: "outgoing"}
	if r.PayerID == userID {
		v.Direction = "incoming"
	}
	return v
}

type MoneyRequestInput struct {
	PayerID string `json:"payer_id"`
	Amount  Paise  `json:"amount_paise"`
	Note    string `json:"note"`
}

// RequestMoney asks another Pointy user to pay you.
func (s *Service) RequestMoney(userID string, in MoneyRequestInput) (MoneyRequestView, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r, err := s.requestMoneyL(userID, in)
	if err != nil {
		return MoneyRequestView{}, err
	}
	if err := s.commitL(); err != nil {
		return MoneyRequestView{}, err
	}
	return s.mrViewL(r, userID), nil
}

func (s *Service) requestMoneyL(userID string, in MoneyRequestInput) (*domain.MoneyRequest, error) {
	if err := checkAmount(in.Amount); err != nil {
		return nil, err
	}
	if _, ok := s.users[in.PayerID]; !ok {
		return nil, domain.Invalid("choose who to ask")
	}
	if in.PayerID == userID {
		return nil, domain.Invalid("you cannot ask yourself for money")
	}
	note := strings.TrimSpace(in.Note)
	if len([]rune(note)) > 80 {
		return nil, domain.Invalid("keep the note under 80 letters")
	}
	r := &domain.MoneyRequest{ID: s.idL("mr"), RequesterID: userID, PayerID: in.PayerID, Amount: in.Amount, Note: note, Status: "open", CreatedAt: s.now()}
	s.moneyRequests = append(s.moneyRequests, r)
	s.track(r)
	body := "Tap to pay or decline"
	if note != "" {
		body = note
	}
	s.alertL("", in.PayerID, "request", s.name(userID)+" asked you for "+INR(in.Amount), body)
	return r, nil
}

func (s *Service) MoneyRequests(userID string) []MoneyRequestView {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []MoneyRequestView{}
	for i := len(s.moneyRequests) - 1; i >= 0; i-- {
		r := s.moneyRequests[i]
		if r.RequesterID == userID || r.PayerID == userID {
			out = append(out, s.mrViewL(r, userID))
		}
	}
	return out
}

// PayMoneyRequest pays a request someone sent you, from your balance.
func (s *Service) PayMoneyRequest(userID, id string) (MoneyRequestView, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r := s.findMRL(id)
	switch {
	case r == nil || r.PayerID != userID:
		return MoneyRequestView{}, domain.NotFound("request")
	case r.Status != "open":
		return MoneyRequestView{}, domain.Conflict("already_closed", "this request is already "+r.Status, nil)
	}
	now := s.now()
	desc := firstNonEmpty(r.Note, "Requested by "+s.name(r.RequesterID))
	if _, err := s.transferL(userID, r.RequesterID, ExpenseInput{Description: desc, Category: domain.Other, Amount: r.Amount, At: &now},
		s.name(userID)+" paid your request of "+INR(r.Amount)); err != nil {
		return MoneyRequestView{}, err
	}
	r.Status, r.ClosedAt = "paid", &now
	s.track(r)
	if err := s.commitL(); err != nil {
		return MoneyRequestView{}, err
	}
	return s.mrViewL(r, userID), nil
}

// DeclineMoneyRequest closes a request: the payer declines it, or the
// person who asked cancels it.
func (s *Service) DeclineMoneyRequest(userID, id string) (MoneyRequestView, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r := s.findMRL(id)
	switch {
	case r == nil || (r.PayerID != userID && r.RequesterID != userID):
		return MoneyRequestView{}, domain.NotFound("request")
	case r.Status != "open":
		return MoneyRequestView{}, domain.Conflict("already_closed", "this request is already "+r.Status, nil)
	}
	now := s.now()
	r.ClosedAt = &now
	if r.PayerID == userID {
		r.Status = "declined"
		s.alertL("", r.RequesterID, "request", s.name(userID)+" declined your request", INR(r.Amount)+" · "+firstNonEmpty(r.Note, "no note"))
	} else {
		r.Status = "cancelled"
	}
	s.track(r)
	if err := s.commitL(); err != nil {
		return MoneyRequestView{}, err
	}
	return s.mrViewL(r, userID), nil
}

func (s *Service) findMRL(id string) *domain.MoneyRequest {
	for _, r := range s.moneyRequests {
		if r.ID == id {
			return r
		}
	}
	return nil
}

// ---------------------------------------------------------------- split a bill

type SplitBillInput struct {
	Description  string              `json:"description"`
	Amount       Paise               `json:"amount_paise"`
	Method       domain.SplitMethod  `json:"split_method"`
	Participants []domain.SplitInput `json:"participants"` // include yourself to take a share
}

type SplitBillResult struct {
	Shares   []domain.Share     `json:"shares"`
	Requests []MoneyRequestView `json:"requests"`
}

// SplitBill is for a bill you already paid (cash, UPI or card): it works
// out everyone's share and sends each person a request for theirs.
func (s *Service) SplitBill(userID string, in SplitBillInput) (SplitBillResult, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	in.Description = strings.TrimSpace(in.Description)
	if in.Description == "" {
		return SplitBillResult{}, domain.Invalid("say what the bill was for")
	}
	if err := checkAmount(in.Amount); err != nil {
		return SplitBillResult{}, err
	}
	for _, p := range in.Participants {
		if _, ok := s.users[p.UserID]; !ok {
			return SplitBillResult{}, domain.Invalid("unknown person %q", p.UserID)
		}
	}
	shares, err := domain.Split(in.Amount, in.Method, in.Participants)
	if err != nil {
		return SplitBillResult{}, err
	}
	out := SplitBillResult{Shares: shares, Requests: []MoneyRequestView{}}
	for _, sh := range shares {
		if sh.UserID == userID || sh.Amount == 0 {
			continue
		}
		r, err := s.requestMoneyL(userID, MoneyRequestInput{PayerID: sh.UserID, Amount: sh.Amount, Note: "Your share of " + in.Description})
		if err != nil {
			s.pending = nil
			return SplitBillResult{}, err
		}
		out.Requests = append(out.Requests, s.mrViewL(r, userID))
	}
	if len(out.Requests) == 0 {
		return SplitBillResult{}, domain.Invalid("add at least one other person to split with")
	}
	if err := s.commitL(); err != nil {
		return SplitBillResult{}, err
	}
	return out, nil
}

// ItemSplitInput is a bill split by who had what.
type ItemSplitInput struct {
	Description string          `json:"description"`
	Items       []ItemShareLine `json:"items"`
	// Extra is everything on the bill that is not an item: taxes, service
	// charge and tip (or a discount, negative). It is shared in proportion
	// to what each person had.
	Extra Paise `json:"extra_paise"`
}

// ItemShareLine is one item and who had it (shared equally between them).
type ItemShareLine struct {
	Name   string   `json:"name"`
	Amount Paise    `json:"amount_paise"`
	People []string `json:"people"`
}

// ItemSplitPart is one person's part: their items and their share of the
// extras.
type ItemSplitPart struct {
	User     domain.PublicUser `json:"user"`
	Items    []string          `json:"items"`
	Subtotal Paise             `json:"subtotal_paise"`
	Extra    Paise             `json:"extra_paise"`
	Total    Paise             `json:"total_paise"`
}

// ItemSplitResult is the parts and the requests sent.
type ItemSplitResult struct {
	Total    Paise              `json:"total_paise"`
	Parts    []ItemSplitPart    `json:"parts"`
	Requests []MoneyRequestView `json:"requests"`
}

// SplitByItems shares a bill by who had what: each item is split equally
// between the people who had it, and the extras in proportion to each
// person's items. Everything is whole paise and adds up exactly to the
// bill. Everyone but the person who paid gets a request listing their
// items.
func (s *Service) SplitByItems(userID string, in ItemSplitInput) (ItemSplitResult, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	in.Description = strings.TrimSpace(in.Description)
	if in.Description == "" {
		in.Description = "the bill"
	}
	if len(in.Items) == 0 || len(in.Items) > 100 {
		return ItemSplitResult{}, domain.Invalid("add the items on the bill")
	}
	var order []string // people in the order they first appear
	sub := map[string]Paise{}
	items := map[string][]string{}
	var subtotal Paise
	for _, it := range in.Items {
		name := strings.TrimSpace(it.Name)
		if name == "" || it.Amount <= 0 {
			return ItemSplitResult{}, domain.Invalid("every item needs a name and a price")
		}
		if len(it.People) == 0 {
			return ItemSplitResult{}, domain.Invalid("choose who had %s", name)
		}
		parts := make([]domain.SplitInput, 0, len(it.People))
		for _, p := range it.People {
			if _, ok := s.users[p]; !ok {
				return ItemSplitResult{}, domain.Invalid("unknown person %q", p)
			}
			parts = append(parts, domain.SplitInput{UserID: p, Weight: 1})
		}
		shares, err := domain.Split(it.Amount, domain.SplitEqual, parts)
		if err != nil {
			return ItemSplitResult{}, err
		}
		for _, sh := range shares {
			if _, seen := sub[sh.UserID]; !seen {
				order = append(order, sh.UserID)
			}
			sub[sh.UserID] += sh.Amount
			label := name
			if len(it.People) > 1 {
				label += " (shared)"
			}
			items[sh.UserID] = append(items[sh.UserID], label)
		}
		subtotal += it.Amount
	}
	total := subtotal + in.Extra
	if in.Extra < -subtotal || total <= 0 {
		return ItemSplitResult{}, domain.Invalid("the discount is bigger than the bill")
	}
	if err := checkAmount(total); err != nil {
		return ItemSplitResult{}, err
	}
	// The extras, shared by each person's subtotal.
	extra := map[string]Paise{}
	if in.Extra != 0 {
		ws := make([]domain.SplitInput, 0, len(order))
		for _, u := range order {
			if sub[u] > 0 { // a share of a few paise can round to nothing
				ws = append(ws, domain.SplitInput{UserID: u, Weight: int64(sub[u])})
			}
		}
		abs := in.Extra
		if abs < 0 {
			abs = -abs
		}
		shares, err := domain.Split(abs, domain.SplitShares, ws)
		if err != nil {
			return ItemSplitResult{}, err
		}
		for _, sh := range shares {
			if in.Extra < 0 {
				extra[sh.UserID] = -sh.Amount
			} else {
				extra[sh.UserID] = sh.Amount
			}
		}
	}
	out := ItemSplitResult{Total: total, Parts: []ItemSplitPart{}, Requests: []MoneyRequestView{}}
	for _, u := range order {
		part := ItemSplitPart{User: s.users[u].Public(), Items: items[u], Subtotal: sub[u], Extra: extra[u], Total: sub[u] + extra[u]}
		out.Parts = append(out.Parts, part)
		if u == userID || part.Total <= 0 {
			continue
		}
		r, err := s.requestMoneyL(userID, MoneyRequestInput{PayerID: u, Amount: part.Total, Note: itemNote(in.Description, part.Items)})
		if err != nil {
			s.pending = nil
			return ItemSplitResult{}, err
		}
		out.Requests = append(out.Requests, s.mrViewL(r, userID))
	}
	if len(out.Requests) == 0 {
		return ItemSplitResult{}, domain.Invalid("give at least one item to someone else")
	}
	if err := s.commitL(); err != nil {
		return ItemSplitResult{}, err
	}
	return out, nil
}

// itemNote is "Dinner: Paneer tikka, Lime soda" cut to fit a request note.
func itemNote(desc string, items []string) string {
	note := desc + ": " + strings.Join(items, ", ")
	if r := []rune(note); len(r) > 80 {
		note = strings.TrimSpace(string(r[:79])) + "…"
	}
	return note
}
