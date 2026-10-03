package app

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/paypal"
)

const trip = "t_goa"

func demo(t *testing.T) (*Service, *paypal.Mock) {
	t.Helper()
	pp := &paypal.Mock{}
	s := New(pp, func() time.Time { return DemoNow })
	SeedDemo(s)
	return s, pp
}

func code(err error) string {
	var de *domain.Error
	if errors.As(err, &de) {
		return de.Code
	}
	return ""
}

// The books must always agree: money held at PayPal for the trip equals the
// sum of what is owed to the members.
func checkBooks(t *testing.T, s *Service) {
	t.Helper()
	v, err := s.Trip(trip, "u_you")
	if err != nil {
		t.Fatal(err)
	}
	var owed Paise
	for _, m := range v.MemberDetails {
		owed += m.Left
	}
	if owed != v.Balance {
		t.Fatalf("books do not balance: held %d, owed to members %d", v.Balance, owed)
	}
}

func dinner(confirm bool) ExpenseInput {
	return ExpenseInput{Description: "Dinner", Category: domain.Food, Amount: domain.Rupees(1840), Payee: "Beach shack, Baga",
		PayeeEmail: "shack@example.com", PlaceName: "Baga", PlaceType: "restaurant", ConfirmOverBudget: confirm}
}

func TestSeedMatchesTheDesigns(t *testing.T) {
	s, _ := demo(t)
	v, _ := s.Trip(trip, "u_you")
	if v.Balance != domain.Rupees(12192) || v.Deposited != domain.Rupees(21000) || v.Spent != domain.Rupees(8808) {
		t.Fatalf("balance %d deposited %d spent %d", v.Balance, v.Deposited, v.Spent)
	}
	if v.Day != 2 || v.Days != 5 {
		t.Fatalf("day %d of %d", v.Day, v.Days)
	}
	if you := v.MemberDetails[0]; you.Left != domain.Rupees(798) || you.Used != domain.Rupees(2202) {
		t.Fatalf("your share: %+v", you)
	}
	me, _ := s.Me("u_you")
	if me.PersonalBalance != domain.Rupees(8430) || me.ActiveTripID != trip {
		t.Fatalf("me: %+v", me)
	}
	checkBooks(t, s)
}

func TestBudgetWarningThenPay(t *testing.T) {
	s, pp := demo(t)
	ctx := context.Background()
	_, err := s.AddExpense(ctx, trip, "u_you", dinner(false))
	var de *domain.Error
	if !errors.As(err, &de) || de.Code != "budget_warning" {
		t.Fatalf("expected a budget warning, got %v", err)
	}
	if c := de.Details.(domain.BudgetCheck); c.PercentBefore != 48 || c.PercentAfter != 85 || c.Left != domain.Rupees(752) || !c.Crosses80 {
		t.Fatalf("check: %+v", c)
	}
	if len(pp.Payouts) != 0 {
		t.Fatal("money moved before the warning was confirmed")
	}
	e, err := s.AddExpense(ctx, trip, "u_you", dinner(true))
	if err != nil {
		t.Fatal(err)
	}
	if len(e.Shares) != 4 || e.Shares[0].Amount != domain.Rupees(460) {
		t.Fatalf("shares: %+v", e.Shares)
	}
	v, _ := s.Trip(trip, "u_you")
	if v.Balance != domain.Rupees(10352) || v.MemberDetails[0].Left != domain.Rupees(338) {
		t.Fatalf("after dinner: balance %d, your share %d", v.Balance, v.MemberDetails[0].Left)
	}
	if len(pp.Payouts) != 1 || pp.Payouts[0][0].ReceiverEmail != "shack@example.com" {
		t.Fatalf("payouts: %+v", pp.Payouts)
	}
	kinds := map[string]bool{}
	for _, a := range s.Alerts("u_you") {
		kinds[a.Title] = true
	}
	if !kinds["Food budget at 85%"] || !kinds["Your trip share is low"] {
		t.Fatalf("alerts: %v", kinds)
	}
	checkBooks(t, s)
}

func TestCannotOverspendAShare(t *testing.T) {
	s, pp := demo(t)
	in := ExpenseInput{Description: "Boat hire", Category: domain.Other, Amount: domain.Rupees(4000), PayeeEmail: "boat@example.com"}
	if _, err := s.AddExpense(context.Background(), trip, "u_you", in); code(err) != "insufficient_share" {
		t.Fatalf("expected insufficient_share, got %v", err) // your part would be ₹1,000 against ₹798
	}
	if len(pp.Payouts) != 0 {
		t.Fatal("a payout was sent for a payment that should have been refused")
	}
	checkBooks(t, s)
}

func TestFailedPayoutLeavesNoTrace(t *testing.T) {
	s, pp := demo(t)
	pp.FailPayouts = true
	if _, err := s.AddExpense(context.Background(), trip, "u_you", dinner(true)); code(err) != "paypal_error" {
		t.Fatalf("expected paypal_error, got %v", err)
	}
	pp.FailPayouts = false
	v, _ := s.Trip(trip, "u_you")
	if v.Balance != domain.Rupees(12192) {
		t.Fatalf("balance changed after a failed payout: %d", v.Balance)
	}
	if _, err := s.AddExpense(context.Background(), trip, "u_you", dinner(true)); err != nil {
		t.Fatalf("the hold was not released: %v", err)
	}
	checkBooks(t, s)
}

func TestDepositIsCreditedOnce(t *testing.T) {
	s, _ := demo(t)
	ctx := context.Background()
	d, err := s.StartDeposit(ctx, trip, "u_you", domain.Rupees(3000))
	if err != nil {
		t.Fatal(err)
	}
	if v, _ := s.Trip(trip, "u_you"); v.Balance != domain.Rupees(12192) {
		t.Fatal("the wallet changed before the capture")
	}
	for i := 0; i < 2; i++ {
		if _, err := s.CaptureDeposit(ctx, d.OrderID); err != nil {
			t.Fatal(err)
		}
	}
	v, _ := s.Trip(trip, "u_you")
	if v.Balance != domain.Rupees(15192) || v.MemberDetails[0].Left != domain.Rupees(3798) {
		t.Fatalf("after deposit: balance %d, your share %d", v.Balance, v.MemberDetails[0].Left)
	}
	checkBooks(t, s)
}

func TestSplit(t *testing.T) {
	people := []domain.SplitInput{{UserID: "a", Weight: 2}, {UserID: "b", Weight: 1}, {UserID: "c", Weight: 1}}
	eq, _ := domain.Split(1000, domain.SplitEqual, people) // ₹10.00 between three
	if eq[0].Amount != 334 || eq[1].Amount != 333 || eq[2].Amount != 333 {
		t.Fatalf("equal: %+v", eq)
	}
	sh, _ := domain.Split(1000, domain.SplitShares, people)
	if sh[0].Amount != 500 || sh[1].Amount != 250 || sh[2].Amount != 250 {
		t.Fatalf("shares: %+v", sh)
	}
	if _, err := domain.Split(1000, domain.SplitExact, []domain.SplitInput{{UserID: "a", Exact: 600}, {UserID: "b", Exact: 300}}); err == nil {
		t.Fatal("exact amounts that do not add up were accepted")
	}
}

func TestInsightsAndSuggestion(t *testing.T) {
	s, _ := demo(t)
	in, _ := s.Insights(trip, "u_you")
	if in.PerPerson != domain.Rupees(2202) || in.ForecastLeft != domain.Rupees(4380) {
		t.Fatalf("per person %d, forecast %d", in.PerPerson, in.ForecastLeft)
	}
	if in.ByCategory[0].Key != "stay" || in.ByCategory[0].Percent != 41 || in.ByTimeOfDay[1].Amount != domain.Rupees(5688) {
		t.Fatalf("category %+v, time %+v", in.ByCategory, in.ByTimeOfDay)
	}
	sg := s.Suggest("u_you", SuggestInput{PlaceType: "restaurant"})
	if sg.Wallet != "trip" || sg.Category != domain.Food || len(sg.Participants) != 4 {
		t.Fatalf("suggestion: %+v", sg)
	}
	if sg := s.Suggest("u_you", SuggestInput{PlaceType: "pharmacy"}); sg.Wallet != "personal" {
		t.Fatalf("a pharmacy should stay personal: %+v", sg)
	}
}

func TestAssistantWaitsForConfirmation(t *testing.T) {
	s, _ := demo(t)
	ctx := context.Background()
	// A fresh trip where nobody has paid yet.
	tv, err := s.CreateTrip("u_you", CreateTripInput{Name: "Hampi", Start: DemoNow.AddDate(0, 1, 0), End: DemoNow.AddDate(0, 1, 2), Members: []string{"u_asha", "u_dev"}, DepositTarget: domain.Rupees(2000)})
	if err != nil {
		t.Fatal(err)
	}
	p, err := s.DraftPlan(tv.ID, "u_you", "Collect ₹2,500 from everyone by 9 Nov")
	if err != nil {
		t.Fatal(err)
	}
	if p.PerPerson != domain.Rupees(2500) || p.Due.Day() != 9 || p.Due.Month() != time.November || p.Total != domain.Rupees(7500) {
		t.Fatalf("plan: %+v", p)
	}
	if rs, _ := s.Requests(tv.ID, "u_you"); len(rs) != 0 {
		t.Fatal("requests were sent before the plan was confirmed")
	}
	rs, err := s.ConfirmPlan(ctx, tv.ID, p.ID, "u_you")
	if err != nil || len(rs) != 2 { // the organiser pays in the app, the other two get requests
		t.Fatalf("confirm: %v, %d requests", err, len(rs))
	}
	if _, err := s.ConfirmPlan(ctx, tv.ID, p.ID, "u_you"); code(err) != "plan_already_confirmed" {
		t.Fatalf("second confirm: %v", err)
	}
	for i := 0; i < 2; i++ {
		if _, err := s.Remind(ctx, rs[0].ID, "u_you"); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := s.Remind(ctx, rs[0].ID, "u_you"); code(err) != "reminder_cap" {
		t.Fatalf("third reminder in a day: %v", err)
	}
	for i := 0; i < 2; i++ { // a repeated webhook must not credit twice
		if err := s.HandleWebhook(ctx, "INVOICING.INVOICE.PAID", rs[0].InvoiceID); err != nil {
			t.Fatal(err)
		}
	}
	if v, _ := s.Trip(tv.ID, "u_you"); v.Balance != domain.Rupees(2500) {
		t.Fatalf("balance after one paid request: %d", v.Balance)
	}
}

func TestSettleRefundsEveryoneAndCloses(t *testing.T) {
	s, pp := demo(t)
	ctx := context.Background()
	if _, err := s.Settle(ctx, trip, "u_asha"); code(err) != "forbidden" {
		t.Fatalf("a member who is not the organiser settled the trip: %v", err)
	}
	out, err := s.Settle(ctx, trip, "u_you")
	if err != nil {
		t.Fatal(err)
	}
	if out.Refund != domain.Rupees(12192) || out.Lines[0].Refund != domain.Rupees(798) || len(pp.Payouts[0]) != 4 {
		t.Fatalf("settlement: %+v", out)
	}
	v, _ := s.Trip(trip, "u_you")
	if v.Balance != 0 || v.Status != domain.TripSettled {
		t.Fatalf("after settle: balance %d, status %s", v.Balance, v.Status)
	}
	if _, err := s.AddExpense(ctx, trip, "u_you", dinner(true)); code(err) != "trip_closed" {
		t.Fatalf("a settled trip accepted a payment: %v", err)
	}
	checkBooks(t, s)
}
