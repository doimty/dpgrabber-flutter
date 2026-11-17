// DPGrabber Flutter — Windows system-tray icon (hand-written Win32).
//
// No tray plugin dependency: the icon, its popup menu and the
// close-button intercept are plain Win32 (`Shell_NotifyIcon`), driven
// from Dart over the `com.doimty.dpgrabber/tray` MethodChannel (see
// `lib/bridge/windows_tray.dart`). The icon is the runner's own
// `IDI_APP_ICON` (Runner.rc), so no asset file is needed.
//
// Why hand-written: tray_manager/window_manager 0.6/0.8 moved to a
// nativeapi/cnativeapi FFI stack whose Linux build hook requires
// GTK3/X11 dev packages — merely listing them in pubspec.yaml breaks
// `flutter test` on the Linux dev VM (and any Linux CI without those
// packages), including the 160 core tests. Win32 here is stable and
// has no such cost.
//
// Lifetime: created by FlutterWindow::OnCreate (after the engine
// exists) and destroyed in FlutterWindow::OnDestroy BEFORE the engine
// is torn down, so the channel handler is unregistered while the
// messenger is still alive.

#ifndef RUNNER_TRAY_ICON_H_
#define RUNNER_TRAY_ICON_H_

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <windows.h>

#include <memory>
#include <string>

class TrayIconManager {
 public:
  // |window| is the Flutter top-level window; |messenger| is the
  // engine messenger (must outlive this object).
  TrayIconManager(HWND window, flutter::BinaryMessenger* messenger);
  ~TrayIconManager();

  TrayIconManager(const TrayIconManager&) = delete;
  TrayIconManager& operator=(const TrayIconManager&) = delete;

  // Message the shell sends for tray-icon events (registered as the
  // NOTIFYICONDATA callback message).
  static constexpr UINT kTrayMessage = WM_APP + 1;
  // Popup-menu command ids.
  static constexpr UINT kMenuShow = 1;
  static constexpr UINT kMenuQuit = 2;

  bool IsActive() const { return icon_added_; }
  // True once Dart has asked for a real exit (via the `quit` method);
  // the window may then close normally instead of hiding to the tray.
  bool IsQuitting() const { return quitting_; }

  void SetToolTip(const std::wstring& text);
  void ShowWindow();
  void HideWindow();
  // Remove the icon and close the window for real.
  void Quit();

  // Call from the window proc: tray callback message / menu commands.
  void OnTrayMessage(WPARAM wparam, LPARAM lparam);
  void OnMenuCommand(UINT command_id);

 private:
  void AddIcon();
  void RemoveIcon();
  void ShowPopupMenu();
  void NotifyDart(const std::string& method);

  HWND window_ = nullptr;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  NOTIFYICONDATAW icon_data_{};
  bool icon_added_ = false;
  bool quitting_ = false;
  std::wstring tooltip_ = L"DPGrabber \x62a2\x5355\x76d1\x542c\x4e2d";
};

#endif  // RUNNER_TRAY_ICON_H_
