/// Regression test: the liquid-glass shader must load.
///
/// `FragmentProgram.fromAsset` only works when the .frag is declared
/// under `flutter: shaders:` in pubspec.yaml. Listed only under
/// `assets:`, the file is bundled as plain text and loading throws —
/// LiquidGlassSurface then silently falls back to blur-only and the
/// "liquid" refraction never renders on any platform.
library;

import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('liquid glass shader loads from asset', () async {
    final program = await ui.FragmentProgram.fromAsset(
      'assets/shaders/liquid_glass.frag',
    );
    expect(program, isNotNull);
    program.fragmentShader().dispose();
  });
}
