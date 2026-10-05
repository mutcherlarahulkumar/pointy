# Pointy

Pay friends, request money, split bills and run shared trip wallets — an Android app (Flutter) and a Go backend on Render with Postgres. Pointy is a wallet: money comes in with PayPal checkout and goes out with **Withdraw** (PayPal Payouts, then on to your bank). Everything in between, friends and trips included, moves instantly inside Pointy's ledger.

| Folder | What |
|---|---|
| `pointy/` | Flutter app ([run and test](pointy/README.md)) |
| `pointy-be/` | Go backend ([API and PayPal setup](pointy-be/Readme.md)) |
| `.github/workflows/apk.yml` | Tests everything and publishes the APK on every push |
| `render.yaml` | Render blueprint: backend + Postgres |

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
| `CHANNEL3_API_KEY` | optional: lets Pointy AI find things to buy ("find sunscreen under 1500") through [Channel3](https://trychannel3.com) product search |
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
9. A: **Close the trip** → what is left goes back to both balances.
10. A: Profile → **Withdrawal account** → a sandbox personal email, then Home → **Withdraw**. The money goes to PayPal, and from there to the bank.

## Development

```bash
cd pointy-be && go test ./...
cd pointy && flutter analyze && flutter test
cd pointy && flutter run --dart-define=API_BASE=http://10.0.2.2:8080   # app against a local backend
```
