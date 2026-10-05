// Package domain holds the pure business rules: money, splitting, the
// double-entry ledger and budget maths. Nothing here does I/O.
package domain

import (
	"fmt"
	"net/http"
	"time"
)

// Paise is money in the smallest rupee unit. All amounts are integers so
// nothing is ever lost to floating point rounding.
type Paise int64

func Rupees(r int64) Paise { return Paise(r * 100) }

// Error is the one error type the HTTP layer knows how to render.
type Error struct {
	Status  int    `json:"-"`
	Code    string `json:"code"`
	Message string `json:"message"`
	Details any    `json:"details,omitempty"`
}

func (e *Error) Error() string { return e.Code + ": " + e.Message }

func NotFound(what string) *Error {
	return &Error{Status: http.StatusNotFound, Code: "not_found", Message: what + " not found"}
}
func Invalid(format string, a ...any) *Error {
	return &Error{Status: http.StatusBadRequest, Code: "invalid", Message: fmt.Sprintf(format, a...)}
}
func Forbidden(msg string) *Error {
	return &Error{Status: http.StatusForbidden, Code: "forbidden", Message: msg}
}
func Conflict(code, msg string, details any) *Error {
	return &Error{Status: http.StatusConflict, Code: code, Message: msg, Details: details}
}

type User struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	Phone     string    `json:"phone,omitempty"`
	CreatedAt time.Time `json:"created_at"`
	// PinHash is a bcrypt hash of the 6-digit PIN. It is never sent out.
	PinHash string `json:"-"`
	// AlertsSeenAt is when the person last opened their alerts, for the
	// unread badge.
	AlertsSeenAt time.Time `json:"-"`
}

// PublicUser is what other people may see about someone.
type PublicUser struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Phone string `json:"phone"`
}

func (u *User) Public() PublicUser { return PublicUser{ID: u.ID, Name: u.Name, Phone: u.Phone} }

// Session is a signed-in device. Only a hash of the token is stored, so a
// leaked database cannot be used to sign in.
type Session struct {
	TokenHash string
	UserID    string
	CreatedAt time.Time
}

// SessionEnd marks a session to delete (sign out).
type SessionEnd struct{ TokenHash string }

// MoneyRequest is one person asking another for money from their personal
// balance, like a UPI collect request.
type MoneyRequest struct {
	ID          string     `json:"id"`
	RequesterID string     `json:"requester_id"` // gets the money
	PayerID     string     `json:"payer_id"`     // is asked to pay
	Amount      Paise      `json:"amount_paise"`
	Note        string     `json:"note"`
	Status      string     `json:"status"` // open, paid, declined
	CreatedAt   time.Time  `json:"created_at"`
	ClosedAt    *time.Time `json:"closed_at,omitempty"`
}

type Category string

const (
	Food      Category = "food"
	Stay      Category = "stay"
	Transport Category = "transport"
	Other     Category = "other"
)

var Categories = []Category{Food, Stay, Transport, Other}

func ValidCategory(c Category) bool {
	for _, k := range Categories {
		if k == c {
			return true
		}
	}
	return false
}

const (
	TripOpen     = "open"
	TripSettling = "settling"
	TripSettled  = "settled"
)

type Trip struct {
	ID            string             `json:"id"`
	Name          string             `json:"name"`
	Place         string             `json:"place"`
	Start         time.Time          `json:"start"`
	End           time.Time          `json:"end"`
	OrganiserID   string             `json:"organiser_id"`
	Members       []string           `json:"members"`
	DepositTarget Paise              `json:"deposit_target_paise"`
	Budgets       map[Category]Paise `json:"budgets_paise"`
	Status        string             `json:"status"`
	CreatedAt     time.Time          `json:"created_at"`
}

func (t *Trip) HasMember(id string) bool {
	for _, m := range t.Members {
		if m == id {
			return true
		}
	}
	return false
}

// DayOf returns which day of the trip `now` falls on (1-based, clamped to
// 0..days) and how many days the trip has.
func (t *Trip) DayOf(now time.Time) (day, days int) {
	days = int(t.End.Sub(t.Start).Hours()/24) + 1
	if now.Before(t.Start) {
		return 0, days
	}
	day = int(now.Sub(t.Start).Hours()/24) + 1
	if day > days {
		day = days
	}
	return day, days
}

type Deposit struct {
	ID         string    `json:"id"`
	TripID     string    `json:"trip_id"`
	UserID     string    `json:"user_id"`
	Amount     Paise     `json:"amount_paise"`
	OrderID    string    `json:"paypal_order_id"`
	ApproveURL string    `json:"approve_url"`
	Status     string    `json:"status"` // created, captured
	CreatedAt  time.Time `json:"created_at"`
}

// A Deposit with an empty TripID is a top-up of the person's own balance.

type Share struct {
	UserID string `json:"user_id"`
	Amount Paise  `json:"amount_paise"`
}

type Expense struct {
	ID          string    `json:"id"`
	TripID      string    `json:"trip_id,omitempty"` // empty for a personal payment
	PaidBy      string    `json:"paid_by"`
	Description string    `json:"description"`
	Category    Category  `json:"category"`
	Amount      Paise     `json:"amount_paise"`
	Mode        string    `json:"mode"`          // trip: member or reimburse; personal: transfer
	Payee       string    `json:"payee"`         // who was paid, as shown on the receipt
	PayeeUserID string    `json:"payee_user_id"` // the Pointy user whose balance received the money
	Shares      []Share   `json:"shares"`
	PlaceName   string    `json:"place_name"`
	PlaceType   string    `json:"place_type"`
	Lat         float64   `json:"lat,omitempty"`
	Lng         float64   `json:"lng,omitempty"`
	At          time.Time `json:"at"`
}

type DepositRequest struct {
	ID            string      `json:"id"`
	TripID        string      `json:"trip_id"`
	UserID        string      `json:"user_id"`
	Amount        Paise       `json:"amount_paise"`
	Due           time.Time   `json:"due"`
	Status        string      `json:"status"` // open, paid
	RemindersSent int         `json:"reminders_sent"`
	Reminders     []time.Time `json:"reminders"`
	PaidAt        *time.Time  `json:"paid_at,omitempty"`
	PaidVia       string      `json:"paid_via,omitempty"` // balance or paypal
}

type PlanItem struct {
	UserID  string `json:"user_id"`
	Name    string `json:"name"`
	Amount  Paise  `json:"amount_paise"`
	Channel string `json:"channel"` // request, organiser, already_paid
}

// Plan is what the deposit assistant drafts. Nothing is sent while Status is
// "draft"; a person has to confirm it.
type Plan struct {
	ID          string     `json:"id"`
	TripID      string     `json:"trip_id"`
	Instruction string     `json:"instruction"`
	PerPerson   Paise      `json:"per_person_paise"`
	Due         time.Time  `json:"due"`
	Items       []PlanItem `json:"items"`
	Total       Paise      `json:"total_paise"`
	Status      string     `json:"status"` // draft, confirmed
	ConfirmedBy string     `json:"confirmed_by,omitempty"`
	// Note is the assistant's one-line reply shown above the plan, and
	// Source says who read the instruction: "ai" or "rules".
	Note   string `json:"note,omitempty"`
	Source string `json:"source,omitempty"`
}

type Alert struct {
	ID     string    `json:"id"`
	TripID string    `json:"trip_id,omitempty"`
	UserID string    `json:"user_id,omitempty"` // empty means everyone on the trip
	Kind   string    `json:"kind"`              // budget, deposit, payment, share, assistant, trip, money
	Title  string    `json:"title"`
	Body   string    `json:"body"`
	At     time.Time `json:"at"`
}

// ChatMessage is one line of a person's conversation with the Pointy AI
// assistant. The assistant may suggest an action, but the app only opens a
// screen with it filled in: it never moves money.
type ChatMessage struct {
	ID     string      `json:"id"`
	UserID string      `json:"-"`
	Role   string      `json:"role"` // user or assistant
	Text   string      `json:"text"`
	Action *ChatAction `json:"action,omitempty"`
	Source string      `json:"source,omitempty"` // ai or rules, on assistant lines
	At     time.Time   `json:"at"`
}

// ChatAction is a button under an assistant reply.
type ChatAction struct {
	Type   string      `json:"type"` // pay, request, open, shop
	Label  string      `json:"label"`
	Person *PublicUser `json:"person,omitempty"`
	Amount Paise       `json:"amount_paise,omitempty"`
	Note   string      `json:"note,omitempty"`
	Screen string      `json:"screen,omitempty"` // add_money, requests, trips, history, insights, split, trip
	TripID string      `json:"trip_id,omitempty"`
	Query  string      `json:"query,omitempty"` // shop: what was searched
	Items  []ShopItem  `json:"items,omitempty"` // shop: the products found
}

// ChatCleared deletes a person's conversation.
type ChatCleared struct{ UserID string }

// ShopItem is a product found for the person (through Channel3), with the
// best in-stock offer. Pointy never buys it: the person opens the shop's
// page, and can then split the cost or add it to a trip.
type ShopItem struct {
	ID        string `json:"id"`
	Title     string `json:"title"`
	Brand     string `json:"brand,omitempty"`
	ImageURL  string `json:"image_url,omitempty"`
	Merchant  string `json:"merchant"`    // "amazon.com"
	BuyURL    string `json:"buy_url"`     // the shop's page (affiliate-tracked by Channel3)
	Price     Paise  `json:"price_paise"` // in rupees, converted at the demo rate
	WasPrice  Paise  `json:"was_price_paise,omitempty"`
	ListPrice string `json:"list_price"` // as the shop shows it: "$19.99"
}
