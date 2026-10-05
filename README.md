# Pointy

Pay friends, request money, split bills and run shared trip wallets — an Android app (Flutter) and a Go backend on Render with Postgres. Money comes in through PayPal checkout (sandbox); everything else moves instantly inside Pointy's ledger, which is what works in India.

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
| `GROQ_API_KEY` | optional: turns on AI trip summaries, the free-form deposit assistant and receipt scanning (Groq) |
| `POINTY_AI_MODEL` | optional, default `openai/gpt-oss-120b` |
| `POINTY_AI_VISION_MODEL` | optional, model that reads receipt photos, default `meta-llama/llama-4-scout-17b-16e-instruct` |

Build command `go build -o bin/server ./cmd/server`, start command `./bin/server`, root directory `pointy-be`, health check `/health`. `POINTY_SEED` and `POINTY_CLOCK` are no longer used.

The server applies pending database migrations when it starts, so nothing extra is needed on deploy. To inspect or roll back by hand, run `go run ./cmd/migrate status | up [n] | down [n]` from `pointy-be` with `DATABASE_URL` set (see `pointy-be/Readme.md`).

## Two-phone demo

1. Phone A and phone B install the APK and sign up with their numbers (name, then a 6-digit PIN).
2. A: **Add money** ₹2,000 → approve on PayPal with the sandbox personal account → back in the app it shows as added.
3. A: **Pay** → B's number → ₹150 → Pay. B's home updates within 10 seconds, with an alert.
4. B: **Request** → A → ₹300 "Movie". A sees it on Home → Pay.
5. A: **Split bill** → ₹1,200 dinner → add B → B gets a request for ₹600.
6. A: **Trips → Plan a trip** with B, ₹3,000 each → the assistant drafts → **Send 1 request**.
7. B: Trips → the trip → Deposits → **You owe ₹3,000** → pay from balance or PayPal.
8. B: **Add an expense** → ₹1,840 dinner, "I paid already" → split equally → budget warning → Pay anyway. B is paid back ₹1,840.
9. A: **Settle up** → what is left goes back to both balances. Check History on both phones.

## Development

```bash
cd pointy-be && go test ./...
cd pointy && flutter analyze && flutter test
cd pointy && flutter run --dart-define=API_BASE=http://10.0.2.2:8080   # app against a local backend
```
