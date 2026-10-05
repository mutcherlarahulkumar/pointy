package app

import (
	"testing"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/ai"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
)

func TestSplitByItemsSharesExtrasByWhatEachHad(t *testing.T) {
	s, _, _ := newTestService(t, nil)
	a := register(t, s, "Asha", "9876543210")
	d := register(t, s, "Dev", "9123456780")
	m := register(t, s, "Meera", "9988776655")
	in := ItemSplitInput{Description: "Dinner at Britto's", Extra: domain.Rupees(150), Items: []ItemShareLine{
		{Name: "Prawn curry", Amount: domain.Rupees(600), People: []string{a}},
		{Name: "Paneer tikka", Amount: domain.Rupees(300), People: []string{d}},
		{Name: "Fries", Amount: domain.Rupees(100), People: []string{a, d, m}},
	}}
	r := must[ItemSplitResult](t)(s.SplitByItems(a, in))
	if r.Total != domain.Rupees(1150) || len(r.Parts) != 3 || len(r.Requests) != 2 {
		t.Fatalf("result %+v", r)
	}
	var sum Paise
	for _, p := range r.Parts {
		sum += p.Total
	}
	if sum != r.Total {
		t.Fatalf("parts add up to %d, bill %d", sum, r.Total)
	}
	// Asha had ₹633.34 of ₹1,000 in items, so 63% of the ₹150 extras (the paise left over go to the first person).
	asha := r.Parts[0]
	if asha.Subtotal != 63334 || asha.Extra != 9501 || len(asha.Items) != 2 {
		t.Fatalf("Asha %+v", asha)
	}
	for _, rq := range r.Requests {
		if rq.Note == "" || rq.Amount <= 0 {
			t.Fatalf("request %+v", rq)
		}
	}

	// A discount is shared the same way.
	in.Extra = -domain.Rupees(100)
	r = must[ItemSplitResult](t)(s.SplitByItems(a, in))
	if r.Total != domain.Rupees(900) {
		t.Fatalf("with a discount %+v", r)
	}
	// Mistakes are turned away.
	if _, err := s.SplitByItems(a, ItemSplitInput{Items: []ItemShareLine{{Name: "Tea", Amount: 2000}}}); code(err) != "invalid" {
		t.Fatalf("no people: %v", err)
	}
	if _, err := s.SplitByItems(a, ItemSplitInput{Items: []ItemShareLine{{Name: "Tea", Amount: 2000, People: []string{a}}}}); code(err) != "invalid" {
		t.Fatalf("only yourself: %v", err)
	}
	if _, err := s.SplitByItems(a, ItemSplitInput{Extra: -5000, Items: []ItemShareLine{{Name: "Tea", Amount: 2000, People: []string{d}}}}); code(err) != "invalid" {
		t.Fatalf("discount bigger than the bill: %v", err)
	}
}

func TestScanReturnsBillLinesAndChecksTheyAddUp(t *testing.T) {
	s, _, _ := newTestService(t, nil)
	s.SetAssistant(&fakeAI{receipt: ai.Receipt{IsReceipt: true, Merchant: "Britto's", Total: "1150", Currency: "INR", Category: "food",
		Items:   []ai.ReceiptLine{{Name: "Prawn curry", Quantity: 1, Amount: "600"}, {Name: "Paneer tikka", Amount: "300"}, {Name: "Fries", Amount: "100"}, {Name: "", Amount: "5"}},
		Charges: []ai.ReceiptLine{{Name: "GST 5%", Amount: "50"}, {Name: "Service", Amount: "120"}, {Name: "Discount", Amount: "-20"}}}})
	png := []byte("\x89PNG\r\n\x1a\n" + string(make([]byte, 64)))
	r := must[ScannedReceipt](t)(s.ScanReceipt(t.Context(), png))
	if len(r.Items) != 3 || r.Items[1].Quantity != 1 || len(r.Charges) != 3 || r.Charges[2].Amount != -2000 || !r.ItemsMatch {
		t.Fatalf("scan %+v", r)
	}
}
