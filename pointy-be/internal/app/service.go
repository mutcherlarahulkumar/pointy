// Package app holds the use cases. It keeps a working copy of the state in
// memory behind one mutex and writes every change through to a Store
// (Postgres in production) before answering, so a restart loses nothing.
// Run one instance per database: the in-memory copy is not shared.
//
// Money model: Pointy is a wallet. PayPal is used only at the two edges:
// money comes in with checkout and goes out when a person withdraws. Each
// person has a personal balance and a share in every trip they are on; all
// payments, splits, requests, trip spending and refunds move money between
// those inside one double-entry ledger, which works in India where PayPal
// cannot pay between Indian accounts.
package app

import (
	"context"
	"fmt"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/ai"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/paypal"
)

type Paise = domain.Paise

// LowShare is the level below which a member is told to top up.
const LowShare = Paise(100000) // ₹1,000

// MaxAmount caps one payment or top-up, to catch typos.
const MaxAmount = Paise(10000000) // ₹1,00,000

// IST is India Standard Time. Times are shown and bucketed in it.
var IST = time.FixedZone("IST", 5*3600+1800)

type Service struct {
	mu    sync.Mutex
	now   func() time.Time
	pp    paypal.Client
	store Store

	pending       []any             // objects changed by the operation in progress
	sessions      map[string]string // token hash -> user id
	phones        map[string]string // phone -> user id
	failedLogins  map[string][]time.Time
	ledger        *domain.Ledger
	users         map[string]*domain.User
	trips         map[string]*domain.Trip
	tripOrder     []string
	deposits      map[string]*domain.Deposit // keyed by PayPal order id
	expenses      []*domain.Expense
	requests      map[string]*domain.DepositRequest
	reqOrder      []string
	plans         map[string]*domain.Plan
	alerts        []*domain.Alert
	moneyRequests []*domain.MoneyRequest
	chats         map[string][]*domain.ChatMessage // user id -> conversation with the AI
	payouts       []*domain.Payout                 // money paid out to PayPal accounts
	groupBuys     []*domain.GroupBuy               // purchases a trip's agent found, bought together
	// holds is money set aside while a PayPal payout is being sent, so it
	// cannot be spent twice in the meantime. Never stored: a payout either
	// finishes (and is posted) or is released.
	holds map[string]Paise

	// ai is optional: without it summaries and the assistant use rules.
	ai          ai.Assistant
	shop        Shopper                  // optional product search (Channel3)
	searches    map[string]*agentSearch  // shopping agent answers, by search id
	aiSummaries map[string]cachedSummary // trip id -> last AI summary
}

// SetAssistant turns on the language-model features.
func (s *Service) SetAssistant(a ai.Assistant) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ai = a
}

// New makes a service with no state. Call Load to read what store holds;
// a nil store keeps everything in memory only.
func New(pp paypal.Client, now func() time.Time, store Store) *Service {
	if store == nil {
		store = MemoryStore{}
	}
	return &Service{
		now: now, pp: pp, store: store, ledger: &domain.Ledger{},
		users: map[string]*domain.User{}, trips: map[string]*domain.Trip{},
		deposits: map[string]*domain.Deposit{}, requests: map[string]*domain.DepositRequest{},
		plans: map[string]*domain.Plan{}, sessions: map[string]string{}, phones: map[string]string{},
		failedLogins: map[string][]time.Time{}, aiSummaries: map[string]cachedSummary{}, chats: map[string][]*domain.ChatMessage{}, holds: map[string]Paise{},
	}
}

// Functions ending in L expect s.mu to be held by the caller.

func (s *Service) idL(prefix string) string { return newID(prefix) }

// postL writes a journal entry to the ledger and marks it for saving.
func (s *Service) postL(e domain.Entry) error {
	if err := s.ledger.Post(e); err != nil {
		return err
	}
	s.track(e)
	return nil
}

func rail(err error) *domain.Error {
	return &domain.Error{Status: http.StatusBadGateway, Code: "paypal_error", Message: err.Error()}
}

func (s *Service) tripL(tripID, userID string) (*domain.Trip, error) {
	t, ok := s.trips[tripID]
	if !ok {
		return nil, domain.NotFound("trip")
	}
	if !t.HasMember(userID) {
		return nil, domain.Forbidden("you are not a member of this trip")
	}
	return t, nil
}

func (s *Service) openTripL(tripID, userID string) (*domain.Trip, error) {
	t, err := s.tripL(tripID, userID)
	if err != nil {
		return nil, err
	}
	if t.Status != domain.TripOpen {
		return nil, domain.Conflict("trip_closed", "this trip is "+t.Status, nil)
	}
	return t, nil
}

func (s *Service) alertL(tripID, userID, kind, title, body string) {
	a := &domain.Alert{ID: s.idL("al"), TripID: tripID, UserID: userID, Kind: kind, Title: title, Body: body, At: s.now()}
	s.alerts = append(s.alerts, a)
	s.track(a)
}

func (s *Service) name(userID string) string {
	if u, ok := s.users[userID]; ok {
		return u.Name
	}
	return "Someone"
}

func checkAmount(a Paise) error {
	if a <= 0 {
		return domain.Invalid("amount must be more than zero")
	}
	if a > MaxAmount {
		return domain.Invalid("amount is over the %s limit", INR(MaxAmount))
	}
	return nil
}

// ---------------------------------------------------------------- me

type Me struct {
	User            *domain.User `json:"user"`
	PersonalBalance Paise        `json:"personal_balance_paise"`
	ActiveTripID    string       `json:"active_trip_id,omitempty"`
	UnreadAlerts    int          `json:"unread_alerts"`
	OpenRequests    int          `json:"open_requests"` // money people are asking you for
	PayPalMode      string       `json:"paypal_mode"`
	Now             time.Time    `json:"now"`
}

func (s *Service) Me(userID string) (Me, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	u, ok := s.users[userID]
	if !ok {
		return Me{}, domain.NotFound("user")
	}
	m := Me{User: u, PersonalBalance: s.ledger.Owed(domain.PersonalAccount(userID)), PayPalMode: s.pp.Mode(), Now: s.now()}
	if t := s.activeTripL(userID, s.now()); t != nil {
		m.ActiveTripID = t.ID
	}
	for _, a := range s.alertsForL(userID) {
		if a.At.After(u.AlertsSeenAt) {
			m.UnreadAlerts++
		}
	}
	for _, r := range s.moneyRequests {
		if r.PayerID == userID && r.Status == "open" {
			m.OpenRequests++
		}
	}
	for _, r := range s.requests {
		if r.UserID == userID && r.Status == "open" {
			m.OpenRequests++
		}
	}
	return m, nil
}

// activeTripL is the open trip happening now, or else the open trip that
// starts soonest, so a trip being planned still counts.
func (s *Service) activeTripL(userID string, at time.Time) *domain.Trip {
	var next *domain.Trip
	for _, id := range s.tripOrder {
		t := s.trips[id]
		if t.Status != domain.TripOpen || !t.HasMember(userID) {
			continue
		}
		if !at.Before(t.Start) && at.Before(t.End.Add(24*time.Hour)) {
			return t
		}
		if t.Start.After(at) && (next == nil || t.Start.Before(next.Start)) {
			next = t
		}
	}
	return next
}

// currentTripL is the open trip happening right now, if any.
func (s *Service) currentTripL(userID string, at time.Time) *domain.Trip {
	if t := s.activeTripL(userID, at); t != nil && !at.Before(t.Start) {
		return t
	}
	return nil
}

// HandleWebhook maps a verified PayPal event onto the same use case the app
// calls: an approved checkout is captured.
func (s *Service) HandleWebhook(ctx context.Context, eventType, resourceID string) error {
	if eventType == "CHECKOUT.ORDER.APPROVED" {
		_, err := s.CaptureDeposit(ctx, resourceID)
		return err
	}
	return nil // other events are acknowledged and ignored
}

// ---------------------------------------------------------------- trips

type MemberView struct {
	User      domain.PublicUser `json:"user"`
	Deposited Paise             `json:"deposited_paise"`
	Used      Paise             `json:"used_paise"`
	Left      Paise             `json:"left_paise"`
}

type TripView struct {
	*domain.Trip
	Balance       Paise        `json:"balance_paise"`
	Deposited     Paise        `json:"deposited_paise"`
	Spent         Paise        `json:"spent_paise"`
	Target        Paise        `json:"target_paise"`
	Day           int          `json:"day"`
	Days          int          `json:"days"`
	MemberDetails []MemberView `json:"member_details"`
}

func (s *Service) tripViewL(t *domain.Trip) TripView {
	v := TripView{Trip: t, Target: t.DepositTarget * Paise(len(t.Members))}
	v.Day, v.Days = t.DayOf(s.now())
	for _, uid := range t.Members {
		acc := domain.ShareAccount(t.ID, uid)
		_, dep := s.ledger.Totals(acc, "deposit")
		used, _ := s.ledger.Totals(acc, "spend")
		m := MemberView{User: s.users[uid].Public(), Deposited: dep, Used: used, Left: s.ledger.Owed(acc)}
		v.MemberDetails = append(v.MemberDetails, m)
		v.Deposited += dep
		v.Spent += used
	}
	v.Balance = s.ledger.Held(domain.ClearingAccount(t.ID))
	return v
}

func (s *Service) ListTrips(userID string) []TripView {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []TripView{}
	for i := len(s.tripOrder) - 1; i >= 0; i-- {
		if t := s.trips[s.tripOrder[i]]; t.HasMember(userID) {
			out = append(out, s.tripViewL(t))
		}
	}
	return out
}

func (s *Service) Trip(tripID, userID string) (TripView, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	t, err := s.tripL(tripID, userID)
	if err != nil {
		return TripView{}, err
	}
	return s.tripViewL(t), nil
}

type CreateTripInput struct {
	Name          string                    `json:"name"`
	Place         string                    `json:"place"`
	Start         time.Time                 `json:"start"`
	End           time.Time                 `json:"end"`
	Members       []string                  `json:"members"`
	DepositTarget Paise                     `json:"deposit_target_paise"`
	Budgets       map[domain.Category]Paise `json:"budgets_paise"`
}

func (s *Service) CreateTrip(userID string, in CreateTripInput) (TripView, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	in.Name = strings.TrimSpace(in.Name)
	if in.Name == "" || in.Start.IsZero() || in.End.Before(in.Start) || in.DepositTarget < 0 || in.DepositTarget > MaxAmount {
		return TripView{}, domain.Invalid("a trip needs a name, a start, an end on or after the start, and a sensible deposit")
	}
	members := []string{userID}
	for _, m := range in.Members {
		if _, ok := s.users[m]; !ok {
			return TripView{}, domain.Invalid("unknown member %q", m)
		}
		if m != userID && !contains(members, m) {
			members = append(members, m)
		}
	}
	budgets := map[domain.Category]Paise{}
	for c, v := range in.Budgets {
		if !domain.ValidCategory(c) || v < 0 {
			return TripView{}, domain.Invalid("bad budget for %q", c)
		}
		budgets[c] = v
	}
	t := &domain.Trip{ID: s.idL("trip"), Name: in.Name, Place: strings.TrimSpace(in.Place), Start: in.Start, End: in.End, OrganiserID: userID,
		Members: members, DepositTarget: in.DepositTarget, Budgets: budgets, Status: domain.TripOpen, CreatedAt: s.now()}
	s.trips[t.ID] = t
	s.tripOrder = append(s.tripOrder, t.ID)
	s.track(t)
	for _, m := range members[1:] {
		body := "Open the trip to see the plan"
		if t.DepositTarget > 0 {
			body = "Everyone puts in " + INR(t.DepositTarget)
		}
		s.alertL(t.ID, m, "trip", s.name(userID)+" added you to "+t.Name, body)
	}
	if err := s.commitL(); err != nil {
		return TripView{}, err
	}
	return s.tripViewL(t), nil
}

// AddMembers lets the organiser bring more people onto an open trip.
func (s *Service) AddMembers(tripID, userID string, ids []string) (TripView, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	t, err := s.openTripL(tripID, userID)
	if err != nil {
		return TripView{}, err
	}
	if t.OrganiserID != userID {
		return TripView{}, domain.Forbidden("only the organiser can add people")
	}
	for _, m := range ids {
		if _, ok := s.users[m]; !ok {
			return TripView{}, domain.Invalid("unknown member %q", m)
		}
		if !t.HasMember(m) {
			t.Members = append(t.Members, m)
			s.alertL(t.ID, m, "trip", s.name(userID)+" added you to "+t.Name, "Open the trip to see the plan")
		}
	}
	s.track(t)
	if err := s.commitL(); err != nil {
		return TripView{}, err
	}
	return s.tripViewL(t), nil
}

func contains(list []string, v string) bool {
	for _, x := range list {
		if x == v {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------- money in (PayPal checkout)

// StartTopUp creates a PayPal order to add money to the person's own balance.
func (s *Service) StartTopUp(ctx context.Context, userID string, amount Paise) (*domain.Deposit, error) {
	if err := checkAmount(amount); err != nil {
		return nil, err
	}
	return s.startOrder(ctx, "", userID, amount, "Pointy balance top-up")
}

func (s *Service) startOrder(ctx context.Context, tripID, userID string, amount Paise, what string) (*domain.Deposit, error) {
	id := s.idL("dep")
	o, perr := s.pp.CreateOrder(ctx, id, amount, what)
	if perr != nil {
		return nil, rail(perr)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	d := &domain.Deposit{ID: id, TripID: tripID, UserID: userID, Amount: amount, OrderID: o.ID, ApproveURL: o.ApproveURL, Status: "created", CreatedAt: s.now()}
	s.deposits[o.ID] = d
	s.track(d)
	if err := s.commitL(); err != nil {
		return nil, err
	}
	return d, nil
}

// Deposit returns one PayPal order the person started.
func (s *Service) Deposit(orderID, userID string) (*domain.Deposit, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	d, ok := s.deposits[orderID]
	if !ok || (userID != "" && d.UserID != userID) {
		return nil, domain.NotFound("deposit")
	}
	return d, nil
}

// CaptureDeposit takes the money once the person approved on PayPal and
// credits their balance or trip share. Calling it twice credits once.
func (s *Service) CaptureDeposit(ctx context.Context, orderID string) (*domain.Deposit, error) {
	s.mu.Lock()
	d, ok := s.deposits[orderID]
	if !ok {
		s.mu.Unlock()
		return nil, domain.NotFound("deposit")
	}
	if d.Status != "created" {
		defer s.mu.Unlock()
		if d.Status == "captured" {
			return d, nil
		}
		return nil, domain.Conflict("capture_in_progress", "this payment is already being completed", nil)
	}
	d.Status = "capturing"
	s.mu.Unlock()

	perr := s.pp.CaptureOrder(ctx, orderID)

	s.mu.Lock()
	defer s.mu.Unlock()
	if perr != nil {
		d.Status = "created"
		return nil, domain.Conflict("not_approved", "PayPal has not approved this payment yet. Approve it on PayPal, then try again.", map[string]any{"paypal": perr.Error()})
	}
	var err error
	if d.TripID == "" {
		err = s.postL(domain.Entry{ID: s.idL("je"), Kind: "topup", Ref: d.OrderID, At: s.now(), Postings: []domain.Posting{
			{Account: domain.PersonalClearing, Debit: d.Amount}, {Account: domain.PersonalAccount(d.UserID), Credit: d.Amount},
		}})
	} else {
		err = s.postL(domain.Entry{ID: s.idL("je"), Kind: "deposit", TripID: d.TripID, Ref: d.OrderID, At: s.now(), Postings: []domain.Posting{
			{Account: domain.ClearingAccount(d.TripID), Debit: d.Amount}, {Account: domain.ShareAccount(d.TripID, d.UserID), Credit: d.Amount},
		}})
	}
	if err != nil {
		d.Status = "created"
		return nil, err
	}
	d.Status = "captured"
	s.track(d)
	if d.TripID == "" {
		s.alertL("", d.UserID, "money", "Added "+INR(d.Amount)+" to your balance", "Paid with PayPal")
	} else {
		t := s.trips[d.TripID]
		s.alertL(d.TripID, "", "deposit", s.name(d.UserID)+" added "+INR(d.Amount), "The "+t.Name+" wallet now holds "+INR(s.ledger.Held(domain.ClearingAccount(d.TripID))))
		s.closeRequestsL(d.TripID, d.UserID, d.Amount, "paypal")
	}
	if err := s.commitL(); err != nil {
		return nil, err
	}
	return d, nil
}

// DepositFromBalance moves money from the person's balance into their trip
// share. No PayPal call: both sit in Pointy's account already.
func (s *Service) DepositFromBalance(tripID, userID string, amount Paise) (TripView, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	t, err := s.openTripL(tripID, userID)
	if err == nil {
		err = checkAmount(amount)
	}
	if err != nil {
		return TripView{}, err
	}
	if err := s.balanceToTripL(t, userID, amount, "balance"); err != nil {
		return TripView{}, err
	}
	s.alertL(tripID, "", "deposit", s.name(userID)+" added "+INR(amount), "The "+t.Name+" wallet now holds "+INR(s.ledger.Held(domain.ClearingAccount(tripID))))
	s.closeRequestsL(tripID, userID, amount, "balance")
	if err := s.commitL(); err != nil {
		return TripView{}, err
	}
	return s.tripViewL(t), nil
}

// balanceToTripL debits the personal balance and credits the trip share,
// moving the backing money between the two PayPal pools in the same entry.
func (s *Service) balanceToTripL(t *domain.Trip, userID string, amount Paise, ref string) error {
	acc := domain.PersonalAccount(userID)
	if s.availL(acc) < amount {
		return domain.Conflict("insufficient_balance", "your balance is "+INR(s.availL(acc))+"; add money first", map[string]any{"balance_paise": s.availL(acc)})
	}
	return s.postL(domain.Entry{ID: s.idL("je"), Kind: "deposit", TripID: t.ID, Ref: ref, At: s.now(), Postings: []domain.Posting{
		{Account: acc, Debit: amount},
		{Account: domain.ShareAccount(t.ID, userID), Credit: amount},
		{Account: domain.ClearingAccount(t.ID), Debit: amount},
		{Account: domain.PersonalClearing, Credit: amount},
	}})
}

// tripToBalancesL pays out of a trip into people's personal balances: each
// share in debits is reduced, each person in credits receives money.
func (s *Service) tripToBalancesL(t *domain.Trip, kind, ref string, at time.Time, debits, credits map[string]Paise) error {
	var total Paise
	ps := []domain.Posting{}
	for _, uid := range t.Members {
		if a := debits[uid]; a > 0 {
			ps = append(ps, domain.Posting{Account: domain.ShareAccount(t.ID, uid), Debit: a})
			total += a
		}
	}
	var in Paise
	ids := make([]string, 0, len(credits))
	for uid := range credits {
		ids = append(ids, uid)
	}
	sort.Strings(ids)
	for _, uid := range ids {
		if a := credits[uid]; a > 0 {
			ps = append(ps, domain.Posting{Account: domain.PersonalAccount(uid), Credit: a})
			in += a
		}
	}
	if in != total {
		return fmt.Errorf("trip payout does not balance: %d out, %d in", total, in)
	}
	ps = append(ps, domain.Posting{Account: domain.PersonalClearing, Debit: total}, domain.Posting{Account: domain.ClearingAccount(t.ID), Credit: total})
	return s.postL(domain.Entry{ID: s.idL("je"), Kind: kind, TripID: t.ID, Ref: ref, At: at, Postings: ps})
}

// ---------------------------------------------------------------- history and alerts

type HistoryItem struct {
	Kind      string          `json:"kind"`   // payment, received, deposit, topup, refund
	Wallet    string          `json:"wallet"` // trip, personal
	TripID    string          `json:"trip_id,omitempty"`
	TripName  string          `json:"trip_name,omitempty"`
	Title     string          `json:"title"`
	Subtitle  string          `json:"subtitle,omitempty"`
	Category  domain.Category `json:"category,omitempty"`
	Amount    Paise           `json:"amount_paise"`
	YourPart  Paise           `json:"your_part_paise"`
	PlaceName string          `json:"place_name,omitempty"`
	At        time.Time       `json:"at"`
}

func (s *Service) History(userID string) []HistoryItem {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []HistoryItem{}
	for _, e := range s.expenses {
		var part Paise
		mine := false
		for _, sh := range e.Shares {
			if sh.UserID == userID {
				part, mine = sh.Amount, true
			}
		}
		if mine {
			h := HistoryItem{Kind: "payment", Wallet: "personal", Title: e.Description, Subtitle: "To " + e.Payee, Category: e.Category, Amount: e.Amount, YourPart: part, PlaceName: e.PlaceName, At: e.At}
			if e.Mode == ModePayPal {
				h.Subtitle += " by PayPal"
			}
			if e.TripID != "" {
				h.Wallet, h.TripID, h.TripName = "trip", e.TripID, s.trips[e.TripID].Name
			}
			out = append(out, h)
		}
		if e.PayeeUserID == userID {
			h := HistoryItem{Kind: "received", Wallet: "personal", Title: e.Description, Subtitle: "From " + s.name(e.PaidBy), Category: e.Category, Amount: e.Amount, YourPart: e.Amount, At: e.At}
			if e.TripID != "" {
				h.Subtitle = "From the " + s.trips[e.TripID].Name + " wallet"
				h.TripID, h.TripName = e.TripID, s.trips[e.TripID].Name
			}
			out = append(out, h)
		}
	}
	for _, e := range s.ledger.Entries() {
		switch e.Kind {
		case "topup":
			for _, p := range e.Postings {
				if p.Account == domain.PersonalAccount(userID) {
					out = append(out, HistoryItem{Kind: "topup", Wallet: "personal", Title: "Added money", Subtitle: "With PayPal", Amount: p.Credit, YourPart: p.Credit, At: e.At})
				}
			}
		case "deposit", "refund":
			for _, p := range e.Postings {
				if p.Account != domain.ShareAccount(e.TripID, userID) {
					continue
				}
				name := s.trips[e.TripID].Name
				if e.Kind == "deposit" {
					sub := "With PayPal"
					if e.Ref == "balance" {
						sub = "From your balance"
					}
					out = append(out, HistoryItem{Kind: "deposit", Wallet: "trip", TripID: e.TripID, TripName: name, Title: "Added to " + name, Subtitle: sub, Amount: p.Credit, YourPart: p.Credit, At: e.At})
				} else {
					out = append(out, HistoryItem{Kind: "refund", Wallet: "personal", TripID: e.TripID, TripName: name, Title: "Refund from " + name, Subtitle: "Into your balance", Amount: p.Debit, YourPart: p.Debit, At: e.At})
				}
			}
		}
	}
	// Withdrawals to your own PayPal account.
	for _, p := range s.payouts {
		if p.UserID != userID || p.Kind != PayoutWithdraw || p.Status == "failed" {
			continue
		}
		out = append(out, HistoryItem{Kind: "withdrawal", Wallet: "personal", Title: "Withdrawn to PayPal", Subtitle: p.Email + " · " + payoutWords(p.Status),
			Amount: p.Amount, YourPart: p.Amount, At: p.CreatedAt})
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].At.After(out[j].At) })
	return out
}

func (s *Service) alertsForL(userID string) []*domain.Alert {
	out := []*domain.Alert{}
	for i := len(s.alerts) - 1; i >= 0; i-- {
		a := s.alerts[i]
		if a.UserID == userID || (a.UserID == "" && a.TripID != "" && s.trips[a.TripID] != nil && s.trips[a.TripID].HasMember(userID)) {
			out = append(out, a)
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].At.After(out[j].At) })
	return out
}

func (s *Service) Alerts(userID string) []*domain.Alert {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.alertsForL(userID)
}

// MarkAlertsSeen clears the unread badge.
func (s *Service) MarkAlertsSeen(userID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	u, ok := s.users[userID]
	if !ok {
		return domain.NotFound("user")
	}
	u.AlertsSeenAt = s.now()
	s.track(u)
	return s.commitL()
}

// INR formats paise the Indian way: ₹1,20,000 or ₹460.50.
func INR(p Paise) string {
	neg := p < 0
	if neg {
		p = -p
	}
	r, ps := int64(p)/100, int64(p)%100
	digits := fmt.Sprint(r)
	out := digits
	if len(digits) > 3 {
		head, tail := digits[:len(digits)-3], digits[len(digits)-3:]
		var groups []string
		for len(head) > 2 {
			groups = append([]string{head[len(head)-2:]}, groups...)
			head = head[:len(head)-2]
		}
		groups = append([]string{head}, groups...)
		out = strings.Join(groups, ",") + "," + tail
	}
	if ps != 0 {
		out += fmt.Sprintf(".%02d", ps)
	}
	if neg {
		return "-₹" + out
	}
	return "₹" + out
}
