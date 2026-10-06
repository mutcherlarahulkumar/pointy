// Package paypal is Pointy's payment rail. Money comes in with checkout (the
// Orders API): a person approves a payment and it lands in Pointy's PayPal
// business account. A group buy uses the same API with intent AUTHORIZE:
// the money is held, and taken only when everyone says yes. Money goes out
// with Payouts: a withdrawal from that business account to the person's
// own PayPal account. In between, Pointy's ledger records whose money it
// is. (Payouts is not offered to Indian accounts; the demo uses a US sandbox
// business account.)
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
	// CreateAuthOrder starts a checkout that only holds the money: after
	// approval, AuthorizeOrder places the hold, and CaptureAuthorization
	// takes it or VoidAuthorization lets it go. Group purchases use it so
	// nobody is charged unless everyone is in.
	CreateAuthOrder(ctx context.Context, reference string, amount domain.Paise, description string) (Order, error)
	AuthorizeOrder(ctx context.Context, orderID string) (authID string, err error)
	CaptureAuthorization(ctx context.Context, authID string) error
	VoidAuthorization(ctx context.Context, authID string) error
	// VerifyWebhook checks that a webhook really came from PayPal.
	VerifyWebhook(ctx context.Context, h http.Header, body []byte) error
	// SendPayout pays amount from Pointy's business account to the PayPal
	// account with this email. ref makes a retry safe: PayPal refuses a
	// second payout with the same ref.
	SendPayout(ctx context.Context, ref, email string, amount domain.Paise, note string) (Payout, error)
	// PayoutStatus reads where a payout is now.
	PayoutStatus(ctx context.Context, batchID string) (string, error)
}

// Payout is PayPal's answer to a payout.
type Payout struct {
	BatchID string
	ItemID  string
	// Status is PayPal's: PENDING, PROCESSING, SUCCESS, UNCLAIMED, ONHOLD,
	// FAILED, RETURNED, BLOCKED, REFUNDED, DENIED.
	Status string
}

// PayoutFailed says whether a payout status means the money did not leave
// (or came back), so Pointy must give it back to the person.
func PayoutFailed(status string) bool {
	switch status {
	case "FAILED", "RETURNED", "BLOCKED", "REFUNDED", "DENIED", "CANCELED":
		return true
	}
	return false
}

// Mock behaves like PayPal without leaving the process: every order can be
// captured straight away. It is used in tests and when no PayPal keys are set.
type Mock struct {
	mu sync.Mutex
	// FailCapture makes CaptureOrder return an error, for tests.
	FailCapture bool
	Captured    []string
	// FailPayout makes SendPayout return an error; PayoutLater sets the
	// status PayoutStatus reports next (for example RETURNED), for tests.
	FailPayout  bool
	PayoutFirst string // the status SendPayout answers; SUCCESS when empty
	PayoutLater string
	Payouts     []string // emails paid
	// FailAuthorize and FailCaptureAuth make those calls fail; Captures and
	// Voids record the authorizations taken and let go.
	FailAuthorize   bool
	FailCaptureAuth bool
	Captures        []string
	Voids           []string
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

func (m *Mock) SendPayout(_ context.Context, ref, email string, _ domain.Paise, _ string) (Payout, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.FailPayout {
		return Payout{}, fmt.Errorf("mock payout failure")
	}
	m.Payouts = append(m.Payouts, email)
	status := m.PayoutFirst
	if status == "" {
		status = "SUCCESS"
	}
	return Payout{BatchID: "BATCH-MOCK-" + ref, ItemID: "ITEM-MOCK-" + ref, Status: status}, nil
}

func (m *Mock) PayoutStatus(_ context.Context, _ string) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.PayoutLater != "" {
		return m.PayoutLater, nil
	}
	return "SUCCESS", nil
}

func (m *Mock) CreateAuthOrder(ctx context.Context, ref string, amount domain.Paise, desc string) (Order, error) {
	return m.CreateOrder(ctx, ref, amount, desc)
}

func (m *Mock) AuthorizeOrder(_ context.Context, orderID string) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.FailAuthorize {
		return "", fmt.Errorf("mock authorize failure")
	}
	return "AUTH-" + orderID, nil
}

func (m *Mock) CaptureAuthorization(_ context.Context, authID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.FailCaptureAuth {
		return fmt.Errorf("mock capture failure")
	}
	m.Captures = append(m.Captures, authID)
	return nil
}

func (m *Mock) VoidAuthorization(_ context.Context, authID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.Voids = append(m.Voids, authID)
	return nil
}
