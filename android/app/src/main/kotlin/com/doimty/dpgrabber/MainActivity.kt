package com.doimty.dpgrabber

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts the `keep_alive` MethodChannel for [ListenService].
 *
 * Channel `com.doimty.dpgrabber/keep_alive` (same name on iOS):
 * - `start` -> start the foreground service, returns true when asked.
 * - `stop` -> stop the foreground service, returns true when asked.
 * - `isRunning` -> whether the foreground service is running.
 * - `updateNotification` {text} -> latest listen status for the
 *   persistent notification (throttled to 2 s inside the service).
 *
 * The service only holds the process alive; the Dart ListenEngine
 * does the polling. No credentials or network access here.
 */
class MainActivity : FlutterActivity() {

    companion object {
        const val CHANNEL = "com.doimty.dpgrabber/keep_alive"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        ListenService.start(this)
                        result.success(true)
                    }
                    "stop" -> {
                        ListenService.stop(this)
                        result.success(true)
                    }
                    "isRunning" -> {
                        result.success(ListenService.isRunning)
                    }
                    "updateNotification" -> {
                        val text = call.argument<String>("text") ?: ""
                        if (ListenService.isRunning) {
                            ListenService.updateNotification(this, text)
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
