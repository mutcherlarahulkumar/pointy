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

// An approval the child asked for before turning 18 cannot be used by the
// ex-parent to pay from what is now an adult's account.
func TestApprovalEndsWhenTheChildTurns18(t *testing.T) {
	s, _, c := newTestService(t, nil)
	p := register(t, s, "Rahul", "9876543210")
	k := register(t, s, "Meera", "9123456780")
	shop := register(t, s, "Canteen", "9988776655")
	topUp(t, s, p, 5000)
	inv := invite(t, s, p, "9123456780", "2008-10-14") // 18 tomorrow
	must[ChildView](t)(s.AcceptInvite(k, inv.Child.LinkID, inv.Code, pin))
	must[*domain.Expense](t)(s.PayPersonal(p, ExpenseInput{Description: "Pocket money", Amount: domain.Rupees(2000), PayeeUserID: k}))
	c.t = time.Date(2026, 10, 13, 23, 50, 0, 0, IST)
	a := must[ApprovalView](t)(s.AskApproval(k, ApprovalInput{PayeeID: shop, Amount: domain.Rupees(1000)}))
	c.t = time.Date(2026, 10, 14, 0, 5, 0, 0, IST) // Meera is 18 now
	before := balance(s, k)
	if _, err := s.DecideApproval(p, a.ID, true, pin); code(err) != "approval_closed" {
		t.Fatalf("approving after the child turned 18: %v", err)
	}
	if balance(s, k) != before {
		t.Fatal("money left an adult's account on the ex-parent's say-so")
	}
}
