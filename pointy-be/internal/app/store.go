package app

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"log"
	"net/http"
	"time"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
)

// Store keeps the service's state durable. The service holds everything in
// memory for fast reads and calls Save once per change with every object
// that changed; a Postgres store writes them in one transaction.
type Store interface {
	Load(ctx context.Context) (*Snapshot, error)
	// Save writes the changed objects atomically. Items are *domain.User,
	// domain.Session, domain.SessionEnd, *domain.Trip, domain.Entry,
	// *domain.Deposit, *domain.Expense, *domain.DepositRequest,
	// *domain.Plan, *domain.Alert and *domain.MoneyRequest.
	Save(ctx context.Context, items []any) error
}

// Snapshot is everything the service needs to start, in creation order.
type Snapshot struct {
	Users         []*domain.User
	Sessions      []domain.Session
	Trips         []*domain.Trip
	Entries       []domain.Entry
	Deposits      []*domain.Deposit
	Expenses      []*domain.Expense
	Requests      []*domain.DepositRequest
	Plans         []*domain.Plan
	Alerts        []*domain.Alert
	MoneyRequests []*domain.MoneyRequest
	Chats         []*domain.ChatMessage
}

// MemoryStore keeps nothing: state lives only as long as the process. Tests
// and a local run without DATABASE_URL use it.
type MemoryStore struct{}

func (MemoryStore) Load(context.Context) (*Snapshot, error) { return &Snapshot{}, nil }
func (MemoryStore) Save(context.Context, []any) error       { return nil }

// track marks an object as changed by the operation in progress.
func (s *Service) track(items ...any) { s.pending = append(s.pending, items...) }

// commitL saves every tracked change in one transaction. If the database
// refuses, the in-memory state is reloaded from it so the two never drift
// apart, and the caller gets an error.
func (s *Service) commitL() error {
	if len(s.pending) == 0 {
		return nil
	}
	items := s.pending
	s.pending = nil
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := s.store.Save(ctx, items); err != nil {
		log.Printf("CRITICAL: could not save %d changes: %v; reloading state from the database", len(items), err)
		if lerr := s.loadL(ctx); lerr != nil {
			log.Printf("CRITICAL: reload failed too: %v", lerr)
		}
		return &domain.Error{Status: http.StatusServiceUnavailable, Code: "storage_error", Message: "could not save, please try again"}
	}
	return nil
}

// Load reads the saved state. Call it once before serving requests.
func (s *Service) Load(ctx context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.loadL(ctx)
}

func (s *Service) loadL(ctx context.Context) error {
	snap, err := s.store.Load(ctx)
	if err != nil {
		return err
	}
	s.users, s.sessions, s.phones = map[string]*domain.User{}, map[string]string{}, map[string]string{}
	for _, u := range snap.Users {
		s.users[u.ID] = u
		if u.Phone != "" {
			s.phones[u.Phone] = u.ID
		}
	}
	for _, se := range snap.Sessions {
		s.sessions[se.TokenHash] = se.UserID
	}
	s.trips, s.tripOrder = map[string]*domain.Trip{}, nil
	for _, t := range snap.Trips {
		s.trips[t.ID] = t
		s.tripOrder = append(s.tripOrder, t.ID)
	}
	s.ledger = &domain.Ledger{}
	s.ledger.Load(snap.Entries)
	s.deposits = map[string]*domain.Deposit{}
	for _, d := range snap.Deposits {
		s.deposits[d.OrderID] = d
	}
	s.expenses = snap.Expenses
	s.requests, s.reqOrder = map[string]*domain.DepositRequest{}, nil
	for _, r := range snap.Requests {
		s.requests[r.ID] = r
		s.reqOrder = append(s.reqOrder, r.ID)
	}
	s.plans = map[string]*domain.Plan{}
	for _, p := range snap.Plans {
		s.plans[p.ID] = p
	}
	s.alerts = snap.Alerts
	s.moneyRequests = snap.MoneyRequests
	s.chats = map[string][]*domain.ChatMessage{}
	for _, m := range snap.Chats {
		s.chats[m.UserID] = append(s.chats[m.UserID], m)
	}
	s.pending = nil
	return nil
}

// newID makes an id that stays unique across restarts: "exp_3f9c2a1b7d04".
func newID(prefix string) string {
	b := make([]byte, 6)
	_, _ = rand.Read(b)
	return prefix + "_" + hex.EncodeToString(b)
}
