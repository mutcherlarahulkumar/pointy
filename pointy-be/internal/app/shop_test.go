package app

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/ai"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
)

// fakeShop stands in for Channel3.
type fakeShop struct {
	items    []domain.ShopItem
	err      error
	query    string
	maxPaise Paise
}

func (f *fakeShop) Search(_ context.Context, query string, maxPaise Paise, _ int) ([]domain.ShopItem, error) {
	f.query, f.maxPaise = query, maxPaise
	return f.items, f.err
}

var sunscreen = domain.ShopItem{ID: "p1", Title: "Sunscreen SPF 50", Merchant: "b.com", BuyURL: "https://buy/b", Price: 148750, ListPrice: "$17.50"}

func TestShopRulesReadTheQueryAndBudget(t *testing.T) {
	for text, want := range map[string]struct {
		q   string
		max Paise
	}{
		"find sunscreen for our Goa trip under 1500":     {"sunscreen", domain.Rupees(1500)},
		"Can you buy a waterproof phone pouch below ₹2k": {"a waterproof phone pouch", domain.Rupees(2000)},
		"search for trekking poles":                      {"trekking poles", 0},
	} {
		if !isShopping(text) {
			t.Fatalf("%q should be shopping", text)
		}
		q, max := shopRules(text)
		if q != want.q || max != want.max {
			t.Fatalf("%q -> %q %d", text, q, max)
		}
	}
	for _, text := range []string{"find my last payment", "what's my balance", "pay dev 200"} {
		if isShopping(text) {
			t.Fatalf("%q is not shopping", text)
		}
	}
}

func TestChatFindsProductsWithoutAModel(t *testing.T) {
	s, _, _ := newTestService(t, nil)
	you, _, _, _ := quickPeople(t, s)
	ctx := context.Background()

	// Not switched on: says so, no button.
	r := must[[]*domain.ChatMessage](t)(s.Chat(ctx, you, "find sunscreen under 1500"))[1]
	if r.Action != nil || !strings.Contains(r.Text, "not switched on") {
		t.Fatalf("off: %+v", r)
	}
	if _, err := s.Shop(ctx, "sunscreen", 0); code(err) != "shop_off" {
		t.Fatalf("shop off: %v", err)
	}

	f := &fakeShop{items: []domain.ShopItem{sunscreen}}
	s.SetShopper(f)
	r = must[[]*domain.ChatMessage](t)(s.Chat(ctx, you, "find sunscreen for our Goa trip under 1500"))[1]
	if r.Action == nil || r.Action.Type != "shop" || len(r.Action.Items) != 1 || r.Action.Items[0].Price != 148750 {
		t.Fatalf("picks: %+v", r.Action)
	}
	if f.query != "sunscreen" || f.maxPaise != domain.Rupees(1500) {
		t.Fatalf("searched %q under %d", f.query, f.maxPaise)
	}
	// The picks are saved with the conversation.
	h := s.ChatHistory(you)
	if last := h[len(h)-1]; last.Action == nil || len(last.Action.Items) != 1 {
		t.Fatalf("history lost the picks: %+v", last)
	}

	f.items = nil
	if r := must[[]*domain.ChatMessage](t)(s.Chat(ctx, you, "find gold bars"))[1]; r.Action != nil || !strings.Contains(r.Text, "found nothing") {
		t.Fatalf("empty: %+v", r)
	}
	f.err = errors.New("timeout")
	if r := must[[]*domain.ChatMessage](t)(s.Chat(ctx, you, "find a hat"))[1]; r.Action != nil || !strings.Contains(r.Text, "could not reach") {
		t.Fatalf("error: %+v", r)
	}
}

func TestChatModelCanAskForAShopSearch(t *testing.T) {
	s, _, _ := newTestService(t, nil)
	you, _, _, _ := quickPeople(t, s)
	sh := &fakeShop{items: []domain.ShopItem{sunscreen}}
	s.SetShopper(sh)
	f := &fakeAI{chat: ai.ChatReply{Reply: "Here are a few sunscreens.", Action: "shop", Query: "sunscreen spf 50", Amount: "1500"}}
	s.SetAssistant(f)
	r := must[[]*domain.ChatMessage](t)(s.Chat(context.Background(), you, "need something for the sun in goa"))[1]
	if r.Source != "ai" || r.Action == nil || r.Action.Type != "shop" || sh.query != "sunscreen spf 50" || sh.maxPaise != domain.Rupees(1500) {
		t.Fatalf("%+v %+v %q", r, r.Action, sh.query)
	}
	if !f.chatIn.Facts.(ChatFacts).ShoppingOn {
		t.Fatal("the model should be told shopping is on")
	}
}
