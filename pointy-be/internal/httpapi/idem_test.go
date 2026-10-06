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

type idemClient struct {
	t   *testing.T
	url string
}

func newIdemServer(t *testing.T) *idemClient {
	t.Helper()
	pp := &paypal.Mock{}
	svc := app.New(pp, func() time.Time { return time.Date(2026, 10, 13, 20, 42, 0, 0, app.IST) }, nil)
	if err := svc.Load(context.Background()); err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(httpapi.New(svc, pp))
	t.Cleanup(srv.Close)
	return &idemClient{t, srv.URL}
}

func (c *idemClient) do(token, key, method, path string, body any) (int, map[string]any) {
	c.t.Helper()
	b, _ := json.Marshal(body)
	req, _ := http.NewRequest(method, c.url+path, bytes.NewReader(b))
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	if key != "" {
		req.Header.Set("Idempotency-Key", key)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		c.t.Fatal(err)
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(res.Body)
	out := map[string]any{}
	_ = json.Unmarshal(raw, &out)
	return res.StatusCode, out
}

func (c *idemClient) register(name, phone string) (token, id string) {
	c.t.Helper()
	st, out := c.do("", "", "POST", "/api/auth/register", map[string]string{"name": name, "phone": phone, "pin": "246810"})
	if st != 201 {
		c.t.Fatalf("register: %d %v", st, out)
	}
	return out["token"].(string), out["user"].(map[string]any)["id"].(string)
}

func (c *idemClient) topUp(token string, paise int) {
	c.t.Helper()
	_, dep := c.do(token, "", "POST", "/api/topups", map[string]any{"amount_paise": paise})
	if st, out := c.do(token, "", "POST", fmt.Sprintf("/api/deposits/%s/capture", dep["paypal_order_id"]), nil); st != 201 {
		c.t.Fatalf("capture: %d %v", st, out)
	}
}

func (c *idemClient) balance(token string) int64 {
	c.t.Helper()
	_, me := c.do(token, "", "GET", "/api/me", nil)
	return int64(me["personal_balance_paise"].(float64))
}

// A double tap sends the same payment twice at the same moment, with one
// key: it must pay once.
func TestIdempotencyConcurrentRetriesPayOnce(t *testing.T) {
	c := newIdemServer(t)
	asha, _ := c.register("Asha", "9876543210")
	_, devID := c.register("Dev", "9123456780")
	c.topUp(asha, 100000)
	pay := map[string]any{"description": "Chai", "amount_paise": 1000, "payee_user_id": devID}
	var wg sync.WaitGroup
	codes := make([]int, 10)
	for i := range codes {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			codes[i], _ = c.do(asha, "tap-1", "POST", "/api/payments/personal", pay)
		}(i)
	}
	wg.Wait()
	if b := c.balance(asha); b != 100000-1000 {
		t.Fatalf("balance %d after one payment sent ten times with one key (codes %v)", b, codes)
	}
	for _, code := range codes {
		if code != 201 {
			t.Fatalf("every retry should get the first answer, got %v", codes)
		}
	}
}

// Sign-in has no caller yet. A second person sending the same key must not
// be handed the first person's token.
func TestIdempotencyNeverReplaysAnotherCallersSignIn(t *testing.T) {
	c := newIdemServer(t)
	c.register("Asha", "9876543210")
	if st, _ := c.do("", "k-1", "POST", "/api/auth/login", map[string]string{"phone": "9876543210", "pin": "246810"}); st != 201 {
		t.Fatalf("login %d", st)
	}
	st, out := c.do("", "k-1", "POST", "/api/auth/login", map[string]string{"phone": "9876543210", "pin": "000001"})
	if st == 201 || out["token"] != nil {
		t.Fatalf("wrong PIN with a reused key got %d %v", st, out)
	}
}

// The same key with a different request is a mistake by the client: it is
// refused, not answered with the first request's result.
func TestIdempotencyKeyReusedWithDifferentBody(t *testing.T) {
	c := newIdemServer(t)
	asha, _ := c.register("Asha", "9876543210")
	_, devID := c.register("Dev", "9123456780")
	c.topUp(asha, 100000)
	if st, _ := c.do(asha, "k-2", "POST", "/api/payments/personal", map[string]any{"description": "Chai", "amount_paise": 1000, "payee_user_id": devID}); st != 201 {
		t.Fatal(st)
	}
	st, out := c.do(asha, "k-2", "POST", "/api/payments/personal", map[string]any{"description": "Rent", "amount_paise": 50000, "payee_user_id": devID})
	if st != 422 {
		t.Fatalf("different body, same key: %d %v", st, out)
	}
	// The same body again still replays.
	if st, _ := c.do(asha, "k-2", "POST", "/api/payments/personal", map[string]any{"description": "Chai", "amount_paise": 1000, "payee_user_id": devID}); st != 201 {
		t.Fatal(st)
	}
	if b := c.balance(asha); b != 99000 {
		t.Fatalf("balance %d", b)
	}
}

// Another person using the same key runs their own request.
func TestIdempotencyKeyIsPerUser(t *testing.T) {
	c := newIdemServer(t)
	asha, ashaID := c.register("Asha", "9876543210")
	dev, devID := c.register("Dev", "9123456780")
	c.topUp(asha, 100000)
	c.topUp(dev, 100000)
	c.do(asha, "same", "POST", "/api/payments/personal", map[string]any{"description": "Chai", "amount_paise": 1000, "payee_user_id": devID})
	st, out := c.do(dev, "same", "POST", "/api/payments/personal", map[string]any{"description": "Chai", "amount_paise": 1000, "payee_user_id": ashaID})
	if st != 201 || out["paid_by"] == ashaID {
		t.Fatalf("Dev got Asha's answer: %d %v", st, out)
	}
	if c.balance(asha) != 100000 || c.balance(dev) != 100000 {
		t.Fatal("both payments should have happened")
	}
}
