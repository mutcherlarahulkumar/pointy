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
