package app

import (
	"context"
	"fmt"
	"log"
	"regexp"
	"strings"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/ai"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
)

// QuickPayResult is a typed sentence read into a payment or a request.
// Nothing moves: the app shows it and the person confirms on the usual
// screen, so a misread can never pay anyone.
type QuickPayResult struct {
	Action string             `json:"action"` // pay or request
	Person *domain.PublicUser `json:"person,omitempty"`
	// Choices are the people a name could mean when it fits more than one.
	Choices []domain.PublicUser `json:"choices,omitempty"`
	Amount  Paise               `json:"amount_paise"`
	Note    string              `json:"note"`
	Reply   string              `json:"reply"`
	Source  string              `json:"source"` // ai or rules
}

// Ready says whether the app can go straight to the confirm screen.
func (q QuickPayResult) Ready() bool { return q.Person != nil && q.Amount > 0 }

const maxQuickPayText = 200

// QuickPay reads a sentence such as "pay Asha 200 for coffee". The model
// reads it when one is set up; otherwise, or if it fails, simple rules do.
func (s *Service) QuickPay(ctx context.Context, userID, text string) (QuickPayResult, error) {
	text = strings.Join(strings.Fields(text), " ")
	if text == "" {
		return QuickPayResult{}, domain.Invalid("type who to pay and how much, for example: pay Dev 200 for chai")
	}
	if len(text) > maxQuickPayText {
		return QuickPayResult{}, domain.Invalid("keep it to one short sentence")
	}
	contacts := s.Contacts(userID)
	s.mu.Lock()
	assistant := s.ai
	s.mu.Unlock()

	var out QuickPayResult
	if assistant != nil {
		in := ai.QuickPayInput{Text: text}
		for _, c := range contacts {
			in.Contacts = append(in.Contacts, c.Name)
		}
		cctx, cancel := context.WithTimeout(ctx, aiTimeout)
		read, err := assistant.ParseQuickPay(cctx, in)
		cancel()
		if err != nil {
			log.Printf("ai quick pay: %v (using the rules)", err)
		} else {
			if !read.Understood && read.Person == "" && read.Amount == "" {
				return QuickPayResult{Action: "pay", Reply: firstNonEmpty(read.Reply, "Say who to pay and how much, for example: pay Dev 200 for chai."), Source: "ai"}, nil
			}
			out = QuickPayResult{Action: read.Action, Note: strings.TrimSpace(read.Note), Reply: strings.TrimSpace(read.Reply), Source: "ai"}
			if v, ok := ai.ParseRupees(read.Amount); ok {
				out.Amount = Paise(v)
			}
			s.pickPerson(&out, userID, contacts, read.Person, read.Person)
		}
	}
	if out.Source == "" {
		out = s.quickPayRules(userID, text, contacts)
	}
	if out.Action != "request" {
		out.Action = "pay"
	}
	if out.Amount > MaxAmount {
		out.Amount = 0
		out.Reply = fmt.Sprintf("That is over the %s limit for one payment.", INR(MaxAmount))
	}
	out.Note = clip(out.Note, 60)
	if out.Reply == "" || !out.Ready() {
		out.Reply = quickPayReply(out)
	}
	return out, nil
}

// pickPerson resolves who: a mobile number, or a name among the people the
// caller has paid or been paid by. [said] is how the text named them, for
// the reply when nobody fits.
func (s *Service) pickPerson(q *QuickPayResult, userID string, contacts []domain.PublicUser, who, said string) {
	who = strings.TrimSpace(who)
	if who == "" {
		return
	}
	if m := reQPPhone.FindStringSubmatch(who); m != nil {
		phone, err := NormalizePhone(m[1])
		if err != nil {
			return
		}
		s.mu.Lock()
		id, ok := s.phones[phone]
		var u domain.PublicUser
		if ok {
			u = s.users[id].Public()
		}
		s.mu.Unlock()
		switch {
		case !ok:
			q.Reply = fmt.Sprintf("+91 %s is not on Pointy yet. Ask them to join, then try again.", phone)
		case id == userID:
			q.Reply = "That is your own number."
		default:
			q.Person = &u
		}
		return
	}
	matches := matchContacts(contacts, who)
	switch len(matches) {
	case 0:
		q.Reply = fmt.Sprintf("I could not find %s among your people. Type their mobile number instead.", strings.TrimSpace(said))
	case 1:
		q.Person = &matches[0]
	default:
		q.Choices = matches
	}
}

// matchContacts finds people whose full name or first name is [name].
func matchContacts(contacts []domain.PublicUser, name string) []domain.PublicUser {
	name = strings.ToLower(strings.Join(strings.Fields(name), " "))
	var full, first []domain.PublicUser
	for _, c := range contacts {
		n := strings.ToLower(c.Name)
		switch {
		case n == name:
			full = append(full, c)
		case firstName(n) == name:
			first = append(first, c)
		}
	}
	if len(full) > 0 {
		return full
	}
	return first
}

var (
	reQPPhone   = regexp.MustCompile(`(?:\+?91[\s-]?)?\b([6-9]\d{4}\s?\d{5})\b`)
	reQPAmount  = regexp.MustCompile(`(?i)(?:₹|\brs\.?|\binr)?\s*(\d[\d,]*(?:\.\d{1,2})?)\s*(k\b)?`)
	reQPFor     = regexp.MustCompile(`(?i)\bfor\b`)
	reQPRequest = regexp.MustCompile(`(?i)\b(request|ask|collect|get|recover)\b`)
	reQPWord    = regexp.MustCompile(`[\p{L}]+`)
)

// quickPayRules reads the sentence without a model: a number or a known
// name for who, the first amount (2k = 2000), "for ..." for the note.
func (s *Service) quickPayRules(userID, text string, contacts []domain.PublicUser) QuickPayResult {
	out := QuickPayResult{Action: "pay", Source: "rules"}
	if reQPRequest.MatchString(text) {
		out.Action = "request"
	}
	rest := text
	if m := reQPPhone.FindString(text); m != "" {
		s.pickPerson(&out, userID, contacts, m, m)
		rest = strings.Replace(rest, m, " ", 1)
	} else {
		// Every contact whose full name, or else first name, is in the text.
		lower := " " + strings.ToLower(strings.Join(reQPWord.FindAllString(text, -1), " ")) + " "
		var full, first []domain.PublicUser
		for _, c := range contacts {
			n := strings.ToLower(strings.Join(strings.Fields(c.Name), " "))
			if strings.Contains(lower, " "+n+" ") {
				full = append(full, c)
			} else if strings.Contains(lower, " "+firstName(n)+" ") {
				first = append(first, c)
			}
		}
		if len(full) == 0 {
			full = first
		}
		switch len(full) {
		case 1:
			out.Person = &full[0]
		case 0:
		default:
			out.Choices = full
		}
	}
	if m := reQPAmount.FindStringSubmatch(rest); m != nil {
		if v, ok := ai.ParseRupees(m[1]); ok {
			if m[2] != "" {
				v *= 1000
			}
			out.Amount = Paise(v)
		}
	}
	// The note is the last "for ..." that is more than an amount.
	parts := reQPFor.Split(rest, -1)
	for i := len(parts) - 1; i >= 1; i-- {
		n := strings.Trim(reQPAmount.ReplaceAllString(parts[i], " "), " .,!?")
		if n = strings.Join(strings.Fields(n), " "); n != "" {
			out.Note = n
			break
		}
	}
	return out
}

// quickPayReply says what was understood, or asks for what is missing.
func quickPayReply(q QuickPayResult) string {
	if q.Reply != "" && q.Person == nil && len(q.Choices) == 0 {
		return q.Reply // nobody fits: keep the reason
	}
	switch {
	case len(q.Choices) > 0:
		return "Which one did you mean?"
	case q.Person == nil:
		if q.Action == "request" {
			return "Who should I ask? Use a name from your people or a mobile number."
		}
		return "Who should I pay? Use a name from your people or a mobile number."
	case q.Amount <= 0:
		return fmt.Sprintf("How much for %s?", firstName(q.Person.Name))
	}
	first := firstName(q.Person.Name)
	what := ""
	if q.Note != "" {
		what = " for " + q.Note
	}
	if q.Action == "request" {
		return fmt.Sprintf("Ask %s for %s%s? Check it and send.", first, INR(q.Amount), what)
	}
	return fmt.Sprintf("Pay %s %s%s? Check it and confirm.", first, INR(q.Amount), what)
}
