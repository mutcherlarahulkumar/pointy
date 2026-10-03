package app

import (
	"context"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/paypal"
)

// ---------------------------------------------------------------- settle up

type SettleLine struct {
	User      *domain.User `json:"user"`
	Deposited Paise        `json:"deposited_paise"`
	Used      Paise        `json:"used_paise"`
	Refund    Paise        `json:"refund_paise"`
}

type Settlement struct {
	TripID    string       `json:"trip_id"`
	Status    string       `json:"status"`
	Deposited Paise        `json:"deposited_paise"`
	Spent     Paise        `json:"spent_paise"`
	Refund    Paise        `json:"refund_paise"`
	Lines     []SettleLine `json:"lines"`
	PayoutID  string       `json:"paypal_payout_id,omitempty"`
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

// Settle refunds every member what they did not use and closes the trip.
// Only the organiser can do it.
func (s *Service) Settle(ctx context.Context, tripID, userID string) (Settlement, error) {
	s.mu.Lock()
	t, err := s.openTripL(tripID, userID)
	if err == nil && t.OrganiserID != userID {
		err = domain.Forbidden("only the organiser can settle the trip")
	}
	if err != nil {
		s.mu.Unlock()
		return Settlement{}, err
	}
	plan := s.settlementL(t)
	// The refunds must add up to exactly what PayPal is holding for this trip.
	if held := s.ledger.Held(domain.ClearingAccount(tripID)); held != plan.Refund {
		s.mu.Unlock()
		return Settlement{}, domain.Conflict("ledger_mismatch", "refunds do not add up to the wallet balance", map[string]any{"held_paise": held, "refund_paise": plan.Refund})
	}
	var items []paypal.PayoutItem
	postings := []domain.Posting{}
	for _, l := range plan.Lines {
		if l.Refund > 0 {
			items = append(items, paypal.PayoutItem{ReceiverEmail: l.User.PayPalEmail, Amount: l.Refund, Note: "Refund from " + t.Name, ItemID: tripID + "-" + l.User.ID})
			postings = append(postings, domain.Posting{Account: domain.ShareAccount(tripID, l.User.ID), Debit: l.Refund})
		}
	}
	t.Status = domain.TripSettling // blocks new payments while PayPal is called
	s.mu.Unlock()

	var payoutID string
	var perr error
	if len(items) > 0 {
		payoutID, perr = s.pp.Payout(ctx, "settle-"+tripID, items)
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	if perr != nil {
		t.Status = domain.TripOpen
		return Settlement{}, rail(perr)
	}
	if len(items) > 0 {
		postings = append(postings, domain.Posting{Account: domain.ClearingAccount(tripID), Credit: plan.Refund})
		if err := s.ledger.Post(domain.Entry{ID: s.idL("je"), Kind: "refund", TripID: tripID, Ref: payoutID, At: s.now(), Postings: postings}); err != nil {
			t.Status = domain.TripOpen
			return Settlement{}, err
		}
	}
	t.Status = domain.TripSettled
	s.alertL(tripID, "", "payment", t.Name+" is settled", INR(plan.Refund)+" was refunded to "+strconv.Itoa(len(items))+" people")
	plan.Status, plan.PayoutID = t.Status, payoutID
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
func parseInstruction(text string, t *domain.Trip) (Paise, time.Time) {
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
		due = time.Date(t.Start.Year(), months[strings.ToLower(m[2])], day, 0, 0, 0, 0, t.Start.Location())
	}
	return amount, due
}

// DraftPlan turns an instruction into a plan. It sends nothing.
func (s *Service) DraftPlan(tripID, userID, instruction string) (*domain.Plan, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	t, err := s.openTripL(tripID, userID)
	if err != nil {
		return nil, err
	}
	if t.OrganiserID != userID {
		return nil, domain.Forbidden("only the organiser can collect deposits")
	}
	per, due := parseInstruction(instruction, t)
	if per <= 0 {
		return nil, domain.Invalid("say how much each person should deposit")
	}
	p := &domain.Plan{ID: s.idL("plan"), TripID: tripID, Instruction: instruction, PerPerson: per, Due: due, Status: "draft"}
	for _, uid := range t.Members {
		_, paid := s.ledger.Totals(domain.ShareAccount(tripID, uid), "deposit")
		it := domain.PlanItem{UserID: uid, Name: s.users[uid].Name, Amount: per - paid, Channel: "paypal_request"}
		switch {
		case it.Amount <= 0:
			it.Amount, it.Channel = 0, "already_paid"
		case uid == userID:
			it.Channel = "in_app"
		}
		p.Items = append(p.Items, it)
		p.Total += it.Amount
	}
	s.plans[p.ID] = p
	return p, nil
}

// ConfirmPlan is the human yes. Only now are PayPal requests sent.
func (s *Service) ConfirmPlan(ctx context.Context, tripID, planID, userID string) ([]*domain.DepositRequest, error) {
	s.mu.Lock()
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
		s.mu.Unlock()
		return nil, err
	}
	p.Status, p.ConfirmedBy = "confirmed", userID
	type job struct {
		id   string
		item domain.PlanItem
		mail string
	}
	var jobs []job
	for _, it := range p.Items {
		open := false // never send a second request to someone who already has one
		for _, r := range s.requests {
			open = open || (r.TripID == tripID && r.UserID == it.UserID && r.Status == "sent")
		}
		if it.Channel == "paypal_request" && !open {
			jobs = append(jobs, job{s.idL("req"), it, s.users[it.UserID].PayPalEmail})
		}
	}
	name := t.Name
	s.mu.Unlock()

	var made []*domain.DepositRequest
	for _, j := range jobs {
		inv, perr := s.pp.CreateAndSendInvoice(ctx, paypal.InvoiceInput{Reference: j.id, RecipientEmail: j.mail, Amount: j.item.Amount, Description: "Deposit for " + name, Due: p.Due})
		if perr != nil {
			s.mu.Lock()
			p.Status = "draft" // confirming again sends only the ones still missing
			s.mu.Unlock()
			return made, rail(perr)
		}
		r := &domain.DepositRequest{ID: j.id, TripID: tripID, UserID: j.item.UserID, Amount: j.item.Amount, Due: p.Due, InvoiceID: inv.ID, PayURL: inv.PayURL, Status: "sent", Reminders: []time.Time{}}
		s.mu.Lock()
		s.requests[r.ID] = r
		s.reqOrder = append(s.reqOrder, r.ID)
		s.mu.Unlock()
		made = append(made, r)
	}
	s.mu.Lock()
	s.alertL(tripID, userID, "assistant", "Assistant: "+strconv.Itoa(len(made))+" requests sent", "Each person got a PayPal pay link for "+name)
	s.mu.Unlock()
	return made, nil
}

func (s *Service) Requests(tripID, userID string) ([]*domain.DepositRequest, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, err := s.tripL(tripID, userID); err != nil {
		return nil, err
	}
	out := []*domain.DepositRequest{}
	for _, id := range s.reqOrder {
		if r := s.requests[id]; r.TripID == tripID {
			out = append(out, r)
		}
	}
	return out, nil
}

// Remind nudges an unpaid request. PayPal allows two reminders per invoice
// per day, so the same cap is enforced here.
func (s *Service) Remind(ctx context.Context, requestID, userID string) (*domain.DepositRequest, error) {
	s.mu.Lock()
	r := s.requests[requestID]
	var err error
	switch {
	case r == nil:
		err = domain.NotFound("request")
	case s.trips[r.TripID].OrganiserID != userID:
		err = domain.Forbidden("only the organiser can send reminders")
	case r.Status == "paid":
		err = domain.Conflict("already_paid", "this request is already paid", nil)
	default:
		today := 0
		y, m, d := s.now().Date()
		for _, at := range r.Reminders {
			if yy, mm, dd := at.Date(); yy == y && mm == m && dd == d {
				today++
			}
		}
		if today >= 2 {
			err = domain.Conflict("reminder_cap", "two reminders were already sent today", nil)
		}
	}
	s.mu.Unlock()
	if err != nil {
		return nil, err
	}
	if perr := s.pp.RemindInvoice(ctx, r.InvoiceID); perr != nil {
		return nil, rail(perr)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	r.Reminders = append(r.Reminders, s.now())
	r.RemindersSent = len(r.Reminders)
	return r, nil
}

// MarkRequestPaid records that a request was paid. The PayPal webhook calls
// it; in mock mode the demo endpoint calls it. A second call changes nothing.
func (s *Service) MarkRequestPaid(requestID string) (*domain.DepositRequest, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r := s.requests[requestID]
	if r == nil {
		return nil, domain.NotFound("request")
	}
	if r.Status == "paid" {
		return r, nil
	}
	now := s.now()
	if err := s.creditShareL(r.TripID, r.UserID, r.Amount, r.InvoiceID, now); err != nil {
		return nil, err
	}
	r.Status, r.PaidAt = "paid", &now
	open := 0
	for _, id := range s.reqOrder {
		if x := s.requests[id]; x.TripID == r.TripID && x.Status != "paid" {
			open++
		}
	}
	if open == 0 {
		s.alertL(r.TripID, s.trips[r.TripID].OrganiserID, "assistant", "Assistant: every request is paid", "Reminders have stopped")
	}
	return r, nil
}

// HandleWebhook maps a verified PayPal event onto the same use cases the app
// calls directly.
func (s *Service) HandleWebhook(ctx context.Context, eventType, resourceID string) error {
	switch eventType {
	case "CHECKOUT.ORDER.APPROVED":
		_, err := s.CaptureDeposit(ctx, resourceID)
		return err
	case "INVOICING.INVOICE.PAID":
		s.mu.Lock()
		id := ""
		for _, r := range s.requests {
			if r.InvoiceID == resourceID {
				id = r.ID
			}
		}
		s.mu.Unlock()
		if id == "" {
			return domain.NotFound("request")
		}
		_, err := s.MarkRequestPaid(id)
		return err
	}
	return nil // other events are acknowledged and ignored
}
