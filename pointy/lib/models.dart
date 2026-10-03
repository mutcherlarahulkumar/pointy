// Plain classes for what the backend sends. Each has a fromJson factory.
// Money is always an int of paise; times are IST wall-clock (see dates.dart).

import 'dates.dart';

int _int(dynamic v) => (v as num?)?.toInt() ?? 0;
String _str(dynamic v) => (v as String?) ?? '';
List<T> _list<T>(dynamic v, T Function(Map<String, dynamic>) f) =>
    ((v as List?) ?? const []).map((e) => f(e as Map<String, dynamic>)).toList();

const categories = ['food', 'stay', 'transport', 'other'];

String categoryLabel(String c) => c.isEmpty ? 'Other' : '${c[0].toUpperCase()}${c.substring(1)}';

class User {
  final String id;
  final String name;
  final String paypalEmail;
  User({required this.id, required this.name, required this.paypalEmail});

  factory User.fromJson(Map<String, dynamic> j) =>
      User(id: _str(j['id']), name: _str(j['name']), paypalEmail: _str(j['paypal_email']));
}

class Me {
  final User user;
  final int personalBalancePaise;
  final String activeTripId;
  final String paypalMode;
  final DateTime now;
  Me({
    required this.user,
    required this.personalBalancePaise,
    required this.activeTripId,
    required this.paypalMode,
    required this.now,
  });

  bool get isMock => paypalMode == 'mock';

  factory Me.fromJson(Map<String, dynamic> j) => Me(
        user: User.fromJson(j['user'] as Map<String, dynamic>),
        personalBalancePaise: _int(j['personal_balance_paise']),
        activeTripId: _str(j['active_trip_id']),
        paypalMode: _str(j['paypal_mode']),
        now: parseIst(j['now'] as String?),
      );
}

class MemberDetail {
  final User user;
  final int depositedPaise;
  final int usedPaise;
  final int leftPaise;
  MemberDetail({required this.user, required this.depositedPaise, required this.usedPaise, required this.leftPaise});

  factory MemberDetail.fromJson(Map<String, dynamic> j) => MemberDetail(
        user: User.fromJson(j['user'] as Map<String, dynamic>),
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

  /// The member's details, or null if they are not on this trip.
  MemberDetail? member(String userId) {
    for (final m in memberDetails) {
      if (m.user.id == userId) return m;
    }
    return null;
  }

  String nameOf(String userId) => member(userId)?.user.name ?? userId;

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
  final String splitMethod;
  final List<String> participants;
  final List<String> reasons;
  Suggestion({
    required this.title,
    required this.category,
    required this.wallet,
    required this.tripId,
    required this.splitMethod,
    required this.participants,
    required this.reasons,
  });

  factory Suggestion.fromJson(Map<String, dynamic> j) => Suggestion(
        title: _str(j['title']),
        category: _str(j['category']),
        wallet: _str(j['wallet']),
        tripId: _str(j['trip_id']),
        splitMethod: _str(j['split_method']),
        participants: ((j['participants'] as List?) ?? const []).cast<String>(),
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
  final String mode;
  final String payee;
  final List<Share> shares;
  final String placeName;
  final DateTime at;
  final String paypalPayoutId;
  Expense({
    required this.id,
    required this.tripId,
    required this.paidBy,
    required this.description,
    required this.category,
    required this.amountPaise,
    required this.mode,
    required this.payee,
    required this.shares,
    required this.placeName,
    required this.at,
    required this.paypalPayoutId,
  });

  /// True when every person's part is the same (give or take a paisa).
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
        shares: _list(j['shares'], Share.fromJson),
        placeName: _str(j['place_name']),
        at: parseIst(j['at'] as String?),
        paypalPayoutId: _str(j['paypal_payout_id']),
      );
}

/// What a payment would do to one category's budget. Comes back from
/// budget-check and inside a budget_warning error.
class BudgetCheck {
  final String category;
  final int limitPaise;
  final int usedPaise;
  final int afterPaise;
  final int leftAfterPaise;
  final int percentBefore;
  final int percentAfter;
  final bool over100;
  final bool warn;
  BudgetCheck({
    required this.category,
    required this.limitPaise,
    required this.usedPaise,
    required this.afterPaise,
    required this.leftAfterPaise,
    required this.percentBefore,
    required this.percentAfter,
    required this.over100,
    required this.warn,
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
        warn: j['warn'] == true,
      );
}

class BudgetLine {
  final String category;
  final int limitPaise;
  final int usedPaise;
  final int percent;
  final bool aheadOfPace;
  BudgetLine({
    required this.category,
    required this.limitPaise,
    required this.usedPaise,
    required this.percent,
    required this.aheadOfPace,
  });

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
  Budgets({
    required this.limitPaise,
    required this.usedPaise,
    required this.percent,
    required this.day,
    required this.days,
    required this.lines,
  });

  factory Budgets.fromJson(Map<String, dynamic> j) => Budgets(
        limitPaise: _int(j['limit_paise']),
        usedPaise: _int(j['used_paise']),
        percent: _int(j['percent']),
        day: _int(j['day']),
        days: _int(j['days']),
        lines: _list(j['lines'], BudgetLine.fromJson),
      );
}

/// One row of a breakdown: a category, a time of day, a place or a person.
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
  final int dailyPacePaise;
  final int forecastLeftPaise;
  final List<Breakdown> byCategory;
  final List<Breakdown> byTimeOfDay;
  final List<Breakdown> byPlace;
  final List<Breakdown> byPerson;
  final String summary;
  Insights({
    required this.spentPaise,
    required this.perPersonPaise,
    required this.leftPaise,
    required this.day,
    required this.days,
    required this.dailyPacePaise,
    required this.forecastLeftPaise,
    required this.byCategory,
    required this.byTimeOfDay,
    required this.byPlace,
    required this.byPerson,
    required this.summary,
  });

  factory Insights.fromJson(Map<String, dynamic> j) => Insights(
        spentPaise: _int(j['spent_paise']),
        perPersonPaise: _int(j['per_person_paise']),
        leftPaise: _int(j['left_paise']),
        day: _int(j['day']),
        days: _int(j['days']),
        dailyPacePaise: _int(j['daily_pace_paise']),
        forecastLeftPaise: _int(j['forecast_left_paise']),
        byCategory: _list(j['by_category'], Breakdown.fromJson),
        byTimeOfDay: _list(j['by_time_of_day'], Breakdown.fromJson),
        byPlace: _list(j['by_place'], Breakdown.fromJson),
        byPerson: _list(j['by_person'], Breakdown.fromJson),
        summary: _str(j['summary']),
      );
}

class Deposit {
  final String id;
  final String tripId;
  final int amountPaise;
  final String paypalOrderId;
  final String approveUrl;
  final String status; // created, captured
  Deposit({
    required this.id,
    required this.tripId,
    required this.amountPaise,
    required this.paypalOrderId,
    required this.approveUrl,
    required this.status,
  });

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
  final String channel; // in_app, paypal_request, already_paid
  PlanItem({required this.userId, required this.name, required this.amountPaise, required this.channel});

  factory PlanItem.fromJson(Map<String, dynamic> j) => PlanItem(
        userId: _str(j['user_id']),
        name: _str(j['name']),
        amountPaise: _int(j['amount_paise']),
        channel: _str(j['channel']),
      );
}

class Plan {
  final String id;
  final String tripId;
  final String instruction;
  final int perPersonPaise;
  final DateTime due;
  final List<PlanItem> items;
  final int totalPaise;
  final String status; // draft, confirmed
  Plan({
    required this.id,
    required this.tripId,
    required this.instruction,
    required this.perPersonPaise,
    required this.due,
    required this.items,
    required this.totalPaise,
    required this.status,
  });

  /// How many PayPal requests confirming this plan would send.
  int get requestCount => items.where((i) => i.channel == 'paypal_request').length;

  factory Plan.fromJson(Map<String, dynamic> j) => Plan(
        id: _str(j['id']),
        tripId: _str(j['trip_id']),
        instruction: _str(j['instruction']),
        perPersonPaise: _int(j['per_person_paise']),
        due: parseIst(j['due'] as String?),
        items: _list(j['items'], PlanItem.fromJson),
        totalPaise: _int(j['total_paise']),
        status: _str(j['status']),
      );
}

class DepositRequest {
  final String id;
  final String tripId;
  final String userId;
  final int amountPaise;
  final DateTime due;
  final String paypalInvoiceId;
  final String payUrl;
  final String status; // sent, paid
  final int remindersSent;
  final List<DateTime> reminders;
  final DateTime? paidAt;
  DepositRequest({
    required this.id,
    required this.tripId,
    required this.userId,
    required this.amountPaise,
    required this.due,
    required this.paypalInvoiceId,
    required this.payUrl,
    required this.status,
    required this.remindersSent,
    required this.reminders,
    required this.paidAt,
  });

  bool get isPaid => status == 'paid';

  factory DepositRequest.fromJson(Map<String, dynamic> j) => DepositRequest(
        id: _str(j['id']),
        tripId: _str(j['trip_id']),
        userId: _str(j['user_id']),
        amountPaise: _int(j['amount_paise']),
        due: parseIst(j['due'] as String?),
        paypalInvoiceId: _str(j['paypal_invoice_id']),
        payUrl: _str(j['pay_url']),
        status: _str(j['status']),
        remindersSent: _int(j['reminders_sent']),
        reminders: ((j['reminders'] as List?) ?? const []).map((e) => parseIst(e as String)).toList(),
        paidAt: j['paid_at'] == null ? null : parseIst(j['paid_at'] as String),
      );
}

class SettleLine {
  final User user;
  final int depositedPaise;
  final int usedPaise;
  final int refundPaise;
  SettleLine({required this.user, required this.depositedPaise, required this.usedPaise, required this.refundPaise});

  factory SettleLine.fromJson(Map<String, dynamic> j) => SettleLine(
        user: User.fromJson(j['user'] as Map<String, dynamic>),
        depositedPaise: _int(j['deposited_paise']),
        usedPaise: _int(j['used_paise']),
        refundPaise: _int(j['refund_paise']),
      );
}

class Settlement {
  final String tripId;
  final String status;
  final int depositedPaise;
  final int spentPaise;
  final int refundPaise;
  final List<SettleLine> lines;
  final String paypalPayoutId;
  Settlement({
    required this.tripId,
    required this.status,
    required this.depositedPaise,
    required this.spentPaise,
    required this.refundPaise,
    required this.lines,
    required this.paypalPayoutId,
  });

  factory Settlement.fromJson(Map<String, dynamic> j) => Settlement(
        tripId: _str(j['trip_id']),
        status: _str(j['status']),
        depositedPaise: _int(j['deposited_paise']),
        spentPaise: _int(j['spent_paise']),
        refundPaise: _int(j['refund_paise']),
        lines: _list(j['lines'], SettleLine.fromJson),
        paypalPayoutId: _str(j['paypal_payout_id']),
      );
}

class HistoryItem {
  final String kind; // payment, deposit, refund
  final String wallet; // trip, personal
  final String tripId;
  final String tripName;
  final String title;
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
    required this.category,
    required this.amountPaise,
    required this.yourPartPaise,
    required this.placeName,
    required this.at,
  });

  bool get isTrip => wallet == 'trip';

  factory HistoryItem.fromJson(Map<String, dynamic> j) => HistoryItem(
        kind: _str(j['kind']),
        wallet: _str(j['wallet']),
        tripId: _str(j['trip_id']),
        tripName: _str(j['trip_name']),
        title: _str(j['title']),
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
  final String kind; // budget, deposit, payment, share, assistant
  final String title;
  final String body;
  final DateTime at;
  AlertItem({
    required this.id,
    required this.tripId,
    required this.kind,
    required this.title,
    required this.body,
    required this.at,
  });

  factory AlertItem.fromJson(Map<String, dynamic> j) => AlertItem(
        id: _str(j['id']),
        tripId: _str(j['trip_id']),
        kind: _str(j['kind']),
        title: _str(j['title']),
        body: _str(j['body']),
        at: parseIst(j['at'] as String?),
      );
}
