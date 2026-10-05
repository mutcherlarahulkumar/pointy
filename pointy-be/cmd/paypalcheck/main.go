// Command paypalcheck proves the PayPal sandbox keys work before the app
// depends on them. Pointy only uses PayPal checkout (the Orders API).
//
//	go run ./cmd/paypalcheck                    # sign in and create a ₹100 order
//	go run ./cmd/paypalcheck -capture ORDER_ID  # capture it after approving in the browser
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/config"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
)

func main() {
	capture := flag.String("capture", "", "order id to capture, after approving it in the browser")
	flag.Parse()

	config.LoadDotEnv(".env")
	pp, err := config.Sandbox()
	if err != nil {
		fail("settings", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	if *capture != "" {
		if err := pp.CaptureOrder(ctx, *capture); err != nil {
			fail("capture", err)
		}
		fmt.Println("OK  captured order", *capture)
		return
	}
	o, err := pp.CreateOrder(ctx, fmt.Sprintf("check-%d", time.Now().Unix()), domain.Rupees(100), "Pointy order check")
	if err != nil {
		fail("create order", err)
	}
	fmt.Println("OK  signed in and created order", o.ID)
	fmt.Println("    1. open this link and approve with a sandbox PERSONAL account:")
	fmt.Println("      ", o.ApproveURL)
	fmt.Println("    2. then run: go run ./cmd/paypalcheck -capture", o.ID)
}

func fail(step string, err error) {
	fmt.Fprintf(os.Stderr, "FAILED at %s: %v\n", step, err)
	os.Exit(1)
}
