// Command server runs the Pointy backend.
package main

import (
	"context"
	"log"
	"net/http"
	"time"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/app"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/config"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/httpapi"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/paypal"
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
