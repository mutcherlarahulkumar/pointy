// Package paypal is the payment rail for money coming into Pointy. Indian
// PayPal accounts cannot pay each other and the Payouts API is not offered
// in India, so Pointy uses PayPal only for checkout (the Orders API): a
// person approves a payment on PayPal and the money lands in Pointy's
// business account. Everything after that moves inside Pointy's ledger.
package paypal

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"net/http"
	"sync"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
)

type Order struct {
	ID         string
	ApproveURL string
}

type Client interface {
	Mode() string
	// CreateOrder starts a checkout. The person approves it at ApproveURL.
	CreateOrder(ctx context.Context, reference string, amount domain.Paise, description string) (Order, error)
	// CaptureOrder takes the money once the person has approved.
	CaptureOrder(ctx context.Context, orderID string) error
	// VerifyWebhook checks that a webhook really came from PayPal.
	VerifyWebhook(ctx context.Context, h http.Header, body []byte) error
}

// Mock behaves like PayPal without leaving the process: every order can be
// captured straight away. It is used in tests and when no PayPal keys are set.
type Mock struct {
	mu sync.Mutex
	// FailCapture makes CaptureOrder return an error, for tests.
	FailCapture bool
	Captured    []string
}

func (m *Mock) Mode() string { return "mock" }

func (m *Mock) CreateOrder(_ context.Context, _ string, _ domain.Paise, _ string) (Order, error) {
	b := make([]byte, 6)
	_, _ = rand.Read(b)
	id := "ORDER-MOCK-" + hex.EncodeToString(b)
	return Order{ID: id, ApproveURL: "https://example.invalid/mock-paypal/approve/" + id}, nil
}

func (m *Mock) CaptureOrder(_ context.Context, orderID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.FailCapture {
		return fmt.Errorf("mock capture failure")
	}
	m.Captured = append(m.Captured, orderID)
	return nil
}

func (m *Mock) VerifyWebhook(context.Context, http.Header, []byte) error { return nil }
