package app

import (
	"testing"
	"time"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
)

// A child cannot guess the parent's 6-digit approval code: after five wrong
// codes, codes are refused for a while, even the right one.
func TestParentCodeCannotBeGuessed(t *testing.T) {
	s, c, p, k := family(t)
	shop := register(t, s, "Canteen", "9988776655")
	pay := func(code string) error {
		_, err := s.PayPersonal(k, ExpenseInput{Description: "Snacks", Amount: domain.Rupees(400), PayeeUserID: shop, ParentCode: code})
		return err
	}
	key := must[CodeKey](t)(s.ChildCodeKey(p, k, pin))
	right := totpAt(key.Secret, c.t.Unix()/totpStep)
	wrong := "000000"
	if wrong == right {
		wrong = "000001"
	}
	for i := 0; i < maxCodeAttempts; i++ {
		if err := pay(wrong); code(err) != "wrong_parent_code" {
			t.Fatalf("try %d: %v", i, err)
		}
	}
	if err := pay(right); code(err) != "too_many_codes" {
		t.Fatalf("the right code after five wrong ones: %v", err)
	}
	c.t = c.t.Add(codeLockout + time.Minute)
	right = totpAt(key.Secret, c.t.Unix()/totpStep)
	if err := pay(right); err != nil {
		t.Fatalf("after the lockout: %v", err)
	}
}
