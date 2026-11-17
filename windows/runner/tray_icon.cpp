#include "tray_icon.h"

#include <flutter/encodable_value.h>

#include <algorithm>

#include "resource.h"

namespace {

// NOTIFYICONDATA.szTip holds at most 127 characters plus the terminator.
constexpr size_t kMaxTipChars = 127;

std::wstring TruncateTip(const std::wstring& text) {
  if (text.size() <= kMaxTipChars) return text;
  return text.substr(0, kMaxTipChars);
}

// Read a string argument out of a {"text": "..."} method-call map.
bool GetTextArg(const flutter::EncodableValue* args, std::string* out) {
  if (args == nullptr) return false;
  if (!std::holds_alternative<flutter::EncodableMap>(*args)) return false;
  const auto& map = std::get<flutter::EncodableMap>(*args);
  auto it = map.find(flutter::EncodableValue("text"));
  if (it == map.end()) return false;
  if (!std::holds_alternative<std::string>(it->second)) return false;
  *out = std::get<std::string>(it->second);
  return true;
}

// UTF-8 (what the standard method codec delivers) -> UTF-16 for Win32.
std::wstring Utf8ToWide(const std::string& text) {
  if (text.empty()) return std::wstring();
  int needed = MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, nullptr, 0);
  if (needed <= 0) return std::wstring();
  std::wstring out(static_cast<size_t>(needed), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, out.data(), needed);
  // Drop the terminator MultiByteToWideChar counted in `needed`.
  if (!out.empty() && out.back() == L'\0') out.pop_back();
  return out;
}

}  // namespace

TrayIconManager::TrayIconManager(HWND window,
                                 flutter::BinaryMessenger* messenger)
    : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "com.doimty.dpgrabber/tray",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const std::string& method = call.method_name();
        if (method == "initialize") {
          AddIcon();
          result->Success(flutter::EncodableValue(icon_added_));
        } else if (method == "setToolTip") {
          std::string text;
          if (GetTextArg(call.arguments(), &text)) {
            SetToolTip(Utf8ToWide(text));
          }
          result->Success();
        } else if (method == "showWindow") {
          ShowWindow();
          result->Success();
        } else if (method == "hideWindow") {
          HideWindow();
          result->Success();
        } else if (method == "quit") {
          // Dart has stopped the engine; close for real.
          Quit();
          result->Success();
        } else if (method == "dispose") {
          RemoveIcon();
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
}

TrayIconManager::~TrayIconManager() {
  // Unregister while the messenger is still alive (FlutterWindow
  // destroys this object before tearing down the engine).
  if (channel_) {
    channel_->SetMethodCallHandler(nullptr);
    channel_.reset();
  }
  RemoveIcon();
}

void TrayIconManager::AddIcon() {
  if (icon_added_ || window_ == nullptr) return;
  icon_data_ = {};
  icon_data_.cbSize = sizeof(icon_data_);
  icon_data_.hWnd = window_;
  icon_data_.uID = 1;
  icon_data_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  icon_data_.uCallbackMessage = kTrayMessage;
  icon_data_.hIcon = LoadIcon(GetModuleHandle(nullptr),
                              MAKEINTRESOURCE(IDI_APP_ICON));
  if (icon_data_.hIcon == nullptr) {
    icon_data_.hIcon = LoadIcon(nullptr, IDI_APPLICATION);
  }
  std::wstring tip = TruncateTip(tooltip_);
  wcsncpy_s(icon_data_.szTip, tip.c_str(), _TRUNCATE);
  icon_added_ = Shell_NotifyIconW(NIM_ADD, &icon_data_) == TRUE;
}

void TrayIconManager::RemoveIcon() {
  if (!icon_added_) return;
  Shell_NotifyIconW(NIM_DELETE, &icon_data_);
  icon_added_ = false;
}

void TrayIconManager::SetToolTip(const std::wstring& text) {
  tooltip_ = TruncateTip(text);
  if (!icon_added_) return;
  wcsncpy_s(icon_data_.szTip, tooltip_.c_str(), _TRUNCATE);
  Shell_NotifyIconW(NIM_MODIFY, &icon_data_);
}

void TrayIconManager::ShowWindow() {
  if (window_ == nullptr) return;
  if (IsIconic(window_)) {
    ::ShowWindow(window_, SW_RESTORE);
  } else {
    ::ShowWindow(window_, SW_SHOW);
  }
  SetForegroundWindow(window_);
}

void TrayIconManager::HideWindow() {
  if (window_ == nullptr) return;
  ::ShowWindow(window_, SW_HIDE);
}

void TrayIconManager::Quit() {
  quitting_ = true;
  RemoveIcon();
  if (window_ != nullptr) {
    DestroyWindow(window_);
  }
}

void TrayIconManager::OnTrayMessage(WPARAM /*wparam*/, LPARAM lparam) {
  switch (lparam) {
    case WM_LBUTTONUP:
    case WM_LBUTTONDBLCLK:
      // Single click restores the window.
      ShowWindow();
      NotifyDart("onTrayShow");
      break;
    case WM_RBUTTONUP:
      ShowPopupMenu();
      break;
    default:
      break;
  }
}

void TrayIconManager::OnMenuCommand(UINT command_id) {
  if (command_id == kMenuShow) {
    ShowWindow();
    NotifyDart("onTrayShow");
  } else if (command_id == kMenuQuit) {
    // Dart owns the shutdown (stop the engine first), so ask it.
    NotifyDart("onTrayQuit");
  }
}

void TrayIconManager::ShowPopupMenu() {
  HMENU menu = CreatePopupMenu();
  if (menu == nullptr) return;
  AppendMenuW(menu, MF_STRING, kMenuShow, L"\x663e\x793a\x7a97\x53e3");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kMenuQuit, L"\x9000\x51fa");
  POINT cursor{};
  GetCursorPos(&cursor);
  // TrackPopupMenu requires the window to be foreground first, and a
  // dummy message afterwards, or the menu will not dismiss on click.
  SetForegroundWindow(window_);
  TrackPopupMenu(menu, TPM_RIGHTBUTTON, cursor.x, cursor.y, 0, window_,
                 nullptr);
  PostMessage(window_, WM_NULL, 0, 0);
  DestroyMenu(menu);
}

void TrayIconManager::NotifyDart(const std::string& method) {
  if (channel_) {
    channel_->InvokeMethod(method, nullptr);
  }
}
