# Pointy app

Flutter app for Pointy. It talks to the Go backend in `../pointy-be`.

## Run

```bash
# 1. Start the backend (mock PayPal, demo data, clock fixed at Tue 13 Oct 2026 8:42 pm)
cd ../pointy-be && go run ./cmd/server

# 2. Run the app
flutter pub get
flutter run                     # Android emulator uses http://10.0.2.2:8080
flutter run -d chrome           # web and iOS simulator use http://localhost:8080
flutter run --dart-define=API_BASE=http://192.168.1.20:8080   # a real phone on your Wi-Fi
```

## Check before pushing

```bash
flutter analyze
flutter test
```

## Layout

```
lib/
  main.dart     app, theme, bottom navigation
  theme.dart    colours and text styles
  money.dart    paise <-> "₹1,20,000"; no floats anywhere
  dates.dart    API times shown in IST
  api.dart      ApiClient, one method per endpoint
  models.dart   plain classes with fromJson
  widgets/      wallet card, AI card, tags, stepper, bars
  screens/      home, pay, trips, assistant, ai, history
test/
  fixtures/     responses captured from the demo backend
```
