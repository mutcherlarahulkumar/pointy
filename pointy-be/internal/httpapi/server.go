// Package httpapi is the thin HTTP layer: it decodes JSON, calls a use case
// and encodes the answer. It holds no business rules.
package httpapi

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"sync"

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
}

// New builds the router. demo adds the endpoints that stand in for PayPal
// webhooks when the mock rail is used.
func New(svc *app.Service, pp paypal.Client, demo bool) http.Handler {
	s := &server{svc: svc, pp: pp, idem: map[string]replay{}}
	mux := http.NewServeMux()
	h := func(pattern string, fn func(w http.ResponseWriter, r *http.Request) (any, error)) {
		mux.HandleFunc(pattern, func(w http.ResponseWriter, r *http.Request) {
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
	}

	h("GET /health", func(w http.ResponseWriter, r *http.Request) (any, error) {
		return map[string]string{"status": "ok", "paypal_mode": pp.Mode()}, nil
	})
	h("GET /api/me", func(w http.ResponseWriter, r *http.Request) (any, error) { return svc.Me(user(r)) })
	h("GET /api/history", func(w http.ResponseWriter, r *http.Request) (any, error) { return svc.History(user(r)), nil })
	h("GET /api/alerts", func(w http.ResponseWriter, r *http.Request) (any, error) { return svc.Alerts(user(r)), nil })
	h("POST /api/suggestions", func(w http.ResponseWriter, r *http.Request) (any, error) {
		var in app.SuggestInput
		if err := decode(r, &in); err != nil {
			return nil, err
		}
		return svc.Suggest(user(r), in), nil
	})
	h("POST /api/payments/personal", func(w http.ResponseWriter, r *http.Request) (any, error) {
		var in app.ExpenseInput
		if err := decode(r, &in); err != nil {
			return nil, err
		}
		return svc.PayPersonal(r.Context(), user(r), in)
	})

	h("GET /api/trips", func(w http.ResponseWriter, r *http.Request) (any, error) { return svc.ListTrips(user(r)), nil })
	h("POST /api/trips", func(w http.ResponseWriter, r *http.Request) (any, error) {
		var in app.CreateTripInput
		if err := decode(r, &in); err != nil {
			return nil, err
		}
		return svc.CreateTrip(user(r), in)
	})
	h("GET /api/trips/{id}", func(w http.ResponseWriter, r *http.Request) (any, error) {
		return svc.Trip(r.PathValue("id"), user(r))
	})

	h("POST /api/trips/{id}/deposits", func(w http.ResponseWriter, r *http.Request) (any, error) {
		var in struct {
			Amount domain.Paise `json:"amount_paise"`
		}
		if err := decode(r, &in); err != nil {
			return nil, err
		}
		return svc.StartDeposit(r.Context(), r.PathValue("id"), user(r), in.Amount)
	})
	h("POST /api/deposits/{orderID}/capture", func(w http.ResponseWriter, r *http.Request) (any, error) {
		return svc.CaptureDeposit(r.Context(), r.PathValue("orderID"))
	})

	h("GET /api/trips/{id}/expenses", func(w http.ResponseWriter, r *http.Request) (any, error) {
		return svc.Expenses(r.PathValue("id"), user(r))
	})
	h("POST /api/trips/{id}/expenses", func(w http.ResponseWriter, r *http.Request) (any, error) {
		var in app.ExpenseInput
		if err := decode(r, &in); err != nil {
			return nil, err
		}
		return svc.AddExpense(r.Context(), r.PathValue("id"), user(r), in)
	})

	h("GET /api/trips/{id}/budgets", func(w http.ResponseWriter, r *http.Request) (any, error) {
		return svc.Budgets(r.PathValue("id"), user(r))
	})
	h("PUT /api/trips/{id}/budgets", func(w http.ResponseWriter, r *http.Request) (any, error) {
		var in map[domain.Category]domain.Paise
		if err := decode(r, &in); err != nil {
			return nil, err
		}
		return svc.SetBudgets(r.PathValue("id"), user(r), in)
	})
	h("POST /api/trips/{id}/budget-check", func(w http.ResponseWriter, r *http.Request) (any, error) {
		var in struct {
			Category domain.Category `json:"category"`
			Amount   domain.Paise    `json:"amount_paise"`
		}
		if err := decode(r, &in); err != nil {
			return nil, err
		}
		return svc.BudgetPreview(r.PathValue("id"), user(r), in.Category, in.Amount)
	})
	h("GET /api/trips/{id}/insights", func(w http.ResponseWriter, r *http.Request) (any, error) {
		return svc.Insights(r.PathValue("id"), user(r))
	})

	h("GET /api/trips/{id}/settlement", func(w http.ResponseWriter, r *http.Request) (any, error) {
		return svc.SettlementPreview(r.PathValue("id"), user(r))
	})
	h("POST /api/trips/{id}/settle", func(w http.ResponseWriter, r *http.Request) (any, error) {
		return svc.Settle(r.Context(), r.PathValue("id"), user(r))
	})

	h("POST /api/trips/{id}/assistant/plan", func(w http.ResponseWriter, r *http.Request) (any, error) {
		var in struct {
			Instruction string `json:"instruction"`
		}
		if err := decode(r, &in); err != nil {
			return nil, err
		}
		return svc.DraftPlan(r.PathValue("id"), user(r), in.Instruction)
	})
	h("POST /api/trips/{id}/assistant/plans/{planID}/confirm", func(w http.ResponseWriter, r *http.Request) (any, error) {
		return svc.ConfirmPlan(r.Context(), r.PathValue("id"), r.PathValue("planID"), user(r))
	})
	h("GET /api/trips/{id}/requests", func(w http.ResponseWriter, r *http.Request) (any, error) {
		return svc.Requests(r.PathValue("id"), user(r))
	})
	h("POST /api/requests/{requestID}/remind", func(w http.ResponseWriter, r *http.Request) (any, error) {
		return svc.Remind(r.Context(), r.PathValue("requestID"), user(r))
	})
	if demo {
		// Stands in for the "invoice paid" webhook while the mock rail is used.
		h("POST /api/demo/requests/{requestID}/paid", func(w http.ResponseWriter, r *http.Request) (any, error) {
			return svc.MarkRequestPaid(r.PathValue("requestID"))
		})
	}

	mux.HandleFunc("POST /webhooks/paypal", s.webhook)
	return cors(s.idempotent(mux))
}

func (s *server) webhook(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		writeErr(w, domain.Invalid("unreadable body"))
		return
	}
	if err := s.pp.VerifyWebhook(r.Context(), r.Header, body); err != nil {
		writeErr(w, domain.Forbidden("webhook signature was not accepted"))
		return
	}
	var ev struct {
		EventType string `json:"event_type"`
		Resource  struct {
			ID      string `json:"id"`
			Invoice struct {
				ID string `json:"id"`
			} `json:"invoice"`
		} `json:"resource"`
	}
	if json.Unmarshal(body, &ev) != nil {
		writeErr(w, domain.Invalid("body is not a PayPal event"))
		return
	}
	id := ev.Resource.ID
	if ev.Resource.Invoice.ID != "" {
		id = ev.Resource.Invoice.ID
	}
	// A verified event is always acknowledged, so PayPal does not retry one
	// this service has no record for.
	if err := s.svc.HandleWebhook(r.Context(), ev.EventType, id); err != nil {
		log.Printf("webhook %s %s: %v", ev.EventType, id, err)
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "received"})
}

// user reads who is calling. The demo trusts a header; a real build would
// take this from a verified session token.
func user(r *http.Request) string {
	if u := r.Header.Get("X-User-Id"); u != "" {
		return u
	}
	return "u_you"
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
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, X-User-Id, Idempotency-Key")
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
func (s *server) idempotent(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		key := r.Header.Get("Idempotency-Key")
		if key == "" || (r.Method != http.MethodPost && r.Method != http.MethodPut) {
			next.ServeHTTP(w, r)
			return
		}
		key = user(r) + "|" + r.Method + "|" + r.URL.Path + "|" + key
		s.mu.Lock()
		old, seen := s.idem[key]
		s.mu.Unlock()
		if seen {
			w.Header().Set("Content-Type", "application/json; charset=utf-8")
			w.Header().Set("Idempotent-Replay", "true")
			w.WriteHeader(old.status)
			_, _ = w.Write(old.body)
			return
		}
		rec := &recorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		if rec.status < 500 { // a server error may be retried for real
			s.mu.Lock()
			s.idem[key] = replay{rec.status, rec.body.Bytes()}
			s.mu.Unlock()
		}
	})
}
