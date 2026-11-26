import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_service.dart';

const privateStorage = FlutterSecureStorage(
  iOptions: IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
  ),
);

/// Supabase tokens are stored using the platform keystore/keychain, not prefs.
class SecureSessionStorage extends LocalStorage {
  static const key = 'siab.auth.session.v2';

  const SecureSessionStorage();

  @override
  Future<void> initialize() async {}

  @override
  Future<String?> accessToken() => privateStorage.read(key: key);

  @override
  Future<bool> hasAccessToken() async => await accessToken() != null;

  @override
  Future<void> persistSession(String persistSessionString) =>
      privateStorage.write(key: key, value: persistSessionString);

  @override
  Future<void> removePersistedSession() => privateStorage.delete(key: key);
}

/// Erase legacy plaintext data once; never turn a cached child into a session.
Future<void> eraseLegacyPrivatePreferences() async {
  final preferences = await SharedPreferences.getInstance();
  for (final key in preferences.getKeys()) {
    if (key.startsWith('wali_') ||
        key.startsWith('cache_today_att_') ||
        key.startsWith('cache_month_stats_') ||
        (key.startsWith('sb-') && key.contains('-auth-token')) ||
        key == 'SUPABASE_PERSIST_SESSION_KEY') {
      await preferences.remove(key);
    }
  }
}

/// A prefs-shaped, encrypted cache scoped to the signed-in account. Values
/// expire within 24 hours; authorization always comes from server membership.
class SecureUserPreferences {
  SecureUserPreferences._(this.owner, this._values);

  static const prefix = 'siab.wali.v2.';
  static const retention = Duration(hours: 24);
  static SecureUserPreferences? _loaded;
  static Future<void>? _writes;
  final String owner;
  final Map<String, dynamic> _values;

  static Future<SecureUserPreferences> getInstance() async {
    final session = supabaseService.currentSession;
    if (session == null || session.isExpired) {
      throw StateError(
        'An authenticated session is required for private cache.',
      );
    }
    final userId = session.user.id;
    if (_loaded?.owner == userId) return _loaded!;
    await _writes;
    final raw = await privateStorage.read(key: '$prefix$userId');
    final state = raw == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(raw) as Map);
    final cache = SecureUserPreferences._(userId, state);
    final now = DateTime.now();
    state.removeWhere((_, entry) {
      if (entry is! Map) return true;
      final saved = DateTime.tryParse(entry['saved_at']?.toString() ?? '');
      return saved == null ||
          now.difference(saved) > retention ||
          saved.isAfter(now);
    });
    if (supabaseService.currentUserId != userId) {
      throw StateError('Account changed while opening private cache.');
    }
    _loaded = cache;
    await cache._persist();
    return cache;
  }

  dynamic _get(String key) {
    if (!supabaseService.isAuthenticated ||
        supabaseService.currentUserId != owner) {
      return null;
    }
    final entry = _values[key];
    if (entry is! Map) return null;
    final saved = DateTime.tryParse(entry['saved_at']?.toString() ?? '');
    final now = DateTime.now();
    if (saved == null ||
        now.difference(saved) > retention ||
        saved.isAfter(now)) {
      return null;
    }
    return entry['value'];
  }

  String? getString(String key) => _get(key) as String?;
  int? getInt(String key) => _get(key) as int?;
  List<String>? getStringList(String key) {
    final value = _get(key);
    return value is List ? List<String>.from(value) : null;
  }

  Set<String> getKeys() => _values.keys.toSet();

  Future<bool> _set(String key, Object value) async {
    if (!supabaseService.isAuthenticated ||
        supabaseService.currentUserId != owner) {
      return false;
    }
    _values[key] = {
      'saved_at': DateTime.now().toUtc().toIso8601String(),
      'value': value,
    };
    await _persist();
    return true;
  }

  Future<bool> setString(String key, String value) => _set(key, value);
  Future<bool> setInt(String key, int value) => _set(key, value);
  Future<bool> setStringList(String key, List<String> value) =>
      _set(key, value);

  Future<bool> remove(String key) async {
    _values.remove(key);
    await _persist();
    return true;
  }

  Future<void> _persist() {
    final snapshot = jsonEncode(_values);
    final previous = _writes;
    final next = (previous?.catchError((_) {}) ?? Future<void>.value()).then((
      _,
    ) async {
      if (!supabaseService.isAuthenticated ||
          supabaseService.currentUserId != owner) {
        return;
      }
      await privateStorage.write(key: '$prefix$owner', value: snapshot);
    });
    _writes = next;
    return next;
  }

  static Future<void> clearPrivateCache() async {
    _loaded = null;
    final pending = _writes;
    await pending?.catchError((_) {});
    if (identical(_writes, pending)) _writes = null;
    final keys = (await privateStorage.readAll()).keys.toList();
    for (final key in keys.where((key) => key.startsWith(prefix))) {
      await privateStorage.delete(key: key);
    }
  }
}
