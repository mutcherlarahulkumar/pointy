package app

import (
	"context"
	"strconv"
	"strings"
	"time"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/paypal"
)

const (
	ModePayee     = "paypal_payee" // PayPal pays the payee directly
	ModeReimburse = "reimburse"    // a member already paid; pay them back
)

type ExpenseInput struct {
	Description       string              `json:"description"`
	Category          domain.Category     `json:"category"`
	Amount            Paise               `json:"amount_paise"`
	Mode              string              `json:"mode"`
	Payee             string              `json:"payee"`
	PayeeEmail        string              `json:"payee_email"`
	Method            domain.SplitMethod  `json:"split_method"`
	Participants      []domain.SplitInput `json:"participants"`
	PlaceName         string              `json:"place_name"`
	PlaceType         string              `json:"place_type"`
	Lat               float64             `json:"lat"`
	Lng               float64             `json:"lng"`
	At                *time.Time          `json:"at"`
	ConfirmOverBudget bool                `json:"confirm_over_budget"`
}

func (in *ExpenseInput) normalise(now time.Time) error {
	in.Description = strings.TrimSpace(in.Description)
	if in.Description == "" {
		return domain.Invalid("say what the payment is for")
	}
	if in.Category == "" {
		in.Category = domain.Other
	}
	if !domain.ValidCategory(in.Category) {
		return domain.Invalid("unknown category %q", in.Category)
	}
	if in.Mode == "" {
		in.Mode = ModePayee
	}
	if in.Mode != ModePayee && in.Mode != ModeReimburse {
		return domain.Invalid("mode must be %q or %q", ModePayee, ModeReimburse)
	}
	if in.Mode == ModePayee && in.PayeeEmail == "" {
		return domain.Invalid("payee_email is needed to pay a payee through PayPal")
	}
	if in.At == nil {
		in.At = &now
	}
	return nil
}

func (s *Service) spentL(tripID string, cat domain.Category) (sum Paise) {
	for _, e := range s.expenses {
		if e.TripID == tripID && e.Category == cat {
			sum += e.Amount
		}
	}
	return
}

// AddExpense pays from a trip wallet and splits the cost.
//
// The order matters: check, reserve each share, call PayPal, then write the
// ledger. The reservation ("hold") is what stops two payments made at the
// same moment from spending the same rupee.
func (s *Service) AddExpense(ctx context.Context, tripID, userID string, in ExpenseInput) (*domain.Expense, error) {
	s.mu.Lock()
	t, err := s.openTripL(tripID, userID)
	if err == nil {
		err = in.normalise(s.now())
	}
	if err != nil {
		s.mu.Unlock()
		return nil, err
	}
	if len(in.Participants) == 0 {
		for _, m := range t.Members {
			in.Participants = append(in.Participants, domain.SplitInput{UserID: m, Weight: 1})
		}
	}
	for _, p := range in.Participants {
		if !t.HasMember(p.UserID) {
			s.mu.Unlock()
			return nil, domain.Invalid("%q is not on this trip", p.UserID)
		}
	}
	shares, err := domain.Split(in.Amount, in.Method, in.Participants)
	if err != nil {
		s.mu.Unlock()
		return nil, err
	}
	for _, sh := range shares {
		acc := domain.ShareAccount(tripID, sh.UserID)
		if avail := s.ledger.Owed(acc) - s.holds[acc]; avail < sh.Amount {
			s.mu.Unlock()
			return nil, domain.Conflict("insufficient_share", s.users[sh.UserID].Name+" has "+INR(avail)+" left in their share but this needs "+INR(sh.Amount),
				map[string]any{"user_id": sh.UserID, "available_paise": avail, "needed_paise": sh.Amount})
		}
	}
	check := domain.CheckBudget(in.Category, t.Budgets[in.Category], s.spentL(tripID, in.Category), in.Amount)
	if check.Warn && !in.ConfirmOverBudget {
		s.mu.Unlock()
		return nil, domain.Conflict("budget_warning", "this payment takes the "+string(in.Category)+" budget to "+itoa(check.PercentAfter)+"%. Send it again with confirm_over_budget to pay anyway", check)
	}
	for _, sh := range shares {
		s.holds[domain.ShareAccount(tripID, sh.UserID)] += sh.Amount
	}
	id := s.idL("exp")
	receiver := in.PayeeEmail
	if in.Mode == ModeReimburse {
		receiver = s.users[userID].PayPalEmail
	}
	s.mu.Unlock()

	payoutID, perr := s.pp.Payout(ctx, id, []paypal.PayoutItem{{ReceiverEmail: receiver, Amount: in.Amount, Note: in.Description, ItemID: id}})

	s.mu.Lock()
	defer s.mu.Unlock()
	for _, sh := range shares {
		s.holds[domain.ShareAccount(tripID, sh.UserID)] -= sh.Amount
	}
	if perr != nil {
		return nil, rail(perr)
	}
	postings := []domain.Posting{{Account: domain.ClearingAccount(tripID), Credit: in.Amount}}
	for _, sh := range shares {
		if sh.Amount > 0 {
			postings = append(postings, domain.Posting{Account: domain.ShareAccount(tripID, sh.UserID), Debit: sh.Amount})
		}
	}
	if err := s.ledger.Post(domain.Entry{ID: s.idL("je"), Kind: "spend", TripID: tripID, Ref: id, At: *in.At, Postings: postings}); err != nil {
		return nil, err
	}
	e := &domain.Expense{ID: id, TripID: tripID, PaidBy: userID, Description: in.Description, Category: in.Category, Amount: in.Amount, Mode: in.Mode,
		Payee: in.Payee, Shares: shares, PlaceName: in.PlaceName, PlaceType: in.PlaceType, Lat: in.Lat, Lng: in.Lng, At: *in.At, PayoutID: payoutID}
	s.expenses = append(s.expenses, e)

	s.alertL(tripID, "", "payment", "Paid "+firstNonEmpty(in.Payee, in.Description), INR(in.Amount)+" from the "+t.Name+" wallet")
	if check.Warn {
		title := titleCase(string(in.Category)) + " budget at " + itoa(check.PercentAfter) + "%"
		body := INR(check.Left) + " left"
		if check.Over100 {
			body = INR(-check.Left) + " over the budget"
		}
		s.alertL(tripID, "", "budget", title, body)
	}
	for _, sh := range shares {
		if left := s.ledger.Owed(domain.ShareAccount(tripID, sh.UserID)); left < LowShare {
			s.alertL(tripID, sh.UserID, "share", "Your trip share is low", INR(left)+" left in "+t.Name)
		}
	}
	return e, nil
}

// PayPersonal pays from the user's own balance. Nothing is split.
func (s *Service) PayPersonal(ctx context.Context, userID string, in ExpenseInput) (*domain.Expense, error) {
	s.mu.Lock()
	u, ok := s.users[userID]
	if !ok {
		s.mu.Unlock()
		return nil, domain.NotFound("user")
	}
	in.Mode = ModePayee
	if err := in.normalise(s.now()); err != nil {
		s.mu.Unlock()
		return nil, err
	}
	acc := domain.PersonalAccount(userID)
	if in.Amount <= 0 || s.ledger.Owed(acc)-s.holds[acc] < in.Amount {
		s.mu.Unlock()
		return nil, domain.Conflict("insufficient_balance", "your personal balance does not cover this payment", nil)
	}
	s.holds[acc] += in.Amount
	id := s.idL("exp")
	s.mu.Unlock()

	payoutID, perr := s.pp.Payout(ctx, id, []paypal.PayoutItem{{ReceiverEmail: in.PayeeEmail, Amount: in.Amount, Note: in.Description, ItemID: id}})

	s.mu.Lock()
	defer s.mu.Unlock()
	s.holds[acc] -= in.Amount
	if perr != nil {
		return nil, rail(perr)
	}
	if err := s.ledger.Post(domain.Entry{ID: s.idL("je"), Kind: "spend", Ref: id, At: *in.At, Postings: []domain.Posting{
		{Account: acc, Debit: in.Amount}, {Account: domain.PersonalClearing, Credit: in.Amount},
	}}); err != nil {
		return nil, err
	}
	e := &domain.Expense{ID: id, PaidBy: u.ID, Description: in.Description, Category: in.Category, Amount: in.Amount, Mode: in.Mode, Payee: in.Payee,
		Shares: []domain.Share{{UserID: userID, Amount: in.Amount}}, PlaceName: in.PlaceName, PlaceType: in.PlaceType, Lat: in.Lat, Lng: in.Lng, At: *in.At, PayoutID: payoutID}
	s.expenses = append(s.expenses, e)
	return e, nil
}

func (s *Service) Expenses(tripID, userID string) ([]*domain.Expense, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, err := s.tripL(tripID, userID); err != nil {
		return nil, err
	}
	out := []*domain.Expense{}
	for i := len(s.expenses) - 1; i >= 0; i-- {
		if s.expenses[i].TripID == tripID {
			out = append(out, s.expenses[i])
		}
	}
	return out, nil
}

func itoa(n int) string { return strconv.Itoa(n) }

func titleCase(s string) string {
	if s == "" {
		return s
	}
	return strings.ToUpper(s[:1]) + s[1:]
}

func firstNonEmpty(a, b string) string {
	if a != "" {
		return a
	}
	return b
}
