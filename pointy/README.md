# Pointy app

Flutter app for Pointy. It talks to the Go backend in `../pointy-be`, deployed at `https://pointy-ceoi.onrender.com` by default.

## Run

```bash
flutter pub get
flutter run                                              # uses the Render backend
flutter run --dart-define=API_BASE=http://10.0.2.2:8080  # Android emulator, local backend
flutter run -d chrome --dart-define=API_BASE=http://localhost:8080
```

The APK for phones is built by CI on every push; see the root README for the download link.

## Check before pushing

```bash
flutter analyze
flutter test
```

## Layout

```
lib/
  main.dart      app root (welcome or main app), bottom navigation
  session.dart   sign-in token kept on the phone; 401 signs out
  api.dart       ApiClient, one method per endpoint
  models.dart    plain classes with fromJson
  theme.dart     colours and text styles
  money.dart     paise <-> "₹1,20,000"; no floats anywhere
  dates.dart     API times shown in IST
  widgets/       cards, PIN pad, person picker, flow scaffold, success screen
  screens/
    auth/        welcome, phone, name, create PIN, PIN sign-in
    home/        home, alerts
    money/       pay, request, split a bill, add money, requests, my QR
    pay/         scan a Pointy QR
    trips/       trips, plan a trip, trip tabs, add an expense, add people, settle up
    assistant/   deposit assistant, member's request view
    ai/          insights, suggestions, what the AI may use
    history/     history
    profile/     profile, how Pointy works in India
test/
  fixtures/      responses captured from the backend
```
