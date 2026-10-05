# pointy-be

Backend for Pointy: pay friends, request money, split bills and run shared trip wallets. One Go service (Go 1.24) with Postgres.

## How money works (and why)

PayPal shut down payments between Indian accounts on 1 April 2021, and the Payouts API is not offered in India. So Pointy uses PayPal for one thing only: **adding money** (checkout, the Orders API), with a US sandbox business account charged in USD and shown in rupees.

Everything after that moves inside Pointy's double-entry ledger, instantly: paying a friend, money requests, split bills, trip deposits, trip expenses, refunds. Each person has a personal balance and a share in each trip; balances are always derived from the ledger, never stored.

## Run it

```bash
cd pointy-be
go test ./...                                   # unit tests + two-phone HTTP test (in memory)
POINTY_TEST_DATABASE_URL=postgres://... go test ./...   # the same on Postgres, with a restart
DATABASE_URL=postgres://... go run ./cmd/server         # http://localhost:8080
```

Without `DATABASE_URL` it keeps everything in memory. Without `PAYPAL_MODE=sandbox` PayPal is simulated (every checkout approves at once) — fine for trying the app, never for a real demo of PayPal.

Settings are in `.env.example`.

## Layout

```
cmd/server        entry point: PayPal client, Postgres store, HTTP server
cmd/paypalcheck   proves the sandbox keys work: create an order, approve it, capture it
internal/domain   money, split, ledger, budget maths. No I/O
internal/paypal   checkout client: interface, Mock, Sandbox
internal/app      use cases; keeps a working copy in memory and saves every change
internal/store    Postgres: schema created on start, each change saved in one transaction
internal/httpapi  routes, bearer-token auth, JSON, idempotency, PayPal return page
```

The service runs as **one instance per database** (its in-memory copy is not shared).

## API

All `/api` routes except `auth/*` need `Authorization: Bearer <token>`. Money is integer paise. Send `Idempotency-Key` on every POST that moves money; a retry with the same key replays the first answer.

| Area | Routes |
|---|---|
| Sign in | `POST /api/auth/check-phone`, `POST /api/auth/register` (name, phone, 6-digit PIN), `POST /api/auth/login`, `POST /api/auth/logout` |
| You | `GET /api/me`, `GET /api/contacts`, `GET /api/users/lookup?phone=`, `GET /api/users/{id}` |
| Balance | `POST /api/topups`, `GET /api/deposits/{orderID}`, `POST /api/deposits/{orderID}/capture`, `POST /api/payments/personal` |
| Requests | `GET/POST /api/money-requests`, `POST /api/money-requests/{id}/pay`, `.../decline`, `POST /api/splits` |
| Activity | `GET /api/history`, `GET /api/alerts`, `POST /api/alerts/seen`, `POST /api/suggestions` |
| Trips | `GET/POST /api/trips`, `GET /api/trips/{id}`, `POST /api/trips/{id}/members`, `POST /api/trips/{id}/deposits` (`source`: `paypal` or `balance`) |
| Trip money | `GET/POST /api/trips/{id}/expenses` (`mode`: `reimburse` or `member`), `GET/PUT /api/trips/{id}/budgets`, `POST .../budget-check`, `GET .../insights`, `GET .../settlement`, `POST .../settle` |
| Assistant | `POST /api/trips/{id}/assistant/plan`, `POST .../plans/{planID}/confirm`, `GET /api/trips/{id}/requests`, `POST /api/requests/{id}/remind`, `POST /api/requests/{id}/pay` |
| PayPal | `GET /paypal/return` (finishes a checkout), `GET /paypal/cancel`, `POST /webhooks/paypal` |

Errors are `{"error":{"code","message","details"}}`; codes include `budget_warning`, `insufficient_share`, `insufficient_balance`, `trip_closed`, `reminder_cap`, `not_approved`, `wrong_pin`, `too_many_attempts`, `signed_out`.

## AI features (optional)

With `ANTHROPIC_API_KEY` set, `internal/ai` uses Claude (`claude-opus-5-5` by default, `POINTY_AI_MODEL` to change it):

- **Trip summaries**: Insights gets a plain-words summary and one tip, written from pre-formatted numbers (the model never does money arithmetic). Cached per trip until the numbers change.
- **Deposit assistant**: free-form instructions such as "ask Dev and Meera for 2k by Friday" become a plan for just those people. The model only drafts; the organiser still confirms before anything is sent.

- **Receipt scanning**: `POST /api/receipts/scan` with `{"image_base64": "..."}` (JPEG/PNG, up to 5 MB) returns the total in paise, merchant, date, category and a short description. Nothing is saved; the app fills the expense form and the person checks it. Non-rupee bills and photos that are not receipts are turned away. Answers `503 ai_off` when no key is set.

Requests use structured outputs (JSON schema), low effort, and server-side refusal fallbacks. Without a key, or on any error or timeout (20 s), the rule-based summary and parser answer instead, so the app never depends on the model being up. `Insights.summary_source` and `Plan.source` say which one answered.

## PayPal sandbox

1. In the PayPal developer dashboard create a sandbox **business** account and a **personal** account, both with country **United States**, and a REST app on the business account.
2. Set `PAYPAL_MODE=sandbox`, `PAYPAL_CLIENT_ID`, `PAYPAL_SECRET`.
3. `go run ./cmd/paypalcheck`, open the link, approve with the sandbox personal account, then `go run ./cmd/paypalcheck -capture ORDER_ID`. Both print `OK`.

After approving in the app's browser tab, PayPal sends the person to `/paypal/return`, which captures the payment at once; the app notices within a few seconds. A webhook (`CHECKOUT.ORDER.APPROVED` → `/webhooks/paypal`, with `PAYPAL_WEBHOOK_ID`) is optional extra safety.
