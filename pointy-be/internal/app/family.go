package app

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base32"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"math/big"
	"net/http"
	"strings"
	"time"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
)

// Pointy Parenting. A parent looks after a child's Pointy wallet: daily and
// monthly spending limits, every payment visible, and payments over a limit
// approved by the parent (on the parent's phone with their PIN, or with a
// one-time code from the parent's app, one code key per child).
//
// The rules come from the law, not taste:
//   - DPDP Act 2023, section 9(1): a child's data is processed only with
//     verifiable parental consent. A link needs both phones: the parent
//     starts it with their PIN and accepts the terms; the child accepts
//     with the pairing code from the parent's phone and the child's PIN.
//     The consent (terms version, times) is stored, and the parent can
//     withdraw it (unlink) at any time.
//   - DPDP Act section 9(3): no tracking, behavioural monitoring or targeted
//     advertising of children. Child accounts get no AI suggestions (which
//     use time and place) and no location is kept with their payments.
//   - RBI Master Direction on Prepaid Payment Instruments (small PPIs):
//     ₹10,000 loaded a month, ₹10,000 held at most, and Pointy keeps
//     ₹2,000 as the most a child can pay at once. No cash-out: children
//     cannot withdraw.
//   - PayPal's user agreement is for adults, so children cannot add money
//     or withdraw with PayPal; parents send pocket money instead.

// FamilyTermsVersion is the version of the terms a parent must accept.
const FamilyTermsVersion = "family-2026-10"

// Limits for child wallets.
var (
	ChildMaxPayment  = domain.Rupees(2000)  // per payment
	ChildMaxMonthIn  = domain.Rupees(10000) // money received in a month
	ChildMaxBalance  = domain.Rupees(10000) // held at any time
	inviteWindow     = 10 * time.Minute
	approvalWindow   = 30 * time.Minute
	maxCodeAttempts  = 5
	codeLockout      = 15 * time.Minute // after maxCodeAttempts wrong parent codes
	totpStep         = int64(30)
	familyAdultYears = 18
)

// ---------------------------------------------------------------- helpers

func ageOn(birth string, now time.Time) (int, bool) {
	b, err := time.ParseInLocation("2006-01-02", birth, IST)
	if err != nil {
		return 0, false
	}
	now = now.In(IST)
	age := now.Year() - b.Year()
	if now.Month() < b.Month() || (now.Month() == b.Month() && now.Day() < b.Day()) {
		age--
	}
	return age, true
}

func dayStart(t time.Time) time.Time {
	t = t.In(IST)
	return time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, IST)
}

func monthStart(t time.Time) time.Time {
	t = t.In(IST)
	return time.Date(t.Year(), t.Month(), 1, 0, 0, 0, 0, IST)
}

// childLinkL is the active link that makes userID a child account, or nil.
// A child who has turned 18 graduates: the link ends by itself.
func (s *Service) childLinkL(userID string) *domain.FamilyLink {
	for _, l := range s.familyLinks {
		if l.ChildID != userID || l.Status != "active" {
			continue
		}
		if age, ok := ageOn(l.BirthDate, s.now()); ok && age >= familyAdultYears {
			now := s.now()
			l.Status, l.EndedAt = "graduated", &now
			s.track(l)
			s.alertL("", l.ChildID, "family", "You're 18: your account is your own now", "Your limits are gone and "+s.name(l.ParentID)+" no longer sees your payments.")
			s.alertL("", l.ParentID, "family", s.name(l.ChildID)+" turned 18", "Their account is now an adult account.")
			return nil
		}
		return l
	}
	return nil
}

func (s *Service) isChildL(userID string) bool { return s.childLinkL(userID) != nil }

func (s *Service) isParentL(userID string) bool {
	for _, l := range s.familyLinks {
		if l.ParentID == userID && (l.Status == "active" || l.Status == "invited") && s.childLinkL(l.ChildID) == l {
			return true
		}
	}
	return false
}

// childOnly turns child accounts away from features meant for adults.
func childOnly(what string) error {
	return domain.Conflict("child_account", what+" is not available on a child account", nil)
}

func (s *Service) spentByL(childID string, since time.Time) (sum Paise) {
	for _, e := range s.expenses {
		if e.PaidBy == childID && e.Mode == ModeTransfer && !e.At.Before(since) {
			sum += e.Amount
		}
	}
	return sum
}

func (s *Service) receivedByL(childID string, since time.Time) (sum Paise) {
	for _, e := range s.expenses {
		if e.PayeeUserID == childID && e.PaidBy != childID && !e.At.Before(since) {
			sum += e.Amount
		}
	}
	return sum
}

// childSendCheckL applies a child's limits to a payment they make. Over
// the daily or monthly limit it needs the parent: a valid approval code,
// or an approval the parent already gave (approved).
func (s *Service) childSendCheckL(from string, in ExpenseInput) error {
	l := s.childLinkL(from)
	if l == nil {
		return nil
	}
	if in.Amount > ChildMaxPayment {
		return domain.Conflict("child_payment_cap", "a child account can pay at most "+INR(ChildMaxPayment)+" at a time", map[string]any{"max_paise": ChildMaxPayment})
	}
	if in.parentApproved {
		return nil
	}
	now := s.now()
	today, month := s.spentByL(from, dayStart(now)), s.spentByL(from, monthStart(now))
	reason := ""
	switch {
	case today+in.Amount > l.DailyLimit:
		reason = "daily"
	case month+in.Amount > l.MonthlyLimit:
		reason = "monthly"
	default:
		return nil
	}
	if code := strings.TrimSpace(in.ParentCode); code != "" {
		// Wrong codes are counted, so a 6-digit code cannot be guessed by
		// trying them all.
		recent := s.failedCodes[l.ID][:0:0]
		for _, at := range s.failedCodes[l.ID] {
			if now.Sub(at) < codeLockout {
				recent = append(recent, at)
			}
		}
		s.failedCodes[l.ID] = recent
		if len(recent) >= maxCodeAttempts {
			return &domain.Error{Status: http.StatusTooManyRequests, Code: "too_many_codes", Message: "too many wrong codes; try again in 15 minutes or ask " + s.name(l.ParentID) + " to approve it"}
		}
		if s.useTOTPL(l, code) {
			delete(s.failedCodes, l.ID)
			return nil
		}
		s.failedCodes[l.ID] = append(recent, now)
		return domain.Conflict("wrong_parent_code", "that code is not right or has been used; ask "+s.name(l.ParentID)+" for the code shown now",
			map[string]int{"attempts_left": max(0, maxCodeAttempts-len(s.failedCodes[l.ID]))})
	}
	return domain.Conflict("needs_parent", "this is over your "+reason+" limit. Ask "+s.name(l.ParentID)+" to approve it", map[string]any{
		"reason": reason, "parent": s.name(l.ParentID),
		"daily_left_paise": max(0, l.DailyLimit-today), "monthly_left_paise": max(0, l.MonthlyLimit-month),
	})
}

// childReceiveCheckL keeps a child's wallet inside the small-PPI limits.
func (s *Service) childReceiveCheckL(to string, amount Paise) error {
	if s.childLinkL(to) == nil {
		return nil
	}
	name := s.name(to)
	if s.ledger.Owed(domain.PersonalAccount(to))+amount > ChildMaxBalance {
		return domain.Conflict("child_balance_cap", name+"'s Pointy can hold at most "+INR(ChildMaxBalance)+" (a child account)", nil)
	}
	if s.receivedByL(to, monthStart(s.now()))+amount > ChildMaxMonthIn {
		return domain.Conflict("child_month_cap", name+" can receive at most "+INR(ChildMaxMonthIn)+" a month (a child account)", nil)
	}
	return nil
}

// ---------------------------------------------------------------- TOTP

func newTOTPSecret() string {
	b := make([]byte, 20)
	_, _ = rand.Read(b)
	return base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(b)
}

// totpAt is the 6-digit RFC 6238 code (HMAC-SHA1, 30 seconds) for step.
func totpAt(secret string, step int64) string {
	key, err := base32.StdEncoding.WithPadding(base32.NoPadding).DecodeString(secret)
	if err != nil {
		return ""
	}
	var msg [8]byte
	binary.BigEndian.PutUint64(msg[:], uint64(step))
	m := hmac.New(sha1.New, key)
	m.Write(msg[:])
	h := m.Sum(nil)
	off := h[len(h)-1] & 0x0f
	v := (binary.BigEndian.Uint32(h[off:off+4]) & 0x7fffffff) % 1_000_000
	return fmt.Sprintf("%06d", v)
}

// useTOTPL accepts the code for now, or one step either side (clocks
// drift), once only.
func (s *Service) useTOTPL(l *domain.FamilyLink, code string) bool {
	now := s.now().Unix() / totpStep
	for _, step := range []int64{now - 1, now, now + 1} {
		if step <= l.LastStep {
			continue
		}
		if subtle.ConstantTimeCompare([]byte(totpAt(l.TOTPSecret, step)), []byte(code)) == 1 {
			l.LastStep = step
			s.track(l)
			return true
		}
	}
	return false
}

func pairingCode() string {
	n, _ := rand.Int(rand.Reader, big.NewInt(1_000_000))
	return fmt.Sprintf("%06d", n.Int64())
}

func codeHash(linkID, code string) string {
	h := sha256.Sum256([]byte(linkID + ":" + code))
	return hex.EncodeToString(h[:])
}

// ---------------------------------------------------------------- views

// ChildView is one child as their parent (or the child) sees it.
type ChildView struct {
	LinkID       string            `json:"link_id"`
	Status       string            `json:"status"`
	Child        domain.PublicUser `json:"child"`
	Parent       domain.PublicUser `json:"parent"`
	BirthDate    string            `json:"birth_date"`
	Age          int               `json:"age"`
	Balance      Paise             `json:"balance_paise"`
	DailyLimit   Paise             `json:"daily_limit_paise"`
	MonthlyLimit Paise             `json:"monthly_limit_paise"`
	SpentToday   Paise             `json:"spent_today_paise"`
	SpentMonth   Paise             `json:"spent_month_paise"`
	DailyLeft    Paise             `json:"daily_left_paise"`
	MonthlyLeft  Paise             `json:"monthly_left_paise"`
	ReceivedLeft Paise             `json:"can_receive_paise"` // more it can receive this month and hold
	MaxPayment   Paise             `json:"max_payment_paise"`
	Pending      int               `json:"pending_approvals"`
	CodeExpires  *time.Time        `json:"code_expires,omitempty"` // invites only
	TermsVersion string            `json:"terms_version"`
	ConsentAt    time.Time         `json:"parent_consent_at"`
	AcceptedAt   *time.Time        `json:"child_accepted_at,omitempty"`
}

// ApprovalView is an approval with names.
type ApprovalView struct {
	*domain.Approval
	Child domain.PublicUser `json:"child"`
	Payee domain.PublicUser `json:"payee"`
	Ends  time.Time         `json:"ends"`
}

// FamilyView is everything Parenting shows one person.
type FamilyView struct {
	Role      string         `json:"role"` // "", "parent" or "child"
	Children  []ChildView    `json:"children"`
	Me        *ChildView     `json:"me,omitempty"` // for a child: their limits
	Invites   []ChildView    `json:"invites"`      // for anyone: a parent asking to link
	Approvals []ApprovalView `json:"approvals"`    // waiting (parent: to decide; child: their own)
	Terms     string         `json:"terms_version"`
	Limits    map[string]any `json:"rules"`
}

func (s *Service) childViewL(l *domain.FamilyLink) ChildView {
	now := s.now()
	v := ChildView{LinkID: l.ID, Status: l.Status, Child: s.users[l.ChildID].Public(), Parent: s.users[l.ParentID].Public(), BirthDate: l.BirthDate,
		DailyLimit: l.DailyLimit, MonthlyLimit: l.MonthlyLimit, MaxPayment: ChildMaxPayment,
		TermsVersion: l.TermsVersion, ConsentAt: l.ParentConsentAt, AcceptedAt: l.ChildAcceptedAt}
	v.Age, _ = ageOn(l.BirthDate, now)
	if l.Status == "invited" {
		exp := l.CodeExpires
		v.CodeExpires = &exp
	}
	if l.Status != "active" {
		// Anyone can invite any number: until the child says yes, the
		// inviter sees nothing of the account (DPDP Act s.9(1)).
		return v
	}
	v.Balance = s.ledger.Owed(domain.PersonalAccount(l.ChildID))
	v.SpentToday, v.SpentMonth = s.spentByL(l.ChildID, dayStart(now)), s.spentByL(l.ChildID, monthStart(now))
	v.DailyLeft, v.MonthlyLeft = max(0, l.DailyLimit-v.SpentToday), max(0, l.MonthlyLimit-v.SpentMonth)
	v.ReceivedLeft = max(0, min(ChildMaxMonthIn-s.receivedByL(l.ChildID, monthStart(now)), ChildMaxBalance-v.Balance))
	for _, a := range s.approvals {
		if a.LinkID == l.ID && a.Status == "pending" {
			v.Pending++
		}
	}
	return v
}

func (s *Service) approvalViewL(a *domain.Approval) ApprovalView {
	return ApprovalView{Approval: a, Child: s.users[a.ChildID].Public(), Payee: s.users[a.PayeeID].Public(), Ends: a.CreatedAt.Add(approvalWindow)}
}

// expireFamilyL ends invites and approvals whose time ran out.
func (s *Service) expireFamilyL() {
	now := s.now()
	for _, l := range s.familyLinks {
		if l.Status == "invited" && now.After(l.CodeExpires) {
			l.Status, l.CodeHash = "cancelled", ""
			s.track(l)
		}
	}
	for _, a := range s.approvals {
		if a.Status == "pending" && now.After(a.CreatedAt.Add(approvalWindow)) {
			a.Status, a.DecidedAt = "expired", &now
			s.track(a)
		}
	}
}

// Family is the Parenting screen's data.
func (s *Service) Family(userID string) (FamilyView, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.users[userID]; !ok {
		return FamilyView{}, domain.NotFound("user")
	}
	s.expireFamilyL()
	v := FamilyView{Children: []ChildView{}, Invites: []ChildView{}, Approvals: []ApprovalView{}, Terms: FamilyTermsVersion,
		Limits: map[string]any{"max_payment_paise": ChildMaxPayment, "max_month_in_paise": ChildMaxMonthIn, "max_balance_paise": ChildMaxBalance}}
	if l := s.childLinkL(userID); l != nil {
		v.Role = "child"
		cv := s.childViewL(l)
		v.Me = &cv
	}
	for _, l := range s.familyLinks {
		switch {
		case l.ParentID == userID && (l.Status == "active" && s.childLinkL(l.ChildID) == l || l.Status == "invited"):
			v.Children = append(v.Children, s.childViewL(l))
			if l.Status == "active" {
				v.Role = "parent"
			}
		case l.ChildID == userID && l.Status == "invited":
			v.Invites = append(v.Invites, s.childViewL(l))
		}
	}
	for i := len(s.approvals) - 1; i >= 0; i-- {
		a := s.approvals[i]
		if a.Status != "pending" {
			continue
		}
		l := s.linkByIDL(a.LinkID)
		if a.ChildID == userID || (l != nil && l.ParentID == userID) {
			v.Approvals = append(v.Approvals, s.approvalViewL(a))
		}
	}
	_ = s.commitL() // anything that just expired or graduated
	return v, nil
}

func (s *Service) linkByIDL(id string) *domain.FamilyLink {
	for _, l := range s.familyLinks {
		if l.ID == id {
			return l
		}
	}
	return nil
}

// parentLinkL is the active link from parent to child.
func (s *Service) parentLinkL(parentID, childID string) (*domain.FamilyLink, error) {
	if l := s.childLinkL(childID); l != nil && l.ParentID == parentID {
		return l, nil
	}
	return nil, domain.NotFound("child")
}

// ---------------------------------------------------------------- linking

// InviteInput is what a parent fills in to link a child.
type InviteInput struct {
	ChildPhone   string `json:"child_phone"`
	BirthDate    string `json:"birth_date"` // YYYY-MM-DD
	DailyLimit   Paise  `json:"daily_limit_paise"`
	MonthlyLimit Paise  `json:"monthly_limit_paise"`
	AcceptTerms  string `json:"accept_terms"` // must be FamilyTermsVersion
	PIN          string `json:"pin"`
}

// Invite is the pairing code for the child's phone. It is shown once.
type Invite struct {
	Child   ChildView `json:"child"`
	Code    string    `json:"code"`
	Expires time.Time `json:"expires"`
}

func checkLimits(daily, monthly Paise) error {
	switch {
	case daily <= 0 || monthly <= 0:
		return domain.Invalid("set a daily and a monthly limit")
	case daily > monthly:
		return domain.Invalid("the daily limit cannot be more than the monthly one")
	case monthly > ChildMaxMonthIn:
		return domain.Invalid("the monthly limit can be at most %s (the rule for children's wallets)", INR(ChildMaxMonthIn))
	}
	return nil
}

// InviteChild starts a link. The parent's PIN and acceptance of the terms
// are the parent's half of the consent; nothing changes for the child
// until the child accepts on their own phone.
func (s *Service) InviteChild(parentID string, in InviteInput) (Invite, error) {
	if in.AcceptTerms != FamilyTermsVersion {
		return Invite{}, domain.Invalid("read and accept the Parenting terms first")
	}
	if err := s.VerifyPIN(parentID, in.PIN); err != nil {
		return Invite{}, err
	}
	phone, err := NormalizePhone(in.ChildPhone)
	if err != nil {
		return Invite{}, err
	}
	if err := checkLimits(in.DailyLimit, in.MonthlyLimit); err != nil {
		return Invite{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	childID, ok := s.phones[phone]
	age, okAge := ageOn(in.BirthDate, s.now())
	switch {
	case !ok:
		return Invite{}, domain.NotFound("Pointy account for this number; your child signs up first")
	case childID == parentID:
		return Invite{}, domain.Invalid("you cannot be your own parent")
	case !okAge || age < 0:
		return Invite{}, domain.Invalid("enter the child's date of birth as YYYY-MM-DD")
	case age >= familyAdultYears:
		// An adult's account can never be turned into a child account.
		return Invite{}, domain.Conflict("not_a_child", "Pointy Parenting is only for children under 18", nil)
	case s.isChildL(parentID):
		return Invite{}, childOnly("Parenting")
	case s.isChildL(childID):
		return Invite{}, domain.Conflict("already_linked", s.name(childID)+" already has a parent on Pointy", nil)
	case s.isParentL(childID):
		return Invite{}, domain.Conflict("is_parent", s.name(childID)+" looks after a child account, so cannot be one", nil)
	}
	// childFitsL (balance, trips, withdrawals) runs when the child accepts:
	// telling the inviter would show them the account.
	// A new invite replaces this parent's earlier one for the same child.
	for _, l := range s.familyLinks {
		if l.ParentID == parentID && l.ChildID == childID && l.Status == "invited" {
			l.Status, l.CodeHash = "cancelled", ""
			s.track(l)
		}
	}
	now := s.now()
	l := &domain.FamilyLink{ID: s.idL("fam"), ParentID: parentID, ChildID: childID, BirthDate: in.BirthDate, Status: "invited",
		DailyLimit: in.DailyLimit, MonthlyLimit: in.MonthlyLimit, TermsVersion: FamilyTermsVersion, ParentConsentAt: now,
		CodeExpires: now.Add(inviteWindow), TOTPSecret: newTOTPSecret(), CreatedAt: now}
	code := pairingCode()
	l.CodeHash = codeHash(l.ID, code)
	s.familyLinks = append(s.familyLinks, l)
	s.track(l)
	s.alertL("", childID, "family", s.name(parentID)+" wants to look after your Pointy", "Open Profile → Family. You need the code on their phone.")
	if err := s.commitL(); err != nil {
		return Invite{}, err
	}
	return Invite{Child: s.childViewL(l), Code: code, Expires: l.CodeExpires}, nil
}

// childFitsL checks that an account can become a child account: within the
// small-wallet balance limit and in no trip wallet.
func (s *Service) childFitsL(childID string) error {
	if bal := s.ledger.Owed(domain.PersonalAccount(childID)); bal > ChildMaxBalance {
		return domain.Conflict("child_balance_cap", s.name(childID)+" has "+INR(bal)+"; a child account can hold at most "+INR(ChildMaxBalance)+". Spend or withdraw the rest first", nil)
	}
	// A withdrawal PayPal may still send back would land in the child
	// wallet past its caps.
	for _, p := range s.payoutsForL(childID) {
		if p.Status == "sending" || p.Status == "pending" || p.Status == "unclaimed" {
			return domain.Conflict("child_payout_open", s.name(childID)+" has a withdrawal still on its way to PayPal; link once it has arrived", nil)
		}
	}
	for _, t := range s.trips {
		if t.Status == domain.TripOpen && t.HasMember(childID) {
			return domain.Conflict("child_in_trip", s.name(childID)+" is in the open trip "+t.Name+"; settle it first", nil)
		}
	}
	return nil
}

// AcceptInvite is the child's half of the consent: the pairing code from
// the parent's phone (they are together) and the child's own PIN (it is
// really the child's account).
func (s *Service) AcceptInvite(childID, linkID, code, pin string) (ChildView, error) {
	if err := s.VerifyPIN(childID, pin); err != nil {
		return ChildView{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.expireFamilyL()
	l := s.linkByIDL(linkID)
	if l == nil || l.ChildID != childID {
		return ChildView{}, domain.NotFound("invite")
	}
	if l.Status != "invited" {
		_ = s.commitL()
		return ChildView{}, domain.Conflict("invite_closed", "this invite is "+l.Status+"; ask your parent to start again", nil)
	}
	if subtle.ConstantTimeCompare([]byte(codeHash(l.ID, strings.TrimSpace(code))), []byte(l.CodeHash)) != 1 {
		l.CodeAttempts++
		if l.CodeAttempts >= maxCodeAttempts {
			l.Status, l.CodeHash = "cancelled", ""
		}
		s.track(l)
		_ = s.commitL()
		return ChildView{}, &domain.Error{Status: 401, Code: "wrong_code", Message: "that code is not the one on your parent's phone",
			Details: map[string]int{"attempts_left": max(0, maxCodeAttempts-l.CodeAttempts)}}
	}
	// Things may have changed since the invite: no child with two parents,
	// no parent who is a child, no two people each other's parent.
	switch {
	case s.isChildL(childID):
		return ChildView{}, domain.Conflict("already_linked", "you already have a parent on Pointy", nil)
	case s.isParentL(childID):
		return ChildView{}, domain.Conflict("is_parent", "you look after a child account, so yours cannot be one", nil)
	case s.isChildL(l.ParentID):
		return ChildView{}, childOnly("Looking after another account")
	}
	if err := s.childFitsL(childID); err != nil {
		return ChildView{}, err
	}
	now := s.now()
	l.Status, l.ChildAcceptedAt, l.CodeHash = "active", &now, ""
	s.track(l)
	s.alertL("", l.ParentID, "family", s.name(childID)+" is linked to you", "Set limits and see their payments in Profile → Family.")
	s.alertL("", childID, "family", s.name(l.ParentID)+" now looks after your Pointy", "Daily "+INR(l.DailyLimit)+", monthly "+INR(l.MonthlyLimit)+".")
	if err := s.commitL(); err != nil {
		return ChildView{}, err
	}
	return s.childViewL(l), nil
}

// DeclineInvite is the child saying no.
func (s *Service) DeclineInvite(childID, linkID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	l := s.linkByIDL(linkID)
	if l == nil || l.ChildID != childID || l.Status != "invited" {
		return domain.NotFound("invite")
	}
	l.Status, l.CodeHash = "cancelled", ""
	s.track(l)
	s.alertL("", l.ParentID, "family", s.name(childID)+" said no to linking", "Nothing changed on their account.")
	return s.commitL()
}

// SetChildLimits changes a child's limits (parent, with their PIN).
func (s *Service) SetChildLimits(parentID, childID string, daily, monthly Paise, pin string) (ChildView, error) {
	if err := checkLimits(daily, monthly); err != nil {
		return ChildView{}, err
	}
	if err := s.VerifyPIN(parentID, pin); err != nil {
		return ChildView{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	l, err := s.parentLinkL(parentID, childID)
	if err != nil {
		return ChildView{}, err
	}
	l.DailyLimit, l.MonthlyLimit = daily, monthly
	s.track(l)
	s.alertL("", childID, "family", s.name(parentID)+" changed your limits", "Daily "+INR(daily)+", monthly "+INR(monthly)+".")
	if err := s.commitL(); err != nil {
		return ChildView{}, err
	}
	return s.childViewL(l), nil
}

// Unlink withdraws the parent's consent: the account becomes an ordinary
// one again and the parent stops seeing it.
func (s *Service) Unlink(parentID, childID, pin string) error {
	if err := s.VerifyPIN(parentID, pin); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	var l *domain.FamilyLink
	for _, x := range s.familyLinks {
		if x.ParentID == parentID && x.ChildID == childID && (x.Status == "active" || x.Status == "invited") {
			l = x
		}
	}
	if l == nil {
		return domain.NotFound("child")
	}
	now := s.now()
	was := l.Status
	l.Status, l.EndedAt, l.CodeHash = "ended", &now, ""
	s.track(l)
	for _, a := range s.approvals {
		if a.LinkID == l.ID && a.Status == "pending" {
			a.Status, a.DecidedAt = "declined", &now
			s.track(a)
		}
	}
	if was == "active" {
		s.alertL("", childID, "family", s.name(parentID)+" unlinked your account", "It is an ordinary Pointy account again.")
	}
	return s.commitL()
}

// ChildActivity is the child's history for their parent.
func (s *Service) ChildActivity(parentID, childID string) ([]HistoryItem, error) {
	s.mu.Lock()
	_, err := s.parentLinkL(parentID, childID)
	s.mu.Unlock()
	if err != nil {
		return nil, err
	}
	return s.History(childID), nil
}

// CodeKey gives the parent's app the child's approval-code key, so it can
// show the code even offline. It needs the parent's PIN.
type CodeKey struct {
	ChildID string `json:"child_id"`
	Label   string `json:"label"`
	Secret  string `json:"secret"` // base32
	Period  int64  `json:"period"`
	Digits  int    `json:"digits"`
}

func (s *Service) ChildCodeKey(parentID, childID, pin string) (CodeKey, error) {
	if err := s.VerifyPIN(parentID, pin); err != nil {
		return CodeKey{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	l, err := s.parentLinkL(parentID, childID)
	if err != nil {
		return CodeKey{}, err
	}
	return CodeKey{ChildID: childID, Label: "Pointy · " + s.name(childID), Secret: l.TOTPSecret, Period: totpStep, Digits: 6}, nil
}

// ---------------------------------------------------------------- approvals

// ApprovalInput is a child's payment that needs the parent.
type ApprovalInput struct {
	PayeeID string `json:"payee_id"`
	Amount  Paise  `json:"amount_paise"`
	Note    string `json:"note"`
}

// maxOpenApprovals keeps a child from flooding the parent with asks.
const maxOpenApprovals = 3

// AskApproval sends an over-limit payment to the parent's phone.
func (s *Service) AskApproval(childID string, in ApprovalInput) (ApprovalView, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	l := s.childLinkL(childID)
	if l == nil {
		return ApprovalView{}, domain.Conflict("not_a_child", "only a child account asks for approval", nil)
	}
	if err := checkAmount(in.Amount); err != nil {
		return ApprovalView{}, err
	}
	if _, ok := s.users[in.PayeeID]; !ok || in.PayeeID == childID {
		return ApprovalView{}, domain.Invalid("choose who to pay")
	}
	if in.Amount > ChildMaxPayment {
		return ApprovalView{}, domain.Conflict("child_payment_cap", "a child account can pay at most "+INR(ChildMaxPayment)+" at a time", nil)
	}
	if bal := s.availL(domain.PersonalAccount(childID)); bal < in.Amount {
		return ApprovalView{}, domain.Conflict("insufficient_balance", "your balance is "+INR(bal), nil)
	}
	s.expireFamilyL()
	open := 0
	for _, x := range s.approvals {
		if x.ChildID == childID && x.Status == "pending" {
			open++
		}
	}
	if open >= maxOpenApprovals {
		return ApprovalView{}, domain.Conflict("too_many_asks", "wait for an answer to the ones you have asked", nil)
	}
	note := clip(strings.TrimSpace(in.Note), 80)
	now := s.now()
	reason := "monthly"
	if s.spentByL(childID, dayStart(now))+in.Amount > l.DailyLimit {
		reason = "daily"
	}
	a := &domain.Approval{ID: s.idL("apr"), LinkID: l.ID, ChildID: childID, PayeeID: in.PayeeID, Amount: in.Amount, Note: note, Reason: reason, Status: "pending", CreatedAt: now}
	s.approvals = append(s.approvals, a)
	s.track(a)
	s.alertL("", l.ParentID, "approval", s.name(childID)+" asks to pay "+INR(in.Amount), "To "+s.name(in.PayeeID)+firstNonEmpty(" · "+note, "")+". Over their "+reason+" limit.")
	if err := s.commitL(); err != nil {
		return ApprovalView{}, err
	}
	return s.approvalViewL(a), nil
}

// DecideApproval is the parent's answer. Approving pays at once from the
// child's balance; it needs the parent's PIN.
func (s *Service) DecideApproval(parentID, id string, approve bool, pin string) (ApprovalView, error) {
	if approve {
		if err := s.VerifyPIN(parentID, pin); err != nil {
			return ApprovalView{}, err
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.expireFamilyL()
	var a *domain.Approval
	for _, x := range s.approvals {
		if x.ID == id {
			a = x
		}
	}
	if a == nil {
		return ApprovalView{}, domain.NotFound("approval")
	}
	l := s.linkByIDL(a.LinkID)
	if l == nil || l.ParentID != parentID {
		return ApprovalView{}, domain.NotFound("approval")
	}
	now := s.now()
	if a.Status == "pending" && s.childLinkL(a.ChildID) != l {
		// The link ended (the child turned 18): the parent no longer
		// decides for this account.
		a.Status, a.DecidedAt = "expired", &now
		s.track(a)
	}
	if a.Status != "pending" {
		_ = s.commitL()
		return ApprovalView{}, domain.Conflict("approval_closed", "this request is "+a.Status, nil)
	}
	if !approve {
		a.Status, a.DecidedAt = "declined", &now
		s.track(a)
		s.alertL("", a.ChildID, "approval", s.name(parentID)+" said no to "+INR(a.Amount), "To "+s.name(a.PayeeID)+". Nothing was paid.")
		if err := s.commitL(); err != nil {
			return ApprovalView{}, err
		}
		return s.approvalViewL(a), nil
	}
	in := ExpenseInput{Description: firstNonEmpty(a.Note, "Approved by "+s.name(parentID)), Category: domain.Other, Amount: a.Amount, At: &now, parentApproved: true}
	if err := s.childReceiveCheckL(a.PayeeID, a.Amount); err != nil {
		return ApprovalView{}, err
	}
	e, err := s.transferL(a.ChildID, a.PayeeID, in, "")
	if err != nil {
		s.pending = nil
		return ApprovalView{}, err
	}
	a.Status, a.DecidedAt, a.ExpenseID = "approved", &now, e.ID
	s.track(a)
	s.alertL("", a.ChildID, "approval", s.name(parentID)+" approved "+INR(a.Amount), "Paid to "+s.name(a.PayeeID)+".")
	if err := s.commitL(); err != nil {
		return ApprovalView{}, err
	}
	return s.approvalViewL(a), nil
}
