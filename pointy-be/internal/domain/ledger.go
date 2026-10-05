package domain

import "time"

// Account names. The ledger only ever sees strings, so every kind of wallet
// goes through the same code path.
func ShareAccount(tripID, userID string) string { return "share:" + tripID + ":" + userID }
func ClearingAccount(tripID string) string      { return "paypal:" + tripID }
func PersonalAccount(userID string) string      { return "personal:" + userID }

const PersonalClearing = "paypal:personal"

type Posting struct {
	Account string `json:"account"`
	Debit   Paise  `json:"debit_paise"`
	Credit  Paise  `json:"credit_paise"`
}

type Entry struct {
	ID       string    `json:"id"`
	Kind     string    `json:"kind"` // deposit, spend, refund, topup, transfer, withdrawal
	TripID   string    `json:"trip_id,omitempty"`
	Ref      string    `json:"ref"`
	At       time.Time `json:"at"`
	Postings []Posting `json:"postings"`
}

// Validate enforces the double-entry rule: debits equal credits.
func (e Entry) Validate() error {
	if len(e.Postings) < 2 {
		return Invalid("a journal entry needs at least two postings")
	}
	var d, c Paise
	for _, p := range e.Postings {
		if p.Debit < 0 || p.Credit < 0 || (p.Debit == 0) == (p.Credit == 0) {
			return Invalid("each posting must be exactly one of debit or credit, and positive")
		}
		d += p.Debit
		c += p.Credit
	}
	if d != c {
		return Invalid("entry does not balance: debits %d, credits %d", d, c)
	}
	return nil
}

// Ledger is append-only. Balances are always derived from the entries.
type Ledger struct{ entries []Entry }

func (l *Ledger) Post(e Entry) error {
	if err := e.Validate(); err != nil {
		return err
	}
	l.entries = append(l.entries, e)
	return nil
}

func (l *Ledger) Entries() []Entry { return l.entries }

// Load replaces the entries with ones read from storage, in posting order.
func (l *Ledger) Load(entries []Entry) { l.entries = entries }

// Totals returns the debits and credits posted to an account, optionally for
// one kind of entry only (pass "" for all kinds).
func (l *Ledger) Totals(account, kind string) (debit, credit Paise) {
	for _, e := range l.entries {
		if kind != "" && e.Kind != kind {
			continue
		}
		for _, p := range e.Postings {
			if p.Account == account {
				debit += p.Debit
				credit += p.Credit
			}
		}
	}
	return
}

// Owed is the balance of a liability account (a member's share, a personal
// wallet): what the app owes that person.
func (l *Ledger) Owed(account string) Paise {
	d, c := l.Totals(account, "")
	return c - d
}

// Held is the balance of an asset account (money sitting at PayPal).
func (l *Ledger) Held(account string) Paise {
	d, c := l.Totals(account, "")
	return d - c
}
