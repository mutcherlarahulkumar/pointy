// Money helpers. The backend sends every amount as whole paise (an int).
// We never turn money into a double: formatting and parsing work on the
// digits directly.

/// Formats paise as rupees with Indian digit grouping.
///
/// 12000000 -> "₹1,20,000", 184050 -> "₹1,840.50", -50000 -> "-₹500".
/// Paise are shown only when there are some, unless [alwaysPaise] is set.
String formatPaise(int paise, {bool alwaysPaise = false}) {
  final negative = paise < 0;
  final abs = paise.abs();
  final rupees = abs ~/ 100;
  final rest = abs % 100;
  var text = '₹${groupIndian(rupees)}';
  if (rest != 0 || alwaysPaise) {
    text += '.${rest.toString().padLeft(2, '0')}';
  }
  return negative ? '-$text' : text;
}

/// Groups a whole number the Indian way: the last three digits, then pairs.
/// 1234567 -> "12,34,567".
String groupIndian(int n) {
  final digits = n.abs().toString();
  if (digits.length <= 3) return n < 0 ? '-$digits' : digits;
  final last3 = digits.substring(digits.length - 3);
  var head = digits.substring(0, digits.length - 3);
  final parts = <String>[];
  while (head.length > 2) {
    parts.insert(0, head.substring(head.length - 2));
    head = head.substring(0, head.length - 2);
  }
  if (head.isNotEmpty) parts.insert(0, head);
  final out = '${parts.join(',')},$last3';
  return n < 0 ? '-$out' : out;
}

/// Reads what someone typed ("1,840", "₹ 1840.5", "1840.50") as paise.
/// Returns null when the text is not a valid positive amount with at most
/// two decimal places.
int? parseToPaise(String input) {
  final cleaned = input.replaceAll(RegExp(r'[₹,\s]'), '');
  final match = RegExp(r'^(\d+)(?:\.(\d{0,2}))?$').firstMatch(cleaned);
  if (match == null) return null;
  final rupees = int.parse(match.group(1)!);
  final fraction = (match.group(2) ?? '').padRight(2, '0');
  final paise = rupees * 100 + int.parse(fraction);
  return paise > 0 ? paise : null;
}

/// Shows paise as plain rupees for an input field: 184050 -> "1840.50".
String paiseToInput(int paise) {
  final rest = paise % 100;
  return rest == 0 ? '${paise ~/ 100}' : '${paise ~/ 100}.${rest.toString().padLeft(2, '0')}';
}

/// Splits [total] the same way the backend does: integer division by
/// weight, then any leftover paise go one at a time to the first people.
List<int> splitPaise(int total, List<int> weights) {
  if (weights.isEmpty) return [];
  final sum = weights.fold<int>(0, (a, b) => a + b);
  if (sum <= 0) return List.filled(weights.length, 0);
  final out = [for (final w in weights) total * w ~/ sum];
  var given = out.fold<int>(0, (a, b) => a + b);
  for (var i = 0; given < total; i = (i + 1) % out.length) {
    out[i]++;
    given++;
  }
  return out;
}
