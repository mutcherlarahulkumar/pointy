package app

import (
	"context"
	"testing"

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
