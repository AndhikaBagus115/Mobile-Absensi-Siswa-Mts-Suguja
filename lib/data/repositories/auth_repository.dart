import '../../core/safe_log.dart';
import 'package:flutter/painting.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../../core/constants.dart';
import '../../core/exceptions.dart';
import '../models/models.dart';
import '../services/onesignal_service.dart';
import '../services/secure_storage_service.dart';
import '../services/supabase_service.dart';

/// Repository for teacher (guru) and authentication operations
class AuthRepository {
  final supabase.SupabaseClient _client = supabaseService.client;

  /// Sign in with email and password
  Future<supabase.AuthResponse> signIn({
    required String email,
    required String password,
  }) async {
    try {
      final response = await _client.auth.signInWithPassword(
        email: email.trim(),
        password: password,
      );
      if (response.user != null) {
        await OneSignalService.loginUser(response.user!.id);
      }
      return response;
    } on supabase.AuthException catch (e) {
      throw AuthException(message: e.message, originalException: e);
    }
  }

  /// Sign out current user
  Future<void> signOut() async {
    try {
      await OneSignalService.logoutUser();
      await _client.auth.signOut();
    } on supabase.AuthException {
      SafeLog.debug('auth_repository.sign_out_error');
    } catch (e) {
      SafeLog.debug('auth_repository.sign_out_error');
    } finally {
      try {
        if (_client.auth.currentSession != null) {
          await _client.auth.signOut(scope: supabase.SignOutScope.local);
        }
      } finally {
        await clearLocalSessionData();
      }
    }
  }

  static Future<void> clearLocalSessionData() async {
    await OneSignalService.logoutUser();
    await SecureUserPreferences.clearPrivateCache();
    await eraseLegacyPrivatePreferences();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  }

  /// Check the token with Auth before using a persisted session for routing.
  Future<void> validateSession() async {
    final response = await _client.auth.getUser();
    if (response.user?.id != currentUserId) {
      throw AuthException(message: 'Sesi tidak valid. Silakan masuk kembali.');
    }
  }

  Future<void> requestParentOtp(String contact) async {
    final normalized = normalizeParentContact(contact);
    await _client.auth.signInWithOtp(
      email: normalized.contains('@') ? normalized : null,
      phone: normalized.contains('@') ? null : normalized,
      shouldCreateUser: false,
    );
  }

  Future<void> verifyParentOtp({
    required String contact,
    required String token,
  }) async {
    final normalized = normalizeParentContact(contact);
    if (!RegExp(r'^\d{6}$').hasMatch(token.trim())) {
      throw ValidationException(
        message: 'Kode OTP harus terdiri dari 6 angka.',
      );
    }
    final isEmail = normalized.contains('@');
    final response = await _client.auth.verifyOTP(
      email: isEmail ? normalized : null,
      phone: isEmail ? null : normalized,
      token: token.trim(),
      type: isEmail ? supabase.OtpType.email : supabase.OtpType.sms,
    );
    if (response.session == null) {
      throw AuthException(message: 'Kode OTP tidak valid atau kedaluwarsa.');
    }
  }

  static String normalizeParentContact(String contact) {
    final value = contact.trim();
    if (RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value)) {
      return value.toLowerCase();
    }
    var phone = value.replaceAll(RegExp(r'[\s()-]'), '');
    if (phone.startsWith('08')) phone = '+62${phone.substring(1)}';
    if (phone.startsWith('628')) phone = '+$phone';
    if (!RegExp(r'^\+[1-9]\d{7,14}$').hasMatch(phone)) {
      throw ValidationException(
        message: 'Masukkan email atau nomor HP terdaftar yang valid.',
      );
    }
    return phone;
  }

  /// Get current user's guru profile
  Future<Guru?> getCurrentGuruProfile() async {
    final userId = supabaseService.currentUserId;
    if (userId == null) return null;

    try {
      final response = await _client
          .from(DbTables.guru)
          .select()
          .eq(GuruColumns.id, userId)
          .maybeSingle();

      if (response == null) return null;
      return Guru.fromJson(response);
    } on supabase.PostgrestException catch (e) {
      throw RepositoryException(
        message: 'Gagal mengambil profil guru: ${e.message}',
        originalException: e,
      );
    }
  }

  /// Get user role for routing
  Future<UserRole?> getCurrentUserRole() async {
    final userId = supabaseService.currentUserId;
    if (userId == null) return null;

    try {
      final response = await _client
          .from(DbTables.guru)
          .select(GuruColumns.role)
          .eq(GuruColumns.id, userId)
          .maybeSingle();

      if (response == null) return null;
      final value = response[GuruColumns.role] as String?;
      for (final role in UserRole.values) {
        if (role.value == value) return role;
      }
      return null;
    } on supabase.PostgrestException {
      SafeLog.debug('auth_repository.error_getting_user_role');
      return null;
    }
  }

  /// Get dashboard summary for teacher
  Future<List<ClassSummary>> getDashboardSummary() async {
    final userId = supabaseService.currentUserId;
    if (userId == null) {
      throw AuthException(message: 'User tidak terautentikasi');
    }

    try {
      final response = await _client.rpc(
        RpcFunctions.getGuruDashboardSummary,
        params: {'p_guru_id': userId},
      );

      final summaries = (response as List)
          .map((item) => ClassSummary.fromJson(item as Map<String, dynamic>))
          .toList();

      // Ensure students with status 'pulang' (checked out today) are accurately counted
      for (int i = 0; i < summaries.length; i++) {
        final summary = summaries[i];
        if (summary.pulang == 0) {
          try {
            final students = await _client.rpc(
              RpcFunctions.getSiswaKelasHariIni,
              params: {'p_nama_kelas': summary.namaKelas},
            );
            if (students is List && students.isNotEmpty) {
              int pulangCount = 0;
              int hadirCount = 0;
              int terlambatCount = 0;
              int sakitCount = 0;
              int izinCount = 0;
              int alfaCount = 0;

              for (final s in students) {
                final st = (s['status_absensi'] as String? ?? '').toLowerCase();
                if (st == 'pulang') pulangCount++;
                if (st == 'hadir') hadirCount++;
                if (st == 'terlambat') terlambatCount++;
                if (st == 'sakit') sakitCount++;
                if (st == 'izin') izinCount++;
                if (st == 'alfa') alfaCount++;
              }

              if (pulangCount > 0) {
                summaries[i] = ClassSummary(
                  namaKelas: summary.namaKelas,
                  totalSiswa: students.length,
                  hadir: hadirCount,
                  terlambat: terlambatCount,
                  sakit: sakitCount,
                  izin: izinCount,
                  alfa: alfaCount,
                  pulang: pulangCount,
                );
              }
            }
          } catch (e) {
            SafeLog.debug('auth_repository.info_checking_class');
          }
        }
      }

      return summaries;
    } on supabase.PostgrestException catch (e) {
      throw RepositoryException(
        message: 'Gagal mengambil data dashboard: ${e.message}',
        originalException: e,
      );
    }
  }

  /// Check if current session is valid
  bool get hasValidSession => supabaseService.isAuthenticated;

  /// Get current user ID
  String? get currentUserId => supabaseService.currentUserId;

  /// Update teacher personal info (nama, no_hp, foto_url)
  Future<void> updateProfile({
    required String nama,
    String? noHp,
    String? fotoUrl,
  }) async {
    final userId = supabaseService.currentUserId;
    if (userId == null) {
      throw AuthException(message: 'User tidak terautentikasi');
    }

    try {
      // Attempt 1: Try with all fields including foto_url & avatar_url
      final fullData = <String, dynamic>{
        'nama': nama.trim(),
        if (noHp != null && noHp.isNotEmpty) 'no_hp': noHp.trim(),
        if (fotoUrl != null && fotoUrl.isNotEmpty) ...{
          'foto_url': fotoUrl,
          'avatar_url': fotoUrl,
        },
      };

      try {
        await _client
            .from(DbTables.guru)
            .update(fullData)
            .eq(GuruColumns.id, userId);
        return;
      } catch (e) {
        SafeLog.debug(
          'auth_repository.authrepo_attempt_1_with_foto_url_avatar_url_failed',
        );
      }

      // Attempt 2: Try avatar_url only
      if (fotoUrl != null && fotoUrl.isNotEmpty) {
        final avatarOnlyData = <String, dynamic>{
          'nama': nama.trim(),
          if (noHp != null && noHp.isNotEmpty) 'no_hp': noHp.trim(),
          'avatar_url': fotoUrl,
        };
        try {
          await _client
              .from(DbTables.guru)
              .update(avatarOnlyData)
              .eq(GuruColumns.id, userId);
          return;
        } catch (e) {
          SafeLog.debug(
            'auth_repository.authrepo_attempt_2_with_avatar_url_failed',
          );
        }

        // Attempt 3: Try foto_url only
        final fotoOnlyData = <String, dynamic>{
          'nama': nama.trim(),
          if (noHp != null && noHp.isNotEmpty) 'no_hp': noHp.trim(),
          'foto_url': fotoUrl,
        };
        try {
          await _client
              .from(DbTables.guru)
              .update(fotoOnlyData)
              .eq(GuruColumns.id, userId);
          return;
        } catch (e) {
          SafeLog.debug(
            'auth_repository.authrepo_attempt_3_with_foto_url_failed',
          );
        }
      }

      // Attempt 4: Update nama & no_hp without photo columns
      final nameAndPhone = <String, dynamic>{
        'nama': nama.trim(),
        if (noHp != null && noHp.isNotEmpty) 'no_hp': noHp.trim(),
      };
      try {
        await _client
            .from(DbTables.guru)
            .update(nameAndPhone)
            .eq(GuruColumns.id, userId);
        return;
      } catch (e) {
        SafeLog.debug('auth_repository.authrepo_attempt_4_with_no_hp_failed');
      }

      // Attempt 5: Just nama
      await _client
          .from(DbTables.guru)
          .update({'nama': nama.trim()})
          .eq(GuruColumns.id, userId);
    } on supabase.PostgrestException catch (e) {
      throw RepositoryException(
        message: 'Gagal memperbarui profil: ${e.message}',
        originalException: e,
      );
    } catch (e) {
      throw RepositoryException(message: 'Gagal memperbarui profil: $e');
    }
  }

  /// Upload avatar image to Supabase Storage
  Future<String?> uploadAvatar(dynamic file) async {
    final userId = supabaseService.currentUserId;
    if (userId == null) return null;

    try {
      final ext = file.path.split('.').last;
      final fileName =
          'avatar_${userId}_${DateTime.now().millisecondsSinceEpoch}.$ext';

      await _client.storage
          .from('avatars')
          .upload(
            '$userId/$fileName',
            file,
            fileOptions: const supabase.FileOptions(upsert: false),
          );
      return _client.storage.from('avatars').getPublicUrl('$userId/$fileName');
    } catch (e) {
      SafeLog.debug('auth_repository.authrepo_error_uploadavatar');
      throw RepositoryException(message: 'Gagal mengunggah foto profil: $e');
    }
  }

  /// Update teacher email in Supabase Auth and database table
  Future<void> updateEmail(String newEmail) async {
    final userId = supabaseService.currentUserId;
    if (userId == null) {
      throw AuthException(message: 'User tidak terautentikasi');
    }

    try {
      final attrs = supabase.UserAttributes(email: newEmail.trim());
      await _client.auth.updateUser(attrs);

      try {
        await _client
            .from(DbTables.guru)
            .update({
              GuruColumns.email: newEmail.trim(),
              GuruColumns.updatedAt: DateTime.now().toIso8601String(),
            })
            .eq(GuruColumns.id, userId);
      } catch (e) {
        SafeLog.debug(
          'auth_repository.authrepo_notice_could_not_update_email_column_in_guru_table',
        );
      }
    } on supabase.AuthException catch (e) {
      throw AuthException(
        message: 'Gagal memperbarui email: ${e.message}',
        originalException: e,
      );
    }
  }

  /// Update teacher password in Supabase Auth
  Future<void> updatePassword(String newPassword) async {
    try {
      final attrs = supabase.UserAttributes(password: newPassword);
      await _client.auth.updateUser(attrs);
    } on supabase.AuthException catch (e) {
      throw AuthException(
        message: 'Gagal mengubah password: ${e.message}',
        originalException: e,
      );
    }
  }
}
