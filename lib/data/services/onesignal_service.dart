import 'package:onesignal_flutter/onesignal_flutter.dart';

import '../../core/constants.dart';
import '../../core/safe_log.dart';
import '../models/wali_murid_models.dart';
import 'supabase_service.dart';
import 'wali_storage_service.dart';

/// The SDK receives an opaque adult-account identity from the server.
/// Sending is event-based only; the client cannot choose recipients or content.
class OneSignalService {
  static bool _isInitialized = false;
  static String? _identifiedUserId;

  static Future<void> initialize() async {
    if (AppConstants.onesignalAppId.isEmpty) return;
    try {
      OneSignal.Debug.setLogLevel(OSLogLevel.none);
      OneSignal.Debug.setAlertLevel(OSLogLevel.none);
      OneSignal.initialize(AppConstants.onesignalAppId);
      // Detach legacy student/NIS aliases and prevent delivery before login.
      await OneSignal.logout();
      await OneSignal.User.pushSubscription.optOut();
      _isInitialized = true;
      OneSignal.Notifications.addForegroundWillDisplayListener((event) {
        if (!supabaseService.isAuthenticated) {
          event.preventDefault();
          return;
        }
        _handleIncomingPush(event.notification);
        event.notification.display();
      });
      OneSignal.Notifications.addClickListener((event) {
        if (supabaseService.isAuthenticated) {
          _handleIncomingPush(event.notification);
        }
      });
    } catch (_) {
      SafeLog.debug('push.initialize_failed');
    }
  }

  static void _handleIncomingPush(OSNotification notification) {
    final data = notification.additionalData ?? {};
    final type = data['type']?.toString() ?? 'pengumuman';
    if (type == 'absensi' || type == 'absensi_status_update') return;
    final safeData = <String, dynamic>{
      for (final key in ['type', 'siswa_id', 'surat_id', 'event_id'])
        if (data.containsKey(key)) key: data[key],
    };
    waliStorageService.saveInAppNotification(
      WaliNotificationItem(
        id: notification.notificationId,
        title: notification.title ?? 'Pemberitahuan sekolah',
        message: notification.body ?? '',
        timestamp: DateTime.now(),
        type: type,
        isRead: false,
        author: 'Sekolah',
        data: safeData,
      ),
    );
  }

  static Future<void> loginUser(String userId) async {
    if (!_isInitialized ||
        !supabaseService.isAuthenticated ||
        supabaseService.currentUserId != userId ||
        _identifiedUserId == userId) {
      return;
    }
    try {
      // This private random identity is never the user/student ID or NIS.
      final identity = await supabaseService.client.rpc(
        'siab_my_push_identity',
      );
      if (identity is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(identity)) {
        return;
      }
      if (supabaseService.currentUserId != userId) return;
      await OneSignal.login(identity);
      await OneSignal.User.pushSubscription.optIn();
      _identifiedUserId = userId;
      await OneSignal.Notifications.requestPermission(true);
    } catch (_) {
      // No alias, tag or direct-REST fallback if the server has not authorized it.
      SafeLog.debug('push.identity_unavailable');
    }
  }

  static Future<void> logoutUser() async {
    _identifiedUserId = null;
    if (!_isInitialized) return;
    try {
      await OneSignal.User.pushSubscription.optOut();
      await OneSignal.logout();
    } catch (_) {
      SafeLog.debug('push.logout_failed');
    }
  }

  static Future<bool> sendAbsensiStatusUpdateNotification({
    required int siswaId,
    String? nis,
    required String namaSiswa,
    required String status,
    required String tanggal,
    String? keterangan,
  }) async {
    if (!supabaseService.isAuthenticated) return false;
    try {
      final record = await supabaseService.client
          .from(DbTables.absensi)
          .select('id')
          .eq('siswa_id', siswaId)
          .eq('tanggal', tanggal)
          .maybeSingle();
      final id = record?['id'];
      if (id is! int) return false;
      return sendEvent(eventType: 'attendance', recordId: id);
    } catch (_) {
      SafeLog.debug('push.attendance_event_unavailable');
      return false;
    }
  }

  static Future<bool> sendSuratDecisionNotification({required int suratId}) =>
      sendEvent(eventType: 'letter_decision', recordId: suratId);

  static Future<bool> sendEvent({
    required String eventType,
    required int recordId,
  }) async {
    if (!supabaseService.isAuthenticated ||
        recordId <= 0 ||
        !{'attendance', 'letter_decision'}.contains(eventType)) {
      return false;
    }
    try {
      final result = await supabaseService.client.functions.invoke(
        'send-push',
        body: {'event_type': eventType, 'record_id': recordId},
      );
      final body = result.data;
      return result.status == 200 && body is Map && body['accepted'] == true;
    } catch (_) {
      SafeLog.debug('push.event_delivery_failed');
      return false;
    }
  }

  static bool get isSubscribed =>
      _isInitialized && (OneSignal.User.pushSubscription.optedIn ?? false);
  static String? get subscriptionId =>
      _isInitialized ? OneSignal.User.pushSubscription.id : null;
  static String? get pushToken =>
      _isInitialized ? OneSignal.User.pushSubscription.token : null;
}
