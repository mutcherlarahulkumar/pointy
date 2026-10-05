import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'family_mode.dart';
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
  Future<Me> me() async {
    final m = Me.fromJson(await _obj('GET', '/api/me'));
    FamilyMode.isChild.value = m.isChild; // the app switches between the adult and child versions
    return m;
  }
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

  // Pointy AI: the conversation is saved on the server.
  Future<List<ChatMessage>> chatHistory() async =>
      (await _arr('GET', '/api/assistant/messages')).map(ChatMessage.fromJson).toList();
  /// Sends one message; returns it and the reply.
  Future<List<ChatMessage>> chat(String text) async =>
      (await _arr('POST', '/api/assistant/messages', body: {'text': text})).map(ChatMessage.fromJson).toList();
  Future<void> clearChat() async => _send('DELETE', '/api/assistant/messages');

  // Withdraw: money out to your PayPal (and on to your bank)
  Future<Me> setPayPalEmail(String email) async => Me.fromJson(await _obj('PUT', '/api/me/paypal', body: {'email': email}));
  Future<Payout> withdraw(int amountPaise, {required String key}) async =>
      Payout.fromJson(await _obj('POST', '/api/withdrawals', body: {'amount_paise': amountPaise}, key: key));

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
  /// Splits a bill by who had what. [items] are {name, amount_paise, people}.
  Future<List<ItemSplitPart>> splitByItems(String description, List<Map<String, dynamic>> items, int extraPaise, {required String key}) async {
    final r = await _obj('POST', '/api/splits/items', body: {'description': description, 'items': items, 'extra_paise': extraPaise}, key: key);
    return [for (final p in (r['parts'] as List? ?? const [])) ItemSplitPart.fromJson(p as Map<String, dynamic>)];
  }

  Future<ScannedReceipt> scanReceipt(List<int> imageBytes) async =>
      ScannedReceipt.fromJson(await _obj('POST', '/api/receipts/scan', body: {'image_base64': base64Encode(imageBytes)}));

  // Trips
  Future<List<Trip>> trips() async => (await _arr('GET', '/api/trips')).map(Trip.fromJson).toList();
  Future<Trip> trip(String id) async => Trip.fromJson(await _obj('GET', '/api/trips/$id'));
  Future<Trip> createTrip(Map<String, dynamic> body, {required String key}) async =>
      Trip.fromJson(await _obj('POST', '/api/trips', body: body, key: key));
  Future<Trip> addMembers(String tripId, List<String> ids) async =>
      Trip.fromJson(await _obj('POST', '/api/trips/$tripId/members', body: {'members': ids}));
  Future<Trip> depositFromBalance(String tripId, int amountPaise, {required String key}) async => Trip.fromJson(
      await _obj('POST', '/api/trips/$tripId/deposits', body: {'amount_paise': amountPaise}, key: key));
  // Pointy Parenting
  Future<FamilyView> family() async => FamilyView.fromJson(await _obj('GET', '/api/family'));
  Future<FamilyInvite> inviteChild(Map<String, dynamic> body) async => FamilyInvite.fromJson(await _obj('POST', '/api/family/invites', body: body));
  Future<ChildView> acceptFamilyInvite(String linkId, String code, String pin) async =>
      ChildView.fromJson(await _obj('POST', '/api/family/invites/$linkId/accept', body: {'code': code, 'pin': pin}));
  Future<void> declineFamilyInvite(String linkId) async => _send('POST', '/api/family/invites/$linkId/decline');
  Future<ChildView> setChildLimits(String childId, int dailyPaise, int monthlyPaise, String pin) async => ChildView.fromJson(await _obj(
      'PUT', '/api/family/children/$childId/limits', body: {'daily_limit_paise': dailyPaise, 'monthly_limit_paise': monthlyPaise, 'pin': pin}));
  Future<void> unlinkChild(String childId, String pin) async => _send('POST', '/api/family/children/$childId/unlink', body: {'pin': pin});
  Future<List<HistoryItem>> childActivity(String childId) async =>
      (await _arr('GET', '/api/family/children/$childId/activity')).map(HistoryItem.fromJson).toList();
  Future<String> childCodeKey(String childId, String pin) async =>
      ((await _obj('POST', '/api/family/children/$childId/code-key', body: {'pin': pin}))['secret'] as String?) ?? '';
  Future<Approval> askApproval(String payeeId, int amountPaise, String note) async =>
      Approval.fromJson(await _obj('POST', '/api/family/approvals', body: {'payee_id': payeeId, 'amount_paise': amountPaise, 'note': note}));
  Future<Approval> decideApproval(String id, {required bool approve, String pin = ''}) async =>
      Approval.fromJson(await _obj('POST', '/api/family/approvals/$id/${approve ? 'approve' : 'decline'}', body: {'pin': pin}));

  // The trip's shopping agent and group purchases
  Future<AgentAnswer> shopAgent(String tripId, String text) async =>
      AgentAnswer.fromJson(await _obj('POST', '/api/trips/$tripId/shop-agent', body: {'text': text}));
  Future<GroupBuy> proposeGroupBuy(String tripId, String searchId, AgentPick pick, {required String key}) async => GroupBuy.fromJson(
      await _obj('POST', '/api/trips/$tripId/group-buys', body: {'search_id': searchId, 'index': pick.index, 'why': pick.why}, key: key));
  Future<List<GroupBuy>> groupBuys(String tripId) async => (await _arr('GET', '/api/trips/$tripId/group-buys')).map(GroupBuy.fromJson).toList();
  Future<GroupBuy> groupBuy(String id) async => GroupBuy.fromJson(await _obj('GET', '/api/group-buys/$id'));
  Future<GroupBuy> joinGroupBuy(String id, String via, {required String key}) async =>
      GroupBuy.fromJson(await _obj('POST', '/api/group-buys/$id/join', body: {'via': via}, key: key));
  Future<GroupBuy> declineGroupBuy(String id) async => GroupBuy.fromJson(await _obj('POST', '/api/group-buys/$id/decline'));
  Future<GroupBuy> authorizeGroupBuy(String orderId) async =>
      GroupBuy.fromJson(await _obj('POST', '/api/group-buys/paypal/${Uri.encodeComponent(orderId)}/authorize'));
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
