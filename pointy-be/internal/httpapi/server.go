// Package httpapi is the thin HTTP layer: it checks who is calling, decodes
// JSON, calls a use case and encodes the answer. It holds no business rules.
package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"html/template"
	"io"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/app"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/paypal"
)

type server struct {
	svc *app.Service
	pp  paypal.Client

	mu   sync.Mutex
	idem map[string]replay // Idempotency-Key -> first response
}

type replay struct {
	status int
	body   []byte
	at     time.Time
}

type ctxKey struct{}

// userID is the signed-in caller, set by the auth middleware.
func userID(r *http.Request) string {
	id, _ := r.Context().Value(ctxKey{}).(string)
	return id
}

func bearer(r *http.Request) string {
	h := r.Header.Get("Authorization")
	if t, ok := strings.CutPrefix(h, "Bearer "); ok {
		return strings.TrimSpace(t)
	}
	return ""
}

// New builds the router.
func New(svc *app.Service, pp paypal.Client) http.Handler {
	s := &server{svc: svc, pp: pp, idem: map[string]replay{}}
	mux := http.NewServeMux()

	// handle registers a JSON endpoint. Unless public is true the caller
	// must send a valid "Authorization: Bearer <token>".
	handle := func(pattern string, public bool, fn func(w http.ResponseWriter, r *http.Request) (any, error)) {
		mux.HandleFunc(pattern, func(w http.ResponseWriter, r *http.Request) {
			if !public {
				id, ok := svc.UserForToken(bearer(r))
				if !ok {
					writeErr(w, &domain.Error{Status: http.StatusUnauthorized, Code: "signed_out", Message: "please sign in again"})
					return
				}
				r = r.WithContext(context.WithValue(r.Context(), ctxKey{}, id))
			}
			s.idempotent(w, r, func(w http.ResponseWriter) {
				v, err := fn(w, r)
				if err != nil {
					writeErr(w, err)
					return
				}
				status := http.StatusOK
				if r.Method == http.MethodPost {
					status = http.StatusCreated
				}
				writeJSON(w, status, v)
			})
		})
	}
	authed := func(pattern string, fn func(w http.ResponseWriter, r *http.Request) (any, error)) {
		handle(pattern, false, fn)
	}
	body := func(r *http.Request, v any) error { return decode(r, v) }

	handle("GET /health", true, func(w http.ResponseWriter, r *http.Request) (any, error) {
		return map[string]string{"status": "ok", "paypal_mode": pp.Mode()}, nil
	})

	// ---- sign in
	handle("POST /api/auth/check-phone", true, func(w http.ResponseWriter, r *http.Request) (any, error) {
		var in struct {
			Phone string `json:"phone"`
		}
		if err := body(r, &in); err != nil {
			return nil, err
		}
		return svc.CheckPhone(in.Phone)
	})
	handle("POST /api/auth/register", true, func(w http.ResponseWriter, r *http.Request) (any, error) {
		var in app.RegisterInput
		if err := body(r, &in); err != nil {
			return nil, err
		}
		return svc.Register(in)
	})
	handle("POST /api/auth/login", true, func(w http.ResponseWriter, r *http.Request) (any, error) {
		var in struct {
			Phone string `json:"phone"`
			PIN   string `json:"pin"`
		}
		if err := body(r, &in); err != nil {
			return nil, err
		}
		return svc.Login(in.Phone, in.PIN)
	})
	authed("POST /api/auth/verify-pin", func(w http.ResponseWriter, r *http.Request) (any, error) {
		var in struct {
			PIN string `json:"pin"`
		}
		if err := body(r, &in); err != nil {
			return nil, err
		}
		return map[string]bool{"ok": true}, svc.VerifyPIN(userID(r), in.PIN)
	})
	authed("POST /api/auth/logout", func(w http.ResponseWriter, r *http.Request) (any, error) {
		return map[string]bool{"ok": true}, svc.Logout(bearer(r))
	})

	// ---- you and people
	authed("GET /api/me", func(w http.ResponseWriter, r *http.Request) (any, error) { return svc.Me(userID(r)) })
	// ---- PayPal payouts: money leaving Pointy's business account
	authed("PUT /api/me/paypal", func(w http.ResponseWriter, r *http.Request) (any, error) {
		var in struct {
			Email string `json:"email"`
		}
		if err := body(r, &in); err != nil {
			return nil, err
		}
		return svc.SetPayPalEmail(userID(r), in.Email)
	})
	authed("POST /api/withdrawals", func(w http.ResponseWriter, r *http.Request) (any, error) {
		var in struct {
			Amount app.Paise `json:"amount_paise"`
		}
		if err := body(r, &in); err != nil {
			return nil, err
		}
		p, err := svc.Withdraw(r.Context(), userID(r), in.Amount)
		if err != nil {
			return nil, err
		}
		return p, nil
	})
	authed("GET /api/payouts", func(w http.ResponseWriter, r *http.Request) (any, error) {
		return svc.Payouts(r.Context(), userID(r)), nil
	})
	authed("GET /api/money", func(w http.ResponseWriter, r *http.Request) (any, error) {
		return svc.Money(r.Context(), userID(r))
	})
	authed("GET /api/contacts", func(w http.ResponseWriter, r *http.Request) (any, error) { return svc.Contacts(userID(r)), nil })
	authed("GET /api/users/lookup", func(w http.ResponseWriter, r *http.Request) (any, error) {
		return svc.LookupPhone(r.URL.Query().Get("phone"))
	})
	// ---- Pointy AI: a conversation about your own money, saved in the database
	authed("GET /api/assistant/messages", func(w http.ResponseWriter, r *http.Request) (any, error) {
		return svc.ChatHistory(userID(r)), nil
	})
	authed("POST /api/assistant/messages", func(w http.ResponseWriter, r *http.Request) (any, error) {
		var in struct {
			Text string `json:"text"`
		}
		if err := body(r, &in); err != nil {
			return nil, err
		}
		return svc.Chat(r.Context(), userID(r), in.Text)
	})
	authed("DELETE /api/assistant/messages", func(w http.ResponseWriter, r *http.Request) (any, error) {
		return map[string]bool{"ok": true}, svc.ClearChat(userID(r))
	})
	// ---- shopping (Channel3): find things to buy; Pointy never buys them
	authed("POST /api/shop/search", func(w http.ResponseWriter, r *http.Request) (any, error) {
		var in struct {
			Query    string    `json:"query"`
			MaxPaise app.Paise `json:"max_paise"`
		}
		if err := body(r, &in); err != nil {
			return nil, err
		}
		items, err := svc.Shop(r.Context(), in.Query, in.MaxPaise)
		if err != nil {
			return nil, err
		}
		return map[string]any{"query": in.Query, "items": items}, nil
	})
	authed("POST /api/quick-pay", func(w http.ResponseWriter, r *http.Request) (any, error) {
		var in struct {
			Text string `json:"text"`
		}
		if err := body(r, &in); err != nil {
			return nil, err
		}
		return svc.QuickPay(r.Context(), userID(r), in.Text)
	})
	authed("GET /api/users/{id}", func(w http.ResponseWriter, r *http.Request) (any, error) { return svc.PublicProfile(r.PathValue("id")) })

	// ---- your balance
	authed("POST /api/topups", func(w http.ResponseWriter, r *http.Request) (any, error) {
		var in struct {
			Amount domain.Paise `json:"amount_paise"`
		}
		if err := body(r, &in); err != nil {
			return nil, err
		}
		return svc.StartTopUp(r.Context(), userID(r), in.Amount)
	})
	authed("GET /api/deposits/{orderID}", func(w http.ResponseWriter, r *http.Request) (any, error) {
		return svc.Deposit(r.PathValue("orderID"), userID(r))
	})
	authed("POST /api/deposits/{orderID}/capture", func(w http.ResponseWriter, r *http.Request) (any, error) {
		if _, err := svc.Deposit(r.PathValue("orderID"), userID(r)); err != nil {
			return nil, err
		}
		return svc.CaptureDeposit(r.Context(), r.PathValue("orderID"))
	})
	authed("POST /api/suggestions", func(w http.ResponseWriter, r *http.Request) (any, error) {
		var in app.SuggestInput
		if err := body(r, &in); err != nil {
			return nil, err
		}
		return svc.Suggest(userID(r), in), nil
	})
	authed("POST /api/payments/personal", func(w http.ResponseWriter, r *http.Request) (any, error) {
		var in app.ExpenseInput
		if err := body(r, &in); err != nil {
			return nil, err
		}
		return svc.PayPersonal(userID(r), in)
	})

	// Reads a photo of a bill into expense fields. JSON: {"image_base64": "..."}.
	authed("POST /api/receipts/scan", func(w http.ResponseWriter, r *http.Request) (any, error) {
		var in struct {
			Image []byte `json:"image_base64"` // base64 in JSON, decoded by encoding/json
		}
		if err := json.NewDecoder(io.LimitReader(r.Body, app.MaxReceiptBytes*4/3+4096)).Decode(&in); err != nil {
			return nil, domain.Invalid("send the photo as image_base64")
		}
		return svc.ScanReceipt(r.Context(), in.Image)
	})

	// ---- requests between people
	authed("GET /api/money-requests", func(w http.ResponseWriter, r *http.Request) (any, error) { return svc.MoneyRequests(userID(r)), nil })
	authed("POST /api/money-requests", func(w http.ResponseWriter, r *http.Request) (any, error) {
		var in app.MoneyRequestInput
		if err := body(r, &in); err != nil {
			return nil, err
		}
		return svc.RequestMoney(userID(r), in)
	})
	authed("POST /api/money-requests/{id}/pay", func(w http.ResponseWriter, r *http.Request) (any, error) {
		return svc.PayMoneyRequest(userID(r), r.PathValue("id"))
	})
	authed("POST /api/money-requests/{id}/decline", func(w http.ResponseWriter, r *http.Request) (any, error) {
		return svc.DeclineMoneyRequest(userID(r), r.PathValue("id"))
	})
	authed("POST /api/splits", func(w http.ResponseWriter, r *http.Request) (any, error) {
		var in app.SplitBillInput
		if err := body(r, &in); err != nil {
			return nil, err
		}
		return svc.SplitBill(userID(r), in)
	})

	// ---- history and alerts
	authed("GET /api/history", func(w http.ResponseWriter, r *http.Request) (any, error) { return svc.History(userID(r)), nil })
	authed("GET /api/alerts", func(w http.ResponseWriter, r *http.Request) (any, error) { return svc.Alerts(userID(r)), nil })
	authed("POST /api/alerts/seen", func(w http.ResponseWriter, r *http.Request) (any, error) {
		return map[string]bool{"ok": true}, svc.MarkAlertsSeen(userID(r))
	})

	// ---- trips
	authed("GET /api/trips", func(w http.ResponseWriter, r *http.Request) (any, error) { return svc.ListTrips(userID(r)), nil })
	authed("POST /api/trips", func(w http.ResponseWriter, r *http.Request) (any, error) {
		var in app.CreateTripInput
		if err := body(r, &in); err != nil {
			return nil, err
		}
		return svc.CreateTrip(userID(r), in)
	})
	authed("GET /api/trips/{id}", func(w http.ResponseWriter, r *http.Request) (any, error) {
		return svc.Trip(r.PathValue("id"), userID(r))
	})
	authed("POST /api/trips/{id}/members", func(w http.ResponseWriter, r *http.Request) (any, error) {
		var in struct {
			Members []string `json:"members"`
		}
		if err := body(r, &in); err != nil {
			return nil, err
		}
		return svc.AddMembers(r.PathValue("id"), userID(r), in.Members)
	})
	authed("POST /api/trips/{id}/deposits", func(w http.ResponseWriter, r *http.Request) (any, error) {
		var in struct {
			Amount domain.Paise `json:"amount_paise"`
		}
		if err := body(r, &in); err != nil {
			return nil, err
		}
		// A trip is a wallet inside Pointy: money comes from your balance.
		return svc.DepositFromBalance(r.PathValue("id"), userID(r), in.Amount)
	})
	authed("GET /api/trips/{id}/expenses", func(w http.ResponseWriter, r *http.Request) (any, error) {
		return svc.Expenses(r.PathValue("id"), userID(r))
	})
	authed("POST /api/trips/{id}/expenses", func(w http.ResponseWriter, r *http.Request) (any, error) {
		var in app.ExpenseInput
		if err := body(r, &in); err != nil {
			return nil, err
		}
		return svc.AddExpense(r.PathValue("id"), userID(r), in)
	})
	authed("GET /api/trips/{id}/budgets", func(w http.ResponseWriter, r *http.Request) (any, error) {
		return svc.Budgets(r.PathValue("id"), userID(r))
	})
	authed("PUT /api/trips/{id}/budgets", func(w http.ResponseWriter, r *http.Request) (any, error) {
		var in map[domain.Category]domain.Paise
		if err := body(r, &in); err != nil {
			return nil, err
		}
		return svc.SetBudgets(r.PathValue("id"), userID(r), in)
	})
	authed("POST /api/trips/{id}/budget-check", func(w http.ResponseWriter, r *http.Request) (any, error) {
		var in struct {
			Category domain.Category `json:"category"`
			Amount   domain.Paise    `json:"amount_paise"`
		}
		if err := body(r, &in); err != nil {
			return nil, err
		}
		return svc.BudgetPreview(r.PathValue("id"), userID(r), in.Category, in.Amount)
	})
	authed("GET /api/trips/{id}/insights", func(w http.ResponseWriter, r *http.Request) (any, error) {
		return svc.Insights(r.Context(), r.PathValue("id"), userID(r))
	})
	authed("GET /api/trips/{id}/settlement", func(w http.ResponseWriter, r *http.Request) (any, error) {
		return svc.SettlementPreview(r.PathValue("id"), userID(r))
	})
	authed("POST /api/trips/{id}/settle", func(w http.ResponseWriter, r *http.Request) (any, error) {
		return svc.Settle(r.PathValue("id"), userID(r))
	})
	authed("POST /api/trips/{id}/assistant/plan", func(w http.ResponseWriter, r *http.Request) (any, error) {
		var in struct {
			Instruction string `json:"instruction"`
		}
		if err := body(r, &in); err != nil {
			return nil, err
		}
		return svc.DraftPlan(r.Context(), r.PathValue("id"), userID(r), in.Instruction)
	})
	authed("POST /api/trips/{id}/assistant/plans/{planID}/confirm", func(w http.ResponseWriter, r *http.Request) (any, error) {
		return svc.ConfirmPlan(r.PathValue("id"), r.PathValue("planID"), userID(r))
	})
	authed("GET /api/trips/{id}/requests", func(w http.ResponseWriter, r *http.Request) (any, error) {
		return svc.Requests(r.PathValue("id"), userID(r))
	})
	authed("POST /api/requests/{requestID}/remind", func(w http.ResponseWriter, r *http.Request) (any, error) {
		return svc.Remind(r.PathValue("requestID"), userID(r))
	})
	authed("POST /api/requests/{requestID}/pay", func(w http.ResponseWriter, r *http.Request) (any, error) {
		return svc.PayRequest(r.PathValue("requestID"), userID(r))
	})

	// ---- PayPal
	mux.HandleFunc("POST /webhooks/paypal", s.webhook)
	mux.HandleFunc("GET /paypal/return", s.paypalReturn)
	mux.HandleFunc("GET /paypal/cancel", func(w http.ResponseWriter, r *http.Request) {
		page(w, http.StatusOK, "Payment cancelled", "Nothing was charged. You can close this tab and go back to Pointy.", false)
	})
	return cors(mux)
}

// paypalReturn is where PayPal sends the person after they approve. It
// finishes the payment at once, so the app only has to refresh.
func (s *server) paypalReturn(w http.ResponseWriter, r *http.Request) {
	orderID := r.URL.Query().Get("token")
	if orderID == "" {
		page(w, http.StatusBadRequest, "Something is missing", "PayPal did not say which payment this was. Go back to Pointy and try again.", false)
		return
	}
	d, err := s.svc.CaptureDeposit(r.Context(), orderID)
	if err != nil {
		log.Printf("paypal return %s: %v", orderID, err)
		page(w, http.StatusOK, "Almost there", "We could not finish the payment yet. Go back to Pointy and tap “I've paid”.", false)
		return
	}
	page(w, http.StatusOK, "Payment received", app.INR(d.Amount)+" was added. Go back to Pointy to see it.", true)
}

var pageTmpl = template.Must(template.New("p").Parse(`<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>{{.Title}} · Pointy</title>
<style>body{margin:0;font-family:system-ui,sans-serif;background:#F3F5F1;color:#10201B;display:grid;place-items:center;min-height:100vh}
main{background:#fff;border-radius:20px;padding:32px 24px;max-width:340px;margin:16px;text-align:center}
.i{width:56px;height:56px;border-radius:50%;margin:0 auto 16px;display:grid;place-items:center;font-size:28px;color:#fff;background:{{if .OK}}#2E8268{{else}}#8A4B00{{end}}}
h1{font-size:22px;margin:0 0 8px}p{color:#4D5C56;line-height:1.5;margin:0}</style></head>
<body><main><div class="i">{{if .OK}}✓{{else}}!{{end}}</div><h1>{{.Title}}</h1><p>{{.Body}}</p></main></body></html>`))

func page(w http.ResponseWriter, status int, title, body string, ok bool) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(status)
	_ = pageTmpl.Execute(w, map[string]any{"Title": title, "Body": body, "OK": ok})
}

func (s *server) webhook(w http.ResponseWriter, r *http.Request) {
	raw, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		writeErr(w, domain.Invalid("unreadable body"))
		return
	}
	if err := s.pp.VerifyWebhook(r.Context(), r.Header, raw); err != nil {
		writeErr(w, domain.Forbidden("webhook signature was not accepted"))
		return
	}
	var ev struct {
		EventType string `json:"event_type"`
		Resource  struct {
			ID string `json:"id"`
		} `json:"resource"`
	}
	if json.Unmarshal(raw, &ev) != nil {
		writeErr(w, domain.Invalid("body is not a PayPal event"))
		return
	}
	// A verified event is always acknowledged, so PayPal does not retry one
	// this service has no record for.
	if err := s.svc.HandleWebhook(r.Context(), ev.EventType, ev.Resource.ID); err != nil {
		log.Printf("webhook %s %s: %v", ev.EventType, ev.Resource.ID, err)
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "received"})
}

func decode(r *http.Request, v any) error {
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(v); err != nil && !errors.Is(err, io.EOF) {
		return domain.Invalid("request body is not valid JSON: %v", err)
	}
	return nil
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, err error) {
	var de *domain.Error
	if !errors.As(err, &de) {
		log.Printf("internal error: %v", err)
		de = &domain.Error{Status: http.StatusInternalServerError, Code: "internal", Message: "something went wrong"}
	}
	writeJSON(w, de.Status, map[string]any{"error": de})
}

func cors(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization, Idempotency-Key")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, OPTIONS")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

type recorder struct {
	http.ResponseWriter
	status int
	body   bytes.Buffer
}

func (r *recorder) WriteHeader(code int) { r.status = code; r.ResponseWriter.WriteHeader(code) }
func (r *recorder) Write(b []byte) (int, error) {
	r.body.Write(b)
	return r.ResponseWriter.Write(b)
}

// idempotent replays the first answer when a write is retried with the same
// Idempotency-Key, so a double tap or a flaky network cannot pay twice.
// Answers are kept for a day.
func (s *server) idempotent(w http.ResponseWriter, r *http.Request, next func(http.ResponseWriter)) {
	key := r.Header.Get("Idempotency-Key")
	if key == "" || (r.Method != http.MethodPost && r.Method != http.MethodPut) {
		next(w)
		return
	}
	key = userID(r) + "|" + r.Method + "|" + r.URL.Path + "|" + key
	s.mu.Lock()
	old, seen := s.idem[key]
	if len(s.idem) > 5000 {
		for k, v := range s.idem {
			if time.Since(v.at) > 24*time.Hour {
				delete(s.idem, k)
			}
		}
	}
	s.mu.Unlock()
	if seen {
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.Header().Set("Idempotent-Replay", "true")
		w.WriteHeader(old.status)
		_, _ = w.Write(old.body)
		return
	}
	rec := &recorder{ResponseWriter: w, status: http.StatusOK}
	next(rec)
	if rec.status < 500 { // a server error may be retried for real
		s.mu.Lock()
		s.idem[key] = replay{rec.status, rec.body.Bytes(), time.Now()}
		s.mu.Unlock()
	}
}
