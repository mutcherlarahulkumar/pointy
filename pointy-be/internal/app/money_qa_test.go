package app

import (
	"context"
	"sync"
	"testing"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
)

// Many withdrawals of the whole balance at once: only one may go through,
// and the balance never goes below zero.
func TestConcurrentWithdrawalsCannotOverdraw(t *testing.T) {
	s, pp, _ := newTestService(t, nil)
	ctx := context.Background()
	a := register(t, s, "Asha", "9876543210")
	must[Me](t)(s.SetPayPalEmail(a, "asha@example.com"))
	for round := 0; round < 20; round++ {
		topUp(t, s, a, 1000)
		before := len(pp.Payouts)
		var wg sync.WaitGroup
		start := make(chan struct{})
		for i := 0; i < 16; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				<-start
				_, _ = s.Withdraw(ctx, a, domain.Rupees(1000))
			}()
		}
		close(start)
		wg.Wait()
		if b := balance(s, a); b != 0 {
			t.Fatalf("round %d: balance %d after withdrawing everything", round, b)
		}
		if n := len(pp.Payouts) - before; n != 1 {
			t.Fatalf("round %d: %d payouts sent for one balance", round, n)
		}
		checkBooks(t, s)
	}
}
