package shop

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestSearchPicksTheCheapestInStockOfferAndConverts(t *testing.T) {
	var got map[string]any
	var key string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/search" || r.Method != http.MethodPost {
			t.Errorf("%s %s", r.Method, r.URL.Path)
		}
		key = r.Header.Get("x-api-key")
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &got)
		_, _ = w.Write([]byte(`{"products":[
		 {"id":"p1","title":"Sunscreen SPF 50","brands":[{"name":"Sunny"}],
		  "images":[{"url":"https://img/side.jpg"},{"url":"https://img/main.jpg","is_main_image":true}],
		  "offers":[
		   {"url":"https://buy/a","domain":"a.com","availability":"InStock","price":{"price":19.99,"currency":"USD","compare_at_price":24.5}},
		   {"url":"https://buy/b","domain":"b.com","availability":"InStock","price":{"price":17.5,"currency":"USD"}},
		   {"url":"https://buy/c","domain":"c.com","availability":"OutOfStock","price":{"price":3,"currency":"USD"}}]},
		 {"id":"p2","title":"Euro only","offers":[{"url":"https://buy/e","domain":"e.eu","availability":"InStock","price":{"price":9,"currency":"EUR"}}]},
		 {"id":"p3","title":"Too dear","offers":[{"url":"https://buy/d","domain":"d.com","availability":"InStock","price":{"price":40,"currency":"USD"}}]}
		]}`))
	}))
	defer srv.Close()
	c, err := New("k-test", "85")
	if err != nil {
		t.Fatal(err)
	}
	c.BaseURL = srv.URL

	items, err := c.Search(context.Background(), "sunscreen", 200000, 6) // under ₹2,000
	if err != nil {
		t.Fatal(err)
	}
	if key != "k-test" || got["query"] != "sunscreen" || got["limit"].(float64) != 6 {
		t.Fatalf("request: key %q body %v", key, got)
	}
	// ₹2,000 at ₹85/$ is $23.52, sent rounded up to whole dollars.
	if mp := got["filters"].(map[string]any)["price"].(map[string]any)["max_price"].(float64); mp != 24 {
		t.Fatalf("max_price %v", mp)
	}
	if len(items) != 1 {
		t.Fatalf("want only the sunscreen, got %+v", items)
	}
	it := items[0]
	// $17.50 at ₹85 = ₹1,487.50, from b.com, the cheapest one in stock.
	if it.Price != 148750 || it.Merchant != "b.com" || it.BuyURL != "https://buy/b" || it.ListPrice != "$17.50" ||
		it.Brand != "Sunny" || it.ImageURL != "https://img/main.jpg" || it.WasPrice != 0 {
		t.Fatalf("%+v", it)
	}
}

func TestSearchReportsErrors(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"detail":"bad key"}`))
	}))
	defer srv.Close()
	c, _ := New("bad", "85")
	c.BaseURL = srv.URL
	if _, err := c.Search(context.Background(), "x", 0, 5); err == nil {
		t.Fatal("want an error for 401")
	}
	if _, err := New("k", "abc"); err == nil {
		t.Fatal("want an error for a bad rate")
	}
}

func TestDecimalHundredths(t *testing.T) {
	for in, want := range map[string]int64{"19.99": 1999, "17.5": 1750, "3": 300, "0.999": 99} {
		if got, ok := decimalHundredths(in); !ok || got != want {
			t.Fatalf("%q -> %d %v", in, got, ok)
		}
	}
	if _, ok := decimalHundredths("-1"); ok {
		t.Fatal("negative should fail")
	}
}
