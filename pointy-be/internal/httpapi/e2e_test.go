package httpapi_test

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/app"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/httpapi"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/paypal"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/store"
)

// The whole two-phone story over HTTP. With POINTY_TEST_DATABASE_URL set it
// runs on Postgres and restarts the server half way to prove nothing is
// lost; without it, it runs in memory.
//
//	POINTY_TEST_DATABASE_URL=postgres://postgres@localhost:5433/pointy_test go test ./internal/httpapi/
func TestTwoPhonesEndToEnd(t *testing.T) {
	ctx := context.Background()
	dbURL := os.Getenv("POINTY_TEST_DATABASE_URL")
	if dbURL != "" {
		conn, err := pgx.Connect(ctx, dbURL)
		if err != nil {
			t.Fatal(err)
		}
		_, err = conn.Exec(ctx, `DROP TABLE IF EXISTS ledger_postings, ledger_entries, sessions, deposits, expenses, deposit_requests, plans, alerts, money_requests, trips, users, schema_migrations CASCADE`)
		conn.Close(ctx)
		if err != nil {
			t.Fatal(err)
		}
	}
	pp := &paypal.Mock{}
	start := func() (*httptest.Server, func()) {
		var st app.Store = app.MemoryStore{}
		closeDB := func() {}
		if dbURL != "" {
			pg, err := store.Open(ctx, dbURL)
			if err != nil {
				t.Fatal(err)
			}
			st, closeDB = pg, pg.Close
		}
		// The clock ticks a second per call, like a real one moving on.
		var mu sync.Mutex
		tick := time.Date(2026, 10, 13, 20, 42, 0, 0, app.IST)
		now := func() time.Time { mu.Lock(); defer mu.Unlock(); tick = tick.Add(time.Second); return tick }
		svc := app.New(pp, now, st)
		if err := svc.Load(ctx); err != nil {
			t.Fatal(err)
		}
		srv := httptest.NewServer(httpapi.New(svc, pp))
		return srv, func() { srv.Close(); closeDB() }
	}
	srv, stop := start()

	type phone struct{ token string }
	call := func(p *phone, method, path string, body any, want int) map[string]any {
		t.Helper()
		var rd io.Reader
		if body != nil {
			b, _ := json.Marshal(body)
			rd = bytes.NewReader(b)
		}
		req, _ := http.NewRequest(method, srv.URL+path, rd)
		if p != nil && p.token != "" {
			req.Header.Set("Authorization", "Bearer "+p.token)
		}
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		raw, _ := io.ReadAll(res.Body)
		if res.StatusCode != want {
			t.Fatalf("%s %s: want %d, got %d: %s", method, path, want, res.StatusCode, raw)
		}
		var out any
		_ = json.Unmarshal(raw, &out)
		if m, ok := out.(map[string]any); ok {
			return m
		}
		return map[string]any{"list": out}
	}
	num := func(v any) int64 { return int64(v.(float64)) }

	asha, dev := &phone{}, &phone{}

	// Sign up on two phones. The first screen only asks for the number.
	if call(nil, "POST", "/api/auth/check-phone", map[string]string{"phone": "98765 43210"}, 201)["exists"] != false {
		t.Fatal("new number should not exist")
	}
	asha.token = call(nil, "POST", "/api/auth/register", map[string]string{"name": "Asha", "phone": "9876543210", "pin": "246810"}, 201)["token"].(string)
	dev.token = call(nil, "POST", "/api/auth/register", map[string]string{"name": "Dev", "phone": "+91 91234 56780", "pin": "135792"}, 201)["token"].(string)
	call(nil, "GET", "/api/me", nil, 401)

	// Asha adds money with PayPal (mock approves straight away).
	dep := call(asha, "POST", "/api/topups", map[string]any{"amount_paise": 500000}, 201)
	call(asha, "POST", fmt.Sprintf("/api/deposits/%s/capture", dep["paypal_order_id"]), nil, 201)
	call(dev, "POST", fmt.Sprintf("/api/deposits/%s/capture", dep["paypal_order_id"]), nil, 404) // not Dev's

	// Asha finds Dev by phone and pays him.
	devUser := call(asha, "GET", "/api/users/lookup?phone=9123456780", nil, 200)
	devID := devUser["id"].(string)
	call(asha, "POST", "/api/payments/personal", map[string]any{"description": "Chai", "amount_paise": 12000, "payee_user_id": devID}, 201)
	if b := num(call(dev, "GET", "/api/me", nil, 200)["personal_balance_paise"]); b != 12000 {
		t.Fatalf("Dev balance %d", b)
	}
	if call(dev, "GET", "/api/me", nil, 200)["unread_alerts"].(float64) < 1 {
		t.Fatal("Dev should have an unread alert")
	}

	// Dev asks Asha for ₹200; Asha pays from her phone.
	ashaID := call(asha, "GET", "/api/me", nil, 200)["user"].(map[string]any)["id"].(string)
	mr := call(dev, "POST", "/api/money-requests", map[string]any{"payer_id": ashaID, "amount_paise": 20000, "note": "Movie"}, 201)
	call(asha, "POST", "/api/money-requests/"+mr["id"].(string)+"/pay", nil, 201)

	// Asha plans a trip with Dev; Dev sees it on his phone.
	trip := call(asha, "POST", "/api/trips", map[string]any{"name": "Goa trip", "place": "Goa",
		"start": "2026-10-12T00:00:00+05:30", "end": "2026-10-16T00:00:00+05:30", "members": []string{devID},
		"deposit_target_paise": 300000, "budgets_paise": map[string]int{"food": 200000}}, 201)
	tripID := trip["id"].(string)
	if len(call(dev, "GET", "/api/trips", nil, 200)["list"].([]any)) != 1 {
		t.Fatal("Dev should see the trip")
	}

	// The assistant drafts, Asha confirms, Dev pays his request with PayPal.
	plan := call(asha, "POST", "/api/trips/"+tripID+"/assistant/plan", map[string]any{"instruction": "Collect ₹3,000 from everyone by 20 Oct"}, 201)
	call(asha, "POST", "/api/trips/"+tripID+"/assistant/plans/"+plan["id"].(string)+"/confirm", nil, 201)
	call(asha, "POST", "/api/trips/"+tripID+"/deposits", map[string]any{"amount_paise": 300000, "source": "balance"}, 201)
	devDep := call(dev, "POST", "/api/trips/"+tripID+"/deposits", map[string]any{"amount_paise": 300000}, 201)

	// Restart: everything must come back from the database.
	if dbURL != "" {
		stop()
		srv, stop = start()
	}
	call(dev, "POST", fmt.Sprintf("/api/deposits/%s/capture", devDep["paypal_order_id"]), nil, 201)
	reqs := call(asha, "GET", "/api/trips/"+tripID+"/requests", nil, 200)["list"].([]any)
	if reqs[0].(map[string]any)["status"] != "paid" {
		t.Fatalf("Dev's request should be paid: %v", reqs[0])
	}

	// Dev paid dinner by UPI; the wallet pays him back. First a budget warning.
	dinner := map[string]any{"description": "Dinner", "category": "food", "amount_paise": 184000, "payee": "Beach shack", "mode": "reimburse"}
	if call(dev, "POST", "/api/trips/"+tripID+"/expenses", dinner, 409)["error"].(map[string]any)["code"] != "budget_warning" {
		t.Fatal("expected budget_warning")
	}
	dinner["confirm_over_budget"] = true
	call(dev, "POST", "/api/trips/"+tripID+"/expenses", dinner, 201)

	// Settle: what is left goes back to both balances.
	call(dev, "POST", "/api/trips/"+tripID+"/settle", nil, 403)
	st := call(asha, "POST", "/api/trips/"+tripID+"/settle", nil, 201)
	if num(st["refund_paise"]) != 600000-184000 {
		t.Fatalf("refund %v", st["refund_paise"])
	}
	// Asha: 5000 - 120 - 200 - 3000 + 2080 = 3760. Dev: 120 + 200 + 1840 + 2080 = 4240.
	if b := num(call(asha, "GET", "/api/me", nil, 200)["personal_balance_paise"]); b != 376000 {
		t.Fatalf("Asha balance %d", b)
	}
	if b := num(call(dev, "GET", "/api/me", nil, 200)["personal_balance_paise"]); b != 424000 {
		t.Fatalf("Dev balance %d", b)
	}
	if len(call(dev, "GET", "/api/history", nil, 200)["list"].([]any)) < 4 {
		t.Fatal("Dev's history is short")
	}
	// Sign out on one phone ends that session only.
	call(dev, "POST", "/api/auth/logout", nil, 201)
	call(dev, "GET", "/api/me", nil, 401)
	call(asha, "GET", "/api/me", nil, 200)
	stop()
}
