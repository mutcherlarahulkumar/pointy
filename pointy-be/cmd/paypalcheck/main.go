// Command paypalcheck proves the PayPal sandbox keys work before the app
// depends on them: checkout (money in) and Payouts (money out).
//
//	go run ./cmd/paypalcheck                    # sign in and create a ₹100 order
//	go run ./cmd/paypalcheck -capture ORDER_ID  # capture it after approving in the browser
//	go run ./cmd/paypalcheck -payout EMAIL      # send ₹100 from the business account to a sandbox PayPal account
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
	payout := flag.String("payout", "", "a sandbox PayPal email to send a ₹100 payout to (needs Payouts on for the sandbox app)")
	flag.Parse()

	config.LoadDotEnv(".env")
	pp, err := config.Sandbox()
	if err != nil {
		fail("settings", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	if *payout != "" {
		p, err := pp.SendPayout(ctx, fmt.Sprintf("check-%d", time.Now().Unix()), *payout, domain.Rupees(100), "Pointy payout check")
		if err != nil {
			fail("payout (is Payouts on for the sandbox app, and is the business account funded?)", err)
		}
		fmt.Println("OK  payout sent, batch", p.BatchID, "status", p.Status)
		status, err := pp.PayoutStatus(ctx, p.BatchID)
		if err != nil {
			fail("payout status", err)
		}
		fmt.Println("OK  PayPal says the payout is", status)
		return
	}
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
