import '../../core/safe_log.dart';
import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/exceptions.dart';
import '../../data/repositories/repositories.dart';
import '../../data/services/onesignal_service.dart';
import '../../data/services/wali_storage_service.dart';
import '../wali/wali_dashboard_screen.dart';
import 'form_login.dart';
import 'dashboard_screen.dart';
import '../scanner/scan_dashboard_screen.dart';

/// Widget that handles authentication state and routing
class AuthWrapper extends StatefulWidget {
  const AuthWrapper({super.key});

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  final AuthRepository _authRepository = AuthRepository();

  bool _isError = false;
  String _errorMessage = '';

  @override
  void initState() {
    super.initState();
    _checkAuth();
  }

  Future<void> _checkAuth() async {
    await Future.delayed(Duration.zero);

    SafeLog.debug('auth_wrapper.debug_mulai_pengecekan_auth');

    // Cached children never establish authentication or ownership.
    if (!_authRepository.hasValidSession) {
      SafeLog.debug('auth_wrapper.debug_session_kosong_mengarahkan_ke_login');
      if (!mounted) return;
      _navigateTo(const LoginScreen());
      return;
    }

    final userId = _authRepository.currentUserId;
    SafeLog.debug('auth_wrapper.debug_user_uid');

    try {
      await _authRepository.validateSession();
      final role = await _authRepository.getCurrentUserRole();
      SafeLog.debug('auth_wrapper.debug_role_ditemukan');

      if (role == null) {
        final children = await WaliRepository().getLinkedChildren();
        if (children.isEmpty) {
          await waliStorageService.clearAll();
          _handleError(
            'Belum ada anak yang ditautkan ke akun ini. Hubungi admin sekolah.',
          );
          return;
        }
        await waliStorageService.replaceSavedChildren(children);
        waliStorageService.syncOneSignalTags(children).catchError((_) {});
        if (!mounted) return;
        _navigateTo(const WaliDashboardScreen());
        return;
      }

      // Sync OneSignal session & user role (non-blocking)
      if (userId != null) {
        OneSignalService.loginUser(userId).catchError((_) {});
      }

      if (!mounted) return;

      switch (role) {
        case UserRole.guru:
          SafeLog.debug('auth_wrapper.debug_redirect_ke_dashboard_guru');
          _navigateTo(const DashboardScreen());
          break;
        case UserRole.admin:
          SafeLog.debug('auth_wrapper.debug_redirect_ke_scan_dashboard');
          _navigateTo(const ScanDashboardScreen());
          break;
      }
    } on RepositoryException {
      _handleError(
        'Akses akun belum tersedia. Hubungi admin sekolah atau coba lagi.',
      );
    } catch (_) {
      _handleError(
        'Sesi belum dapat diverifikasi. Periksa koneksi dan coba lagi.',
      );
    }
  }

  void _handleError(String message) {
    SafeLog.debug('auth_wrapper.exception');
    if (mounted) {
      setState(() {
        _isError = true;
        _errorMessage = message;
      });
    }
  }

  void _navigateTo(Widget page) {
    Navigator.of(
      context,
    ).pushReplacement(MaterialPageRoute(builder: (_) => page));
  }

  Future<void> _handleLogout() async {
    await _authRepository.signOut();
    if (mounted) {
      _navigateTo(const LoginScreen());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isError) {
      return Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error_outline, size: 80, color: Colors.red),
                  const SizedBox(height: 24),
                  const Text(
                    'Terjadi Kesalahan',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _errorMessage,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 14, color: Colors.grey),
                  ),
                  const SizedBox(height: 32),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ElevatedButton.icon(
                        onPressed: () {
                          setState(() {
                            _isError = false;
                            _errorMessage = '';
                          });
                          _checkAuth();
                        },
                        icon: const Icon(Icons.refresh),
                        label: const Text('Coba Lagi'),
                      ),
                      const SizedBox(width: 16),
                      OutlinedButton.icon(
                        onPressed: _handleLogout,
                        icon: const Icon(Icons.logout, color: Colors.red),
                        label: const Text(
                          'Logout',
                          style: TextStyle(color: Colors.red),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Memuat...'),
          ],
        ),
      ),
    );
  }
}
