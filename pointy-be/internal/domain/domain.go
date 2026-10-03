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
	ID          string `json:"id"`
	Name        string `json:"name"`
	PayPalEmail string `json:"paypal_email"`
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
	Mode        string    `json:"mode"` // paypal_payee or reimburse
	Payee       string    `json:"payee"`
	Shares      []Share   `json:"shares"`
	PlaceName   string    `json:"place_name"`
	PlaceType   string    `json:"place_type"`
	Lat         float64   `json:"lat,omitempty"`
	Lng         float64   `json:"lng,omitempty"`
	At          time.Time `json:"at"`
	PayoutID    string    `json:"paypal_payout_id"`
}

type DepositRequest struct {
	ID            string      `json:"id"`
	TripID        string      `json:"trip_id"`
	UserID        string      `json:"user_id"`
	Amount        Paise       `json:"amount_paise"`
	Due           time.Time   `json:"due"`
	InvoiceID     string      `json:"paypal_invoice_id"`
	PayURL        string      `json:"pay_url"`
	Status        string      `json:"status"` // sent, paid
	RemindersSent int         `json:"reminders_sent"`
	Reminders     []time.Time `json:"reminders"`
	PaidAt        *time.Time  `json:"paid_at,omitempty"`
}

type PlanItem struct {
	UserID  string `json:"user_id"`
	Name    string `json:"name"`
	Amount  Paise  `json:"amount_paise"`
	Channel string `json:"channel"` // in_app, paypal_request, already_paid
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
}

type Alert struct {
	ID     string    `json:"id"`
	TripID string    `json:"trip_id,omitempty"`
	UserID string    `json:"user_id,omitempty"` // empty means everyone on the trip
	Kind   string    `json:"kind"`              // budget, deposit, payment, share, assistant
	Title  string    `json:"title"`
	Body   string    `json:"body"`
	At     time.Time `json:"at"`
}
