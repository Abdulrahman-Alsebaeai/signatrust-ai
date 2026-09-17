import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class LocalCryptoService {
  LocalCryptoService._();

  static final instance = LocalCryptoService._();

  static const _masterKeyStorageKey = 'signatrust.local.master_key.v1';
  static const _passwordVersion = 'argon2id-v1';

  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  final AesGcm _cipher = AesGcm.with256bits();
  final Argon2id _passwordKdf = Argon2id(
    memory: 65536,
    parallelism: 2,
    iterations: 3,
    hashLength: 32,
  );

  SecretKey? _masterKey;

  Future<void> initialize() async {
    if (_masterKey != null) return;

    final encoded = await _secureStorage.read(key: _masterKeyStorageKey);
    if (encoded != null && encoded.isNotEmpty) {
      _masterKey = SecretKey(base64Decode(encoded));
      return;
    }

    final key = await _cipher.newSecretKey();
    final bytes = await key.extractBytes();
    await _secureStorage.write(
      key: _masterKeyStorageKey,
      value: base64Encode(bytes),
    );
    _masterKey = SecretKey(bytes);
  }

  Future<Uint8List> encryptBytes(List<int> clearBytes) async {
    await initialize();
    final box = await _cipher.encrypt(
      clearBytes,
      secretKey: _masterKey!,
    );
    return box.concatenation();
  }

  Future<Uint8List> decryptBytes(List<int> encryptedBytes) async {
    await initialize();
    final box = SecretBox.fromConcatenation(
      encryptedBytes,
      nonceLength: _cipher.nonceLength,
      macLength: _cipher.macAlgorithm.macLength,
      copy: false,
    );
    final clear = await _cipher.decrypt(
      box,
      secretKey: _masterKey!,
    );
    return Uint8List.fromList(clear);
  }

  Future<String> hashPassword(String password) async {
    final salt = _secureRandomBytes(16);
    final derived = await _passwordKdf.deriveKeyFromPassword(
      password: password,
      nonce: salt,
    );
    final hash = await derived.extractBytes();
    return '$_passwordVersion\$${base64Encode(salt)}\$${base64Encode(hash)}';
  }

  Future<bool> verifyPassword(String password, String encodedHash) async {
    final parts = encodedHash.split(r'$');
    if (parts.length != 3 || parts[0] != _passwordVersion) return false;

    try {
      final salt = base64Decode(parts[1]);
      final expected = base64Decode(parts[2]);
      final derived = await _passwordKdf.deriveKeyFromPassword(
        password: password,
        nonce: salt,
      );
      final actual = await derived.extractBytes();
      return _constantTimeEquals(actual, expected);
    } catch (_) {
      return false;
    }
  }

  Uint8List _secureRandomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }

  bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var index = 0; index < a.length; index++) {
      difference |= a[index] ^ b[index];
    }
    return difference == 0;
  }
}
