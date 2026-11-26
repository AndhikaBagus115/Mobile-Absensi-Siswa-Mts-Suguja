import '../../core/safe_log.dart';
import 'dart:convert';
import 'secure_storage_service.dart';
import 'supabase_service.dart';

import '../models/wali_murid_models.dart';
import 'onesignal_service.dart';

/// Local Storage Service to manage linked child profiles for parents
class WaliStorageService {
  static final WaliStorageService _instance = WaliStorageService._internal();
  factory WaliStorageService() => _instance;
  WaliStorageService._internal();

  static const String _keyChildren = 'wali_saved_children';
  static const String _keyActiveChildId = 'wali_active_child_id';

  /// Replace a cache only after the server has returned the owned children.
  Future<void> replaceSavedChildren(List<ChildProfile> children) async {
    final prefs = await SecureUserPreferences.getInstance();
    final ids = children.map((child) => child.id).toSet();
    for (final key in prefs.getKeys()) {
      final match = RegExp(
        r'^cache_(?:today_att|month_stats)_([0-9]+)',
      ).firstMatch(key);
      if (match != null && !ids.contains(int.tryParse(match.group(1)!))) {
        await prefs.remove(key);
      }
    }
    await prefs.setStringList(
      _keyChildren,
      children.map((child) => jsonEncode(child.toJson())).toList(),
    );
    if (children.isNotEmpty && !ids.contains(prefs.getInt(_keyActiveChildId))) {
      await prefs.setInt(_keyActiveChildId, children.first.id);
    }
  }

  /// Get all saved linked children
  Future<List<ChildProfile>> getSavedChildren() async {
    try {
      final prefs = await SecureUserPreferences.getInstance();
      final rawList = prefs.getStringList(_keyChildren);
      if (rawList == null || rawList.isEmpty) return [];

      return rawList.map((item) {
        final map = jsonDecode(item) as Map<String, dynamic>;
        return ChildProfile.fromJson(map);
      }).toList();
    } catch (e) {
      SafeLog.debug(
        'wali_storage_service.walistorage_error_getting_saved_children',
      );
      return [];
    }
  }

  /// Save or update a child profile, and set as active if desired
  Future<void> saveChild(ChildProfile child, {bool makeActive = true}) async {
    try {
      final prefs = await SecureUserPreferences.getInstance();
      final currentList = await getSavedChildren();

      // Check if child is already in the list, update it or append
      final existingIndex = currentList.indexWhere((c) => c.id == child.id);
      if (existingIndex >= 0) {
        currentList[existingIndex] = child;
      } else {
        currentList.add(child);
      }

      // Save back to SharedPreferences
      final encodedList = currentList
          .map((c) => jsonEncode(c.toJson()))
          .toList();
      await prefs.setStringList(_keyChildren, encodedList);

      if (makeActive || currentList.length == 1) {
        await prefs.setInt(_keyActiveChildId, child.id);
      }

      // Synchronize OneSignal Tags for all children
      await syncOneSignalTags(currentList);
      SafeLog.debug('wali_storage_service.walistorage_berhasil_menyimpan_anak');
    } catch (e) {
      SafeLog.debug('wali_storage_service.walistorage_error_saving_child');
    }
  }

  /// Get the currently selected active child
  Future<ChildProfile?> getActiveChild() async {
    try {
      final children = await getSavedChildren();
      if (children.isEmpty) return null;

      final prefs = await SecureUserPreferences.getInstance();
      final activeId = prefs.getInt(_keyActiveChildId);

      if (activeId != null) {
        final match = children.firstWhere(
          (c) => c.id == activeId,
          orElse: () => children.first,
        );
        return match;
      }

      return children.first;
    } catch (e) {
      SafeLog.debug(
        'wali_storage_service.walistorage_error_getting_active_child',
      );
      return null;
    }
  }

  /// Set the active child by ID
  Future<void> setActiveChildId(int childId) async {
    try {
      final prefs = await SecureUserPreferences.getInstance();
      await prefs.setInt(_keyActiveChildId, childId);
      SafeLog.debug(
        'wali_storage_service.walistorage_active_child_id_diset_ke',
      );
    } catch (e) {
      SafeLog.debug(
        'wali_storage_service.walistorage_error_setting_active_child_id',
      );
    }
  }

  /// Remove a linked child
  Future<void> removeChild(int childId) async {
    try {
      final prefs = await SecureUserPreferences.getInstance();
      final currentList = await getSavedChildren();
      currentList.removeWhere((c) => c.id == childId);

      final encodedList = currentList
          .map((c) => jsonEncode(c.toJson()))
          .toList();
      await prefs.setStringList(_keyChildren, encodedList);

      final activeId = prefs.getInt(_keyActiveChildId);
      if (activeId == childId) {
        if (currentList.isNotEmpty) {
          await prefs.setInt(_keyActiveChildId, currentList.first.id);
        } else {
          await prefs.remove(_keyActiveChildId);
        }
      }

      // Re-sync OneSignal Tags
      await syncOneSignalTags(currentList);
      SafeLog.debug('wali_storage_service.walistorage_anak_id');
    } catch (e) {
      SafeLog.debug('wali_storage_service.walistorage_error_removing_child');
    }
  }

  /// Clear encrypted private data and disconnect the push identity.
  Future<void> clearAll() async {
    await SecureUserPreferences.clearPrivateCache();
    await eraseLegacyPrivatePreferences();
    await OneSignalService.logoutUser();
  }

  static const String _keyReadNotifications = 'wali_read_notification_ids';
  static const String _keyInAppNotifications = 'wali_in_app_notifications';

  /// Save an incoming in-app notification (e.g. from OneSignal push)
  Future<void> saveInAppNotification(WaliNotificationItem item) async {
    try {
      final prefs = await SecureUserPreferences.getInstance();
      final currentList = await getLocalInAppNotifications();
      final existingIndex = currentList.indexWhere((n) => n.id == item.id);
      if (existingIndex >= 0) {
        currentList[existingIndex] = item;
      } else {
        currentList.insert(0, item);
      }
      if (currentList.length > 50) {
        currentList.removeRange(50, currentList.length);
      }
      final encoded = currentList.map((n) => jsonEncode(n.toJson())).toList();
      await prefs.setStringList(_keyInAppNotifications, encoded);
      SafeLog.debug(
        'wali_storage_service.walistorage_in_app_notifikasi_disimpan',
      );
    } catch (e) {
      SafeLog.debug(
        'wali_storage_service.walistorage_error_saving_in_app_notification',
      );
    }
  }

  /// Get local in-app notifications
  Future<List<WaliNotificationItem>> getLocalInAppNotifications() async {
    try {
      final prefs = await SecureUserPreferences.getInstance();
      final rawList = prefs.getStringList(_keyInAppNotifications);
      if (rawList == null || rawList.isEmpty) return [];
      return rawList.map((str) {
        final map = jsonDecode(str) as Map<String, dynamic>;
        return WaliNotificationItem.fromJson(map);
      }).toList();
    } catch (e) {
      SafeLog.debug(
        'wali_storage_service.walistorage_error_getting_local_in_app_notifications',
      );
      return [];
    }
  }

  /// Clear all local in-app notifications
  Future<void> clearInAppNotifications() async {
    try {
      final prefs = await SecureUserPreferences.getInstance();
      await prefs.remove(_keyInAppNotifications);
    } catch (e) {
      SafeLog.debug(
        'wali_storage_service.walistorage_error_clearing_in_app_notifications',
      );
    }
  }

  /// Get list of read notification IDs
  Future<Set<String>> getReadNotificationIds() async {
    try {
      final prefs = await SecureUserPreferences.getInstance();
      final list = prefs.getStringList(_keyReadNotifications) ?? [];
      return list.toSet();
    } catch (e) {
      return {};
    }
  }

  /// Mark single notification as read
  Future<void> markNotificationAsRead(String notifId) async {
    try {
      final prefs = await SecureUserPreferences.getInstance();
      final current = (prefs.getStringList(_keyReadNotifications) ?? [])
          .toSet();
      current.add(notifId);
      await prefs.setStringList(_keyReadNotifications, current.toList());
    } catch (e) {
      SafeLog.debug(
        'wali_storage_service.walistorage_error_marking_notif_read',
      );
    }
  }

  /// Mark multiple notifications as read
  Future<void> markAllNotificationsAsRead(Iterable<String> notifIds) async {
    try {
      final prefs = await SecureUserPreferences.getInstance();
      final current = (prefs.getStringList(_keyReadNotifications) ?? [])
          .toSet();
      current.addAll(notifIds);
      await prefs.setStringList(_keyReadNotifications, current.toList());
    } catch (e) {
      SafeLog.debug(
        'wali_storage_service.walistorage_error_marking_all_notifs_read',
      );
    }
  }

  /// Push identity belongs to the verified adult account, never to a child/NIS.
  Future<void> syncOneSignalTags(List<ChildProfile> children) async {
    final userId = supabaseService.currentUserId;
    if (userId == null || children.isEmpty) return;
    await OneSignalService.loginUser(userId);
  }

  // ===========================================================================
  // OFFLINE SNAPSHOT CACHING (Instant Perceived Load)
  // ===========================================================================

  static const String _prefixTodayAttendance = 'cache_today_att_';
  static const String _prefixMonthlyStats = 'cache_month_stats_';

  /// Cache today's attendance data for instant offline view
  Future<void> cacheTodayAttendance(int childId, TodayAttendance data) async {
    try {
      final prefs = await SecureUserPreferences.getInstance();
      await prefs.setString(
        '$_prefixTodayAttendance$childId',
        jsonEncode(data.toJson()),
      );
    } catch (_) {}
  }

  /// Get cached today's attendance data
  Future<TodayAttendance?> getCachedTodayAttendance(int childId) async {
    try {
      final prefs = await SecureUserPreferences.getInstance();
      final str = prefs.getString('$_prefixTodayAttendance$childId');
      if (str == null || str.isEmpty) return null;
      final map = jsonDecode(str) as Map<String, dynamic>;
      return TodayAttendance.fromJson(map);
    } catch (_) {
      return null;
    }
  }

  /// Cache monthly attendance stats for instant offline view
  Future<void> cacheMonthlyStats(
    int childId,
    int month,
    int year,
    MonthlyAttendanceStats stats,
  ) async {
    try {
      final prefs = await SecureUserPreferences.getInstance();
      await prefs.setString(
        '$_prefixMonthlyStats${childId}_${month}_$year',
        jsonEncode(stats.toJson()),
      );
    } catch (_) {}
  }

  /// Get cached monthly attendance stats
  Future<MonthlyAttendanceStats?> getCachedMonthlyStats(
    int childId,
    int month,
    int year,
  ) async {
    try {
      final prefs = await SecureUserPreferences.getInstance();
      final str = prefs.getString(
        '$_prefixMonthlyStats${childId}_${month}_$year',
      );
      if (str == null || str.isEmpty) return null;
      final map = jsonDecode(str) as Map<String, dynamic>;
      return MonthlyAttendanceStats.fromJson(map);
    } catch (_) {
      return null;
    }
  }
}

final waliStorageService = WaliStorageService();
