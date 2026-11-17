/// Background image import tests: HEIC rejection, decode, and the
/// unreadable-file path that used to surface as a generic banner.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dpgrabber/background/background_image.dart';
import 'package:dpgrabber/background/background_repository.dart';
import 'package:dpgrabber/background/background_settings.dart';
import 'package:dpgrabber/background/background_support.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 1x1 transparent PNG.
  const png1x1 =
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

  test('HEIC bytes are rejected with an actionable message', () async {
    final heic = Uint8List.fromList([
      0, 0, 0, 24, // box size
      0x66, 0x74, 0x79, 0x70, // 'ftyp'
      0x68, 0x65, 0x69, 0x63, // 'heic'
      0, 0, 0, 0,
    ]);
    await expectLater(
      prepareBackgroundImage(heic),
      throwsA(
        isA<AppException>().having(
          (e) => e.message,
          'message',
          contains('HEIC'),
        ),
      ),
    );
  });

  test('a valid PNG decodes', () async {
    final out = await prepareBackgroundImage(base64Decode(png1x1));
    expect(out, isNotEmpty);
    expect(backgroundPngSize(out), (1, 1));
  });

  test('importFile maps an unreadable file to an AppException', () async {
    final dir = await Directory.systemTemp.createTemp('dpgrabber_bg_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final repo = BackgroundRepository(
      dir,
      current: () => const BackgroundSettings(),
    );
    final draft = repo.beginDraft();
    await expectLater(
      repo.importFile(XFile('/nonexistent/photo.jpg'), draft),
      throwsA(
        isA<AppException>().having(
          (e) => e.message,
          'message',
          contains('无法读取'),
        ),
      ),
    );
    await repo.endDraft(draft);
  });

  test('importFile accepts a valid PNG file', () async {
    final dir = await Directory.systemTemp.createTemp('dpgrabber_bg2_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final source = File('${dir.path}/source.png');
    await source.writeAsBytes(base64Decode(png1x1));
    final repo = BackgroundRepository(
      dir,
      current: () => const BackgroundSettings(),
    );
    final draft = repo.beginDraft();
    final picture = await repo.importFile(XFile(source.path), draft);
    expect(picture.width, 1);
    expect(picture.height, 1);
    await repo.endDraft(draft);
  });
}
