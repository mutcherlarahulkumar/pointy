package app

import (
	"strconv"
	"strings"
	"time"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
)

const (
	ModeMember    = "member"    // the trip wallet pays someone on Pointy
	ModeReimburse = "reimburse" // you already paid (cash, UPI, card); the wallet pays you back
	ModeTransfer  = "transfer"  // a personal payment to another Pointy user
	// ModePayPal: older trip payments sent by PayPal. No longer accepted;
	// kept so their history still reads right.
	ModePayPal = "paypal"
)

type ExpenseInput struct {
	Description       string              `json:"description"`
	Category          domain.Category     `json:"category"`
	Amount            Paise               `json:"amount_paise"`
	Mode              string              `json:"mode"`
	Payee             string              `json:"payee"`         // shop or person name, for the receipt
	PayeeUserID       string              `json:"payee_user_id"` // who receives the money (mode member / personal)
	Method            domain.SplitMethod  `json:"split_method"`
	Participants      []domain.SplitInput `json:"participants"`
	PlaceName         string              `json:"place_name"`
	PlaceType         string              `json:"place_type"`
	Lat               float64             `json:"lat"`
	Lng               float64             `json:"lng"`
	At                *time.Time          `json:"at"`
	ConfirmOverBudget bool                `json:"confirm_over_budget"`
	// ParentCode is a child's one-time approval code from their parent's
	// app, for a payment over the child's limit.
	ParentCode string `json:"parent_code"`
	// parentApproved is set by the server when the parent approved on
	// their own phone.
	parentApproved bool
}

func (in *ExpenseInput) normalise(now time.Time) error {
	in.Description = strings.TrimSpace(in.Description)
	in.Payee = strings.TrimSpace(in.Payee)
	if in.Description == "" {
		return domain.Invalid("say what the payment is for")
	}
	if in.Category == "" {
		in.Category = domain.Other
	}
	if !domain.ValidCategory(in.Category) {
		return domain.Invalid("unknown category %q", in.Category)
	}
	if err := checkAmount(in.Amount); err != nil {
		return err
	}
	if in.At == nil || in.At.After(now) {
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
	return sum
}

// AddExpense pays from a trip wallet and splits the cost. The trip is a
// wallet inside Pointy, so the money moves between Pointy balances:
//   - mode "member": the money goes into a Pointy user's balance.
//   - mode "reimburse": it goes back to the person who already paid the shop
//     in cash, UPI or card.
func (s *Service) AddExpense(tripID, userID string, in ExpenseInput) (*domain.Expense, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	t, shares, check, err := s.prepareExpenseL(tripID, userID, &in)
	if err != nil {
		return nil, err
	}
	e, err := s.recordExpenseL(t, userID, in, shares, check)
	if err != nil {
		return nil, err
	}
	if err := s.commitL(); err != nil {
		return nil, err
	}
	return e, nil
}

// prepareExpenseL checks an expense and works out the shares. Nothing is
// written.
func (s *Service) prepareExpenseL(tripID, userID string, in *ExpenseInput) (*domain.Trip, []domain.Share, domain.BudgetCheck, error) {
	var none domain.BudgetCheck
	t, err := s.openTripL(tripID, userID)
	if err == nil {
		err = in.normalise(s.now())
	}
	if err != nil {
		return nil, nil, none, err
	}
	if in.Mode == "" {
		in.Mode = ModeReimburse
	}
	switch in.Mode {
	case ModeReimburse:
		in.PayeeUserID = userID
	case ModeMember:
		if _, ok := s.users[in.PayeeUserID]; !ok {
			return nil, nil, none, domain.Invalid("choose who on Pointy gets the money")
		}
		// Money into a child account keeps to the child-wallet caps.
		if err := s.childReceiveCheckL(in.PayeeUserID, in.Amount); err != nil {
			return nil, nil, none, err
		}
	default:
		return nil, nil, none, domain.Invalid("mode must be %q or %q", ModeMember, ModeReimburse)
	}
	if in.Payee == "" {
		in.Payee = s.name(in.PayeeUserID)
	}
	if len(in.Participants) == 0 {
		for _, m := range t.Members {
			in.Participants = append(in.Participants, domain.SplitInput{UserID: m, Weight: 1})
		}
	}
	for _, p := range in.Participants {
		if !t.HasMember(p.UserID) {
			return nil, nil, none, domain.Invalid("%q is not on this trip", p.UserID)
		}
	}
	shares, err := domain.Split(in.Amount, in.Method, in.Participants)
	if err != nil {
		return nil, nil, none, err
	}
	for _, sh := range shares {
		if avail := s.availL(domain.ShareAccount(tripID, sh.UserID)); avail < sh.Amount {
			return nil, nil, none, domain.Conflict("insufficient_share", s.name(sh.UserID)+" has "+INR(avail)+" left in their share but this needs "+INR(sh.Amount),
				map[string]any{"user_id": sh.UserID, "available_paise": avail, "needed_paise": sh.Amount})
		}
	}
	check := domain.CheckBudget(in.Category, t.Budgets[in.Category], s.spentL(tripID, in.Category), in.Amount)
	if check.Warn && !in.ConfirmOverBudget {
		return nil, nil, none, domain.Conflict("budget_warning", "this payment takes the "+string(in.Category)+" budget to "+itoa(check.PercentAfter)+"%. Send it again with confirm_over_budget to pay anyway", check)
	}
	return t, shares, check, nil
}

// recordExpenseL moves the money from the shares into the payee's balance
// and writes the expense. The caller commits.
func (s *Service) recordExpenseL(t *domain.Trip, userID string, in ExpenseInput, shares []domain.Share, check domain.BudgetCheck) (*domain.Expense, error) {
	id := s.idL("exp")
	debits := map[string]Paise{}
	for _, sh := range shares {
		debits[sh.UserID] += sh.Amount
	}
	if err := s.tripToBalancesL(t, "spend", id, *in.At, debits, map[string]Paise{in.PayeeUserID: in.Amount}); err != nil {
		return nil, err
	}
	e := &domain.Expense{ID: id, TripID: t.ID, PaidBy: userID, Description: in.Description, Category: in.Category, Amount: in.Amount, Mode: in.Mode,
		Payee: in.Payee, PayeeUserID: in.PayeeUserID, Shares: shares, PlaceName: in.PlaceName, PlaceType: in.PlaceType,
		Lat: in.Lat, Lng: in.Lng, At: *in.At}
	s.expenses = append(s.expenses, e)
	s.track(e)

	how := "Paid from the " + t.Name + " wallet by " + s.name(userID)
	s.alertL(t.ID, "", "payment", firstNonEmpty(in.Description, in.Payee)+" · "+INR(in.Amount), how)
	if in.Mode == ModeMember && in.PayeeUserID != userID {
		s.alertL("", in.PayeeUserID, "money", "You got "+INR(in.Amount)+" from "+t.Name, in.Description)
	}
	if check.Warn {
		title := titleCase(string(in.Category)) + " budget at " + itoa(check.PercentAfter) + "%"
		body := INR(check.Left) + " left"
		if check.Over100 {
			body = INR(-check.Left) + " over the budget"
		}
		s.alertL(t.ID, "", "budget", title, body)
	}
	for _, sh := range shares {
		if left := s.ledger.Owed(domain.ShareAccount(t.ID, sh.UserID)); left < LowShare {
			s.alertL(t.ID, sh.UserID, "share", "Your "+t.Name+" share is low", INR(left)+" left. Put money in from the trip's Overview")
		}
	}
	return e, nil
}

// PayPersonal pays another Pointy user from your own balance. Both
// balances live in Pointy's account, so it is instant and works in India
// where PayPal cannot pay between Indian accounts.
func (s *Service) PayPersonal(userID string, in ExpenseInput) (*domain.Expense, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := in.normalise(s.now()); err != nil {
		return nil, err
	}
	payee, ok := s.users[in.PayeeUserID]
	switch {
	case !ok:
		return nil, domain.Invalid("choose who to pay")
	case in.PayeeUserID == userID:
		return nil, domain.Invalid("you cannot pay yourself")
	}
	e, err := s.transferL(userID, payee.ID, in, "")
	if err != nil {
		return nil, err
	}
	if err := s.commitL(); err != nil {
		return nil, err
	}
	return e, nil
}

// transferL moves money between two personal balances and records it. The
// caller commits.
func (s *Service) transferL(from, to string, in ExpenseInput, alertTitle string) (*domain.Expense, error) {
	// Money between balances moves now. A time from the app (meant for a
	// trip expense paid earlier) would let a payment be back-dated out of
	// a child's daily and monthly limits.
	now := s.now()
	in.At = &now
	if err := s.childSendCheckL(from, in); err != nil {
		return nil, err
	}
	if err := s.childReceiveCheckL(to, in.Amount); err != nil {
		return nil, err
	}
	if s.isChildL(from) {
		// No location is kept for a child's payments (DPDP Act s.9(3)).
		in.PlaceName, in.PlaceType, in.Lat, in.Lng = "", "", 0, 0
	}
	acc := domain.PersonalAccount(from)
	if bal := s.availL(acc); bal < in.Amount {
		return nil, domain.Conflict("insufficient_balance", "your balance is "+INR(bal)+"; add money first", map[string]any{"balance_paise": bal})
	}
	id := s.idL("exp")
	if err := s.postL(domain.Entry{ID: s.idL("je"), Kind: "transfer", Ref: id, At: *in.At, Postings: []domain.Posting{
		{Account: acc, Debit: in.Amount}, {Account: domain.PersonalAccount(to), Credit: in.Amount},
	}}); err != nil {
		return nil, err
	}
	e := &domain.Expense{ID: id, PaidBy: from, Description: in.Description, Category: in.Category, Amount: in.Amount, Mode: ModeTransfer,
		Payee: s.name(to), PayeeUserID: to, Shares: []domain.Share{{UserID: from, Amount: in.Amount}},
		PlaceName: in.PlaceName, PlaceType: in.PlaceType, Lat: in.Lat, Lng: in.Lng, At: *in.At}
	s.expenses = append(s.expenses, e)
	s.track(e)
	if alertTitle == "" {
		alertTitle = s.name(from) + " paid you " + INR(in.Amount)
	}
	s.alertL("", to, "money", alertTitle, in.Description)
	return e, nil
}

func (s *Service) Expenses(tripID, userID string) ([]*domain.Expense, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, err := s.tripL(tripID, userID); err != nil {
		return nil, err
	}
	out := []*domain.Expense{}
	for _, e := range s.expenses {
		if e.TripID == tripID {
			out = append(out, e)
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
