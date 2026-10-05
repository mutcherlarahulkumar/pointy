package app

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/paypal"
)

// clock is a settable time for tests: Tue 13 Oct 2026, 8:42 pm IST.
type clock struct{ t time.Time }

func (c *clock) now() time.Time { return c.t }

func newTestService(t *testing.T, st Store) (*Service, *paypal.Mock, *clock) {
	t.Helper()
	pp := &paypal.Mock{}
	c := &clock{time.Date(2026, 10, 13, 20, 42, 0, 0, IST)}
	s := New(pp, c.now, st)
	if err := s.Load(context.Background()); err != nil {
		t.Fatal(err)
	}
	return s, pp, c
}

func code(err error) string {
	var de *domain.Error
	if errors.As(err, &de) {
		return de.Code
	}
	return ""
}

func must[T any](t *testing.T) func(T, error) T {
	return func(v T, err error) T {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
		return v
	}
}

func register(t *testing.T, s *Service, name, phone string) string {
	t.Helper()
	r, err := s.Register(RegisterInput{Name: name, Phone: phone, PIN: "246810"})
	if err != nil {
		t.Fatal(err)
	}
	return r.User.ID
}

// topUp adds money to a balance through the PayPal checkout path.
func topUp(t *testing.T, s *Service, user string, rupees int64) {
	t.Helper()
	d, err := s.StartTopUp(context.Background(), user, domain.Rupees(rupees))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.CaptureDeposit(context.Background(), d.OrderID); err != nil {
		t.Fatal(err)
	}
}

func balance(s *Service, user string) Paise {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.ledger.Owed(domain.PersonalAccount(user))
}

// checkBooks: money held for personal balances equals the sum of all
// balances, and each trip's pool equals what its members are owed.
func checkBooks(t *testing.T, s *Service) {
	t.Helper()
	s.mu.Lock()
	defer s.mu.Unlock()
	var owed Paise
	for id := range s.users {
		owed += s.ledger.Owed(domain.PersonalAccount(id))
	}
	if held := s.ledger.Held(domain.PersonalClearing); held != owed {
		t.Fatalf("personal pool holds %d but balances add up to %d", held, owed)
	}
	for _, tr := range s.trips {
		var shares Paise
		for _, m := range tr.Members {
			shares += s.ledger.Owed(domain.ShareAccount(tr.ID, m))
		}
		if held := s.ledger.Held(domain.ClearingAccount(tr.ID)); held != shares {
			t.Fatalf("trip %s holds %d but shares add up to %d", tr.Name, held, shares)
		}
	}
}

func TestPhoneAndPINRules(t *testing.T) {
	for in, want := range map[string]string{"+91 98765 43210": "9876543210", "098765-43210": "9876543210", "9876543210": "9876543210"} {
		if got, err := NormalizePhone(in); err != nil || got != want {
			t.Fatalf("%q -> %q, %v", in, got, err)
		}
	}
	for _, bad := range []string{"12345", "5876543210", "98765432101"} {
		if _, err := NormalizePhone(bad); err == nil {
			t.Fatalf("%q should be rejected", bad)
		}
	}
	s, _, _ := newTestService(t, nil)
	for _, pin := range []string{"12345", "abcdef", "111111", "123456", "654321"} {
		if _, err := s.Register(RegisterInput{Name: "Asha", Phone: "9876543210", PIN: pin}); code(err) != "invalid" {
			t.Fatalf("PIN %q: %v", pin, err)
		}
	}
}

func TestRegisterLoginAndLockout(t *testing.T) {
	s, _, c := newTestService(t, nil)
	reg := must[AuthResult](t)(s.Register(RegisterInput{Name: "  Asha   Rao ", Phone: "+91 98765 43210", PIN: "246810"}))
	if reg.User.Name != "Asha Rao" || reg.User.Phone != "9876543210" {
		t.Fatalf("got %+v", reg.User)
	}
	if id, ok := s.UserForToken(reg.Token); !ok || id != reg.User.ID {
		t.Fatal("token does not resolve")
	}
	if _, err := s.Register(RegisterInput{Name: "Other", Phone: "9876543210", PIN: "246810"}); code(err) != "phone_taken" {
		t.Fatalf("duplicate phone: %v", err)
	}
	pc := must[PhoneCheck](t)(s.CheckPhone("9876543210"))
	if !pc.Exists || pc.FirstName != "Asha" {
		t.Fatalf("check phone %+v", pc)
	}
	for i := 0; i < maxFailedPINs; i++ {
		if _, err := s.Login("9876543210", "000001"); code(err) != "wrong_pin" {
			t.Fatalf("attempt %d: %v", i, err)
		}
	}
	if _, err := s.Login("9876543210", "246810"); code(err) != "too_many_attempts" {
		t.Fatalf("should be locked: %v", err)
	}
	c.t = c.t.Add(loginWindow + time.Minute)
	log := must[AuthResult](t)(s.Login("9876543210", "246810"))
	if err := s.Logout(log.Token); err != nil {
		t.Fatal(err)
	}
	if _, ok := s.UserForToken(log.Token); ok {
		t.Fatal("token still works after sign out")
	}
}

func TestTopUpCapturesOnce(t *testing.T) {
	s, _, _ := newTestService(t, nil)
	a := register(t, s, "Asha", "9876543210")
	d := must[*domain.Deposit](t)(s.StartTopUp(context.Background(), a, domain.Rupees(500)))
	for i := 0; i < 3; i++ {
		if _, err := s.CaptureDeposit(context.Background(), d.OrderID); err != nil {
			t.Fatal(err)
		}
	}
	if b := balance(s, a); b != domain.Rupees(500) {
		t.Fatalf("balance %d", b)
	}
	checkBooks(t, s)
}

func TestCaptureNotApprovedLeavesNothing(t *testing.T) {
	s, pp, _ := newTestService(t, nil)
	a := register(t, s, "Asha", "9876543210")
	d := must[*domain.Deposit](t)(s.StartTopUp(context.Background(), a, domain.Rupees(500)))
	pp.FailCapture = true
	if _, err := s.CaptureDeposit(context.Background(), d.OrderID); code(err) != "not_approved" {
		t.Fatalf("got %v", err)
	}
	if balance(s, a) != 0 {
		t.Fatal("money credited without capture")
	}
	pp.FailCapture = false
	must[*domain.Deposit](t)(s.CaptureDeposit(context.Background(), d.OrderID))
	if balance(s, a) != domain.Rupees(500) {
		t.Fatal("retry after approval should credit")
	}
}

func TestPayFriendAndRequests(t *testing.T) {
	s, _, _ := newTestService(t, nil)
	a := register(t, s, "Asha", "9876543210")
	d := register(t, s, "Dev", "9123456780")
	topUp(t, s, a, 1000)

	if _, err := s.PayPersonal(a, ExpenseInput{Description: "Chai", Amount: domain.Rupees(5000), PayeeUserID: d}); code(err) != "insufficient_balance" {
		t.Fatalf("overspend: %v", err)
	}
	must[*domain.Expense](t)(s.PayPersonal(a, ExpenseInput{Description: "Chai", Amount: domain.Rupees(120), PayeeUserID: d}))
	if balance(s, a) != domain.Rupees(880) || balance(s, d) != domain.Rupees(120) {
		t.Fatalf("balances %d %d", balance(s, a), balance(s, d))
	}

	// Dev asks Asha for ₹300; Asha pays it.
	r := must[MoneyRequestView](t)(s.RequestMoney(d, MoneyRequestInput{PayerID: a, Amount: domain.Rupees(300), Note: "Movie"}))
	if me := must[Me](t)(s.Me(a)); me.OpenRequests != 1 {
		t.Fatalf("open requests %d", me.OpenRequests)
	}
	if _, err := s.PayMoneyRequest(d, r.ID); code(err) != "not_found" {
		t.Fatal("the requester cannot pay their own request")
	}
	must[MoneyRequestView](t)(s.PayMoneyRequest(a, r.ID))
	if _, err := s.PayMoneyRequest(a, r.ID); code(err) != "already_closed" {
		t.Fatal("paid twice")
	}
	if balance(s, a) != domain.Rupees(580) || balance(s, d) != domain.Rupees(420) {
		t.Fatalf("balances %d %d", balance(s, a), balance(s, d))
	}

	// A declined request moves nothing.
	r2 := must[MoneyRequestView](t)(s.RequestMoney(a, MoneyRequestInput{PayerID: d, Amount: domain.Rupees(50)}))
	if v := must[MoneyRequestView](t)(s.DeclineMoneyRequest(d, r2.ID)); v.Status != "declined" {
		t.Fatal(v.Status)
	}
	if len(s.Contacts(a)) != 1 || len(s.History(d)) == 0 {
		t.Fatal("contacts or history missing")
	}
	checkBooks(t, s)
}

func TestSplitBillSendsShares(t *testing.T) {
	s, _, _ := newTestService(t, nil)
	a := register(t, s, "Asha", "9876543210")
	d := register(t, s, "Dev", "9123456780")
	m := register(t, s, "Meera", "9988776655")
	res := must[SplitBillResult](t)(s.SplitBill(a, SplitBillInput{Description: "Dinner", Amount: 100000,
		Participants: []domain.SplitInput{{UserID: a}, {UserID: d}, {UserID: m}}}))
	if len(res.Requests) != 2 || res.Requests[0].Amount+res.Requests[1].Amount != 100000-res.Shares[0].Amount {
		t.Fatalf("requests %+v shares %+v", res.Requests, res.Shares)
	}
}

func goa(t *testing.T, s *Service, org string, members ...string) string {
	t.Helper()
	tv := must[TripView](t)(s.CreateTrip(org, CreateTripInput{Name: "Goa trip", Place: "Goa",
		Start: time.Date(2026, 10, 12, 0, 0, 0, 0, IST), End: time.Date(2026, 10, 16, 0, 0, 0, 0, IST),
		Members: members, DepositTarget: domain.Rupees(3000), Budgets: map[domain.Category]Paise{domain.Food: domain.Rupees(2000)}}))
	return tv.ID
}

func TestTripFromDepositsToSettleUp(t *testing.T) {
	s, _, _ := newTestService(t, nil)
	a := register(t, s, "Asha", "9876543210")
	d := register(t, s, "Dev", "9123456780")
	trip := goa(t, s, a, d)
	if me := must[Me](t)(s.Me(d)); me.ActiveTripID != trip {
		t.Fatal("trip should be active for Dev")
	}

	// Asha pays her deposit from her balance; Dev with PayPal.
	topUp(t, s, a, 5000)
	must[TripView](t)(s.DepositFromBalance(trip, a, domain.Rupees(3000)))
	dep := must[*domain.Deposit](t)(s.StartDeposit(context.Background(), trip, d, domain.Rupees(3000)))
	must[*domain.Deposit](t)(s.CaptureDeposit(context.Background(), dep.OrderID))
	v := must[TripView](t)(s.Trip(trip, a))
	if v.Balance != domain.Rupees(6000) || balance(s, a) != domain.Rupees(2000) {
		t.Fatalf("wallet %d balance %d", v.Balance, balance(s, a))
	}
	checkBooks(t, s)

	// Dev paid the shack ₹1,840 by UPI: the wallet pays him back, split 2 ways.
	dinner := ExpenseInput{Description: "Dinner", Category: domain.Food, Amount: domain.Rupees(1840), Payee: "Beach shack", Mode: ModeReimburse}
	if _, err := s.AddExpense(trip, d, dinner); code(err) != "budget_warning" {
		t.Fatalf("expected a budget warning, got %v", err)
	}
	dinner.ConfirmOverBudget = true
	e := must[*domain.Expense](t)(s.AddExpense(trip, d, dinner))
	if e.PayeeUserID != d || balance(s, d) != domain.Rupees(1840) {
		t.Fatalf("Dev should be paid back: %d", balance(s, d))
	}
	v = must[TripView](t)(s.Trip(trip, a))
	if v.Spent != domain.Rupees(1840) || v.MemberDetails[0].Left != domain.Rupees(2080) {
		t.Fatalf("spent %d, Asha left %d", v.Spent, v.MemberDetails[0].Left)
	}
	checkBooks(t, s)

	// Too big for one share.
	big := ExpenseInput{Description: "Villa", Category: domain.Stay, Amount: domain.Rupees(5000), Mode: ModeMember, PayeeUserID: a}
	if _, err := s.AddExpense(trip, a, big); code(err) != "insufficient_share" {
		t.Fatalf("got %v", err)
	}

	// Only the organiser settles; everything left goes back to balances.
	if _, err := s.Settle(trip, d); code(err) != "forbidden" {
		t.Fatal("Dev is not the organiser")
	}
	st := must[Settlement](t)(s.Settle(trip, a))
	if st.Refund != domain.Rupees(4160) || balance(s, a) != domain.Rupees(4080) || balance(s, d) != domain.Rupees(3920) {
		t.Fatalf("refund %d, balances %d %d", st.Refund, balance(s, a), balance(s, d))
	}
	if _, err := s.AddExpense(trip, a, dinner); code(err) != "trip_closed" {
		t.Fatal("a settled trip cannot pay")
	}
	checkBooks(t, s)
}

func TestAssistantRequestsArePaidInApp(t *testing.T) {
	s, _, _ := newTestService(t, nil)
	a := register(t, s, "Asha", "9876543210")
	d := register(t, s, "Dev", "9123456780")
	trip := goa(t, s, a, d)
	if _, err := s.DraftPlan(trip, d, "Collect ₹3,000"); code(err) != "forbidden" {
		t.Fatal("only the organiser drafts")
	}
	p := must[*domain.Plan](t)(s.DraftPlan(trip, a, "Collect ₹3,000 from everyone by 20 Oct"))
	if p.PerPerson != domain.Rupees(3000) || p.Due.Day() != 20 || len(s.requests) != 0 {
		t.Fatalf("plan %+v; nothing may be sent before confirm", p)
	}
	made := must[[]*domain.DepositRequest](t)(s.ConfirmPlan(trip, p.ID, a))
	if len(made) != 1 || made[0].UserID != d {
		t.Fatalf("made %+v", made)
	}
	if _, err := s.PayRequest(made[0].ID, d); code(err) != "insufficient_balance" {
		t.Fatalf("got %v", err)
	}
	must[RequestView](t)(s.Remind(made[0].ID, a))
	must[RequestView](t)(s.Remind(made[0].ID, a))
	if _, err := s.Remind(made[0].ID, a); code(err) != "reminder_cap" {
		t.Fatal("third reminder in a day")
	}
	topUp(t, s, d, 3000)
	r := must[RequestView](t)(s.PayRequest(made[0].ID, d))
	if r.Status != "paid" || r.PaidVia != "balance" {
		t.Fatalf("request %+v", r.DepositRequest)
	}
	checkBooks(t, s)
}

func TestPayPalDepositClosesRequest(t *testing.T) {
	s, _, _ := newTestService(t, nil)
	a := register(t, s, "Asha", "9876543210")
	d := register(t, s, "Dev", "9123456780")
	trip := goa(t, s, a, d)
	p := must[*domain.Plan](t)(s.DraftPlan(trip, a, "Collect ₹3,000"))
	made := must[[]*domain.DepositRequest](t)(s.ConfirmPlan(trip, p.ID, a))
	dep := must[*domain.Deposit](t)(s.StartDeposit(context.Background(), trip, d, domain.Rupees(3000)))
	must[*domain.Deposit](t)(s.CaptureDeposit(context.Background(), dep.OrderID))
	if made[0].Status != "paid" || made[0].PaidVia != "paypal" {
		t.Fatalf("request %+v", made[0])
	}
}

// memStore records saves and reloads them, standing in for Postgres to prove
// the service rebuilds the same state after a restart.
type memStore struct{ saved []any }

func (m *memStore) Save(_ context.Context, items []any) error { m.saved = append(m.saved, items...); return nil }
func (m *memStore) Load(context.Context) (*Snapshot, error) {
	s := &Snapshot{}
	seen := map[any]bool{}
	for i := len(m.saved) - 1; i >= 0; i-- { // keep the latest copy of each object
		it := m.saved[i]
		key := it
		switch v := it.(type) {
		case domain.Entry:
			key = "entry:" + v.ID
		case domain.Session:
			key = "session:" + v.TokenHash
		case domain.SessionEnd:
			key = "end:" + v.TokenHash
		}
		if seen[key] {
			continue
		}
		seen[key] = true
		switch v := it.(type) {
		case *domain.User:
			s.Users = append([]*domain.User{v}, s.Users...)
		case domain.Session:
			s.Sessions = append(s.Sessions, v)
		case *domain.Trip:
			s.Trips = append([]*domain.Trip{v}, s.Trips...)
		case domain.Entry:
			s.Entries = append([]domain.Entry{v}, s.Entries...)
		case *domain.Deposit:
			s.Deposits = append(s.Deposits, v)
		case *domain.Expense:
			s.Expenses = append([]*domain.Expense{v}, s.Expenses...)
		case *domain.DepositRequest:
			s.Requests = append(s.Requests, v)
		case *domain.Plan:
			s.Plans = append(s.Plans, v)
		case *domain.Alert:
			s.Alerts = append([]*domain.Alert{v}, s.Alerts...)
		case *domain.MoneyRequest:
			s.MoneyRequests = append(s.MoneyRequests, v)
		}
	}
	return s, nil
}

func TestStateSurvivesRestart(t *testing.T) {
	st := &memStore{}
	s, _, _ := newTestService(t, st)
	a := register(t, s, "Asha", "9876543210")
	d := register(t, s, "Dev", "9123456780")
	topUp(t, s, a, 1000)
	must[*domain.Expense](t)(s.PayPersonal(a, ExpenseInput{Description: "Chai", Amount: domain.Rupees(100), PayeeUserID: d}))

	s2, _, _ := newTestService(t, st)
	if balance(s2, a) != domain.Rupees(900) || balance(s2, d) != domain.Rupees(100) {
		t.Fatalf("after restart: %d %d", balance(s2, a), balance(s2, d))
	}
	if _, err := s2.Login("9123456780", "246810"); err != nil {
		t.Fatal(err)
	}
	checkBooks(t, s2)
}
