// Package store keeps Pointy's state in Postgres. The service holds a
// working copy in memory; this package loads it at start-up and writes each
// change in one transaction.
package store

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/app"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
)

type Postgres struct{ pool *pgxpool.Pool }

var _ app.Store = (*Postgres)(nil)

// Open connects and applies any migrations that have not run yet.
func Open(ctx context.Context, url string) (*Postgres, error) {
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		return nil, err
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("cannot reach the database: %w", err)
	}
	if _, err := Migrate(ctx, pool, Up, 0); err != nil {
		pool.Close()
		return nil, err
	}
	return &Postgres{pool: pool}, nil
}

func (p *Postgres) Close() { p.pool.Close() }

// Save writes every changed object in one transaction.
func (p *Postgres) Save(ctx context.Context, items []any) error {
	tx, err := p.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck // a no-op after Commit
	for _, it := range items {
		if err := save(ctx, tx, it); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}

func js(v any) []byte {
	b, _ := json.Marshal(v)
	return b
}

func save(ctx context.Context, tx pgx.Tx, it any) error {
	var err error
	switch v := it.(type) {
	case *domain.User:
		_, err = tx.Exec(ctx, `INSERT INTO users (id, name, phone, pin_hash, alerts_seen_at, created_at) VALUES ($1,$2,$3,$4,$5,$6)
			ON CONFLICT (id) DO UPDATE SET name=$2, phone=$3, pin_hash=$4, alerts_seen_at=$5`,
			v.ID, v.Name, v.Phone, v.PinHash, v.AlertsSeenAt, v.CreatedAt)
	case domain.Session:
		_, err = tx.Exec(ctx, `INSERT INTO sessions (token_hash, user_id, created_at) VALUES ($1,$2,$3) ON CONFLICT DO NOTHING`, v.TokenHash, v.UserID, v.CreatedAt)
	case domain.SessionEnd:
		_, err = tx.Exec(ctx, `DELETE FROM sessions WHERE token_hash=$1`, v.TokenHash)
	case *domain.Trip:
		_, err = tx.Exec(ctx, `INSERT INTO trips (id, name, place, start_at, end_at, organiser_id, members, deposit_target, budgets, status, created_at)
			VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
			ON CONFLICT (id) DO UPDATE SET name=$2, place=$3, start_at=$4, end_at=$5, members=$7, deposit_target=$8, budgets=$9, status=$10`,
			v.ID, v.Name, v.Place, v.Start, v.End, v.OrganiserID, js(v.Members), int64(v.DepositTarget), js(v.Budgets), v.Status, v.CreatedAt)
	case domain.Entry:
		// Journal entries are append-only: an id is written once.
		var tag pgconn.CommandTag
		tag, err = tx.Exec(ctx, `INSERT INTO ledger_entries (id, kind, trip_id, ref, at) VALUES ($1,$2,$3,$4,$5) ON CONFLICT DO NOTHING`, v.ID, v.Kind, v.TripID, v.Ref, v.At)
		if err == nil && tag.RowsAffected() == 1 {
			for i, ps := range v.Postings {
				if _, err = tx.Exec(ctx, `INSERT INTO ledger_postings (entry_id, line, account, debit, credit) VALUES ($1,$2,$3,$4,$5)`,
					v.ID, i, ps.Account, int64(ps.Debit), int64(ps.Credit)); err != nil {
					break
				}
			}
		}
	case *domain.Deposit:
		_, err = tx.Exec(ctx, `INSERT INTO deposits (order_id, id, trip_id, user_id, amount, approve_url, status, created_at) VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
			ON CONFLICT (order_id) DO UPDATE SET status=$7`,
			v.OrderID, v.ID, v.TripID, v.UserID, int64(v.Amount), v.ApproveURL, v.Status, v.CreatedAt)
	case *domain.Expense:
		_, err = tx.Exec(ctx, `INSERT INTO expenses (id, trip_id, paid_by, description, category, amount, mode, payee, payee_user_id, shares, place_name, place_type, lat, lng, at)
			VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15) ON CONFLICT DO NOTHING`,
			v.ID, v.TripID, v.PaidBy, v.Description, string(v.Category), int64(v.Amount), v.Mode, v.Payee, v.PayeeUserID, js(v.Shares),
			v.PlaceName, v.PlaceType, v.Lat, v.Lng, v.At)
	case *domain.DepositRequest:
		_, err = tx.Exec(ctx, `INSERT INTO deposit_requests (id, trip_id, user_id, amount, due, status, reminders, paid_at, paid_via) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
			ON CONFLICT (id) DO UPDATE SET amount=$4, due=$5, status=$6, reminders=$7, paid_at=$8, paid_via=$9`,
			v.ID, v.TripID, v.UserID, int64(v.Amount), v.Due, v.Status, js(v.Reminders), v.PaidAt, v.PaidVia)
	case *domain.Plan:
		_, err = tx.Exec(ctx, `INSERT INTO plans (id, trip_id, body) VALUES ($1,$2,$3) ON CONFLICT (id) DO UPDATE SET body=$3`, v.ID, v.TripID, js(v))
	case *domain.Alert:
		_, err = tx.Exec(ctx, `INSERT INTO alerts (id, trip_id, user_id, kind, title, body, at) VALUES ($1,$2,$3,$4,$5,$6,$7) ON CONFLICT DO NOTHING`,
			v.ID, v.TripID, v.UserID, v.Kind, v.Title, v.Body, v.At)
	case *domain.MoneyRequest:
		_, err = tx.Exec(ctx, `INSERT INTO money_requests (id, requester_id, payer_id, amount, note, status, created_at, closed_at) VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
			ON CONFLICT (id) DO UPDATE SET status=$6, closed_at=$8`,
			v.ID, v.RequesterID, v.PayerID, int64(v.Amount), v.Note, v.Status, v.CreatedAt, v.ClosedAt)
	default:
		return fmt.Errorf("store: cannot save %T", it)
	}
	if err != nil {
		return fmt.Errorf("store: saving %T: %w", it, err)
	}
	return nil
}

// Load reads everything in creation order.
func (p *Postgres) Load(ctx context.Context) (*app.Snapshot, error) {
	s := &app.Snapshot{}
	q := func(sql string, scan func(pgx.Rows) error) error {
		rows, err := p.pool.Query(ctx, sql)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			if err := scan(rows); err != nil {
				return err
			}
		}
		return rows.Err()
	}
	steps := []func() error{
		func() error {
			return q(`SELECT id, name, phone, pin_hash, alerts_seen_at, created_at FROM users ORDER BY seq`, func(r pgx.Rows) error {
				u := &domain.User{}
				if err := r.Scan(&u.ID, &u.Name, &u.Phone, &u.PinHash, &u.AlertsSeenAt, &u.CreatedAt); err != nil {
					return err
				}
				s.Users = append(s.Users, u)
				return nil
			})
		},
		func() error {
			return q(`SELECT token_hash, user_id, created_at FROM sessions`, func(r pgx.Rows) error {
				var se domain.Session
				if err := r.Scan(&se.TokenHash, &se.UserID, &se.CreatedAt); err != nil {
					return err
				}
				s.Sessions = append(s.Sessions, se)
				return nil
			})
		},
		func() error {
			return q(`SELECT id, name, place, start_at, end_at, organiser_id, members, deposit_target, budgets, status, created_at FROM trips ORDER BY seq`, func(r pgx.Rows) error {
				t := &domain.Trip{}
				var members, budgets []byte
				var target int64
				if err := r.Scan(&t.ID, &t.Name, &t.Place, &t.Start, &t.End, &t.OrganiserID, &members, &target, &budgets, &t.Status, &t.CreatedAt); err != nil {
					return err
				}
				t.DepositTarget = domain.Paise(target)
				if err := json.Unmarshal(members, &t.Members); err != nil {
					return err
				}
				if err := json.Unmarshal(budgets, &t.Budgets); err != nil {
					return err
				}
				if t.Budgets == nil {
					t.Budgets = map[domain.Category]domain.Paise{}
				}
				s.Trips = append(s.Trips, t)
				return nil
			})
		},
		func() error {
			byID := map[string]int{}
			if err := q(`SELECT id, kind, trip_id, ref, at FROM ledger_entries ORDER BY seq`, func(r pgx.Rows) error {
				var e domain.Entry
				if err := r.Scan(&e.ID, &e.Kind, &e.TripID, &e.Ref, &e.At); err != nil {
					return err
				}
				byID[e.ID] = len(s.Entries)
				s.Entries = append(s.Entries, e)
				return nil
			}); err != nil {
				return err
			}
			return q(`SELECT entry_id, account, debit, credit FROM ledger_postings ORDER BY entry_id, line`, func(r pgx.Rows) error {
				var id, acc string
				var d, c int64
				if err := r.Scan(&id, &acc, &d, &c); err != nil {
					return err
				}
				i, ok := byID[id]
				if !ok {
					return fmt.Errorf("posting for unknown entry %s", id)
				}
				s.Entries[i].Postings = append(s.Entries[i].Postings, domain.Posting{Account: acc, Debit: domain.Paise(d), Credit: domain.Paise(c)})
				return nil
			})
		},
		func() error {
			return q(`SELECT order_id, id, trip_id, user_id, amount, approve_url, status, created_at FROM deposits ORDER BY seq`, func(r pgx.Rows) error {
				d := &domain.Deposit{}
				var amt int64
				if err := r.Scan(&d.OrderID, &d.ID, &d.TripID, &d.UserID, &amt, &d.ApproveURL, &d.Status, &d.CreatedAt); err != nil {
					return err
				}
				d.Amount = domain.Paise(amt)
				if d.Status == "capturing" { // interrupted mid-capture: let it be tried again
					d.Status = "created"
				}
				s.Deposits = append(s.Deposits, d)
				return nil
			})
		},
		func() error {
			return q(`SELECT id, trip_id, paid_by, description, category, amount, mode, payee, payee_user_id, shares, place_name, place_type, lat, lng, at FROM expenses ORDER BY seq`, func(r pgx.Rows) error {
				e := &domain.Expense{}
				var cat string
				var amt int64
				var shares []byte
				if err := r.Scan(&e.ID, &e.TripID, &e.PaidBy, &e.Description, &cat, &amt, &e.Mode, &e.Payee, &e.PayeeUserID, &shares, &e.PlaceName, &e.PlaceType, &e.Lat, &e.Lng, &e.At); err != nil {
					return err
				}
				e.Category, e.Amount = domain.Category(cat), domain.Paise(amt)
				if err := json.Unmarshal(shares, &e.Shares); err != nil {
					return err
				}
				s.Expenses = append(s.Expenses, e)
				return nil
			})
		},
		func() error {
			return q(`SELECT id, trip_id, user_id, amount, due, status, reminders, paid_at, paid_via FROM deposit_requests ORDER BY seq`, func(r pgx.Rows) error {
				d := &domain.DepositRequest{}
				var amt int64
				var rem []byte
				if err := r.Scan(&d.ID, &d.TripID, &d.UserID, &amt, &d.Due, &d.Status, &rem, &d.PaidAt, &d.PaidVia); err != nil {
					return err
				}
				d.Amount = domain.Paise(amt)
				if err := json.Unmarshal(rem, &d.Reminders); err != nil {
					return err
				}
				if d.Reminders == nil {
					d.Reminders = []time.Time{}
				}
				d.RemindersSent = len(d.Reminders)
				s.Requests = append(s.Requests, d)
				return nil
			})
		},
		func() error {
			return q(`SELECT body FROM plans ORDER BY seq`, func(r pgx.Rows) error {
				var b []byte
				if err := r.Scan(&b); err != nil {
					return err
				}
				pl := &domain.Plan{}
				if err := json.Unmarshal(b, pl); err != nil {
					return err
				}
				s.Plans = append(s.Plans, pl)
				return nil
			})
		},
		func() error {
			return q(`SELECT id, trip_id, user_id, kind, title, body, at FROM alerts ORDER BY seq`, func(r pgx.Rows) error {
				a := &domain.Alert{}
				if err := r.Scan(&a.ID, &a.TripID, &a.UserID, &a.Kind, &a.Title, &a.Body, &a.At); err != nil {
					return err
				}
				s.Alerts = append(s.Alerts, a)
				return nil
			})
		},
		func() error {
			return q(`SELECT id, requester_id, payer_id, amount, note, status, created_at, closed_at FROM money_requests ORDER BY seq`, func(r pgx.Rows) error {
				m := &domain.MoneyRequest{}
				var amt int64
				if err := r.Scan(&m.ID, &m.RequesterID, &m.PayerID, &amt, &m.Note, &m.Status, &m.CreatedAt, &m.ClosedAt); err != nil {
					return err
				}
				m.Amount = domain.Paise(amt)
				s.MoneyRequests = append(s.MoneyRequests, m)
				return nil
			})
		},
	}
	for _, step := range steps {
		if err := step(); err != nil {
			return nil, fmt.Errorf("store: loading: %w", err)
		}
	}
	return s, nil
}
