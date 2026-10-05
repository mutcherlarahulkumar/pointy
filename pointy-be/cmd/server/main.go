// Command server runs the Pointy backend.
package main

import (
	"context"
	"log"
	"net/http"
	"time"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/ai"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/app"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/config"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/httpapi"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/paypal"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/shop"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/store"
)

var env = config.Env

func main() {
	config.LoadDotEnv(".env")

	// PayPal: the sandbox when keys are set, otherwise a mock that approves
	// every payment at once (fine for trying the app, never for real money).
	var pp paypal.Client = &paypal.Mock{}
	if env("PAYPAL_MODE", "mock") == "sandbox" {
		sb, err := config.Sandbox()
		if err != nil {
			log.Fatal(err)
		}
		pp = sb
	}

	// Storage: Postgres when DATABASE_URL is set, otherwise memory only.
	var st app.Store = app.MemoryStore{}
	if url := env("DATABASE_URL", ""); url != "" {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		pg, err := store.Open(ctx, url)
		cancel()
		if err != nil {
			log.Fatal(err)
		}
		defer pg.Close()
		st = pg
	} else {
		log.Print("WARNING: DATABASE_URL is not set; everything is lost when the server stops")
	}

	svc := app.New(pp, func() time.Time { return time.Now().In(app.IST) }, st)

	// Language-model features (trip summaries, the deposit assistant) turn on
	// when a Groq API key is set; without one they use rules.
	if key := env("GROQ_API_KEY", ""); key != "" {
		g := ai.NewGroq(key, env("POINTY_AI_MODEL", ""), env("POINTY_AI_VISION_MODEL", ""))
		svc.SetAssistant(g)
		log.Printf("AI features on (Groq, model %s)", env("POINTY_AI_MODEL", ai.DefaultModel))
	}
	// Product search for Pointy AI's "find me…" answers, with Channel3.
	if key := env("CHANNEL3_API_KEY", ""); key != "" {
		sh, err := shop.New(key, env("POINTY_INR_PER_UNIT", "85"))
		if err != nil {
			log.Fatal(err)
		}
		sh.BaseURL = env("CHANNEL3_BASE_URL", shop.DefaultBaseURL)
		svc.SetShopper(sh)
		log.Print("shopping on (Channel3)")
	} else {
		// Without a key the shopping agent uses a small built-in catalogue,
		// so the whole app can be tried with no accounts at all.
		svc.SetShopper(shop.Demo{})
		log.Print("shopping on (built-in demo catalogue; set CHANNEL3_API_KEY for real shops)")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	if err := svc.Load(ctx); err != nil {
		log.Fatal(err)
	}
	cancel()

	addr := ":" + env("PORT", "8080")
	srv := &http.Server{Addr: addr, Handler: httpapi.New(svc, pp), ReadHeaderTimeout: 10 * time.Second}
	log.Printf("pointy-be listening on %s (paypal: %s, public url: %s)", addr, pp.Mode(), config.PublicURL())
	log.Fatal(srv.ListenAndServe())
}
