package ai

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// Default models. gpt-oss supports strict JSON-schema output on Groq, so its
// answers always match the schema; Llama 4 Scout reads images.
const (
	DefaultModel       = "openai/gpt-oss-120b"
	DefaultVisionModel = "meta-llama/llama-4-scout-17b-16e-instruct"
	groqURL            = "https://api.groq.com/openai/v1/chat/completions"
)

// Groq implements Assistant with Groq's OpenAI-compatible chat API.
type Groq struct {
	apiKey      string
	model       string
	visionModel string
	url         string
	http        *http.Client
}

// NewGroq builds the client. apiKey comes from GROQ_API_KEY; empty model
// names use the defaults.
func NewGroq(apiKey, model, visionModel string) *Groq {
	if model == "" {
		model = DefaultModel
	}
	if visionModel == "" {
		visionModel = DefaultVisionModel
	}
	return &Groq{apiKey: apiKey, model: model, visionModel: visionModel, url: groqURL, http: &http.Client{Timeout: 60 * time.Second}}
}

// ErrDeclined is returned when the model gives no usable answer; callers
// fall back to the rule-based one.
var ErrDeclined = errors.New("ai: the model gave no usable answer")

type chatMessage struct {
	Role    string `json:"role"`
	Content any    `json:"content"` // a string, or content parts for images
}

type chatRequest struct {
	Model           string        `json:"model"`
	Messages        []chatMessage `json:"messages"`
	ResponseFormat  any           `json:"response_format"`
	Temperature     float64       `json:"temperature"`
	MaxTokens       int           `json:"max_completion_tokens"`
	ReasoningEffort string        `json:"reasoning_effort,omitempty"`
}

// complete sends one chat request whose answer must be JSON matching schema,
// and decodes it into out.
func (g *Groq) complete(ctx context.Context, model, system string, user any, name string, schema map[string]any, out any) error {
	req := chatRequest{
		Model:       model,
		Messages:    []chatMessage{{Role: "system", Content: system}, {Role: "user", Content: user}},
		Temperature: 0.2,
		MaxTokens:   4000,
		ResponseFormat: map[string]any{"type": "json_schema", "json_schema": map[string]any{
			"name": name, "schema": schema,
			// Constrained decoding is only offered on the gpt-oss models.
			"strict": strings.HasPrefix(model, "openai/gpt-oss"),
		}},
	}
	if strings.HasPrefix(model, "openai/gpt-oss") {
		req.ReasoningEffort = "low" // short, well-specified tasks
	}
	body, err := json.Marshal(req)
	if err != nil {
		return err
	}
	hreq, err := http.NewRequestWithContext(ctx, http.MethodPost, g.url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	hreq.Header.Set("Authorization", "Bearer "+g.apiKey)
	hreq.Header.Set("Content-Type", "application/json")
	res, err := g.http.Do(hreq)
	if err != nil {
		return fmt.Errorf("ai: groq: %w", err)
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if res.StatusCode != http.StatusOK {
		var e struct {
			Error struct{ Message string } `json:"error"`
		}
		_ = json.Unmarshal(raw, &e)
		return fmt.Errorf("ai: groq returned HTTP %d: %s", res.StatusCode, e.Error.Message)
	}
	var resp struct {
		Choices []struct {
			Message      struct{ Content string } `json:"message"`
			FinishReason string                   `json:"finish_reason"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(raw, &resp); err != nil || len(resp.Choices) == 0 {
		return ErrDeclined
	}
	c := resp.Choices[0]
	if c.FinishReason == "length" {
		return errors.New("ai: the answer was cut off")
	}
	if strings.TrimSpace(c.Message.Content) == "" {
		return ErrDeclined
	}
	if err := json.Unmarshal([]byte(c.Message.Content), out); err != nil {
		return fmt.Errorf("ai: answer is not the expected JSON: %w", err)
	}
	return nil
}

func obj(props map[string]any, required ...string) map[string]any {
	return map[string]any{"type": "object", "properties": props, "required": required, "additionalProperties": false}
}

var str = map[string]any{"type": "string"}

const summarySystem = `You write the spending summary for a group trip in Pointy, an Indian payments app.
Write in plain, friendly English for people checking the app on a trip. Amounts are already formatted in rupees; quote them exactly as given and never do arithmetic of your own.
The summary is two or three short sentences: where the trip stands, what the money went on, and whether the wallet will last. The tip is one concrete, kind suggestion the group could act on today, or an empty string if there is nothing useful to say.
No markdown, no emoji, no headings. Answer with JSON only.`

// Summarize writes a short summary of the trip's spending and one tip.
func (g *Groq) Summarize(ctx context.Context, f TripFacts) (Summary, error) {
	facts, err := json.MarshalIndent(f, "", "  ")
	if err != nil {
		return Summary{}, err
	}
	var out Summary
	err = g.complete(ctx, g.model, summarySystem, "Trip facts:\n"+string(facts), "trip_summary",
		obj(map[string]any{"summary": str, "tip": str}, "summary", "tip"), &out)
	return out, err
}

const instructionSystem = `You read instructions that a trip organiser types to Pointy's deposit assistant, for example "Collect ₹3,000 from everyone by 20 Oct" or "ask Dev and Meera for 2k each by Friday".
Work out:
- per_person_rupees: the amount each person should have put in, as plain digits with optional paise ("3000", "2500.50"). Understand shorthand such as 2k = 2000, 1.5k = 1500, "one thousand". If no amount is given, use the usual deposit when there is one, else "".
- due_date: the due date as YYYY-MM-DD, resolving words like "Friday", "tomorrow" or "next week" from today's date. If no date is given, "".
- members: the names of the people to ask, spelled exactly as in the members list. An empty list means everyone. Never include names that are not in the list.
- understood: false if the message is not about collecting money for this trip, or the amount is unclear.
- reply: one short, friendly sentence for the chat. If understood, say what you will draft (it is only a draft; the organiser confirms before anything is sent). If not, ask for what is missing.
Never invent amounts or people. Answer with JSON only.`

// ParseInstruction reads the organiser's sentence.
func (g *Groq) ParseInstruction(ctx context.Context, in InstructionInput) (Instruction, error) {
	data, err := json.MarshalIndent(in, "", "  ")
	if err != nil {
		return Instruction{}, err
	}
	var out Instruction
	err = g.complete(ctx, g.model, instructionSystem, string(data), "deposit_instruction",
		obj(map[string]any{
			"understood":        map[string]any{"type": "boolean"},
			"per_person_rupees": str,
			"due_date":          str,
			"members":           map[string]any{"type": "array", "items": str},
			"reply":             str,
		}, "understood", "per_person_rupees", "due_date", "members", "reply"), &out)
	return out, err
}

const quickPaySystem = `You read one-line payment messages typed into Pointy, an Indian payments app, for example "pay Asha 200 for coffee", "send 1.5k to Dev for the cab" or "ask Meera for 500 for movie tickets".
Work out:
- action: "request" when the person wants to receive money (ask, request, collect, get money from someone), otherwise "pay".
- person: who to pay or ask. Use the name exactly as written in the contacts list when it matches (a first name or nickname for a listed person counts). If the message gives a 10-digit Indian mobile number, use those 10 digits. Otherwise "".
- amount_rupees: plain digits with optional paise ("200", "1500", "99.50"). Understand shorthand such as 2k = 2000, 1.5k = 1500, "five hundred". "" if no amount.
- note: what it is for, two to four words without "for" ("coffee", "cab to airport"), or "".
- understood: false if the message is not about paying or requesting money.
- reply: one short, friendly sentence. If something is missing (who, or how much), ask for it. Do not say the money was sent: the person still confirms.
Never invent people or amounts. Answer with JSON only.`

// ParseQuickPay reads a one-line payment.
func (g *Groq) ParseQuickPay(ctx context.Context, in QuickPayInput) (QuickPay, error) {
	data, err := json.MarshalIndent(in, "", "  ")
	if err != nil {
		return QuickPay{}, err
	}
	var out QuickPay
	err = g.complete(ctx, g.model, quickPaySystem, string(data), "quick_pay",
		obj(map[string]any{
			"understood":    map[string]any{"type": "boolean"},
			"action":        map[string]any{"type": "string", "enum": []string{"pay", "request"}},
			"person":        str,
			"amount_rupees": str,
			"note":          str,
			"reply":         str,
		}, "understood", "action", "person", "amount_rupees", "note", "reply"), &out)
	return out, err
}

const receiptSystem = `You read photos of bills and receipts for Pointy, an Indian payments app, so a trip expense can be filled in.
- is_receipt: false if the photo is not a bill or receipt, or the total cannot be read.
- merchant: the shop or restaurant name as printed, short.
- total: the final amount paid including taxes and service charge, as plain digits with optional paise ("1840", "1840.50"). Use the grand total, not a subtotal. "" if unreadable.
- currency: the ISO code, usually "INR".
- date: the bill date as YYYY-MM-DD, or "" if not printed.
- category: one of food (restaurants, cafes, groceries, drinks), stay (hotels, homestays), transport (cabs, fuel, tickets, rentals, tolls) or other.
- description: two to five words for the expense list, for example "Dinner at Britto's".
Never guess numbers you cannot read. Answer with JSON only.`

// ReadReceipt reads a photo of a bill with the vision model.
func (g *Groq) ReadReceipt(ctx context.Context, image []byte, mediaType string) (Receipt, error) {
	content := []map[string]any{
		{"type": "text", "text": "Read this bill."},
		{"type": "image_url", "image_url": map[string]any{"url": "data:" + mediaType + ";base64," + base64.StdEncoding.EncodeToString(image)}},
	}
	var out Receipt
	err := g.complete(ctx, g.visionModel, receiptSystem, content, "receipt",
		obj(map[string]any{
			"is_receipt":  map[string]any{"type": "boolean"},
			"merchant":    str,
			"total":       str,
			"currency":    str,
			"date":        str,
			"category":    map[string]any{"type": "string", "enum": []string{"food", "stay", "transport", "other"}},
			"description": str,
		}, "is_receipt", "merchant", "total", "currency", "date", "category", "description"), &out)
	return out, err
}
