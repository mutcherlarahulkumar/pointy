package paypal

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
)

// Sandbox talks to the real PayPal REST API (sandbox by default).
//
// The app keeps its books in rupees. PayPal does not take INR between
// accounts, so every amount is converted to Currency (USD by default, for a
// US sandbox business account) at a fixed demo rate before it is sent.
type Sandbox struct {
	BaseURL    string // https://api-m.sandbox.paypal.com
	ClientID   string
	Secret     string
	WebhookID  string
	Currency   string  // e.g. USD
	INRPerUnit float64 // demo rate: how many rupees one unit of Currency costs
	ReturnURL  string
	CancelURL  string
	HTTP       *http.Client

	mu      sync.Mutex
	token   string
	expires time.Time
}

func (s *Sandbox) Mode() string { return "sandbox" }

func (s *Sandbox) money(p domain.Paise) map[string]string {
	v := float64(p) / 100 / s.INRPerUnit
	return map[string]string{"currency_code": s.Currency, "value": fmt.Sprintf("%.2f", v)}
}

func (s *Sandbox) accessToken(ctx context.Context) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.token != "" && time.Now().Before(s.expires) {
		return s.token, nil
	}
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, s.BaseURL+"/v1/oauth2/token", strings.NewReader(url.Values{"grant_type": {"client_credentials"}}.Encode()))
	req.SetBasicAuth(s.ClientID, s.Secret)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	res, err := s.HTTP.Do(req)
	if err != nil {
		return "", err
	}
	defer res.Body.Close()
	var out struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
	}
	if res.StatusCode != http.StatusOK || json.NewDecoder(res.Body).Decode(&out) != nil || out.AccessToken == "" {
		return "", fmt.Errorf("paypal: could not get an access token (HTTP %d)", res.StatusCode)
	}
	s.token, s.expires = out.AccessToken, time.Now().Add(time.Duration(out.ExpiresIn-60)*time.Second)
	return s.token, nil
}

// call sends one JSON request. requestID becomes PayPal-Request-Id, which
// makes a retried POST safe.
func (s *Sandbox) call(ctx context.Context, method, path, requestID string, in, out any) error {
	tok, err := s.accessToken(ctx)
	if err != nil {
		return err
	}
	var body io.Reader
	if in != nil {
		b, _ := json.Marshal(in)
		body = bytes.NewReader(b)
	}
	req, _ := http.NewRequestWithContext(ctx, method, s.BaseURL+path, body)
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set("Content-Type", "application/json")
	if requestID != "" {
		req.Header.Set("PayPal-Request-Id", requestID)
	}
	res, err := s.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(res.Body)
	if res.StatusCode >= 300 {
		return fmt.Errorf("paypal: %s %s returned HTTP %d: %s", method, path, res.StatusCode, raw)
	}
	if out != nil && len(raw) > 0 {
		return json.Unmarshal(raw, out)
	}
	return nil
}

type link struct{ Href, Rel string }

func (s *Sandbox) CreateOrder(ctx context.Context, reference string, amount domain.Paise, description string) (Order, error) {
	in := map[string]any{
		"intent": "CAPTURE",
		"purchase_units": []any{map[string]any{
			"reference_id": reference, "description": description, "amount": s.money(amount),
		}},
		"payment_source": map[string]any{"paypal": map[string]any{"experience_context": map[string]any{
			"return_url": s.ReturnURL, "cancel_url": s.CancelURL, "user_action": "PAY_NOW",
		}}},
	}
	var out struct {
		ID    string
		Links []link
	}
	if err := s.call(ctx, http.MethodPost, "/v2/checkout/orders", reference, in, &out); err != nil {
		return Order{}, err
	}
	o := Order{ID: out.ID}
	for _, l := range out.Links {
		if l.Rel == "payer-action" || l.Rel == "approve" {
			o.ApproveURL = l.Href
		}
	}
	return o, nil
}

func (s *Sandbox) CaptureOrder(ctx context.Context, orderID string) error {
	var out struct{ Status string }
	if err := s.call(ctx, http.MethodPost, "/v2/checkout/orders/"+orderID+"/capture", "capture-"+orderID, struct{}{}, &out); err != nil {
		// Captured earlier (for example by the return page) but not yet
		// recorded here: the money is in, so this is success.
		if strings.Contains(err.Error(), "ORDER_ALREADY_CAPTURED") {
			return nil
		}
		return err
	}
	if out.Status != "COMPLETED" {
		return fmt.Errorf("paypal: order %s is %s, not COMPLETED", orderID, out.Status)
	}
	return nil
}

func (s *Sandbox) VerifyWebhook(ctx context.Context, h http.Header, body []byte) error {
	in := map[string]any{
		"auth_algo": h.Get("Paypal-Auth-Algo"), "cert_url": h.Get("Paypal-Cert-Url"),
		"transmission_id": h.Get("Paypal-Transmission-Id"), "transmission_sig": h.Get("Paypal-Transmission-Sig"),
		"transmission_time": h.Get("Paypal-Transmission-Time"), "webhook_id": s.WebhookID,
		"webhook_event": json.RawMessage(body),
	}
	var out struct {
		VerificationStatus string `json:"verification_status"`
	}
	if err := s.call(ctx, http.MethodPost, "/v1/notifications/verify-webhook-signature", "", in, &out); err != nil {
		return err
	}
	if out.VerificationStatus != "SUCCESS" {
		return fmt.Errorf("paypal: webhook signature is %s", out.VerificationStatus)
	}
	return nil
}

// SendPayout sends one payout item from the business account (Payouts API).
// The Payouts feature must be on for the sandbox app.
func (s *Sandbox) SendPayout(ctx context.Context, ref, email string, amount domain.Paise, note string) (Payout, error) {
	in := map[string]any{
		"sender_batch_header": map[string]any{
			"sender_batch_id": ref,
			"email_subject":   "You have money from Pointy",
			"email_message":   note,
		},
		"items": []map[string]any{{
			"recipient_type": "EMAIL",
			"receiver":       email,
			"amount":         s.money(amount),
			"note":           note,
			"sender_item_id": ref,
		}},
	}
	var out struct {
		BatchHeader struct {
			PayoutBatchID string `json:"payout_batch_id"`
			BatchStatus   string `json:"batch_status"`
		} `json:"batch_header"`
	}
	if err := s.call(ctx, http.MethodPost, "/v1/payments/payouts", ref, in, &out); err != nil {
		return Payout{}, err
	}
	if out.BatchHeader.PayoutBatchID == "" {
		return Payout{}, fmt.Errorf("paypal: payout answer has no batch id")
	}
	return Payout{BatchID: out.BatchHeader.PayoutBatchID, Status: out.BatchHeader.BatchStatus}, nil
}

// PayoutStatus reads the one item of a payout batch.
func (s *Sandbox) PayoutStatus(ctx context.Context, batchID string) (string, error) {
	var out struct {
		BatchHeader struct {
			BatchStatus string `json:"batch_status"`
		} `json:"batch_header"`
		Items []struct {
			TransactionStatus string `json:"transaction_status"`
		} `json:"items"`
	}
	if err := s.call(ctx, http.MethodGet, "/v1/payments/payouts/"+batchID, "", nil, &out); err != nil {
		return "", err
	}
	if len(out.Items) > 0 && out.Items[0].TransactionStatus != "" {
		return out.Items[0].TransactionStatus, nil
	}
	return out.BatchHeader.BatchStatus, nil
}
