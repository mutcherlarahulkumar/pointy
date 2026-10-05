import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Approval codes for a child's payment (RFC 6238: HMAC-SHA1, 30 seconds,
/// 6 digits), worked out on the parent's phone from that child's key, so it
/// shows even offline. Each child has their own key and so their own code.
class Totp {
  Totp(String base32Secret) : _key = _base32(base32Secret);

  final List<int> _key;
  static const period = 30;

  /// The code for [at] (now by default).
  String code([DateTime? at]) {
    final step = (at ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000 ~/ period;
    // Two 32-bit halves: web browsers have no 64-bit setInt64.
    final msg = ByteData(8)
      ..setUint32(0, step ~/ 0x100000000)
      ..setUint32(4, step % 0x100000000);
    final h = Hmac(sha1, _key).convert(msg.buffer.asUint8List()).bytes;
    final off = h[h.length - 1] & 0x0f;
    final v = ((h[off] & 0x7f) << 24 | h[off + 1] << 16 | h[off + 2] << 8 | h[off + 3]) % 1000000;
    return v.toString().padLeft(6, '0');
  }

  /// Seconds before the code changes.
  static int secondsLeft([DateTime? at]) => period - ((at ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000) % period;

  static List<int> _base32(String s) {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    final out = <int>[];
    var buffer = 0, bits = 0;
    for (final ch in s.toUpperCase().replaceAll('=', '').split('')) {
      final v = alphabet.indexOf(ch);
      if (v < 0) continue;
      buffer = (buffer << 5) | v;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        out.add((buffer >> bits) & 0xff);
      }
    }
    return out;
  }
}
