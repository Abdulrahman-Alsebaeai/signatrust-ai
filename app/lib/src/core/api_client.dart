import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'local_backend.dart';
import 'local_exception.dart';

/// A response object that preserves the existing `response.data` screen API.
class LocalResponse<T> {
  final T data;

  const LocalResponse(this.data);
}

/// Local route facade used as a drop-in replacement for Dio in the UI.
/// Every request is executed inside the application process.
class LocalApi {
  LocalApi(this._client);

  final ApiClient _client;

  Future<LocalResponse<dynamic>> get(String route) => _client._get(route);

  Future<LocalResponse<dynamic>> post(
    String route, {
    Object? data,
  }) =>
      _client._post(route, data: data);

  Future<LocalResponse<dynamic>> patch(
    String route, {
    Object? data,
  }) =>
      _client._patch(route, data: data);

  Future<LocalResponse<dynamic>> delete(String route) =>
      _client._delete(route);
}

class ApiClient {
  ApiClient._() {
    dio = LocalApi(this);
  }

  static final ApiClient instance = ApiClient._();

  final FlutterSecureStorage storage = const FlutterSecureStorage();
  final LocalBackend _backend = LocalBackend.instance;
  late final LocalApi dio;

  Future<void> initialize() async {
    await _backend.initialize();
  }

  Future<void> saveTokens(Map<String, dynamic> data) async {
    final accessToken = data['access_token']?.toString();
    final refreshToken = data['refresh_token']?.toString();
    if (accessToken == null || refreshToken == null) {
      throw const LocalAppException('The local session could not be created.');
    }
    await storage.write(key: 'access_token', value: accessToken);
    await storage.write(key: 'refresh_token', value: refreshToken);
  }

  Future<void> clearTokens() async {
    await storage.delete(key: 'access_token');
    await storage.delete(key: 'refresh_token');
  }

  Future<int> _currentUserId() async {
    final token = await storage.read(key: 'access_token');
    if (token == null || !token.startsWith('local:')) {
      throw const LocalAppException('Please sign in to continue.', code: 401);
    }
    final id = int.tryParse(token.substring('local:'.length));
    if (id == null || id <= 0) {
      throw const LocalAppException('Your local session is invalid.', code: 401);
    }
    await _backend.getUser(id);
    return id;
  }

  Future<LocalResponse<dynamic>> _get(String route) async {
    switch (route) {
      case '/auth/me':
        return LocalResponse(await _backend.getUser(await _currentUserId()));
      case '/signatures/enrollment':
        return LocalResponse(
          await _backend.enrollmentStatus(await _currentUserId()),
        );
      case '/signatures/history':
        return LocalResponse(
          await _backend.verificationHistory(await _currentUserId()),
        );
      case '/documents':
        return LocalResponse(
          await _backend.listDocuments(await _currentUserId()),
        );
      case '/admin/stats':
        return LocalResponse(
          await _backend.adminStats(await _currentUserId()),
        );
      case '/admin/users':
        return LocalResponse(
          await _backend.adminUsers(await _currentUserId()),
        );
      case '/admin/shared-documents':
        return LocalResponse(
          await _backend.adminSharedDocuments(await _currentUserId()),
        );
      case '/admin/verifications':
        return LocalResponse(
          await _backend.adminVerifications(await _currentUserId()),
        );
      default:
        throw LocalAppException('Unknown local route: $route', code: 404);
    }
  }

  Future<LocalResponse<dynamic>> _post(
    String route, {
    Object? data,
  }) async {
    final payload = _mapPayload(data);

    switch (route) {
      case '/auth/register':
        return LocalResponse(await _backend.register(payload));

      case '/auth/login':
        final userId = await _backend.login(
          payload['email']?.toString() ?? '',
          payload['password']?.toString() ?? '',
        );
        return LocalResponse({
          'access_token': 'local:$userId',
          'refresh_token': 'local:$userId',
          'token_type': 'local',
        });

      case '/auth/refresh':
        final refreshToken = payload['refresh_token']?.toString();
        if (refreshToken == null || !refreshToken.startsWith('local:')) {
          throw const LocalAppException(
            'Your local session has expired. Please sign in again.',
            code: 401,
          );
        }
        final userId = int.tryParse(refreshToken.substring('local:'.length));
        if (userId == null) {
          throw const LocalAppException(
            'Your local session has expired. Please sign in again.',
            code: 401,
          );
        }
        await _backend.getUser(userId);
        return LocalResponse({
          'access_token': 'local:$userId',
          'refresh_token': 'local:$userId',
          'token_type': 'local',
        });

      case '/auth/logout':
        await clearTokens();
        return const LocalResponse({'success': true});

      case '/signatures/enrollment':
        final references = payload['references'];
        if (references is! List) {
          throw const LocalAppException(
            'Five reference signatures are required.',
          );
        }
        return LocalResponse(
          await _backend.enroll(await _currentUserId(), references),
        );

      case '/signatures/verify':
        final signature = payload['signature'];
        if (signature is! Map) {
          throw const LocalAppException('The captured signature is invalid.');
        }
        return LocalResponse(
          await _backend.verifySignature(
            await _currentUserId(),
            Map<String, dynamic>.from(signature),
            payload['mode']?.toString() ?? 'balanced',
          ),
        );

      case '/users/me/change-password':
        await _backend.changePassword(
          await _currentUserId(),
          payload['current_password']?.toString() ?? '',
          payload['new_password']?.toString() ?? '',
        );
        return const LocalResponse({'success': true});
    }

    final documentSign = RegExp(
      r'^/documents/(\d+)/sign$',
    ).firstMatch(route);
    if (documentSign != null) {
      final signature = payload['signature'];
      if (signature is! Map) {
        throw const LocalAppException('The captured signature is invalid.');
      }
      return LocalResponse(
        await _backend.signDocument(
          await _currentUserId(),
          int.parse(documentSign.group(1)!),
          Map<String, dynamic>.from(signature),
        ),
      );
    }

    final documentAction = RegExp(
      r'^/documents/(\d+)/(share|unshare)$',
    ).firstMatch(route);
    if (documentAction != null) {
      final documentId = int.parse(documentAction.group(1)!);
      final shared = documentAction.group(2) == 'share';
      return LocalResponse(
        await _backend.setDocumentSharing(
          await _currentUserId(),
          documentId,
          shared,
        ),
      );
    }

    final adminAction = RegExp(
      r'^/admin/users/(\d+)/(activate|deactivate)$',
    ).firstMatch(route);
    if (adminAction != null) {
      final userId = int.parse(adminAction.group(1)!);
      final active = adminAction.group(2) == 'activate';
      await _backend.setUserActive(
        await _currentUserId(),
        userId,
        active,
      );
      return const LocalResponse({'success': true});
    }

    throw LocalAppException('Unknown local route: $route', code: 404);
  }

  Future<LocalResponse<dynamic>> _patch(
    String route, {
    Object? data,
  }) async {
    if (route == '/users/me') {
      return LocalResponse(
        await _backend.updateProfile(
          await _currentUserId(),
          _mapPayload(data),
        ),
      );
    }
    throw LocalAppException('Unknown local route: $route', code: 404);
  }

  Future<LocalResponse<dynamic>> _delete(String route) async {
    if (route == '/signatures/enrollment') {
      await _backend.deleteEnrollment(await _currentUserId());
      return const LocalResponse({'success': true});
    }

    final document = RegExp(r'^/documents/(\d+)$').firstMatch(route);
    if (document != null) {
      await _backend.deleteDocument(
        await _currentUserId(),
        int.parse(document.group(1)!),
      );
      return const LocalResponse({'success': true});
    }

    throw LocalAppException('Unknown local route: $route', code: 404);
  }

  Future<LocalResponse<Map<String, dynamic>>> uploadDocument({
    required String fileName,
    required Uint8List bytes,
    String? mimeType,
  }) async {
    return LocalResponse(
      await _backend.uploadDocument(
        userId: await _currentUserId(),
        fileName: fileName,
        bytes: bytes,
        mimeType: mimeType,
      ),
    );
  }

  Future<LocalResponse<Uint8List>> readDocumentOriginal({
    required int documentId,
    bool administrator = false,
  }) async {
    return LocalResponse(
      await _backend.readDocumentOriginal(
        await _currentUserId(),
        documentId,
        administrator: administrator,
      ),
    );
  }

  Future<LocalResponse<Uint8List>> readSignedDocumentPreview({
    required int documentId,
    bool administrator = false,
  }) async {
    return LocalResponse(
      await _backend.readSignedDocumentPreview(
        await _currentUserId(),
        documentId,
        administrator: administrator,
      ),
    );
  }

  Map<String, dynamic> _mapPayload(Object? data) {
    if (data == null) return <String, dynamic>{};
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    throw const LocalAppException('The submitted data is invalid.');
  }

  String errorMessage(Object error) {
    if (error is LocalAppException) return error.message;
    if (error is FormatException) return error.message;
    return 'The operation could not be completed. Please try again.';
  }
}
