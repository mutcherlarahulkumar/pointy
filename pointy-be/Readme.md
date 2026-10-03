# pointy-be

Backend for Pointy: a UPI-style payments app with shared trip wallets, built on the PayPal sandbox.

It is one Go service with no third-party dependencies (Go 1.22 standard library only), so `go run` works straight after cloning.

## Run it

```bash
cd pointy-be
go test ./...            # 9 tests: ledger, splits, budgets, deposits, assistant, settle-up
go run ./cmd/server      # http://localhost:8080
```

By default it starts in **mock** mode with the Goa trip from the designs already loaded, and the clock frozen at Tue 13 Oct 2026, 8:42 pm (day 2 of the trip). Try:

```bash
curl localhost:8080/api/trips/t_goa
curl -X POST localhost:8080/api/suggestions -d '{"place_type":"restaurant"}'
curl -X POST localhost:8080/api/trips/t_goa/expenses \
  -H 'Idempotency-Key: demo-1' \
  -d '{"description":"Dinner","category":"food","amount_paise":184000,
       "payee":"Beach shack, Baga","payee_email":"shack@example.com",
       "place_name":"Baga","place_type":"restaurant"}'
# -> 409 budget_warning (food budget 48% -> 85%). Add "confirm_over_budget": true to pay.
```

## Connect the PayPal sandbox

1. Copy `.env.example` to `.env` and fill in the client ID, the secret and the sandbox business account email. `.env` is ignored by git; never commit the secret.
2. Check each PayPal feature on its own before starting the server:

```bash
go run ./cmd/paypalcheck                      # sign in, create a Rs 100 order, print the approve link
go run ./cmd/paypalcheck -capture ORDER_ID    # after approving it with a sandbox personal account
go run ./cmd/paypalcheck -payout  buyer@...   # needs Payouts switched on for the sandbox app
go run ./cmd/paypalcheck -invoice buyer@...   # needs Invoicing switched on for the sandbox app
```

3. When all four print `OK`, run `go run ./cmd/server`. It reads the same `.env`.

Webhooks need a public URL. Until one is registered, the app captures deposits itself through `POST /api/deposits/{orderID}/capture`, and paid requests are not detected.

## Settings

| Variable | Default | Meaning |
|---|---|---|
| `PORT` | `8080` | Port to listen on |
| `PAYPAL_MODE` | `mock` | `mock` never leaves the process. `sandbox` calls PayPal |
| `PAYPAL_CLIENT_ID`, `PAYPAL_SECRET` | | Sandbox REST app credentials (needed for `sandbox`) |
| `PAYPAL_WEBHOOK_ID` | | Id of the webhook registered for `/webhooks/paypal` |
| `PAYPAL_INVOICER_EMAIL` | | Sandbox business account email, used on invoices |
| `PAYPAL_CURRENCY` | `USD` | Currency PayPal is charged in |
| `POINTY_INR_PER_UNIT` | `85` | Demo conversion rate: rupees per one unit of `PAYPAL_CURRENCY`. A placeholder, not a live rate |
| `PAYPAL_RETURN_URL`, `PAYPAL_CANCEL_URL` | example.com | Where PayPal sends the member after approving |
| `POINTY_SEED` | `true` | Load the demo trip |
| `POINTY_CLOCK` | `demo` | `demo` freezes time at the design moment. `real` uses the system clock |

## API

All amounts are integers in paise (`amount_paise`). The caller is named by the `X-User-Id` header (default `u_you`; demo users are `u_you`, `u_asha`, `u_dev`, `u_meera`). Send an `Idempotency-Key` header on every POST that moves money: a retry with the same key replays the first answer instead of paying twice.

| Feature | Method and path |
|---|---|
| Home | `GET /api/me`, `POST /api/suggestions`, `POST /api/payments/personal` |
| History, alerts | `GET /api/history`, `GET /api/alerts` |
| Trips | `GET /api/trips`, `POST /api/trips`, `GET /api/trips/{id}` |
| Deposits | `POST /api/trips/{id}/deposits`, `POST /api/deposits/{orderID}/capture` |
| Pay and split | `GET` and `POST /api/trips/{id}/expenses` |
| Budgets | `GET` and `PUT /api/trips/{id}/budgets`, `POST /api/trips/{id}/budget-check` |
| Insights | `GET /api/trips/{id}/insights` |
| Settle up | `GET /api/trips/{id}/settlement`, `POST /api/trips/{id}/settle` |
| Assistant | `POST /api/trips/{id}/assistant/plan`, `POST /api/trips/{id}/assistant/plans/{planID}/confirm`, `GET /api/trips/{id}/requests`, `POST /api/requests/{requestID}/remind` |
| PayPal | `POST /webhooks/paypal` |
| Mock only | `POST /api/demo/requests/{requestID}/paid` (stands in for the invoice-paid webhook) |

Errors look like `{"error":{"code":"...","message":"...","details":{...}}}`. Codes the app should handle: `budget_warning`, `insufficient_share`, `insufficient_balance`, `trip_closed`, `reminder_cap`, `paypal_error`.

## How the money stays right

- **One ledger.** Every movement is a double-entry journal entry that must balance. Balances are never stored, only derived. See `internal/domain/ledger.go`.
- **Holds.** A payment reserves each person's part before PayPal is called and releases it afterwards, so two payments at once cannot spend the same rupee. See `internal/app/expenses.go`.
- **Nothing is written on failure.** If PayPal refuses, the hold is released and the ledger is untouched.
- **Idempotent.** Capturing a deposit twice, or receiving the same webhook twice, credits once.
- **Settle-up cross-check.** Refunds must add up to exactly what PayPal holds for the trip, or the settle is refused.
- **The assistant only drafts.** `assistant/plan` sends nothing. Requests go out only on `confirm`, and only from the organiser.

## Layout

```
cmd/server          entry point
cmd/paypalcheck     checks the sandbox credentials, one feature at a time
internal/config     settings from the environment and .env
internal/domain     money, split, ledger, budget maths. No I/O
internal/paypal     the payment rail: Client interface, Mock, Sandbox
internal/app        use cases, in-memory state, demo data, tests
internal/httpapi    routes, JSON, CORS, idempotency
```

## What is not done yet

- **Storage is in memory.** Restarting the server resets it to the demo data. Postgres is the next step.
- **Sign-in is a header.** There is no OTP login or token check.
- **The sandbox rail has not been run against PayPal.** `internal/paypal/sandbox.go` is written from the API reference and compiles, but it was developed without sandbox credentials. Expect to adjust it on first contact.
- **Suggestions and summaries are rules and templates**, not an LLM. The deposit assistant reads the amount and date with a small parser.
- **The standard library router is used instead of Gin**, to keep the module dependency-free. The handlers are thin, so moving them to Gin is mechanical.
