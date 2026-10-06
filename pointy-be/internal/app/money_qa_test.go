package app

import (
	"context"
	"errors"
	"fmt"
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

// flakyStore is a memStore whose next Save can be made to fail. Like
// Postgres, it keeps deposits and payouts as they were when saved and
// loads them as new objects.
type flakyStore struct {
	memStore
	mu       sync.Mutex
	fail     bool
	deposits []domain.Deposit
	payouts  []domain.Payout
}

func (f *flakyStore) Save(ctx context.Context, items []any) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.fail {
		f.fail = false
		return errors.New("database went away")
	}
	rest := []any{}
	for _, it := range items {
		switch v := it.(type) {
		case *domain.Deposit:
			f.deposits = upsert(f.deposits, *v, func(a, b domain.Deposit) bool { return a.OrderID == b.OrderID })
		case *domain.Payout:
			f.payouts = upsert(f.payouts, *v, func(a, b domain.Payout) bool { return a.ID == b.ID })
		default:
			rest = append(rest, it)
		}
	}
	return f.memStore.Save(ctx, rest)
}

func upsert[T any](list []T, v T, same func(a, b T) bool) []T {
	for i := range list {
		if same(list[i], v) {
			list[i] = v
			return list
		}
	}
	return append(list, v)
}

func (f *flakyStore) Load(ctx context.Context) (*Snapshot, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	snap, err := f.memStore.Load(ctx)
	if err != nil {
		return nil, err
	}
	for _, d := range f.deposits {
		d := d
		snap.Deposits = append(snap.Deposits, &d)
	}
	for _, p := range f.payouts {
		p := p
		snap.Payouts = append(snap.Payouts, &p)
	}
	return snap, nil
}

func (f *flakyStore) failNextSave() {
	f.mu.Lock()
	f.fail = true
	f.mu.Unlock()
}

// blockingPayPal blocks CaptureOrder and PayoutStatus until released.
type blockingPayPal struct {
	*paypal.Mock
	block            bool
	entered, release chan struct{}
}

func (p *blockingPayPal) wait() {
	if p.block {
		p.entered <- struct{}{}
		<-p.release
	}
}

func (p *blockingPayPal) CaptureOrder(ctx context.Context, orderID string) error {
	p.wait()
	return p.Mock.CaptureOrder(ctx, orderID)
}

func (p *blockingPayPal) PayoutStatus(ctx context.Context, batchID string) (string, error) {
	p.wait()
	return p.Mock.PayoutStatus(ctx, batchID)
}

func newFlakyService(t *testing.T) (*Service, *flakyStore, *blockingPayPal) {
	t.Helper()
	st := &flakyStore{}
	pp := &blockingPayPal{Mock: &paypal.Mock{}, entered: make(chan struct{}), release: make(chan struct{})}
	c := &clock{time.Date(2026, 10, 13, 20, 42, 0, 0, IST)}
	s := New(pp, c.now, st)
	if err := s.Load(context.Background()); err != nil {
		t.Fatal(err)
	}
	return s, st, pp
}

// A failed save in the middle of a capture reloads the deposit as a new
// object. The capture must still credit exactly once, however often the
// app then retries.
func TestCaptureDuringReloadCreditsOnce(t *testing.T) {
	s, st, pp := newFlakyService(t)
	ctx := context.Background()
	a := register(t, s, "Asha", "9876543210")
	d := must[*domain.Deposit](t)(s.StartTopUp(ctx, a, domain.Rupees(500)))
	pp.block = true
	done := make(chan error)
	go func() { _, err := s.CaptureDeposit(ctx, d.OrderID); done <- err }()
	<-pp.entered
	st.failNextSave()
	_ = s.MarkAlertsSeen(a) // fails and reloads everything
	pp.block = false
	// The app retries while the first capture is still waiting on PayPal.
	_, _ = s.CaptureDeposit(ctx, d.OrderID)
	close(pp.release)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	_, _ = s.CaptureDeposit(ctx, d.OrderID)
	if b := balance(s, a); b != domain.Rupees(500) {
		t.Fatalf("balance %d after one ₹500 top-up", b)
	}
	if got := must[*domain.Deposit](t)(s.Deposit(d.OrderID, a)); got.Status != "captured" {
		t.Fatalf("deposit is %s", got.Status)
	}
	checkBooks(t, s)
}

// The same for a payout PayPal sends back: it is given back once.
func TestReturnedPayoutDuringReloadIsGivenBackOnce(t *testing.T) {
	s, st, pp := newFlakyService(t)
	ctx := context.Background()
	a := register(t, s, "Asha", "9876543210")
	d := must[*domain.Deposit](t)(s.StartTopUp(ctx, a, domain.Rupees(1000)))
	must[*domain.Deposit](t)(s.CaptureDeposit(ctx, d.OrderID))
	must[Me](t)(s.SetPayPalEmail(a, "asha@example.com"))
	pp.PayoutFirst = "PENDING"
	must[*domain.Payout](t)(s.Withdraw(ctx, a, domain.Rupees(400)))
	pp.PayoutLater = "RETURNED"
	pp.block = true
	done := make(chan struct{})
	go func() { s.RefreshPayouts(ctx, a); close(done) }()
	<-pp.entered
	st.failNextSave()
	_ = s.MarkAlertsSeen(a)
	pp.block = false
	close(pp.release)
	<-done
	s.RefreshPayouts(ctx, a)
	s.RefreshPayouts(ctx, a)
	if b := balance(s, a); b != domain.Rupees(1000) {
		t.Fatalf("balance %d: the ₹400 should come back once", b)
	}
	checkBooks(t, s)
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

// PIN guesses sent in parallel must not get past the five-try lockout:
// each guess counts before the slow bcrypt check, not after it.
func TestParallelPINGuessesAreCapped(t *testing.T) {
	s, _, _ := newTestService(t, nil)
	register(t, s, "Asha", "9876543210")
	var mu sync.Mutex
	tried := 0
	var wg sync.WaitGroup
	for i := 0; i < 30; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_, err := s.Login("9876543210", fmt.Sprintf("%06d", 100000+i*7))
			if c := code(err); c == "wrong_pin" || c == "" {
				mu.Lock()
				tried++
				mu.Unlock()
			}
		}(i)
	}
	wg.Wait()
	if tried > maxFailedPINs {
		t.Fatalf("%d PINs were checked in parallel; the limit is %d", tried, maxFailedPINs)
	}
}

// A payment between balances happens now: a back-dated "at" from the app
// must not move it into another day (it would slip past a child's daily
// and monthly limits, and reorder history).
func TestPersonalPaymentCannotBeBackdated(t *testing.T) {
	s, c, _, k := family(t)
	shop := register(t, s, "Shop", "9988776655")
	old := c.t.AddDate(0, -2, 0)
	// The daily limit is ₹300; five back-dated ₹100 payments are ₹500 today.
	var err error
	for i := 0; i < 5 && err == nil; i++ {
		_, err = s.PayPersonal(k, ExpenseInput{Description: "Sweets", Amount: domain.Rupees(100), PayeeUserID: shop, At: &old})
	}
	if code(err) != "needs_parent" {
		t.Fatalf("back-dated payments got past the daily limit: %v", err)
	}
	for _, h := range s.History(k) {
		if h.At.Before(c.t) && h.Kind == "payment" {
			t.Fatalf("payment recorded at %v, before now %v", h.At, c.t)
		}
	}
}

// Item prices so big they wrap around int64 must be refused, not added up
// into a small, wrong bill.
func TestSplitByItemsRefusesHugeItems(t *testing.T) {
	s, _, _ := newTestService(t, nil)
	a := register(t, s, "Asha", "9876543210")
	d := register(t, s, "Dev", "9123456780")
	huge := Paise(1 << 62)
	_, err := s.SplitByItems(a, ItemSplitInput{Description: "Dinner", Items: []ItemShareLine{
		{Name: "Gold plate", Amount: huge, People: []string{d}},
		{Name: "Gold plate", Amount: huge, People: []string{d}},
		{Name: "Gold plate", Amount: huge, People: []string{d}},
		{Name: "Gold plate", Amount: huge, People: []string{d}},
		{Name: "Chai", Amount: 500, People: []string{d}},
		{Name: "Dosa", Amount: 100, People: []string{a}},
	}})
	if code(err) != "invalid" {
		t.Fatalf("huge items: %v", err)
	}
	if len(s.MoneyRequests(d)) != 0 {
		t.Fatal("a request was sent")
	}
}
