package app

import (
	"sort"
	"strings"
	"time"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
)

// ---------------------------------------------------------------- people

// LookupPhone finds the Pointy user with this number.
func (s *Service) LookupPhone(raw string) (domain.PublicUser, error) {
	phone, err := NormalizePhone(raw)
	if err != nil {
		return domain.PublicUser{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	id, ok := s.phones[phone]
	if !ok {
		return domain.PublicUser{}, &domain.Error{Status: 404, Code: "not_found", Message: "no one on Pointy uses this number yet; ask them to join"}
	}
	return s.users[id].Public(), nil
}

// PublicProfile is what a scanned Pointy QR code resolves to.
func (s *Service) PublicProfile(id string) (domain.PublicUser, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	u, ok := s.users[id]
	if !ok {
		return domain.PublicUser{}, domain.NotFound("user")
	}
	return u.Public(), nil
}

// Contacts are the people you have shared a trip, a payment or a request
// with, most recent first.
func (s *Service) Contacts(userID string) []domain.PublicUser {
	s.mu.Lock()
	defer s.mu.Unlock()
	last := map[string]time.Time{}
	see := func(id string, at time.Time) {
		if id != userID && id != "" && at.After(last[id]) {
			last[id] = at
		}
	}
	for _, t := range s.trips {
		if t.HasMember(userID) {
			for _, m := range t.Members {
				see(m, t.CreatedAt)
			}
		}
	}
	for _, e := range s.expenses {
		if e.PaidBy == userID {
			see(e.PayeeUserID, e.At)
		}
		if e.PayeeUserID == userID {
			see(e.PaidBy, e.At)
		}
	}
	for _, r := range s.moneyRequests {
		if r.RequesterID == userID {
			see(r.PayerID, r.CreatedAt)
		}
		if r.PayerID == userID {
			see(r.RequesterID, r.CreatedAt)
		}
	}
	out := []domain.PublicUser{}
	for id := range last {
		out = append(out, s.users[id].Public())
	}
	sort.Slice(out, func(i, j int) bool { return last[out[i].ID].After(last[out[j].ID]) })
	return out
}

// ---------------------------------------------------------------- money requests

type MoneyRequestView struct {
	*domain.MoneyRequest
	Requester domain.PublicUser `json:"requester"`
	Payer     domain.PublicUser `json:"payer"`
	Direction string            `json:"direction"` // incoming (you are asked to pay) or outgoing
}

func (s *Service) mrViewL(r *domain.MoneyRequest, userID string) MoneyRequestView {
	v := MoneyRequestView{MoneyRequest: r, Requester: s.users[r.RequesterID].Public(), Payer: s.users[r.PayerID].Public(), Direction: "outgoing"}
	if r.PayerID == userID {
		v.Direction = "incoming"
	}
	return v
}

type MoneyRequestInput struct {
	PayerID string `json:"payer_id"`
	Amount  Paise  `json:"amount_paise"`
	Note    string `json:"note"`
}

// RequestMoney asks another Pointy user to pay you.
func (s *Service) RequestMoney(userID string, in MoneyRequestInput) (MoneyRequestView, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r, err := s.requestMoneyL(userID, in)
	if err != nil {
		return MoneyRequestView{}, err
	}
	if err := s.commitL(); err != nil {
		return MoneyRequestView{}, err
	}
	return s.mrViewL(r, userID), nil
}

func (s *Service) requestMoneyL(userID string, in MoneyRequestInput) (*domain.MoneyRequest, error) {
	if err := checkAmount(in.Amount); err != nil {
		return nil, err
	}
	if _, ok := s.users[in.PayerID]; !ok {
		return nil, domain.Invalid("choose who to ask")
	}
	if in.PayerID == userID {
		return nil, domain.Invalid("you cannot ask yourself for money")
	}
	note := strings.TrimSpace(in.Note)
	if len([]rune(note)) > 80 {
		return nil, domain.Invalid("keep the note under 80 letters")
	}
	r := &domain.MoneyRequest{ID: s.idL("mr"), RequesterID: userID, PayerID: in.PayerID, Amount: in.Amount, Note: note, Status: "open", CreatedAt: s.now()}
	s.moneyRequests = append(s.moneyRequests, r)
	s.track(r)
	body := "Tap to pay or decline"
	if note != "" {
		body = note
	}
	s.alertL("", in.PayerID, "request", s.name(userID)+" asked you for "+INR(in.Amount), body)
	return r, nil
}

func (s *Service) MoneyRequests(userID string) []MoneyRequestView {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []MoneyRequestView{}
	for i := len(s.moneyRequests) - 1; i >= 0; i-- {
		r := s.moneyRequests[i]
		if r.RequesterID == userID || r.PayerID == userID {
			out = append(out, s.mrViewL(r, userID))
		}
	}
	return out
}

// PayMoneyRequest pays a request someone sent you, from your balance.
func (s *Service) PayMoneyRequest(userID, id string) (MoneyRequestView, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r := s.findMRL(id)
	switch {
	case r == nil || r.PayerID != userID:
		return MoneyRequestView{}, domain.NotFound("request")
	case r.Status != "open":
		return MoneyRequestView{}, domain.Conflict("already_closed", "this request is already "+r.Status, nil)
	}
	now := s.now()
	desc := firstNonEmpty(r.Note, "Requested by "+s.name(r.RequesterID))
	if _, err := s.transferL(userID, r.RequesterID, ExpenseInput{Description: desc, Category: domain.Other, Amount: r.Amount, At: &now},
		s.name(userID)+" paid your request of "+INR(r.Amount)); err != nil {
		return MoneyRequestView{}, err
	}
	r.Status, r.ClosedAt = "paid", &now
	s.track(r)
	if err := s.commitL(); err != nil {
		return MoneyRequestView{}, err
	}
	return s.mrViewL(r, userID), nil
}

// DeclineMoneyRequest closes a request: the payer declines it, or the
// person who asked cancels it.
func (s *Service) DeclineMoneyRequest(userID, id string) (MoneyRequestView, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r := s.findMRL(id)
	switch {
	case r == nil || (r.PayerID != userID && r.RequesterID != userID):
		return MoneyRequestView{}, domain.NotFound("request")
	case r.Status != "open":
		return MoneyRequestView{}, domain.Conflict("already_closed", "this request is already "+r.Status, nil)
	}
	now := s.now()
	r.ClosedAt = &now
	if r.PayerID == userID {
		r.Status = "declined"
		s.alertL("", r.RequesterID, "request", s.name(userID)+" declined your request", INR(r.Amount)+" · "+firstNonEmpty(r.Note, "no note"))
	} else {
		r.Status = "cancelled"
	}
	s.track(r)
	if err := s.commitL(); err != nil {
		return MoneyRequestView{}, err
	}
	return s.mrViewL(r, userID), nil
}

func (s *Service) findMRL(id string) *domain.MoneyRequest {
	for _, r := range s.moneyRequests {
		if r.ID == id {
			return r
		}
	}
	return nil
}

// ---------------------------------------------------------------- split a bill

type SplitBillInput struct {
	Description  string              `json:"description"`
	Amount       Paise               `json:"amount_paise"`
	Method       domain.SplitMethod  `json:"split_method"`
	Participants []domain.SplitInput `json:"participants"` // include yourself to take a share
}

type SplitBillResult struct {
	Shares   []domain.Share     `json:"shares"`
	Requests []MoneyRequestView `json:"requests"`
}

// SplitBill is for a bill you already paid (cash, UPI or card): it works
// out everyone's share and sends each person a request for theirs.
func (s *Service) SplitBill(userID string, in SplitBillInput) (SplitBillResult, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	in.Description = strings.TrimSpace(in.Description)
	if in.Description == "" {
		return SplitBillResult{}, domain.Invalid("say what the bill was for")
	}
	if err := checkAmount(in.Amount); err != nil {
		return SplitBillResult{}, err
	}
	for _, p := range in.Participants {
		if _, ok := s.users[p.UserID]; !ok {
			return SplitBillResult{}, domain.Invalid("unknown person %q", p.UserID)
		}
	}
	shares, err := domain.Split(in.Amount, in.Method, in.Participants)
	if err != nil {
		return SplitBillResult{}, err
	}
	out := SplitBillResult{Shares: shares, Requests: []MoneyRequestView{}}
	for _, sh := range shares {
		if sh.UserID == userID || sh.Amount == 0 {
			continue
		}
		r, err := s.requestMoneyL(userID, MoneyRequestInput{PayerID: sh.UserID, Amount: sh.Amount, Note: "Your share of " + in.Description})
		if err != nil {
			s.pending = nil
			return SplitBillResult{}, err
		}
		out.Requests = append(out.Requests, s.mrViewL(r, userID))
	}
	if len(out.Requests) == 0 {
		return SplitBillResult{}, domain.Invalid("add at least one other person to split with")
	}
	if err := s.commitL(); err != nil {
		return SplitBillResult{}, err
	}
	return out, nil
}
