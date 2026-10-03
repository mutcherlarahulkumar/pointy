# Pointy — handoff for Claude Code / Cowork

Read this whole file before changing anything. It is the brief for finishing the project in this repo:
`https://github.com/mutcherlarahulkumar/pointy`

## 1. What Pointy is

A payments app in the style of a UPI app, built for a demo on the **PayPal sandbox** with a **rupee UI**. Trips are one feature in it: a shared wallet everyone deposits into, pays from and splits. AI suggests the category, wallet and split from the time and place, produces spending insights, and an assistant collects deposits.

The design rule the owner cares most about: **every feature is separate and every screen does one job.** Do not mix features on a screen.

## 2. State of the repo

| Path | State |
|---|---|
| `pointy-be/` | **Done and tested** (delivered with this file). Go 1.22, standard library only. 9 tests pass with `-race`. |
| `pointy/` | Fresh `flutter create` project. `lib/main.dart` is a 28-line practice screen. **Everything in the app is still to build.** |

### First steps

1. Put `pointy-be/` and this file at the repo root, run `cd pointy-be && go test ./...`, then commit and push (`feat(be): backend with ledger, trips, budgets, assistant`).
2. Create `pointy-be/.env` from `.env.example`. The owner supplies `PAYPAL_CLIENT_ID` and `PAYPAL_SECRET`. **Never commit `.env` or print the secret.**
3. Run `go run ./cmd/paypalcheck` (see section 6) and fix `internal/paypal/sandbox.go` until all four checks print `OK`. That file has never been run against PayPal.
4. Build the Flutter app (section 5), one feature per commit.

## 3. Backend

```bash
cd pointy-be
go test ./...
go run ./cmd/server        # http://localhost:8080, mock PayPal, demo data loaded
```

- Starts in **mock** mode with the Goa trip loaded and the clock frozen at **Tue 13 Oct 2026, 8:42 pm IST** (day 2 of 5). Set `POINTY_CLOCK=real` to use the system clock.
- Caller is the `X-User-Id` header (default `u_you`). Demo users: `u_you` (organiser), `u_asha`, `u_dev`, `u_meera`.
- **All money is integer paise** (`amount_paise`). Format in the app, never do float maths.
- Send an `Idempotency-Key` header on every POST that moves money. A retry with the same key replays the first answer.
- Errors: `{"error":{"code","message","details"}}`. Codes to handle in the UI: `budget_warning` (409), `insufficient_share` (409), `insufficient_balance` (409), `trip_closed` (409), `reminder_cap` (409), `paypal_error` (502), `forbidden` (403), `not_found` (404), `invalid` (400).

### Layout

```
cmd/server          entry point
cmd/paypalcheck     checks sandbox credentials, one feature at a time
internal/config     settings from the environment and .env
internal/domain     money, split, ledger, budget maths. No I/O
internal/paypal     payment rail: Client interface, Mock, Sandbox
internal/app        use cases, in-memory state, demo data, tests
internal/httpapi    routes, JSON, CORS, idempotency
```

### Endpoints

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
| Mock only | `POST /api/demo/requests/{requestID}/paid` |

### Real responses (captured from the running server, lists trimmed to one item)

`GET /api/me`
```json
{
 "user": {
  "id": "u_you",
  "name": "You",
  "paypal_email": "you@example.com"
 },
 "personal_balance_paise": 843000,
 "active_trip_id": "t_goa",
 "paypal_mode": "mock",
 "now": "2026-10-13T20:42:00+05:30"
}
```

`GET /api/trips/t_goa` (`GET /api/trips` returns a list of the same shape)
```json
{
 "id": "t_goa",
 "name": "Goa trip",
 "place": "Goa",
 "start": "2026-10-12T00:00:00+05:30",
 "end": "2026-10-16T00:00:00+05:30",
 "organiser_id": "u_you",
 "members": [
  "u_you",
  "u_asha",
  "u_dev",
  "u_meera"
 ],
 "deposit_target_paise": 600000,
 "budgets_paise": {
  "food": 500000,
  "other": 500000,
  "stay": 1000000,
  "transport": 400000
 },
 "status": "open",
 "created_at": "2026-10-05T10:00:00+05:30",
 "balance_paise": 1219200,
 "deposited_paise": 2100000,
 "spent_paise": 880800,
 "target_paise": 2400000,
 "day": 2,
 "days": 5,
 "member_details": [
  {
   "user": {
    "id": "u_you",
    "name": "You",
    "paypal_email": "you@example.com"
   },
   "deposited_paise": 300000,
   "used_paise": 220200,
   "left_paise": 79800
  }
 ]
}
```

`POST /api/suggestions` with `{"place_type":"restaurant"}` (optional `at`, `place_name`)
```json
{
 "title": "Dinner with your Goa trip group? Pay from the trip wallet and split 4 ways.",
 "category": "food",
 "wallet": "trip",
 "trip_id": "t_goa",
 "split_method": "equal",
 "participants": [
  "u_you",
  "u_asha",
  "u_dev",
  "u_meera"
 ],
 "reasons": [
  "8:42 pm, dinner time",
  "Restaurant nearby",
  "Goa trip is active"
 ]
}
```

`POST /api/trips/t_goa/expenses` request. Optional fields: `mode` (`paypal_payee` default, or `reimburse`), `split_method` (`equal` default, `shares`, `exact`), `participants` (`[{"user_id","weight","exact_paise"}]`, default everyone), `lat`, `lng`, `at`, `confirm_over_budget`.
```json
{
 "description": "Dinner",
 "category": "food",
 "amount_paise": 184000,
 "payee": "Beach shack, Baga",
 "payee_email": "shack@example.com",
 "place_name": "Baga",
 "place_type": "restaurant"
}
```

Answer to that request: **409 budget_warning**. Show the budget check screen, then resend with `"confirm_over_budget": true` to get a 201 with the expense (`id`, `shares`, `paypal_payout_id`, ...).
```json
{
 "error": {
  "code": "budget_warning",
  "message": "this payment takes the food budget to 85%. Send it again with confirm_over_budget to pay anyway",
  "details": {
   "category": "food",
   "limit_paise": 500000,
   "used_paise": 240800,
   "after_paise": 424800,
   "left_after_paise": 75200,
   "percent_before": 48,
   "percent_after": 85,
   "crosses_80": true,
   "over_100": false,
   "warn": true
  }
 }
}
```

`POST /api/trips/t_goa/budget-check` with `{"category","amount_paise"}` returns the same `details` object without paying.

`GET /api/trips/t_goa/budgets` (`PUT` takes `{"food":500000,...}` in paise)
```json
{
 "limit_paise": 2400000,
 "used_paise": 880800,
 "percent": 37,
 "day": 2,
 "days": 5,
 "lines": [
  {
   "category": "food",
   "limit_paise": 500000,
   "used_paise": 240800,
   "percent": 48,
   "ahead_of_pace": true
  }
 ]
}
```

`GET /api/trips/t_goa/insights`
```json
{
 "spent_paise": 880800,
 "per_person_paise": 220200,
 "left_paise": 1219200,
 "day": 2,
 "days": 5,
 "daily_pace_paise": 260400,
 "forecast_left_paise": 438000,
 "by_category": [
  {
   "key": "stay",
   "amount_paise": 360000,
   "percent": 41
  }
 ],
 "by_time_of_day": [
  {
   "key": "morning",
   "amount_paise": 120000,
   "percent": 14
  }
 ],
 "by_place": [
  {
   "key": "Anjuna",
   "amount_paise": 360000,
   "percent": 41
  }
 ],
 "by_person": [
  {
   "key": "Asha",
   "amount_paise": 220200,
   "percent": 25
  }
 ],
 "summary": "Day 2 of 5. The group has spent ₹8,808, which is ₹2,202 each. Stay is the biggest cost and the afternoon costs the most. At this pace about ₹4,380 is left at the end."
}
```

`POST /api/trips/t_goa/deposits` with `{"amount_paise":300000}`. Open `approve_url`, then call `POST /api/deposits/{paypal_order_id}/capture`.
```json
{
 "id": "dep_0023",
 "trip_id": "t_goa",
 "user_id": "u_you",
 "amount_paise": 300000,
 "paypal_order_id": "ORDER-MOCK-0001",
 "approve_url": "https://example.invalid/mock-paypal/approve/ORDER-MOCK-0001",
 "status": "created",
 "created_at": "2026-10-13T20:42:00+05:30"
}
```

`POST /api/trips/t_goa/assistant/plan` with `{"instruction":"Collect ₹6,000 from everyone by 10 Oct"}`. Channels: `in_app`, `paypal_request`, `already_paid`. Nothing is sent until `.../plans/{id}/confirm`.
```json
{
 "id": "plan_0022",
 "trip_id": "t_goa",
 "instruction": "Collect ₹6,000 from everyone by 10 Oct",
 "per_person_paise": 600000,
 "due": "2026-10-10T00:00:00+05:30",
 "items": [
  {
   "user_id": "u_you",
   "name": "You",
   "amount_paise": 300000,
   "channel": "in_app"
  },
  {
   "user_id": "u_asha",
   "name": "Asha",
   "amount_paise": 0,
   "channel": "already_paid"
  }
 ],
 "total_paise": 300000,
 "status": "draft"
}
```

`GET /api/trips/t_goa/requests`
```json
[
 {
  "id": "req_0006",
  "trip_id": "t_goa",
  "user_id": "u_asha",
  "amount_paise": 600000,
  "due": "2026-10-10T00:00:00+05:30",
  "paypal_invoice_id": "INV2-SEED-u_asha",
  "pay_url": "",
  "status": "paid",
  "reminders_sent": 0,
  "reminders": [],
  "paid_at": "2026-10-06T18:00:00+05:30"
 }
]
```

`GET /api/trips/t_goa/settlement` (`POST .../settle` is organiser only and closes the trip)
```json
{
 "trip_id": "t_goa",
 "status": "open",
 "deposited_paise": 2100000,
 "spent_paise": 880800,
 "refund_paise": 1219200,
 "lines": [
  {
   "user": {
    "id": "u_you",
    "name": "You",
    "paypal_email": "you@example.com"
   },
   "deposited_paise": 300000,
   "used_paise": 220200,
   "refund_paise": 79800
  }
 ]
}
```

`GET /api/history`
```json
[
 {
  "kind": "payment",
  "wallet": "trip",
  "trip_id": "t_goa",
  "trip_name": "Goa trip",
  "title": "Dinner, beach shack",
  "category": "food",
  "amount_paise": 192000,
  "your_part_paise": 48000,
  "place_name": "Baga",
  "at": "2026-10-12T21:10:00+05:30"
 }
]
```

`GET /api/alerts` (kinds: `budget`, `deposit`, `payment`, `share`, `assistant`)
```json
[
 {
  "id": "al_0021",
  "trip_id": "t_goa",
  "kind": "budget",
  "title": "Transport budget at 70%",
  "body": "₹1,200 left",
  "at": "2026-10-12T13:20:00+05:30"
 }
]
```

### Rules the backend enforces (do not weaken them)

- One double-entry ledger. Every entry balances. Balances are derived, never stored.
- A payment places a hold on each person's share, calls PayPal, then posts. On failure the hold is released and nothing is written.
- Capturing a deposit twice, or the same webhook twice, credits once.
- Settle-up refuses unless refunds equal exactly what PayPal holds for the trip.
- The assistant only drafts. Requests are sent only on confirm, only by the organiser. Reminders are capped at 2 per request per day (PayPal's own cap).

### Backend backlog (after the app works)

- In-memory state. Add Postgres behind the service.
- Sign-in is a header. Add OTP login and a token.
- Suggestions, insight summaries and the assistant's parser are rules and templates. An LLM can replace the summary text and the instruction parser, behind the same endpoints.
- The owner normally uses Gin, gRPC and clean architecture. The standard library router was used only to stay dependency-free; porting the thin handlers to Gin is fine if asked.

## 4. Design

Full designs (architecture, flows, data model, colours, 24 screens): https://claude.ai/artifact/DK85NR3i6M72mZYmKgWNVk

### Colours

| Token | Hex | Use |
|---|---|---|
| Pine 900 | `#0A3D30` | Pressed states, dark tags |
| Pine 700 | `#0F5A47` | Primary buttons, trip wallet card, active tab |
| Pine 500 | `#2E8268` | Charts, secondary icons |
| Pine 100 | `#DCEBE4` | Selected state, trip tags, icon tiles |
| Amber 500 | `#F2B33D` | AI accent, "Add" button on green |
| Amber 100 | `#FFF1CC` | Every AI suggestion card |
| Amber 900 | `#3D2A00` | Text on amber |
| Ink | `#10201B` | Main text, scan screen background |
| Slate | `#4D5C56` | Secondary text |
| Line strong / Line | `#BFC9C1` / `#D9E0DA` | Input borders / dividers |
| Mist | `#E3E9E4` | Tracks, segmented controls |
| Ground | `#F3F5F1` | App background |
| Surface | `#FFFFFF` | Cards |
| Personal | `#33478F` on `#E3E7F6` | Personal tag |
| Pending | `#8A4B00` on `#FFE8CC` | Pending tag, budget warning |
| Error | `#B3261E` on `#FBE4E1` | Failed |

Type: **Bricolage Grotesque** 700 for balances (40/48) and screen titles (28/32); **Instrument Sans** for everything else (15/20 body, 13/18 details, 12/16 tabs and tags). Use the `google_fonts` package.

### Three visual rules

1. **Green card with a dashed tear line** = a trip wallet. Nothing else uses it.
2. **Yellow card with a spark icon** = an AI suggestion. It never acts until tapped.
3. Every payment carries a **Trip** or **Personal** tag.

### Navigation

Bottom bar, five items: **Home, Trips, Scan (raised centre button), Insights, History.**

### Screens, by feature

**Home (your own money only)**
- Home: location and time, alerts bell, personal balance card, four actions (Scan to pay, Pay a contact, Pay by ID, Request money), one AI suggestion card with its reasons as tags, "Pay again" people row. No trip wallet and no recent list here. APIs: `/api/me`, `/api/suggestions`.
- Alerts (from the bell): list grouped by day, each row opens the screen that fixes it. API: `/api/alerts`.

**Pay someone, five steps with a labelled progress bar (Payee, Amount, Wallet, Split, Review)**
1. Payee: camera scan of an app or PayPal payee QR, or enter phone or ID. Shows the payee found.
2. Amount: "How much?", what it is for, AI-suggested category with a Change button.
3. Wallet: "Which wallet pays?", AI suggestion with the reason, two options (trip wallet, personal balance), and "How the payee gets the money": PayPal to the payee, or I paid, pay me back.
4. Split: Equally, By shares, Exact amounts; tick who shares; show each person's share left after this.
5. Review: every choice on one screen, wallet balance after, Pay button, biometric note.
- Budget check: shown only when the API answers `budget_warning`. Bar showing used so far plus this payment, three rows (used, this payment, left), buttons: Pay anyway, Raise the budget, Go back.
- Receipt: amount, payee, wallet, split, category, place, PayPal reference, wallet balance now.
- If the wallet is Personal, skip step 4 and call `/api/payments/personal`.

**Trips**
- Trips list: active trip as a green wallet card, finished trips, "Plan a new trip".
- Plan a trip: name, dates, place, people, deposit per person, pay-by date, optional food budget. `POST /api/trips`.
- Inside a trip, four tabs, each its own screen with the same header:
  - **Wallet**: balance card, your share, three actions with one-line explanations (Add money, Pay from this wallet, Settle up).
  - **Deposits**: collected progress, who has paid, a yellow card to open the assistant, the reminders it sent.
  - **Spending**: spent by the group, per person, every expense with "x each".
  - **Budget**: whole trip, a bar per category with an "Ahead of pace" tag, AI suggestion to move money between categories, alert switches.
- Add money: amount, quick chips, PayPal approve, then capture.
- Settle up: AI recap, totals, refund per person, "Send refunds".

**Trip assistant**
- Chat screen: the organiser types an instruction, the assistant shows a plan card marked "Waiting for your OK" with "Send N requests" and "Edit plan". Quick prompts below.
- Member view of a request: amount, due date, QR code, "Pay with PayPal".

**AI**
- Suggestions: everything proposed right now, each with reasons.
- What the AI may use: one switch per kind of data (location, time, past choices, assistant), plus "It never moves money on its own."
- Insights, Trip and Personal tabs: AI summary, spent / each / left, by category, by time of day, by place.

**History**: every payment, newest first, tagged Trip or Personal.

## 5. Flutter app plan

The owner is new to Flutter, so keep the code plain and readable: `StatefulWidget` plus `FutureBuilder`, one file per screen, short comments on anything non-obvious. No state-management framework unless asked.

```
pointy/lib/
  main.dart            app, theme, bottom navigation
  theme.dart           colours, text styles
  money.dart           paise -> "₹1,20,000" (Indian grouping), parse input to paise
  api.dart             one ApiClient class, base URL from --dart-define=API_BASE
  models.dart          plain classes with fromJson
  widgets/             wallet_card, ai_card, tag, stepper, section_title, tile_icon
  screens/home/        home, alerts
  screens/pay/         payee, amount, wallet, split, review, budget_check, receipt
  screens/trips/       trips, new_trip, trip_shell (4 tabs), wallet_tab, deposits_tab,
                       spending_tab, budget_tab, add_money, settle
  screens/assistant/   assistant, request_view
  screens/ai/          suggestions, ai_settings, insights
  screens/history/     history
```

Dependencies: `http`, `google_fonts`, `url_launcher` (open the PayPal approve link), `mobile_scanner` (QR), `geolocator` (coarse location, only at payment time, with consent), `uuid` (idempotency keys).

Base URL: Android emulator `http://10.0.2.2:8080`, iOS simulator and web `http://localhost:8080`.

Suggested commit order:
1. Theme, money formatting, API client, models, bottom navigation with empty screens.
2. Home and Alerts.
3. Trips list and the four trip tabs.
4. Pay flow, budget check, receipt.
5. Add money, Settle up, Plan a trip.
6. Assistant and request view.
7. Suggestions, AI settings, Insights, History.
8. Replace `test/widget_test.dart` (it still tests the counter template and fails) with a smoke test and money-formatting tests.

Run `flutter analyze` and `flutter test` before every push.

## 6. PayPal sandbox

`pointy-be/.env` (ignored by git):

```
PAYPAL_MODE=sandbox
PAYPAL_CLIENT_ID=...
PAYPAL_SECRET=...
PAYPAL_INVOICER_EMAIL=the sandbox business account email
```

```bash
go run ./cmd/paypalcheck                    # sign in, create a ₹100 order, print the approve link
go run ./cmd/paypalcheck -capture ORDER_ID  # after approving with a sandbox personal account
go run ./cmd/paypalcheck -payout  buyer@... # needs Payouts enabled on the sandbox app
go run ./cmd/paypalcheck -invoice buyer@... # needs Invoicing enabled on the sandbox app
```

Facts to keep in mind:
- PayPal does not pay UPI QR codes and has no shared-wallet API. The pool is one sandbox business account plus the ledger.
- The app shows rupees; the sandbox is charged in USD at `POINTY_INR_PER_UNIT` (default 85, a placeholder).
- Webhooks need a public URL (a tunnel). Without one, deposits are captured by the app calling `/capture`, and paid requests are not detected; use the mock-only `paid` endpoint in demos.
- Invoice QR codes can only be generated after the invoice is sent.

## 7. Do not

- Commit `.env`, the secret, or any credential.
- Use floats for money.
- Let the assistant send anything without an explicit confirm.
- Put two features on one screen.
