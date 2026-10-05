// Plain classes for what the backend sends. Each has a fromJson factory.
// Money is always an int of paise; times are IST wall-clock (see dates.dart).

import 'dates.dart';

int _int(dynamic v) => (v as num?)?.toInt() ?? 0;
String _str(dynamic v) => (v as String?) ?? '';
List<T> _list<T>(dynamic v, T Function(Map<String, dynamic>) f) =>
    ((v as List?) ?? const []).map((e) => f(e as Map<String, dynamic>)).toList();
Map<String, dynamic> _map(dynamic v) => (v as Map<String, dynamic>?) ?? const {};

const categories = ['food', 'stay', 'transport', 'other'];

String categoryLabel(String c) => c.isEmpty ? 'Other' : '${c[0].toUpperCase()}${c.substring(1)}';

/// First name, for greetings: "Asha Rao" -> "Asha".
String firstName(String name) => name.trim().split(RegExp(r'\s+')).first;

/// Up to two initials for an avatar.
String initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  return parts.take(2).map((p) => p[0].toUpperCase()).join();
}

/// "98765 43210"
String formatPhone(String p) => p.length == 10 ? '${p.substring(0, 5)} ${p.substring(5)}' : p;

/// Someone on Pointy, as other people see them.
class Person {
  final String id;
  final String name;
  final String phone;
  Person({required this.id, required this.name, required this.phone});

  factory Person.fromJson(Map<String, dynamic> j) => Person(id: _str(j['id']), name: _str(j['name']), phone: _str(j['phone']));

  @override
  bool operator ==(Object other) => other is Person && other.id == id;
  @override
  int get hashCode => id.hashCode;
}

class AuthResult {
  final String token;
  final Person user;
  AuthResult(this.token, this.user);

  factory AuthResult.fromJson(Map<String, dynamic> j) => AuthResult(_str(j['token']), Person.fromJson(_map(j['user'])));
}

class PhoneCheck {
  final String phone;
  final bool exists;
  final String firstName;
  PhoneCheck(this.phone, this.exists, this.firstName);

  factory PhoneCheck.fromJson(Map<String, dynamic> j) =>
      PhoneCheck(_str(j['phone']), j['exists'] == true, _str(j['first_name']));
}

class Me {
  final Person user;
  final int personalBalancePaise;
  final String activeTripId;
  final int unreadAlerts;
  final int openRequests;
  final String paypalMode;
  final DateTime now;
  Me({
    required this.user,
    required this.personalBalancePaise,
    required this.activeTripId,
    required this.unreadAlerts,
    required this.openRequests,
    required this.paypalMode,
    required this.now,
  });

  bool get isMock => paypalMode == 'mock';

  factory Me.fromJson(Map<String, dynamic> j) => Me(
        user: Person.fromJson(_map(j['user'])),
        personalBalancePaise: _int(j['personal_balance_paise']),
        activeTripId: _str(j['active_trip_id']),
        unreadAlerts: _int(j['unread_alerts']),
        openRequests: _int(j['open_requests']),
        paypalMode: _str(j['paypal_mode']),
        now: parseIst(j['now'] as String?),
      );
}

class MemberDetail {
  final Person user;
  final int depositedPaise;
  final int usedPaise;
  final int leftPaise;
  MemberDetail({required this.user, required this.depositedPaise, required this.usedPaise, required this.leftPaise});

  factory MemberDetail.fromJson(Map<String, dynamic> j) => MemberDetail(
        user: Person.fromJson(_map(j['user'])),
        depositedPaise: _int(j['deposited_paise']),
        usedPaise: _int(j['used_paise']),
        leftPaise: _int(j['left_paise']),
      );
}

class Trip {
  final String id;
  final String name;
  final String place;
  final DateTime start;
  final DateTime end;
  final String organiserId;
  final List<String> members;
  final int depositTargetPaise;
  final Map<String, int> budgetsPaise;
  final String status;
  final int balancePaise;
  final int depositedPaise;
  final int spentPaise;
  final int targetPaise;
  final int day;
  final int days;
  final List<MemberDetail> memberDetails;

  Trip({
    required this.id,
    required this.name,
    required this.place,
    required this.start,
    required this.end,
    required this.organiserId,
    required this.members,
    required this.depositTargetPaise,
    required this.budgetsPaise,
    required this.status,
    required this.balancePaise,
    required this.depositedPaise,
    required this.spentPaise,
    required this.targetPaise,
    required this.day,
    required this.days,
    required this.memberDetails,
  });

  bool get isOpen => status == 'open';

  /// "Day 2 of 5", "Starts 20 Oct" or "12 – 16 Oct".
  String get when {
    if (day > 0 && day <= days && isOpen) return 'Day $day of $days';
    if (day == 0) return 'Starts ${formatDay(start)}';
    return '${formatDay(start)} – ${formatDay(end)}';
  }

  MemberDetail? member(String userId) {
    for (final m in memberDetails) {
      if (m.user.id == userId) return m;
    }
    return null;
  }

  String nameOf(String userId) => member(userId)?.user.name ?? 'Someone';

  factory Trip.fromJson(Map<String, dynamic> j) => Trip(
        id: _str(j['id']),
        name: _str(j['name']),
        place: _str(j['place']),
        start: parseIst(j['start'] as String?),
        end: parseIst(j['end'] as String?),
        organiserId: _str(j['organiser_id']),
        members: ((j['members'] as List?) ?? const []).cast<String>(),
        depositTargetPaise: _int(j['deposit_target_paise']),
        budgetsPaise: ((j['budgets_paise'] as Map?) ?? const {}).map((k, v) => MapEntry(k as String, _int(v))),
        status: _str(j['status']),
        balancePaise: _int(j['balance_paise']),
        depositedPaise: _int(j['deposited_paise']),
        spentPaise: _int(j['spent_paise']),
        targetPaise: _int(j['target_paise']),
        day: _int(j['day']),
        days: _int(j['days']),
        memberDetails: _list(j['member_details'], MemberDetail.fromJson),
      );
}

class Suggestion {
  final String title;
  final String category;
  final String wallet; // trip or personal
  final String tripId;
  final List<String> reasons;
  Suggestion({required this.title, required this.category, required this.wallet, required this.tripId, required this.reasons});

  factory Suggestion.fromJson(Map<String, dynamic> j) => Suggestion(
        title: _str(j['title']),
        category: _str(j['category']),
        wallet: _str(j['wallet']),
        tripId: _str(j['trip_id']),
        reasons: ((j['reasons'] as List?) ?? const []).cast<String>(),
      );
}

class Share {
  final String userId;
  final int amountPaise;
  Share({required this.userId, required this.amountPaise});

  factory Share.fromJson(Map<String, dynamic> j) => Share(userId: _str(j['user_id']), amountPaise: _int(j['amount_paise']));
}

class Expense {
  final String id;
  final String tripId;
  final String paidBy;
  final String description;
  final String category;
  final int amountPaise;
  final String mode; // member, reimburse, transfer
  final String payee;
  final String payeeUserId;
  final List<Share> shares;
  final String placeName;
  final DateTime at;
  Expense({
    required this.id,
    required this.tripId,
    required this.paidBy,
    required this.description,
    required this.category,
    required this.amountPaise,
    required this.mode,
    required this.payee,
    required this.payeeUserId,
    required this.shares,
    required this.placeName,
    required this.at,
  });

  bool get isEvenSplit {
    if (shares.isEmpty) return true;
    final amounts = shares.map((s) => s.amountPaise);
    final lo = amounts.reduce((a, b) => a < b ? a : b);
    final hi = amounts.reduce((a, b) => a > b ? a : b);
    return hi - lo <= 1;
  }

  factory Expense.fromJson(Map<String, dynamic> j) => Expense(
        id: _str(j['id']),
        tripId: _str(j['trip_id']),
        paidBy: _str(j['paid_by']),
        description: _str(j['description']),
        category: _str(j['category']),
        amountPaise: _int(j['amount_paise']),
        mode: _str(j['mode']),
        payee: _str(j['payee']),
        payeeUserId: _str(j['payee_user_id']),
        shares: _list(j['shares'], Share.fromJson),
        placeName: _str(j['place_name']),
        at: parseIst(j['at'] as String?),
      );
}

class BudgetCheck {
  final String category;
  final int limitPaise;
  final int usedPaise;
  final int afterPaise;
  final int leftAfterPaise;
  final int percentBefore;
  final int percentAfter;
  final bool over100;
  BudgetCheck({
    required this.category,
    required this.limitPaise,
    required this.usedPaise,
    required this.afterPaise,
    required this.leftAfterPaise,
    required this.percentBefore,
    required this.percentAfter,
    required this.over100,
  });

  int get thisPaymentPaise => afterPaise - usedPaise;

  factory BudgetCheck.fromJson(Map<String, dynamic> j) => BudgetCheck(
        category: _str(j['category']),
        limitPaise: _int(j['limit_paise']),
        usedPaise: _int(j['used_paise']),
        afterPaise: _int(j['after_paise']),
        leftAfterPaise: _int(j['left_after_paise']),
        percentBefore: _int(j['percent_before']),
        percentAfter: _int(j['percent_after']),
        over100: j['over_100'] == true,
      );
}

class BudgetLine {
  final String category;
  final int limitPaise;
  final int usedPaise;
  final int percent;
  final bool aheadOfPace;
  BudgetLine({required this.category, required this.limitPaise, required this.usedPaise, required this.percent, required this.aheadOfPace});

  factory BudgetLine.fromJson(Map<String, dynamic> j) => BudgetLine(
        category: _str(j['category']),
        limitPaise: _int(j['limit_paise']),
        usedPaise: _int(j['used_paise']),
        percent: _int(j['percent']),
        aheadOfPace: j['ahead_of_pace'] == true,
      );
}

class Budgets {
  final int limitPaise;
  final int usedPaise;
  final int percent;
  final int day;
  final int days;
  final List<BudgetLine> lines;
  Budgets({required this.limitPaise, required this.usedPaise, required this.percent, required this.day, required this.days, required this.lines});

  factory Budgets.fromJson(Map<String, dynamic> j) => Budgets(
        limitPaise: _int(j['limit_paise']),
        usedPaise: _int(j['used_paise']),
        percent: _int(j['percent']),
        day: _int(j['day']),
        days: _int(j['days']),
        lines: _list(j['lines'], BudgetLine.fromJson),
      );
}

class Breakdown {
  final String key;
  final int amountPaise;
  final int percent;
  Breakdown({required this.key, required this.amountPaise, required this.percent});

  factory Breakdown.fromJson(Map<String, dynamic> j) =>
      Breakdown(key: _str(j['key']), amountPaise: _int(j['amount_paise']), percent: _int(j['percent']));
}

class Insights {
  final int spentPaise;
  final int perPersonPaise;
  final int leftPaise;
  final int day;
  final int days;
  final List<Breakdown> byCategory;
  final List<Breakdown> byTimeOfDay;
  final List<Breakdown> byPlace;
  final List<Breakdown> byPerson;
  final String summary;
  final String tip;

  /// "ai" when a language model wrote the summary, "rules" for the template.
  final String summarySource;
  Insights({
    required this.spentPaise,
    required this.perPersonPaise,
    required this.leftPaise,
    required this.day,
    required this.days,
    required this.byCategory,
    required this.byTimeOfDay,
    required this.byPlace,
    required this.byPerson,
    required this.summary,
    this.tip = '',
    this.summarySource = 'rules',
  });

  factory Insights.fromJson(Map<String, dynamic> j) => Insights(
        spentPaise: _int(j['spent_paise']),
        perPersonPaise: _int(j['per_person_paise']),
        leftPaise: _int(j['left_paise']),
        day: _int(j['day']),
        days: _int(j['days']),
        byCategory: _list(j['by_category'], Breakdown.fromJson),
        byTimeOfDay: _list(j['by_time_of_day'], Breakdown.fromJson),
        byPlace: _list(j['by_place'], Breakdown.fromJson),
        byPerson: _list(j['by_person'], Breakdown.fromJson),
        summary: _str(j['summary']),
        tip: _str(j['tip']),
        summarySource: _str(j['summary_source']),
      );
}

/// A PayPal checkout: adding money to your balance (no trip) or to a trip.
class Deposit {
  final String id;
  final String tripId;
  final int amountPaise;
  final String paypalOrderId;
  final String approveUrl;
  final String status; // created, capturing, captured
  Deposit({required this.id, required this.tripId, required this.amountPaise, required this.paypalOrderId, required this.approveUrl, required this.status});

  bool get isCaptured => status == 'captured';

  factory Deposit.fromJson(Map<String, dynamic> j) => Deposit(
        id: _str(j['id']),
        tripId: _str(j['trip_id']),
        amountPaise: _int(j['amount_paise']),
        paypalOrderId: _str(j['paypal_order_id']),
        approveUrl: _str(j['approve_url']),
        status: _str(j['status']),
      );
}

class PlanItem {
  final String userId;
  final String name;
  final int amountPaise;
  final String channel; // request, organiser, already_paid
  PlanItem({required this.userId, required this.name, required this.amountPaise, required this.channel});

  factory PlanItem.fromJson(Map<String, dynamic> j) =>
      PlanItem(userId: _str(j['user_id']), name: _str(j['name']), amountPaise: _int(j['amount_paise']), channel: _str(j['channel']));
}

class Plan {
  final String id;
  final String instruction;
  final int perPersonPaise;
  final DateTime due;
  final List<PlanItem> items;
  final int totalPaise;
  final String status;

  /// The assistant's one-line reply, and who read the instruction ("ai" or "rules").
  final String note;
  final String source;
  Plan({
    required this.id,
    required this.instruction,
    required this.perPersonPaise,
    required this.due,
    required this.items,
    required this.totalPaise,
    required this.status,
    this.note = '',
    this.source = 'rules',
  });

  int get requestCount => items.where((i) => i.channel == 'request').length;

  Plan withStatus(String s) => Plan(
      id: id, instruction: instruction, perPersonPaise: perPersonPaise, due: due, items: items, totalPaise: totalPaise, status: s, note: note, source: source);

  factory Plan.fromJson(Map<String, dynamic> j) => Plan(
        id: _str(j['id']),
        instruction: _str(j['instruction']),
        perPersonPaise: _int(j['per_person_paise']),
        due: parseIst(j['due'] as String?),
        items: _list(j['items'], PlanItem.fromJson),
        totalPaise: _int(j['total_paise']),
        status: _str(j['status']),
        note: _str(j['note']),
        source: _str(j['source']),
      );
}

/// A trip deposit the organiser asked a member for.
class DepositRequest {
  final String id;
  final String tripId;
  final String tripName;
  final Person user;
  final int amountPaise;
  final DateTime due;
  final String status; // open, paid, cancelled
  final int remindersSent;
  final DateTime? paidAt;
  final String paidVia;
  DepositRequest({
    required this.id,
    required this.tripId,
    required this.tripName,
    required this.user,
    required this.amountPaise,
    required this.due,
    required this.status,
    required this.remindersSent,
    required this.paidAt,
    required this.paidVia,
  });

  bool get isOpen => status == 'open';

  factory DepositRequest.fromJson(Map<String, dynamic> j) => DepositRequest(
        id: _str(j['id']),
        tripId: _str(j['trip_id']),
        tripName: _str(j['trip_name']),
        user: Person.fromJson(_map(j['user'])),
        amountPaise: _int(j['amount_paise']),
        due: parseIst(j['due'] as String?),
        status: _str(j['status']),
        remindersSent: _int(j['reminders_sent']),
        paidAt: j['paid_at'] == null ? null : parseIst(j['paid_at'] as String),
        paidVia: _str(j['paid_via']),
      );
}

/// One person asking another for money.
class MoneyRequest {
  final String id;
  final Person requester;
  final Person payer;
  final int amountPaise;
  final String note;
  final String status; // open, paid, declined, cancelled
  final String direction; // incoming (you pay) or outgoing
  final DateTime createdAt;
  MoneyRequest({
    required this.id,
    required this.requester,
    required this.payer,
    required this.amountPaise,
    required this.note,
    required this.status,
    required this.direction,
    required this.createdAt,
  });

  bool get isOpen => status == 'open';
  bool get isIncoming => direction == 'incoming';
  Person get other => isIncoming ? requester : payer;

  factory MoneyRequest.fromJson(Map<String, dynamic> j) => MoneyRequest(
        id: _str(j['id']),
        requester: Person.fromJson(_map(j['requester'])),
        payer: Person.fromJson(_map(j['payer'])),
        amountPaise: _int(j['amount_paise']),
        note: _str(j['note']),
        status: _str(j['status']),
        direction: _str(j['direction']),
        createdAt: parseIst(j['created_at'] as String?),
      );
}

class SettleLine {
  final Person user;
  final int depositedPaise;
  final int usedPaise;
  final int refundPaise;
  SettleLine({required this.user, required this.depositedPaise, required this.usedPaise, required this.refundPaise});

  factory SettleLine.fromJson(Map<String, dynamic> j) => SettleLine(
        user: Person.fromJson(_map(j['user'])),
        depositedPaise: _int(j['deposited_paise']),
        usedPaise: _int(j['used_paise']),
        refundPaise: _int(j['refund_paise']),
      );
}

class Settlement {
  final String status;
  final int depositedPaise;
  final int spentPaise;
  final int refundPaise;
  final List<SettleLine> lines;
  Settlement({required this.status, required this.depositedPaise, required this.spentPaise, required this.refundPaise, required this.lines});

  factory Settlement.fromJson(Map<String, dynamic> j) => Settlement(
        status: _str(j['status']),
        depositedPaise: _int(j['deposited_paise']),
        spentPaise: _int(j['spent_paise']),
        refundPaise: _int(j['refund_paise']),
        lines: _list(j['lines'], SettleLine.fromJson),
      );
}

class HistoryItem {
  final String kind; // payment, received, deposit, topup, refund
  final String wallet; // trip, personal
  final String tripId;
  final String tripName;
  final String title;
  final String subtitle;
  final String category;
  final int amountPaise;
  final int yourPartPaise;
  final String placeName;
  final DateTime at;
  HistoryItem({
    required this.kind,
    required this.wallet,
    required this.tripId,
    required this.tripName,
    required this.title,
    required this.subtitle,
    required this.category,
    required this.amountPaise,
    required this.yourPartPaise,
    required this.placeName,
    required this.at,
  });

  bool get isTrip => wallet == 'trip';

  /// Money that came into your balance.
  bool get isIncoming => kind == 'received' || kind == 'topup' || kind == 'refund';

  factory HistoryItem.fromJson(Map<String, dynamic> j) => HistoryItem(
        kind: _str(j['kind']),
        wallet: _str(j['wallet']),
        tripId: _str(j['trip_id']),
        tripName: _str(j['trip_name']),
        title: _str(j['title']),
        subtitle: _str(j['subtitle']),
        category: _str(j['category']),
        amountPaise: _int(j['amount_paise']),
        yourPartPaise: _int(j['your_part_paise']),
        placeName: _str(j['place_name']),
        at: parseIst(j['at'] as String?),
      );
}

class AlertItem {
  final String id;
  final String tripId;
  final String kind; // budget, deposit, payment, share, assistant, trip, money, request
  final String title;
  final String body;
  final DateTime at;
  AlertItem({required this.id, required this.tripId, required this.kind, required this.title, required this.body, required this.at});

  factory AlertItem.fromJson(Map<String, dynamic> j) => AlertItem(
        id: _str(j['id']),
        tripId: _str(j['trip_id']),
        kind: _str(j['kind']),
        title: _str(j['title']),
        body: _str(j['body']),
        at: parseIst(j['at'] as String?),
      );
}

/// A receipt photo read into the fields of an expense. Nothing is saved
/// until the person pays.
class ScannedReceipt {
  final int amountPaise;
  final String merchant;
  final String category;
  final String description;
  final String date;
  ScannedReceipt({required this.amountPaise, required this.merchant, required this.category, required this.description, required this.date});

  factory ScannedReceipt.fromJson(Map<String, dynamic> j) => ScannedReceipt(
        amountPaise: _int(j['amount_paise']),
        merchant: _str(j['merchant']),
        category: _str(j['category']),
        description: _str(j['description']),
        date: _str(j['date']),
      );
}

/// A button under a Pointy AI reply. It only opens a screen, filled in; the
/// person still checks and confirms there.
class ChatAction {
  final String type; // pay, request, open
  final String label;
  final Person? person;
  final int amountPaise;
  final String note;
  final String screen; // add_money, requests, trips, history, insights, split, trip
  final String tripId;
  final String query; // shop: what was searched
  final List<ShopItem> items; // shop: the products found
  ChatAction(
      {required this.type,
      required this.label,
      this.person,
      this.amountPaise = 0,
      this.note = '',
      this.screen = '',
      this.tripId = '',
      this.query = '',
      this.items = const []});

  factory ChatAction.fromJson(Map<String, dynamic> j) => ChatAction(
        type: _str(j['type']),
        label: _str(j['label']),
        person: j['person'] == null ? null : Person.fromJson(j['person'] as Map<String, dynamic>),
        amountPaise: _int(j['amount_paise']),
        note: _str(j['note']),
        screen: _str(j['screen']),
        tripId: _str(j['trip_id']),
        query: _str(j['query']),
        items: _list(j['items'], ShopItem.fromJson),
      );
}

/// A product Pointy AI found in online shops (through Channel3). Pointy
/// never buys it: the person opens the shop, then can split it or add it
/// to a trip.
class ShopItem {
  final String id;
  final String title;
  final String brand;
  final String imageUrl;
  final String merchant; // "amazon.com"
  final String buyUrl;
  final int pricePaise; // converted to rupees
  final int wasPricePaise;
  final String listPrice; // as the shop shows it: "$19.99"
  ShopItem(
      {required this.id,
      required this.title,
      this.brand = '',
      this.imageUrl = '',
      required this.merchant,
      required this.buyUrl,
      required this.pricePaise,
      this.wasPricePaise = 0,
      this.listPrice = ''});

  factory ShopItem.fromJson(Map<String, dynamic> j) => ShopItem(
        id: _str(j['id']),
        title: _str(j['title']),
        brand: _str(j['brand']),
        imageUrl: _str(j['image_url']),
        merchant: _str(j['merchant']),
        buyUrl: _str(j['buy_url']),
        pricePaise: _int(j['price_paise']),
        wasPricePaise: _int(j['was_price_paise']),
        listPrice: _str(j['list_price']),
      );
}

/// One line of the conversation with Pointy AI, saved on the server.
class ChatMessage {
  final String id;
  final String role; // user or assistant
  final String text;
  final ChatAction? action;
  final String source; // ai or rules, on assistant lines
  final String at;
  ChatMessage({required this.id, required this.role, required this.text, this.action, this.source = '', this.at = ''});

  bool get mine => role == 'user';

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        id: _str(j['id']),
        role: _str(j['role']),
        text: _str(j['text']),
        action: j['action'] == null ? null : ChatAction.fromJson(j['action'] as Map<String, dynamic>),
        source: _str(j['source']),
        at: _str(j['at']),
      );
}
