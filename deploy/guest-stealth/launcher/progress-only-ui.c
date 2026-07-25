#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif

#include <windows.h>
#include <commctrl.h>
#include "progress-only-ui.h"

#define PROGRESS_WINDOW_CLASS L"StealthGpuProgressOnlyWindow"
#define PROGRESS_WINDOW_TITLE L"StealthGPU 初始化"
#define PROGRESS_READY_TIMEOUT_MS 10000
#define PROGRESS_CLOSE_TIMEOUT_MS 10000
#define PROGRESS_SUCCESS_DELAY_MS 1200
#define PROGRESS_FAILURE_DELAY_MS 2600
#define WM_PROGRESS_RUNNING (WM_APP + 1)
#define WM_PROGRESS_FINISHED (WM_APP + 2)
#define ID_PROGRESS_CLOSE_TIMER 1
#define ID_PROGRESS_STATUS 101
#define ID_PROGRESS_BAR 102

typedef struct ProgressUiState {
    HANDLE ready_event;
    HANDLE closed_event;
    HANDLE thread;
    HWND window;
    HWND status;
    HWND bar;
    HFONT font;
    int finished;
} ProgressUiState;

static ProgressUiState progress_state;

static void center_window(HWND window)
{
    RECT work_area;
    RECT window_rect;
    int width;
    int height;
    int x;
    int y;

    if (!SystemParametersInfoW(SPI_GETWORKAREA, 0, &work_area, 0) ||
        !GetWindowRect(window, &window_rect)) {
        return;
    }
    width = window_rect.right - window_rect.left;
    height = window_rect.bottom - window_rect.top;
    x = work_area.left + (work_area.right - work_area.left - width) / 2;
    y = work_area.top + (work_area.bottom - work_area.top - height) / 2;
    SetWindowPos(window, NULL, x, y, 0, 0,
                 SWP_NOACTIVATE | SWP_NOSIZE | SWP_NOZORDER);
}

static HFONT create_ui_font(void)
{
    HDC screen = GetDC(NULL);
    int dpi = screen != NULL ? GetDeviceCaps(screen, LOGPIXELSY) : 96;

    if (screen != NULL) {
        ReleaseDC(NULL, screen);
    }
    return CreateFontW(
        -MulDiv(11, dpi, 72), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
        DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
        CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE, L"Segoe UI");
}

static int create_controls(HWND window)
{
    progress_state.font = create_ui_font();
    progress_state.status = CreateWindowExW(
        0, L"STATIC", L"正在准备，请稍候…",
        WS_CHILD | WS_VISIBLE | SS_LEFT,
        32, 31, 396, 28, window, (HMENU)(INT_PTR)ID_PROGRESS_STATUS,
        GetModuleHandleW(NULL), NULL);
    progress_state.bar = CreateWindowExW(
        0, PROGRESS_CLASSW, NULL,
        WS_CHILD | WS_VISIBLE | PBS_MARQUEE | PBS_SMOOTH,
        32, 72, 396, 18, window, (HMENU)(INT_PTR)ID_PROGRESS_BAR,
        GetModuleHandleW(NULL), NULL);
    if (progress_state.status == NULL || progress_state.bar == NULL) {
        return 0;
    }
    if (progress_state.font != NULL) {
        SendMessageW(progress_state.status, WM_SETFONT,
                     (WPARAM)progress_state.font, TRUE);
    }
    /*
     * PBS_MARQUEE / PBM_SETMARQUEE 只由 Common Controls v6 实现。EXE manifest
     * 必须声明 Microsoft.Windows.Common-Controls 6.0，否则旧版控件会显示一条
     * 静止的进度槽，看起来像 UI 线程没有刷新。
     */
    SendMessageW(progress_state.bar, PBM_SETMARQUEE, TRUE, 32);
    return 1;
}

static void show_finished_state(int succeeded)
{
    const wchar_t *message = succeeded
        ? L"已完成。"
        : L"未完成，请稍后重试。";
    UINT delay = succeeded
        ? PROGRESS_SUCCESS_DELAY_MS
        : PROGRESS_FAILURE_DELAY_MS;

    progress_state.finished = 1;
    SetWindowTextW(progress_state.status, message);
    SendMessageW(progress_state.bar, PBM_SETMARQUEE, FALSE, 0);
    SetWindowLongPtrW(progress_state.bar, GWL_STYLE,
                      (GetWindowLongPtrW(progress_state.bar, GWL_STYLE) &
                       ~(LONG_PTR)PBS_MARQUEE) | PBS_SMOOTH);
    SendMessageW(progress_state.bar, PBM_SETRANGE, 0, MAKELPARAM(0, 100));
    SendMessageW(progress_state.bar, PBM_SETPOS, 100, 0);
    SendMessageW(progress_state.bar, PBM_SETSTATE,
                 succeeded ? PBST_NORMAL : PBST_ERROR, 0);
    InvalidateRect(progress_state.bar, NULL, TRUE);
    SetTimer(progress_state.window, ID_PROGRESS_CLOSE_TIMER, delay, NULL);
}

static LRESULT CALLBACK progress_window_proc(
    HWND window,
    UINT message,
    WPARAM wparam,
    LPARAM lparam)
{
    (void)lparam;

    switch (message) {
    case WM_CREATE:
        if (!create_controls(window)) {
            return -1;
        }
        return 0;
    case WM_PROGRESS_RUNNING:
        SetWindowTextW(progress_state.status, L"正在处理，请稍候…");
        return 0;
    case WM_PROGRESS_FINISHED:
        show_finished_state(wparam != 0);
        return 0;
    case WM_TIMER:
        if (wparam == ID_PROGRESS_CLOSE_TIMER) {
            KillTimer(window, ID_PROGRESS_CLOSE_TIMER);
            DestroyWindow(window);
        }
        return 0;
    case WM_CLOSE:
        if (progress_state.finished) {
            DestroyWindow(window);
        }
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    default:
        return DefWindowProcW(window, message, wparam, lparam);
    }
}

static DWORD WINAPI progress_ui_thread(void *context)
{
    INITCOMMONCONTROLSEX controls;
    WNDCLASSEXW window_class;
    MSG message;
    HINSTANCE instance = GetModuleHandleW(NULL);
    HWND window;

    (void)context;
    controls.dwSize = sizeof(controls);
    controls.dwICC = ICC_PROGRESS_CLASS;
    if (!InitCommonControlsEx(&controls)) {
        SetEvent(progress_state.ready_event);
        SetEvent(progress_state.closed_event);
        return 1;
    }

    ZeroMemory(&window_class, sizeof(window_class));
    window_class.cbSize = sizeof(window_class);
    window_class.lpfnWndProc = progress_window_proc;
    window_class.hInstance = instance;
    window_class.hIcon = LoadIconW(instance, MAKEINTRESOURCEW(101));
    window_class.hIconSm = window_class.hIcon;
    window_class.hCursor = LoadCursorW(NULL, IDC_ARROW);
    window_class.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    window_class.lpszClassName = PROGRESS_WINDOW_CLASS;
    if (!RegisterClassExW(&window_class) &&
        GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
        SetEvent(progress_state.ready_event);
        SetEvent(progress_state.closed_event);
        return 1;
    }

    window = CreateWindowExW(
        WS_EX_APPWINDOW, PROGRESS_WINDOW_CLASS, PROGRESS_WINDOW_TITLE,
        WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU,
        CW_USEDEFAULT, CW_USEDEFAULT, 476, 154,
        NULL, NULL, instance, NULL);
    if (window == NULL) {
        SetEvent(progress_state.ready_event);
        SetEvent(progress_state.closed_event);
        return 1;
    }
    progress_state.window = window;
    center_window(window);
    ShowWindow(window, SW_SHOWNORMAL);
    UpdateWindow(window);
    SetForegroundWindow(window);
    SetEvent(progress_state.ready_event);

    while (GetMessageW(&message, NULL, 0, 0) > 0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }

    if (progress_state.font != NULL) {
        DeleteObject(progress_state.font);
        progress_state.font = NULL;
    }
    progress_state.window = NULL;
    SetEvent(progress_state.closed_event);
    return 0;
}

static void close_progress_handles(void)
{
    if (progress_state.thread != NULL) {
        CloseHandle(progress_state.thread);
    }
    if (progress_state.ready_event != NULL) {
        CloseHandle(progress_state.ready_event);
    }
    if (progress_state.closed_event != NULL) {
        CloseHandle(progress_state.closed_event);
    }
    ZeroMemory(&progress_state, sizeof(progress_state));
}

static void close_progress_handles_if_stopped(void)
{
    if (progress_state.thread == NULL ||
        WaitForSingleObject(
            progress_state.thread, PROGRESS_CLOSE_TIMEOUT_MS) ==
            WAIT_OBJECT_0) {
        close_progress_handles();
    }
}

int progress_only_ui_start(void)
{
    DWORD wait_result;

    ZeroMemory(&progress_state, sizeof(progress_state));
    progress_state.ready_event = CreateEventW(NULL, TRUE, FALSE, NULL);
    progress_state.closed_event = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (progress_state.ready_event == NULL ||
        progress_state.closed_event == NULL) {
        close_progress_handles();
        return 0;
    }
    progress_state.thread = CreateThread(
        NULL, 0, progress_ui_thread, NULL, 0, NULL);
    if (progress_state.thread == NULL) {
        close_progress_handles();
        return 0;
    }
    wait_result = WaitForSingleObject(
        progress_state.ready_event, PROGRESS_READY_TIMEOUT_MS);
    if (wait_result != WAIT_OBJECT_0 || progress_state.window == NULL) {
        /*
         * UI 线程若异常卡住，主线程会立即返回并结束进程。此时不能关闭它仍可能访问的
         * event 或清空共享状态；只有确认线程已经退出后才回收这些句柄。
         */
        close_progress_handles_if_stopped();
        return 0;
    }
    return 1;
}

void progress_only_ui_set_running(void)
{
    if (progress_state.window != NULL) {
        PostMessageW(progress_state.window, WM_PROGRESS_RUNNING, 0, 0);
    }
}

void progress_only_ui_finish(int succeeded)
{
    if (progress_state.window == NULL) {
        close_progress_handles_if_stopped();
        return;
    }
    PostMessageW(progress_state.window, WM_PROGRESS_FINISHED,
                 succeeded ? 1 : 0, 0);
    WaitForSingleObject(progress_state.closed_event, PROGRESS_CLOSE_TIMEOUT_MS);
    close_progress_handles_if_stopped();
}

BOOL progress_only_create_process(
    const wchar_t *application,
    wchar_t *command_line,
    wchar_t *environment,
    const wchar_t *work_dir,
    PROCESS_INFORMATION *process)
{
    SECURITY_ATTRIBUTES attributes;
    STARTUPINFOW startup;
    HANDLE null_input;
    HANDLE null_output;
    BOOL created;
    DWORD error;

    ZeroMemory(&attributes, sizeof(attributes));
    attributes.nLength = sizeof(attributes);
    attributes.bInheritHandle = TRUE;
    null_input = CreateFileW(
        L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
        &attributes, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (null_input == INVALID_HANDLE_VALUE) {
        return FALSE;
    }
    null_output = CreateFileW(
        L"NUL", GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
        &attributes, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (null_output == INVALID_HANDLE_VALUE) {
        error = GetLastError();
        CloseHandle(null_input);
        SetLastError(error);
        return FALSE;
    }

    ZeroMemory(&startup, sizeof(startup));
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
    startup.wShowWindow = SW_HIDE;
    startup.hStdInput = null_input;
    startup.hStdOutput = null_output;
    startup.hStdError = null_output;
    created = CreateProcessW(
        application, command_line, NULL, NULL, TRUE,
        CREATE_UNICODE_ENVIRONMENT | CREATE_NO_WINDOW,
        environment, work_dir, &startup, process);
    error = created ? ERROR_SUCCESS : GetLastError();
    CloseHandle(null_output);
    CloseHandle(null_input);
    if (!created) {
        SetLastError(error);
    }
    return created;
}
