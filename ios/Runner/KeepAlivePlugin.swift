// DPGrabber Flutter — `keep_alive` MethodChannel plugin (iOS side).
//
// Same channel name as Android (`com.doimty.dpgrabber/keep_alive`):
// - `start` -> start the silent-audio loop, returns true.
// - `stop` -> stop the loop, returns true.
// - `isRunning` -> whether the loop is running.
// - `updateNotification` -> no-op on iOS (no persistent notification);
//   accepted so the Dart side can call it unconditionally.
//
// Registered from AppDelegate's `didInitializeImplicitFlutterEngine`
// via `engineBridge.applicationRegistrar.messenger()` (the Flutter
// 3.47 implicit-engine pattern). The shared instance is retained
// statically so the channel handler — and the audio engine — outlive
// any single call.

import Flutter
import UIKit

final class KeepAlivePlugin {
    static let channelName = "com.doimty.dpgrabber/keep_alive"

    /// Retained for the app's lifetime; the audio engine lives here.
    static let shared = KeepAlivePlugin()

    private let keepAlive = AudioKeepAlive()

    private init() {}

    func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: Self.channelName,
            binaryMessenger: messenger
        )
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self else {
                result(FlutterError(code: "UNAVAILABLE",
                                    message: "KeepAlivePlugin released",
                                    details: nil))
                return
            }
            switch call.method {
            case "start":
                self.keepAlive.start()
                result(true)
            case "stop":
                self.keepAlive.stop()
                result(true)
            case "isRunning":
                result(self.keepAlive.state == .running)
            case "updateNotification":
                // No persistent notification on iOS; accept and ignore.
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }
}
