package app

import (
	"context"
	"testing"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
)

func money(t *testing.T, s *Service, user string) MoneyView {
	t.Helper()
	v := must[MoneyView](t)(s.Money(context.Background(), user))
	if !v.Balanced {
		t.Fatalf("business account %d does not match what is owed %d", v.BusinessAccount, v.OwedToEveryone)
	}
	return v
}

func TestWithdrawToPayPal(t *testing.T) {
	s, pp, _ := newTestService(t, nil)
	ctx := context.Background()
	a := register(t, s, "Asha", "9876543210")
	topUp(t, s, a, 2000)

	if _, err := s.Withdraw(ctx, a, domain.Rupees(500)); code(err) != "no_paypal_email" {
		t.Fatalf("no email: %v", err)
	}
	if _, err := s.SetPayPalEmail(a, "not-an-email"); code(err) != "invalid" {
		t.Fatalf("bad email: %v", err)
	}
	if me := must[Me](t)(s.SetPayPalEmail(a, " Asha@Example.com ")); me.User.PayPalEmail != "asha@example.com" {
		t.Fatalf("email %q", me.User.PayPalEmail)
	}
	if _, err := s.Withdraw(ctx, a, domain.Rupees(5000)); code(err) != "insufficient_balance" {
		t.Fatalf("too much: %v", err)
	}

	p := must[*domain.Payout](t)(s.Withdraw(ctx, a, domain.Rupees(500)))
	if p.Status != "paid" || p.Email != "asha@example.com" || p.BatchID == "" || len(pp.Payouts) != 1 {
		t.Fatalf("payout %+v %v", p, pp.Payouts)
	}
	if b := balance(s, a); b != domain.Rupees(1500) {
		t.Fatalf("balance %d", b)
	}
	v := money(t, s, a)
	// ₹2,000 came in by PayPal, ₹500 went out: ₹1,500 is left at PayPal.
	if v.BusinessAccount != domain.Rupees(1500) || v.YouPaidIn != domain.Rupees(2000) || v.YouPaidOut != domain.Rupees(500) || len(v.Payouts) != 1 {
		t.Fatalf("money view %+v", v)
	}
}

func TestWithdrawThatPayPalRefusesOrSendsBack(t *testing.T) {
	s, pp, _ := newTestService(t, nil)
	ctx := context.Background()
	a := register(t, s, "Asha", "9876543210")
	topUp(t, s, a, 1000)
	must[Me](t)(s.SetPayPalEmail(a, "asha@example.com"))

	// Refused: nothing moves, the attempt is kept as failed.
	pp.FailPayout = true
	if _, err := s.Withdraw(ctx, a, domain.Rupees(300)); code(err) != "paypal_error" {
		t.Fatalf("refused: %v", err)
	}
	if b := balance(s, a); b != domain.Rupees(1000) {
		t.Fatalf("balance after refusal %d", b)
	}
	if ps := s.Payouts(ctx, a); len(ps) != 1 || ps[0].Status != "failed" {
		t.Fatalf("payouts %+v", ps)
	}

	// Accepted but pending, then PayPal sends it back: the money returns.
	pp.FailPayout, pp.PayoutFirst = false, "PENDING"
	p := must[*domain.Payout](t)(s.Withdraw(ctx, a, domain.Rupees(300)))
	if p.Status != "pending" || balance(s, a) != domain.Rupees(700) {
		t.Fatalf("pending %+v balance %d", p, balance(s, a))
	}
	pp.PayoutLater = "RETURNED"
	ps := s.Payouts(ctx, a)
	if ps[0].Status != "returned" || balance(s, a) != domain.Rupees(1000) {
		t.Fatalf("returned %+v balance %d", ps[0], balance(s, a))
	}
	money(t, s, a)
}

func TestTripIsAWalletAndOnlyWithdrawUsesPayPal(t *testing.T) {
	s, pp, _ := newTestService(t, nil)
	ctx := context.Background()
	a := register(t, s, "Asha", "9876543210")
	d := register(t, s, "Dev", "9123456780")
	m := register(t, s, "Meera", "9988776655") // not on the trip; runs the beach shack
	trip := goa(t, s, a, d)
	for _, u := range []string{a, d} {
		topUp(t, s, u, 3000)
		must[TripView](t)(s.DepositFromBalance(trip, u, domain.Rupees(3000)))
	}

	// Paying by PayPal from a trip is gone.
	if _, err := s.AddExpense(trip, a, ExpenseInput{Description: "Dinner", Amount: 100, Mode: ModePayPal}); code(err) != "invalid" {
		t.Fatalf("paypal mode: %v", err)
	}
	// The trip pays a Pointy user: the money lands in Meera's balance.
	dinner := ExpenseInput{Description: "Dinner", Category: domain.Food, Amount: domain.Rupees(1200), Mode: ModeMember, PayeeUserID: m, ConfirmOverBudget: true}
	must[*domain.Expense](t)(s.AddExpense(trip, a, dinner))
	if balance(s, m) != domain.Rupees(1200) {
		t.Fatalf("Meera got %d", balance(s, m))
	}
	tv := must[TripView](t)(s.Trip(trip, a))
	if tv.Balance != domain.Rupees(4800) || tv.Spent != domain.Rupees(1200) || tv.MemberDetails[0].Left != domain.Rupees(2400) {
		t.Fatalf("trip %+v", tv)
	}

	// Settle: what is left goes back to both balances.
	must[Settlement](t)(s.Settle(trip, a))
	if balance(s, a) != domain.Rupees(2400) || balance(s, d) != domain.Rupees(2400) {
		t.Fatalf("balances Asha %d Dev %d", balance(s, a), balance(s, d))
	}
	if len(pp.Payouts) != 0 {
		t.Fatalf("the trip must not call PayPal: %v", pp.Payouts)
	}

	// Meera takes her money out to PayPal (and on to her bank).
	must[Me](t)(s.SetPayPalEmail(m, "meera@example.com"))
	must[*domain.Payout](t)(s.Withdraw(ctx, m, domain.Rupees(1200)))
	if balance(s, m) != 0 || len(pp.Payouts) != 1 {
		t.Fatalf("withdraw: balance %d payouts %v", balance(s, m), pp.Payouts)
	}
	if v := money(t, s, a); v.BusinessAccount != domain.Rupees(4800) {
		t.Fatalf("left at PayPal %d", v.BusinessAccount)
	}
}
