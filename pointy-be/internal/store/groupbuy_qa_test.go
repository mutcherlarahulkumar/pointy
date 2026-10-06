package store

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/app"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/paypal"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/shop"
)

// TestGroupBuySurvivesPostgresRestart saves a group purchase half way
// (one yes from a trip share, one PayPal hold, one person still to answer),
// reloads the service from Postgres, and finishes it there.
func TestGroupBuySurvivesPostgresRestart(t *testing.T) {
	url := os.Getenv("POINTY_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("POINTY_TEST_DATABASE_URL is not set")
	}
	ctx := context.Background()
	admin, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer admin.Close()
	if _, err := admin.Exec(ctx, `DROP SCHEMA IF EXISTS groupbuy_qa CASCADE; CREATE SCHEMA groupbuy_qa`); err != nil {
		t.Fatal(err)
	}
	defer admin.Exec(ctx, `DROP SCHEMA IF EXISTS groupbuy_qa CASCADE`) //nolint:errcheck
	sep := "?"
	if strings.Contains(url, "?") {
		sep = "&"
	}
	schemaURL := url + sep + "search_path=groupbuy_qa"

	pp := &paypal.Mock{}
	now := func() time.Time { return time.Date(2026, 10, 13, 20, 42, 0, 0, app.IST) }
	start := func() (*app.Service, func()) {
		pg, err := Open(ctx, schemaURL)
		if err != nil {
			t.Fatal(err)
		}
		s := app.New(pp, now, pg)
		if err := s.Load(ctx); err != nil {
			t.Fatal(err)
		}
		s.SetShopper(shop.Demo{})
		return s, pg.Close
	}
	ok := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	s, stop := start()
	var ids []string
	for i, name := range []string{"Asha", "Dev", "Meera"} {
		phone := []string{"9876543210", "9123456780", "9988776655"}[i]
		r, err := s.Register(app.RegisterInput{Name: name, Phone: phone, PIN: "246810"})
		ok(err)
		ids = append(ids, r.User.ID)
	}
	a, d, m := ids[0], ids[1], ids[2]
	tv, err := s.CreateTrip(a, app.CreateTripInput{Name: "Goa", Start: now(), End: now().Add(72 * time.Hour), Members: []string{d, m}})
	ok(err)
	trip := tv.ID
	for _, u := range []string{a, m} {
		dep, err := s.StartTopUp(ctx, u, domain.Rupees(3000))
		ok(err)
		_, err = s.CaptureDeposit(ctx, dep.OrderID)
		ok(err)
		_, err = s.DepositFromBalance(trip, u, domain.Rupees(3000))
		ok(err)
	}
	ans, err := s.ShopForTrip(ctx, trip, a, "beach towels")
	ok(err)
	g, err := s.ProposeGroupBuy(trip, a, ans.SearchID, ans.Picks[0].Index, ans.Picks[0].Why)
	ok(err)
	_, err = s.JoinGroupBuy(ctx, g.ID, a, app.ViaWallet)
	ok(err)
	g, err = s.JoinGroupBuy(ctx, g.ID, d, app.ViaPayPal)
	ok(err)
	var order string
	for _, sh := range g.Shares {
		if sh.UserID == d {
			order = sh.OrderID
		}
	}
	g, err = s.AuthorizeGroupBuyOrder(ctx, order, d)
	ok(err)
	before, _ := json.Marshal(g)
	stop()

	// After a restart: the same purchase, and Asha's part still held.
	s, stop = start()
	defer stop()
	g2, err := s.GroupBuy(ctx, g.ID, a)
	ok(err)
	if after, _ := json.Marshal(g2); string(after) != string(before) {
		t.Fatalf("group buy changed on reload:\n%s\n%s", before, after)
	}
	all := domain.Rupees(3000)
	_, err = s.AddExpense(trip, a, app.ExpenseInput{Description: "Villa", Amount: all, ConfirmOverBudget: true,
		Method: domain.SplitExact, Participants: []domain.SplitInput{{UserID: a, Exact: all}}})
	if de, isDE := err.(*domain.Error); !isDE || de.Code != "insufficient_share" {
		t.Fatalf("held money spendable after restart: %v", err)
	}
	g2, err = s.JoinGroupBuy(ctx, g.ID, m, app.ViaWallet)
	ok(err)
	if g2.Status != "paid" || len(pp.Captures) != 1 {
		t.Fatalf("after restart: %+v captures %v", g2, pp.Captures)
	}
	tv, err = s.Trip(trip, a)
	ok(err)
	if tv.Spent != g2.Amount || tv.Balance != domain.Rupees(6000)+g2.Shares[1].Amount-g2.Amount {
		t.Fatalf("trip after paying: spent %d balance %d", tv.Spent, tv.Balance)
	}
}
