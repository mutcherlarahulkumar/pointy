// Package ai holds the language-model features: trip summaries written in
// plain words and the deposit assistant's reading of an instruction. The
// app works without it: every caller falls back to its rule-based version
// when no model is configured or a call fails.
package ai

import (
	"context"
	"regexp"
	"strconv"
	"strings"
)

// Assistant is what the app needs from a language model.
type Assistant interface {
	// Summarize writes a short summary of a trip's spending and one tip.
	Summarize(ctx context.Context, f TripFacts) (Summary, error)
	// ParseInstruction reads an organiser's request such as "ask Dev and
	// Meera for 2k each by Friday".
	ParseInstruction(ctx context.Context, in InstructionInput) (Instruction, error)
	// ReadReceipt reads a photo of a bill into the fields of an expense.
	ReadReceipt(ctx context.Context, image []byte, mediaType string) (Receipt, error)
	// ParseQuickPay reads a one-line payment such as "pay Asha 200 for coffee".
	ParseQuickPay(ctx context.Context, in QuickPayInput) (QuickPay, error)
	// Chat answers the person's question about their own money from facts
	// the app read from its database, and may suggest one action.
	Chat(ctx context.Context, in ChatInput) (ChatReply, error)
	// PickProducts chooses what a trip group should buy from products the
	// app found, and says why for each pick.
	PickProducts(ctx context.Context, in PickInput) (Picks, error)
}

// PickInput is a group's shopping request and the products found for it.
// Money is already formatted in rupees; the model never does arithmetic.
type PickInput struct {
	Request    string          `json:"request"`     // what the person asked for
	TripName   string          `json:"trip_name"`   // "Goa trip"
	TripPlace  string          `json:"trip_place"`  // "Goa"
	People     int             `json:"people"`      // how many share the cost
	Budget     string          `json:"budget"`      // "₹3,000" or ""
	WalletLeft string          `json:"wallet_left"` // what is left in the trip wallet
	Candidates []PickCandidate `json:"candidates"`
}

// PickCandidate is one product the app found.
type PickCandidate struct {
	Index     int    `json:"index"`
	Title     string `json:"title"`
	Brand     string `json:"brand"`
	Shop      string `json:"shop"`
	Price     string `json:"price"`      // "₹1,275"
	EachPays  string `json:"each_pays"`  // "₹425"
	WasPrice  string `json:"was_price"`  // "" or "₹1,600"
	FitsMoney bool   `json:"fits_money"` // within the budget and the wallet
}

// Picks is the model's choice: up to three candidate indexes, best first,
// each with a one-sentence reason, and a one-line reply to the group.
type Picks struct {
	Picks []Pick `json:"picks"`
	Reply string `json:"reply"`
}

type Pick struct {
	Index int    `json:"index"`
	Why   string `json:"why"`
}

// ChatInput is everything the assistant may know: the person's facts
// (amounts already formatted as rupees), the recent conversation and the
// new message.
type ChatInput struct {
	Today        string     `json:"today"`
	You          string     `json:"you"`
	Facts        any        `json:"facts"`
	Conversation []ChatLine `json:"conversation"`
	Message      string     `json:"message"`
}

type ChatLine struct {
	Role string `json:"role"` // user or assistant
	Text string `json:"text"`
}

// ChatReply is the answer and at most one suggested action. Nothing runs by
// itself: the app shows a button that opens a screen to check and confirm.
type ChatReply struct {
	Reply  string `json:"reply"`
	Action string `json:"action"`        // none, pay, request, open, shop
	Person string `json:"person"`        // a name from the facts' people, a 10-digit mobile, or ""
	Amount string `json:"amount_rupees"` // "200" or ""
	Note   string `json:"note"`
	Screen string `json:"screen"`     // add_money, requests, trips, history, insights, split, trip, or ""
	Trip   string `json:"trip"`       // trip name when screen is trip
	Query  string `json:"shop_query"` // what to search the shops for when action is shop
}

// QuickPayInput is what the person typed plus the names of people they
// have paid or been paid by, so the model can pick one of them.
type QuickPayInput struct {
	Text     string   `json:"message"`
	Contacts []string `json:"contacts"`
}

// QuickPay is what the model understood. Nothing is paid: the app shows it
// and the person confirms. The amount stays as text for ParseRupees.
type QuickPay struct {
	Understood bool   `json:"understood"`
	Action     string `json:"action"`        // "pay" or "request"
	Person     string `json:"person"`        // a contact's name as listed, a 10-digit mobile number, or ""
	Amount     string `json:"amount_rupees"` // "200", "1500.50" or ""
	Note       string `json:"note"`          // "coffee" or ""
	Reply      string `json:"reply"`         // one short sentence
}

// Receipt is what the model read off a bill. Total stays as text and is
// parsed into paise by ParseRupees.
type Receipt struct {
	IsReceipt   bool   `json:"is_receipt"`
	Merchant    string `json:"merchant"`
	Total       string `json:"total"`    // "1840.00"
	Currency    string `json:"currency"` // "INR"
	Date        string `json:"date"`     // "2026-10-12" or ""
	Category    string `json:"category"` // food, stay, transport, other
	Description string `json:"description"`
	// Items are the bill's lines (what was ordered); Charges are taxes,
	// service charge, tips and discounts (a discount is negative). Used to
	// split a bill by who had what.
	Items   []ReceiptLine `json:"items"`
	Charges []ReceiptLine `json:"charges"`
}

// ReceiptLine is one printed line of a bill.
type ReceiptLine struct {
	Name     string `json:"name"`
	Quantity int    `json:"quantity"`
	Amount   string `json:"amount"` // the line's total, "360.00"; "-50" for a discount
}

// Line is one row of a breakdown, already formatted for the model.
type Line struct {
	Key     string `json:"key"`
	Amount  string `json:"amount"` // "₹1,840"
	Percent int    `json:"percent"`
}

// BudgetLine is one category's budget.
type BudgetLine struct {
	Category    string `json:"category"`
	Limit       string `json:"limit"`
	Used        string `json:"used"`
	Percent     int    `json:"percent"`
	AheadOfPace bool   `json:"ahead_of_pace"`
}

// TripFacts are the numbers the summary is written from. Amounts are
// pre-formatted rupees so the model never does arithmetic on money.
type TripFacts struct {
	TripName     string       `json:"trip_name"`
	Place        string       `json:"place"`
	Day          int          `json:"day"`
	Days         int          `json:"days"`
	People       int          `json:"people"`
	Spent        string       `json:"spent"`
	PerPerson    string       `json:"per_person"`
	Left         string       `json:"left_in_wallet"`
	DailyPace    string       `json:"daily_pace_excluding_stay"`
	ForecastLeft string       `json:"forecast_left_at_end"` // negative means short
	ByCategory   []Line       `json:"by_category"`
	ByTimeOfDay  []Line       `json:"by_time_of_day"`
	ByPlace      []Line       `json:"by_place"`
	ByPerson     []Line       `json:"by_person"`
	Budgets      []BudgetLine `json:"budgets"`
}

type Summary struct {
	Text string `json:"summary"`
	Tip  string `json:"tip"`
}

// InstructionInput is the organiser's sentence plus what the model needs to
// read it: who is on the trip and what "today" is.
type InstructionInput struct {
	Text          string   `json:"instruction"`
	TripName      string   `json:"trip_name"`
	TripStart     string   `json:"trip_start"` // 2026-10-20
	Today         string   `json:"today"`      // 2026-10-05 (Monday)
	Organiser     string   `json:"organiser"`
	Members       []string `json:"members"` // names, organiser included
	DefaultAmount string   `json:"usual_deposit_per_person"`
}

// Instruction is what the model understood. Amounts stay as text and are
// parsed into paise by ParseRupees, never through floating point.
type Instruction struct {
	Understood  bool     `json:"understood"`
	PerPerson   string   `json:"per_person_rupees"` // "3000" or ""
	DueDate     string   `json:"due_date"`          // "2026-10-18" or ""
	MemberNames []string `json:"members"`           // empty means everyone
	Reply       string   `json:"reply"`             // one friendly sentence for the chat
}

var reRupees = regexp.MustCompile(`^(\d+)(?:\.(\d{1,2}))?$`)

// ParseRupees turns "1,840.5" or "₹3000" into paise without floats.
func ParseRupees(s string) (int64, bool) {
	s = strings.NewReplacer("₹", "", ",", "", " ", "", "Rs.", "", "Rs", "", "INR", "").Replace(strings.TrimSpace(s))
	m := reRupees.FindStringSubmatch(s)
	if m == nil {
		return 0, false
	}
	r, err := strconv.ParseInt(m[1], 10, 64)
	if err != nil || r > 1_000_000_000 {
		return 0, false
	}
	p, _ := strconv.ParseInt((m[2] + "00")[:2], 10, 64)
	return r*100 + p, true
}
