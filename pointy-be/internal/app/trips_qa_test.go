package app

import (
	"context"
	"testing"
	"time"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/paypal"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/shop"
)

// Joining after the 48 hours are up must not buy anything, even when
// nobody listed the purchases in between (expiry used to happen only on a
// list).
func TestQAJoinAfterDeadlineDoesNotBuy(t *testing.T) {
	s, trip, a, d, c := groupTrip(t, nil)
	ctx := context.Background()
	g := propose(t, s, trip, a, "first aid kit")
	must[*domain.GroupBuy](t)(s.JoinGroupBuy(ctx, g.ID, a, ViaWallet))
	c.t = g.Deadline // "say yes before <deadline>": at the deadline it is too late
	if _, err := s.JoinGroupBuy(ctx, g.ID, d, ViaWallet); code(err) != "group_buy_closed" {
		t.Fatalf("late join: %v", err)
	}
	if g.Status != "expired" {
		t.Fatalf("status %s", g.Status)
	}
	if tv := must[TripView](t)(s.Trip(trip, a)); tv.Spent != 0 {
		t.Fatalf("bought after the deadline: %+v", tv)
	}
	checkBooks(t, s)
}

// A wallet hold of an expired purchase must not block spending or settling.
func TestQAExpiredHoldDoesNotBlockSettle(t *testing.T) {
	s, trip, a, _, c := groupTrip(t, nil)
	ctx := context.Background()
	g := propose(t, s, trip, a, "first aid kit")
	must[*domain.GroupBuy](t)(s.JoinGroupBuy(ctx, g.ID, a, ViaWallet))
	c.t = g.Deadline.Add(1)
	must[Settlement](t)(s.Settle(trip, a))
	if g.Status != "expired" {
		t.Fatalf("status %s", g.Status)
	}
	checkBooks(t, s)
}

// A PayPal approval that arrives after the deadline is voided, not counted.
func TestQAAuthorizeAfterDeadlineIsVoided(t *testing.T) {
	s, pp, c := newTestService(t, nil)
	s.SetShopper(shop.Demo{})
	ctx := context.Background()
	a := register(t, s, "Asha", "9876543210")
	d := register(t, s, "Dev", "9123456780")
	trip := goa(t, s, a, d)
	g := propose(t, s, trip, a, "beach towels")
	for _, u := range []string{a, d} {
		g = must[*domain.GroupBuy](t)(s.JoinGroupBuy(ctx, g.ID, u, ViaPayPal))
	}
	must[*domain.GroupBuy](t)(s.AuthorizeGroupBuyOrder(ctx, shareOf(g, a).OrderID, a))
	c.t = g.Deadline.Add(1)
	if _, err := s.AuthorizeGroupBuyOrder(ctx, shareOf(g, d).OrderID, d); code(err) != "group_buy_closed" {
		t.Fatalf("late authorize: %v", err)
	}
	if len(pp.Captures) != 0 || len(pp.Voids) != 2 || g.Status != "expired" {
		t.Fatalf("captures %v voids %v status %s", pp.Captures, pp.Voids, g.Status)
	}
}

// hookPP lets a test run something while PayPal is placing a hold, the
// moment the service has let go of its lock.
type hookPP struct {
	*paypal.Mock
	onAuthorize func()
}

func (h *hookPP) AuthorizeOrder(ctx context.Context, orderID string) (string, error) {
	if f := h.onAuthorize; f != nil {
		h.onAuthorize = nil
		f()
	}
	return h.Mock.AuthorizeOrder(ctx, orderID)
}

// A person who approves on PayPal while also saying yes from their trip
// share pays once, and the PayPal hold that was not used is let go.
func TestQAAuthorizeRacingWalletJoinVoidsTheSpareHold(t *testing.T) {
	pp := &hookPP{Mock: &paypal.Mock{}}
	c := &clock{time.Date(2026, 10, 13, 20, 42, 0, 0, IST)}
	s := New(pp, c.now, nil)
	s.SetShopper(shop.Demo{})
	ctx := context.Background()
	a := register(t, s, "Asha", "9876543210")
	d := register(t, s, "Dev", "9123456780")
	trip := goa(t, s, a, d)
	for _, u := range []string{a, d} {
		topUp(t, s, u, 3000)
		must[TripView](t)(s.DepositFromBalance(trip, u, domain.Rupees(3000)))
	}
	g := propose(t, s, trip, a, "beach towels")
	g = must[*domain.GroupBuy](t)(s.JoinGroupBuy(ctx, g.ID, d, ViaPayPal))
	order := shareOf(g, d).OrderID
	pp.onAuthorize = func() { must[*domain.GroupBuy](t)(s.JoinGroupBuy(ctx, g.ID, d, ViaWallet)) }
	must[*domain.GroupBuy](t)(s.AuthorizeGroupBuyOrder(ctx, order, d))
	g = must[*domain.GroupBuy](t)(s.JoinGroupBuy(ctx, g.ID, a, ViaWallet))
	if g.Status != "paid" {
		t.Fatalf("status %s", g.Status)
	}
	if len(pp.Captures) != 0 || len(pp.Voids) != 1 {
		t.Fatalf("Dev's spare PayPal hold: captures %v voids %v", pp.Captures, pp.Voids)
	}
	checkBooks(t, s)
}
