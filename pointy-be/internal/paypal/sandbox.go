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
// The app keeps its books in rupees. PayPal India accounts aside, PayPal does
// not transact in INR, so every amount is converted to Currency at a fixed
// demo rate before it is sent.
type Sandbox struct {
	BaseURL      string // https://api-m.sandbox.paypal.com
	ClientID     string
	Secret       string
	WebhookID    string
	Currency     string  // e.g. USD
	INRPerUnit   float64 // demo rate: how many rupees one unit of Currency costs
	ReturnURL    string
	CancelURL    string
	InvoicerMail string
	HTTP         *http.Client

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
		return err
	}
	if out.Status != "COMPLETED" {
		return fmt.Errorf("paypal: order %s is %s, not COMPLETED", orderID, out.Status)
	}
	return nil
}

func (s *Sandbox) Payout(ctx context.Context, batchID string, items []PayoutItem) (string, error) {
	list := make([]any, len(items))
	for i, it := range items {
		m := s.money(it.Amount)
		list[i] = map[string]any{
			"recipient_type": "EMAIL", "receiver": it.ReceiverEmail, "note": it.Note, "sender_item_id": it.ItemID,
			"amount": map[string]string{"value": m["value"], "currency": m["currency_code"]},
		}
	}
	in := map[string]any{
		"sender_batch_header": map[string]any{"sender_batch_id": batchID, "email_subject": "You have a payment from Pointy"},
		"items":               list,
	}
	var out struct {
		BatchHeader struct {
			PayoutBatchID string `json:"payout_batch_id"`
		} `json:"batch_header"`
	}
	if err := s.call(ctx, http.MethodPost, "/v1/payments/payouts", batchID, in, &out); err != nil {
		return "", err
	}
	return out.BatchHeader.PayoutBatchID, nil
}

func (s *Sandbox) CreateAndSendInvoice(ctx context.Context, in InvoiceInput) (Invoice, error) {
	draft := map[string]any{
		"detail": map[string]any{
			"currency_code": s.Currency, "reference": in.Reference, "note": in.Description,
			"payment_term": map[string]any{"due_date": in.Due.Format("2006-01-02")},
		},
		"invoicer":           map[string]any{"email_address": s.InvoicerMail},
		"primary_recipients": []any{map[string]any{"billing_info": map[string]any{"email_address": in.RecipientEmail}}},
		"items":              []any{map[string]any{"name": in.Description, "quantity": "1", "unit_amount": s.money(in.Amount)}},
	}
	var created struct {
		ID   string
		Href string
	}
	if err := s.call(ctx, http.MethodPost, "/v2/invoicing/invoices", in.Reference, draft, &created); err != nil {
		return Invoice{}, err
	}
	id := created.ID
	if id == "" { // the create call answers with a link to the new invoice
		id = created.Href[strings.LastIndex(created.Href, "/")+1:]
	}
	var sent struct{ Href string }
	if err := s.call(ctx, http.MethodPost, "/v2/invoicing/invoices/"+id+"/send", "send-"+id, map[string]any{"send_to_invoicer": false}, &sent); err != nil {
		return Invoice{}, err
	}
	return Invoice{ID: id, PayURL: sent.Href}, nil
}

func (s *Sandbox) RemindInvoice(ctx context.Context, invoiceID string) error {
	return s.call(ctx, http.MethodPost, "/v2/invoicing/invoices/"+invoiceID+"/remind", "", map[string]any{"send_to_invoicer": false}, nil)
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
