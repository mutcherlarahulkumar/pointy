import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'models.dart';

/// An error answer from the backend: {"error":{"code","message","details"}}.
class ApiException implements Exception {
  final int status;
  final String code;
  final String message;
  final Map<String, dynamic>? details;
  ApiException(this.status, this.code, this.message, [this.details]);

  @override
  String toString() => message.isEmpty ? message : '${message[0].toUpperCase()}${message.substring(1)}';
}

/// The deployed backend. Builds can point elsewhere with
/// --dart-define=API_BASE=https://... (CI sets it from a repository variable).
const defaultApiBase = 'https://pointy-ceoi.onrender.com';

String defaultBaseUrl() {
  const fromDefine = String.fromEnvironment('API_BASE');
  return fromDefine.isNotEmpty ? fromDefine : defaultApiBase;
}

/// Makes a fresh Idempotency-Key. Make one per payment attempt and reuse it
/// for retries of that same attempt, so a double tap cannot pay twice.
String newIdempotencyKey() => const Uuid().v4();

/// One class that knows every endpoint. Screens call these methods and get
/// model objects back.
class ApiClient {
  ApiClient({String? baseUrl, http.Client? client})
      : baseUrl = baseUrl ?? defaultBaseUrl(),
        _http = client ?? http.Client();

  final String baseUrl;
  final http.Client _http;

  /// The signed-in session, or null. Set by Session.
  String? token;

  /// The signed-in person's id, filled in after sign-in.
  String userId = '';

  /// Called when the server says the session is no longer valid.
  void Function()? onSignedOut;

  Future<dynamic> _send(String method, String path, {Object? body, String? idempotencyKey}) async {
    final headers = {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
      if (idempotencyKey != null) 'Idempotency-Key': idempotencyKey,
    };
    final req = http.Request(method, Uri.parse('$baseUrl$path'))..headers.addAll(headers);
    if (body != null) req.body = jsonEncode(body);

    final http.Response res;
    try {
      // The free Render plan sleeps when idle and takes up to a minute to wake.
      res = await http.Response.fromStream(await _http.send(req).timeout(const Duration(seconds: 75)));
    } catch (_) {
      throw ApiException(0, 'offline', 'Could not reach Pointy. Check your internet and try again.');
    }
    final text = utf8.decode(res.bodyBytes);
    dynamic decoded;
    try {
      decoded = text.isEmpty ? null : jsonDecode(text);
    } catch (_) {
      decoded = null; // an HTML error page from a proxy
    }
    if (res.statusCode >= 400) {
      final err = (decoded is Map ? decoded['error'] : null) as Map<String, dynamic>?;
      final e = ApiException(
        res.statusCode,
        (err?['code'] as String?) ?? 'error',
        (err?['message'] as String?) ?? 'Something went wrong (${res.statusCode}). Please try again.',
        err?['details'] as Map<String, dynamic>?,
      );
      if (e.code == 'signed_out') onSignedOut?.call();
      throw e;
    }
    return decoded;
  }

  Future<Map<String, dynamic>> _obj(String method, String path, {Object? body, String? key}) async =>
      ((await _send(method, path, body: body, idempotencyKey: key)) as Map<String, dynamic>?) ?? {};

  Future<List<Map<String, dynamic>>> _arr(String method, String path, {Object? body, String? key}) async =>
      (((await _send(method, path, body: body, idempotencyKey: key)) as List?) ?? const []).cast<Map<String, dynamic>>();

  // Sign in
  Future<PhoneCheck> checkPhone(String phone) async =>
      PhoneCheck.fromJson(await _obj('POST', '/api/auth/check-phone', body: {'phone': phone}));
  Future<AuthResult> register(String name, String phone, String pin) async =>
      AuthResult.fromJson(await _obj('POST', '/api/auth/register', body: {'name': name, 'phone': phone, 'pin': pin}));
  Future<AuthResult> login(String phone, String pin) async =>
      AuthResult.fromJson(await _obj('POST', '/api/auth/login', body: {'phone': phone, 'pin': pin}));
  Future<void> logout() async => _send('POST', '/api/auth/logout');
  /// Checks the signed-in person's PIN before a payment (phones with no screen lock).
  Future<void> verifyPin(String pin) async => _send('POST', '/api/auth/verify-pin', body: {'pin': pin});

  // You and people
  Future<Me> me() async => Me.fromJson(await _obj('GET', '/api/me'));
  Future<List<Person>> contacts() async => (await _arr('GET', '/api/contacts')).map(Person.fromJson).toList();
  Future<Person> lookupPhone(String phone) async =>
      Person.fromJson(await _obj('GET', '/api/users/lookup?phone=${Uri.encodeQueryComponent(phone)}'));
  Future<Person> person(String id) async => Person.fromJson(await _obj('GET', '/api/users/${Uri.encodeComponent(id)}'));

  // Your balance
  Future<Deposit> startTopUp(int amountPaise, {required String key}) async =>
      Deposit.fromJson(await _obj('POST', '/api/topups', body: {'amount_paise': amountPaise}, key: key));
  Future<Deposit> deposit(String orderId) async => Deposit.fromJson(await _obj('GET', '/api/deposits/$orderId'));
  Future<Deposit> captureDeposit(String orderId, {required String key}) async =>
      Deposit.fromJson(await _obj('POST', '/api/deposits/$orderId/capture', key: key));
  Future<Suggestion> suggest({String placeType = ''}) async =>
      Suggestion.fromJson(await _obj('POST', '/api/suggestions', body: {'place_type': placeType}));
  Future<Expense> payPerson(Map<String, dynamic> body, {required String key}) async =>
      Expense.fromJson(await _obj('POST', '/api/payments/personal', body: body, key: key));

  // Requests between people
  Future<List<MoneyRequest>> moneyRequests() async => (await _arr('GET', '/api/money-requests')).map(MoneyRequest.fromJson).toList();
  Future<MoneyRequest> requestMoney(String payerId, int amountPaise, String note, {required String key}) async =>
      MoneyRequest.fromJson(await _obj('POST', '/api/money-requests',
          body: {'payer_id': payerId, 'amount_paise': amountPaise, 'note': note}, key: key));
  Future<MoneyRequest> payMoneyRequest(String id, {required String key}) async =>
      MoneyRequest.fromJson(await _obj('POST', '/api/money-requests/$id/pay', key: key));
  Future<MoneyRequest> declineMoneyRequest(String id) async =>
      MoneyRequest.fromJson(await _obj('POST', '/api/money-requests/$id/decline'));
  Future<List<MoneyRequest>> splitBill(Map<String, dynamic> body, {required String key}) async =>
      ((await _obj('POST', '/api/splits', body: body, key: key))['requests'] as List? ?? const [])
          .map((e) => MoneyRequest.fromJson(e as Map<String, dynamic>))
          .toList();

  // History and alerts
  Future<List<HistoryItem>> history() async => (await _arr('GET', '/api/history')).map(HistoryItem.fromJson).toList();
  Future<List<AlertItem>> alerts() async => (await _arr('GET', '/api/alerts')).map(AlertItem.fromJson).toList();
  Future<void> markAlertsSeen() async => _send('POST', '/api/alerts/seen');

  /// Reads a photo of a bill (JPEG or PNG bytes) into expense fields.
  Future<ScannedReceipt> scanReceipt(List<int> imageBytes) async =>
      ScannedReceipt.fromJson(await _obj('POST', '/api/receipts/scan', body: {'image_base64': base64Encode(imageBytes)}));

  // Trips
  Future<List<Trip>> trips() async => (await _arr('GET', '/api/trips')).map(Trip.fromJson).toList();
  Future<Trip> trip(String id) async => Trip.fromJson(await _obj('GET', '/api/trips/$id'));
  Future<Trip> createTrip(Map<String, dynamic> body, {required String key}) async =>
      Trip.fromJson(await _obj('POST', '/api/trips', body: body, key: key));
  Future<Trip> addMembers(String tripId, List<String> ids) async =>
      Trip.fromJson(await _obj('POST', '/api/trips/$tripId/members', body: {'members': ids}));
  Future<Deposit> startTripDeposit(String tripId, int amountPaise, {required String key}) async => Deposit.fromJson(
      await _obj('POST', '/api/trips/$tripId/deposits', body: {'amount_paise': amountPaise, 'source': 'paypal'}, key: key));
  Future<Trip> depositFromBalance(String tripId, int amountPaise, {required String key}) async => Trip.fromJson(
      await _obj('POST', '/api/trips/$tripId/deposits', body: {'amount_paise': amountPaise, 'source': 'balance'}, key: key));
  Future<List<Expense>> expenses(String tripId) async =>
      (await _arr('GET', '/api/trips/$tripId/expenses')).map(Expense.fromJson).toList();
  Future<Expense> addExpense(String tripId, Map<String, dynamic> body, {required String key}) async =>
      Expense.fromJson(await _obj('POST', '/api/trips/$tripId/expenses', body: body, key: key));
  Future<Budgets> budgets(String tripId) async => Budgets.fromJson(await _obj('GET', '/api/trips/$tripId/budgets'));
  Future<Budgets> setBudgets(String tripId, Map<String, int> paiseByCategory) async =>
      Budgets.fromJson(await _obj('PUT', '/api/trips/$tripId/budgets', body: paiseByCategory));
  Future<Insights> insights(String tripId) async => Insights.fromJson(await _obj('GET', '/api/trips/$tripId/insights'));
  Future<Settlement> settlement(String tripId) async => Settlement.fromJson(await _obj('GET', '/api/trips/$tripId/settlement'));
  Future<Settlement> settle(String tripId, {required String key}) async =>
      Settlement.fromJson(await _obj('POST', '/api/trips/$tripId/settle', key: key));

  // Assistant and deposit requests
  Future<Plan> draftPlan(String tripId, String instruction) async =>
      Plan.fromJson(await _obj('POST', '/api/trips/$tripId/assistant/plan', body: {'instruction': instruction}));
  Future<int> confirmPlan(String tripId, String planId, {required String key}) async =>
      (await _arr('POST', '/api/trips/$tripId/assistant/plans/$planId/confirm', key: key)).length;
  Future<List<DepositRequest>> requests(String tripId) async =>
      (await _arr('GET', '/api/trips/$tripId/requests')).map(DepositRequest.fromJson).toList();
  Future<DepositRequest> remind(String requestId, {required String key}) async =>
      DepositRequest.fromJson(await _obj('POST', '/api/requests/$requestId/remind', key: key));
  Future<DepositRequest> payDepositRequest(String requestId, {required String key}) async =>
      DepositRequest.fromJson(await _obj('POST', '/api/requests/$requestId/pay', key: key));
}

/// The one client the app uses. Tests replace it with one that has a fake
/// http.Client.
ApiClient api = ApiClient();
