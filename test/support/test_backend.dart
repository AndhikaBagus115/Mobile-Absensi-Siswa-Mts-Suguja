import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// In-memory transport only: never reads .env or connects to a real backend.
class TestBackend {
  static const url = 'https://siab-test.invalid';
  static const userId = '11111111-1111-4111-8111-111111111111';
  static const childId = 999999;
  static const child = {
    'id': childId,
    'nis': 'UJI-001',
    'nama': 'Anak Uji',
    'kelas_id': 999999,
    'nama_kelas': 'Kelas Uji',
  };

  final requests = <http.Request>[];
  final unexpectedRequests = <String>[];
  String role = 'guru';
  bool rejectLogin = false;
  bool missingProfile = false;

  late final http.Client client = MockClient(_respond);

  Map<String, dynamic> get session {
    String encode(Object value) =>
        base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    final expiry = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
    final token =
        '${encode({'alg': 'HS256', 'typ': 'JWT'})}.'
        '${encode({'sub': userId, 'exp': expiry})}.synthetic';
    return {
      'access_token': token,
      'refresh_token': 'synthetic-refresh-token',
      'token_type': 'bearer',
      'expires_in': 3600,
      'expires_at': expiry,
      'user': {
        'id': userId,
        'aud': 'authenticated',
        'email': 'guru@example.test',
        'app_metadata': <String, dynamic>{},
        'user_metadata': <String, dynamic>{},
        'created_at': '2026-01-01T00:00:00Z',
      },
    };
  }

  Future<http.Response> _respond(http.Request request) async {
    requests.add(request);
    final path = request.url.path;
    if (request.url.origin != url) return _unexpected(request);
    if (request.method == 'POST' && path == '/auth/v1/token') {
      return rejectLogin
          ? _json(request, {
              'error_code': 'invalid_credentials',
              'msg': 'Invalid login credentials',
            }, status: 400)
          : _json(request, session);
    }
    if (request.method == 'POST' &&
        path == '/rest/v1/rpc/get_guru_dashboard_summary') {
      return _json(request, [
        {
          'nama_kelas': 'Kelas Uji',
          'total_siswa': 3,
          'hadir': 1,
          'terlambat': 0,
          'pulang': 1,
          'sakit': 1,
          'izin': 0,
          'alfa': 0,
        },
      ]);
    }
    if (request.method != 'GET') return _unexpected(request);
    final List<Map<String, dynamic>> rows;
    switch (path) {
      case '/rest/v1/guru':
        rows = missingProfile
            ? []
            : [
                {
                  'id': userId,
                  'nama': 'Guru Uji',
                  'nip': 'UJI-001',
                  'role': role,
                  'kelas_diampu': {
                    'Uji': ['Kelas Uji'],
                  },
                },
              ];
      case '/rest/v1/siswa':
        rows = [child];
      case '/rest/v1/kelas':
        rows = [
          {
            'id': 999999,
            'nama_kelas': 'Kelas Uji',
            'jam_masuk': '07:00:00',
            'jam_pulang': '14:00:00',
          },
        ];
      case '/rest/v1/absensi':
      case '/rest/v1/surat':
      case '/rest/v1/pengumuman':
        rows = [];
      default:
        return _unexpected(request);
    }
    final wantsObject =
        request.headers['Accept']?.contains('vnd.pgrst.object') ?? false;
    return _json(request, wantsObject ? rows.firstOrNull : rows);
  }

  Never _unexpected(http.Request request) {
    final description = '${request.method} ${request.url}';
    unexpectedRequests.add(description);
    throw StateError('Unexpected test request: $description');
  }

  http.Response _json(http.Request request, Object? body, {int status = 200}) =>
      http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json'},
        request: request,
      );
}
