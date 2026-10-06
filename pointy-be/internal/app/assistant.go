package app

import (
	"context"
	"log"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/ai"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
)

// ---------------------------------------------------------------- settle up

type SettleLine struct {
	User      domain.PublicUser `json:"user"`
	Deposited Paise             `json:"deposited_paise"`
	Used      Paise             `json:"used_paise"`
	Refund    Paise             `json:"refund_paise"`
}

type Settlement struct {
	TripID    string       `json:"trip_id"`
	Status    string       `json:"status"`
	Deposited Paise        `json:"deposited_paise"`
	Spent     Paise        `json:"spent_paise"`
	Refund    Paise        `json:"refund_paise"`
	Lines     []SettleLine `json:"lines"`
}

func (s *Service) settlementL(t *domain.Trip) Settlement {
	v := s.tripViewL(t)
	out := Settlement{TripID: t.ID, Status: t.Status, Deposited: v.Deposited, Spent: v.Spent}
	for _, m := range v.MemberDetails {
		out.Lines = append(out.Lines, SettleLine{User: m.User, Deposited: m.Deposited, Used: m.Used, Refund: m.Left})
		out.Refund += m.Left
	}
	return out
}

func (s *Service) SettlementPreview(tripID, userID string) (Settlement, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	t, err := s.tripL(tripID, userID)
	if err != nil {
		return Settlement{}, err
	}
	return s.settlementL(t), nil
}

// Settle closes the trip: what is left in each share goes back to that
// person's Pointy balance. Only the organiser can do it.
func (s *Service) Settle(tripID, userID string) (Settlement, error) {
	s.expireDue(context.Background()) // purchases whose time ran out let their holds go
	s.mu.Lock()
	defer s.mu.Unlock()
	t, err := s.openTripL(tripID, userID)
	if err == nil && t.OrganiserID != userID {
		err = domain.Forbidden("only the organiser can settle the trip")
	}
	if err == nil && s.openBuysOnTripL(tripID) {
		err = domain.Conflict("group_buy_open", "a group purchase is still being decided; finish or call it off first", nil)
	}
	if err != nil {
		return Settlement{}, err
	}
	plan := s.settlementL(t)
	// The refunds must add up to exactly what is held for this trip.
	if held := s.ledger.Held(domain.ClearingAccount(tripID)); held != plan.Refund {
		return Settlement{}, domain.Conflict("ledger_mismatch", "refunds do not add up to the wallet balance", map[string]any{"held_paise": held, "refund_paise": plan.Refund})
	}
	back := map[string]Paise{}
	people := 0
	for _, l := range plan.Lines {
		if l.Refund > 0 {
			back[l.User.ID] = l.Refund
			people++
		}
	}
	if plan.Refund > 0 {
		if err := s.tripToBalancesL(t, "refund", "settle", s.now(), back, back); err != nil {
			return Settlement{}, err
		}
	}
	t.Status = domain.TripSettled
	s.track(t)
	for _, r := range s.requests {
		if r.TripID == tripID && r.Status == "open" {
			r.Status = "cancelled"
			s.track(r)
		}
	}
	s.alertL(tripID, "", "payment", t.Name+" is settled", INR(plan.Refund)+" went back to "+strconv.Itoa(people)+" people's balances")
	if err := s.commitL(); err != nil {
		return Settlement{}, err
	}
	plan.Status = t.Status
	return plan, nil
}

// ---------------------------------------------------------------- deposit assistant

var (
	reMoney = regexp.MustCompile(`(?i)(?:₹|rs\.?|inr)\s*([0-9][0-9,]*)`)
	reNum   = regexp.MustCompile(`[0-9][0-9,]*`)
	reDue   = regexp.MustCompile(`(?i)\bby\s+(\d{1,2})(?:st|nd|rd|th)?\s+(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)`)
	months  = map[string]time.Month{"jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12}
)

func toInt(s string) int64 {
	n, _ := strconv.ParseInt(strings.ReplaceAll(s, ",", ""), 10, 64)
	return n
}

// parseInstruction pulls an amount and a due date out of a sentence such as
// "Collect ₹6,000 from everyone by 10 Oct". Anything it cannot find falls
// back to the trip's own deposit target and two days before the trip.
func parseInstruction(text string, t *domain.Trip, now time.Time) (Paise, time.Time) {
	amount := t.DepositTarget
	if m := reMoney.FindStringSubmatch(text); m != nil {
		amount = domain.Rupees(toInt(m[1]))
	} else {
		for _, n := range reNum.FindAllString(reDue.ReplaceAllString(text, ""), -1) {
			if v := toInt(n); v >= 100 {
				amount = domain.Rupees(v)
				break
			}
		}
	}
	due := t.Start.AddDate(0, 0, -2)
	if m := reDue.FindStringSubmatch(text); m != nil {
		day, _ := strconv.Atoi(m[1])
		due = time.Date(t.Start.In(IST).Year(), months[strings.ToLower(m[2])], day, 0, 0, 0, 0, IST)
	}
	// A due date already in the past gives people three days instead.
	if due.Before(now) {
		y, mo, d := now.In(IST).AddDate(0, 0, 3).Date()
		due = time.Date(y, mo, d, 0, 0, 0, 0, IST)
	}
	return amount, due
}

// DraftPlan turns an instruction into a plan. It sends nothing. With a
// language model configured it understands free-form requests ("ask Dev and
// Meera for 2k by Friday"), including asking only some people; otherwise, or
// if the model fails, a rule-based reader handles the common phrasings.
func (s *Service) DraftPlan(ctx context.Context, tripID, userID, instruction string) (*domain.Plan, error) {
	s.mu.Lock()
	t, err := s.openTripL(tripID, userID)
	if err == nil && t.OrganiserID != userID {
		err = domain.Forbidden("only the organiser can collect deposits")
	}
	if err != nil {
		s.mu.Unlock()
		return nil, err
	}
	assistant := s.ai
	input := ai.InstructionInput{Text: instruction, TripName: t.Name, TripStart: t.Start.In(IST).Format("2006-01-02"),
		Today: s.now().In(IST).Format("2006-01-02 (Monday)"), Organiser: s.name(userID)}
	if t.DepositTarget > 0 {
		input.DefaultAmount = INR(t.DepositTarget)
	}
	for _, m := range t.Members {
		input.Members = append(input.Members, s.name(m))
	}
	s.mu.Unlock()

	var read *ai.Instruction
	if assistant != nil {
		cctx, cancel := context.WithTimeout(ctx, aiTimeout)
		got, aerr := assistant.ParseInstruction(cctx, input)
		cancel()
		if aerr != nil {
			log.Printf("ai instruction for %s: %v (using the rules)", tripID, aerr)
		} else {
			read = &got
		}
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	if t, err = s.openTripL(tripID, userID); err != nil {
		return nil, err
	}
	per, due := parseInstruction(instruction, t, s.now())
	p := &domain.Plan{ID: s.idL("plan"), TripID: tripID, Instruction: instruction, Status: "draft", Source: "rules"}
	who := t.Members
	if read != nil {
		if !read.Understood {
			return nil, domain.Invalid("%s", firstNonEmpty(read.Reply, "say how much each person should put in, for example ₹3,000"))
		}
		if v, ok := ai.ParseRupees(read.PerPerson); ok && v > 0 {
			per = Paise(v)
		}
		if d, derr := time.ParseInLocation("2006-01-02", read.DueDate, IST); derr == nil && !d.Before(startOfDay(s.now())) {
			due = d
		}
		if picked := s.membersByNameL(t, read.MemberNames); len(picked) > 0 {
			who = picked
		}
		p.Note, p.Source = read.Reply, "ai"
	}
	if per <= 0 || per > MaxAmount {
		return nil, domain.Invalid("say how much each person should put in, for example ₹3,000")
	}
	p.PerPerson, p.Due = per, due
	for _, uid := range who {
		_, paid := s.ledger.Totals(domain.ShareAccount(tripID, uid), "deposit")
		it := domain.PlanItem{UserID: uid, Name: s.name(uid), Amount: per - paid, Channel: "request"}
		switch {
		case it.Amount <= 0:
			it.Amount, it.Channel = 0, "already_paid"
		case uid == userID:
			it.Channel = "organiser"
		}
		p.Items = append(p.Items, it)
		p.Total += it.Amount
	}
	s.plans[p.ID] = p
	s.track(p)
	if err := s.commitL(); err != nil {
		return nil, err
	}
	return p, nil
}

// membersByNameL maps names the model returned to trip members, matching the
// full name or the first name without case. Unknown names are ignored.
func (s *Service) membersByNameL(t *domain.Trip, names []string) []string {
	var out []string
	for _, n := range names {
		n = strings.ToLower(strings.TrimSpace(n))
		for _, m := range t.Members {
			full := strings.ToLower(s.name(m))
			if n != "" && (full == n || strings.Fields(full)[0] == n) && !contains(out, m) {
				out = append(out, m)
			}
		}
	}
	return out
}

func startOfDay(t time.Time) time.Time {
	y, m, d := t.In(IST).Date()
	return time.Date(y, m, d, 0, 0, 0, 0, IST)
}

// ConfirmPlan is the human yes. Only now does each member get a request on
// their phone.
func (s *Service) ConfirmPlan(tripID, planID, userID string) ([]*domain.DepositRequest, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	t, err := s.openTripL(tripID, userID)
	p := s.plans[planID]
	switch {
	case err != nil:
	case p == nil || p.TripID != tripID:
		err = domain.NotFound("plan")
	case t.OrganiserID != userID:
		err = domain.Forbidden("only the organiser can confirm a plan")
	case p.Status != "draft":
		err = domain.Conflict("plan_already_confirmed", "this plan was already confirmed", nil)
	}
	if err != nil {
		return nil, err
	}
	p.Status, p.ConfirmedBy = "confirmed", userID
	s.track(p)
	made := []*domain.DepositRequest{}
	for _, it := range p.Items {
		if it.Channel != "request" {
			continue
		}
		// One open request per person: a new plan replaces the old amount.
		var r *domain.DepositRequest
		for _, x := range s.requests {
			if x.TripID == tripID && x.UserID == it.UserID && x.Status == "open" {
				r = x
			}
		}
		if r == nil {
			r = &domain.DepositRequest{ID: s.idL("req"), TripID: tripID, UserID: it.UserID, Reminders: []time.Time{}, Status: "open"}
			s.requests[r.ID] = r
			s.reqOrder = append(s.reqOrder, r.ID)
		}
		r.Amount, r.Due = it.Amount, p.Due
		s.track(r)
		s.alertL(tripID, it.UserID, "deposit", s.name(userID)+" asked you for "+INR(it.Amount), "For "+t.Name+", due "+p.Due.Format("2 Jan"))
		made = append(made, r)
	}
	s.alertL(tripID, userID, "assistant", "Assistant: "+strconv.Itoa(len(made))+" requests sent", "Each person sees it on their phone")
	if err := s.commitL(); err != nil {
		return nil, err
	}
	return made, nil
}

type RequestView struct {
	*domain.DepositRequest
	User     domain.PublicUser `json:"user"`
	TripName string            `json:"trip_name"`
}

func (s *Service) requestViewL(r *domain.DepositRequest) RequestView {
	return RequestView{DepositRequest: r, User: s.users[r.UserID].Public(), TripName: s.trips[r.TripID].Name}
}

func (s *Service) Requests(tripID, userID string) ([]RequestView, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, err := s.tripL(tripID, userID); err != nil {
		return nil, err
	}
	out := []RequestView{}
	for i := len(s.reqOrder) - 1; i >= 0; i-- {
		if r := s.requests[s.reqOrder[i]]; r.TripID == tripID {
			out = append(out, s.requestViewL(r))
		}
	}
	return out, nil
}

// Remind nudges an unpaid request, at most twice a day.
func (s *Service) Remind(requestID, userID string) (RequestView, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r := s.requests[requestID]
	switch {
	case r == nil:
		return RequestView{}, domain.NotFound("request")
	case s.trips[r.TripID].OrganiserID != userID:
		return RequestView{}, domain.Forbidden("only the organiser can send reminders")
	case r.Status != "open":
		return RequestView{}, domain.Conflict("already_paid", "this request is already "+r.Status, nil)
	}
	today := 0
	y, m, d := s.now().In(IST).Date()
	for _, at := range r.Reminders {
		if yy, mm, dd := at.In(IST).Date(); yy == y && mm == m && dd == d {
			today++
		}
	}
	if today >= 2 {
		return RequestView{}, domain.Conflict("reminder_cap", "two reminders were already sent today", nil)
	}
	r.Reminders = append(r.Reminders, s.now())
	r.RemindersSent = len(r.Reminders)
	s.track(r)
	s.alertL(r.TripID, r.UserID, "deposit", "Reminder: "+INR(r.Amount)+" for "+s.trips[r.TripID].Name, "Due "+r.Due.Format("2 Jan")+". Pay it from the trip's Deposits tab")
	if err := s.commitL(); err != nil {
		return RequestView{}, err
	}
	return s.requestViewL(r), nil
}

// PayRequest pays your own deposit request from your balance.
func (s *Service) PayRequest(requestID, userID string) (RequestView, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r := s.requests[requestID]
	if r == nil || r.UserID != userID {
		return RequestView{}, domain.NotFound("request")
	}
	if r.Status != "open" {
		return RequestView{}, domain.Conflict("already_paid", "this request is already "+r.Status, nil)
	}
	t, err := s.openTripL(r.TripID, userID)
	if err != nil {
		return RequestView{}, err
	}
	if err := s.balanceToTripL(t, userID, r.Amount, "balance"); err != nil {
		return RequestView{}, err
	}
	s.alertL(t.ID, "", "deposit", s.name(userID)+" added "+INR(r.Amount), "The "+t.Name+" wallet now holds "+INR(s.ledger.Held(domain.ClearingAccount(t.ID))))
	s.closeRequestsL(t.ID, userID, r.Amount, "balance")
	if err := s.commitL(); err != nil {
		return RequestView{}, err
	}
	return s.requestViewL(r), nil
}

// closeRequestsL marks a member's open request paid once a deposit covers
// it, and tells the organiser when everyone has paid.
func (s *Service) closeRequestsL(tripID, userID string, amount Paise, via string) {
	for _, id := range s.reqOrder {
		r := s.requests[id]
		if r.TripID != tripID || r.UserID != userID || r.Status != "open" || amount < r.Amount {
			continue
		}
		now := s.now()
		r.Status, r.PaidAt, r.PaidVia = "paid", &now, via
		s.track(r)
		open := 0
		for _, x := range s.requests {
			if x.TripID == tripID && x.Status == "open" {
				open++
			}
		}
		if open == 0 {
			s.alertL(tripID, s.trips[tripID].OrganiserID, "assistant", "Assistant: every request is paid", "Reminders have stopped")
		}
	}
}
