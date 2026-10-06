package store_test

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/app"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/paypal"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/store"
)

// Money between people, withdrawals and their return survive restarts on
// Postgres, and the books balance after each one.
//
//	POINTY_TEST_DATABASE_URL=postgres://... go test ./internal/store
func TestMoneySurvivesRestartsOnPostgres(t *testing.T) {
	url := os.Getenv("POINTY_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("POINTY_TEST_DATABASE_URL is not set")
	}
	ctx := context.Background()
	// A schema of its own, so this runs alongside the other database tests.
	admin, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer admin.Close()
	if _, err := admin.Exec(ctx, `DROP SCHEMA IF EXISTS money_test CASCADE; CREATE SCHEMA money_test`); err != nil {
		t.Fatal(err)
	}
	defer admin.Exec(ctx, `DROP SCHEMA IF EXISTS money_test CASCADE`) //nolint:errcheck
	sep := "?"
	if strings.Contains(url, "?") {
		sep = "&"
	}
	schemaURL := url + sep + "search_path=money_test"

	pp := &paypal.Mock{}
	now := func() time.Time { return time.Date(2026, 10, 13, 20, 42, 0, 0, app.IST) }
	boot := func() *app.Service {
		t.Helper()
		pg, err := store.Open(ctx, schemaURL)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(pg.Close)
		s := app.New(pp, now, pg)
		if err := s.Load(ctx); err != nil {
			t.Fatal(err)
		}
		return s
	}
	bal := func(s *app.Service, id string) domain.Paise {
		t.Helper()
		me, err := s.Me(id)
		if err != nil {
			t.Fatal(err)
		}
		return me.PersonalBalance
	}
	balanced := func(s *app.Service, id string) {
		t.Helper()
		v, err := s.Money(ctx, id)
		if err != nil {
			t.Fatal(err)
		}
		if !v.Balanced {
			t.Fatalf("PayPal holds %d but Pointy owes %d", v.BusinessAccount, v.OwedToEveryone)
		}
	}

	s := boot()
	asha, err := s.Register(app.RegisterInput{Name: "Asha", Phone: "9876543210", PIN: "246810"})
	if err != nil {
		t.Fatal(err)
	}
	dev, err := s.Register(app.RegisterInput{Name: "Dev", Phone: "9123456780", PIN: "246810"})
	if err != nil {
		t.Fatal(err)
	}
	a, d := asha.User.ID, dev.User.ID
	dep, err := s.StartTopUp(ctx, a, domain.Rupees(2000))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.CaptureDeposit(ctx, dep.OrderID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.SetPayPalEmail(a, "asha@example.com"); err != nil {
		t.Fatal(err)
	}
	pp.PayoutFirst = "PENDING"
	if _, err := s.Withdraw(ctx, a, domain.Rupees(500)); err != nil {
		t.Fatal(err)
	}
	r, err := s.RequestMoney(d, app.MoneyRequestInput{PayerID: a, Amount: domain.Rupees(300), Note: "Movie"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.PayMoneyRequest(a, r.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.SplitByItems(a, app.ItemSplitInput{Description: "Dinner", Extra: 1,
		Items: []app.ItemShareLine{{Name: "Dosa", Amount: 1, People: []string{a, d}}, {Name: "Chai", Amount: 2000, People: []string{d}}}}); err != nil {
		t.Fatal(err)
	}
	if err := s.Logout(asha.Token); err != nil {
		t.Fatal(err)
	}
	balanced(s, a)

	// Restart: everything is as it was.
	s = boot()
	if b := bal(s, a); b != domain.Rupees(1200) {
		t.Fatalf("Asha %d after restart", b)
	}
	if b := bal(s, d); b != domain.Rupees(300) {
		t.Fatalf("Dev %d after restart", b)
	}
	if _, ok := s.UserForToken(asha.Token); ok {
		t.Fatal("a signed-out token works again after restart")
	}
	if _, ok := s.UserForToken(dev.Token); !ok {
		t.Fatal("Dev was signed out by the restart")
	}
	reqs := s.MoneyRequests(d)
	if len(reqs) != 2 || reqs[1].Status != "paid" || reqs[0].Status != "open" || reqs[0].Amount != 2000 {
		t.Fatalf("requests after restart: %+v %+v", reqs[0].MoneyRequest, reqs[1].MoneyRequest)
	}
	if _, err := s.PayMoneyRequest(a, r.ID); err == nil {
		t.Fatal("a paid request was paid again after restart")
	}
	po := s.Payouts(ctx, a)
	if len(po) != 1 || po[0].Status != "paid" {
		t.Fatalf("payouts after restart: %+v", po)
	}
	balanced(s, a)

	// A second withdrawal that PayPal sends back is given back once, also
	// across restarts.
	pp.PayoutLater = "PENDING"
	if _, err := s.Withdraw(ctx, a, domain.Rupees(200)); err != nil {
		t.Fatal(err)
	}
	pp.PayoutLater = "RETURNED"
	s.RefreshPayouts(ctx, a)
	s = boot()
	s.RefreshPayouts(ctx, a)
	if b := bal(s, a); b != domain.Rupees(1200) {
		t.Fatalf("Asha %d after a returned payout and a restart", b)
	}
	balanced(s, a)
}
