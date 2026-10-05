package app

import (
	"context"
	"fmt"
	"log"
	"sort"
	"strings"
	"time"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/ai"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
)

// ---------------------------------------------------------------- budgets

type BudgetLine struct {
	Category    domain.Category `json:"category"`
	Limit       Paise           `json:"limit_paise"`
	Used        Paise           `json:"used_paise"`
	Percent     int             `json:"percent"`
	AheadOfPace bool            `json:"ahead_of_pace"`
}

type BudgetView struct {
	Limit   Paise        `json:"limit_paise"`
	Used    Paise        `json:"used_paise"`
	Percent int          `json:"percent"`
	Day     int          `json:"day"`
	Days    int          `json:"days"`
	Lines   []BudgetLine `json:"lines"`
}

func pct(part, whole Paise) int {
	if whole <= 0 {
		return 0
	}
	return int((int64(part)*200 + int64(whole)) / (2 * int64(whole)))
}

func (s *Service) Budgets(tripID, userID string) (BudgetView, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	t, err := s.tripL(tripID, userID)
	if err != nil {
		return BudgetView{}, err
	}
	v := BudgetView{}
	v.Day, v.Days = t.DayOf(s.now())
	elapsed := v.Day * 100 / v.Days
	for _, c := range domain.Categories {
		l := BudgetLine{Category: c, Limit: t.Budgets[c], Used: s.spentL(tripID, c)}
		l.Percent = pct(l.Used, l.Limit)
		// A category is ahead of pace when more of it is gone than of the trip.
		l.AheadOfPace = l.Limit > 0 && l.Percent > elapsed+5
		v.Lines = append(v.Lines, l)
		v.Limit += l.Limit
		v.Used += l.Used
	}
	v.Percent = pct(v.Used, v.Limit)
	return v, nil
}

func (s *Service) SetBudgets(tripID, userID string, in map[domain.Category]Paise) (BudgetView, error) {
	s.mu.Lock()
	t, err := s.openTripL(tripID, userID)
	if err == nil {
		for c, v := range in {
			if !domain.ValidCategory(c) || v < 0 {
				err = domain.Invalid("bad budget for %q", c)
			}
		}
	}
	if err == nil {
		for c, v := range in {
			t.Budgets[c] = v
		}
		s.track(t)
		err = s.commitL()
	}
	s.mu.Unlock()
	if err != nil {
		return BudgetView{}, err
	}
	return s.Budgets(tripID, userID)
}

// BudgetPreview is what the app calls before the money moves.
func (s *Service) BudgetPreview(tripID, userID string, cat domain.Category, amount Paise) (domain.BudgetCheck, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	t, err := s.tripL(tripID, userID)
	if err != nil {
		return domain.BudgetCheck{}, err
	}
	if !domain.ValidCategory(cat) || amount <= 0 {
		return domain.BudgetCheck{}, domain.Invalid("a known category and a positive amount are needed")
	}
	return domain.CheckBudget(cat, t.Budgets[cat], s.spentL(tripID, cat), amount), nil
}

// ---------------------------------------------------------------- insights

type Bucket struct {
	Key     string `json:"key"`
	Amount  Paise  `json:"amount_paise"`
	Percent int    `json:"percent"`
}

type Insights struct {
	Spent        Paise    `json:"spent_paise"`
	PerPerson    Paise    `json:"per_person_paise"`
	Left         Paise    `json:"left_paise"`
	Day          int      `json:"day"`
	Days         int      `json:"days"`
	DailyPace    Paise    `json:"daily_pace_paise"`
	ForecastLeft Paise    `json:"forecast_left_paise"`
	ByCategory   []Bucket `json:"by_category"`
	ByTimeOfDay  []Bucket `json:"by_time_of_day"`
	ByPlace      []Bucket `json:"by_place"`
	ByPerson     []Bucket `json:"by_person"`
	Summary      string   `json:"summary"`
	Tip          string   `json:"tip,omitempty"`
	// SummarySource is "ai" when a language model wrote the summary, else "rules".
	SummarySource string `json:"summary_source"`
}

// cachedSummary is the last AI summary for a trip, reused until the numbers
// it was written from change.
type cachedSummary struct {
	key  string
	text ai.Summary
}

// aiTimeout bounds how long a screen waits for the model before showing the
// rule-based answer instead.
const aiTimeout = 20 * time.Second

// TimeOfDay buckets a clock time. It uses the time zone the payment was made
// in, which is carried in the timestamp the app sends.
func TimeOfDay(t time.Time) string {
	switch h := t.In(IST).Hour(); {
	case h >= 5 && h < 12:
		return "morning"
	case h >= 12 && h < 18:
		return "afternoon"
	case h >= 18 && h < 22:
		return "evening"
	}
	return "night"
}

func buckets(m map[string]Paise, total Paise, order []string) []Bucket {
	out := []Bucket{}
	if order != nil {
		for _, k := range order {
			if v, ok := m[k]; ok {
				out = append(out, Bucket{k, v, pct(v, total)})
			}
		}
		return out
	}
	for k, v := range m {
		out = append(out, Bucket{k, v, pct(v, total)})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Amount != out[j].Amount {
			return out[i].Amount > out[j].Amount
		}
		return out[i].Key < out[j].Key
	})
	return out
}

// Insights works out the trip's numbers and a written summary. With a
// language model configured the summary is written by it (and cached until
// the numbers change); otherwise, or if the model fails, a template writes it.
func (s *Service) Insights(ctx context.Context, tripID, userID string) (Insights, error) {
	s.mu.Lock()
	in, facts, err := s.insightsL(tripID, userID)
	assistant := s.ai
	cached, hit := s.aiSummaries[tripID]
	s.mu.Unlock()
	if err != nil || assistant == nil || in.Spent == 0 {
		return in, err
	}
	key := fmt.Sprintf("%d|%d|%d|%d", in.Spent, in.Left, in.Day, len(in.ByPerson))
	if hit && cached.key == key {
		in.Summary, in.Tip, in.SummarySource = cached.text.Text, cached.text.Tip, "ai"
		return in, nil
	}
	cctx, cancel := context.WithTimeout(ctx, aiTimeout)
	defer cancel()
	sum, aerr := assistant.Summarize(cctx, facts)
	if aerr != nil || strings.TrimSpace(sum.Text) == "" {
		if aerr != nil {
			log.Printf("ai summary for %s: %v (using the template)", tripID, aerr)
		}
		return in, nil
	}
	s.mu.Lock()
	s.aiSummaries[tripID] = cachedSummary{key: key, text: sum}
	s.mu.Unlock()
	in.Summary, in.Tip, in.SummarySource = sum.Text, sum.Tip, "ai"
	return in, nil
}

func (s *Service) insightsL(tripID, userID string) (Insights, ai.TripFacts, error) {
	t, err := s.tripL(tripID, userID)
	if err != nil {
		return Insights{}, ai.TripFacts{}, err
	}
	cat, tod, place, person := map[string]Paise{}, map[string]Paise{}, map[string]Paise{}, map[string]Paise{}
	var in Insights
	for _, e := range s.expenses {
		if e.TripID != tripID {
			continue
		}
		in.Spent += e.Amount
		cat[string(e.Category)] += e.Amount
		tod[TimeOfDay(e.At)] += e.Amount
		place[firstNonEmpty(e.PlaceName, "Unknown place")] += e.Amount
		for _, sh := range e.Shares {
			person[s.users[sh.UserID].Name] += sh.Amount
		}
	}
	in.Day, in.Days = t.DayOf(s.now())
	in.Left = s.ledger.Held(domain.ClearingAccount(tripID))
	if n := len(t.Members); n > 0 {
		in.PerPerson = in.Spent / Paise(n)
	}
	in.ByCategory = buckets(cat, in.Spent, nil)
	in.ByTimeOfDay = buckets(tod, in.Spent, []string{"morning", "afternoon", "evening", "night"})
	in.ByPlace = buckets(place, in.Spent, nil)
	in.ByPerson = buckets(person, in.Spent, nil)

	// Forecast: the stay is paid once, so it is left out of the daily pace.
	if in.Day > 0 {
		in.DailyPace = (in.Spent - cat[string(domain.Stay)]) / Paise(in.Day)
	}
	in.ForecastLeft = in.Left - in.DailyPace*Paise(in.Days-in.Day)

	var b strings.Builder
	if in.Spent == 0 {
		b.WriteString("Nothing has been spent from this wallet yet.")
	} else {
		fmt.Fprintf(&b, "Day %d of %d. The group has spent %s, which is %s each. ", in.Day, in.Days, INR(in.Spent), INR(in.PerPerson))
		fmt.Fprintf(&b, "%s is the biggest cost and the %s costs the most. ", titleCase(in.ByCategory[0].Key), biggest(in.ByTimeOfDay))
		if in.ForecastLeft >= 0 {
			fmt.Fprintf(&b, "At this pace about %s is left at the end.", INR(in.ForecastLeft))
		} else {
			fmt.Fprintf(&b, "At this pace the wallet runs %s short.", INR(-in.ForecastLeft))
		}
	}
	in.Summary, in.SummarySource = b.String(), "rules"

	lines := func(bs []Bucket) []ai.Line {
		out := []ai.Line{}
		for _, x := range bs {
			out = append(out, ai.Line{Key: x.Key, Amount: INR(x.Amount), Percent: x.Percent})
		}
		return out
	}
	facts := ai.TripFacts{TripName: t.Name, Place: t.Place, Day: in.Day, Days: in.Days, People: len(t.Members),
		Spent: INR(in.Spent), PerPerson: INR(in.PerPerson), Left: INR(in.Left), DailyPace: INR(in.DailyPace), ForecastLeft: INR(in.ForecastLeft),
		ByCategory: lines(in.ByCategory), ByTimeOfDay: lines(in.ByTimeOfDay), ByPlace: lines(in.ByPlace), ByPerson: lines(in.ByPerson)}
	for _, c := range domain.Categories {
		if limit := t.Budgets[c]; limit > 0 {
			used := cat[string(c)]
			facts.Budgets = append(facts.Budgets, ai.BudgetLine{Category: string(c), Limit: INR(limit), Used: INR(used), Percent: pct(used, limit),
				AheadOfPace: in.Days > 0 && in.Day > 0 && int64(used)*int64(in.Days) > int64(limit)*int64(in.Day)})
		}
	}
	return in, facts, nil
}

func biggest(b []Bucket) string {
	best := b[0]
	for _, x := range b {
		if x.Amount > best.Amount {
			best = x
		}
	}
	return best.Key
}

// ---------------------------------------------------------------- suggestions

type SuggestInput struct {
	At        *time.Time `json:"at"`
	PlaceType string     `json:"place_type"`
	PlaceName string     `json:"place_name"`
}

type Suggestion struct {
	Title        string             `json:"title"`
	Category     domain.Category    `json:"category"`
	Wallet       string             `json:"wallet"` // trip or personal
	TripID       string             `json:"trip_id,omitempty"`
	SplitMethod  domain.SplitMethod `json:"split_method,omitempty"`
	Participants []string           `json:"participants,omitempty"`
	Reasons      []string           `json:"reasons"`
}

var placeCategory = map[string]domain.Category{
	"restaurant": domain.Food, "cafe": domain.Food, "bar": domain.Food, "grocery": domain.Food,
	"fuel": domain.Transport, "taxi": domain.Transport, "transit": domain.Transport, "rental": domain.Transport,
	"hotel": domain.Stay, "lodging": domain.Stay,
}

// Places where the payment is normally just for you, even on a trip.
var personalPlaces = map[string]bool{"pharmacy": true, "clothing": true, "electronics": true, "salon": true}

// Suggest proposes the category, wallet and split from the time, the type of
// place and whether a trip is on. It is plain rules, so it answers instantly
// and can always say why. It never moves money.
func (s *Service) Suggest(userID string, in SuggestInput) Suggestion {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.isChildL(userID) {
		// No suggestions from time and place for children (DPDP Act s.9(3)).
		return Suggestion{Title: "Pay someone", Category: domain.Other, Wallet: "personal", Reasons: []string{}}
	}
	at := s.now()
	if in.At != nil {
		at = *in.At
	}
	at = at.In(IST)
	pt := strings.ToLower(strings.TrimSpace(in.PlaceType))
	out := Suggestion{Category: domain.Other, Wallet: "personal", Reasons: []string{}}
	if c, ok := placeCategory[pt]; ok {
		out.Category = c
	}
	meal := ""
	if out.Category == domain.Food {
		switch h := at.Hour(); {
		case h >= 6 && h < 11:
			meal = "breakfast"
		case h >= 12 && h < 16:
			meal = "lunch"
		case h >= 19 && h < 24:
			meal = "dinner"
		}
	}
	if meal != "" {
		out.Reasons = append(out.Reasons, at.Format("3:04 pm")+", "+meal+" time")
	} else {
		out.Reasons = append(out.Reasons, titleCase(TimeOfDay(at)))
	}
	if pt != "" {
		out.Reasons = append(out.Reasons, titleCase(pt)+" nearby")
	}
	t := s.currentTripL(userID, at)
	switch {
	case t != nil && !personalPlaces[pt]:
		out.Wallet, out.TripID, out.SplitMethod, out.Participants = "trip", t.ID, domain.SplitEqual, t.Members
		out.Reasons = append(out.Reasons, t.Name+" is active")
		what := firstNonEmpty(meal, string(out.Category))
		out.Title = fmt.Sprintf("%s with your %s group? Pay from the trip wallet and split %d ways.", titleCase(what), t.Name, len(t.Members))
	case t != nil:
		out.Reasons = append(out.Reasons, "This kind of shop is usually just for you")
		out.Title = "This looks personal. Pay from your own balance."
	default:
		out.Title = "Paying a friend? It is instant from your Pointy balance."
	}
	return out
}
