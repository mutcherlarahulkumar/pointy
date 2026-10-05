# pointy-be

Backend for Pointy: pay friends, request money, split bills and run shared trip wallets. One Go service (Go 1.24) with Postgres.

## How money works (and why)

Pointy is a **wallet**. PayPal is used only at its two edges, with a US sandbox business account charged in USD and shown in rupees (PayPal does not pay between Indian accounts, and Payouts is not offered in India):

- **Add money** — checkout (the Orders API). The person approves on PayPal and their Pointy balance goes up.
- **Withdraw** — Payouts (`POST /v1/payments/payouts`) from the business account to the person's PayPal email, from where they move it to their bank.

Everything in between is an instant entry in Pointy's double-entry ledger, with no PayPal call: paying a Pointy user, requests, split bills, moving money into a trip, the trip paying a Pointy user (`mode: member`) or paying you back (`mode: reimburse`), and settle-up into balances. Balances are always derived from the ledger, never stored.

A withdrawal holds the money first, calls PayPal, and posts only if PayPal accepts it; if PayPal refuses, nothing changes. If it later comes back (unclaimed and returned, failed, blocked) the entry is reversed and the money is back in the balance. `GET /api/money` checks that the money at PayPal equals what Pointy owes everyone.

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
cmd/migrate       moves the schema up or down, shows what is applied
cmd/paypalcheck   proves the sandbox keys work: create an order, approve it, capture it, send a payout
internal/domain   money, split, ledger, budget maths. No I/O
internal/paypal   add money (checkout) and withdraw (payouts): interface, Mock, Sandbox
internal/app      use cases; keeps a working copy in memory and saves every change
internal/store    Postgres: versioned migrations, each change saved in one transaction
internal/httpapi  routes, bearer-token auth, JSON, idempotency, PayPal return page
```

## Database migrations

The schema lives in `internal/store/migrations/` as numbered pairs, `0001_init.up.sql` and `0001_init.down.sql`, built into the binary. Applied versions are recorded in the `schema_migrations` table.

```bash
go run ./cmd/migrate status     # applied and pending versions
go run ./cmd/migrate up         # apply everything pending
go run ./cmd/migrate up 1       # apply only the next one
go run ./cmd/migrate down       # undo the last one
go run ./cmd/migrate down 2     # undo the last two
```

It reads `DATABASE_URL` from the environment or `.env`. The server runs `up` on start, so a deploy on Render applies new migrations by itself. A Postgres advisory lock stops two processes from migrating at once, and each migration runs in one transaction with its `schema_migrations` row, so a failure leaves the last fully applied version.

To change the schema, add the next number with both an `up` and a `down` file. Never edit a migration that has already run anywhere. `down` on `0001` drops every table, and with them all the data.

A database created before migrations existed (tables, but no `schema_migrations`) is adopted on the first start: `0001` only creates what is missing.

The service runs as **one instance per database** (its in-memory copy is not shared).

## API

All `/api` routes except `auth/*` need `Authorization: Bearer <token>`. Money is integer paise. Send `Idempotency-Key` on every POST that moves money; a retry with the same key replays the first answer.

| Area | Routes |
|---|---|
| Sign in | `POST /api/auth/check-phone`, `POST /api/auth/register` (name, phone, 6-digit PIN), `POST /api/auth/login`, `POST /api/auth/logout`, `POST /api/auth/verify-pin` (`{"pin"}`, checks the PIN before a payment on phones with no screen lock; wrong PINs share the sign-in lockout) |
| You | `GET /api/me`, `PUT /api/me/paypal` (`{"email"}`, where payouts go), `GET /api/contacts`, `GET /api/users/lookup?phone=`, `GET /api/users/{id}` |
| Balance | `POST /api/topups`, `GET /api/deposits/{orderID}`, `POST /api/deposits/{orderID}/capture`, `POST /api/payments/personal` |
| Withdraw | `POST /api/withdrawals` (`{"amount_paise"}`, answers the payout with `status` and `paypal_batch_id`), `GET /api/payouts` (also refreshes pending ones), `GET /api/money` (money at PayPal, what is owed, `balanced`, your balance, trip shares, paid in and out) |
| Requests | `GET/POST /api/money-requests`, `POST /api/money-requests/{id}/pay`, `.../decline`, `POST /api/splits` |
| Activity | `GET /api/history`, `GET /api/alerts`, `POST /api/alerts/seen`, `POST /api/suggestions` |
| Trips | `GET/POST /api/trips`, `GET /api/trips/{id}`, `POST /api/trips/{id}/members`, `POST /api/trips/{id}/deposits` (from your balance) |
| Trip money | `GET/POST /api/trips/{id}/expenses` (`mode`: `member` with `payee_user_id`, any Pointy user, or `reimburse`), `GET/PUT /api/trips/{id}/budgets`, `POST .../budget-check`, `GET .../insights`, `GET .../settlement`, `POST .../settle` (refunds go to balances) |
| Assistant | `POST /api/trips/{id}/assistant/plan`, `POST .../plans/{planID}/confirm`, `GET /api/trips/{id}/requests`, `POST /api/requests/{id}/remind`, `POST /api/requests/{id}/pay` |
| PayPal | `GET /paypal/return` (finishes a checkout), `GET /paypal/cancel`, `POST /webhooks/paypal` |

Errors are `{"error":{"code","message","details"}}`; codes include `budget_warning`, `insufficient_share`, `insufficient_balance`, `trip_closed`, `reminder_cap`, `not_approved`, `no_paypal_email`, `payment_in_progress`, `paypal_error`, `wrong_pin`, `too_many_attempts`, `signed_out`.

## AI features (optional)

With `GROQ_API_KEY` set, `internal/ai` uses Groq's OpenAI-compatible chat API (`openai/gpt-oss-120b` by default, `POINTY_AI_MODEL` to change it):

- **Trip summaries**: Insights gets a plain-words summary and one tip, written from pre-formatted numbers (the model never does money arithmetic). Cached per trip until the numbers change.
- **Deposit assistant**: free-form instructions such as "ask Dev and Meera for 2k by Friday" become a plan for just those people. The model only drafts; the organiser still confirms before anything is sent.

- **Pointy AI** (always-on assistant): `GET /api/assistant/messages` (the saved conversation), `POST /api/assistant/messages` with `{"text": "..."}` (returns the question and the reply), `DELETE /api/assistant/messages` (clear). Each reply is written from the caller's own data in the database (balance, last 7 days and this month by category, recent activity, open requests both ways, trips with wallet and share left, people), with the last 10 lines as memory. A reply may carry one `action` (`pay`, `request` or `open` a screen); the server keeps it only if the person is a real contact or Pointy number and the screen exists, and the app only opens the confirm screen with it. Conversations are stored in `chat_messages` (migration 0002). Without a key, rules answer balance, spending, requests, trips, history and payments.
- **Shopping** (Channel3): `POST /api/shop/search` with `{"query", "max_paise"}` returns up to 6 in-stock products, each with its cheapest offer: title, brand, image, merchant, buy link (affiliate-tracked by Channel3), price converted to paise at `POINTY_INR_PER_UNIT` with whole-number maths, and the shop's own price ("$17.50"). Pointy AI uses it for "find sunscreen for our Goa trip under 1500" (action `shop`); the app shows cards with **Open shop**, **Split it** (split form filled in) and **Add to trip** (trip expense filled in). Pointy never buys anything itself. Needs `CHANNEL3_API_KEY`; `503 shop_off` without it.
- **Say it** (quick pay): `POST /api/quick-pay` with `{"text": "pay Asha 200 for coffee"}` returns `action` (`pay` or `request`), `person` (or `choices` when a name fits several people), `amount_paise`, `note`, `reply` and `source`. The model only picks from the caller's contacts or a mobile number of a Pointy user, so a made-up name never resolves. Without a key, or if the model fails, rules read it (names, numbers, `2k`, `for ...`). Nothing is paid: the app opens the usual confirm screen.
- **Receipt scanning**: `POST /api/receipts/scan` with `{"image_base64": "..."}` (JPEG/PNG, up to 3 MB) returns the total in paise, merchant, date, category and a short description. Read by Groq's vision model (`POINTY_AI_VISION_MODEL`, default `meta-llama/llama-4-scout-17b-16e-instruct`). Nothing is saved; the app fills the expense form and the person checks it. Non-rupee bills and photos that are not receipts are turned away. Answers `503 ai_off` when no key is set.

Requests ask for JSON matching a schema; on the gpt-oss models Groq enforces it strictly (constrained decoding), and answers are validated either way. Without a key, or on any error or timeout (20 s), the rule-based summary and parser answer instead, so the app never depends on the model being up. `Insights.summary_source` and `Plan.source` say which one answered.

## PayPal sandbox

1. In the PayPal developer dashboard create a sandbox **business** account and a **personal** account, both with country **United States**, and a REST app on the business account.
2. Set `PAYPAL_MODE=sandbox`, `PAYPAL_CLIENT_ID`, `PAYPAL_SECRET`.
3. `go run ./cmd/paypalcheck`, open the link, approve with the sandbox personal account, then `go run ./cmd/paypalcheck -capture ORDER_ID`. Both print `OK`.
4. **Payouts** (withdrawals): in the developer dashboard turn on **Payouts** for the REST app, and fund the sandbox business account (Sandbox accounts → the business account → add balance). Then `go run ./cmd/paypalcheck -payout PERSONAL_SANDBOX_EMAIL` sends ₹100 and prints the payout status. Payouts to an email with no PayPal account stay `UNCLAIMED` and come back after 30 days; Pointy then gives the money back.

After approving in the app's browser tab, PayPal sends the person to `/paypal/return`, which captures the payment at once; the app notices within a few seconds. A webhook (`CHECKOUT.ORDER.APPROVED` → `/webhooks/paypal`, with `PAYPAL_WEBHOOK_ID`) is optional extra safety.
