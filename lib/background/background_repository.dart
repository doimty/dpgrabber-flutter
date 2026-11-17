/// Content-addressed background image store, ported from
/// wenxi/lib/data/backgrounds.dart. The backup-carry helpers
/// (exportImages/restoreImages) are not ported — dpgrabber has no
/// config-backup system.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'background_image.dart';
import 'background_settings.dart';
import 'background_support.dart';

class BackgroundRepository {
  BackgroundRepository(Directory dataDirectory, {required this.current})
    : directory = Directory(p.join(dataDirectory.path, 'backgrounds'));

  final Directory directory;
  final BackgroundSettings Function() current;
  final _gate = AsyncGate();
  final _drafts = <Object, Set<String>>{};

  Object beginDraft() {
    final token = Object();
    _drafts[token] = {...current().ids};
    return token;
  }

  File file(String id) {
    require(validBackgroundId(id), '背景图片标识无效');
    return File(p.join(directory.path, id));
  }

  Future<BackgroundPicture> importFile(XFile source, Object draft) async {
    // A picked file can be unreadable on iOS (an iCloud photo not
    // downloaded to the device, or a Files placeholder): length() /
    // openRead() then throw a platform/IO error, not an AppException.
    // Convert it so the caller can show the real cause instead of a
    // generic banner.
    late final Uint8List bytes;
    try {
      require(
        await source.length() <= backgroundSourceMaxBytes,
        '请选择不超过 24 MB 的图片',
      );
      // Cap reads as well as metadata; some Android document providers omit size.
      final builder = BytesBuilder(copy: false);
      await for (final chunk in source.openRead()) {
        require(
          builder.length + chunk.length <= backgroundSourceMaxBytes,
          '请选择不超过 24 MB 的图片',
        );
        builder.add(chunk);
      }
      bytes = builder.takeBytes();
    } on AppException {
      rethrow;
    } catch (e) {
      throw AppException('无法读取这张图片文件：$e，请换一张已下载到本机的图片');
    }
    final processed = await prepareBackgroundImage(bytes);
    return _save(processed, draft);
  }

  Future<BackgroundPicture> _save(Uint8List bytes, Object draft) =>
      _gate.run(() async {
        require(_drafts.containsKey(draft), '已取消背景设置');
        final (width, height) = backgroundPngSize(bytes);
        final id = '${sha256.convert(bytes)}.png';
        await directory.create(recursive: true);
        final target = file(id);
        final intact =
            await target.exists() &&
            await target.length() == bytes.length &&
            '${sha256.convert(await target.readAsBytes())}.png' == id;
        if (!intact) {
          final pending = File('${target.path}.tmp');
          try {
            await pending.writeAsBytes(bytes, flush: true);
            await pending.rename(target.path);
          } finally {
            if (await pending.exists()) await pending.delete();
          }
        }
        // The user may close the editor while the file write is finishing.
        _drafts[draft]?.add(id);
        return BackgroundPicture(id: id, width: width, height: height);
      });

  Future<void> endDraft(Object token) {
    _drafts.remove(token);
    return collectUnused();
  }

  Future<void> collectUnused() => _gate.run(() async {
    final keep = {...current().ids, for (final ids in _drafts.values) ...ids};
    try {
      if (!await directory.exists()) return;
      // Only our content-addressed files are eligible; never follow directories.
      await for (final entry in directory.list(followLinks: false)) {
        final name = p.basename(entry.path);
        if (entry is File && validBackgroundId(name) && !keep.contains(name)) {
          try {
            await entry.delete();
          } on FileSystemException {
            /* Retry next edit. */
          }
        }
      }
    } on FileSystemException {
      /* Cleanup must not interrupt applying a theme. */
    }
  });
}

/// Persisted [BackgroundSettings] + change notifier. Settings live in
/// `backgrounds/settings.json` under the app directory; wallpaper files
/// are content-addressed PNGs in the same folder.
class BackgroundController extends ChangeNotifier {
  BackgroundController(Directory appDir)
    : _settingsFile = File(
        p.join(appDir.path, 'backgrounds', 'settings.json'),
      ) {
    repository = BackgroundRepository(appDir, current: () => settings);
  }

  late final BackgroundRepository repository;
  final File _settingsFile;
  BackgroundSettings settings = const BackgroundSettings();
  bool _loaded = false;

  Future<void> load() async {
    try {
      if (await _settingsFile.exists()) {
        final decoded = jsonDecode(await _settingsFile.readAsString());
        if (decoded is Map) {
          settings = BackgroundSettings.fromJson(
            decoded.cast<String, dynamic>(),
          );
        }
      }
    } catch (_) {
      // Corrupt settings fall back to defaults; files stay for re-selection.
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    if (!_loaded) return;
    try {
      await _settingsFile.parent.create(recursive: true);
      await _settingsFile.writeAsString(jsonEncode(settings.toJson()));
    } on FileSystemException {
      /* Persistence failures surface on the next load. */
    }
  }

  Future<BackgroundPicture> importImage(XFile source, {required bool dark}) async {
    final draft = repository.beginDraft();
    try {
      final picture = await repository.importFile(source, draft);
      settings = settings.withPicture(picture, dark: dark);
      notifyListeners();
      await _persist();
      return picture;
    } finally {
      await repository.endDraft(draft);
    }
  }

  Future<void> clearPicture({required bool dark}) async {
    settings = settings.withPicture(null, dark: dark);
    notifyListeners();
    await _persist();
    await repository.collectUnused();
  }

  Future<void> update({
    double? brightness,
    double? blur,
    double? cardOpacity,
  }) async {
    settings = settings.copyWith(
      brightness: brightness,
      blur: blur,
      cardOpacity: cardOpacity,
    );
    notifyListeners();
    await _persist();
  }
}
