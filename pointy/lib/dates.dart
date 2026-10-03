// Date helpers. The backend writes times in IST ("+05:30"). Dart turns an
// offset time into UTC when parsing, so we shift it back to IST wall-clock
// time and show that, whatever the phone's time zone is.

const _ist = Duration(hours: 5, minutes: 30);
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// Parses an API timestamp into IST wall-clock time.
DateTime parseIst(String? s) {
  if (s == null || s.isEmpty) return DateTime(1970);
  final t = DateTime.parse(s).toUtc().add(_ist);
  return DateTime(t.year, t.month, t.day, t.hour, t.minute, t.second);
}

/// Writes a wall-clock IST date as the backend expects: "2026-10-20T00:00:00+05:30".
String toIsoIst(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}T${two(d.hour)}:${two(d.minute)}:00+05:30';
}

/// "8:42 pm"
String formatTime(DateTime d) {
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final m = d.minute.toString().padLeft(2, '0');
  return '$h:$m ${d.hour < 12 ? 'am' : 'pm'}';
}

/// "13 Oct"
String formatDay(DateTime d) => '${d.day} ${_months[d.month - 1]}';

/// "Tue 13 Oct"
String formatWeekday(DateTime d) => '${_days[d.weekday - 1]} ${formatDay(d)}';

/// "Tue 13 Oct, 8:42 pm"
String formatDateTime(DateTime d) => '${formatWeekday(d)}, ${formatTime(d)}';

bool sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;
