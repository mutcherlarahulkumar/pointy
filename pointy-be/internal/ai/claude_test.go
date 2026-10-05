package ai

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/anthropics/anthropic-sdk-go"
	"github.com/anthropics/anthropic-sdk-go/option"
)

func TestParseRupees(t *testing.T) {
	for in, want := range map[string]int64{"3000": 300000, "₹1,840.5": 184050, "2,500.05": 250005, " Rs 99 ": 9900} {
		if got, ok := ParseRupees(in); !ok || got != want {
			t.Fatalf("%q -> %d %v", in, got, ok)
		}
	}
	for _, bad := range []string{"", "2k", "-5", "1.234", "abc"} {
		if _, ok := ParseRupees(bad); ok {
			t.Fatalf("%q should not parse", bad)
		}
	}
}

// fakeAPI answers like the Messages API and records the request.
func fakeAPI(t *testing.T, stopReason, text string) (*Claude, *map[string]any, *http.Header) {
	t.Helper()
	var body map[string]any
	var hdr http.Header
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &body)
		hdr = r.Header.Clone()
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"id": "msg_test", "type": "message", "role": "assistant", "model": DefaultModel,
			"content":     []any{map[string]any{"type": "text", "text": text}},
			"stop_reason": stopReason, "usage": map[string]any{"input_tokens": 10, "output_tokens": 10},
		})
	}))
	t.Cleanup(srv.Close)
	c := &Claude{client: anthropic.NewClient(option.WithAPIKey("test"), option.WithBaseURL(srv.URL), option.WithMaxRetries(0)), model: DefaultModel}
	return c, &body, &hdr
}

func TestSummarizeSendsAStructuredRequest(t *testing.T) {
	c, body, hdr := fakeAPI(t, "end_turn", `{"summary":"Day 2 of 5. ₹1,840 spent.","tip":"Split cabs."}`)
	got, err := c.Summarize(context.Background(), TripFacts{TripName: "Goa trip", Spent: "₹1,840"})
	if err != nil || got.Text != "Day 2 of 5. ₹1,840 spent." || got.Tip != "Split cabs." {
		t.Fatalf("%+v %v", got, err)
	}
	b := *body
	if b["model"] != DefaultModel {
		t.Fatalf("model %v", b["model"])
	}
	oc := b["output_config"].(map[string]any)
	format := oc["format"].(map[string]any)
	if oc["effort"] != "low" || format["type"] != "json_schema" || format["schema"].(map[string]any)["additionalProperties"] != false {
		t.Fatalf("output_config %v", oc)
	}
	if b["fallbacks"] != "default" || !strings.Contains(hdr.Get("anthropic-beta"), "server-side-fallback-2026-07-01") {
		t.Fatalf("fallbacks %v, beta %q", b["fallbacks"], hdr.Get("anthropic-beta"))
	}
	if _, has := b["thinking"]; has {
		t.Fatal("thinking must be left to the model default")
	}
	msg := b["messages"].([]any)[0].(map[string]any)["content"].([]any)[0].(map[string]any)["text"].(string)
	if !strings.Contains(msg, "Goa trip") || !strings.Contains(msg, "₹1,840") {
		t.Fatalf("facts not sent: %s", msg)
	}
}

func TestParseInstruction(t *testing.T) {
	c, _, _ := fakeAPI(t, "end_turn", `{"understood":true,"per_person_rupees":"2000","due_date":"2026-10-16","members":["Dev"],"reply":"I'll ask Dev."}`)
	got, err := c.ParseInstruction(context.Background(), InstructionInput{Text: "ask dev for 2k by friday", Members: []string{"Asha", "Dev"}})
	if err != nil || !got.Understood || got.PerPerson != "2000" || got.DueDate != "2026-10-16" || len(got.MemberNames) != 1 {
		t.Fatalf("%+v %v", got, err)
	}
}

func TestRefusalIsAnError(t *testing.T) {
	c, _, _ := fakeAPI(t, "refusal", "")
	if _, err := c.Summarize(context.Background(), TripFacts{}); !errors.Is(err, ErrDeclined) {
		t.Fatalf("got %v", err)
	}
}
