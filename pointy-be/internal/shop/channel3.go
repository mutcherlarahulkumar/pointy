// Package shop finds products to buy through Channel3's product search
// (https://trychannel3.com), so Pointy AI can answer "find sunscreen for
// our Goa trip under ₹1,500". Pointy never buys anything: the person opens
// the shop's page, and can then split the cost or add it to a trip.
package shop

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
)

// DefaultBaseURL is Channel3's API.
const DefaultBaseURL = "https://api.trychannel3.com"

// Channel3 searches Channel3's catalogue.
type Channel3 struct {
	BaseURL string
	APIKey  string
	// RupeesPerDollar100 is the demo exchange rate in hundredths of a rupee
	// per dollar (85 rupees = 8500), the same rate PayPal checkout uses.
	RupeesPerDollar100 int64
	HTTP               *http.Client
}

// New makes a client. rate is POINTY_INR_PER_UNIT ("85").
func New(apiKey, rate string) (*Channel3, error) {
	r, ok := decimalHundredths(rate)
	if !ok || r <= 0 {
		return nil, fmt.Errorf("shop: POINTY_INR_PER_UNIT %q is not a positive number", rate)
	}
	return &Channel3{BaseURL: DefaultBaseURL, APIKey: apiKey, RupeesPerDollar100: r, HTTP: &http.Client{Timeout: 20 * time.Second}}, nil
}

type searchRequest struct {
	Query   string         `json:"query"`
	Limit   int            `json:"limit"`
	Filters map[string]any `json:"filters,omitempty"`
}

type searchResponse struct {
	Products []struct {
		ID     string `json:"id"`
		Title  string `json:"title"`
		Brands []struct {
			Name string `json:"name"`
		} `json:"brands"`
		Images []struct {
			URL    string `json:"url"`
			IsMain bool   `json:"is_main_image"`
		} `json:"images"`
		Offers []struct {
			URL          string `json:"url"`
			Domain       string `json:"domain"`
			Availability string `json:"availability"`
			Price        struct {
				Price          json.Number  `json:"price"`
				Currency       string       `json:"currency"`
				CompareAtPrice *json.Number `json:"compare_at_price"`
			} `json:"price"`
		} `json:"offers"`
	} `json:"products"`
}

// Search finds up to limit in-stock products for query, at or under
// maxPaise when it is above zero.
func (c *Channel3) Search(ctx context.Context, query string, maxPaise domain.Paise, limit int) ([]domain.ShopItem, error) {
	req := searchRequest{Query: query, Limit: limit, Filters: map[string]any{"availability": []string{"InStock"}}}
	if maxPaise > 0 {
		// Whole dollars, rounded up, so nothing at the limit is cut off.
		cents := int64(maxPaise) * 100 / c.RupeesPerDollar100
		req.Filters["price"] = map[string]any{"max_price": (cents + 99) / 100}
	}
	body, _ := json.Marshal(req)
	hr, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(c.BaseURL, "/")+"/v1/search", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	hr.Header.Set("Content-Type", "application/json")
	hr.Header.Set("x-api-key", c.APIKey)
	res, err := c.HTTP.Do(hr)
	if err != nil {
		return nil, fmt.Errorf("shop: %w", err)
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(res.Body, 4<<20))
	if res.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("shop: channel3 answered %d: %.200s", res.StatusCode, raw)
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber() // prices stay exact decimals, never floats
	var out searchResponse
	if err := dec.Decode(&out); err != nil {
		return nil, errors.New("shop: channel3 answer is not the expected JSON")
	}

	var items []domain.ShopItem
	for _, p := range out.Products {
		var best *domain.ShopItem
		for _, o := range p.Offers {
			if o.Availability != "" && o.Availability != "InStock" {
				continue
			}
			price, list, ok := c.toPaise(string(o.Price.Price), o.Price.Currency)
			if !ok || o.URL == "" || (maxPaise > 0 && price > maxPaise) {
				continue
			}
			if best != nil && price >= best.Price {
				continue
			}
			it := domain.ShopItem{ID: p.ID, Title: strings.TrimSpace(p.Title), Merchant: o.Domain, BuyURL: o.URL, Price: price, ListPrice: list}
			if o.Price.CompareAtPrice != nil {
				if was, _, ok := c.toPaise(string(*o.Price.CompareAtPrice), o.Price.Currency); ok && was > price {
					it.WasPrice = was
				}
			}
			best = &it
		}
		if best == nil {
			continue
		}
		if len(p.Brands) > 0 {
			best.Brand = p.Brands[0].Name
		}
		for i, im := range p.Images {
			if i == 0 || im.IsMain {
				best.ImageURL = im.URL
			}
			if im.IsMain {
				break
			}
		}
		items = append(items, *best)
	}
	return items, nil
}

// toPaise converts a shop price to rupee paise with whole-number maths.
// Dollars use the demo rate; rupee prices pass through. Other currencies
// are skipped.
func (c *Channel3) toPaise(price, currency string) (domain.Paise, string, bool) {
	cents, ok := decimalHundredths(price)
	if !ok || cents <= 0 {
		return 0, "", false
	}
	switch strings.ToUpper(currency) {
	case "USD", "":
		return domain.Paise(cents * c.RupeesPerDollar100 / 100), fmt.Sprintf("$%d.%02d", cents/100, cents%100), true
	case "INR":
		return domain.Paise(cents), fmt.Sprintf("₹%d.%02d", cents/100, cents%100), true
	}
	return 0, "", false
}

var reDecimal = regexp.MustCompile(`^(\d+)(?:\.(\d+))?$`)

// decimalHundredths reads "19.99" as 1999 without floating point; digits
// past the second decimal are dropped.
func decimalHundredths(s string) (int64, bool) {
	m := reDecimal.FindStringSubmatch(strings.TrimSpace(s))
	if m == nil {
		return 0, false
	}
	whole, err := strconv.ParseInt(m[1], 10, 64)
	if err != nil || whole > 1_000_000_000 {
		return 0, false
	}
	frac, _ := strconv.ParseInt((m[2] + "00")[:2], 10, 64)
	return whole*100 + frac, true
}
