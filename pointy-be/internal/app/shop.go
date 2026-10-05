package app

import (
	"context"
	"errors"
	"log"
	"net/http"
	"regexp"
	"strings"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/ai"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
)

// Shopper finds products (Channel3 in production, a fake in tests).
type Shopper interface {
	Search(ctx context.Context, query string, maxPaise Paise, limit int) ([]domain.ShopItem, error)
}

// SetShopper turns on product search.
func (s *Service) SetShopper(sh Shopper) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.shop = sh
}

const shopResults = 6

// Shop finds products for query, at or under maxPaise when above zero.
func (s *Service) Shop(ctx context.Context, query string, maxPaise Paise) ([]domain.ShopItem, error) {
	query = strings.Join(strings.Fields(query), " ")
	if query == "" || len(query) > 120 {
		return nil, domain.Invalid("say what to look for, for example: sunscreen spf 50")
	}
	s.mu.Lock()
	sh := s.shop
	s.mu.Unlock()
	if sh == nil {
		return nil, &domain.Error{Status: http.StatusServiceUnavailable, Code: "shop_off", Message: "shopping is not set up on this server"}
	}
	cctx, cancel := context.WithTimeout(ctx, aiTimeout)
	defer cancel()
	items, err := sh.Search(cctx, query, maxPaise, shopResults)
	if err != nil {
		log.Printf("shop: %v", err)
		return nil, &domain.Error{Status: http.StatusBadGateway, Code: "shop_error", Message: "could not search the shops right now; try again"}
	}
	return items, nil
}

// shopAction runs a search for the chat and wraps the results as a button
// row. The note explains an empty or failed search.
func (s *Service) shopAction(ctx context.Context, query string, maxPaise Paise) (*domain.ChatAction, string) {
	items, err := s.Shop(ctx, query, maxPaise)
	switch {
	case err != nil && errCode(err) == "shop_off":
		return nil, "Shopping is not switched on for this Pointy server yet."
	case err != nil:
		return nil, "I could not reach the shops just now. Try again in a moment."
	case len(items) == 0:
		return nil, "I found nothing in stock for that. Try other words or a higher budget."
	}
	return &domain.ChatAction{Type: "shop", Label: "Picks for " + query, Query: query, Items: items}, ""
}

// errCode is the code of a domain error, or "".
func errCode(err error) string {
	var de *domain.Error
	if errors.As(err, &de) {
		return de.Code
	}
	return ""
}

var (
	// A shopping request starts with what to do: "find sunscreen…",
	// "buy a power bank…", unless it is about the person's own money.
	reShop       = regexp.MustCompile(`(?i)^\s*(please\s+|can you\s+|could you\s+|pointy,?\s+)*(buy|shop( for)?|find( me)?|look(ing)? for|search( for)?|get me|recommend|i need to buy|i want to buy)\b`)
	reShopNot    = regexp.MustCompile(`(?i)\b(payments?|balance|spent|spend|owe|owes|requests?|history|transactions?)\b`)
	reShopBudget = regexp.MustCompile(`(?i)\b(?:under|below|within|less than|upto|up to|max)\s*(?:₹|rs\.?|inr)?\s*(\d[\d,]*(?:\.\d{1,2})?)\s*(k\b)?`)
	reShopFiller = regexp.MustCompile(`(?i)\b(can you|could you|please|pointy|i want to|i need to|i'd like to|help me|buy|shop(ping)?( for)?|find me|find|look(ing)? for|search( for)?|get me|recommend|some|a few|for (our|my|the) [a-z]+ trip|for (our|my) trip)\b`)
)

// isShopping says whether a sentence asks to find something to buy.
func isShopping(text string) bool { return reShop.MatchString(text) && !reShopNot.MatchString(text) }

// shopRules reads "find sunscreen for our Goa trip under 1500" without a
// model: what to look for, and the budget.
func shopRules(text string) (query string, maxPaise Paise) {
	if m := reShopBudget.FindStringSubmatch(text); m != nil {
		if v, ok := ai.ParseRupees(m[1]); ok {
			if m[2] != "" {
				v *= 1000
			}
			maxPaise = Paise(v)
		}
		text = strings.Replace(text, m[0], " ", 1)
	}
	q := reShopFiller.ReplaceAllString(text, " ")
	q = strings.Trim(strings.Join(strings.Fields(q), " "), " .,!?")
	return q, maxPaise
}
