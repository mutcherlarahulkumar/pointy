// Package paypal is the payment rail. The app only talks to the Client
// interface, so another rail can be added without touching the services.
package paypal

import (
	"context"
	"fmt"
	"net/http"
	"sync"
	"time"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
)

type Order struct {
	ID         string
	ApproveURL string
}

type PayoutItem struct {
	ReceiverEmail string
	Amount        domain.Paise
	Note          string
	ItemID        string
}

type InvoiceInput struct {
	Reference      string
	RecipientEmail string
	Amount         domain.Paise
	Description    string
	Due            time.Time
}

type Invoice struct {
	ID     string
	PayURL string
}

type Client interface {
	Mode() string
	// CreateOrder starts a checkout. The member approves it at ApproveURL.
	CreateOrder(ctx context.Context, reference string, amount domain.Paise, description string) (Order, error)
	// CaptureOrder takes the money once the member has approved.
	CaptureOrder(ctx context.Context, orderID string) error
	// Payout sends money out of the business account in one batch.
	Payout(ctx context.Context, batchID string, items []PayoutItem) (string, error)
	CreateAndSendInvoice(ctx context.Context, in InvoiceInput) (Invoice, error)
	RemindInvoice(ctx context.Context, invoiceID string) error
	// VerifyWebhook checks that a webhook really came from PayPal.
	VerifyWebhook(ctx context.Context, h http.Header, body []byte) error
}

// Mock is the default rail: it behaves like PayPal but never leaves the
// process. Every order can be captured, every payout succeeds.
type Mock struct {
	mu  sync.Mutex
	seq int
	// FailPayouts makes Payout return an error, for tests.
	FailPayouts bool
	Payouts     [][]PayoutItem
}

func (m *Mock) next(prefix string) string {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.seq++
	return fmt.Sprintf("%s-MOCK-%04d", prefix, m.seq)
}

func (m *Mock) Mode() string { return "mock" }

func (m *Mock) CreateOrder(_ context.Context, _ string, _ domain.Paise, _ string) (Order, error) {
	id := m.next("ORDER")
	return Order{ID: id, ApproveURL: "https://example.invalid/mock-paypal/approve/" + id}, nil
}

func (m *Mock) CaptureOrder(context.Context, string) error { return nil }

func (m *Mock) Payout(_ context.Context, _ string, items []PayoutItem) (string, error) {
	if m.FailPayouts {
		return "", fmt.Errorf("mock payout failure")
	}
	id := m.next("PAYOUT")
	m.mu.Lock()
	m.Payouts = append(m.Payouts, items)
	m.mu.Unlock()
	return id, nil
}

func (m *Mock) CreateAndSendInvoice(_ context.Context, _ InvoiceInput) (Invoice, error) {
	id := m.next("INV2")
	return Invoice{ID: id, PayURL: "https://example.invalid/mock-paypal/invoice/" + id}, nil
}

func (m *Mock) RemindInvoice(context.Context, string) error { return nil }

func (m *Mock) VerifyWebhook(context.Context, http.Header, []byte) error { return nil }
