package httpapi_test

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/app"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/httpapi"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/paypal"
)

// testServer is an in-memory server with a fixed clock.
func testServer(t *testing.T) *httptest.Server {
	t.Helper()
	pp := &paypal.Mock{}
	now := func() time.Time { return time.Date(2026, 10, 13, 20, 42, 0, 0, app.IST) }
	svc := app.New(pp, now, nil)
	if err := svc.Load(context.Background()); err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(httpapi.New(svc, pp))
	t.Cleanup(srv.Close)
	return srv
}

// send makes one call and returns the status and the decoded body.
func send(t *testing.T, srv *httptest.Server, token, key, method, path string, body any) (int, map[string]any) {
	t.Helper()
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, srv.URL+path, rd)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	if key != "" {
		req.Header.Set("Idempotency-Key", key)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Error(err)
		return 0, nil
	}
	defer res.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(res.Body).Decode(&out)
	return res.StatusCode, out
}

func signUp(t *testing.T, srv *httptest.Server, name, phone string) (token, id string) {
	t.Helper()
	st, out := send(t, srv, "", "", "POST", "/api/auth/register", map[string]string{"name": name, "phone": phone, "pin": "246810"})
	if st != 201 {
		t.Fatalf("register %s: %d %v", name, st, out)
	}
	return out["token"].(string), out["user"].(map[string]any)["id"].(string)
}

// A double tap sends the same payment twice at the same moment. With one
// Idempotency-Key it must pay once.
func TestSameKeyAtOncePaysOnce(t *testing.T) {
	srv := testServer(t)
	asha, _ := signUp(t, srv, "Asha", "9876543210")
	dev, devID := signUp(t, srv, "Dev", "9123456780")
	_, dep := send(t, srv, asha, "", "POST", "/api/topups", map[string]any{"amount_paise": 500000})
	send(t, srv, asha, "", "POST", fmt.Sprintf("/api/deposits/%s/capture", dep["paypal_order_id"]), nil)

	var wg sync.WaitGroup
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			send(t, srv, asha, "tap-1", "POST", "/api/payments/personal", map[string]any{"description": "Chai", "amount_paise": 10000, "payee_user_id": devID})
		}()
	}
	wg.Wait()
	_, me := send(t, srv, dev, "", "GET", "/api/me", nil)
	if b := me["personal_balance_paise"].(float64); b != 10000 {
		t.Fatalf("Dev got %v paise from one payment sent with one key", b)
	}
}

// Someone who learns another person's Idempotency-Key cannot replay their
// sign-in and get their token.
func TestSignInIsNeverReplayed(t *testing.T) {
	srv := testServer(t)
	signUp(t, srv, "Asha", "9876543210")
	st, first := send(t, srv, "", "k-login", "POST", "/api/auth/login", map[string]string{"phone": "9876543210", "pin": "246810"})
	if st != 201 {
		t.Fatalf("login %d %v", st, first)
	}
	st, second := send(t, srv, "", "k-login", "POST", "/api/auth/login", map[string]string{"phone": "9876543210", "pin": "000000"})
	if st == 201 || second["token"] == first["token"] {
		t.Fatalf("a wrong PIN with the same key got %d and the token back", st)
	}
}

// A bad body gets a plain answer that does not show the server's Go types.
func TestBadJSONDoesNotShowInternals(t *testing.T) {
	srv := testServer(t)
	asha, _ := signUp(t, srv, "Asha", "9876543210")
	for _, raw := range []string{`{"amount_paise":"lots"}`, `{"amount_paise":`, `[1,2]`} {
		req, _ := http.NewRequest("POST", srv.URL+"/api/topups", bytes.NewReader([]byte(raw)))
		req.Header.Set("Authorization", "Bearer "+asha)
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		body, _ := io.ReadAll(res.Body)
		res.Body.Close()
		if res.StatusCode != 400 || bytes.Contains(body, []byte("Go ")) || bytes.Contains(body, []byte("domain.")) || bytes.Contains(body, []byte("struct")) {
			t.Fatalf("%s: %d %s", raw, res.StatusCode, body)
		}
	}
}

// The web app's DELETE (clear the AI chat) must pass the CORS preflight.
func TestCORSAllowsDelete(t *testing.T) {
	srv := testServer(t)
	req, _ := http.NewRequest("OPTIONS", srv.URL+"/api/assistant/messages", nil)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if !bytes.Contains([]byte(res.Header.Get("Access-Control-Allow-Methods")), []byte("DELETE")) {
		t.Fatalf("allowed methods %q", res.Header.Get("Access-Control-Allow-Methods"))
	}
}
