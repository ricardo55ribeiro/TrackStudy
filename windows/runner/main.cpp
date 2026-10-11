#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <functional>
#include <algorithm>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  std::vector<std::string> command_line_arguments = GetCommandLineArguments();
  bool autostart = std::find(command_line_arguments.begin(), command_line_arguments.end(), "--autostart") != command_line_arguments.end();
  std::wstring title = L"TrackStudy", mutex_name = L"Local\\TrackStudy.Desktop";
  bool isolated = false;
  for (const auto& arg : command_line_arguments) {
    if (arg.rfind("--data-dir=", 0) == 0) {
      isolated = true;
      auto suffix = std::to_wstring(std::hash<std::string>{}(arg));
      mutex_name += L".Test." + suffix; title += L" Test " + suffix;
    }
  }
  // One writer/UI per user session. Isolated test data has its own instance.
  HANDLE single_instance = ::CreateMutex(nullptr, TRUE, mutex_name.c_str());
  if (single_instance != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND existing = ::FindWindow(nullptr, title.c_str());
    if (existing != nullptr && !autostart) {
      DWORD process_id = 0;
      ::GetWindowThreadProcessId(existing, &process_id);
      if (!isolated) ::AllowSetForegroundWindow(process_id);
      // Use the same maximize/focus path as the tray's Open TrackStudy action.
      ::PostMessage(existing, WM_APP + 43, 1, 0);
    }
    ::CloseHandle(single_instance);
    return EXIT_SUCCESS;
  }
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");
  // Use the stable Skia path: the Impeller OpenGLES backend can fail to
  // present the first frame on some Windows graphics drivers.
  project.set_impeller_switch(flutter::ImpellerSwitch::Disabled);

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, autostart, isolated);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1040, 840);
  if (!window.Create(title, origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (single_instance != nullptr) {
    ::ReleaseMutex(single_instance);
    ::CloseHandle(single_instance);
  }
  return EXIT_SUCCESS;
}
