import 'dart:convert';

import 'package:app_absensi_mts/features/auth/dashboard_screen.dart';
import 'package:app_absensi_mts/features/auth/form_login.dart';
import 'package:app_absensi_mts/features/scanner/scan_dashboard_screen.dart';
import 'package:app_absensi_mts/features/wali/wali_dashboard_screen.dart';
import 'package:app_absensi_mts/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'support/test_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TestBackend backend;
  const oneSignalUserChannel = MethodChannel('OneSignal#user');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dotenv.testLoad(fileInput: 'ONESIGNAL_APP_ID=\n');
    await initializeDateFormatting('id_ID');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(oneSignalUserChannel, (_) async => null);
    backend = TestBackend();
    await Supabase.initialize(
      url: TestBackend.url,
      anonKey: 'synthetic-test-key',
      httpClient: backend.client,
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
    );
  });

  tearDown(() async {
    await Supabase.instance.dispose();
    dotenv.clean();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(oneSignalUserChannel, null);
    expect(backend.unexpectedRequests, isEmpty);
  });

  // Dashboards have repeating animations and refresh timers. Use bounded pumps
  // and dispose the app before the framework checks for pending timers.
  void testApp(String description, WidgetTesterCallback scenario) {
    testWidgets(description, (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 1200);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      try {
        await scenario(tester);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
    });
  }

  testApp('Tanpa sesi, aplikasi membuka form login', (tester) async {
    await openApp(tester);
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.text('Guru / Admin'), findsOneWidget);
    expect(find.text('Wali Murid'), findsOneWidget);
    expect(backend.requests, isEmpty);
    expect(Supabase.instance.client.auth.currentSession, isNull);
  });

  testApp('Form guru menolak email dan password kosong tanpa request', (
    tester,
  ) async {
    await openApp(tester);
    await tapButton(tester, 'MASUK SEBAGAI GURU');
    expect(find.text('Email tidak boleh kosong'), findsOneWidget);
    expect(find.text('Password tidak boleh kosong'), findsOneWidget);
    expect(backend.requests, isEmpty);
  });

  testApp('Form guru menolak email tidak valid dan password pendek', (
    tester,
  ) async {
    await openApp(tester);
    await enterCredentials(tester, email: 'bukan-email', password: '123');
    await tapButton(tester, 'MASUK SEBAGAI GURU');
    expect(find.text('Format email tidak valid'), findsOneWidget);
    expect(find.text('Password minimal 6 karakter'), findsOneWidget);
    expect(backend.requests, isEmpty);
  });

  testApp('Form wali menolak NIS kosong tanpa request', (tester) async {
    await openApp(tester);
    await tapButton(tester, 'Wali Murid');
    await tapButton(tester, 'MASUK SEBAGAI WALI MURID');
    expect(find.text('NIS siswa wajib diisi'), findsOneWidget);
    expect(backend.requests, isEmpty);
  });

  testApp('Login ditolak menampilkan pesan dan tetap berada di form', (
    tester,
  ) async {
    backend.rejectLogin = true;
    await openApp(tester);
    await enterCredentials(tester);
    await tapButton(tester, 'MASUK SEBAGAI GURU');
    expect(
      find.text('Email atau kata sandi salah. Silakan periksa kembali.'),
      findsOneWidget,
    );
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(Supabase.instance.client.auth.currentSession, isNull);
    expect(backend.requests.single.url.path, '/auth/v1/token');
    expect(find.byType(ScanDashboardScreen), findsNothing);
  });

  testApp('Login admin berhasil mengirim kredensial dan membuka scanner', (
    tester,
  ) async {
    backend.role = 'admin';
    await openApp(tester);
    await enterCredentials(tester, email: '  admin@example.test  ');
    await tapButton(tester, 'MASUK SEBAGAI GURU');
    final loginRequest = backend.requests.first;
    expect(loginRequest.method, 'POST');
    expect(loginRequest.url.path, '/auth/v1/token');
    expect(loginRequest.url.queryParameters['grant_type'], 'password');
    final credentials = jsonDecode(loginRequest.body) as Map<String, dynamic>;
    expect(credentials['email'], 'admin@example.test');
    expect(credentials['password'], 'synthetic-password');
    expect(Supabase.instance.client.auth.currentUser?.id, TestBackend.userId);
    expect(find.byType(ScanDashboardScreen), findsOneWidget);
    expect(find.byType(DashboardScreen), findsNothing);
    expect(find.byType(LoginScreen), findsNothing);
  });

  testApp('Sesi guru dipulihkan dan dashboard memuat kelas dari backend', (
    tester,
  ) async {
    await Supabase.instance.client.auth.recoverSession(
      jsonEncode(backend.session),
    );
    await openApp(tester);
    expect(find.byType(DashboardScreen), findsOneWidget);
    expect(find.text('Dashboard Guru'), findsOneWidget);
    expect(find.text('Kelas Uji'), findsOneWidget);
    expect(find.byType(ScanDashboardScreen), findsNothing);
    expect(
      backend.requests.where(
        (request) => request.url.path.endsWith('/get_guru_dashboard_summary'),
      ),
      hasLength(1),
    );
    final profileRequests = backend.requests.where(
      (request) => request.url.path == '/rest/v1/guru',
    );
    expect(profileRequests, isNotEmpty);
    expect(
      profileRequests.every(
        (request) =>
            request.url.queryParameters['id'] == 'eq.${TestBackend.userId}',
      ),
      isTrue,
    );
  });

  testApp('Sesi tanpa profil menampilkan error dan tidak membuka dashboard', (
    tester,
  ) async {
    backend.missingProfile = true;
    await Supabase.instance.client.auth.recoverSession(
      jsonEncode(backend.session),
    );
    await openApp(tester);
    expect(find.text('Terjadi Kesalahan'), findsOneWidget);
    expect(
      find.textContaining('data profil \'guru\' belum dibuat'),
      findsOneWidget,
    );
    expect(find.text('Coba Lagi'), findsOneWidget);
    expect(find.byType(DashboardScreen), findsNothing);
    expect(find.byType(ScanDashboardScreen), findsNothing);
  });

  testApp(
    'Profil anak tersimpan membuka dashboard wali dan memuat anak aktif',
    (tester) async {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setStringList('wali_saved_children', [
        jsonEncode(TestBackend.child),
      ]);
      await preferences.setInt('wali_active_child_id', TestBackend.childId);
      await openApp(tester);
      expect(find.byType(WaliDashboardScreen), findsOneWidget);
      expect(find.text('Anak Uji'), findsWidgets);
      expect(find.byType(LoginScreen), findsNothing);
      final attendanceRequests = backend.requests.where(
        (request) => request.url.path == '/rest/v1/absensi',
      );
      expect(attendanceRequests, isNotEmpty);
      expect(
        attendanceRequests.every(
          (request) =>
              request.url.queryParameters['siswa_id'] ==
              'eq.${TestBackend.childId}',
        ),
        isTrue,
      );
    },
  );
}

Future<void> pumpFrames(WidgetTester tester) async {
  for (var frame = 0; frame < 20; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> openApp(WidgetTester tester) async {
  await tester.pumpWidget(const MyApp());
  await pumpFrames(tester);
}

Future<void> tapButton(WidgetTester tester, String label) async {
  final button = find.text(label);
  await tester.ensureVisible(button);
  await tester.tap(button);
  await pumpFrames(tester);
}

Future<void> enterCredentials(
  WidgetTester tester, {
  String email = 'guru@example.test',
  String password = 'synthetic-password',
}) async {
  await tester.enterText(
    find.widgetWithText(TextFormField, 'Email Akun'),
    email,
  );
  await tester.enterText(
    find.widgetWithText(TextFormField, 'Kata Sandi'),
    password,
  );
  tester.testTextInput.hide();
  await tester.pump();
}
