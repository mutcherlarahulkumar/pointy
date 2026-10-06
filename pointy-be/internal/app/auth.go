package app

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"net/http"
	"regexp"
	"strings"
	"time"

	"golang.org/x/crypto/bcrypt"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
)

var (
	reIndianMobile = regexp.MustCompile(`^[6-9][0-9]{9}$`)
	rePIN          = regexp.MustCompile(`^[0-9]{6}$`)
	reNonDigit     = regexp.MustCompile(`[^0-9]`)
)

// Five wrong PINs in this window lock the number out for the rest of it.
const (
	loginWindow   = 15 * time.Minute
	maxFailedPINs = 5
)

// NormalizePhone turns "+91 98765 43210", "098765 43210" or "9876543210"
// into "9876543210" and checks it is an Indian mobile number.
func NormalizePhone(raw string) (string, error) {
	d := reNonDigit.ReplaceAllString(raw, "")
	switch {
	case len(d) == 12 && strings.HasPrefix(d, "91"):
		d = d[2:]
	case len(d) == 11 && strings.HasPrefix(d, "0"):
		d = d[1:]
	}
	if !reIndianMobile.MatchString(d) {
		return "", domain.Invalid("enter a 10-digit Indian mobile number")
	}
	return d, nil
}

type AuthResult struct {
	Token string       `json:"token"`
	User  *domain.User `json:"user"`
}

type PhoneCheck struct {
	Phone     string `json:"phone"`
	Exists    bool   `json:"exists"`
	FirstName string `json:"first_name,omitempty"`
}

// CheckPhone tells the app whether to show sign-in or sign-up next.
func (s *Service) CheckPhone(raw string) (PhoneCheck, error) {
	phone, err := NormalizePhone(raw)
	if err != nil {
		return PhoneCheck{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	out := PhoneCheck{Phone: phone}
	if id, ok := s.phones[phone]; ok {
		out.Exists, out.FirstName = true, firstName(s.users[id].Name)
	}
	return out, nil
}

type RegisterInput struct {
	Name  string `json:"name"`
	Phone string `json:"phone"`
	PIN   string `json:"pin"`
}

func (s *Service) Register(in RegisterInput) (AuthResult, error) {
	phone, err := NormalizePhone(in.Phone)
	if err != nil {
		return AuthResult{}, err
	}
	name := strings.Join(strings.Fields(in.Name), " ")
	if len([]rune(name)) < 2 || len([]rune(name)) > 40 {
		return AuthResult{}, domain.Invalid("enter your name (2 to 40 letters)")
	}
	if !rePIN.MatchString(in.PIN) {
		return AuthResult{}, domain.Invalid("the PIN must be 6 digits")
	}
	if weakPIN(in.PIN) {
		return AuthResult{}, domain.Invalid("that PIN is too easy to guess; avoid repeats and sequences")
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(in.PIN), bcrypt.DefaultCost)
	if err != nil {
		return AuthResult{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, taken := s.phones[phone]; taken {
		return AuthResult{}, domain.Conflict("phone_taken", "this number already has a Pointy account; sign in instead", nil)
	}
	u := &domain.User{ID: s.idL("u"), Name: name, Phone: phone, PinHash: string(hash), CreatedAt: s.now(), AlertsSeenAt: s.now()}
	s.users[u.ID], s.phones[phone] = u, u.ID
	s.track(u)
	token := s.newSessionL(u.ID)
	s.alertL("", u.ID, "money", "Welcome to Pointy, "+firstName(name), "Add money with PayPal to start paying friends")
	if err := s.commitL(); err != nil { // commitL put the state back
		return AuthResult{}, err
	}
	return AuthResult{Token: token, User: u}, nil
}

func (s *Service) Login(rawPhone, pin string) (AuthResult, error) {
	phone, err := NormalizePhone(rawPhone)
	if err != nil {
		return AuthResult{}, err
	}
	id, err := s.checkPIN(phone, pin)
	if err != nil {
		return AuthResult{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	token := s.newSessionL(id)
	if err := s.commitL(); err != nil {
		return AuthResult{}, err
	}
	return AuthResult{Token: token, User: s.users[id]}, nil
}

// VerifyPIN checks a signed-in person's PIN before a payment, on phones with
// no fingerprint or screen lock. Wrong PINs count towards the same lockout
// as signing in.
func (s *Service) VerifyPIN(userID, pin string) error {
	s.mu.Lock()
	u, ok := s.users[userID]
	s.mu.Unlock()
	if !ok {
		return domain.NotFound("user")
	}
	_, err := s.checkPIN(u.Phone, pin)
	return err
}

// checkPIN compares a PIN with the account for phone, counting wrong ones.
func (s *Service) checkPIN(phone, pin string) (string, error) {
	s.mu.Lock()
	recent := s.failedLogins[phone][:0:0]
	for _, at := range s.failedLogins[phone] {
		if s.now().Sub(at) < loginWindow {
			recent = append(recent, at)
		}
	}
	if len(recent) >= maxFailedPINs {
		s.failedLogins[phone] = recent
		s.mu.Unlock()
		return "", &domain.Error{Status: http.StatusTooManyRequests, Code: "too_many_attempts", Message: "too many wrong PINs; try again in 15 minutes"}
	}
	id, ok := s.phones[phone]
	if !ok {
		// Nothing to guess, so nothing is counted: tries on numbers with no
		// account must not fill memory.
		delete(s.failedLogins, phone)
		s.mu.Unlock()
		return "", domain.NotFound("account for this number")
	}
	hash := s.users[id].PinHash
	// Count this try as wrong before checking it, and take it back only if
	// it is right: otherwise many guesses sent at once would all pass the
	// limit above while bcrypt runs.
	s.failedLogins[phone] = append(recent, s.now())
	left := maxFailedPINs - len(s.failedLogins[phone])
	s.mu.Unlock()

	// bcrypt is slow on purpose, so it runs without the lock.
	if bcrypt.CompareHashAndPassword([]byte(hash), []byte(pin)) != nil {
		return "", &domain.Error{Status: http.StatusUnauthorized, Code: "wrong_pin", Message: "wrong PIN", Details: map[string]int{"attempts_left": left}}
	}
	s.mu.Lock()
	delete(s.failedLogins, phone)
	s.mu.Unlock()
	return id, nil
}

func (s *Service) Logout(token string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	h := hashToken(token)
	if _, ok := s.sessions[h]; !ok {
		return nil
	}
	delete(s.sessions, h)
	s.track(domain.SessionEnd{TokenHash: h})
	return s.commitL()
}

// UserForToken resolves a bearer token to the signed-in user.
func (s *Service) UserForToken(token string) (string, bool) {
	if token == "" {
		return "", false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	id, ok := s.sessions[hashToken(token)]
	return id, ok
}

func (s *Service) newSessionL(userID string) string {
	b := make([]byte, 32)
	_, _ = rand.Read(b)
	token := base64.RawURLEncoding.EncodeToString(b)
	se := domain.Session{TokenHash: hashToken(token), UserID: userID, CreatedAt: s.now()}
	s.sessions[se.TokenHash] = userID
	s.track(se)
	return token
}

func hashToken(t string) string {
	sum := sha256.Sum256([]byte(t))
	return hex.EncodeToString(sum[:])
}

// weakPIN rejects all-same digits and straight runs like 123456 or 987654.
func weakPIN(p string) bool {
	same, up, down := true, true, true
	for i := 1; i < len(p); i++ {
		d := int(p[i]) - int(p[i-1])
		same = same && d == 0
		up = up && d == 1
		down = down && d == -1
	}
	return same || up || down
}

// firstName is the first word of a name, or "" for an empty one.
func firstName(name string) string {
	if f := strings.Fields(name); len(f) > 0 {
		return f[0]
	}
	return ""
}
