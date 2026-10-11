#include "flutter_window.h"

#include <optional>
#include <flutter/standard_method_codec.h>
#include "resource.h"

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project, bool autostart, bool isolated)
    : project_(project), autostart_(autostart), isolated_(isolated) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  taskbar_created_ = RegisterWindowMessage(L"TaskbarCreated");
  background_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "dev.trackstudy/background",
      &flutter::StandardMethodCodec::GetInstance());
  background_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    // Native acceptance controls are restricted to explicit isolated data runs.
    if (isolated_ && call.method_name() == "testState") {
      DWORD bytes = 0;
      bool startup = RegGetValue(HKEY_CURRENT_USER, L"Software\\TrackStudy\\TestStartup", L"TrackStudy", RRF_RT_REG_SZ, nullptr, nullptr, &bytes) == ERROR_SUCCESS;
      result->Success(flutter::EncodableValue(flutter::EncodableMap{
        {flutter::EncodableValue("tray"), flutter::EncodableValue(tray_)},
        {flutter::EncodableValue("visible"), flutter::EncodableValue(IsWindowVisible(GetHandle()) != 0)},
        {flutter::EncodableValue("maximized"), flutter::EncodableValue(IsZoomed(GetHandle()) != 0)},
        {flutter::EncodableValue("minimized"), flutter::EncodableValue(IsIconic(GetHandle()) != 0)},
        {flutter::EncodableValue("ready"), flutter::EncodableValue(first_frame_)},
        {flutter::EncodableValue("startup"), flutter::EncodableValue(startup)}
      })); return;
    }
    if (isolated_ && call.method_name() == "testClose") { result->Success(); PostMessage(GetHandle(), WM_CLOSE, 0, 0); return; }
    if (isolated_ && call.method_name() == "testOpen") { OpenWindow(); result->Success(); return; }
    if (isolated_ && call.method_name() == "testRestore") { ShowWindow(GetHandle(), SW_RESTORE); result->Success(); return; }
    if (isolated_ && call.method_name() == "testMinimize") { ShowWindow(GetHandle(), SW_SHOWMINNOACTIVE); result->Success(); return; }
    if (isolated_ && call.method_name() == "testSync") { background_channel_->InvokeMethod("sync", nullptr); result->Success(); return; }
    if (call.method_name() != "configure") { result->NotImplemented(); return; }
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (!args) { result->Error("invalid", "Missing settings"); return; }
    auto flag = [args](const char* key) {
      auto it = args->find(flutter::EncodableValue(key));
      return it != args->end() && std::holds_alternative<bool>(it->second) && std::get<bool>(it->second);
    };
    bool background = flag("background"), startup = flag("startup");
    if (!SetTray(background)) { result->Error("tray", "Could not create system tray icon"); return; }
    if (!SetStartup(startup)) { SetTray(background_); result->Error("startup", "Could not update startup entry"); return; }
    background_ = background;
    if (!background_ && !IsWindowVisible(GetHandle()) && first_frame_) OpenWindow();
    result->Success();
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    if (!autostart_ || !background_) {
      OpenWindow();
    }
    autostart_ = false;
    first_frame_ = true;
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  SetTray(false);
  background_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == taskbar_created_ && background_) { tray_ = false; SetTray(true); }
  if (message == WM_CLOSE && background_ && tray_) { ShowWindow(hwnd, SW_HIDE); return 0; }
  if (message == WM_APP + 43) {
    if (wparam == 1) OpenWindow();
    if (wparam == 2 && background_channel_) background_channel_->InvokeMethod("sync", nullptr);
    if (wparam == 3) { background_ = false; DestroyWindow(hwnd); }
    return 0;
  }
  if (message == WM_APP + 42) {
    if (lparam == WM_LBUTTONDBLCLK) OpenWindow();
    if (lparam == WM_RBUTTONUP || lparam == WM_CONTEXTMENU) {
      HMENU menu = CreatePopupMenu();
      AppendMenu(menu, MF_STRING, 1, L"Open TrackStudy");
      AppendMenu(menu, MF_STRING, 2, L"Sync now");
      AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
      AppendMenu(menu, MF_STRING, 3, L"Quit");
      POINT point; GetCursorPos(&point); SetForegroundWindow(hwnd);
      UINT action = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, point.x, point.y, 0, hwnd, nullptr);
      DestroyMenu(menu); PostMessage(hwnd, WM_NULL, 0, 0);
      if (action != 0) PostMessage(hwnd, WM_APP + 43, action, 0);
    }
    return 0;
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

bool FlutterWindow::SetTray(bool enabled) {
  if (enabled == tray_) return true;
  NOTIFYICONDATA data{};
  data.cbSize = sizeof(data); data.hWnd = GetHandle(); data.uID = 1;
  data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  data.uCallbackMessage = WM_APP + 42;
  data.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(data.szTip, L"TrackStudy");
  if (enabled && !Shell_NotifyIcon(NIM_ADD, &data)) return false;
  if (!enabled) Shell_NotifyIcon(NIM_DELETE, &data);
  tray_ = enabled;
  return true;
}

bool FlutterWindow::SetStartup(bool enabled) {
  HKEY key;
  // Isolated acceptance runners never touch the real Windows startup entry.
  const wchar_t* path = isolated_ ? L"Software\\TrackStudy\\TestStartup" : L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
  if (RegCreateKeyEx(HKEY_CURRENT_USER, path, 0, nullptr, 0, KEY_SET_VALUE, nullptr, &key, nullptr) != ERROR_SUCCESS) return false;
  LSTATUS status;
  if (enabled) {
    wchar_t executable[32768];
    DWORD length = GetModuleFileName(nullptr, executable, 32768);
    if (length == 0 || length >= 32768) { RegCloseKey(key); return false; }
    std::wstring command = L"\"" + std::wstring(executable, length) + L"\" --autostart";
    status = RegSetValueEx(key, L"TrackStudy", 0, REG_SZ, reinterpret_cast<const BYTE*>(command.c_str()), static_cast<DWORD>((command.size()+1)*sizeof(wchar_t)));
  } else {
    status = RegDeleteValue(key, L"TrackStudy");
    if (status == ERROR_FILE_NOT_FOUND) status = ERROR_SUCCESS;
  }
  RegCloseKey(key);
  return status == ERROR_SUCCESS;
}

void FlutterWindow::OpenWindow() {
  // A normal decorated Windows maximize, including after hide/minimize.
  ShowWindow(GetHandle(), SW_MAXIMIZE);
  // The first ShowWindow can honor the launcher's show state instead (for
  // example a shortcut's "Normal window"). Enforce our state after that call.
  if (!IsWindowVisible(GetHandle()) || IsIconic(GetHandle()) || !IsZoomed(GetHandle())) {
    ShowWindow(GetHandle(), SW_MAXIMIZE);
  }
  if (!isolated_) SetForegroundWindow(GetHandle());
}
