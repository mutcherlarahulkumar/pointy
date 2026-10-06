package app

import (
	"context"
	"fmt"
	"log"
	"regexp"
	"strings"
	"time"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/ai"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
)

const (
	maxChatText    = 500
	chatMemory     = 10 // earlier lines sent with each question
	chatHistoryMax = 60 // lines the app gets back
)

// ChatFacts is what the assistant may know about one person, read from the
// database. Amounts are formatted rupees so the model quotes, never computes.
type ChatFacts struct {
	Balance         string   `json:"balance"`
	SpentLast7Days  string   `json:"you_spent_last_7_days"`
	SpentThisMonth  string   `json:"you_spent_this_month"`
	ByCategoryMonth []string `json:"this_month_by_category"`
	Recent          []string `json:"recent_activity"`
	AskedOfYou      []string `json:"money_people_ask_you_for"`
	YouAsked        []string `json:"money_you_asked_for"`
	Trips           []string `json:"trips"`
	People          []string `json:"people"`
	ShoppingOn      bool     `json:"shopping_available"`
}

// ChatHistory is the person's conversation, oldest first.
func (s *Service) ChatHistory(userID string) []*domain.ChatMessage {
	s.mu.Lock()
	defer s.mu.Unlock()
	all := s.chats[userID]
	if len(all) > chatHistoryMax {
		all = all[len(all)-chatHistoryMax:]
	}
	return append([]*domain.ChatMessage{}, all...)
}

// ClearChat deletes the person's conversation.
func (s *Service) ClearChat(userID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.chats, userID)
	s.track(domain.ChatCleared{UserID: userID})
	return s.commitL() // on failure commitL puts the state back
}

// Chat answers one message and saves both lines. The model answers when one
// is set up; otherwise, or if it fails, simple rules do.
func (s *Service) Chat(ctx context.Context, userID, text string) ([]*domain.ChatMessage, error) {
	text = strings.TrimSpace(text)
	if text == "" {
		return nil, domain.Invalid("type a question, for example: how much did I spend this week?")
	}
	if len([]rune(text)) > maxChatText {
		return nil, domain.Invalid("keep it under %d characters", maxChatText)
	}
	contacts := s.Contacts(userID)
	facts, you, err := s.chatFacts(userID, contacts)
	if err != nil {
		return nil, err
	}
	s.mu.Lock()
	assistant := s.ai
	facts.ShoppingOn = s.shop != nil
	var convo []ai.ChatLine
	past := s.chats[userID]
	if len(past) > chatMemory {
		past = past[len(past)-chatMemory:]
	}
	for _, m := range past {
		convo = append(convo, ai.ChatLine{Role: m.Role, Text: m.Text})
	}
	now := s.now()
	s.mu.Unlock()

	reply := &domain.ChatMessage{Role: "assistant", Source: "rules"}
	if assistant != nil {
		cctx, cancel := context.WithTimeout(ctx, aiTimeout)
		got, aerr := assistant.Chat(cctx, ai.ChatInput{Today: now.In(IST).Format("Mon 2 Jan 2006, 3:04 pm"), You: you, Facts: facts, Conversation: convo, Message: text})
		cancel()
		if aerr != nil {
			log.Printf("ai chat: %v (using the rules)", aerr)
		} else if strings.TrimSpace(got.Reply) != "" {
			reply.Text, reply.Source = strings.TrimSpace(got.Reply), "ai"
			if got.Action == "shop" {
				max, _ := ai.ParseRupees(got.Amount)
				var note string
				reply.Action, note = s.shopAction(ctx, firstNonEmpty(strings.TrimSpace(got.Query), text), Paise(max))
				if note != "" {
					reply.Text = note
				}
			} else {
				reply.Action = s.chatAction(userID, contacts, got)
			}
		}
	}
	if reply.Source == "rules" {
		reply.Text, reply.Action = s.chatRules(userID, text, contacts, facts)
		if isShopping(text) {
			if q, max := shopRules(text); q != "" {
				act, note := s.shopAction(ctx, q, max)
				reply.Action, reply.Text = act, firstNonEmpty(note, fmt.Sprintf("Here are some picks for %s. Prices are converted to rupees; you buy on the shop's site, then you can split it or add it to a trip.", q))
			}
		}
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	mine := &domain.ChatMessage{ID: newID("msg"), UserID: userID, Role: "user", Text: text, At: s.now()}
	reply.ID, reply.UserID, reply.At = newID("msg"), userID, s.now().Add(time.Millisecond)
	s.chats[userID] = append(s.chats[userID], mine, reply)
	s.track(mine, reply)
	if err := s.commitL(); err != nil {
		return nil, err
	}
	return []*domain.ChatMessage{mine, reply}, nil
}

// chatFacts reads the person's money from the working copy of the database.
func (s *Service) chatFacts(userID string, contacts []domain.PublicUser) (ChatFacts, string, error) {
	me, err := s.Me(userID)
	if err != nil {
		return ChatFacts{}, "", err
	}
	f := ChatFacts{Balance: INR(me.PersonalBalance)}
	now := s.now().In(IST)
	monthStart := time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, IST)
	var week, month Paise
	byCat := map[domain.Category]Paise{}
	var catOrder []domain.Category
	for i, h := range s.History(userID) {
		if i < 8 {
			line := fmt.Sprintf("%s · %s · %s", h.At.In(IST).Format("2 Jan 3:04 pm"), h.Title, INR(h.Amount))
			if h.YourPart > 0 && h.YourPart != h.Amount {
				line += " (your part " + INR(h.YourPart) + ")"
			}
			if h.Wallet == "trip" && h.TripName != "" {
				line += " · " + h.TripName
			}
			f.Recent = append(f.Recent, line+" · "+h.Kind)
		}
		if h.Kind != "payment" {
			continue
		}
		part := h.YourPart
		if part == 0 {
			part = h.Amount
		}
		if now.Sub(h.At) <= 7*24*time.Hour {
			week += part
		}
		if !h.At.Before(monthStart) {
			month += part
			if _, ok := byCat[h.Category]; !ok {
				catOrder = append(catOrder, h.Category)
			}
			byCat[h.Category] += part
		}
	}
	f.SpentLast7Days, f.SpentThisMonth = INR(week), INR(month)
	for _, c := range catOrder {
		name := string(c)
		if name == "" {
			name = "other"
		}
		f.ByCategoryMonth = append(f.ByCategoryMonth, fmt.Sprintf("%s %s", name, INR(byCat[c])))
	}
	for _, r := range s.MoneyRequests(userID) {
		if r.Status != "open" {
			continue
		}
		what := ""
		if r.Note != "" {
			what = " for " + r.Note
		}
		if r.Direction == "incoming" {
			f.AskedOfYou = append(f.AskedOfYou, fmt.Sprintf("%s asks you for %s%s", r.Requester.Name, INR(r.Amount), what))
		} else {
			f.YouAsked = append(f.YouAsked, fmt.Sprintf("you asked %s for %s%s", r.Payer.Name, INR(r.Amount), what))
		}
	}
	for _, t := range s.ListTrips(userID) {
		line := fmt.Sprintf("%s (%s): wallet %s, spent %s", t.Name, t.Status, INR(t.Balance), INR(t.Spent))
		for _, m := range t.MemberDetails {
			if m.User.ID == userID {
				line += fmt.Sprintf(", your share left %s", INR(m.Left))
			}
		}
		if t.Status == domain.TripOpen && t.Days > 0 {
			line += fmt.Sprintf(", day %d of %d", t.Day, t.Days)
		}
		f.Trips = append(f.Trips, line)
	}
	for _, c := range contacts {
		f.People = append(f.People, c.Name)
	}
	return f, me.User.Name, nil
}

var chatScreens = map[string]string{
	"add_money": "Add money",
	"requests":  "Open requests",
	"trips":     "Open trips",
	"history":   "Open history",
	"insights":  "Open insights",
	"split":     "Split a bill",
}

// chatAction turns the model's suggestion into a button, keeping only what
// checks out: a known person, a valid amount, a real screen or trip.
func (s *Service) chatAction(userID string, contacts []domain.PublicUser, r ai.ChatReply) *domain.ChatAction {
	switch r.Action {
	case "pay", "request":
		q := QuickPayResult{Action: r.Action}
		s.pickPerson(&q, userID, contacts, r.Person, r.Person)
		if q.Person == nil {
			return nil
		}
		amount, _ := ai.ParseRupees(r.Amount)
		if Paise(amount) > MaxAmount {
			amount = 0
		}
		return payAction(r.Action, q.Person, Paise(amount), strings.TrimSpace(r.Note))
	case "open":
		if r.Screen == "trip" {
			for _, t := range s.ListTrips(userID) {
				if strings.EqualFold(strings.TrimSpace(r.Trip), t.Name) {
					return &domain.ChatAction{Type: "open", Screen: "trip", TripID: t.ID, Label: "Open " + t.Name}
				}
			}
			return &domain.ChatAction{Type: "open", Screen: "trips", Label: chatScreens["trips"]}
		}
		if label, ok := chatScreens[r.Screen]; ok {
			return &domain.ChatAction{Type: "open", Screen: r.Screen, Label: label}
		}
	}
	return nil
}

func payAction(kind string, p *domain.PublicUser, amount Paise, note string) *domain.ChatAction {
	first := firstName(p.Name)
	a := &domain.ChatAction{Type: kind, Person: p, Amount: amount, Note: note}
	switch {
	case kind == "request" && amount > 0:
		a.Label = fmt.Sprintf("Ask %s for %s", first, INR(amount))
	case kind == "request":
		a.Label = "Ask " + first
	case amount > 0:
		a.Label = fmt.Sprintf("Review: pay %s %s", first, INR(amount))
	default:
		a.Label = "Pay " + first
	}
	return a
}

var (
	reChatPay     = regexp.MustCompile(`(?i)\b(pay|send|give|transfer|request|ask|collect)\b`)
	reChatBalance = regexp.MustCompile(`(?i)\b(balance|how much (do i|have i) (have|got)|money left|wallet)\b`)
	reChatOwe     = regexp.MustCompile(`(?i)\b(owe|owes|owed|pending|requests?|due)\b`)
	reChatSpend   = regexp.MustCompile(`(?i)\b(spen[dt]|spending|expenses?|bills?)\b`)
	reChatTrip    = regexp.MustCompile(`(?i)\btrips?\b`)
	reChatTopUp   = regexp.MustCompile(`(?i)\b(add money|top ?up|add funds|load)\b`)
	reChatSplit   = regexp.MustCompile(`(?i)\bsplit\b`)
	reChatRecent  = regexp.MustCompile(`(?i)\b(history|recent|last (payment|transaction)s?)\b`)
)

// chatRules answers the common questions without a model.
func (s *Service) chatRules(userID, text string, contacts []domain.PublicUser, f ChatFacts) (string, *domain.ChatAction) {
	if reChatPay.MatchString(text) {
		q := s.quickPayRules(userID, text, contacts)
		if q.Person != nil {
			return quickPayReply(q), payAction(q.Action, q.Person, q.Amount, q.Note)
		}
		if len(q.Choices) > 1 {
			names := make([]string, 0, len(q.Choices))
			for _, c := range q.Choices {
				names = append(names, c.Name)
			}
			return "Which one: " + strings.Join(names, " or ") + "?", nil
		}
	}
	switch {
	case reChatTopUp.MatchString(text):
		return "Add money from PayPal and it lands in your Pointy balance (" + f.Balance + " now).", &domain.ChatAction{Type: "open", Screen: "add_money", Label: chatScreens["add_money"]}
	case reChatSplit.MatchString(text):
		return "Split a bill: enter the total, pick who was there, and Pointy asks each person for their share.", &domain.ChatAction{Type: "open", Screen: "split", Label: chatScreens["split"]}
	case reChatOwe.MatchString(text):
		var parts []string
		if len(f.AskedOfYou) > 0 {
			parts = append(parts, "People ask you for: "+strings.Join(f.AskedOfYou, "; ")+".")
		}
		if len(f.YouAsked) > 0 {
			parts = append(parts, "You are waiting on: "+strings.Join(f.YouAsked, "; ")+".")
		}
		if len(parts) == 0 {
			return "Nothing is pending: nobody owes you and you owe nobody.", nil
		}
		return strings.Join(parts, " "), &domain.ChatAction{Type: "open", Screen: "requests", Label: chatScreens["requests"]}
	case reChatSpend.MatchString(text):
		msg := fmt.Sprintf("You spent %s in the last 7 days and %s this month.", f.SpentLast7Days, f.SpentThisMonth)
		if len(f.ByCategoryMonth) > 0 {
			msg += " This month: " + strings.Join(f.ByCategoryMonth, ", ") + "."
		}
		return msg, &domain.ChatAction{Type: "open", Screen: "insights", Label: chatScreens["insights"]}
	case reChatTrip.MatchString(text):
		if len(f.Trips) == 0 {
			return "You are not on any trip yet. Plan one from the Trips tab and everyone puts money into one wallet.", &domain.ChatAction{Type: "open", Screen: "trips", Label: chatScreens["trips"]}
		}
		return strings.Join(f.Trips, ". ") + ".", &domain.ChatAction{Type: "open", Screen: "trips", Label: chatScreens["trips"]}
	case reChatRecent.MatchString(text):
		if len(f.Recent) == 0 {
			return "No payments yet.", nil
		}
		n := min(3, len(f.Recent))
		return "Latest: " + strings.Join(f.Recent[:n], "; ") + ".", &domain.ChatAction{Type: "open", Screen: "history", Label: chatScreens["history"]}
	case reChatBalance.MatchString(text):
		return "Your Pointy balance is " + f.Balance + ".", nil
	}
	return "I can tell you your balance, what you spent, who owes whom and how your trips are going, fill in a payment (\"pay Dev 200 for chai\") or find things to buy (\"find sunscreen under 1500\"). I never send money myself; you always confirm.", nil
}
