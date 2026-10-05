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

// fakeGroq answers like Groq's chat completions API and records the request.
func fakeGroq(t *testing.T, status int, finish, content string) (*Groq, *map[string]any, *http.Header) {
	t.Helper()
	var body map[string]any
	var hdr http.Header
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &body)
		hdr = r.Header.Clone()
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		if status != http.StatusOK {
			_ = json.NewEncoder(w).Encode(map[string]any{"error": map[string]any{"message": "rate limited"}})
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"choices": []any{map[string]any{"message": map[string]any{"role": "assistant", "content": content}, "finish_reason": finish}},
		})
	}))
	t.Cleanup(srv.Close)
	g := NewGroq("test-key", "", "")
	g.url = srv.URL
	return g, &body, &hdr
}

func TestSummarizeSendsAStrictSchemaRequest(t *testing.T) {
	g, body, hdr := fakeGroq(t, 200, "stop", `{"summary":"Day 2 of 5. ₹1,840 spent.","tip":"Split cabs."}`)
	got, err := g.Summarize(context.Background(), TripFacts{TripName: "Goa trip", Spent: "₹1,840"})
	if err != nil || got.Text != "Day 2 of 5. ₹1,840 spent." || got.Tip != "Split cabs." {
		t.Fatalf("%+v %v", got, err)
	}
	b := *body
	if b["model"] != DefaultModel || b["reasoning_effort"] != "low" || hdr.Get("Authorization") != "Bearer test-key" {
		t.Fatalf("model %v effort %v auth %q", b["model"], b["reasoning_effort"], hdr.Get("Authorization"))
	}
	rf := b["response_format"].(map[string]any)
	js := rf["json_schema"].(map[string]any)
	if rf["type"] != "json_schema" || js["strict"] != true || js["schema"].(map[string]any)["additionalProperties"] != false {
		t.Fatalf("response_format %v", rf)
	}
	user := b["messages"].([]any)[1].(map[string]any)["content"].(string)
	if !strings.Contains(user, "Goa trip") || !strings.Contains(user, "₹1,840") {
		t.Fatalf("facts not sent: %s", user)
	}
}

func TestParseInstruction(t *testing.T) {
	g, _, _ := fakeGroq(t, 200, "stop", `{"understood":true,"per_person_rupees":"2000","due_date":"2026-10-16","members":["Dev"],"reply":"I'll ask Dev."}`)
	got, err := g.ParseInstruction(context.Background(), InstructionInput{Text: "ask dev for 2k by friday", Members: []string{"Asha", "Dev"}})
	if err != nil || !got.Understood || got.PerPerson != "2000" || got.DueDate != "2026-10-16" || len(got.MemberNames) != 1 {
		t.Fatalf("%+v %v", got, err)
	}
}

func TestErrorsAreReported(t *testing.T) {
	g, _, _ := fakeGroq(t, 429, "", "")
	if _, err := g.Summarize(context.Background(), TripFacts{}); err == nil || !strings.Contains(err.Error(), "429") {
		t.Fatalf("got %v", err)
	}
	g, _, _ = fakeGroq(t, 200, "stop", "")
	if _, err := g.Summarize(context.Background(), TripFacts{}); !errors.Is(err, ErrDeclined) {
		t.Fatalf("empty answer: %v", err)
	}
	g, _, _ = fakeGroq(t, 200, "length", `{"summary":"Day`)
	if _, err := g.Summarize(context.Background(), TripFacts{}); err == nil {
		t.Fatal("a cut-off answer must be an error")
	}
}

func TestReadReceiptSendsTheImageToTheVisionModel(t *testing.T) {
	g, body, _ := fakeGroq(t, 200, "stop", `{"is_receipt":true,"merchant":"Britto's","total":"1840","currency":"INR","date":"","category":"food","description":"Dinner"}`)
	got, err := g.ReadReceipt(context.Background(), []byte{1, 2, 3}, "image/jpeg")
	if err != nil || got.Total != "1840" || got.Category != "food" {
		t.Fatalf("%+v %v", got, err)
	}
	b := *body
	if b["model"] != DefaultVisionModel || b["reasoning_effort"] != nil {
		t.Fatalf("model %v, effort %v", b["model"], b["reasoning_effort"])
	}
	if b["response_format"].(map[string]any)["json_schema"].(map[string]any)["strict"] != false {
		t.Fatal("strict mode is only for gpt-oss models")
	}
	parts := b["messages"].([]any)[1].(map[string]any)["content"].([]any)
	img := parts[1].(map[string]any)
	if img["type"] != "image_url" || img["image_url"].(map[string]any)["url"] != "data:image/jpeg;base64,AQID" {
		t.Fatalf("image part %v", img)
	}
}
