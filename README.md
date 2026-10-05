# Pointy

Pay friends, request money, split bills and run shared trip wallets — an Android app (Flutter) and a Go backend on Render with Postgres. Pointy is a wallet: money comes in with PayPal checkout and goes out with **Withdraw** (PayPal Payouts, then on to your bank). Everything in between, friends and trips included, moves instantly inside Pointy's ledger.

| Folder | What |
|---|---|
| `pointy/` | Flutter app ([run and test](pointy/README.md)) |
| `pointy-be/` | Go backend ([API and PayPal setup](pointy-be/Readme.md)) |
| `.github/workflows/apk.yml` | Tests everything and publishes the APK on every push |
| `.github/workflows/reset-db.yml` | Run by hand: empties the database (keeps the schema) and restarts the backend |
| `render.yaml` | Render blueprint: backend + Postgres |

## Buy together: a group shopping agent on PayPal

Group trips run on "someone pays, then chases everyone". In a Pointy trip, anyone tells the AI agent what the group needs ("a speaker for the beach under 2000"). The agent searches real shops through Channel3, and the AI (Groq) picks up to three products with a one-line reason each. A pick becomes a group purchase split equally over the trip, and it is **all or nothing**:

- Each person says yes with their **trip share** (held in Pointy's ledger) or with **PayPal**: an Orders v2 `AUTHORIZE` order, so the money is only *held* on their PayPal.
- When the last person says yes, Pointy captures every PayPal authorization and pays from the trip wallet in one ledger entry.
- One "no", or 48 hours without everyone, calls it off: every authorization is voided and every hold is let go. Nobody pays for something the group did not agree on.

Without any keys the backend uses simulated PayPal and a built-in demo catalogue, so judges can run the whole thing locally (see Development).

## Pointy Parenting

A parent looks after a child's Pointy wallet: daily and monthly limits, every payment visible, and anything over a limit approved by the parent, either on the parent's own phone (with their PIN) or, when they are together, with a one-time code from the parent's app. Each child has their own code key, so a parent with several children never mixes them up (RFC 6238 TOTP, 30 seconds, used once).

Built around Indian rules:

- **Consent from both phones (DPDP Act 2023, s.9(1)).** The parent accepts the terms and confirms with their PIN; the child types the pairing code from the parent's phone and their own PIN. Neither phone alone can turn an account into a child account, an adult's date of birth is refused, and at 18 the account graduates by itself. The consent record (terms version, times) is stored; unlinking withdraws it.
- **No tracking or profiling of children (s.9(3)).** No AI suggestions from time and place, no location kept with payments, no trips or shopping agent on child accounts.
- **Small-wallet limits (RBI PPI Master Direction).** At most ₹2,000 a payment, ₹10,000 received a month, ₹10,000 held. No PayPal top-up or withdrawal for children (PayPal is for adults); the parent sends pocket money.

The child's phone shows a separate, simpler app: pocket money, what is left today and this month, Pay, Scan, Ask a parent, and the latest payments.

## Get the APK

Every push builds the app. Download the latest:

- `main`: `https://github.com/mutcherlarahulkumar/pointy/releases/download/apk-main/pointy.apk`
- a branch: `.../releases/download/apk-<branch with / replaced by ->/pointy.apk`

The run's summary page also links it, and the APK is kept as a run artifact.

## Render setup

The backend service needs these environment variables:

| Variable | Value |
|---|---|
| `DATABASE_URL` | the **Internal Database URL** of a Render Postgres database |
| `PAYPAL_MODE` | `sandbox` (or leave unset to simulate PayPal) |
| `PAYPAL_CLIENT_ID`, `PAYPAL_SECRET` | from the PayPal sandbox REST app |
| `PAYPAL_CURRENCY` | `USD` |
| `POINTY_INR_PER_UNIT` | `85` (rupees per dollar used for conversion) |
| `PAYPAL_WEBHOOK_ID` | optional |

For withdrawals, turn on **Payouts** for the sandbox REST app and give the sandbox business account a balance.
| `GROQ_API_KEY` | optional: turns on AI trip summaries, the free-form deposit assistant, receipt scanning and the Pointy AI assistant (Groq) |
| `CHANNEL3_API_KEY` | optional: real shops for Buy together and Pointy AI ("find sunscreen under 1500") through [Channel3](https://trychannel3.com) product search; without it a small built-in demo catalogue answers |
| `POINTY_AI_MODEL` | optional, default `openai/gpt-oss-120b` |
| `POINTY_AI_VISION_MODEL` | optional, model that reads receipt photos, default `meta-llama/llama-4-scout-17b-16e-instruct` |

Build command `go build -o bin/server ./cmd/server`, start command `./bin/server`, root directory `pointy-be`, health check `/health`. `POINTY_SEED` and `POINTY_CLOCK` are no longer used.

The server applies pending database migrations when it starts, so nothing extra is needed on deploy. To inspect or roll back by hand, run `go run ./cmd/migrate status | up [n] | down [n]` from `pointy-be` with `DATABASE_URL` set (see `pointy-be/Readme.md`).

## Two-phone demo

1. Phone A and phone B install the APK and sign up with their numbers (name, then a 6-digit PIN).
2. A: **Add money** ₹2,000 → approve on PayPal with the sandbox personal account → back in the app it shows as added.
3. A: **Pay** → B's number → ₹150 → Pay → confirm with your Pointy PIN (Profile → Confirm payments switches to fingerprint). B's home updates within 10 seconds, with an alert.
4. B: tap the glowing **Ask AI** button → "ask Rahul for 300 for the movie" (any name from B's people) → **Ask Rahul for ₹300** → Ask. Try "what did I spend this week?", "who owes me?" and "find sunscreen for our Goa trip under 1500" too (shopping needs `CHANNEL3_API_KEY`). Or B: **Request** → A → ₹300 "Movie". A sees it on Home → Pay.
5. A: **Split bill** → ₹1,200 dinner → add B → B gets a request for ₹600.
6. A: **Trips → Plan a trip** with B, ₹3,000 each → the assistant drafts → **Send 1 request**.
7. B: Trips → the trip → Money in → **You owe ₹3,000** → pay from your balance (add money first if it is short).
8. B: trip **Overview → Pay from the trip** → ₹1,840 dinner → **Pay someone on Pointy** → A's number → split equally → budget warning → Pay anyway. A's balance goes up by ₹1,840 at once. (Or "I paid already" and the wallet pays B back.)
9. A: trip **Overview → Buy together** → "A beach speaker" → **Propose to the group** → **Yes from my trip share**. B: the trip shows "Waiting for the group" → open it → **Yes, hold it on my PayPal** → approve on PayPal. As soon as both are in, it is bought (the PayPal hold is captured) and lands in Spent. Try it again and have B say **No thanks**: nothing is charged and A's hold is released.
10. A: **Close the trip** → what is left goes back to both balances.
11. Parenting: B (the child) and A (the parent) on two phones. A: Profile → **Family** → **Add a child** → accept the terms → B's number and a date of birth under 18 → limits → PIN. A's phone shows a 6-digit code. B: the Home banner (or Profile → Family) → **See what changes** → type the code → own PIN. Both phones celebrate, and B's phone switches to the child app. A: **Pocket money** ₹500. B: pay A ₹250 → over the daily limit → **Ask on their phone**; A approves with the PIN. Or A opens **Approval code** and B types it.
12. A: Profile → **Withdrawal account** → a sandbox personal email, then Home → **Withdraw**. The money goes to PayPal, and from there to the bank.

## Development

Run everything locally with no accounts or keys (simulated PayPal, demo shop):

```bash
cd pointy-be && go run ./cmd/server                                   # http://localhost:8080
cd pointy && flutter run -d chrome --dart-define=API_BASE=http://localhost:8080
```

Tests:

```bash
cd pointy-be && go test ./...
cd pointy && flutter analyze && flutter test
cd pointy && flutter run --dart-define=API_BASE=http://10.0.2.2:8080   # app against a local backend
```
