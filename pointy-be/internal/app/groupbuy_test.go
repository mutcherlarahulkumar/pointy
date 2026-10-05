package app

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/ai"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/shop"
)

// groupTrip is a trip of Asha (organiser) and Dev with ₹3,000 each in it,
// and the demo shop switched on.
func groupTrip(t *testing.T, st Store) (*Service, string, string, string, *clock) {
	t.Helper()
	s, _, c := newTestService(t, st)
	s.SetShopper(shop.Demo{})
	a := register(t, s, "Asha", "9876543210")
	d := register(t, s, "Dev", "9123456780")
	trip := goa(t, s, a, d)
	for _, u := range []string{a, d} {
		topUp(t, s, u, 3000)
		must[TripView](t)(s.DepositFromBalance(trip, u, domain.Rupees(3000)))
	}
	return s, trip, a, d, c
}

func propose(t *testing.T, s *Service, trip, user, text string) *domain.GroupBuy {
	t.Helper()
	ans := must[AgentAnswer](t)(s.ShopForTrip(context.Background(), trip, user, text))
	if len(ans.Picks) == 0 {
		t.Fatalf("no picks for %q: %+v", text, ans)
	}
	return must[*domain.GroupBuy](t)(s.ProposeGroupBuy(trip, user, ans.SearchID, ans.Picks[0].Index, ans.Picks[0].Why))
}

func TestAgentPicksAndEveryonePaysFromTheWallet(t *testing.T) {
	s, trip, a, d, _ := groupTrip(t, nil)
	ctx := context.Background()

	ans := must[AgentAnswer](t)(s.ShopForTrip(ctx, trip, a, "find a speaker for the beach under 2500"))
	if ans.Source != "rules" || !strings.Contains(ans.Query, "speaker") || ans.Budget != domain.Rupees(2500) || ans.People != 2 {
		t.Fatalf("answer %+v", ans)
	}
	// The JBL speaker costs ₹4,999: over the budget, so only the boAt one.
	if len(ans.Picks) != 1 || ans.Picks[0].Item.Brand != "boAt" || ans.Picks[0].Each != 89950 {
		t.Fatalf("picks %+v", ans.Picks)
	}
	// Someone else cannot propose from Asha's search.
	if _, err := s.ProposeGroupBuy(trip, d, ans.SearchID, 0, ""); code(err) != "search_expired" {
		t.Fatalf("other user: %v", err)
	}
	g := must[*domain.GroupBuy](t)(s.ProposeGroupBuy(trip, a, ans.SearchID, ans.Picks[0].Index, ans.Picks[0].Why))
	if g.Status != "open" || g.Amount != domain.Rupees(1799) || len(g.Shares) != 2 || g.Shares[0].Amount+g.Shares[1].Amount != g.Amount {
		t.Fatalf("group buy %+v", g)
	}

	// Asha is in from her share: that money is held and cannot be spent.
	g = must[*domain.GroupBuy](t)(s.JoinGroupBuy(ctx, g.ID, a, ViaWallet))
	held := g.Shares[0].Amount
	big := ExpenseInput{Description: "Villa", Amount: domain.Rupees(6000) - 2*held + 100, Mode: ModeReimburse, ConfirmOverBudget: true,
		Participants: []domain.SplitInput{{UserID: a, Weight: 1}, {UserID: d, Weight: 1}}}
	if _, err := s.AddExpense(trip, a, big); code(err) != "insufficient_share" {
		t.Fatalf("held money was spendable: %v", err)
	}
	if _, err := s.Settle(trip, a); code(err) != "group_buy_open" {
		t.Fatalf("settle while open: %v", err)
	}
	// Dev is in too: it is paid at once.
	g = must[*domain.GroupBuy](t)(s.JoinGroupBuy(ctx, g.ID, d, ViaWallet))
	if g.Status != "paid" || g.ExpenseID == "" {
		t.Fatalf("not paid: %+v", g)
	}
	tv := must[TripView](t)(s.Trip(trip, a))
	if tv.Spent != domain.Rupees(1799) || tv.Balance != domain.Rupees(6000-1799) {
		t.Fatalf("trip spent %d balance %d", tv.Spent, tv.Balance)
	}
	es := must[[]*domain.Expense](t)(s.Expenses(trip, d))
	if len(es) != 1 || es[0].Mode != ModeGroupBuy || es[0].Payee != "amazon.in" {
		t.Fatalf("expenses %+v", es)
	}
	checkBooks(t, s)
	// A retry after it is paid changes nothing.
	if _, err := s.JoinGroupBuy(ctx, g.ID, d, ViaWallet); code(err) != "group_buy_closed" {
		t.Fatalf("join after paid: %v", err)
	}
}

func TestPayPalShareIsHeldThenCapturedWhenEveryoneIsIn(t *testing.T) {
	s, pp, _ := newTestService(t, nil)
	s.SetShopper(shop.Demo{})
	ctx := context.Background()
	a := register(t, s, "Asha", "9876543210")
	d := register(t, s, "Dev", "9123456780")
	trip := goa(t, s, a, d)
	topUp(t, s, a, 3000)
	must[TripView](t)(s.DepositFromBalance(trip, a, domain.Rupees(3000)))
	// Dev has nothing in the trip: he says yes with PayPal.
	g := propose(t, s, trip, a, "sunscreen for goa under 800")
	if _, err := s.JoinGroupBuy(ctx, g.ID, d, ViaWallet); code(err) != "insufficient_share" {
		t.Fatalf("Dev from an empty share: %v", err)
	}
	g = must[*domain.GroupBuy](t)(s.JoinGroupBuy(ctx, g.ID, d, ViaPayPal))
	dev := shareOf(g, d)
	if dev.OrderID == "" || dev.ApproveURL == "" || dev.Status != "waiting" {
		t.Fatalf("paypal share %+v", dev)
	}
	// Approved and held, but Asha is not in yet: nothing is captured.
	g = must[*domain.GroupBuy](t)(s.AuthorizeGroupBuyOrder(ctx, dev.OrderID, d))
	if shareOf(g, d).Status != "in" || len(pp.Captures) != 0 || g.Status != "open" {
		t.Fatalf("after authorize %+v captures %v", g, pp.Captures)
	}
	if _, err := s.AuthorizeGroupBuyOrder(ctx, dev.OrderID, a); code(err) != "not_found" {
		t.Fatalf("someone else's approval: %v", err)
	}
	g = must[*domain.GroupBuy](t)(s.JoinGroupBuy(ctx, g.ID, a, ViaWallet))
	if g.Status != "paid" || len(pp.Captures) != 1 {
		t.Fatalf("paid %+v captures %v", g, pp.Captures)
	}
	// Dev's PayPal money went into his share and straight out to the shop.
	tv := must[TripView](t)(s.Trip(trip, a))
	if tv.Balance != domain.Rupees(3000)-shareOf(g, a).Amount || tv.Spent != g.Amount {
		t.Fatalf("trip %+v", tv)
	}
	checkBooks(t, s)
}

func TestOneNoCallsItOffAndLetsEveryHoldGo(t *testing.T) {
	s, pp, _ := newTestService(t, nil)
	s.SetShopper(shop.Demo{})
	ctx := context.Background()
	a := register(t, s, "Asha", "9876543210")
	d := register(t, s, "Dev", "9123456780")
	trip := goa(t, s, a, d)
	topUp(t, s, a, 3000)
	must[TripView](t)(s.DepositFromBalance(trip, a, domain.Rupees(3000)))
	g := propose(t, s, trip, a, "beach towels")
	g = must[*domain.GroupBuy](t)(s.JoinGroupBuy(ctx, g.ID, d, ViaPayPal))
	must[*domain.GroupBuy](t)(s.AuthorizeGroupBuyOrder(ctx, shareOf(g, d).OrderID, d))
	g = must[*domain.GroupBuy](t)(s.JoinGroupBuy(ctx, g.ID, a, ViaPayPal))

	g = must[*domain.GroupBuy](t)(s.DeclineGroupBuy(ctx, g.ID, a))
	if g.Status != "cancelled" || len(pp.Voids) != 1 || len(pp.Captures) != 0 {
		t.Fatalf("declined %+v voids %v", g, pp.Voids)
	}
	// Asha approving her PayPal page now is too late: the hold is let go.
	if _, err := s.AuthorizeGroupBuyOrder(ctx, shareOf(g, a).OrderID, a); code(err) != "group_buy_closed" || len(pp.Voids) != 2 {
		t.Fatalf("late approval: %v voids %v", err, pp.Voids)
	}
	if tv := must[TripView](t)(s.Trip(trip, a)); tv.Spent != 0 || tv.Balance != domain.Rupees(3000) {
		t.Fatalf("trip %+v", tv)
	}
	must[Settlement](t)(s.Settle(trip, a))
	checkBooks(t, s)
}

func TestFailedCaptureBuysNothingAndKeepsTheMoney(t *testing.T) {
	s, pp, _ := newTestService(t, nil)
	s.SetShopper(shop.Demo{})
	ctx := context.Background()
	a := register(t, s, "Asha", "9876543210")
	d := register(t, s, "Dev", "9123456780")
	trip := goa(t, s, a, d)
	g := propose(t, s, trip, a, "playing cards uno")
	for _, u := range []string{d, a} {
		g = must[*domain.GroupBuy](t)(s.JoinGroupBuy(ctx, g.ID, u, ViaPayPal))
		if u == a {
			pp.FailCaptureAuth = true
		}
		g, _ = s.AuthorizeGroupBuyOrder(ctx, shareOf(g, u).OrderID, u)
	}
	if g.Status != "failed" || len(pp.Captures) != 0 || len(pp.Voids) != 2 {
		t.Fatalf("failed %+v captures %v voids %v", g, pp.Captures, pp.Voids)
	}
	if tv := must[TripView](t)(s.Trip(trip, a)); tv.Spent != 0 || tv.Balance != 0 {
		t.Fatalf("trip %+v", tv)
	}
	checkBooks(t, s)
}

func TestGroupBuyExpiresAndHoldsSurviveARestart(t *testing.T) {
	st := &memStore{}
	s, trip, a, _, c := groupTrip(t, st)
	ctx := context.Background()
	g := propose(t, s, trip, a, "first aid kit")
	must[*domain.GroupBuy](t)(s.JoinGroupBuy(ctx, g.ID, a, ViaWallet))

	// After a restart Asha's part is still held.
	s2, _, c2 := newTestService(t, st)
	acc := domain.ShareAccount(trip, a)
	s2.mu.Lock()
	avail := s2.availL(acc)
	s2.mu.Unlock()
	if avail != domain.Rupees(3000)-g.Shares[0].Amount {
		t.Fatalf("held after restart: avail %d", avail)
	}
	// Two days later nobody else said yes: it expires and the hold goes.
	c2.t = c.t.Add(groupBuyWindow + time.Minute)
	gs := must[[]*domain.GroupBuy](t)(s2.GroupBuys(ctx, trip, a))
	if gs[0].Status != "expired" {
		t.Fatalf("status %s", gs[0].Status)
	}
	s2.mu.Lock()
	avail = s2.availL(acc)
	s2.mu.Unlock()
	if avail != domain.Rupees(3000) {
		t.Fatalf("hold not released: %d", avail)
	}
}

func TestAgentUsesTheModelsPicksOnlyWhenValid(t *testing.T) {
	s, trip, a, _, _ := groupTrip(t, nil)
	f := &fakeAI{picks: ai.Picks{Reply: "Two good options.", Picks: []ai.Pick{{Index: 9, Why: "made up"}, {Index: 1, Why: "Cheaper, and enough for two."}, {Index: 1, Why: "again"}}}}
	s.SetAssistant(f)
	ans := must[AgentAnswer](t)(s.ShopForTrip(context.Background(), trip, a, "sunscreen"))
	if ans.Source != "ai" || len(ans.Picks) != 1 || ans.Picks[0].Index != 1 || ans.Reply != "Two good options." {
		t.Fatalf("answer %+v", ans)
	}
	if f.picksIn.People != 2 || len(f.picksIn.Candidates) == 0 || f.picksIn.Candidates[0].Price == "" {
		t.Fatalf("model input %+v", f.picksIn)
	}
	// A model that answers nothing usable falls back to rules.
	f.picks = ai.Picks{Picks: []ai.Pick{{Index: -1, Why: "x"}}}
	if ans := must[AgentAnswer](t)(s.ShopForTrip(context.Background(), trip, a, "sunscreen")); ans.Source != "rules" || len(ans.Picks) == 0 {
		t.Fatalf("fallback %+v", ans)
	}
}
