import 'dart:io';
import 'dart:math';

import 'package:supabase_flutter/supabase_flutter.dart' hide AuthException;

import '../../core/constants.dart';
import '../../core/exceptions.dart';
import 'supabase_service.dart';

class PrivateDocumentService {
  PrivateDocumentService({SupabaseClient? client})
    : _client = client ?? supabaseService.client;

  final SupabaseClient _client;
  static const signedUrlLifetimeSeconds = 60;
  static const maxUploadBytes = 5 * 1024 * 1024;

  /// Accept old same-project storage URLs for viewing, and persist new paths.
  static String objectPath(String reference, {required Uri storageBase}) {
    // Uri.parse normalizes encoded dot segments; reject them before parsing.
    final decoded = Uri.decodeComponent(reference);
    if (decoded.contains('\\') ||
        RegExp(r'(^|/)\.{1,2}(/|$)').hasMatch(decoded)) {
      throw const FormatException('Document path traversal is not allowed.');
    }
    final uri = Uri.tryParse(reference);
    if (uri == null) throw const FormatException('Invalid document reference.');
    List<String> parts;
    if (uri.hasScheme || uri.hasAuthority) {
      if (!{'https', 'http'}.contains(uri.scheme) ||
          uri.origin != storageBase.origin) {
        throw const FormatException('External document hosts are not allowed.');
      }
      parts = uri.pathSegments;
      if (parts.length < 6 ||
          parts.take(3).join('/') != 'storage/v1/object' ||
          !{'public', 'sign', 'authenticated'}.contains(parts[3]) ||
          parts[4] != StorageBuckets.suratKeterangan) {
        throw const FormatException('Unexpected document bucket.');
      }
      parts = parts.sublist(5);
    } else {
      if (uri.hasQuery || uri.hasFragment) {
        throw const FormatException('Document paths cannot contain a query.');
      }
      parts = uri.pathSegments;
    }
    if (parts.isEmpty ||
        parts.any(
          (part) =>
              part.isEmpty ||
              part == '.' ||
              part == '..' ||
              !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(part),
        )) {
      throw const FormatException('Invalid document object path.');
    }
    return parts.join('/');
  }

  Future<String> signedUrl(String reference) async {
    final session = _client.auth.currentSession;
    if (session == null || session.isExpired) {
      throw AuthException(
        message: 'Silakan masuk kembali untuk melihat lampiran.',
      );
    }
    final path = objectPath(
      reference,
      storageBase: Uri.parse(_client.storage.url),
    );
    final url = await _client.storage
        .from(StorageBuckets.suratKeterangan)
        .createSignedUrl(path, signedUrlLifetimeSeconds);
    if (_client.auth.currentUser?.id != session.user.id) {
      throw AuthException(message: 'Sesi akun telah berubah.');
    }
    return url;
  }

  Future<String> upload({required File file, required int siswaId}) async {
    if (_client.auth.currentSession == null || siswaId <= 0) {
      throw AuthException(
        message: 'Sesi diperlukan untuk mengunggah lampiran.',
      );
    }
    final ext = file.path.split('.').last.toLowerCase();
    const mime = {
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'png': 'image/png',
    };
    if (!mime.containsKey(ext) || await file.length() > maxUploadBytes) {
      throw ValidationException(
        message: 'Lampiran harus JPG/PNG dengan ukuran maksimal 5 MB.',
      );
    }
    final random = Random.secure();
    final nonce = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final path =
        '$siswaId/${DateTime.now().microsecondsSinceEpoch}_$nonce.$ext';
    await _client.storage
        .from(StorageBuckets.suratKeterangan)
        .upload(
          path,
          file,
          fileOptions: FileOptions(upsert: false, contentType: mime[ext]),
        );
    return path;
  }
}
