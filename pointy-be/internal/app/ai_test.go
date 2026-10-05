package app

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/ai"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
)

// fakeAI stands in for the language model.
type fakeAI struct {
	summaries   int
	summary     ai.Summary
	instruction ai.Instruction
	err         error
	lastInput   ai.InstructionInput
	receipt     ai.Receipt
	gotType     string
	quick       ai.QuickPay
	quickIn     ai.QuickPayInput
}

func (f *fakeAI) ParseQuickPay(_ context.Context, in ai.QuickPayInput) (ai.QuickPay, error) {
	f.quickIn = in
	return f.quick, f.err
}

func (f *fakeAI) ReadReceipt(_ context.Context, _ []byte, mediaType string) (ai.Receipt, error) {
	f.gotType = mediaType
	return f.receipt, f.err
}

func (f *fakeAI) Summarize(_ context.Context, facts ai.TripFacts) (ai.Summary, error) {
	f.summaries++
	if facts.Spent == "" || facts.TripName == "" {
		return ai.Summary{}, errors.New("facts are empty")
	}
	return f.summary, f.err
}

func (f *fakeAI) ParseInstruction(_ context.Context, in ai.InstructionInput) (ai.Instruction, error) {
	f.lastInput = in
	return f.instruction, f.err
}

func spendOnTrip(t *testing.T, s *Service, trip, who string) {
	t.Helper()
	topUp(t, s, who, 3000)
	must[TripView](t)(s.DepositFromBalance(trip, who, domain.Rupees(3000)))
	must[*domain.Expense](t)(s.AddExpense(trip, who, ExpenseInput{Description: "Taxi", Category: domain.Transport, Amount: domain.Rupees(600), Mode: ModeReimburse}))
}

func TestInsightsUseTheModelAndCacheIt(t *testing.T) {
	s, _, _ := newTestService(t, nil)
	a := register(t, s, "Asha", "9876543210")
	trip := goa(t, s, a)
	f := &fakeAI{summary: ai.Summary{Text: "Day 2 of 5 and taxis are the big cost.", Tip: "Share one cab tomorrow."}}
	s.SetAssistant(f)

	// Nothing spent: the template answers, the model is not called.
	if in := must[Insights](t)(s.Insights(context.Background(), trip, a)); in.SummarySource != "rules" || f.summaries != 0 {
		t.Fatalf("source %s, calls %d", in.SummarySource, f.summaries)
	}
	spendOnTrip(t, s, trip, a)
	in := must[Insights](t)(s.Insights(context.Background(), trip, a))
	if in.SummarySource != "ai" || in.Tip != "Share one cab tomorrow." || f.summaries != 1 {
		t.Fatalf("got %+v after %d calls", in, f.summaries)
	}
	must[Insights](t)(s.Insights(context.Background(), trip, a))
	if f.summaries != 1 {
		t.Fatal("unchanged numbers should reuse the cached summary")
	}
	must[*domain.Expense](t)(s.AddExpense(trip, a, ExpenseInput{Description: "Chai", Category: domain.Food, Amount: domain.Rupees(100), Mode: ModeReimburse}))
	must[Insights](t)(s.Insights(context.Background(), trip, a))
	if f.summaries != 2 {
		t.Fatal("new spending should ask for a fresh summary")
	}
}

func TestInsightsFallBackWhenTheModelFails(t *testing.T) {
	s, _, _ := newTestService(t, nil)
	a := register(t, s, "Asha", "9876543210")
	trip := goa(t, s, a)
	s.SetAssistant(&fakeAI{err: ai.ErrDeclined})
	spendOnTrip(t, s, trip, a)
	in := must[Insights](t)(s.Insights(context.Background(), trip, a))
	if in.SummarySource != "rules" || !strings.Contains(in.Summary, "₹600") {
		t.Fatalf("got %+v", in)
	}
}

func TestAssistantAsksOnlyThePeopleNamed(t *testing.T) {
	s, _, c := newTestService(t, nil)
	a := register(t, s, "Asha Rao", "9876543210")
	d := register(t, s, "Dev Mehta", "9123456780")
	m := register(t, s, "Meera", "9988776655")
	trip := goa(t, s, a, d, m)
	f := &fakeAI{instruction: ai.Instruction{Understood: true, PerPerson: "2,000", DueDate: "2026-10-16", MemberNames: []string{"dev", "Nobody"}, Reply: "I'll ask Dev for ₹2,000 by Friday."}}
	s.SetAssistant(f)

	p := must[*domain.Plan](t)(s.DraftPlan(context.Background(), trip, a, "ask dev for 2k by friday"))
	if p.Source != "ai" || p.PerPerson != domain.Rupees(2000) || p.Due.Day() != 16 || len(p.Items) != 1 || p.Items[0].UserID != d {
		t.Fatalf("plan %+v", p)
	}
	if p.Note == "" || len(f.lastInput.Members) != 3 || !strings.Contains(f.lastInput.Today, c.t.Format("2006-01-02")) {
		t.Fatalf("note %q, input %+v", p.Note, f.lastInput)
	}
	made := must[[]*domain.DepositRequest](t)(s.ConfirmPlan(trip, p.ID, a))
	if len(made) != 1 || made[0].UserID != d {
		t.Fatalf("only Dev should be asked: %+v", made)
	}
	_ = m
}

func TestAssistantAsksBackWhenItDoesNotUnderstand(t *testing.T) {
	s, _, _ := newTestService(t, nil)
	a := register(t, s, "Asha", "9876543210")
	trip := goa(t, s, a)
	s.SetAssistant(&fakeAI{instruction: ai.Instruction{Understood: false, Reply: "How much should each person put in?"}})
	_, err := s.DraftPlan(context.Background(), trip, a, "sort out the money")
	if code(err) != "invalid" || !strings.Contains(err.Error(), "How much should each person put in?") {
		t.Fatalf("got %v", err)
	}
}

func TestAssistantFallsBackToRules(t *testing.T) {
	s, _, _ := newTestService(t, nil)
	a := register(t, s, "Asha", "9876543210")
	d := register(t, s, "Dev", "9123456780")
	trip := goa(t, s, a, d)
	s.SetAssistant(&fakeAI{err: errors.New("network down")})
	p := must[*domain.Plan](t)(s.DraftPlan(context.Background(), trip, a, "Collect ₹2,500 from everyone by 20 Oct"))
	if p.Source != "rules" || p.PerPerson != domain.Rupees(2500) || len(p.Items) != 2 {
		t.Fatalf("plan %+v", p)
	}
}

// A real 1x1 PNG, so content sniffing sees an image.
var tinyPNG = []byte{0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0x0d, 0x49, 0x48, 0x44, 0x52, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 0x1f, 0x15, 0xc4, 0x89}

func TestScanReceipt(t *testing.T) {
	s, _, _ := newTestService(t, nil)
	if _, err := s.ScanReceipt(context.Background(), tinyPNG); code(err) != "ai_off" {
		t.Fatalf("without a model: %v", err)
	}
	f := &fakeAI{receipt: ai.Receipt{IsReceipt: true, Merchant: "Britto's", Total: "1,840.50", Currency: "INR", Date: "2026-10-12", Category: "food", Description: "Dinner at Britto's"}}
	s.SetAssistant(f)
	if _, err := s.ScanReceipt(context.Background(), []byte("not an image at all")); code(err) != "invalid" {
		t.Fatalf("text upload: %v", err)
	}
	r := must[ScannedReceipt](t)(s.ScanReceipt(context.Background(), tinyPNG))
	if r.Amount != 184050 || r.Category != domain.Food || r.Merchant != "Britto's" || r.Date != "2026-10-12" || f.gotType != "image/png" {
		t.Fatalf("got %+v (type %s)", r, f.gotType)
	}
	f.receipt.Currency = "USD"
	if _, err := s.ScanReceipt(context.Background(), tinyPNG); code(err) != "invalid" {
		t.Fatalf("dollar bill: %v", err)
	}
	f.receipt = ai.Receipt{IsReceipt: false}
	if _, err := s.ScanReceipt(context.Background(), tinyPNG); code(err) != "invalid" {
		t.Fatalf("not a receipt: %v", err)
	}
	f.receipt, f.err = ai.Receipt{}, ai.ErrDeclined
	if _, err := s.ScanReceipt(context.Background(), tinyPNG); code(err) != "invalid" {
		t.Fatalf("declined: %v", err)
	}
}
