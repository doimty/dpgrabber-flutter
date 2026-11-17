import 'dart:convert';

import 'package:dpgrabber/core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('hexDecode', () {
    test('decodes lower/upper hex', () {
      expect(hexDecode('00ff'), [0, 255]);
      expect(hexDecode('AABB'), [0xAA, 0xBB]);
    });
    test('rejects empty, odd length, non-hex', () {
      expect(() => hexDecode(''), throwsFormatException);
      expect(() => hexDecode('abc'), throwsFormatException);
      expect(() => hexDecode('zz'), throwsFormatException);
    });
  });

  group('validateKeyIv', () {
    test('accepts 16 and 32 byte keys with a 16 byte IV', () {
      validateKeyIv(ApiClient.altAesKeyHex, ApiClient.altAesIvHex);
      validateKeyIv(ApiClient.defaultAesKeyHex, ApiClient.defaultAesIvHex);
    });
    test('rejects wrong sizes', () {
      expect(
          () => validateKeyIv('00' * 8, ApiClient.defaultAesIvHex),
          throwsFormatException);
      expect(
          () => validateKeyIv(
              ApiClient.defaultAesKeyHex, '00' * 8),
          throwsFormatException);
    });
  });

  group('AES-CBC roundtrip', () {
    test('AES-256 primary pair roundtrips', () {
      const plain = '{"code":0,"msg":"ok"}';
      final enc = aesEncryptB64(
          utf8.encode(plain),
          ApiClient.defaultAesKeyHex,
          ApiClient.defaultAesIvHex);
      final dec = aesDecryptB64(
          enc, ApiClient.defaultAesKeyHex, ApiClient.defaultAesIvHex);
      expect(utf8.decode(dec), plain);
    });
    test('AES-128 alternate pair roundtrips', () {
      const plain = '{"code":0}';
      final enc = aesEncryptB64(
          utf8.encode(plain),
          ApiClient.altAesKeyHex,
          ApiClient.altAesIvHex);
      expect(
          utf8.decode(aesDecryptB64(
              enc, ApiClient.altAesKeyHex, ApiClient.altAesIvHex)),
          plain);
    });
    test('wrong key fails (bad padding)', () {
      final enc = aesEncryptB64(
          utf8.encode('{"code":0}'),
          ApiClient.defaultAesKeyHex,
          ApiClient.defaultAesIvHex);
      expect(
          () => aesDecryptB64(
              enc, ApiClient.altAesKeyHex, ApiClient.altAesIvHex),
          throwsA(anything));
    });
    test('rejects bad base64 and non-multiple-of-16 ciphertext', () {
      expect(
          () => aesDecryptB64('!!!not-base64!!!',
              ApiClient.defaultAesKeyHex, ApiClient.defaultAesIvHex),
          throwsFormatException);
      expect(
          () => aesDecryptB64(base64Encode([1, 2, 3]),
              ApiClient.defaultAesKeyHex, ApiClient.defaultAesIvHex),
          throwsFormatException);
    });
  });

  group('login password value (D-04)', () {
    test('plaintext is MD5-hexed', () {
      // md5('abc') is a well-known vector.
      expect(loginPasswordValue('abc'),
          '900150983cd24fb0d6963f7d28e17f72');
    });
    test('a 32-hex digest passes through untouched', () {
      const digest = '900150983cd24fb0d6963f7d28e17f72';
      expect(loginPasswordValue(digest), digest);
      expect(loginPasswordValue(digest.toUpperCase()),
          digest.toUpperCase());
    });
    test('md5Hex of a fake password is 32 lowercase hex', () {
      final v = loginPasswordValue('fake-password-1');
      expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(v), isTrue);
    });
  });
}
