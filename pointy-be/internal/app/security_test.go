package app

import (
	"context"
	"fmt"
	"sync"
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

// Trip payments to a Pointy user cannot push a child's wallet over the
// small-wallet caps.
func TestTripPaymentToAChildKeepsTheCaps(t *testing.T) {
	s, _, _, k := family(t)
	a := register(t, s, "Asha", "9811111111")
	b := register(t, s, "Dev", "9822222222")
	topUp(t, s, a, 20000)
	topUp(t, s, b, 20000)
	trip := goa(t, s, a, b)
	must[TripView](t)(s.DepositFromBalance(trip, a, domain.Rupees(15000)))
	must[TripView](t)(s.DepositFromBalance(trip, b, domain.Rupees(15000)))
	_, err := s.AddExpense(trip, a, ExpenseInput{Description: "Gift", Amount: domain.Rupees(20000), Mode: ModeMember, PayeeUserID: k, ConfirmOverBudget: true})
	if code(err) != "child_balance_cap" {
		t.Fatalf("trip paid a child past the cap: %v", err)
	}
	checkBooks(t, s)
}

// Linking cannot make a loop (two people each other's parent) or give a
// child a parent who is a child.
func TestLinksCannotLoopOrChain(t *testing.T) {
	s, _, _ := newTestService(t, nil)
	a := register(t, s, "Asha", "9811111111")
	b := register(t, s, "Dev", "9822222222")
	ab := invite(t, s, a, "9822222222", "2012-05-03") // a would look after b
	ba := invite(t, s, b, "9811111111", "2012-05-03") // b would look after a
	must[ChildView](t)(s.AcceptInvite(a, ba.Child.LinkID, ba.Code, pin))
	if _, err := s.AcceptInvite(b, ab.Child.LinkID, ab.Code, pin); code(err) != "is_parent" {
		t.Fatalf("b, a's parent, became a's child: %v", err)
	}

	p := register(t, s, "Rahul", "9876543210")
	k := register(t, s, "Meera", "9123456780")
	g := register(t, s, "Gita", "9833333333")
	pk := invite(t, s, p, "9123456780", "2012-05-03")
	gp := invite(t, s, g, "9876543210", "2012-05-03")
	must[ChildView](t)(s.AcceptInvite(p, gp.Child.LinkID, gp.Code, pin)) // Rahul is now a child
	if _, err := s.AcceptInvite(k, pk.Child.LinkID, pk.Code, pin); code(err) != "child_account" {
		t.Fatalf("a child became a parent: %v", err)
	}
}

// A PayPal top-up started before the account became a child account
// cannot be captured into the child's wallet.
func TestTopUpStartedBeforeLinkingIsNotCaptured(t *testing.T) {
	s, _, _ := newTestService(t, nil)
	p := register(t, s, "Rahul", "9876543210")
	k := register(t, s, "Meera", "9123456780")
	d := must[*domain.Deposit](t)(s.StartTopUp(context.Background(), k, domain.Rupees(50000)))
	inv := invite(t, s, p, "9123456780", "2012-05-03")
	must[ChildView](t)(s.AcceptInvite(k, inv.Child.LinkID, inv.Code, pin))
	if _, err := s.CaptureDeposit(context.Background(), d.OrderID); code(err) != "child_account" {
		t.Fatalf("capture into a child wallet: %v", err)
	}
	if b := balance(s, k); b != 0 {
		t.Fatalf("child holds %d", b)
	}
	checkBooks(t, s)
}

// A withdrawal PayPal may still send back cannot land in a child wallet
// past its caps: the account cannot be linked while one is on its way.
func TestNoLinkWhileAWithdrawalCanComeBack(t *testing.T) {
	s, pp, _ := newTestService(t, nil)
	ctx := context.Background()
	p := register(t, s, "Rahul", "9876543210")
	k := register(t, s, "Meera", "9123456780")
	topUp(t, s, k, 50000)
	must[Me](t)(s.SetPayPalEmail(k, "nobody@example.com"))
	pp.PayoutFirst, pp.PayoutLater = "UNCLAIMED", "RETURNED"
	must[*domain.Payout](t)(s.Withdraw(ctx, k, domain.Rupees(45000)))
	inv := invite(t, s, p, "9123456780", "2012-05-03")
	if _, err := s.AcceptInvite(k, inv.Child.LinkID, inv.Code, pin); code(err) != "child_payout_open" {
		t.Fatalf("linked with a withdrawal on its way: %v", err)
	}
	s.RefreshPayouts(ctx, k) // PayPal sends it back
	if b := balance(s, k); b != domain.Rupees(50000) {
		t.Fatalf("balance %d", b)
	}
	if _, err := s.AcceptInvite(k, inv.Child.LinkID, inv.Code, pin); code(err) != "child_balance_cap" {
		t.Fatalf("back over the cap: %v", err)
	}
}

// Anyone can invite any number, so an invite the child has not accepted
// must not show the inviter the account's money, spending or trips.
func TestInviteShowsNothingBeforeConsent(t *testing.T) {
	s, _, _ := newTestService(t, nil)
	x := register(t, s, "Stranger", "9988776655")
	v := register(t, s, "Victim", "9123456780")
	shop := register(t, s, "Shop", "9811111111")
	topUp(t, s, v, 5000)
	must[*domain.Expense](t)(s.PayPersonal(v, ExpenseInput{Description: "Lunch", Amount: domain.Rupees(700), PayeeUserID: shop}))
	inv := invite(t, s, x, "9123456780", "2012-05-03")
	if c := inv.Child; c.Balance != 0 || c.SpentToday != 0 || c.SpentMonth != 0 || c.ReceivedLeft != 0 {
		t.Fatalf("the invite shows the account: %+v", c)
	}
	if c := must[FamilyView](t)(s.Family(x)).Children[0]; c.Balance != 0 || c.SpentToday != 0 || c.SpentMonth != 0 {
		t.Fatalf("the parent's screen shows the account: %+v", c)
	}
	// A rich account, or one in a trip, gets an invite all the same: the
	// inviter learns nothing until the child says yes.
	topUp(t, s, v, 20000)
	goa(t, s, shop, v)
	if _, err := s.InviteChild(x, InviteInput{ChildPhone: "9123456780", BirthDate: "2012-05-03", DailyLimit: domain.Rupees(300),
		MonthlyLimit: domain.Rupees(3000), AcceptTerms: FamilyTermsVersion, PIN: pin}); err != nil {
		t.Fatalf("the invite told the inviter about the account: %v", err)
	}
}

// Firing many PIN guesses at once does not get more than five checked:
// the lockout counts a guess before the slow comparison, not after.
func TestPINGuessesAtOnceShareTheLockout(t *testing.T) {
	s, _, _ := newTestService(t, nil)
	u := register(t, s, "Asha", "9876543210")
	var wg sync.WaitGroup
	var mu sync.Mutex
	checked := 0
	for i := 0; i < 30; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			err := s.VerifyPIN(u, fmt.Sprintf("%06d", 100000+i))
			if code(err) == "wrong_pin" {
				mu.Lock()
				checked++
				mu.Unlock()
			}
		}(i)
	}
	wg.Wait()
	if checked > maxFailedPINs {
		t.Fatalf("%d guesses were checked; the lockout allows %d", checked, maxFailedPINs)
	}
	if err := s.VerifyPIN(u, pin); code(err) != "too_many_attempts" {
		t.Fatalf("should be locked: %v", err)
	}
}

// The time of a payment is the server's: a back-dated "at" cannot hide a
// child's spending or pocket money from this day's and month's limits.
func TestBackDatedPaymentsCountTowardsChildLimits(t *testing.T) {
	s, c, p, k := family(t)
	shop := register(t, s, "Canteen", "9988776655")
	lastMonth := c.t.AddDate(0, -1, 0)
	must[*domain.Expense](t)(s.PayPersonal(k, ExpenseInput{Description: "Snacks", Amount: domain.Rupees(250), PayeeUserID: shop, At: &lastMonth}))
	if _, err := s.PayPersonal(k, ExpenseInput{Description: "Snacks", Amount: domain.Rupees(250), PayeeUserID: shop, At: &lastMonth}); code(err) != "needs_parent" {
		t.Fatalf("₹500 today with a ₹300 daily limit: %v", err)
	}

	// Pocket money: ₹2,000 in already this month.
	must[ChildView](t)(s.SetChildLimits(p, k, domain.Rupees(10000), domain.Rupees(10000), pin))
	must[*domain.Expense](t)(s.PayPersonal(p, ExpenseInput{Description: "More", Amount: domain.Rupees(6000), PayeeUserID: k, At: &lastMonth}))
	for i := 0; i < 3; i++ {
		must[*domain.Expense](t)(s.PayPersonal(k, ExpenseInput{Description: "Books", Amount: domain.Rupees(2000), PayeeUserID: shop}))
	}
	if _, err := s.PayPersonal(p, ExpenseInput{Description: "Even more", Amount: domain.Rupees(3000), PayeeUserID: k}); code(err) != "child_month_cap" {
		t.Fatalf("₹11,000 received this month: %v", err)
	}
}

// A trip payment to a child counts in this month, whatever "at" says.
func TestBackDatedTripPaymentToAChildIsNow(t *testing.T) {
	s, c, _, k := family(t)
	a := register(t, s, "Asha", "9811111111")
	topUp(t, s, a, 5000)
	trip := goa(t, s, a)
	must[TripView](t)(s.DepositFromBalance(trip, a, domain.Rupees(3000)))
	lastMonth := c.t.AddDate(0, -1, 0)
	e := must[*domain.Expense](t)(s.AddExpense(trip, a, ExpenseInput{Description: "Gift", Amount: domain.Rupees(1000), Mode: ModeMember, PayeeUserID: k, At: &lastMonth}))
	if !e.At.Equal(c.t) {
		t.Fatalf("paid to a child at %v", e.At)
	}
}
