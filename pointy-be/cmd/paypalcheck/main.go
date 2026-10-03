// Command paypalcheck proves the PayPal sandbox credentials work, one feature
// at a time, before the app depends on them.
//
//	go run ./cmd/paypalcheck                      # sign in and create a ₹100 order
//	go run ./cmd/paypalcheck -capture ORDER_ID    # capture it after approving in the browser
//	go run ./cmd/paypalcheck -payout  buyer@...   # send ₹100 to a sandbox personal account
//	go run ./cmd/paypalcheck -invoice buyer@...   # email a ₹100 payment request
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/config"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/paypal"
)

func main() {
	capture := flag.String("capture", "", "order id to capture, after approving it in the browser")
	payout := flag.String("payout", "", "sandbox personal account email to send ₹100 to")
	invoice := flag.String("invoice", "", "sandbox personal account email to send a ₹100 request to")
	flag.Parse()

	config.LoadDotEnv(".env")
	pp, err := config.Sandbox()
	if err != nil {
		fail("settings", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	amount, ref := domain.Rupees(100), fmt.Sprintf("check-%d", time.Now().Unix())

	switch {
	case *capture != "":
		if err := pp.CaptureOrder(ctx, *capture); err != nil {
			fail("capture", err)
		}
		fmt.Println("OK  captured order", *capture)
	case *payout != "":
		id, err := pp.Payout(ctx, ref, []paypal.PayoutItem{{ReceiverEmail: *payout, Amount: amount, Note: "Pointy payout check", ItemID: ref}})
		if err != nil {
			fail("payout", err)
		}
		fmt.Println("OK  payout batch", id)
	case *invoice != "":
		inv, err := pp.CreateAndSendInvoice(ctx, paypal.InvoiceInput{Reference: ref, RecipientEmail: *invoice, Amount: amount, Description: "Pointy invoice check", Due: time.Now().AddDate(0, 0, 7)})
		if err != nil {
			fail("invoice", err)
		}
		fmt.Println("OK  invoice", inv.ID)
		fmt.Println("    pay link:", inv.PayURL)
	default:
		o, err := pp.CreateOrder(ctx, ref, amount, "Pointy order check")
		if err != nil {
			fail("create order", err)
		}
		fmt.Println("OK  signed in and created order", o.ID)
		fmt.Println("    1. open this link and approve with a sandbox PERSONAL account:")
		fmt.Println("      ", o.ApproveURL)
		fmt.Println("    2. then run: go run ./cmd/paypalcheck -capture", o.ID)
	}
}

func fail(step string, err error) {
	fmt.Fprintf(os.Stderr, "FAILED at %s: %v\n", step, err)
	os.Exit(1)
}
