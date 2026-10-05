package app

import (
	"context"
	"testing"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/ai"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
)

// quickPeople signs up "you" plus three people you have asked for money,
// so they are your contacts. Two of them are called Dev.
func quickPeople(t *testing.T, s *Service) (you, asha, devM, devK string) {
	t.Helper()
	you = register(t, s, "Rahul Kumar", "9000000001")
	asha = register(t, s, "Asha Rao", "9000000002")
	devM = register(t, s, "Dev Mehta", "9000000003")
	devK = register(t, s, "Dev Kumar", "9000000004")
	register(t, s, "Stranger", "9000000005")
	for _, p := range []string{asha, devM, devK} {
		must[MoneyRequestView](t)(s.RequestMoney(you, MoneyRequestInput{PayerID: p, Amount: domain.Rupees(1), Note: "hi"}))
	}
	return
}

func TestQuickPayRules(t *testing.T) {
	s, _, _ := newTestService(t, nil)
	you, asha, devM, _ := quickPeople(t, s)
	ctx := context.Background()
	read := func(text string) QuickPayResult { return must[QuickPayResult](t)(s.QuickPay(ctx, you, text)) }

	q := read("pay asha 200 for coffee")
	if q.Action != "pay" || q.Person == nil || q.Person.ID != asha || q.Amount != domain.Rupees(200) || q.Note != "coffee" || !q.Ready() || q.Source != "rules" {
		t.Fatalf("%+v", q)
	}
	if q := read("Ask Dev Mehta for 1.5k for the cab to airport"); q.Action != "request" || q.Person == nil || q.Person.ID != devM ||
		q.Amount != domain.Rupees(1500) || q.Note != "the cab to airport" {
		t.Fatalf("%+v", q)
	}
	if q := read("send ₹1,250.50 to dev"); q.Person != nil || len(q.Choices) != 2 || q.Amount != 125050 || q.Reply != "Which one did you mean?" {
		t.Fatalf("two Devs should both be offered: %+v", q)
	}
	if q := read("pay 90000 00005 300"); q.Person == nil || q.Person.Name != "Stranger" || q.Amount != domain.Rupees(300) {
		t.Fatalf("by number: %+v", q)
	}
	if q := read("pay 9876500000 300"); q.Person != nil || q.Reply != "+91 9876500000 is not on Pointy yet. Ask them to join, then try again." {
		t.Fatalf("unknown number: %+v", q)
	}
	if q := read("pay asha"); q.Amount != 0 || q.Reply != "How much for Asha?" {
		t.Fatalf("no amount: %+v", q)
	}
	if q := read("pay 300 for lunch"); q.Person != nil || q.Note != "lunch" {
		t.Fatalf("no person: %+v", q)
	}
	if q := read("pay asha 50000000"); q.Amount != 0 {
		t.Fatalf("over the limit should be dropped: %+v", q)
	}
	if _, err := s.QuickPay(ctx, you, "   "); code(err) != "invalid" {
		t.Fatalf("empty: %v", err)
	}
}

func TestQuickPayUsesTheModel(t *testing.T) {
	s, _, _ := newTestService(t, nil)
	you, asha, _, _ := quickPeople(t, s)
	f := &fakeAI{quick: ai.QuickPay{Understood: true, Action: "pay", Person: "Asha Rao", Amount: "200", Note: "coffee", Reply: "Pay Asha ₹200 for coffee?"}}
	s.SetAssistant(f)
	q := must[QuickPayResult](t)(s.QuickPay(context.Background(), you, "give ashu two hundred for coffee"))
	if q.Source != "ai" || q.Person == nil || q.Person.ID != asha || q.Amount != domain.Rupees(200) || q.Reply != "Pay Asha ₹200 for coffee?" {
		t.Fatalf("%+v", q)
	}
	if len(f.quickIn.Contacts) != 3 {
		t.Fatalf("contacts sent to the model: %v", f.quickIn.Contacts)
	}

	// A name the model made up is not paid.
	f.quick = ai.QuickPay{Understood: true, Action: "pay", Person: "Ravi", Amount: "100"}
	if q := must[QuickPayResult](t)(s.QuickPay(context.Background(), you, "pay ravi 100")); q.Person != nil || q.Reply == "" {
		t.Fatalf("unknown name: %+v", q)
	}

	// The model failing falls back to the rules.
	f.err = context.DeadlineExceeded
	if q := must[QuickPayResult](t)(s.QuickPay(context.Background(), you, "pay asha 200")); q.Source != "rules" || q.Person == nil {
		t.Fatalf("fallback: %+v", q)
	}
}
