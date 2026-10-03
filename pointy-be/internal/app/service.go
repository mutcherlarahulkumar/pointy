// Package app holds the use cases. It keeps its state in memory behind one
// mutex, which is enough for a demo; a database-backed store can replace the
// maps without changing the HTTP layer.
package app

import (
	"context"
	"fmt"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/paypal"
)

type (
	Paise = domain.Paise
)

// LowShare is the level below which a member is told to top up.
const LowShare = Paise(100000) // ₹1,000

type Service struct {
	mu  sync.Mutex
	now func() time.Time
	pp  paypal.Client

	ledger    *domain.Ledger
	holds     map[string]Paise // money reserved while PayPal is being called
	users     map[string]*domain.User
	trips     map[string]*domain.Trip
	tripOrder []string
	deposits  map[string]*domain.Deposit // keyed by PayPal order id
	expenses  []*domain.Expense
	requests  map[string]*domain.DepositRequest
	reqOrder  []string
	plans     map[string]*domain.Plan
	alerts    []*domain.Alert
	seq       int
}

func New(pp paypal.Client, now func() time.Time) *Service {
	return &Service{
		now: now, pp: pp, ledger: &domain.Ledger{}, holds: map[string]Paise{},
		users: map[string]*domain.User{}, trips: map[string]*domain.Trip{},
		deposits: map[string]*domain.Deposit{}, requests: map[string]*domain.DepositRequest{},
		plans: map[string]*domain.Plan{},
	}
}

// Functions ending in L expect s.mu to be held by the caller.

func (s *Service) idL(prefix string) string {
	s.seq++
	return fmt.Sprintf("%s_%04d", prefix, s.seq)
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
	s.alerts = append(s.alerts, &domain.Alert{ID: s.idL("al"), TripID: tripID, UserID: userID, Kind: kind, Title: title, Body: body, At: s.now()})
}

// ---------------------------------------------------------------- me

type Me struct {
	User            *domain.User `json:"user"`
	PersonalBalance Paise        `json:"personal_balance_paise"`
	ActiveTripID    string       `json:"active_trip_id,omitempty"`
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
	return m, nil
}

func (s *Service) activeTripL(userID string, at time.Time) *domain.Trip {
	for _, id := range s.tripOrder {
		t := s.trips[id]
		if t.Status == domain.TripOpen && t.HasMember(userID) && !at.Before(t.Start) && at.Before(t.End.Add(24*time.Hour)) {
			return t
		}
	}
	return nil
}

// ---------------------------------------------------------------- trips

type MemberView struct {
	User      *domain.User `json:"user"`
	Deposited Paise        `json:"deposited_paise"`
	Used      Paise        `json:"used_paise"`
	Left      Paise        `json:"left_paise"`
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
		m := MemberView{User: s.users[uid], Deposited: dep, Used: used, Left: s.ledger.Owed(acc)}
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
	for _, id := range s.tripOrder {
		if t := s.trips[id]; t.HasMember(userID) {
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
	if strings.TrimSpace(in.Name) == "" || in.Start.IsZero() || in.End.Before(in.Start) || in.DepositTarget < 0 {
		return TripView{}, domain.Invalid("a trip needs a name, a start, an end on or after the start, and a deposit that is not negative")
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
	t := &domain.Trip{ID: s.idL("trip"), Name: in.Name, Place: in.Place, Start: in.Start, End: in.End, OrganiserID: userID,
		Members: members, DepositTarget: in.DepositTarget, Budgets: budgets, Status: domain.TripOpen, CreatedAt: s.now()}
	s.trips[t.ID] = t
	s.tripOrder = append(s.tripOrder, t.ID)
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

// ---------------------------------------------------------------- deposits

// StartDeposit creates the PayPal order. No money has moved yet.
func (s *Service) StartDeposit(ctx context.Context, tripID, userID string, amount Paise) (*domain.Deposit, error) {
	s.mu.Lock()
	t, err := s.openTripL(tripID, userID)
	if err == nil && amount <= 0 {
		err = domain.Invalid("amount must be more than zero")
	}
	var id, name string
	if err == nil {
		id, name = s.idL("dep"), t.Name
	}
	s.mu.Unlock()
	if err != nil {
		return nil, err
	}
	o, perr := s.pp.CreateOrder(ctx, id, amount, "Deposit for "+name)
	if perr != nil {
		return nil, rail(perr)
	}
	d := &domain.Deposit{ID: id, TripID: tripID, UserID: userID, Amount: amount, OrderID: o.ID, ApproveURL: o.ApproveURL, Status: "created", CreatedAt: s.now()}
	s.mu.Lock()
	s.deposits[o.ID] = d
	s.mu.Unlock()
	return d, nil
}

// CaptureDeposit takes the money and credits the member's share. Calling it
// twice for the same order credits only once.
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
		return nil, domain.Conflict("capture_in_progress", "this deposit is already being captured", nil)
	}
	d.Status = "capturing"
	s.mu.Unlock()

	perr := s.pp.CaptureOrder(ctx, orderID)

	s.mu.Lock()
	defer s.mu.Unlock()
	if perr != nil {
		d.Status = "created"
		return nil, rail(perr)
	}
	if err := s.creditShareL(d.TripID, d.UserID, d.Amount, d.OrderID, s.now()); err != nil {
		return nil, err
	}
	d.Status = "captured"
	s.alertL(d.TripID, "", "deposit", s.users[d.UserID].Name+" added "+INR(d.Amount), "The trip wallet now holds "+INR(s.ledger.Held(domain.ClearingAccount(d.TripID))))
	return d, nil
}

func (s *Service) creditShareL(tripID, userID string, amount Paise, ref string, at time.Time) error {
	return s.ledger.Post(domain.Entry{ID: s.idL("je"), Kind: "deposit", TripID: tripID, Ref: ref, At: at, Postings: []domain.Posting{
		{Account: domain.ClearingAccount(tripID), Debit: amount},
		{Account: domain.ShareAccount(tripID, userID), Credit: amount},
	}})
}

// ---------------------------------------------------------------- history and alerts

type HistoryItem struct {
	Kind      string          `json:"kind"`   // payment, deposit, refund
	Wallet    string          `json:"wallet"` // trip, personal
	TripID    string          `json:"trip_id,omitempty"`
	TripName  string          `json:"trip_name,omitempty"`
	Title     string          `json:"title"`
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
		if !mine {
			continue
		}
		h := HistoryItem{Kind: "payment", Wallet: "personal", Title: e.Description, Category: e.Category, Amount: e.Amount, YourPart: part, PlaceName: e.PlaceName, At: e.At}
		if e.TripID != "" {
			h.Wallet, h.TripID, h.TripName = "trip", e.TripID, s.trips[e.TripID].Name
		}
		out = append(out, h)
	}
	for _, e := range s.ledger.Entries() {
		if e.Kind != "deposit" && e.Kind != "refund" {
			continue
		}
		for _, p := range e.Postings {
			if e.TripID != "" && p.Account == domain.ShareAccount(e.TripID, userID) {
				amt, title := p.Credit, "Added to "+s.trips[e.TripID].Name
				if e.Kind == "refund" {
					amt, title = p.Debit, "Refund from "+s.trips[e.TripID].Name
				}
				out = append(out, HistoryItem{Kind: e.Kind, Wallet: "trip", TripID: e.TripID, TripName: s.trips[e.TripID].Name, Title: title, Amount: amt, YourPart: amt, At: e.At})
			}
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].At.After(out[j].At) })
	return out
}

func (s *Service) Alerts(userID string) []*domain.Alert {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []*domain.Alert{}
	for i := len(s.alerts) - 1; i >= 0; i-- {
		a := s.alerts[i]
		if a.UserID == userID || (a.UserID == "" && a.TripID != "" && s.trips[a.TripID].HasMember(userID)) {
			out = append(out, a)
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].At.After(out[j].At) })
	return out
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
