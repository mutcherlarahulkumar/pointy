package app

import (
	"time"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
)

// IST is the time zone the demo data is written in.
var IST = time.FixedZone("IST", 5*3600+1800)

// DemoNow is the moment the designs show: Tuesday evening, day 2 of the trip.
var DemoNow = time.Date(2026, 10, 13, 20, 42, 0, 0, IST)

// SeedDemo loads the Goa trip from the designs so every screen has data.
// It writes straight to the ledger; no PayPal call is made.
func SeedDemo(s *Service) {
	s.mu.Lock()
	defer s.mu.Unlock()
	at := func(day, h, m int) time.Time { return time.Date(2026, 10, day, h, m, 0, 0, IST) }
	for _, u := range []*domain.User{
		{ID: "u_you", Name: "You", PayPalEmail: "you@example.com"},
		{ID: "u_asha", Name: "Asha", PayPalEmail: "asha@example.com"},
		{ID: "u_dev", Name: "Dev", PayPalEmail: "dev@example.com"},
		{ID: "u_meera", Name: "Meera", PayPalEmail: "meera@example.com"},
	} {
		s.users[u.ID] = u
	}
	must := func(err error) {
		if err != nil {
			panic(err)
		}
	}
	must(s.ledger.Post(domain.Entry{ID: s.idL("je"), Kind: "deposit", Ref: "seed", At: at(1, 9, 0), Postings: []domain.Posting{
		{Account: domain.PersonalClearing, Debit: domain.Rupees(8430)}, {Account: domain.PersonalAccount("u_you"), Credit: domain.Rupees(8430)},
	}}))
	members := []string{"u_you", "u_asha", "u_dev", "u_meera"}
	t := &domain.Trip{ID: "t_goa", Name: "Goa trip", Place: "Goa", Start: at(12, 0, 0), End: at(16, 0, 0), OrganiserID: "u_you", Members: members,
		DepositTarget: domain.Rupees(6000), Status: domain.TripOpen, CreatedAt: at(5, 10, 0),
		Budgets: map[domain.Category]Paise{domain.Food: domain.Rupees(5000), domain.Stay: domain.Rupees(10000), domain.Transport: domain.Rupees(4000), domain.Other: domain.Rupees(5000)}}
	s.trips[t.ID] = t
	s.tripOrder = append(s.tripOrder, t.ID)

	must(s.creditShareL(t.ID, "u_asha", domain.Rupees(6000), "seed", at(6, 11, 0)))
	must(s.creditShareL(t.ID, "u_dev", domain.Rupees(6000), "seed", at(8, 18, 30)))
	must(s.creditShareL(t.ID, "u_you", domain.Rupees(3000), "seed", at(9, 9, 15)))
	must(s.creditShareL(t.ID, "u_meera", domain.Rupees(6000), "seed", at(10, 18, 10)))
	paid := func(uid string, day, reminders int) {
		when := at(day, 18, 0)
		r := &domain.DepositRequest{ID: s.idL("req"), TripID: t.ID, UserID: uid, Amount: domain.Rupees(6000), Due: at(10, 0, 0), InvoiceID: "INV2-SEED-" + uid, Status: "paid", RemindersSent: reminders, Reminders: []time.Time{}, PaidAt: &when}
		s.requests[r.ID] = r
		s.reqOrder = append(s.reqOrder, r.ID)
	}
	paid("u_asha", 6, 0)
	paid("u_dev", 8, 1)
	paid("u_meera", 10, 2)

	spend := func(desc string, cat domain.Category, rupees int64, place, ptype string, when time.Time) {
		in := make([]domain.SplitInput, len(members))
		for i, m := range members {
			in[i] = domain.SplitInput{UserID: m}
		}
		shares, err := domain.Split(domain.Rupees(rupees), domain.SplitEqual, in)
		must(err)
		id := s.idL("exp")
		postings := []domain.Posting{{Account: domain.ClearingAccount(t.ID), Credit: domain.Rupees(rupees)}}
		for _, sh := range shares {
			postings = append(postings, domain.Posting{Account: domain.ShareAccount(t.ID, sh.UserID), Debit: sh.Amount})
		}
		must(s.ledger.Post(domain.Entry{ID: s.idL("je"), Kind: "spend", TripID: t.ID, Ref: id, At: when, Postings: postings}))
		s.expenses = append(s.expenses, &domain.Expense{ID: id, TripID: t.ID, PaidBy: "u_you", Description: desc, Category: cat, Amount: domain.Rupees(rupees),
			Mode: ModePayee, Payee: desc, Shares: shares, PlaceName: place, PlaceType: ptype, At: when, PayoutID: "seed"})
	}
	spend("Airport cab", domain.Transport, 1200, "Dabolim Airport", "taxi", at(12, 10, 40))
	spend("Scooter rental", domain.Transport, 1600, "Calangute", "rental", at(12, 13, 20))
	spend("Villa stay", domain.Stay, 3600, "Anjuna", "lodging", at(12, 15, 0))
	spend("Groceries", domain.Food, 488, "Calangute", "grocery", at(12, 17, 30))
	spend("Dinner, beach shack", domain.Food, 1920, "Baga", "restaurant", at(12, 21, 10))

	s.alerts = append(s.alerts,
		&domain.Alert{ID: s.idL("al"), TripID: t.ID, UserID: "u_you", Kind: "deposit", Title: "Deposit due today", Body: "₹3,000 of your ₹6,000 is still open", At: at(10, 9, 0)},
		&domain.Alert{ID: s.idL("al"), TripID: t.ID, UserID: "u_you", Kind: "assistant", Title: "Assistant: every request is paid", Body: "Reminders have stopped", At: at(10, 18, 10)},
		&domain.Alert{ID: s.idL("al"), TripID: t.ID, Kind: "budget", Title: "Transport budget at 70%", Body: "₹1,200 left", At: at(12, 13, 20)},
	)
}
