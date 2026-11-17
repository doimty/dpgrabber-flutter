import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // DPGrabber keep-alive: silent-audio loop (AudioKeepAlive) behind
    // the `com.doimty.dpgrabber/keep_alive` MethodChannel.
    KeepAlivePlugin.shared.register(
      with: engineBridge.applicationRegistrar.messenger())
  }
}
