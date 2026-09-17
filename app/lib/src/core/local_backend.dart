import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'local_crypto.dart';
import 'local_database.dart';
import 'local_exception.dart';
import 'local_model_service.dart';
import 'signature_preprocessor.dart';

class LocalBackend {
  LocalBackend._();

  static final instance = LocalBackend._();

  final LocalDatabase _databaseService = LocalDatabase.instance;
  final LocalCryptoService _crypto = LocalCryptoService.instance;
  final LocalSignatureModelService model = LocalSignatureModelService.instance;

  Database get _db => _databaseService.database;

  Future<void> initialize() async {
    await _crypto.initialize();
    await _databaseService.initialize();
    await _seedAdministrator();

    // Warm up and validate the bundled ONNX model. A missing model does not
    // block account or document features; verification will show its own
    // concise error when requested.
    try {
      await model.ensureLoaded();
    } catch (_) {
      // Model readiness remains available through model.ready/model.error.
    }
  }

  Future<Map<String, dynamic>> register(Map<String, dynamic> payload) async {
    final fullName = payload['full_name']?.toString().trim() ?? '';
    final email = payload['email']?.toString().trim().toLowerCase() ?? '';
    final phone = payload['phone']?.toString().trim();
    final password = payload['password']?.toString() ?? '';
    final acceptedTerms = payload['accepted_terms'] == true;
    final acceptedPrivacy = payload['accepted_privacy'] == true;

    if (!acceptedTerms || !acceptedPrivacy) {
      throw const LocalAppException(
        'Accept the Terms of Use and Privacy Policy to continue.',
      );
    }

    _validateFullName(fullName);
    _validateEmail(email);
    _validatePassword(password);
    if (phone != null && phone.isNotEmpty) {
      _validatePhone(phone);
    }

    final existing = await _db.query(
      'users',
      columns: const ['id'],
      where: 'email = ?',
      whereArgs: [email],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      throw const LocalAppException(
        'An account already exists with this email.',
        code: 409,
      );
    }

    final now = _now();
    final id = await _db.insert('users', {
      'email': email,
      'full_name': fullName,
      'phone': phone == null || phone.isEmpty ? null : phone,
      'avatar_url': null,
      'password_hash': await _crypto.hashPassword(password),
      'role': 'user',
      'is_active': 1,
      'accepted_terms_at': now,
      'accepted_privacy_at': now,
      'created_at': now,
      'updated_at': now,
    });

    await _audit(
      actorUserId: id,
      action: 'user.registered',
      resourceType: 'user',
      resourceId: id.toString(),
    );

    return getUser(id);
  }

  Future<int> login(String email, String password) async {
    final normalizedEmail = email.trim().toLowerCase();
    final rows = await _db.query(
      'users',
      where: 'email = ?',
      whereArgs: [normalizedEmail],
      limit: 1,
    );

    if (rows.isEmpty) {
      throw const LocalAppException('Incorrect email or password.', code: 401);
    }

    final user = rows.first;
    final valid = await _crypto.verifyPassword(
      password,
      user['password_hash'] as String,
    );
    if (!valid) {
      throw const LocalAppException('Incorrect email or password.', code: 401);
    }
    if ((user['is_active'] as int? ?? 0) != 1) {
      throw const LocalAppException('This account is disabled.', code: 403);
    }

    final id = user['id'] as int;
    await _audit(
      actorUserId: id,
      action: 'user.logged_in',
      resourceType: 'user',
      resourceId: id.toString(),
    );
    return id;
  }

  Future<Map<String, dynamic>> getUser(int userId) async {
    final rows = await _db.rawQuery('''
      SELECT
        u.*,
        CASE WHEN e.id IS NULL THEN 0 ELSE 1 END AS has_enrollment
      FROM users u
      LEFT JOIN enrollment_templates e ON e.user_id = u.id
      WHERE u.id = ?
      LIMIT 1
    ''', [userId]);

    if (rows.isEmpty) {
      throw const LocalAppException('This account is unavailable.', code: 401);
    }
    if (rows.first['is_active'] != 1) {
      throw const LocalAppException('This account is disabled.', code: 403);
    }

    return _serializeUser(rows.first);
  }

  Future<Map<String, dynamic>> updateProfile(
    int userId,
    Map<String, dynamic> payload,
  ) async {
    final updates = <String, Object?>{};

    if (payload.containsKey('full_name')) {
      final fullName = payload['full_name']?.toString().trim() ?? '';
      _validateFullName(fullName);
      updates['full_name'] = fullName;
    }
    if (payload.containsKey('phone')) {
      final phone = payload['phone']?.toString().trim() ?? '';
      if (phone.isNotEmpty) _validatePhone(phone);
      updates['phone'] = phone.isEmpty ? null : phone;
    }
    if (payload.containsKey('avatar_url')) {
      final avatar = payload['avatar_url']?.toString().trim() ?? '';
      updates['avatar_url'] = avatar.isEmpty ? null : avatar;
    }

    if (updates.isNotEmpty) {
      updates['updated_at'] = _now();
      await _db.update(
        'users',
        updates,
        where: 'id = ?',
        whereArgs: [userId],
      );
      await _audit(
        actorUserId: userId,
        action: 'profile.updated',
        resourceType: 'user',
        resourceId: userId.toString(),
      );
    }

    return getUser(userId);
  }

  Future<void> changePassword(
    int userId,
    String currentPassword,
    String newPassword,
  ) async {
    _validatePassword(newPassword);
    final rows = await _db.query(
      'users',
      columns: const ['password_hash'],
      where: 'id = ?',
      whereArgs: [userId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw const LocalAppException('This account is unavailable.');
    }

    final valid = await _crypto.verifyPassword(
      currentPassword,
      rows.first['password_hash'] as String,
    );
    if (!valid) {
      throw const LocalAppException('Current password is incorrect.');
    }

    await _db.update(
      'users',
      {
        'password_hash': await _crypto.hashPassword(newPassword),
        'updated_at': _now(),
      },
      where: 'id = ?',
      whereArgs: [userId],
    );
    await _audit(
      actorUserId: userId,
      action: 'password.changed',
      resourceType: 'user',
      resourceId: userId.toString(),
    );
  }

  Future<Map<String, dynamic>> enrollmentStatus(int userId) async {
    final rows = await _db.query(
      'enrollment_templates',
      where: 'user_id = ?',
      whereArgs: [userId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return {
        'enrolled': false,
        'reference_count': 0,
        'quality_score': null,
        'updated_at': null,
      };
    }
    final row = rows.first;
    return {
      'enrolled': true,
      'reference_count': row['reference_count'],
      'quality_score': row['quality_score'],
      'updated_at': row['updated_at'],
    };
  }

  Future<Map<String, dynamic>> enroll(
    int userId,
    List<dynamic> rawReferences,
  ) async {
    if (rawReferences.length != 5) {
      throw const LocalAppException(
        'Exactly five reference signatures are required.',
      );
    }

    final processed = <SignatureFeatureResult>[];
    for (final item in rawReferences) {
      processed.add(
        SignaturePreprocessor.preprocess(
          Map<String, dynamic>.from(item as Map),
        ),
      );
    }

    final quality = processed
            .map((item) => item.qualityScore)
            .fold<double>(0.0, (sum, value) => sum + value) /
        processed.length;

    if (quality < 0.38) {
      throw const LocalAppException(
        'Signature quality is too low. Sign naturally and use a larger area.',
      );
    }

    final sequences = processed.map((item) => item.sequence).toList();
    final encrypted = await _crypto.encryptBytes(_packSequences(sequences));
    final now = _now();

    final existing = await _db.query(
      'enrollment_templates',
      columns: const ['id'],
      where: 'user_id = ?',
      whereArgs: [userId],
      limit: 1,
    );

    if (existing.isEmpty) {
      await _db.insert('enrollment_templates', {
        'user_id': userId,
        'encrypted_sequences': encrypted,
        'reference_count': 5,
        'quality_score': quality,
        'created_at': now,
        'updated_at': now,
      });
    } else {
      await _db.update(
        'enrollment_templates',
        {
          'encrypted_sequences': encrypted,
          'reference_count': 5,
          'quality_score': quality,
          'updated_at': now,
        },
        where: 'user_id = ?',
        whereArgs: [userId],
      );
    }

    await _audit(
      actorUserId: userId,
      action: 'signature.enrolled',
      resourceType: 'enrollment',
      resourceId: userId.toString(),
      details: {'quality': quality},
    );

    return {
      'enrolled': true,
      'reference_count': 5,
      'quality_score': quality,
      'updated_at': now,
    };
  }

  Future<void> deleteEnrollment(int userId) async {
    await _db.delete(
      'enrollment_templates',
      where: 'user_id = ?',
      whereArgs: [userId],
    );
    await _audit(
      actorUserId: userId,
      action: 'signature.enrollment_deleted',
      resourceType: 'enrollment',
      resourceId: userId.toString(),
    );
  }

  Future<Map<String, dynamic>> verifySignature(
    int userId,
    Map<String, dynamic> signature,
    String mode,
  ) async {
    if (mode != 'balanced' && mode != 'secure') {
      throw const LocalAppException('The verification mode is invalid.');
    }

    final rows = await _db.query(
      'enrollment_templates',
      columns: const ['encrypted_sequences'],
      where: 'user_id = ?',
      whereArgs: [userId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw const LocalAppException(
        'Complete signature enrollment before verification.',
        code: 409,
      );
    }

    final query = SignaturePreprocessor.preprocess(signature);
    final encrypted = rows.first['encrypted_sequences'] as Uint8List;
    final clear = await _crypto.decryptBytes(encrypted);
    final references = _unpackSequences(clear);

    final output = await model.verify(
      references: references,
      query: query.sequence,
    );
    final threshold = model.thresholds[mode]!;
    final genuine = output.probability >= threshold;
    final now = _now();
    final requestId = _randomId();

    final eventId = await _db.insert('verification_events', {
      'user_id': userId,
      'mode': mode,
      'score': output.probability,
      'calibrated_logit': output.calibratedLogit,
      'cosine_similarity': output.cosineSimilarity,
      'threshold_value': threshold,
      'decision': genuine ? 'genuine' : 'forged',
      'quality_score': query.qualityScore,
      'request_id': requestId,
      'created_at': now,
    });

    await _audit(
      actorUserId: userId,
      action: 'signature.verified',
      resourceType: 'verification',
      resourceId: eventId.toString(),
      details: {
        'decision': genuine ? 'genuine' : 'forged',
        'probability': output.probability,
        'mode': mode,
      },
    );

    return {
      'id': eventId,
      'genuine': genuine,
      'decision': genuine ? 'genuine' : 'forged',
      'probability': output.probability,
      'calibrated_logit': output.calibratedLogit,
      'cosine_similarity': output.cosineSimilarity,
      'threshold': threshold,
      'mode': mode,
      'quality_score': query.qualityScore,
      'request_id': requestId,
      'created_at': now,
    };
  }

  Future<List<Map<String, dynamic>>> verificationHistory(
    int userId, {
    int limit = 50,
  }) async {
    final rows = await _db.query(
      'verification_events',
      where: 'user_id = ?',
      whereArgs: [userId],
      orderBy: 'created_at DESC',
      limit: limit.clamp(1, 200).toInt(),
    );
    return rows.map(_serializeVerification).toList(growable: false);
  }

  Future<Map<String, dynamic>> uploadDocument({
    required int userId,
    required String fileName,
    required Uint8List bytes,
    String? mimeType,
  }) async {
    if (bytes.isEmpty) {
      throw const LocalAppException('The selected file is empty.');
    }
    if (bytes.length > 25 * 1024 * 1024) {
      throw const LocalAppException('The selected file exceeds the 25 MB limit.');
    }

    final root = await getApplicationDocumentsDirectory();
    final documentsDirectory = Directory(
      path.join(root.path, 'signatrust_encrypted_documents'),
    );
    await documentsDirectory.create(recursive: true);

    final storedName = '${_randomId()}.bin';
    final destination = File(path.join(documentsDirectory.path, storedName));
    final encrypted = await _crypto.encryptBytes(bytes);
    await destination.writeAsBytes(encrypted, flush: true);

    final now = _now();
    final id = await _db.insert('documents', {
      'owner_id': userId,
      'original_name': fileName.length > 255 ? fileName.substring(0, 255) : fileName,
      'stored_name': storedName,
      'mime_type': mimeType ?? _inferMimeType(fileName),
      'size_bytes': bytes.length,
      'encrypted_path': destination.path,
      'is_shared_with_admin': 0,
      'status': 'uploaded',
      'created_at': now,
    });

    await _audit(
      actorUserId: userId,
      action: 'document.uploaded',
      resourceType: 'document',
      resourceId: id.toString(),
      details: {'name': fileName},
    );

    return _documentById(id);
  }

  Future<List<Map<String, dynamic>>> listDocuments(int userId) async {
    final rows = await _db.query(
      'documents',
      where: 'owner_id = ?',
      whereArgs: [userId],
      orderBy: 'created_at DESC',
    );
    return rows.map(_serializeDocument).toList(growable: false);
  }

  Future<Map<String, dynamic>> signDocument(
    int userId,
    int documentId,
    Map<String, dynamic> signature,
  ) async {
    final document = await _ownedDocument(userId, documentId);
    final verification = await verifySignature(
      userId,
      signature,
      'balanced',
    );

    if (verification['genuine'] != true) {
      throw const LocalAppException(
        'The signature was not accepted. Please sign again naturally.',
      );
    }

    final originalBytes = await _decryptFile(
      document['encrypted_path'] as String,
    );
    final signatureBytes = await _renderSignaturePng(signature);
    final signedAt = _now();
    final previewBytes = await _renderSignedDocumentPreview(
      originalName: document['original_name'] as String,
      mimeType: document['mime_type'] as String,
      originalBytes: originalBytes,
      signatureBytes: signatureBytes,
      signedAt: signedAt,
      probability: (verification['probability'] as num).toDouble(),
    );

    final root = await getApplicationDocumentsDirectory();
    final signedDirectory = Directory(
      path.join(root.path, 'signatrust_signed_documents'),
    );
    await signedDirectory.create(recursive: true);

    final previewPath = path.join(
      signedDirectory.path,
      '${_randomId()}_signed_preview.bin',
    );
    final signaturePath = path.join(
      signedDirectory.path,
      '${_randomId()}_signature.bin',
    );

    await _deleteFileIfPresent(document['signed_preview_path'] as String?);
    await _deleteFileIfPresent(document['signature_path'] as String?);

    await File(previewPath).writeAsBytes(
      await _crypto.encryptBytes(previewBytes),
      flush: true,
    );
    await File(signaturePath).writeAsBytes(
      await _crypto.encryptBytes(signatureBytes),
      flush: true,
    );

    await _db.update(
      'documents',
      {
        'status': 'signed',
        'signed_preview_path': previewPath,
        'signature_path': signaturePath,
        'signed_at': signedAt,
        'signature_verification_id': verification['id'],
        'signature_probability': verification['probability'],
        'signature_decision': verification['decision'],
      },
      where: 'id = ? AND owner_id = ?',
      whereArgs: [documentId, userId],
    );

    await _audit(
      actorUserId: userId,
      action: 'document.signed',
      resourceType: 'document',
      resourceId: documentId.toString(),
      details: {
        'name': document['original_name'],
        'verification_id': verification['id'],
        'probability': verification['probability'],
      },
    );

    return _documentById(documentId);
  }

  Future<Uint8List> readDocumentOriginal(
    int requesterId,
    int documentId, {
    bool administrator = false,
  }) async {
    final document = await _authorizedDocument(
      requesterId,
      documentId,
      administrator: administrator,
    );
    return _decryptFile(document['encrypted_path'] as String);
  }

  Future<Uint8List> readSignedDocumentPreview(
    int requesterId,
    int documentId, {
    bool administrator = false,
  }) async {
    final document = await _authorizedDocument(
      requesterId,
      documentId,
      administrator: administrator,
    );
    final previewPath = document['signed_preview_path'] as String?;
    if (previewPath == null || previewPath.isEmpty) {
      throw const LocalAppException('This document has not been signed yet.');
    }
    return _decryptFile(previewPath);
  }

  Future<Map<String, dynamic>> setDocumentSharing(
    int userId,
    int documentId,
    bool shared,
  ) async {
    final document = await _ownedDocument(userId, documentId);
    if (shared && document['signed_at'] == null) {
      throw const LocalAppException(
        'Sign the document before sharing it with the administrator.',
      );
    }
    await _db.update(
      'documents',
      {'is_shared_with_admin': shared ? 1 : 0},
      where: 'id = ?',
      whereArgs: [documentId],
    );
    await _audit(
      actorUserId: userId,
      action: shared ? 'document.shared' : 'document.unshared',
      resourceType: 'document',
      resourceId: documentId.toString(),
      details: {'name': document['original_name']},
    );
    return _documentById(documentId);
  }

  Future<void> deleteDocument(int userId, int documentId) async {
    final document = await _ownedDocument(userId, documentId);
    final paths = <String?>[
      document['encrypted_path'] as String?,
      document['signed_preview_path'] as String?,
      document['signature_path'] as String?,
    ];
    for (final value in paths) {
      if (value == null || value.isEmpty) continue;
      final file = File(value);
      if (await file.exists()) await file.delete();
    }

    await _db.delete('documents', where: 'id = ?', whereArgs: [documentId]);
    await _audit(
      actorUserId: userId,
      action: 'document.deleted',
      resourceType: 'document',
      resourceId: documentId.toString(),
    );
  }

  Future<Map<String, dynamic>> adminStats(int adminId) async {
    await _requireAdmin(adminId);
    final users = Sqflite.firstIntValue(
          await _db.rawQuery('SELECT COUNT(*) FROM users'),
        ) ??
        0;
    final activeUsers = Sqflite.firstIntValue(
          await _db.rawQuery('SELECT COUNT(*) FROM users WHERE is_active = 1'),
        ) ??
        0;
    final enrolledUsers = Sqflite.firstIntValue(
          await _db.rawQuery('SELECT COUNT(*) FROM enrollment_templates'),
        ) ??
        0;
    final documents = Sqflite.firstIntValue(
          await _db.rawQuery('SELECT COUNT(*) FROM documents'),
        ) ??
        0;
    final sharedDocuments = Sqflite.firstIntValue(
          await _db.rawQuery(
            'SELECT COUNT(*) FROM documents WHERE is_shared_with_admin = 1',
          ),
        ) ??
        0;
    final signedDocuments = Sqflite.firstIntValue(
          await _db.rawQuery(
            'SELECT COUNT(*) FROM documents WHERE signed_at IS NOT NULL',
          ),
        ) ??
        0;
    final verifications = Sqflite.firstIntValue(
          await _db.rawQuery('SELECT COUNT(*) FROM verification_events'),
        ) ??
        0;
    final genuine = Sqflite.firstIntValue(
          await _db.rawQuery(
            "SELECT COUNT(*) FROM verification_events WHERE decision = 'genuine'",
          ),
        ) ??
        0;
    final forged = Sqflite.firstIntValue(
          await _db.rawQuery(
            "SELECT COUNT(*) FROM verification_events WHERE decision = 'forged'",
          ),
        ) ??
        0;

    return {
      'users': users,
      'active_users': activeUsers,
      'enrolled_users': enrolledUsers,
      'documents': documents,
      'shared_documents': sharedDocuments,
      'signed_documents': signedDocuments,
      'verifications': verifications,
      'genuine_decisions': genuine,
      'forged_decisions': forged,
      'model_ready': model.ready,
    };
  }

  Future<List<Map<String, dynamic>>> adminUsers(int adminId) async {
    await _requireAdmin(adminId);
    final rows = await _db.rawQuery('''
      SELECT
        u.*,
        CASE WHEN e.id IS NULL THEN 0 ELSE 1 END AS has_enrollment
      FROM users u
      LEFT JOIN enrollment_templates e ON e.user_id = u.id
      ORDER BY u.created_at DESC
    ''');
    return rows.map(_serializeUser).toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> adminSharedDocuments(int adminId) async {
    await _requireAdmin(adminId);
    final rows = await _db.rawQuery('''
      SELECT
        d.*,
        u.full_name AS owner_name,
        u.email AS owner_email
      FROM documents d
      INNER JOIN users u ON u.id = d.owner_id
      WHERE d.is_shared_with_admin = 1
        AND d.signed_at IS NOT NULL
      ORDER BY d.signed_at DESC, d.created_at DESC
    ''');
    return rows.map(_serializeDocument).toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> adminVerifications(int adminId) async {
    await _requireAdmin(adminId);
    final rows = await _db.query(
      'verification_events',
      orderBy: 'created_at DESC',
      limit: 500,
    );
    return rows.map(_serializeVerification).toList(growable: false);
  }

  Future<void> setUserActive(
    int adminId,
    int userId,
    bool active,
  ) async {
    await _requireAdmin(adminId);
    if (adminId == userId && !active) {
      throw const LocalAppException(
        'You cannot deactivate your own administrator account.',
      );
    }

    final changed = await _db.update(
      'users',
      {'is_active': active ? 1 : 0, 'updated_at': _now()},
      where: 'id = ?',
      whereArgs: [userId],
    );
    if (changed == 0) {
      throw const LocalAppException('User was not found.');
    }

    await _audit(
      actorUserId: adminId,
      action: active ? 'admin.user_activated' : 'admin.user_deactivated',
      resourceType: 'user',
      resourceId: userId.toString(),
    );
  }

  Future<void> _seedAdministrator() async {
    final existing = await _db.query(
      'users',
      columns: const ['id'],
      where: 'email = ?',
      whereArgs: ['admin@signatrust.local'],
      limit: 1,
    );
    if (existing.isNotEmpty) return;

    final now = _now();
    await _db.insert('users', {
      'email': 'admin@signatrust.local',
      'full_name': 'System Administrator',
      'phone': null,
      'avatar_url': null,
      'password_hash': await _crypto.hashPassword('ChangeMe!2026'),
      'role': 'admin',
      'is_active': 1,
      'accepted_terms_at': now,
      'accepted_privacy_at': now,
      'created_at': now,
      'updated_at': now,
    });
  }

  Future<Map<String, Object?>> _authorizedDocument(
    int requesterId,
    int documentId, {
    required bool administrator,
  }) async {
    if (!administrator) {
      return _ownedDocument(requesterId, documentId);
    }

    await _requireAdmin(requesterId);
    final rows = await _db.query(
      'documents',
      where: 'id = ? AND is_shared_with_admin = 1 AND signed_at IS NOT NULL',
      whereArgs: [documentId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw const LocalAppException(
        'The shared signed document was not found.',
      );
    }
    return rows.first;
  }

  Future<Uint8List> _decryptFile(String encryptedPath) async {
    final file = File(encryptedPath);
    if (!await file.exists()) {
      throw const LocalAppException('The encrypted document file is missing.');
    }
    final encrypted = await file.readAsBytes();
    return _crypto.decryptBytes(encrypted);
  }

  Future<void> _deleteFileIfPresent(String? filePath) async {
    if (filePath == null || filePath.isEmpty) return;
    final file = File(filePath);
    if (await file.exists()) await file.delete();
  }

  Future<Uint8List> _renderSignaturePng(
    Map<String, dynamic> signature,
  ) async {
    final rawPoints = signature['points'];
    if (rawPoints is! List || rawPoints.length < 2) {
      throw const LocalAppException('The captured signature is invalid.');
    }

    final points = <ui.Offset>[];
    for (final item in rawPoints) {
      if (item is! Map) continue;
      final x = (item['x'] as num?)?.toDouble();
      final y = (item['y'] as num?)?.toDouble();
      if (x == null || y == null || !x.isFinite || !y.isFinite) continue;
      points.add(ui.Offset(x, y));
    }
    if (points.length < 2) {
      throw const LocalAppException('The captured signature is invalid.');
    }

    var minX = points.first.dx;
    var maxX = points.first.dx;
    var minY = points.first.dy;
    var maxY = points.first.dy;
    for (final point in points.skip(1)) {
      minX = min(minX, point.dx);
      maxX = max(maxX, point.dx);
      minY = min(minY, point.dy);
      maxY = max(maxY, point.dy);
    }

    const width = 720.0;
    const height = 280.0;
    const padding = 24.0;
    final sourceWidth = max(maxX - minX, 1.0);
    final sourceHeight = max(maxY - minY, 1.0);
    final scale = min(
      (width - padding * 2) / sourceWidth,
      (height - padding * 2) / sourceHeight,
    );
    final offsetX = (width - sourceWidth * scale) / 2;
    final offsetY = (height - sourceHeight * scale) / 2;

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final paint = ui.Paint()
      ..color = const ui.Color(0xFF173B57)
      ..strokeWidth = 7
      ..strokeCap = ui.StrokeCap.round
      ..strokeJoin = ui.StrokeJoin.round
      ..style = ui.PaintingStyle.stroke;

    final drawing = ui.Path();
    final first = points.first;
    drawing.moveTo(
      offsetX + (first.dx - minX) * scale,
      offsetY + (first.dy - minY) * scale,
    );
    for (final point in points.skip(1)) {
      drawing.lineTo(
        offsetX + (point.dx - minX) * scale,
        offsetY + (point.dy - minY) * scale,
      );
    }
    canvas.drawPath(drawing, paint);

    final picture = recorder.endRecording();
    final image = await picture.toImage(width.toInt(), height.toInt());
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null) {
      throw const LocalAppException('The signature image could not be created.');
    }
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  Future<Uint8List> _renderSignedDocumentPreview({
    required String originalName,
    required String mimeType,
    required Uint8List originalBytes,
    required Uint8List signatureBytes,
    required String signedAt,
    required double probability,
  }) async {
    const width = 1240.0;
    const height = 1754.0;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);

    canvas.drawRect(
      const ui.Rect.fromLTWH(0, 0, width, height),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );

    canvas.drawRect(
      const ui.Rect.fromLTWH(0, 0, width, 22),
      ui.Paint()..color = const ui.Color(0xFF148F8B),
    );

    _drawParagraph(
      canvas,
      originalName,
      const ui.Rect.fromLTWH(68, 58, 1104, 72),
      fontSize: 34,
      fontWeight: ui.FontWeight.w700,
      color: const ui.Color(0xFF17232D),
      maxLines: 1,
    );
    _drawParagraph(
      canvas,
      'Electronically signed document',
      const ui.Rect.fromLTWH(68, 125, 1104, 48),
      fontSize: 23,
      color: const ui.Color(0xFF6C7A86),
      maxLines: 1,
    );

    const contentRect = ui.Rect.fromLTWH(68, 205, 1104, 1085);
    canvas.drawRRect(
      ui.RRect.fromRectAndRadius(contentRect, const ui.Radius.circular(22)),
      ui.Paint()..color = const ui.Color(0xFFF5F7FA),
    );

    var contentDrawn = false;
    if (mimeType.startsWith('image/')) {
      ui.Image? originalImage;
      try {
        originalImage = await _decodeImage(originalBytes);
        _drawImageContained(canvas, originalImage, contentRect.deflate(30));
        contentDrawn = true;
      } catch (_) {
        contentDrawn = false;
      } finally {
        originalImage?.dispose();
      }
    } else if (mimeType == 'text/plain') {
      final text = utf8.decode(originalBytes, allowMalformed: true).trim();
      if (text.isNotEmpty) {
        _drawParagraph(
          canvas,
          text.length > 6000 ? '${text.substring(0, 6000)}…' : text,
          contentRect.deflate(42),
          fontSize: 25,
          color: const ui.Color(0xFF17232D),
          maxLines: 35,
        );
        contentDrawn = true;
      }
    }

    if (!contentDrawn) {
      final iconPaint = ui.Paint()
        ..color = const ui.Color(0xFF148F8B)
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 10;
      final iconRect = ui.Rect.fromCenter(
        center: contentRect.center.translate(0, -100),
        width: 220,
        height: 280,
      );
      canvas.drawRRect(
        ui.RRect.fromRectAndRadius(iconRect, const ui.Radius.circular(20)),
        iconPaint,
      );
      canvas.drawLine(
        ui.Offset(iconRect.left + 42, iconRect.top + 90),
        ui.Offset(iconRect.right - 42, iconRect.top + 90),
        iconPaint..strokeWidth = 7,
      );
      canvas.drawLine(
        ui.Offset(iconRect.left + 42, iconRect.top + 140),
        ui.Offset(iconRect.right - 42, iconRect.top + 140),
        iconPaint,
      );
      canvas.drawLine(
        ui.Offset(iconRect.left + 42, iconRect.top + 190),
        ui.Offset(iconRect.right - 70, iconRect.top + 190),
        iconPaint,
      );
      _drawParagraph(
        canvas,
        originalName,
        ui.Rect.fromLTWH(
          contentRect.left + 70,
          contentRect.center.dy + 100,
          contentRect.width - 140,
          100,
        ),
        fontSize: 28,
        fontWeight: ui.FontWeight.w600,
        color: const ui.Color(0xFF17232D),
        textAlign: ui.TextAlign.center,
        maxLines: 2,
      );
    }

    canvas.drawLine(
      const ui.Offset(68, 1340),
      const ui.Offset(1172, 1340),
      ui.Paint()
        ..color = const ui.Color(0xFFD9E1E8)
        ..strokeWidth = 2,
    );

    final signatureImage = await _decodeImage(signatureBytes);
    _drawImageContained(
      canvas,
      signatureImage,
      const ui.Rect.fromLTWH(660, 1390, 500, 205),
    );
    signatureImage.dispose();

    _drawParagraph(
      canvas,
      'Verified electronic signature',
      const ui.Rect.fromLTWH(68, 1380, 530, 54),
      fontSize: 28,
      fontWeight: ui.FontWeight.w700,
      color: const ui.Color(0xFF16865C),
      maxLines: 1,
    );
    _drawParagraph(
      canvas,
      'Authenticity decision: Genuine',
      const ui.Rect.fromLTWH(68, 1444, 530, 46),
      fontSize: 23,
      color: const ui.Color(0xFF17232D),
      maxLines: 1,
    );
    _drawParagraph(
      canvas,
      'Confidence: ${(probability * 100).toStringAsFixed(1)}%',
      const ui.Rect.fromLTWH(68, 1494, 530, 46),
      fontSize: 23,
      color: const ui.Color(0xFF17232D),
      maxLines: 1,
    );
    final localTime = DateTime.tryParse(signedAt)?.toLocal();
    final dateText = localTime == null
        ? signedAt
        : '${localTime.year.toString().padLeft(4, '0')}-'
            '${localTime.month.toString().padLeft(2, '0')}-'
            '${localTime.day.toString().padLeft(2, '0')} '
            '${localTime.hour.toString().padLeft(2, '0')}:'
            '${localTime.minute.toString().padLeft(2, '0')}';
    _drawParagraph(
      canvas,
      'Signed at: $dateText',
      const ui.Rect.fromLTWH(68, 1544, 530, 46),
      fontSize: 23,
      color: const ui.Color(0xFF6C7A86),
      maxLines: 1,
    );

    _drawParagraph(
      canvas,
      'Generated and protected locally by SignaTrust AI',
      const ui.Rect.fromLTWH(68, 1660, 1104, 42),
      fontSize: 20,
      color: const ui.Color(0xFF6C7A86),
      textAlign: ui.TextAlign.center,
      maxLines: 1,
    );

    final picture = recorder.endRecording();
    final image = await picture.toImage(width.toInt(), height.toInt());
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null) {
      throw const LocalAppException('The signed document could not be created.');
    }
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  Future<ui.Image> _decodeImage(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      return frame.image;
    } finally {
      codec.dispose();
    }
  }

  void _drawImageContained(ui.Canvas canvas, ui.Image image, ui.Rect area) {
    final imageWidth = image.width.toDouble();
    final imageHeight = image.height.toDouble();
    final scale = min(area.width / imageWidth, area.height / imageHeight);
    final targetWidth = imageWidth * scale;
    final targetHeight = imageHeight * scale;
    final destination = ui.Rect.fromLTWH(
      area.left + (area.width - targetWidth) / 2,
      area.top + (area.height - targetHeight) / 2,
      targetWidth,
      targetHeight,
    );
    canvas.drawImageRect(
      image,
      ui.Rect.fromLTWH(0, 0, imageWidth, imageHeight),
      destination,
      ui.Paint()..filterQuality = ui.FilterQuality.high,
    );
  }

  void _drawParagraph(
    ui.Canvas canvas,
    String text,
    ui.Rect area, {
    required double fontSize,
    required ui.Color color,
    ui.FontWeight fontWeight = ui.FontWeight.normal,
    ui.TextAlign textAlign = ui.TextAlign.left,
    int? maxLines,
  }) {
    final builder = ui.ParagraphBuilder(
      ui.ParagraphStyle(
        textAlign: textAlign,
        textDirection: ui.TextDirection.ltr,
        maxLines: maxLines,
        ellipsis: maxLines == null ? null : '…',
      ),
    )..pushStyle(
        ui.TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: fontWeight,
          height: 1.35,
        ),
      );
    builder.addText(text);
    final paragraph = builder.build()
      ..layout(ui.ParagraphConstraints(width: area.width));
    canvas.drawParagraph(paragraph, area.topLeft);
  }

  Future<Map<String, Object?>> _ownedDocument(
    int userId,
    int documentId,
  ) async {
    final rows = await _db.query(
      'documents',
      where: 'id = ? AND owner_id = ?',
      whereArgs: [documentId, userId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw const LocalAppException('Document was not found.');
    }
    return rows.first;
  }

  Future<Map<String, dynamic>> _documentById(int documentId) async {
    final rows = await _db.query(
      'documents',
      where: 'id = ?',
      whereArgs: [documentId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw const LocalAppException('Document was not found.');
    }
    return _serializeDocument(rows.first);
  }

  Future<void> _requireAdmin(int userId) async {
    final rows = await _db.query(
      'users',
      columns: const ['role', 'is_active'],
      where: 'id = ?',
      whereArgs: [userId],
      limit: 1,
    );
    if (rows.isEmpty ||
        rows.first['role'] != 'admin' ||
        rows.first['is_active'] != 1) {
      throw const LocalAppException(
        'Administrator access is required.',
        code: 403,
      );
    }
  }

  Map<String, dynamic> _serializeUser(Map<String, Object?> row) {
    return {
      'id': row['id'],
      'email': row['email'],
      'full_name': row['full_name'],
      'phone': row['phone'],
      'avatar_url': row['avatar_url'],
      'role': row['role'],
      'is_active': row['is_active'] == 1,
      'created_at': row['created_at'],
      'has_enrollment': row['has_enrollment'] == 1,
    };
  }

  Map<String, dynamic> _serializeVerification(Map<String, Object?> row) {
    return {
      'id': row['id'],
      'mode': row['mode'],
      'score': row['score'],
      'calibrated_logit': row['calibrated_logit'],
      'cosine_similarity': row['cosine_similarity'],
      'threshold': row['threshold_value'],
      'decision': row['decision'],
      'quality_score': row['quality_score'],
      'request_id': row['request_id'],
      'created_at': row['created_at'],
    };
  }

  Map<String, dynamic> _serializeDocument(Map<String, Object?> row) {
    final signedAt = row['signed_at'] as String?;
    return {
      'id': row['id'],
      'owner_id': row['owner_id'],
      'owner_name': row['owner_name'],
      'owner_email': row['owner_email'],
      'original_name': row['original_name'],
      'mime_type': row['mime_type'],
      'size_bytes': row['size_bytes'],
      'is_shared_with_admin': row['is_shared_with_admin'] == 1,
      'is_signed': signedAt != null && signedAt.isNotEmpty,
      'status': row['status'],
      'signed_at': signedAt,
      'signature_verification_id': row['signature_verification_id'],
      'signature_probability': row['signature_probability'],
      'signature_decision': row['signature_decision'],
      'created_at': row['created_at'],
    };
  }

  Uint8List _packSequences(List<List<List<double>>> sequences) {
    final count = 5 * SignaturePreprocessor.sequenceLength * SignaturePreprocessor.inputFeatures;
    final data = ByteData(count * 4);
    var offset = 0;
    for (final sequence in sequences) {
      for (final row in sequence) {
        for (final value in row) {
          data.setFloat32(offset, value, Endian.little);
          offset += 4;
        }
      }
    }
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  List<List<List<double>>> _unpackSequences(Uint8List bytes) {
    final expectedValues = 5 * SignaturePreprocessor.sequenceLength * SignaturePreprocessor.inputFeatures;
    if (bytes.length != expectedValues * 4) {
      throw const LocalAppException(
        'Stored signature references are damaged or incompatible.',
      );
    }

    final data = ByteData.sublistView(bytes);
    var offset = 0;
    return List<List<List<double>>>.generate(5, (_) {
      return List<List<double>>.generate(
        SignaturePreprocessor.sequenceLength,
        (_) {
          return List<double>.generate(
            SignaturePreprocessor.inputFeatures,
            (_) {
              final value = data.getFloat32(offset, Endian.little);
              offset += 4;
              return value;
            },
            growable: false,
          );
        },
        growable: false,
      );
    }, growable: false);
  }

  Future<void> _audit({
    required int? actorUserId,
    required String action,
    required String resourceType,
    String? resourceId,
    Map<String, dynamic>? details,
  }) async {
    await _db.insert('audit_logs', {
      'actor_user_id': actorUserId,
      'action': action,
      'resource_type': resourceType,
      'resource_id': resourceId,
      'details_json': jsonEncode(details ?? const {}),
      'created_at': _now(),
    });
  }

  void _validateFullName(String value) {
    if (value.length < 2 || value.length > 120) {
      throw const LocalAppException('Enter a valid full name.');
    }
  }

  void _validateEmail(String value) {
    final expression = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');
    if (!expression.hasMatch(value)) {
      throw const LocalAppException('Enter a valid email address.');
    }
  }


  void _validatePhone(String value) {
    if (!RegExp(r'^\+?[0-9]{7,15}$').hasMatch(value)) {
      throw const LocalAppException('Enter a valid phone number.');
    }
  }

  void _validatePassword(String value) {
    if (value.length < 10 || value.length > 128) {
      throw const LocalAppException(
        'Password must contain at least 10 characters.',
      );
    }
    if (!RegExp(r'[a-z]').hasMatch(value) ||
        !RegExp(r'[A-Z]').hasMatch(value) ||
        !RegExp(r'[0-9]').hasMatch(value)) {
      throw const LocalAppException(
        'Password must include uppercase, lowercase, and a number.',
      );
    }
  }

  String _inferMimeType(String fileName) {
    final extension = path.extension(fileName).toLowerCase();
    return switch (extension) {
      '.pdf' => 'application/pdf',
      '.png' => 'image/png',
      '.jpg' || '.jpeg' => 'image/jpeg',
      '.doc' => 'application/msword',
      '.docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      '.txt' => 'text/plain',
      _ => 'application/octet-stream',
    };
  }

  String _now() => DateTime.now().toUtc().toIso8601String();

  String _randomId() {
    final random = Random.secure();
    final values = List<int>.generate(16, (_) => random.nextInt(256));
    return values.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }
}
