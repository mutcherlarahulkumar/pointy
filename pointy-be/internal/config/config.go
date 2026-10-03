// Package config reads settings from the environment, and from a local .env
// file so secrets never have to be typed on the command line or committed.
package config

import (
	"bufio"
	"errors"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/paypal"
)

// LoadDotEnv reads KEY=VALUE lines from path. Variables that are already set
// in the environment win, and a missing file is not an error.
func LoadDotEnv(path string) {
	f, err := os.Open(path)
	if err != nil {
		return
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		k, v = strings.TrimSpace(k), strings.Trim(strings.TrimSpace(v), `"'`)
		if _, set := os.LookupEnv(k); !set {
			os.Setenv(k, v)
		}
	}
}

func Env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// Sandbox builds the PayPal client from the environment.
func Sandbox() (*paypal.Sandbox, error) {
	rate, err := strconv.ParseFloat(Env("POINTY_INR_PER_UNIT", "85"), 64)
	if err != nil || rate <= 0 {
		return nil, errors.New("POINTY_INR_PER_UNIT must be a positive number")
	}
	sb := &paypal.Sandbox{
		BaseURL: Env("PAYPAL_BASE_URL", "https://api-m.sandbox.paypal.com"), ClientID: os.Getenv("PAYPAL_CLIENT_ID"), Secret: os.Getenv("PAYPAL_SECRET"),
		WebhookID: os.Getenv("PAYPAL_WEBHOOK_ID"), Currency: Env("PAYPAL_CURRENCY", "USD"), INRPerUnit: rate,
		ReturnURL: Env("PAYPAL_RETURN_URL", "https://example.com/pointy/return"), CancelURL: Env("PAYPAL_CANCEL_URL", "https://example.com/pointy/cancel"),
		InvoicerMail: os.Getenv("PAYPAL_INVOICER_EMAIL"), HTTP: &http.Client{Timeout: 20 * time.Second},
	}
	if sb.ClientID == "" || sb.Secret == "" {
		return nil, errors.New("PAYPAL_CLIENT_ID and PAYPAL_SECRET must both be set (put them in pointy-be/.env)")
	}
	return sb, nil
}
