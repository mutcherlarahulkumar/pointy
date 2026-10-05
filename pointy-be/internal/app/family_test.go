package app

import (
	"context"
	"testing"
	"time"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
)

const pin = "246810" // every test account's PIN (see register)

func invite(t *testing.T, s *Service, parent, childPhone, birth string) Invite {
	t.Helper()
	return must[Invite](t)(s.InviteChild(parent, InviteInput{ChildPhone: childPhone, BirthDate: birth,
		DailyLimit: domain.Rupees(300), MonthlyLimit: domain.Rupees(3000), AcceptTerms: FamilyTermsVersion, PIN: pin}))
}

// family is Rahul (parent) linked to Meera (14), both with some money.
func family(t *testing.T) (*Service, *clock, string, string) {
	t.Helper()
	s, _, c := newTestService(t, nil)
	p := register(t, s, "Rahul", "9876543210")
	k := register(t, s, "Meera", "9123456780")
	topUp(t, s, p, 20000)
	inv := invite(t, s, p, "9123456780", "2012-05-03")
	must[ChildView](t)(s.AcceptInvite(k, inv.Child.LinkID, inv.Code, pin))
	must[*domain.Expense](t)(s.PayPersonal(p, ExpenseInput{Description: "Pocket money", Amount: domain.Rupees(2000), PayeeUserID: k}))
	return s, c, p, k
}

func TestLinkingNeedsBothPhonesAndOnlyChildren(t *testing.T) {
	s, _, _ := newTestService(t, nil)
	p := register(t, s, "Rahul", "9876543210")
	k := register(t, s, "Meera", "9123456780")
	x := register(t, s, "Stranger", "9988776655")
	in := InviteInput{ChildPhone: "9123456780", BirthDate: "2012-05-03", DailyLimit: domain.Rupees(300), MonthlyLimit: domain.Rupees(3000), PIN: pin}

	if _, err := s.InviteChild(p, in); code(err) != "invalid" {
		t.Fatalf("without the terms: %v", err)
	}
	in.AcceptTerms = FamilyTermsVersion
	bad := in
	bad.PIN = "111111"
	if _, err := s.InviteChild(p, bad); code(err) != "wrong_pin" {
		t.Fatalf("wrong parent PIN: %v", err)
	}
	adult := in
	adult.BirthDate = "2000-01-01"
	if _, err := s.InviteChild(p, adult); code(err) != "not_a_child" {
		t.Fatalf("an adult cannot be made a child: %v", err)
	}
	over := in
	over.MonthlyLimit = domain.Rupees(20000)
	if _, err := s.InviteChild(p, over); code(err) != "invalid" {
		t.Fatalf("limit over the RBI cap: %v", err)
	}

	inv := must[Invite](t)(s.InviteChild(p, in))
	if len(inv.Code) != 6 || inv.Child.Status != "invited" {
		t.Fatalf("invite %+v", inv)
	}
	// Nothing has changed for Meera yet.
	if me := must[Me](t)(s.Me(k)); me.FamilyRole != "" || me.FamilyInvites != 1 {
		t.Fatalf("before accepting: %+v", me)
	}
	// Someone else cannot accept it; Meera needs the right code and her PIN.
	if _, err := s.AcceptInvite(x, inv.Child.LinkID, inv.Code, pin); code(err) != "not_found" {
		t.Fatalf("stranger: %v", err)
	}
	if _, err := s.AcceptInvite(k, inv.Child.LinkID, "000000", pin); code(err) != "wrong_code" {
		t.Fatalf("wrong code: %v", err)
	}
	if _, err := s.AcceptInvite(k, inv.Child.LinkID, inv.Code, "111111"); code(err) != "wrong_pin" {
		t.Fatalf("wrong child PIN: %v", err)
	}
	cv := must[ChildView](t)(s.AcceptInvite(k, inv.Child.LinkID, inv.Code, pin))
	if cv.Status != "active" || cv.Age != 14 {
		t.Fatalf("linked %+v", cv)
	}
	if me := must[Me](t)(s.Me(k)); me.FamilyRole != "child" {
		t.Fatalf("child role %+v", me)
	}
	if me := must[Me](t)(s.Me(p)); me.FamilyRole != "parent" {
		t.Fatalf("parent role %+v", me)
	}
	// A child cannot be a parent, and a parent cannot be made a child.
	if _, err := s.InviteChild(k, InviteInput{ChildPhone: "9988776655", BirthDate: "2015-01-01", DailyLimit: 100, MonthlyLimit: 100, AcceptTerms: FamilyTermsVersion, PIN: pin}); code(err) != "child_account" {
		t.Fatalf("child as parent: %v", err)
	}
	if _, err := s.InviteChild(x, InviteInput{ChildPhone: "9876543210", BirthDate: "2015-01-01", DailyLimit: 100, MonthlyLimit: 100, AcceptTerms: FamilyTermsVersion, PIN: pin}); code(err) != "is_parent" {
		t.Fatalf("parent as child: %v", err)
	}
	f := must[FamilyView](t)(s.Family(p))
	if f.Role != "parent" || len(f.Children) != 1 || f.Children[0].TermsVersion != FamilyTermsVersion {
		t.Fatalf("family %+v", f)
	}
}

func TestFiveWrongCodesCancelTheInviteAndItExpires(t *testing.T) {
	s, _, c := newTestService(t, nil)
	p := register(t, s, "Rahul", "9876543210")
	k := register(t, s, "Meera", "9123456780")
	inv := invite(t, s, p, "9123456780", "2012-05-03")
	for i := 0; i < maxCodeAttempts; i++ {
		_, _ = s.AcceptInvite(k, inv.Child.LinkID, "000000", pin)
	}
	if _, err := s.AcceptInvite(k, inv.Child.LinkID, inv.Code, pin); code(err) != "invite_closed" {
		t.Fatalf("after 5 wrong codes: %v", err)
	}
	inv = invite(t, s, p, "9123456780", "2012-05-03")
	c.t = c.t.Add(inviteWindow + time.Minute)
	if _, err := s.AcceptInvite(k, inv.Child.LinkID, inv.Code, pin); code(err) != "invite_closed" {
		t.Fatalf("expired invite: %v", err)
	}
}

func TestChildLimitsCodesAndApprovals(t *testing.T) {
	s, c, p, k := family(t)
	shop := register(t, s, "Canteen", "9988776655")
	pay := func(amount int64, code string) error {
		_, err := s.PayPersonal(k, ExpenseInput{Description: "Snacks", Amount: domain.Rupees(amount), PayeeUserID: shop, ParentCode: code, Lat: 12.9, Lng: 77.6, PlaceName: "School"})
		return err
	}
	if err := pay(250, ""); err != nil {
		t.Fatal(err)
	}
	// ₹250 of ₹300 used today: ₹100 more needs the parent.
	if err := pay(100, ""); code(err) != "needs_parent" {
		t.Fatalf("over the daily limit: %v", err)
	}
	if err := pay(2500, ""); code(err) != "child_payment_cap" {
		t.Fatalf("over ₹2,000 at once: %v", err)
	}
	// The code from the parent's app lets it through, once.
	key := must[CodeKey](t)(s.ChildCodeKey(p, k, pin))
	now := totpAt(key.Secret, c.t.Unix()/totpStep)
	if err := pay(100, now); err != nil {
		t.Fatalf("with the code: %v", err)
	}
	if err := pay(100, now); code(err) != "wrong_parent_code" {
		t.Fatalf("code used twice: %v", err)
	}
	if _, err := s.ChildCodeKey(k, k, pin); code(err) != "not_found" {
		t.Fatalf("child reading the key: %v", err)
	}
	// No location is kept for a child's payment.
	for _, e := range s.expenses {
		if e.PaidBy == k && (e.Lat != 0 || e.PlaceName != "") {
			t.Fatalf("location kept: %+v", e)
		}
	}

	// Or the child asks and the parent approves on their own phone.
	a := must[ApprovalView](t)(s.AskApproval(k, ApprovalInput{PayeeID: shop, Amount: domain.Rupees(150), Note: "Book fair"}))
	if a.Status != "pending" || a.Reason != "daily" {
		t.Fatalf("approval %+v", a)
	}
	if f := must[FamilyView](t)(s.Family(p)); len(f.Approvals) != 1 || f.Children[0].Pending != 1 {
		t.Fatalf("parent sees %+v", f)
	}
	if _, err := s.DecideApproval(p, a.ID, true, "111111"); code(err) != "wrong_pin" {
		t.Fatalf("wrong PIN: %v", err)
	}
	before := balance(s, shop)
	a = must[ApprovalView](t)(s.DecideApproval(p, a.ID, true, pin))
	if a.Status != "approved" || balance(s, shop)-before != domain.Rupees(150) {
		t.Fatalf("approved %+v", a)
	}
	if _, err := s.DecideApproval(p, a.ID, true, pin); code(err) != "approval_closed" {
		t.Fatalf("approved twice: %v", err)
	}
	// Declined and expired requests pay nothing.
	b := must[ApprovalView](t)(s.AskApproval(k, ApprovalInput{PayeeID: shop, Amount: domain.Rupees(50)}))
	must[ApprovalView](t)(s.DecideApproval(p, b.ID, false, ""))
	e := must[ApprovalView](t)(s.AskApproval(k, ApprovalInput{PayeeID: shop, Amount: domain.Rupees(50)}))
	c.t = c.t.Add(approvalWindow + time.Minute)
	if _, err := s.DecideApproval(p, e.ID, true, pin); code(err) != "approval_closed" {
		t.Fatalf("expired: %v", err)
	}
	// A new day: the daily limit starts again.
	c.t = c.t.Add(24 * time.Hour)
	if err := pay(200, ""); err != nil {
		t.Fatalf("next day: %v", err)
	}
	// The parent sees every payment.
	h := must[[]HistoryItem](t)(s.ChildActivity(p, k))
	if len(h) < 4 {
		t.Fatalf("activity %+v", h)
	}
	checkBooks(t, s)
}

func TestChildWalletCapsAndBlockedFeatures(t *testing.T) {
	s, _, p, k := family(t)
	ctx := context.Background()
	// ₹2,000 in already: ₹8,000 more this month at most.
	if _, err := s.PayPersonal(p, ExpenseInput{Description: "Too much", Amount: domain.Rupees(8001), PayeeUserID: k}); code(err) != "child_balance_cap" {
		t.Fatalf("over the balance cap: %v", err)
	}
	if _, err := s.StartTopUp(ctx, k, domain.Rupees(100)); code(err) != "child_account" {
		t.Fatalf("PayPal top-up: %v", err)
	}
	if _, err := s.Withdraw(ctx, k, domain.Rupees(100)); code(err) != "child_account" {
		t.Fatalf("withdraw: %v", err)
	}
	if _, err := s.CreateTrip(k, CreateTripInput{Name: "x", Start: s.now(), End: s.now()}); code(err) != "child_account" {
		t.Fatalf("child trip: %v", err)
	}
	if _, err := s.CreateTrip(p, CreateTripInput{Name: "x", Start: s.now(), End: s.now(), Members: []string{k}}); code(err) != "child_account" {
		t.Fatalf("child in a trip: %v", err)
	}
	if sg := s.Suggest(k, SuggestInput{PlaceType: "restaurant"}); len(sg.Reasons) != 0 || sg.TripID != "" {
		t.Fatalf("suggestions for a child: %+v", sg)
	}
	// Changing limits needs the parent's PIN; unlinking makes it ordinary.
	if _, err := s.SetChildLimits(p, k, domain.Rupees(500), domain.Rupees(2000), "111111"); code(err) != "wrong_pin" {
		t.Fatalf("limits without PIN: %v", err)
	}
	cv := must[ChildView](t)(s.SetChildLimits(p, k, domain.Rupees(500), domain.Rupees(2000), pin))
	if cv.DailyLimit != domain.Rupees(500) {
		t.Fatalf("limits %+v", cv)
	}
	if err := s.Unlink(p, k, pin); err != nil {
		t.Fatal(err)
	}
	if me := must[Me](t)(s.Me(k)); me.FamilyRole != "" {
		t.Fatalf("after unlink %+v", me)
	}
	if _, err := s.Withdraw(ctx, k, domain.Rupees(100)); code(err) == "child_account" {
		t.Fatal("still blocked after unlink")
	}
}

func TestChildGraduatesAt18(t *testing.T) {
	s, _, c := newTestService(t, nil)
	p := register(t, s, "Rahul", "9876543210")
	k := register(t, s, "Meera", "9123456780")
	inv := invite(t, s, p, "9123456780", "2008-10-14") // 18 tomorrow
	must[ChildView](t)(s.AcceptInvite(k, inv.Child.LinkID, inv.Code, pin))
	if me := must[Me](t)(s.Me(k)); me.FamilyRole != "child" {
		t.Fatalf("today %+v", me)
	}
	c.t = c.t.Add(24 * time.Hour)
	if me := must[Me](t)(s.Me(k)); me.FamilyRole != "" {
		t.Fatalf("at 18 %+v", me)
	}
	if _, err := s.ChildActivity(p, k); code(err) != "not_found" {
		t.Fatalf("parent still sees an adult: %v", err)
	}
}

func TestTOTPMatchesRFC6238(t *testing.T) {
	// RFC 6238 test key "12345678901234567890" at T=59 s gives 94287082
	// (8 digits); the last 6 are 287082.
	secret := "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
	if got := totpAt(secret, 59/30); got != "287082" {
		t.Fatalf("totp %s", got)
	}
}
