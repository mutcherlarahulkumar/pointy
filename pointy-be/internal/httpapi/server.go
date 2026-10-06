// Package httpapi is the thin HTTP layer: it checks who is calling, decodes
// JSON, calls a use case and encodes the answer. It holds no business rules.
package httpapi

import (
	"bytes"
	"context"
	"crypto/sha256"
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

	mu       sync.Mutex
	idem     map[string]*replay // Idempotency-Key -> first response
	idemList []idemKey          // keys oldest first, to forget old answers
}

// replay is the first answer to a request with an Idempotency-Key. While
// that request is still running, done is open and retries wait for it.
type replay struct {
	fingerprint [32]byte      // hash of the request body
	done        chan struct{} // closed when the first request has finished
	status      int           // 0 while running, or after a server error
	body        []byte
	at          time.Time
}

type idemKey struct {
	key string
	r   *replay
}

// Answers are kept for a day, and at most this many at once.
const (
	idemTTL = 24 * time.Hour
	idemMax = 10000
)

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
	s := &server{svc: svc, pp: pp, idem: map[string]*replay{}}
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
				// Views point into live state: encode them under the
				// service lock so a write cannot change them mid-way.
				b, err := svc.Marshal(v)
				if err != nil {
					writeErr(w, err)
					return
				}
				w.Header().Set("Content-Type", "application/json; charset=utf-8")
				w.WriteHeader(status)
				_, _ = w.Write(b)
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
	// ---- Pointy Parenting
	authed("GET /api/family", func(w http.ResponseWriter, r *http.Request) (any, error) {
		return svc.Family(userID(r))
	})
	authed("POST /api/family/invites", func(w http.ResponseWriter, r *http.Request) (any, error) {
		var in app.InviteInput
		if err := body(r, &in); err != nil {
			return nil, err
		}
		return svc.InviteChild(userID(r), in)
	})
	authed("POST /api/family/invites/{id}/accept", func(w http.ResponseWriter, r *http.Request) (any, error) {
		var in struct {
			Code string `json:"code"`
			PIN  string `json:"pin"`
		}
		if err := body(r, &in); err != nil {
			return nil, err
		}
		return svc.AcceptInvite(userID(r), r.PathValue("id"), in.Code, in.PIN)
	})
	authed("POST /api/family/invites/{id}/decline", func(w http.ResponseWriter, r *http.Request) (any, error) {
		return map[string]bool{"ok": true}, svc.DeclineInvite(userID(r), r.PathValue("id"))
	})
	authed("PUT /api/family/children/{id}/limits", func(w http.ResponseWriter, r *http.Request) (any, error) {
		var in struct {
			Daily   app.Paise `json:"daily_limit_paise"`
			Monthly app.Paise `json:"monthly_limit_paise"`
			PIN     string    `json:"pin"`
		}
		if err := body(r, &in); err != nil {
			return nil, err
		}
		return svc.SetChildLimits(userID(r), r.PathValue("id"), in.Daily, in.Monthly, in.PIN)
	})
	authed("POST /api/family/children/{id}/unlink", func(w http.ResponseWriter, r *http.Request) (any, error) {
		var in struct {
			PIN string `json:"pin"`
		}
		if err := body(r, &in); err != nil {
			return nil, err
		}
		return map[string]bool{"ok": true}, svc.Unlink(userID(r), r.PathValue("id"), in.PIN)
	})
	authed("GET /api/family/children/{id}/activity", func(w http.ResponseWriter, r *http.Request) (any, error) {
		return svc.ChildActivity(userID(r), r.PathValue("id"))
	})
	authed("POST /api/family/children/{id}/code-key", func(w http.ResponseWriter, r *http.Request) (any, error) {
		var in struct {
			PIN string `json:"pin"`
		}
		if err := body(r, &in); err != nil {
			return nil, err
		}
		return svc.ChildCodeKey(userID(r), r.PathValue("id"), in.PIN)
	})
	authed("POST /api/family/approvals", func(w http.ResponseWriter, r *http.Request) (any, error) {
		var in app.ApprovalInput
		if err := body(r, &in); err != nil {
			return nil, err
		}
		return svc.AskApproval(userID(r), in)
	})
	authed("POST /api/family/approvals/{id}/approve", func(w http.ResponseWriter, r *http.Request) (any, error) {
		var in struct {
			PIN string `json:"pin"`
		}
		if err := body(r, &in); err != nil {
			return nil, err
		}
		return svc.DecideApproval(userID(r), r.PathValue("id"), true, in.PIN)
	})
	authed("POST /api/family/approvals/{id}/decline", func(w http.ResponseWriter, r *http.Request) (any, error) {
		return svc.DecideApproval(userID(r), r.PathValue("id"), false, "")
	})

	// ---- the trip's shopping agent and group purchases (all or nothing)
	authed("POST /api/trips/{id}/shop-agent", func(w http.ResponseWriter, r *http.Request) (any, error) {
		var in struct {
			Text string `json:"text"`
		}
		if err := body(r, &in); err != nil {
			return nil, err
		}
		return svc.ShopForTrip(r.Context(), r.PathValue("id"), userID(r), in.Text)
	})
	authed("POST /api/trips/{id}/group-buys", func(w http.ResponseWriter, r *http.Request) (any, error) {
		var in struct {
			SearchID string `json:"search_id"`
			Index    int    `json:"index"`
			Why      string `json:"why"`
		}
		if err := body(r, &in); err != nil {
			return nil, err
		}
		return svc.ProposeGroupBuy(r.PathValue("id"), userID(r), in.SearchID, in.Index, in.Why)
	})
	authed("GET /api/trips/{id}/group-buys", func(w http.ResponseWriter, r *http.Request) (any, error) {
		return svc.GroupBuys(r.Context(), r.PathValue("id"), userID(r))
	})
	authed("GET /api/group-buys/{id}", func(w http.ResponseWriter, r *http.Request) (any, error) {
		return svc.GroupBuy(r.Context(), r.PathValue("id"), userID(r))
	})
	authed("POST /api/group-buys/{id}/join", func(w http.ResponseWriter, r *http.Request) (any, error) {
		var in struct {
			Via string `json:"via"` // wallet or paypal
		}
		if err := body(r, &in); err != nil {
			return nil, err
		}
		return svc.JoinGroupBuy(r.Context(), r.PathValue("id"), userID(r), in.Via)
	})
	authed("POST /api/group-buys/{id}/decline", func(w http.ResponseWriter, r *http.Request) (any, error) {
		return svc.DeclineGroupBuy(r.Context(), r.PathValue("id"), userID(r))
	})
	// After approving on PayPal (or at once in demo mode) the app asks the
	// server to place the hold; PayPal's return page does the same.
	authed("POST /api/group-buys/paypal/{orderID}/authorize", func(w http.ResponseWriter, r *http.Request) (any, error) {
		return svc.AuthorizeGroupBuyOrder(r.Context(), r.PathValue("orderID"), userID(r))
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
	authed("POST /api/splits/items", func(w http.ResponseWriter, r *http.Request) (any, error) {
		var in app.ItemSplitInput
		if err := body(r, &in); err != nil {
			return nil, err
		}
		return svc.SplitByItems(userID(r), in)
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
	if s.svc.IsGroupBuyOrder(orderID) {
		g, err := s.svc.AuthorizeGroupBuyOrder(r.Context(), orderID, "")
		if err != nil {
			log.Printf("paypal return %s: %v", orderID, err)
			page(w, http.StatusOK, "Almost there", "We could not place the hold yet. Go back to Pointy and tap “I've approved it”.", false)
			return
		}
		body := "Your part is held on PayPal. You are only charged if everyone says yes. Go back to Pointy."
		if g.Status == "paid" {
			body = "Everyone said yes, so the purchase is paid. Go back to Pointy."
		}
		page(w, http.StatusOK, "You're in", body, true)
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
		// Name the field, never the server's own types.
		var te *json.UnmarshalTypeError
		if errors.As(err, &te) && te.Field != "" {
			return domain.Invalid("%s cannot be a %s", te.Field, te.Value)
		}
		return domain.Invalid("request body is not valid JSON")
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
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
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
// Keys belong to the signed-in caller; a retry that arrives while the first
// request is still running waits for its answer; the same key with a
// different body is refused. Answers are kept for a day.
func (s *server) idempotent(w http.ResponseWriter, r *http.Request, next func(http.ResponseWriter)) {
	key := r.Header.Get("Idempotency-Key")
	// Sign-in and sign-up have no caller yet, so a key there could replay
	// one person's token to another: they are never replayed.
	if key == "" || userID(r) == "" || (r.Method != http.MethodPost && r.Method != http.MethodPut) {
		next(w)
		return
	}
	key = userID(r) + "|" + r.Method + "|" + r.URL.Path + "|" + key
	// Hash the body, then hand the handler the same bytes.
	raw, err := io.ReadAll(io.LimitReader(r.Body, 8<<20))
	if err != nil {
		writeErr(w, domain.Invalid("unreadable body"))
		return
	}
	r.Body = io.NopCloser(io.MultiReader(bytes.NewReader(raw), r.Body))
	fp := sha256.Sum256(raw)

	for {
		s.mu.Lock()
		s.forgetOldL()
		old, seen := s.idem[key]
		if !seen {
			break // still locked
		}
		s.mu.Unlock()
		if old.fingerprint != fp {
			writeErr(w, &domain.Error{Status: http.StatusUnprocessableEntity, Code: "idempotency_key_reused",
				Message: "this Idempotency-Key was already used for a different request; make a new key"})
			return
		}
		select {
		case <-old.done:
		case <-r.Context().Done():
			return
		}
		s.mu.Lock()
		status, body := old.status, old.body
		s.mu.Unlock()
		if status == 0 {
			continue // the first try failed with a server error: run it again
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.Header().Set("Idempotent-Replay", "true")
		w.WriteHeader(status)
		_, _ = w.Write(body)
		return
	}
	mine := &replay{fingerprint: fp, done: make(chan struct{}), at: time.Now()}
	s.idem[key] = mine
	s.idemList = append(s.idemList, idemKey{key, mine})
	s.mu.Unlock()

	rec := &recorder{ResponseWriter: w, status: http.StatusOK}
	finished := false
	defer func() { // also runs if the handler panics
		s.mu.Lock()
		if finished && rec.status < 500 { // a server error may be retried for real
			mine.status, mine.body = rec.status, rec.body.Bytes()
		} else if s.idem[key] == mine {
			delete(s.idem, key)
		}
		s.mu.Unlock()
		close(mine.done)
	}()
	next(rec)
	finished = true
}

// forgetOldL drops answers older than a day, and the oldest when full.
func (s *server) forgetOldL() {
	n := 0
	for n < len(s.idemList) && (len(s.idemList)-n >= idemMax || time.Since(s.idemList[n].r.at) > idemTTL) {
		if k := s.idemList[n]; s.idem[k.key] == k.r {
			delete(s.idem, k.key)
		}
		n++
	}
	if n > 0 {
		s.idemList = s.idemList[n:]
	}
}
