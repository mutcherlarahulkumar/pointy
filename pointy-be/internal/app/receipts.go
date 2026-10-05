package app

import (
	"context"
	"errors"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/ai"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
)

// MaxReceiptBytes caps an uploaded receipt photo. Groq accepts base64 image
// requests up to 4 MB, and base64 is a third larger than the file.
const MaxReceiptBytes = 3 << 20

// ScannedReceipt is a receipt read into the fields of an expense. Nothing is
// saved: the app fills the form and the person checks it before paying.
type ScannedReceipt struct {
	Amount      Paise           `json:"amount_paise"`
	Merchant    string          `json:"merchant"`
	Category    domain.Category `json:"category"`
	Description string          `json:"description"`
	Date        string          `json:"date,omitempty"`
	Currency    string          `json:"currency"`
	// The bill's lines and its charges, for splitting by who had what.
	// ItemsMatch says the lines and charges add up to the total (within
	// ₹2); when they do not, the app asks the person to check them.
	Items      []ScannedLine `json:"items"`
	Charges    []ScannedLine `json:"charges"`
	ItemsMatch bool          `json:"items_match"`
}

// ScannedLine is one line of a scanned bill, in paise.
type ScannedLine struct {
	Name     string `json:"name"`
	Quantity int    `json:"quantity"`
	Amount   Paise  `json:"amount_paise"`
}

// scannedLines converts the model's lines, dropping any it could not read.
func scannedLines(in []ai.ReceiptLine, allowNegative bool) (out []ScannedLine, sum Paise) {
	out = []ScannedLine{}
	for _, l := range in {
		raw := strings.TrimSpace(l.Amount)
		neg := strings.HasPrefix(raw, "-")
		v, ok := ai.ParseRupees(strings.TrimPrefix(raw, "-"))
		name := strings.TrimSpace(l.Name)
		if !ok || v <= 0 || name == "" || (neg && !allowNegative) {
			continue
		}
		p := Paise(v)
		if neg {
			p = -p
		}
		q := l.Quantity
		if q <= 0 {
			q = 1
		}
		if len([]rune(name)) > 40 {
			name = string([]rune(name)[:40])
		}
		out = append(out, ScannedLine{Name: name, Quantity: q, Amount: p})
		sum += p
	}
	return out, sum
}

var receiptTypes = map[string]bool{"image/jpeg": true, "image/png": true, "image/webp": true, "image/gif": true}

// ScanReceipt reads a photo of a bill with the language model.
func (s *Service) ScanReceipt(ctx context.Context, image []byte) (ScannedReceipt, error) {
	s.mu.Lock()
	assistant := s.ai
	s.mu.Unlock()
	if assistant == nil {
		return ScannedReceipt{}, &domain.Error{Status: http.StatusServiceUnavailable, Code: "ai_off", Message: "receipt scanning is not set up on this server"}
	}
	if len(image) == 0 || len(image) > MaxReceiptBytes {
		return ScannedReceipt{}, domain.Invalid("send a photo under 3 MB")
	}
	// Trust the bytes, not what the phone says the file is.
	mediaType := http.DetectContentType(image)
	if !receiptTypes[mediaType] {
		return ScannedReceipt{}, domain.Invalid("send a JPEG or PNG photo")
	}
	cctx, cancel := context.WithTimeout(ctx, 45*time.Second)
	defer cancel()
	r, err := assistant.ReadReceipt(cctx, image, mediaType)
	if err != nil {
		log.Printf("receipt scan: %v", err)
		if errors.Is(err, ai.ErrDeclined) {
			return ScannedReceipt{}, domain.Invalid("that photo could not be read; enter the bill by hand")
		}
		return ScannedReceipt{}, &domain.Error{Status: http.StatusBadGateway, Code: "ai_error", Message: "could not read the receipt right now; enter it by hand"}
	}
	amount, ok := ai.ParseRupees(r.Total)
	if !r.IsReceipt || !ok || amount <= 0 {
		return ScannedReceipt{}, domain.Invalid("no total found on that photo; try a clearer picture of the whole bill")
	}
	if cur := strings.ToUpper(strings.TrimSpace(r.Currency)); cur != "" && cur != "INR" {
		return ScannedReceipt{}, domain.Invalid("that bill is in %s; Pointy works in rupees", cur)
	}
	if Paise(amount) > MaxAmount {
		return ScannedReceipt{}, domain.Invalid("that total is over the %s limit", INR(MaxAmount))
	}
	out := ScannedReceipt{Amount: Paise(amount), Merchant: strings.TrimSpace(r.Merchant), Category: domain.Category(r.Category),
		Description: strings.TrimSpace(r.Description), Currency: "INR"}
	if !domain.ValidCategory(out.Category) {
		out.Category = domain.Other
	}
	if _, err := time.Parse("2006-01-02", r.Date); err == nil {
		out.Date = r.Date
	}
	if out.Description == "" {
		out.Description = firstNonEmpty(out.Merchant, "Receipt")
	}
	var items, charges Paise
	out.Items, items = scannedLines(r.Items, false)
	out.Charges, charges = scannedLines(r.Charges, true)
	diff := items + charges - out.Amount
	out.ItemsMatch = len(out.Items) > 0 && diff >= -200 && diff <= 200
	return out, nil
}
