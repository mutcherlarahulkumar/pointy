// Command server runs the Pointy backend.
package main

import (
	"log"
	"net/http"
	"time"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/app"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/config"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/httpapi"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/paypal"
)

var env = config.Env

func main() {
	config.LoadDotEnv(".env")
	var pp paypal.Client = &paypal.Mock{}
	if env("PAYPAL_MODE", "mock") == "sandbox" {
		sb, err := config.Sandbox()
		if err != nil {
			log.Fatal(err)
		}
		pp = sb
	}

	// With the demo clock the server believes it is Tuesday 13 Oct 2026,
	// 8:42 pm, so the seeded trip is on day 2 exactly as in the designs.
	now := time.Now
	if env("POINTY_CLOCK", "demo") == "demo" {
		now = func() time.Time { return app.DemoNow }
	}
	svc := app.New(pp, now)
	if env("POINTY_SEED", "true") == "true" {
		app.SeedDemo(svc)
	}

	addr := ":" + env("PORT", "8080")
	srv := &http.Server{Addr: addr, Handler: httpapi.New(svc, pp, pp.Mode() == "mock"), ReadHeaderTimeout: 10 * time.Second}
	log.Printf("pointy-be listening on %s (paypal: %s, clock: %s)", addr, pp.Mode(), env("POINTY_CLOCK", "demo"))
	log.Fatal(srv.ListenAndServe())
}
