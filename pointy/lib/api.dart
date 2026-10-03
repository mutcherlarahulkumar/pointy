import 'dart:convert';

import 'package:flutter/foundation.dart';
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
  String toString() => message;
}

/// Picks the server address. Pass --dart-define=API_BASE=http://... to
/// override it; otherwise the Android emulator uses 10.0.2.2 (its name for
/// the computer running it) and everything else uses localhost.
String defaultBaseUrl() {
  const fromDefine = String.fromEnvironment('API_BASE');
  if (fromDefine.isNotEmpty) return fromDefine;
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) return 'http://10.0.2.2:8080';
  return 'http://localhost:8080';
}

/// Makes a fresh Idempotency-Key. Make one per payment attempt and reuse it
/// for retries of that same attempt, so a double tap cannot pay twice.
String newIdempotencyKey() => const Uuid().v4();

/// One class that knows every endpoint. Screens call these methods and get
/// model objects back.
class ApiClient {
  ApiClient({String? baseUrl, http.Client? client, this.userId = 'u_you'})
      : baseUrl = baseUrl ?? defaultBaseUrl(),
        _http = client ?? http.Client();

  final String baseUrl;
  final http.Client _http;

  /// Who is calling. The demo backend trusts this header.
  String userId;

  Future<dynamic> _send(String method, String path, {Object? body, String? idempotencyKey}) async {
    final headers = {
      'Content-Type': 'application/json',
      'X-User-Id': userId,
      if (idempotencyKey != null) 'Idempotency-Key': idempotencyKey,
    };
    final req = http.Request(method, Uri.parse('$baseUrl$path'))..headers.addAll(headers);
    if (body != null) req.body = jsonEncode(body);

    final http.Response res;
    try {
      res = await http.Response.fromStream(await _http.send(req));
    } catch (_) {
      throw ApiException(0, 'offline', 'Could not reach the Pointy server at $baseUrl');
    }
    final text = utf8.decode(res.bodyBytes);
    final decoded = text.isEmpty ? null : jsonDecode(text);
    if (res.statusCode >= 400) {
      final err = (decoded is Map ? decoded['error'] : null) as Map<String, dynamic>?;
      throw ApiException(
        res.statusCode,
        (err?['code'] as String?) ?? 'error',
        (err?['message'] as String?) ?? 'Something went wrong (${res.statusCode})',
        err?['details'] as Map<String, dynamic>?,
      );
    }
    return decoded;
  }

  Future<Map<String, dynamic>> _obj(String method, String path, {Object? body, String? key}) async =>
      (await _send(method, path, body: body, idempotencyKey: key)) as Map<String, dynamic>;

  Future<List<Map<String, dynamic>>> _arr(String path) async =>
      (((await _send('GET', path)) as List?) ?? const []).cast<Map<String, dynamic>>();

  // Home
  Future<Me> me() async => Me.fromJson(await _obj('GET', '/api/me'));

  Future<Suggestion> suggest({String placeType = '', String placeName = ''}) async => Suggestion.fromJson(
      await _obj('POST', '/api/suggestions', body: {'place_type': placeType, 'place_name': placeName}));

  Future<Expense> payPersonal(Map<String, dynamic> body, {required String key}) async =>
      Expense.fromJson(await _obj('POST', '/api/payments/personal', body: body, key: key));

  // History and alerts
  Future<List<HistoryItem>> history() async => (await _arr('/api/history')).map(HistoryItem.fromJson).toList();
  Future<List<AlertItem>> alerts() async => (await _arr('/api/alerts')).map(AlertItem.fromJson).toList();

  // Trips
  Future<List<Trip>> trips() async => (await _arr('/api/trips')).map(Trip.fromJson).toList();
  Future<Trip> trip(String id) async => Trip.fromJson(await _obj('GET', '/api/trips/$id'));
  Future<Trip> createTrip(Map<String, dynamic> body, {required String key}) async =>
      Trip.fromJson(await _obj('POST', '/api/trips', body: body, key: key));

  // Deposits
  Future<Deposit> startDeposit(String tripId, int amountPaise, {required String key}) async => Deposit.fromJson(
      await _obj('POST', '/api/trips/$tripId/deposits', body: {'amount_paise': amountPaise}, key: key));
  Future<Deposit> captureDeposit(String orderId, {required String key}) async =>
      Deposit.fromJson(await _obj('POST', '/api/deposits/$orderId/capture', key: key));

  // Pay and split
  Future<List<Expense>> expenses(String tripId) async =>
      (await _arr('/api/trips/$tripId/expenses')).map(Expense.fromJson).toList();
  Future<Expense> addExpense(String tripId, Map<String, dynamic> body, {required String key}) async =>
      Expense.fromJson(await _obj('POST', '/api/trips/$tripId/expenses', body: body, key: key));

  // Budgets
  Future<Budgets> budgets(String tripId) async => Budgets.fromJson(await _obj('GET', '/api/trips/$tripId/budgets'));
  Future<Budgets> setBudgets(String tripId, Map<String, int> paiseByCategory) async =>
      Budgets.fromJson(await _obj('PUT', '/api/trips/$tripId/budgets', body: paiseByCategory));
  Future<BudgetCheck> budgetCheck(String tripId, String category, int amountPaise) async =>
      BudgetCheck.fromJson(await _obj('POST', '/api/trips/$tripId/budget-check',
          body: {'category': category, 'amount_paise': amountPaise}));

  // Insights
  Future<Insights> insights(String tripId) async => Insights.fromJson(await _obj('GET', '/api/trips/$tripId/insights'));

  // Settle up
  Future<Settlement> settlement(String tripId) async =>
      Settlement.fromJson(await _obj('GET', '/api/trips/$tripId/settlement'));
  Future<Settlement> settle(String tripId, {required String key}) async =>
      Settlement.fromJson(await _obj('POST', '/api/trips/$tripId/settle', key: key));

  // Assistant
  Future<Plan> draftPlan(String tripId, String instruction) async => Plan.fromJson(
      await _obj('POST', '/api/trips/$tripId/assistant/plan', body: {'instruction': instruction}));
  Future<List<DepositRequest>> confirmPlan(String tripId, String planId, {required String key}) async =>
      (((await _send('POST', '/api/trips/$tripId/assistant/plans/$planId/confirm', idempotencyKey: key)) as List?) ??
              const [])
          .map((e) => DepositRequest.fromJson(e as Map<String, dynamic>))
          .toList();
  Future<List<DepositRequest>> requests(String tripId) async =>
      (await _arr('/api/trips/$tripId/requests')).map(DepositRequest.fromJson).toList();
  Future<DepositRequest> remind(String requestId, {required String key}) async =>
      DepositRequest.fromJson(await _obj('POST', '/api/requests/$requestId/remind', key: key));

  /// Mock mode only: pretends PayPal told us the request was paid.
  Future<DepositRequest> demoMarkPaid(String requestId) async =>
      DepositRequest.fromJson(await _obj('POST', '/api/demo/requests/$requestId/paid'));
}

/// The one client the app uses.
final api = ApiClient();
