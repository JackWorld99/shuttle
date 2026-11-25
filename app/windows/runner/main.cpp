#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"
#include "winrt_ext.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  if (IsRunningWithIdentity()) {
    winrt::hstring share_arg = GetSharedMedia();
    if (!share_arg.empty()) {
      printf("share: %ls\n", share_arg.c_str());
      command_line_arguments.push_back("--share");
      command_line_arguments.push_back(Utf8FromUtf16(share_arg.c_str()));
    }
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  // Shuttle: draw with Skia instead of Impeller, the default on Windows since
  // Flutter 3.47. Impeller runs on OpenGL ES (ANGLE) there. Measured on an
  // integrated Intel GPU: 2 to 3 ms per gradient, 20 to 50 ms per frame on our
  // pages (Skia: 3 to 9 ms), and its gradients aren't dithered, so the backdrop
  // shows rings. Before this opt-out is removed from Flutter, measure again
  // (tools/test/live/bench.dart) and use fewer gradients if needed.
  project.set_impeller_switch(flutter::ImpellerSwitch::Disabled);

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1100, 720);  // Shuttle: wide enough for the three-column layout on first launch
  // Shuttle: window title (the name shown in the taskbar and in Alt+Tab)
  if (!window.Create(L"Shuttle", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
