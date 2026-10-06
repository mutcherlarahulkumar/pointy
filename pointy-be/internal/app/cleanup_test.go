package app

import (
	"context"
	"testing"
	"time"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/shop"
)

// clip never splits a letter that takes more than one byte.
func TestClipKeepsWholeLetters(t *testing.T) {
	if got := clip("₹₹₹₹", 2); got != "₹₹" {
		t.Fatalf("clip: %q", got)
	}
	if got := clip("short", 80); got != "short" {
		t.Fatalf("clip: %q", got)
	}
}

// An old trip PayPal order approved after the trip was settled is not
// captured: its money would land in a share nobody can be refunded from.
func TestOldTripOrderIsNotCapturedAfterSettle(t *testing.T) {
	s, _, _ := newTestService(t, nil)
	a := register(t, s, "Asha", "9876543210")
	d := register(t, s, "Dev", "9123456780")
	trip := goa(t, s, a, d)
	must[Settlement](t)(s.Settle(trip, a))
	s.mu.Lock()
	s.deposits["ORDER-OLD"] = &domain.Deposit{ID: "dep_old", TripID: trip, UserID: d, Amount: 50000, OrderID: "ORDER-OLD", Status: "created"}
	s.mu.Unlock()
	if _, err := s.CaptureDeposit(context.Background(), "ORDER-OLD"); code(err) != "trip_closed" {
		t.Fatalf("capture into a settled trip: %v", err)
	}
	checkBooks(t, s)
}

// A child can have only a few asks waiting, so the parent is not flooded.
func TestChildCannotFloodTheParentWithAsks(t *testing.T) {
	s, c, p, k := family(t)
	shop := register(t, s, "Canteen", "9988776655")
	ask := func() error {
		_, err := s.AskApproval(k, ApprovalInput{PayeeID: shop, Amount: domain.Rupees(50)})
		return err
	}
	for i := 0; i < maxOpenApprovals; i++ {
		if err := ask(); err != nil {
			t.Fatal(err)
		}
	}
	if err := ask(); code(err) != "too_many_asks" {
		t.Fatalf("ask over the cap: %v", err)
	}
	// Once one is answered, or they expire, the child can ask again.
	f := must[FamilyView](t)(s.Family(p))
	must[ApprovalView](t)(s.DecideApproval(p, f.Approvals[0].ID, false, ""))
	if err := ask(); err != nil {
		t.Fatal(err)
	}
	c.t = c.t.Add(approvalWindow + time.Minute)
	if err := ask(); err != nil {
		t.Fatal(err)
	}
}

// Adding people is all or nothing: one unknown id adds nobody.
func TestAddMembersIsAllOrNothing(t *testing.T) {
	s, _, _ := newTestService(t, nil)
	a := register(t, s, "Asha", "9876543210")
	d := register(t, s, "Dev", "9123456780")
	trip := goa(t, s, a)
	if _, err := s.AddMembers(trip, a, []string{d, "u_nobody"}); code(err) != "invalid" {
		t.Fatalf("unknown member: %v", err)
	}
	if _, err := s.Trip(trip, d); code(err) != "not_found" && code(err) != "forbidden" {
		t.Fatalf("Dev was added by a refused call: %v", err)
	}
}

// PayPal's webhook for a group-buy approval places the hold, like the
// return page does, instead of trying to capture it as a top-up.
func TestWebhookPlacesGroupBuyHold(t *testing.T) {
	s, pp, _ := newTestService(t, nil)
	s.SetShopper(shop.Demo{})
	ctx := context.Background()
	a := register(t, s, "Asha", "9876543210")
	d := register(t, s, "Dev", "9123456780")
	trip := goa(t, s, a, d)
	g := propose(t, s, trip, a, "beach towels")
	for _, u := range []string{a, d} {
		g = must[*domain.GroupBuy](t)(s.JoinGroupBuy(ctx, g.ID, u, ViaPayPal))
	}
	for _, u := range []string{a, d} {
		if err := s.HandleWebhook(ctx, "CHECKOUT.ORDER.APPROVED", shareOf(g, u).OrderID); err != nil {
			t.Fatal(err)
		}
	}
	if g.Status != "paid" || len(pp.Captures) != 2 {
		t.Fatalf("status %s captures %v", g.Status, pp.Captures)
	}
	checkBooks(t, s)
}
