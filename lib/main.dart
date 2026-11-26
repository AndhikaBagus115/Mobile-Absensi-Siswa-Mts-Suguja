import 'package:flutter/material.dart';
import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'core/constants.dart';
import 'data/services/onesignal_service.dart';
import 'data/services/secure_storage_service.dart';
import 'data/repositories/auth_repository.dart';
import 'features/auth/form_login.dart';
import 'features/auth/auth_wrapper.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Clear plaintext state from older builds; verified sessions use the keystore.
  await eraseLegacyPrivatePreferences();

  // 2. Initialize Indonesian date formatting
  await initializeDateFormatting('id_ID', null);

  // 3. Initialize Supabase with environment variables
  await Supabase.initialize(
    url: AppConstants.supabaseUrl,
    anonKey: AppConstants.supabaseAnonKey,
    debug: false,
    authOptions: const FlutterAuthClientOptions(
      localStorage: SecureSessionStorage(),
      authFlowType: AuthFlowType.implicit,
      detectSessionInUri: false,
    ),
  );

  // 4. Initialize OneSignal Push Notifications
  await OneSignalService.initialize();

  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final _navigator = GlobalKey<NavigatorState>();
  StreamSubscription<AuthState>? _authChanges;

  @override
  void initState() {
    super.initState();
    _authChanges = Supabase.instance.client.auth.onAuthStateChange.listen((
      state,
    ) {
      if (state.event == AuthChangeEvent.signedOut) {
        unawaited(
          Future<void>(() async {
            await AuthRepository.clearLocalSessionData();
            if (!mounted) return;
            _navigator.currentState?.pushAndRemoveUntil(
              MaterialPageRoute(builder: (_) => const LoginScreen()),
              (_) => false,
            );
          }),
        );
      }
    });
  }

  @override
  void dispose() {
    _authChanges?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigator,
      debugShowCheckedModeBanner: false,
      title: AppConstants.appName,

      // Material 3 Theme
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: UiConstants.primaryColor,
          brightness: Brightness.light,
        ),
      ),

      // Indonesian Localization
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('id', 'ID')],

      home: const AuthWrapper(),
    );
  }
}
