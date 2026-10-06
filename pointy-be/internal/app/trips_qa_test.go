package app

import (
	"context"
	"testing"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
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
