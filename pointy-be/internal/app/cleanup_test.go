package app

import (
	"context"
	"testing"
	"time"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
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
