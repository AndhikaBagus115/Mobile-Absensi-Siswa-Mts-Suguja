import 'dart:convert';

import 'package:app_absensi_mts/data/repositories/auth_repository.dart';
import 'package:app_absensi_mts/data/repositories/wali_repository.dart';
import 'package:app_absensi_mts/data/services/onesignal_service.dart';
import 'package:app_absensi_mts/data/services/private_document_service.dart';
import 'package:app_absensi_mts/data/services/secure_storage_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../tool/configure_public.dart' as configuration;
import 'support/test_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TestBackend backend;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    backend = TestBackend();
    await Supabase.initialize(
      url: TestBackend.url,
      anonKey: 'synthetic-test-key',
      httpClient: backend.client,
      authOptions: const FlutterAuthClientOptions(
        autoRefreshToken: false,
        localStorage: SecureSessionStorage(),
        authFlowType: AuthFlowType.implicit,
      ),
    );
  });
  tearDown(() async {
    await SecureUserPreferences.clearPrivateCache();
    await Supabase.instance.dispose();
    expect(backend.unexpectedRequests, isEmpty);
  });

  Future<void> signIn() =>
      Supabase.instance.client.auth.recoverSession(jsonEncode(backend.session));

  test(
    'Public build config excludes all private and unknown environment keys',
    () {
      final config = configuration.extractPublicConfig('''
SUPABASE_URL=https://test.invalid
SUPABASE_ANON_KEY=public-key
ONESIGNAL_APP_ID=public-id
ONESIGNAL_REST_API_KEY=private-sentinel
SUPABASE_SERVICE_ROLE_KEY=service-sentinel
UNKNOWN_SECRET=another-sentinel
''');
      expect(config, {
        'SUPABASE_URL': 'https://test.invalid',
        'SUPABASE_ANON_KEY': 'public-key',
        'ONESIGNAL_APP_ID': 'public-id',
      });
      expect(jsonEncode(config), isNot(contains('sentinel')));
    },
  );

  test('NIS alone is not an OTP contact', () {
    expect(
      () => AuthRepository.normalizeParentContact('99000001'),
      throwsException,
    );
    expect(backend.requests, isEmpty);
  });

  test(
    'Registered phone and email are normalized before requesting OTP',
    () async {
      await AuthRepository().requestParentOtp('0812 0000 0000');
      await AuthRepository().requestParentOtp('  WALI@example.test  ');
      final phone = jsonDecode(backend.requests[0].body) as Map;
      final email = jsonDecode(backend.requests[1].body) as Map;
      expect(phone['phone'], '+6281200000000');
      expect(email['email'], 'wali@example.test');
      expect(phone['create_user'], isFalse);
      expect(email['create_user'], isFalse);
    },
  );

  test(
    'Verifying email OTP uses the requested contact and email method',
    () async {
      backend.role = 'wali_murid';
      await AuthRepository().verifyParentOtp(
        contact: 'wali@example.test',
        token: '123456',
      );
      final body = jsonDecode(backend.requests.single.body) as Map;
      expect(body['type'], 'email');
      expect(body['email'], 'wali@example.test');
      expect(body.containsKey('phone'), isFalse);
      expect(Supabase.instance.client.auth.currentUser?.id, TestBackend.userId);
    },
  );

  test('Verifying phone OTP uses SMS and no email', () async {
    await AuthRepository().verifyParentOtp(
      contact: '081200000000',
      token: '123456',
    );
    final body = jsonDecode(backend.requests.single.body) as Map;
    expect(body['type'], 'sms');
    expect(body['phone'], '+6281200000000');
    expect(body.containsKey('email'), isFalse);
  });

  test('Invalid OTP never creates a session', () async {
    backend.rejectOtp = true;
    await expectLater(
      AuthRepository().verifyParentOtp(
        contact: 'wali@example.test',
        token: '000000',
      ),
      throwsException,
    );
    expect(Supabase.instance.client.auth.currentSession, isNull);
  });

  test(
    'Unauthenticated child lookup is rejected before querying data',
    () async {
      await expectLater(
        WaliRepository().findLinkedChildByNis(nis: 'UJI-001'),
        throwsException,
      );
      expect(backend.requests, isEmpty);
    },
  );

  test('Child selection uses only the server membership RPC', () async {
    backend.role = 'wali_murid';
    await signIn();
    final child = await WaliRepository().findLinkedChildByNis(nis: 'UJI-001');
    expect(child.id, TestBackend.childId);
    expect(backend.requests.single.url.path, '/rest/v1/rpc/siab_my_children');
    await expectLater(
      WaliRepository().findLinkedChildByNis(nis: 'OTHER'),
      throwsException,
    );
    expect(
      backend.requests.every((r) => r.url.path.endsWith('/siab_my_children')),
      isTrue,
    );
  });

  test(
    'Legacy plaintext data is removed while unrelated preferences remain',
    () async {
      SharedPreferences.setMockInitialValues({
        'wali_saved_children': ['private-child'],
        'cache_today_att_1': 'private-attendance',
        'sb-example-auth-token': 'private-token',
        'theme': 'dark',
      });
      await eraseLegacyPrivatePreferences();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), {'theme'});
    },
  );

  test(
    'Private cache is not available without an authenticated session',
    () async {
      await expectLater(SecureUserPreferences.getInstance(), throwsStateError);
    },
  );

  test(
    'Private cache uses secure storage and cannot cross an account change',
    () async {
      await signIn();
      final cache = await SecureUserPreferences.getInstance();
      await cache.setString('private_value', 'private-sentinel');
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
      expect(
        await privateStorage.containsKey(
          key: '${SecureUserPreferences.prefix}${TestBackend.userId}',
        ),
        isTrue,
      );
      await Supabase.instance.client.auth.signOut(scope: SignOutScope.local);
      expect(cache.getString('private_value'), isNull);
      await SecureUserPreferences.clearPrivateCache();
      expect(
        await privateStorage.containsKey(
          key: '${SecureUserPreferences.prefix}${TestBackend.userId}',
        ),
        isFalse,
      );
    },
  );

  test('Document references accept old same-project URLs and new paths', () {
    final base = Uri.parse('${TestBackend.url}/storage/v1');
    expect(
      PrivateDocumentService.objectPath(
        '${TestBackend.url}/storage/v1/object/public/surat_keterangan/pengajuan/surat_1_test.jpg',
        storageBase: base,
      ),
      'pengajuan/surat_1_test.jpg',
    );
    expect(
      PrivateDocumentService.objectPath('1/document.jpg', storageBase: base),
      '1/document.jpg',
    );
  });

  test(
    'Document references reject external hosts, other buckets, and traversal',
    () {
      final base = Uri.parse('${TestBackend.url}/storage/v1');
      for (final input in [
        'https://external.invalid/document.jpg',
        '${TestBackend.url}/storage/v1/object/public/avatars/photo.jpg',
        '../secret.jpg',
        '1/%2e%2e/secret.jpg',
        '1/%2Fsecret.jpg',
        'data:text/plain,tracking',
        '//external.invalid/image.jpg',
      ]) {
        expect(
          () => PrivateDocumentService.objectPath(input, storageBase: base),
          throwsFormatException,
          reason: input,
        );
      }
    },
  );

  test(
    'Signing requires a session and never falls back to a public download',
    () async {
      await expectLater(
        PrivateDocumentService().signedUrl('1/document.jpg'),
        throwsException,
      );
      expect(backend.requests, isEmpty);
      await signIn();
      backend.denyDocuments = true;
      await expectLater(
        PrivateDocumentService().signedUrl('1/document.jpg'),
        throwsException,
      );
      expect(backend.requests, hasLength(1));
      expect(backend.requests.single.method, 'POST');
      expect(backend.requests.single.url.path, contains('/object/sign/'));
    },
  );

  test(
    'Document signed URLs expire after 60 seconds and are not persisted',
    () async {
      await signIn();
      final url = await PrivateDocumentService().signedUrl('1/document.jpg');
      expect(url, contains('/object/sign/surat_keterangan/1/document.jpg'));
      expect(jsonDecode(backend.requests.single.body)['expiresIn'], 60);
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    },
  );

  test(
    'Push requests carry only event identity, never caller message or audience',
    () async {
      await signIn();
      expect(
        await OneSignalService.sendSuratDecisionNotification(suratId: 12),
        isTrue,
      );
      expect(backend.requests.single.url.path, '/functions/v1/send-push');
      expect(jsonDecode(backend.requests.single.body), {
        'event_type': 'letter_decision',
        'record_id': 12,
      });
    },
  );

  test('Push denial has no direct REST fallback', () async {
    await signIn();
    backend.rejectPush = true;
    expect(
      await OneSignalService.sendEvent(eventType: 'attendance', recordId: 12),
      isFalse,
    );
    expect(backend.requests, hasLength(1));
    expect(backend.requests.single.url.origin, TestBackend.url);
  });
}
