package ai

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/anthropics/anthropic-sdk-go"
	"github.com/anthropics/anthropic-sdk-go/option"
	"github.com/anthropics/anthropic-sdk-go/shared/constant"
)

// DefaultModel is used unless POINTY_AI_MODEL says otherwise.
const DefaultModel = "claude-opus-5-5"

// Claude implements Assistant with the Anthropic API.
type Claude struct {
	client anthropic.Client
	model  string
}

// NewClaude builds the client. apiKey comes from ANTHROPIC_API_KEY.
func NewClaude(apiKey, model string) *Claude {
	if model == "" {
		model = DefaultModel
	}
	return &Claude{client: anthropic.NewClient(option.WithAPIKey(apiKey), option.WithMaxRetries(1)), model: model}
}

// ErrDeclined is returned when the model declines a request; callers fall
// back to the rule-based answer.
var ErrDeclined = errors.New("ai: the model declined this request")

// structured sends one request and decodes the JSON answer into out. The
// answer is constrained to schema by structured outputs, so it always parses.
func (c *Claude) structured(ctx context.Context, system string, content []anthropic.BetaContentBlockParamUnion, schema map[string]any, out any) error {
	resp, err := c.client.Beta.Messages.New(ctx, anthropic.BetaMessageNewParams{
		Model:     c.model,
		MaxTokens: 8000,
		System:    []anthropic.BetaTextBlockParam{{Text: system}},
		Messages:  []anthropic.BetaMessageParam{anthropic.NewBetaUserMessage(content...)},
		// These are short, well-specified tasks: low effort keeps them quick.
		OutputConfig: anthropic.BetaOutputConfigParam{
			Effort: anthropic.BetaOutputConfigEffortLow,
			Format: anthropic.BetaJSONOutputFormatParam{Schema: schema},
		},
		// If a safety classifier declines, another model answers within the
		// same call instead of the request simply stopping.
		Fallbacks: anthropic.BetaFallbacksParamUnion{OfDefault: constant.ValueOf[constant.Default]()},
		Betas:     []anthropic.AnthropicBeta{anthropic.AnthropicBetaServerSideFallback2026_07_01},
	})
	if err != nil {
		return err
	}
	if resp.StopReason == anthropic.BetaStopReasonRefusal {
		return ErrDeclined
	}
	if resp.StopReason == anthropic.BetaStopReasonMaxTokens {
		return errors.New("ai: the answer was cut off")
	}
	var text strings.Builder
	for _, block := range resp.Content {
		if t, ok := block.AsAny().(anthropic.BetaTextBlock); ok {
			text.WriteString(t.Text)
		}
	}
	if err := json.Unmarshal([]byte(text.String()), out); err != nil {
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
No markdown, no emoji, no headings.`

// Summarize writes a short summary of the trip's spending and one tip.
func (c *Claude) Summarize(ctx context.Context, f TripFacts) (Summary, error) {
	facts, err := json.MarshalIndent(f, "", "  ")
	if err != nil {
		return Summary{}, err
	}
	var out Summary
	err = c.structured(ctx, summarySystem,
		[]anthropic.BetaContentBlockParamUnion{anthropic.NewBetaTextBlock("Trip facts:\n" + string(facts))},
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
Never invent amounts or people.`

// ParseInstruction reads the organiser's sentence.
func (c *Claude) ParseInstruction(ctx context.Context, in InstructionInput) (Instruction, error) {
	data, err := json.MarshalIndent(in, "", "  ")
	if err != nil {
		return Instruction{}, err
	}
	var out Instruction
	err = c.structured(ctx, instructionSystem,
		[]anthropic.BetaContentBlockParamUnion{anthropic.NewBetaTextBlock(string(data))},
		obj(map[string]any{
			"understood":        map[string]any{"type": "boolean"},
			"per_person_rupees": str,
			"due_date":          str,
			"members":           map[string]any{"type": "array", "items": str},
			"reply":             str,
		}, "understood", "per_person_rupees", "due_date", "members", "reply"), &out)
	return out, err
}

const receiptSystem = `You read photos of bills and receipts for Pointy, an Indian payments app, so a trip expense can be filled in.
- is_receipt: false if the photo is not a bill or receipt, or the total cannot be read.
- merchant: the shop or restaurant name as printed, short.
- total: the final amount paid including taxes and service charge, as plain digits with optional paise ("1840", "1840.50"). Use the grand total, not a subtotal. "" if unreadable.
- currency: the ISO code, usually "INR".
- date: the bill date as YYYY-MM-DD, or "" if not printed.
- category: food (restaurants, cafes, groceries, drinks), stay (hotels, homestays), transport (cabs, fuel, tickets, rentals, tolls) or other.
- description: two to five words for the expense list, for example "Dinner at Britto's".
Never guess numbers you cannot read.`

// ReadReceipt reads a photo of a bill.
func (c *Claude) ReadReceipt(ctx context.Context, image []byte, mediaType string) (Receipt, error) {
	var out Receipt
	err := c.structured(ctx, receiptSystem,
		[]anthropic.BetaContentBlockParamUnion{
			anthropic.NewBetaImageBlock(anthropic.BetaBase64ImageSourceParam{
				Data: base64.StdEncoding.EncodeToString(image), MediaType: anthropic.BetaBase64ImageSourceMediaType(mediaType),
			}),
			anthropic.NewBetaTextBlock("Read this bill."),
		},
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
