#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

// Keep ownership until the window and Flutter engine have been destroyed.
// Windows releases the mutex automatically if the process crashes.
class SingleInstance {
 public:
  enum class Result { kPrimary, kActivated, kError };

  SingleInstance()
      : mutex_(::CreateMutex(nullptr, FALSE,
                             L"Local\\Any2MD.Desktop.SingleInstance")) {}

  ~SingleInstance() {
    if (mutex_) {
      if (owns_mutex_) {
        ::ReleaseMutex(mutex_);
      }
      ::CloseHandle(mutex_);
    }
  }

  SingleInstance(const SingleInstance&) = delete;
  SingleInstance& operator=(const SingleInstance&) = delete;

  Result AcquireOrActivate() {
    if (!mutex_) {
      return Result::kError;
    }

    // The first process may still be creating its window. Wait for it rather
    // than starting another engine when shortcuts are clicked in quick succession.
    const ULONGLONG deadline = ::GetTickCount64() + 10000;
    do {
      const DWORD result = ::WaitForSingleObject(mutex_, 50);
      if (result == WAIT_OBJECT_0 || result == WAIT_ABANDONED) {
        owns_mutex_ = true;
        return Result::kPrimary;
      }
      if (result != WAIT_TIMEOUT) {
        return Result::kError;
      }

      HWND window = ::FindWindow(Win32Window::kWindowClassName, nullptr);
      if (window) {
        DWORD process_id = 0;
        ::GetWindowThreadProcessId(window, &process_id);
        // Pass the shortcut launcher's foreground permission to the existing
        // process, which restores and focuses its window on its own UI thread.
        ::AllowSetForegroundWindow(process_id);
        const UINT message = Win32Window::GetActivationMessage();
        if (message && ::PostMessage(window, message, 0, 0)) {
          return Result::kActivated;
        }
      }
    } while (::GetTickCount64() < deadline);

    return Result::kError;
  }

 private:
  HANDLE mutex_;
  bool owns_mutex_ = false;
};

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  SingleInstance single_instance;
  const auto startup = single_instance.AcquireOrActivate();
  if (startup == SingleInstance::Result::kActivated) {
    return EXIT_SUCCESS;
  }
  if (startup == SingleInstance::Result::kError) {
    ::MessageBox(nullptr,
                 L"Any2MD could not be started or activated. Please try again.",
                 L"Any2MD", MB_OK | MB_ICONERROR);
    return EXIT_FAILURE;
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

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Any2MD", origin, size)) {
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
