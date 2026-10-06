package domain

import (
	"math"
	"testing"
)

func sum(shares []Share) (t Paise) {
	for _, s := range shares {
		t += s.Amount
	}
	return t
}

func TestSplitOddAmountsAddUp(t *testing.T) {
	got, err := Split(100, SplitEqual, []SplitInput{{UserID: "a"}, {UserID: "b"}, {UserID: "c"}})
	if err != nil || got[0].Amount != 34 || got[1].Amount != 33 || got[2].Amount != 33 {
		t.Fatalf("₹1 between 3: %+v %v", got, err)
	}
	got, err = Split(1, SplitEqual, []SplitInput{{UserID: "a"}, {UserID: "b"}})
	if err != nil || got[0].Amount != 1 || got[1].Amount != 0 {
		t.Fatalf("1 paisa between 2: %+v %v", got, err)
	}
	if _, err := Split(100, SplitShares, []SplitInput{{UserID: "a", Weight: 0}}); err == nil {
		t.Fatal("weight 0 accepted")
	}
	if _, err := Split(100, SplitExact, []SplitInput{{UserID: "a", Exact: 60}, {UserID: "b", Exact: 39}}); err == nil {
		t.Fatal("exact amounts one paisa short accepted")
	}
}

// Huge weights must not overflow into negative or lopsided shares (or a
// near-endless loop handing out the "leftover" paise one at a time).
func TestSplitHugeWeights(t *testing.T) {
	big := int64(math.MaxInt64 / 2)
	got, err := Split(1000, SplitShares, []SplitInput{{UserID: "a", Weight: big}, {UserID: "b", Weight: big}})
	if err != nil {
		t.Fatal(err)
	}
	if got[0].Amount != 500 || got[1].Amount != 500 {
		t.Fatalf("equal huge weights: %+v", got)
	}
	got, err = Split(10000000, SplitShares, []SplitInput{{UserID: "a", Weight: 1e12}, {UserID: "b", Weight: 3e12}})
	if err != nil || got[0].Amount != 2500000 || got[1].Amount != 7500000 {
		t.Fatalf("1:3 with big weights: %+v %v", got, err)
	}
	got, err = Split(10000000, SplitShares, []SplitInput{{UserID: "a", Weight: math.MaxInt64 - 10}, {UserID: "b", Weight: 1}})
	if err == nil {
		for _, s := range got {
			if s.Amount < 0 {
				t.Fatalf("negative share: %+v", got)
			}
		}
		if sum(got) != 10000000 {
			t.Fatalf("shares add up to %d", sum(got))
		}
	}
	// Weights whose sum overflows are refused.
	if _, err := Split(100, SplitShares, []SplitInput{{UserID: "a", Weight: math.MaxInt64}, {UserID: "b", Weight: math.MaxInt64}}); err == nil {
		t.Fatal("overflowing weights accepted")
	}
}

// Exact amounts that wrap around int64 must not pass as adding up.
func TestSplitExactOverflow(t *testing.T) {
	in := []SplitInput{{UserID: "a", Exact: math.MaxInt64}, {UserID: "b", Exact: math.MaxInt64}, {UserID: "c", Exact: 102}}
	if got, err := Split(100, SplitExact, in); err == nil {
		t.Fatalf("wrapped exact amounts accepted: %+v", got)
	}
}
