import 'package:flutter/foundation.dart';

/// Whether this phone's account is a child account. The app shows the
/// child version when it is; it is set whenever the account is read.
class FamilyMode {
  static final isChild = ValueNotifier<bool>(false);
}
