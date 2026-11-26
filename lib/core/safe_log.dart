import 'package:flutter/foundation.dart';

/// Log fixed event labels only. Never pass row values, tokens, payloads or errors.
abstract final class SafeLog {
  static void debug(String event) {
    if (kDebugMode) debugPrint('[SIAB] $event');
  }
}
