import '../../core/safe_log.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthException;

import '../../core/constants.dart';
import '../../core/exceptions.dart';
import '../models/models.dart';
import '../services/supabase_service.dart';
import '../services/wali_storage_service.dart';

/// Repository for Wali Murid (Parent Portal) data access
class WaliRepository {
  final SupabaseClient _client = supabaseService.client;

  /// The server derives the parent account from auth.uid(); no caller user ID.
  Future<List<ChildProfile>> getLinkedChildren() async {
    if (!supabaseService.isAuthenticated) {
      throw AuthException(message: 'Silakan masuk dengan OTP terlebih dahulu.');
    }
    try {
      final rows = await _client.rpc('siab_my_children') as List;
      return rows
          .map(
            (row) =>
                ChildProfile.fromJson(Map<String, dynamic>.from(row as Map)),
          )
          .toList();
    } on PostgrestException catch (error) {
      throw RepositoryException(
        message: 'Akses anak belum tersedia. Hubungi admin sekolah.',
        originalException: error,
      );
    }
  }

  /// NIS selects an already linked child; it never creates authentication.
  Future<ChildProfile> findLinkedChildByNis({required String nis}) async {
    final children = await getLinkedChildren();
    for (final child in children) {
      if (child.nis == nis.trim()) return child;
    }
    throw ValidationException(
      message: 'Anak belum ditautkan ke akun ini. Hubungi admin sekolah.',
    );
  }

  Future<ChildProfile?> getChildProfileById(int siswaId) async {
    final children = await getLinkedChildren();
    for (final child in children) {
      if (child.id == siswaId) return child;
    }
    return null;
  }

  /// Get today's attendance status for a student
  Future<TodayAttendance> getTodayAttendance(
    int siswaId, {
    int? kelasId,
  }) async {
    try {
      final now = DateTime.now();
      final todayStr = DateFormat('yyyy-MM-dd').format(now);

      // Get target class schedule
      String targetJamMasuk = Kelas.defaultJamMasuk;
      if (kelasId != null) {
        try {
          final kelasRes = await _client
              .from(DbTables.kelas)
              .select('${KelasColumns.jamMasuk}, ${KelasColumns.jamPulang}')
              .eq(KelasColumns.id, kelasId)
              .maybeSingle();
          if (kelasRes != null && kelasRes[KelasColumns.jamMasuk] != null) {
            targetJamMasuk = kelasRes[KelasColumns.jamMasuk] as String;
          }
        } catch (_) {}
      }

      final response = await _client
          .from(DbTables.absensi)
          .select(
            '${AbsensiColumns.id}, ${AbsensiColumns.siswaId}, ${AbsensiColumns.tanggal}, ${AbsensiColumns.status}, ${AbsensiColumns.waktuMasuk}, ${AbsensiColumns.waktuPulang}, ${AbsensiColumns.keterangan}',
          )
          .eq(AbsensiColumns.siswaId, siswaId)
          .eq(AbsensiColumns.tanggal, todayStr)
          .maybeSingle();

      if (response == null) {
        return TodayAttendance.empty(siswaId);
      }

      return TodayAttendance.fromJson(response, targetJamMasuk: targetJamMasuk);
    } on PostgrestException {
      SafeLog.debug('wali_repository.walirepo_error_fetching_today_attendance');
      return TodayAttendance.empty(siswaId);
    }
  }

  /// Get monthly attendance statistics for a student
  Future<MonthlyAttendanceStats> getMonthlyAttendanceStats({
    required int siswaId,
    required int month,
    required int year,
  }) async {
    try {
      final monthStr = month.toString().padLeft(2, '0');
      final daysInMonth = DateTime(year, month + 1, 0).day;
      final startDate = '$year-$monthStr-01';
      final endDate =
          '$year-$monthStr-${daysInMonth.toString().padLeft(2, '0')}';

      final response = await _client
          .from(DbTables.absensi)
          .select('${AbsensiColumns.status}, ${AbsensiColumns.tanggal}')
          .eq(AbsensiColumns.siswaId, siswaId)
          .gte(AbsensiColumns.tanggal, startDate)
          .lte(AbsensiColumns.tanggal, endDate);

      int hadir = 0;
      int terlambat = 0;
      int sakit = 0;
      int izin = 0;
      int alfa = 0;

      final records = response as List;
      for (final raw in records) {
        final item = raw as Map<String, dynamic>;
        final status = AttendanceStatus.fromValue(
          item[AbsensiColumns.status] as String?,
        );

        switch (status) {
          case AttendanceStatus.hadir:
          case AttendanceStatus.pulang:
            hadir++;
            break;
          case AttendanceStatus.terlambat:
            terlambat++;
            break;
          case AttendanceStatus.sakit:
            sakit++;
            break;
          case AttendanceStatus.izin:
            izin++;
            break;
          case AttendanceStatus.alfa:
            alfa++;
            break;
        }
      }

      // Estimate total school days up to current date in this month (Mon - Sat)
      final now = DateTime.now();
      final isCurrentMonth = now.year == year && now.month == month;
      final maxDay = isCurrentMonth ? now.day : daysInMonth;

      int schoolDays = 0;
      for (int d = 1; d <= maxDay; d++) {
        final date = DateTime(year, month, d);
        if (date.weekday != DateTime.sunday) {
          schoolDays++;
        }
      }

      if (schoolDays == 0) schoolDays = records.isNotEmpty ? records.length : 1;

      // Calculate Weekly Trend for Line Chart (Weeks 1 to 4/5)
      final List<AttendanceChartPoint> weeklyTrend = [];
      final weekRanges = [
        (1, 7, 'Mgg 1'),
        (8, 14, 'Mgg 2'),
        (15, 21, 'Mgg 3'),
        (22, 28, 'Mgg 4'),
        if (daysInMonth > 28) (29, daysInMonth, 'Mgg 5'),
      ];

      for (final range in weekRanges) {
        final startDay = range.$1;
        final endDay = range.$2;
        final label = range.$3;

        // Count attended and total recorded in this week window
        int weekAttended = 0;
        int weekRecorded = 0;
        for (final raw in records) {
          final item = raw as Map<String, dynamic>;
          final tglStr = item[AbsensiColumns.tanggal] as String? ?? '';
          final tglParts = tglStr.split('-');
          if (tglParts.length == 3) {
            final day = int.tryParse(tglParts[2]) ?? 0;
            if (day >= startDay && day <= endDay) {
              final status = AttendanceStatus.fromValue(
                item[AbsensiColumns.status] as String?,
              );
              weekRecorded++;
              if (status.isPresent || status.isLate) {
                weekAttended++;
              }
            }
          }
        }

        double pct = 0.0;
        if (weekRecorded > 0) {
          pct = ((weekAttended / weekRecorded) * 100).clamp(0.0, 100.0);
        } else {
          pct = 0.0;
        }

        weeklyTrend.add(
          AttendanceChartPoint(
            label: label,
            percentage: pct,
            hadir: weekAttended,
            totalHari: weekRecorded,
          ),
        );
      }

      return MonthlyAttendanceStats(
        totalHariSekolah: schoolDays,
        totalHadir: hadir,
        totalTerlambat: terlambat,
        totalSakit: sakit,
        totalIzin: izin,
        totalAlfa: alfa,
        bulan: month,
        tahun: year,
        weeklyTrend: weeklyTrend,
      );
    } on PostgrestException {
      SafeLog.debug('wali_repository.walirepo_error_fetching_monthly_stats');
      return MonthlyAttendanceStats.empty(month, year);
    }
  }

  /// Get student's monthly attendance history
  Future<List<Absensi>> getAttendanceHistory({
    required int siswaId,
    required int month,
    required int year,
  }) async {
    try {
      final monthStr = month.toString().padLeft(2, '0');
      final daysInMonth = DateTime(year, month + 1, 0).day;
      final startDate = '$year-$monthStr-01';
      final endDate =
          '$year-$monthStr-${daysInMonth.toString().padLeft(2, '0')}';

      final response = await _client
          .from(DbTables.absensi)
          .select()
          .eq(AbsensiColumns.siswaId, siswaId)
          .gte(AbsensiColumns.tanggal, startDate)
          .lte(AbsensiColumns.tanggal, endDate)
          .order(AbsensiColumns.tanggal, ascending: false);

      return (response as List).map((json) => Absensi.fromJson(json)).toList();
    } on PostgrestException {
      SafeLog.debug('wali_repository.walirepo_error_fetching_history');
      return [];
    }
  }

  /// Get announcement & broadcast notifications for child from Supabase & local inbox
  Future<List<WaliNotificationItem>> getNotificationsForChild(
    ChildProfile child,
  ) async {
    final readIds = await waliStorageService.getReadNotificationIds();
    final List<WaliNotificationItem> items = [];
    final Set<String> processedIds = {};

    // 1. Fetch announcements from Supabase 'pengumuman' table
    try {
      List<dynamic>? response;
      try {
        response = await _client
            .from(DbTables.pengumuman)
            .select()
            .order('created_at', ascending: false);
      } catch (_) {
        try {
          // Fallback if created_at column is not present or named differently
          response = await _client.from(DbTables.pengumuman).select();
        } catch (e) {
          SafeLog.debug('wali_repository.walirepo_info_query_tabel_pengumuman');
        }
      }

      if (response != null && response.isNotEmpty) {
        for (final row in response) {
          final map = row as Map<String, dynamic>;

          // Target Role Filter (e.g. 'all', 'wali_murid', 'semua', 'umum')
          final targetRole =
              (map['target_role'] ?? map['target'] ?? map['role'])
                  ?.toString()
                  .toLowerCase();
          if (targetRole != null &&
              targetRole.isNotEmpty &&
              targetRole != 'all' &&
              targetRole != 'semua' &&
              targetRole != 'wali' &&
              targetRole != 'wali_murid' &&
              targetRole != 'umum') {
            if (targetRole.contains('guru') || targetRole.contains('admin')) {
              continue; // Announcement is only for teachers / admins
            }
          }

          // Target Class Filter
          final rawKelasId = map['kelas_id'] ?? map['id_kelas'];
          if (rawKelasId != null && child.kelasId != null) {
            final parsedKelasId = int.tryParse(rawKelasId.toString());
            if (parsedKelasId != null && parsedKelasId != child.kelasId) {
              continue; // Announcement is targeted to a different class
            }
          }

          // Target Student (Siswa) Filter
          final rawSiswaId =
              map['siswa_id'] ??
              map['target_siswa_id'] ??
              map['id_siswa'] ??
              map['student_id'];
          if (rawSiswaId != null) {
            final parsedSiswaId = int.tryParse(rawSiswaId.toString());
            if (parsedSiswaId != null && parsedSiswaId != child.id) {
              continue; // Announcement is targeted to a different student
            }
          }

          final rawNis = map['nis'] ?? map['student_nis'];
          if (rawNis != null && rawNis.toString().trim().isNotEmpty) {
            if (rawNis.toString().trim() != child.nis.trim()) {
              continue; // Announcement is targeted to a different NIS
            }
          }

          final id =
              (map['id'] ?? map['uuid'] ?? map['pengumuman_id'])?.toString() ??
              'pengumuman_${map.hashCode}';
          final title =
              (map['judul'] ??
                      map['title'] ??
                      map['subjek'] ??
                      map['nama'] ??
                      'Pengumuman Sekolah')
                  .toString();
          final message =
              (map['isi'] ??
                      map['konten'] ??
                      map['pesan'] ??
                      map['deskripsi'] ??
                      map['keterangan'] ??
                      map['content'] ??
                      '')
                  .toString();
          final rawTime =
              map['created_at'] ??
              map['tanggal'] ??
              map['tgl'] ??
              map['waktu'] ??
              map['updated_at'];
          final timestamp = rawTime != null
              ? (DateTime.tryParse(rawTime.toString()) ?? DateTime.now())
              : DateTime.now();
          final author =
              (map['penulis'] ??
                      map['author'] ??
                      map['created_by'] ??
                      map['nama_guru'] ??
                      map['sender'])
                  ?.toString();
          final category = (map['kategori'] ?? map['tipe'] ?? map['category'])
              ?.toString();

          processedIds.add(id);
          items.add(
            WaliNotificationItem(
              id: id,
              title: title,
              message: message,
              timestamp: timestamp,
              type: 'pengumuman',
              isRead: readIds.contains(id),
              author: author,
              category: category,
              data: map,
            ),
          );
        }
      }
    } catch (e) {
      SafeLog.debug('wali_repository.walirepo_error_fetching_pengumuman');
    }

    // 2. Merge local push notifications received via OneSignal (inbox) - FILTERED BY CHILD
    try {
      final localPushItems = await waliStorageService
          .getLocalInAppNotifications();
      for (final localItem in localPushItems) {
        if (processedIds.contains(localItem.id)) continue;

        // Check if this push notification was targeted to a specific child
        final notifData = localItem.data ?? {};
        final rawNotifSiswaId =
            notifData['siswa_id'] ??
            notifData['student_id'] ??
            notifData['id_siswa'];
        if (rawNotifSiswaId != null) {
          final parsedId = int.tryParse(rawNotifSiswaId.toString());
          if (parsedId != null && parsedId != child.id) {
            continue; // Push notification belongs to a different child
          }
        }

        final rawNotifNis = notifData['nis'] ?? notifData['student_nis'];
        if (rawNotifNis != null && rawNotifNis.toString().trim().isNotEmpty) {
          if (rawNotifNis.toString().trim() != child.nis.trim()) {
            continue; // Push notification belongs to a different NIS
          }
        }

        final rawNotifKelasId =
            notifData['kelas_id'] ?? notifData['student_class'];
        if (rawNotifKelasId != null && child.kelasId != null) {
          final parsedKId = int.tryParse(rawNotifKelasId.toString());
          if (parsedKId != null && parsedKId != child.kelasId) {
            continue; // Push notification belongs to a different class
          }
        }

        processedIds.add(localItem.id);
        items.add(
          WaliNotificationItem(
            id: localItem.id,
            title: localItem.title,
            message: localItem.message,
            timestamp: localItem.timestamp,
            type: 'pengumuman',
            isRead: readIds.contains(localItem.id),
            author: localItem.author,
            category: localItem.category,
            data: localItem.data,
          ),
        );
      }
    } catch (e) {
      SafeLog.debug(
        'wali_repository.walirepo_error_merging_local_notifications',
      );
    }

    // 3. Sort newest first
    items.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return items;
  }

  /// Get unread notification count for child
  Future<int> getUnreadNotificationCount(ChildProfile child) async {
    try {
      final items = await getNotificationsForChild(child);
      return items.where((item) => !item.isRead).length;
    } catch (e) {
      return 0;
    }
  }
}
