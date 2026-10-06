package app

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/paypal"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/shop"
)

// Joining after the 48 hours are up must not buy anything, even when
// nobody listed the purchases in between (expiry used to happen only on a
// list).
func TestJoinAfterDeadlineDoesNotBuy(t *testing.T) {
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
func TestExpiredHoldDoesNotBlockSettle(t *testing.T) {
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
func TestAuthorizeAfterDeadlineIsVoided(t *testing.T) {
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

// Huge share weights or exact amounts must be refused as invalid, never
// wrap around int64 into negative or oversized shares.
func TestSplitRefusesOverflow(t *testing.T) {
	big := int64(1) << 62
	cases := []struct {
		method domain.SplitMethod
		in     []domain.SplitInput
	}{
		{domain.SplitShares, []domain.SplitInput{{UserID: "a", Weight: big}, {UserID: "b", Weight: big}}},
		// three amounts that wrap around to exactly 1,000 paise
		{domain.SplitExact, []domain.SplitInput{{UserID: "a", Exact: 6148914691236517539}, {UserID: "b", Exact: 6148914691236517539}, {UserID: "c", Exact: 6148914691236517538}}},
	}
	for i, c := range cases {
		shares, err := domain.Split(1000, c.method, c.in)
		if code(err) != "invalid" {
			t.Errorf("case %d: shares %v err %v", i, shares, err)
		}
	}
	// A big weight that fits is worked out exactly (it used to wrap and
	// come out as 500 and 500).
	shares, err := domain.Split(1000, domain.SplitShares, []domain.SplitInput{{UserID: "a", Weight: big}, {UserID: "b", Weight: 1}})
	if err != nil || shares[0].Amount != 1000 || shares[1].Amount != 0 {
		t.Errorf("big weight: %v %v", shares, err)
	}
}

// A budget so large that budget maths wraps around int64 is refused, both
// when planning a trip and when changing budgets later.
func TestHugeBudgetIsRefused(t *testing.T) {
	s, _, _ := newTestService(t, nil)
	a := register(t, s, "Asha", "9876543210")
	trip := goa(t, s, a)
	huge := Paise(1) << 61
	if _, err := s.SetBudgets(trip, a, map[domain.Category]Paise{domain.Food: huge, domain.Stay: huge, domain.Other: huge, domain.Transport: huge}); code(err) != "invalid" {
		v, _ := s.Budgets(trip, a)
		t.Fatalf("huge budgets: %v (total limit %d)", err, v.Limit)
	}
	_, err := s.CreateTrip(a, CreateTripInput{Name: "x", Start: s.now(), End: s.now(), Budgets: map[domain.Category]Paise{domain.Food: huge}})
	if code(err) != "invalid" {
		t.Fatalf("huge budget on a new trip: %v", err)
	}
}

// Joins, a no, and listing all at once: whatever wins, the purchase is
// paid at most once, the books balance and no share goes below zero.
func TestConcurrentJoinsDeclineAndExpire(t *testing.T) {
	for round := 0; round < 8; round++ {
		s, pp, c := newTestService(t, nil)
		s.SetShopper(shop.Demo{})
		ctx := context.Background()
		var users []string
		for i, ph := range []string{"9876543210", "9123456780", "9988776655"} {
			users = append(users, register(t, s, []string{"Asha", "Dev", "Meera"}[i], ph))
		}
		trip := goa(t, s, users[0], users[1:]...)
		for _, u := range users {
			topUp(t, s, u, 3000)
			must[TripView](t)(s.DepositFromBalance(trip, u, domain.Rupees(3000)))
		}
		g := propose(t, s, trip, users[0], "beach towels")
		if round%3 == 0 {
			c.t = g.Deadline.Add(-1) // right at the edge; expiry may not happen yet
		}
		var wg sync.WaitGroup
		for i, u := range users {
			wg.Add(1)
			go func(i int, u string) {
				defer wg.Done()
				if i == 2 && round%2 == 1 {
					_, _ = s.JoinGroupBuy(ctx, g.ID, u, ViaPayPal)
					s.mu.Lock()
					order := shareOf(g, u).OrderID
					s.mu.Unlock()
					if order != "" {
						_, _ = s.AuthorizeGroupBuyOrder(ctx, order, u)
					}
					return
				}
				_, _ = s.JoinGroupBuy(ctx, g.ID, u, ViaWallet)
			}(i, u)
		}
		wg.Add(2)
		go func() { defer wg.Done(); _, _ = s.GroupBuys(ctx, trip, users[0]) }()
		go func() {
			defer wg.Done()
			if round%4 == 0 {
				_, _ = s.DeclineGroupBuy(ctx, g.ID, users[1])
			}
		}()
		wg.Wait()
		s.mu.Lock()
		status := g.Status
		paid := 0
		for _, e := range s.expenses {
			if e.Mode == ModeGroupBuy {
				paid++
			}
		}
		for _, u := range users {
			if av := s.availL(domain.ShareAccount(trip, u)); av < 0 {
				t.Errorf("round %d: %s has %d free", round, u, av)
			}
		}
		s.mu.Unlock()
		if (status == "paid") != (paid == 1) || paid > 1 || len(pp.Captures) > 1 {
			t.Fatalf("round %d: status %s, %d expenses, captures %v", round, status, paid, pp.Captures)
		}
		checkBooks(t, s)
	}
}

// hookPP lets a test run something while PayPal is placing a hold, the
// moment the service has let go of its lock.
type hookPP struct {
	*paypal.Mock
	onAuthorize  func()
	onCreateAuth func()
}

func (h *hookPP) AuthorizeOrder(ctx context.Context, orderID string) (string, error) {
	if f := h.onAuthorize; f != nil {
		h.onAuthorize = nil
		f()
	}
	return h.Mock.AuthorizeOrder(ctx, orderID)
}

// ctxPP behaves like a real HTTP client: a cancelled context fails the call.
type ctxPP struct{ *paypal.Mock }

func (p ctxPP) CaptureAuthorization(ctx context.Context, authID string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	return p.Mock.CaptureAuthorization(ctx, authID)
}

func (p ctxPP) VoidAuthorization(ctx context.Context, authID string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	return p.Mock.VoidAuthorization(ctx, authID)
}

// The last yes comes from a phone that hangs up (the request is
// cancelled) before PayPal answers: everyone agreed, so the purchase must
// still be paid, not fail half way because of the dropped connection.
// Likewise a no from a phone that hangs up still lets the PayPal holds go.
func TestHangingUpDoesNotBreakPayingOrVoiding(t *testing.T) {
	mock := &paypal.Mock{}
	c := &clock{time.Date(2026, 10, 13, 20, 42, 0, 0, IST)}
	s := New(ctxPP{mock}, c.now, nil)
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
	gone, cancel := context.WithCancel(ctx)
	cancel()
	g, err := s.JoinGroupBuy(gone, g.ID, a, ViaWallet)
	if err != nil || g.Status != "paid" || len(mock.Captures) != 1 {
		t.Fatalf("hung-up last yes: %v status %s captures %v", err, g.Status, mock.Captures)
	}

	g = propose(t, s, trip, a, "playing cards uno")
	g = must[*domain.GroupBuy](t)(s.JoinGroupBuy(ctx, g.ID, d, ViaPayPal))
	must[*domain.GroupBuy](t)(s.AuthorizeGroupBuyOrder(ctx, shareOf(g, d).OrderID, d))
	g = must[*domain.GroupBuy](t)(s.DeclineGroupBuy(gone, g.ID, a))
	if g.Status != "cancelled" || len(mock.Voids) != 1 {
		t.Fatalf("hung-up no: status %s voids %v", g.Status, mock.Voids)
	}
	checkBooks(t, s)
}

func (h *hookPP) CreateAuthOrder(ctx context.Context, ref string, amount domain.Paise, desc string) (paypal.Order, error) {
	if f := h.onCreateAuth; f != nil {
		h.onCreateAuth = nil
		f()
	}
	return h.Mock.CreateAuthOrder(ctx, ref, amount, desc)
}

// Saying yes from the trip share while the PayPal page is being made must
// keep the wallet hold: the late PayPal order must not turn the share
// into an unauthorized PayPal one.
func TestPayPalJoinRacingWalletJoinKeepsTheWalletHold(t *testing.T) {
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
	pp.onCreateAuth = func() { must[*domain.GroupBuy](t)(s.JoinGroupBuy(ctx, g.ID, d, ViaWallet)) }
	g = must[*domain.GroupBuy](t)(s.JoinGroupBuy(ctx, g.ID, d, ViaPayPal))
	if sh := shareOf(g, d); sh.Status != "in" || sh.Via != ViaWallet {
		t.Fatalf("Dev's share %+v", sh)
	}
	g = must[*domain.GroupBuy](t)(s.JoinGroupBuy(ctx, g.ID, a, ViaWallet))
	if g.Status != "paid" || len(pp.Captures) != 0 {
		t.Fatalf("status %s captures %v", g.Status, pp.Captures)
	}
	if tv := must[TripView](t)(s.Trip(trip, a)); tv.Deposited != domain.Rupees(6000) || tv.Balance != domain.Rupees(6000)-g.Amount {
		t.Fatalf("money appeared from nowhere: %+v", tv)
	}
	checkBooks(t, s)
}

// A person who approves on PayPal while also saying yes from their trip
// share pays once, and the PayPal hold that was not used is let go.
func TestAuthorizeRacingWalletJoinVoidsTheSpareHold(t *testing.T) {
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
