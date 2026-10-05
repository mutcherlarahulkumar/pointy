package app

import (
	"context"
	"log"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/paypal"
)

// PayoutWithdraw is the only payout Pointy makes: your balance to your
// PayPal, from where you move it to your bank. Everything else (friends,
// trips, settle-up) stays inside Pointy's wallet.
const PayoutWithdraw = "withdraw"

var reEmail = regexp.MustCompile(`^[^@\s]+@[^@\s]+\.[^@\s]+$`)

func checkEmail(email string) (string, error) {
	email = strings.ToLower(strings.TrimSpace(email))
	if !reEmail.MatchString(email) || len(email) > 254 {
		return "", domain.Invalid("enter a PayPal email address, like name@example.com")
	}
	return email, nil
}

// SetPayPalEmail sets where Pointy pays this person out. Empty removes it.
func (s *Service) SetPayPalEmail(userID, email string) (Me, error) {
	if strings.TrimSpace(email) != "" {
		var err error
		if email, err = checkEmail(email); err != nil {
			return Me{}, err
		}
	}
	s.mu.Lock()
	u, ok := s.users[userID]
	if !ok {
		s.mu.Unlock()
		return Me{}, domain.NotFound("user")
	}
	old := u.PayPalEmail
	u.PayPalEmail = strings.TrimSpace(email)
	s.track(u)
	if err := s.commitL(); err != nil {
		u.PayPalEmail = old
		s.mu.Unlock()
		return Me{}, err
	}
	s.mu.Unlock()
	return s.Me(userID)
}

// availL is what an account can spend right now: its balance less any
// money held for a withdrawal on its way to PayPal.
// It also leaves out trip-share money promised to an open group purchase.
func (s *Service) availL(account string) Paise {
	return s.ledger.Owed(account) - s.holds[account] - s.heldForBuysL(account)
}

// Withdraw pays money from your Pointy balance to your PayPal account, from
// where you move it to your bank.
func (s *Service) Withdraw(ctx context.Context, userID string, amount Paise) (*domain.Payout, error) {
	if err := checkAmount(amount); err != nil {
		return nil, err
	}
	s.mu.Lock()
	u, ok := s.users[userID]
	if !ok {
		s.mu.Unlock()
		return nil, domain.NotFound("user")
	}
	if u.PayPalEmail == "" {
		s.mu.Unlock()
		return nil, domain.Conflict("no_paypal_email", "add your PayPal email in Profile first, so Pointy knows where to send the money", nil)
	}
	acc := domain.PersonalAccount(userID)
	if avail := s.availL(acc); avail < amount {
		s.mu.Unlock()
		return nil, domain.Conflict("insufficient_balance", "your balance is "+INR(avail)+"; you can withdraw up to that", map[string]any{"balance_paise": avail})
	}
	p := &domain.Payout{ID: newID("po"), UserID: userID, Kind: PayoutWithdraw, Email: u.PayPalEmail, Description: "Withdrawal from Pointy", Amount: amount, Status: "sending", CreatedAt: s.now()}
	s.mu.Unlock()
	if err := s.payOut(ctx, p, acc); err != nil {
		return p, err
	}
	return p, nil
}

// payOut sends p through PayPal. The money is held in the balance while
// PayPal is called, so it cannot be spent twice. When PayPal accepts, one
// balanced entry moves it out of the business account; when it refuses,
// nothing is posted, the hold is released and the payout is kept as failed.
func (s *Service) payOut(ctx context.Context, p *domain.Payout, acc string) error {
	s.mu.Lock()
	s.holds[acc] += p.Amount
	s.mu.Unlock()

	cctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	res, perr := s.pp.SendPayout(cctx, p.ID, p.Email, p.Amount, p.Description)
	cancel()

	s.mu.Lock()
	defer s.mu.Unlock()
	if s.holds[acc] -= p.Amount; s.holds[acc] <= 0 {
		delete(s.holds, acc)
	}
	if perr != nil {
		log.Printf("payout %s to %s: %v", p.ID, p.Email, perr)
		p.Status, p.Error = "failed", "PayPal did not accept the payout"
		s.payouts = append(s.payouts, p)
		s.track(p)
		_ = s.commitL()
		return &domain.Error{Status: http.StatusBadGateway, Code: "paypal_error",
			Message: "PayPal did not accept the payout, so nothing was sent and your money is still in Pointy. Check the PayPal email, or that Payouts is on for the sandbox app."}
	}
	postings := []domain.Posting{{Account: acc, Debit: p.Amount}, {Account: domain.PersonalClearing, Credit: p.Amount}}
	if err := s.postL(domain.Entry{ID: s.idL("je"), Kind: "payout", Ref: p.ID, At: s.now(), Postings: postings}); err != nil {
		return err
	}
	p.BatchID = res.BatchID
	s.setPayoutStatusL(p, res.Status)
	s.payouts = append(s.payouts, p)
	s.track(p)
	s.alertL("", p.UserID, "money", INR(p.Amount)+" sent to your PayPal", p.Email+" · "+payoutWords(p.Status))
	return s.commitL()
}

// setPayoutStatusL maps PayPal's status onto the payout.
func (s *Service) setPayoutStatusL(p *domain.Payout, status string) {
	switch {
	case status == "SUCCESS":
		p.Status = "paid"
		now := s.now()
		p.DoneAt = &now
	case status == "UNCLAIMED":
		p.Status = "unclaimed"
	case paypal.PayoutFailed(status):
		p.Status = "returned"
	default:
		p.Status = "pending"
	}
}

func payoutWords(status string) string {
	switch status {
	case "paid":
		return "paid"
	case "unclaimed":
		return "waiting for the PayPal account to accept it"
	case "returned":
		return "sent back by PayPal"
	}
	return "on its way"
}

// RefreshPayouts asks PayPal about payouts still on their way. A payout
// PayPal sends back (failed, returned, blocked) is given back: the payout
// entry is reversed, so the money is back in the person's balance.
func (s *Service) RefreshPayouts(ctx context.Context, userID string) {
	s.mu.Lock()
	var open []*domain.Payout
	for _, p := range s.payoutsForL(userID) {
		if (p.Status == "pending" || p.Status == "unclaimed") && p.BatchID != "" {
			open = append(open, p)
		}
	}
	s.mu.Unlock()
	for _, p := range open {
		cctx, cancel := context.WithTimeout(ctx, 10*time.Second)
		status, err := s.pp.PayoutStatus(cctx, p.BatchID)
		cancel()
		if err != nil {
			log.Printf("payout %s status: %v", p.ID, err)
			continue
		}
		s.mu.Lock()
		before := p.Status
		s.setPayoutStatusL(p, status)
		if p.Status != before {
			if p.Status == "returned" {
				s.reversePayoutL(p)
			}
			s.track(p)
			if err := s.commitL(); err != nil {
				log.Printf("payout %s: %v", p.ID, err)
			}
		}
		s.mu.Unlock()
	}
}

// reversePayoutL gives back a payout PayPal returned: the opposite of its
// payout entry.
func (s *Service) reversePayoutL(p *domain.Payout) {
	for _, e := range s.ledger.Entries() {
		if (e.Kind != "payout" && e.Kind != "spend") || e.Ref != p.ID {
			continue
		}
		back := make([]domain.Posting, len(e.Postings))
		for i, ps := range e.Postings {
			back[i] = domain.Posting{Account: ps.Account, Debit: ps.Credit, Credit: ps.Debit}
		}
		if err := s.postL(domain.Entry{ID: s.idL("je"), Kind: "payout_return", TripID: e.TripID, Ref: p.ID, At: s.now(), Postings: back}); err != nil {
			log.Printf("payout %s reversal: %v", p.ID, err)
			return
		}
		where := "your balance"
		if p.TripID != "" {
			where = "the trip wallet" // payouts made before trips went wallet-only
		}
		s.alertL(p.TripID, p.UserID, "money", "PayPal sent back "+INR(p.Amount), "It is back in "+where+". Check the PayPal email "+p.Email)
		return
	}
}

// payoutsForL is the person's own withdrawals, newest first.
func (s *Service) payoutsForL(userID string) []*domain.Payout {
	var out []*domain.Payout
	for i := len(s.payouts) - 1; i >= 0; i-- {
		p := s.payouts[i]
		if p.UserID == userID && p.Kind == PayoutWithdraw {
			out = append(out, p)
		}
	}
	return out
}

// Payouts lists the person's payouts after checking the open ones.
func (s *Service) Payouts(ctx context.Context, userID string) []*domain.Payout {
	s.RefreshPayouts(ctx, userID)
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]*domain.Payout{}, s.payoutsForL(userID)...)
}

// MoneyView answers "where is my money?": everything Pointy holds sits in
// one PayPal business account, and the ledger says whose it is.
type MoneyView struct {
	PayPalMode      string           `json:"paypal_mode"`
	PayPalEmail     string           `json:"paypal_email"`
	BusinessAccount Paise            `json:"business_account_paise"` // all of Pointy's money at PayPal, everyone's
	OwedToEveryone  Paise            `json:"owed_to_everyone_paise"` // all balances and trip shares: must equal the above
	Balanced        bool             `json:"balanced"`
	YourBalance     Paise            `json:"your_balance_paise"`
	YourTripShares  Paise            `json:"your_trip_shares_paise"`
	YouPaidIn       Paise            `json:"you_paid_in_paise"`  // your PayPal checkouts
	YouPaidOut      Paise            `json:"you_paid_out_paise"` // your withdrawals
	Payouts         []*domain.Payout `json:"payouts"`
}

// Money builds the MoneyView for one person.
func (s *Service) Money(ctx context.Context, userID string) (MoneyView, error) {
	s.RefreshPayouts(ctx, userID)
	s.mu.Lock()
	defer s.mu.Unlock()
	u, ok := s.users[userID]
	if !ok {
		return MoneyView{}, domain.NotFound("user")
	}
	v := MoneyView{PayPalMode: s.pp.Mode(), PayPalEmail: u.PayPalEmail, YourBalance: s.ledger.Owed(domain.PersonalAccount(userID))}
	assets := map[string]bool{}
	liabilities := map[string]bool{}
	for _, e := range s.ledger.Entries() {
		for _, p := range e.Postings {
			switch {
			case strings.HasPrefix(p.Account, "paypal:"):
				assets[p.Account] = true
			case strings.HasPrefix(p.Account, "personal:"), strings.HasPrefix(p.Account, "share:"):
				liabilities[p.Account] = true
			}
		}
	}
	for acc := range assets {
		v.BusinessAccount += s.ledger.Held(acc)
	}
	for acc := range liabilities {
		v.OwedToEveryone += s.ledger.Owed(acc)
	}
	v.Balanced = v.BusinessAccount == v.OwedToEveryone
	for _, t := range s.trips {
		if t.HasMember(userID) {
			v.YourTripShares += s.ledger.Owed(domain.ShareAccount(t.ID, userID))
		}
	}
	for _, d := range s.deposits {
		if d.UserID == userID && d.Status == "captured" {
			v.YouPaidIn += d.Amount
		}
	}
	for _, p := range s.payouts {
		if p.UserID == userID && p.Kind == PayoutWithdraw && p.Status != "failed" && p.Status != "returned" {
			v.YouPaidOut += p.Amount
		}
	}
	v.Payouts = s.payoutsForL(userID)
	if len(v.Payouts) > 20 {
		v.Payouts = v.Payouts[:20]
	}
	return v, nil
}
