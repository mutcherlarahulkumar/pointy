package app

import (
	"context"
	"strings"
	"testing"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/ai"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
)

func TestChatRulesAnswerFromTheAccount(t *testing.T) {
	s, _, _ := newTestService(t, nil)
	you, asha, _, _ := quickPeople(t, s)
	topUp(t, s, you, 2000)
	must[*domain.Expense](t)(s.PayPersonal(you, ExpenseInput{PayeeUserID: asha, Description: "Lunch", Category: domain.Food, Amount: domain.Rupees(300)}))
	must[MoneyRequestView](t)(s.RequestMoney(asha, MoneyRequestInput{PayerID: you, Amount: domain.Rupees(150), Note: "Cab"}))
	ctx := context.Background()
	ask := func(text string) *domain.ChatMessage {
		t.Helper()
		turn := must[[]*domain.ChatMessage](t)(s.Chat(ctx, you, text))
		if len(turn) != 2 || turn[0].Role != "user" || turn[1].Role != "assistant" || turn[1].Source != "rules" {
			t.Fatalf("turn %+v", turn)
		}
		return turn[1]
	}

	if r := ask("What's my balance?"); !strings.Contains(r.Text, "₹1,700") {
		t.Fatalf("balance: %q", r.Text)
	}
	if r := ask("how much did I spend this week"); !strings.Contains(r.Text, "₹300") || r.Action == nil || r.Action.Screen != "insights" {
		t.Fatalf("spend: %+v", r)
	}
	if r := ask("who do I owe?"); !strings.Contains(r.Text, "Asha Rao asks you for ₹150 for Cab") || r.Action.Screen != "requests" {
		t.Fatalf("owe: %+v", r)
	}
	r := ask("pay asha 200 for chai")
	if r.Action == nil || r.Action.Type != "pay" || r.Action.Person.ID != asha || r.Action.Amount != domain.Rupees(200) || r.Action.Label != "Review: pay Asha ₹200" {
		t.Fatalf("pay: %+v %+v", r, r.Action)
	}
	if r := ask("tell me a joke"); r.Action != nil || !strings.Contains(r.Text, "never send money") {
		t.Fatalf("fallback: %+v", r)
	}
	// The conversation is kept, oldest first, and can be cleared.
	if h := s.ChatHistory(you); len(h) != 10 || h[0].Text != "What's my balance?" {
		t.Fatalf("history %d", len(h))
	}
	if err := s.ClearChat(you); err != nil || len(s.ChatHistory(you)) != 0 {
		t.Fatalf("clear: %v", err)
	}
	if _, err := s.Chat(ctx, you, "  "); code(err) != "invalid" {
		t.Fatalf("empty: %v", err)
	}
}

func TestChatUsesTheModelWithFactsAndChecksItsAction(t *testing.T) {
	s, _, _ := newTestService(t, nil)
	you, asha, _, _ := quickPeople(t, s)
	topUp(t, s, you, 1000)
	f := &fakeAI{chat: ai.ChatReply{Reply: "You have ₹1,000. Paying Asha?", Action: "pay", Person: "Asha Rao", Amount: "250", Note: "dinner"}}
	s.SetAssistant(f)
	turn := must[[]*domain.ChatMessage](t)(s.Chat(context.Background(), you, "send asha 250 for dinner"))
	r := turn[1]
	if r.Source != "ai" || r.Action == nil || r.Action.Person.ID != asha || r.Action.Amount != domain.Rupees(250) {
		t.Fatalf("%+v %+v", r, r.Action)
	}
	facts := f.chatIn.Facts.(ChatFacts)
	if facts.Balance != "₹1,000" || len(facts.People) != 3 || f.chatIn.Message != "send asha 250 for dinner" {
		t.Fatalf("facts %+v", facts)
	}

	// A person the model made up gets no button; a made-up screen neither.
	f.chat = ai.ChatReply{Reply: "Sure.", Action: "pay", Person: "Ravi", Amount: "100"}
	if r := must[[]*domain.ChatMessage](t)(s.Chat(context.Background(), you, "pay ravi"))[1]; r.Action != nil {
		t.Fatalf("made-up person: %+v", r.Action)
	}
	f.chat = ai.ChatReply{Reply: "Opening.", Action: "open", Screen: "admin"}
	if r := must[[]*domain.ChatMessage](t)(s.Chat(context.Background(), you, "open admin"))[1]; r.Action != nil {
		t.Fatalf("made-up screen: %+v", r.Action)
	}
	// Earlier lines go with the next question.
	if len(f.chatIn.Conversation) != 4 {
		t.Fatalf("conversation sent: %d", len(f.chatIn.Conversation))
	}
	// A failing model falls back to the rules.
	f.err = context.DeadlineExceeded
	if r := must[[]*domain.ChatMessage](t)(s.Chat(context.Background(), you, "balance?"))[1]; r.Source != "rules" || !strings.Contains(r.Text, "₹1,000") {
		t.Fatalf("fallback: %+v", r)
	}
}
