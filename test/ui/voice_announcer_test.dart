import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dpgrabber/ui/voice_announcer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('flutter_tts');
  final calls = <MethodCall>[];
  TargetPlatform? previousPlatform;

  setUp(() {
    previousPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return 1;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = previousPlatform;
  });

  test('keeps the shared audio session active across TTS completion', () async {
    final announcer = VoiceAnnouncer();

    await announcer.speak('first');
    await announcer.speak('second');

    final autoStopCalls = calls
        .where((call) => call.method == 'autoStopSharedSession')
        .toList();
    expect(autoStopCalls, hasLength(1));
    expect(autoStopCalls.single.arguments, isFalse);
    expect(
      calls.indexWhere((call) => call.method == 'autoStopSharedSession'),
      lessThan(calls.indexWhere((call) => call.method == 'speak')),
    );
    expect(calls.where((call) => call.method == 'speak'), hasLength(2));
  });
}
