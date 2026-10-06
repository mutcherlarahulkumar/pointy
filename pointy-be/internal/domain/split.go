package domain

import (
	"math"
	"math/bits"
)

type SplitMethod string

const (
	SplitEqual  SplitMethod = "equal"
	SplitShares SplitMethod = "shares"
	SplitExact  SplitMethod = "exact"
)

// SplitInput is one participant. Weight is used by "shares", Exact by "exact".
type SplitInput struct {
	UserID string `json:"user_id"`
	Weight int64  `json:"weight,omitempty"`
	Exact  Paise  `json:"exact_paise,omitempty"`
}

// Split divides total between participants. The parts always add up to total:
// any paise left over after integer division go one at a time to the first
// participants in the list.
func Split(total Paise, method SplitMethod, in []SplitInput) ([]Share, error) {
	if total <= 0 {
		return nil, Invalid("amount must be more than zero")
	}
	if len(in) == 0 {
		return nil, Invalid("at least one person must share the payment")
	}
	seen := map[string]bool{}
	for _, p := range in {
		if p.UserID == "" || seen[p.UserID] {
			return nil, Invalid("participants must be unique and have a user_id")
		}
		seen[p.UserID] = true
	}
	out := make([]Share, len(in))
	switch method {
	case SplitExact:
		var sum Paise
		for i, p := range in {
			if p.Exact < 0 {
				return nil, Invalid("exact amounts cannot be negative")
			}
			if p.Exact > total-sum { // also stops the sum wrapping around
				return nil, Invalid("exact amounts add up to more than %d paise", total)
			}
			out[i] = Share{p.UserID, p.Exact}
			sum += p.Exact
		}
		if sum != total {
			return nil, Invalid("exact amounts add up to %d paise, expected %d", sum, total)
		}
		return out, nil
	case SplitEqual, SplitShares, "":
		var sumW int64
		w := make([]int64, len(in))
		for i, p := range in {
			w[i] = 1
			if method == SplitShares {
				w[i] = p.Weight
			}
			if w[i] <= 0 {
				return nil, Invalid("every share weight must be more than zero")
			}
			if w[i] > math.MaxInt64-sumW {
				return nil, Invalid("share weights are too large")
			}
			sumW += w[i]
		}
		var given Paise
		for i, p := range in {
			// total*w can pass int64, so multiply into 128 bits. The
			// quotient fits: w <= sumW, so it is at most total.
			hi, lo := bits.Mul64(uint64(total), uint64(w[i]))
			q, _ := bits.Div64(hi, lo, uint64(sumW))
			part := Paise(q)
			out[i] = Share{p.UserID, part}
			given += part
		}
		for i := 0; given < total; i = (i + 1) % len(out) {
			out[i].Amount++
			given++
		}
		return out, nil
	}
	return nil, Invalid("unknown split method %q", method)
}
