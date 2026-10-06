package app

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/paypal"
)

// slowPayPal blocks SendPayout until released, to act while a withdrawal is
// on its way to PayPal.
type slowPayPal struct {
	*paypal.Mock
	entered, release chan struct{}
}

func (p *slowPayPal) SendPayout(ctx context.Context, ref, email string, amount domain.Paise, note string) (paypal.Payout, error) {
	p.entered <- struct{}{}
	<-p.release
	return p.Mock.SendPayout(ctx, ref, email, amount, note)
}

// flakyStore is a memStore whose next Save can be made to fail.
type flakyStore struct {
	memStore
	mu   sync.Mutex
	fail bool
}

func (f *flakyStore) Save(ctx context.Context, items []any) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.fail {
		f.fail = false
		return errors.New("database went away")
	}
	return f.memStore.Save(ctx, items)
}

func (f *flakyStore) Load(ctx context.Context) (*Snapshot, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.memStore.Load(ctx)
}

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

// A failed save reloads the state from the database. Money held for a
// withdrawal still on its way to PayPal must stay held.
func TestReloadKeepsWithdrawalHolds(t *testing.T) {
	st := &flakyStore{}
	pp := &slowPayPal{Mock: &paypal.Mock{}, entered: make(chan struct{}), release: make(chan struct{})}
	c := &clock{time.Date(2026, 10, 13, 20, 42, 0, 0, IST)}
	s := New(pp, c.now, st)
	if err := s.Load(context.Background()); err != nil {
		t.Fatal(err)
	}
	a := register(t, s, "Asha", "9876543210")
	d := register(t, s, "Dev", "9123456780")
	topUp(t, s, a, 1000)
	must[Me](t)(s.SetPayPalEmail(a, "asha@example.com"))

	done := make(chan error)
	go func() {
		_, err := s.Withdraw(context.Background(), a, domain.Rupees(1000))
		done <- err
	}()
	<-pp.entered
	st.mu.Lock()
	st.fail = true
	st.mu.Unlock()
	if err := s.MarkAlertsSeen(d); code(err) != "storage_error" {
		t.Fatalf("expected the save to fail: %v", err)
	}
	if _, err := s.PayPersonal(a, ExpenseInput{Description: "Chai", Amount: domain.Rupees(1000), PayeeUserID: d}); code(err) != "insufficient_balance" {
		t.Fatalf("money on its way to PayPal was spent again: %v", err)
	}
	close(pp.release)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if b := balance(s, a); b != 0 {
		t.Fatalf("balance %d", b)
	}
	checkBooks(t, s)
}
