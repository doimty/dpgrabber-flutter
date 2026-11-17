/// Hex/Base64 conversion and AES-CBC decryption (PORTING_CONTRACT §5).
///
/// Only decrypts responses; requests are never encrypted. Key length
/// selects the variant: 16 bytes -> AES-128, 32 bytes -> AES-256.
/// Uses `pointycastle` (platform AES); the pure-Swift AES table
/// implementation from the iOS snapshot is NOT ported.
///
/// The key/IV constants in §5 (and in `config.dart` defaults) are the
/// protocol constants from PROTOCOL.md §4 — the only key material that
/// may be copied verbatim. Never put a phone number, password or token
/// in this file.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart';

/// Hex string -> bytes. Throws [FormatException] on empty / odd-length /
/// non-hex input.
List<int> hexDecode(String text) {
  final cleaned = text.trim().toLowerCase();
  if (cleaned.isEmpty || cleaned.length.isOdd) {
    throw const FormatException('bad hex string');
  }
  final out = <int>[];
  for (var i = 0; i < cleaned.length; i += 2) {
    final byte = int.tryParse(cleaned.substring(i, i + 2), radix: 16);
    if (byte == null) throw const FormatException('bad hex string');
    out.add(byte);
  }
  return out;
}

/// Validate a key/IV hex pair: key decodes to 16 or 32 bytes, IV to
/// 16 bytes. Throws [FormatException] otherwise.
void validateKeyIv(String keyHex, String ivHex) {
  final key = hexDecode(keyHex);
  if (key.length != 16 && key.length != 32) {
    throw const FormatException('AES key must be 16 or 32 bytes');
  }
  final iv = hexDecode(ivHex);
  if (iv.length != 16) {
    throw const FormatException('AES IV must be 16 bytes');
  }
}

/// Base64 ciphertext -> plaintext bytes with AES-CBC + PKCS#7.
///
/// Throws [FormatException] on bad Base64 / bad key-IV sizes /
/// ciphertext not a multiple of 16, and [ArgumentError] (from
/// pointycastle) on bad padding / wrong key.
List<int> aesDecryptB64(String payloadB64, String keyHex, String ivHex) {
  final key = hexDecode(keyHex);
  final iv = hexDecode(ivHex);
  if (key.length != 16 && key.length != 32) {
    throw const FormatException('AES key must be 16 or 32 bytes');
  }
  if (iv.length != 16) {
    throw const FormatException('AES IV must be 16 bytes');
  }
  late final Uint8List cipherBytes;
  try {
    cipherBytes = base64Decode(payloadB64.trim());
  } on FormatException catch (e) {
    throw FormatException('payload is not valid Base64: $e');
  }
  if (cipherBytes.isEmpty || cipherBytes.length % 16 != 0) {
    throw const FormatException('ciphertext length is not a multiple of 16');
  }
  final cipher = PaddedBlockCipherImpl(
    PKCS7Padding(),
    CBCBlockCipher(AESEngine()),
  );
  cipher.init(
    false,
    PaddedBlockCipherParameters(
      ParametersWithIV(KeyParameter(Uint8List.fromList(key)),
          Uint8List.fromList(iv)),
      null,
    ),
  );
  return cipher.process(cipherBytes);
}

/// Test helper only: plaintext -> Base64 ciphertext (AES-CBC + PKCS#7).
String aesEncryptB64(List<int> plaintext, String keyHex, String ivHex) {
  final key = hexDecode(keyHex);
  final iv = hexDecode(ivHex);
  if (key.length != 16 && key.length != 32) {
    throw const FormatException('AES key must be 16 or 32 bytes');
  }
  if (iv.length != 16) {
    throw const FormatException('AES IV must be 16 bytes');
  }
  final cipher = PaddedBlockCipherImpl(
    PKCS7Padding(),
    CBCBlockCipher(AESEngine()),
  );
  cipher.init(
    true,
    PaddedBlockCipherParameters(
      ParametersWithIV(KeyParameter(Uint8List.fromList(key)),
          Uint8List.fromList(iv)),
      null,
    ),
  );
  return base64Encode(cipher.process(Uint8List.fromList(plaintext)));
}

/// MD5 hex digest (32 lowercase hex chars) of a UTF-8 string.
String md5Hex(String value) =>
    crypto.md5.convert(utf8.encode(value)).toString();

/// The `password` field value for the login body (§4.2, D-04, PC rule):
/// a value that is already a 32-hex digest is passed through untouched;
/// anything else is MD5-hexed first. The field name is always
/// `password`; there is no separate `password_hash` key.
String loginPasswordValue(String password) {
  final value = password.trim();
  if (RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(value)) return value;
  return md5Hex(value);
}
