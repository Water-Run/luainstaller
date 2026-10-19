/* Exercise real console handles, independently of the SSH/CI pipe handles. */
#ifndef _CRT_SECURE_NO_WARNINGS
#define _CRT_SECURE_NO_WARNINGS
#endif
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0501
#endif
#include <windows.h>
#include <shellapi.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>
#ifdef _MSC_VER
#pragma comment(lib, "shell32.lib")
#endif

static int launch(const wchar_t *program, const wchar_t *arguments, const wchar_t *cwd,
    DWORD flags, PROCESS_INFORMATION *child)
{
    wchar_t command[32768];
    STARTUPINFOW startup;
    int size = _snwprintf(command, sizeof(command) / sizeof(command[0]), L"\"%ls\" %ls", program, arguments);
    if (size < 0 || (size_t)size >= sizeof(command) / sizeof(command[0])) return 0;
    memset(&startup, 0, sizeof(startup)); startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESHOWWINDOW; startup.wShowWindow = SW_HIDE;
    memset(child, 0, sizeof(*child));
    return CreateProcessW(program, command, NULL, NULL, TRUE, flags, NULL, cwd, &startup, child) != 0;
}

static HANDLE progress_child(DWORD owner)
{
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0), found = NULL;
    PROCESSENTRY32W entry;
    if (snapshot == INVALID_HANDLE_VALUE) return NULL;
    memset(&entry, 0, sizeof(entry)); entry.dwSize = sizeof(entry);
    if (Process32FirstW(snapshot, &entry)) do {
        if (entry.th32ParentProcessID == owner && _wcsicmp(entry.szExeFile, L"rundll32.exe") == 0) {
            found = OpenProcess(SYNCHRONIZE, FALSE, entry.th32ProcessID); break;
        }
    } while (Process32NextW(snapshot, &entry));
    CloseHandle(snapshot);
    return found;
}

static int exercise(wchar_t **argv)
{
    HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE), guard = NULL;
    DWORD initial, mode, status = 1, count, deadline;
    wchar_t arguments[32768], screen[160], previous = 0;
    PROCESS_INFORMATION child;
    COORD origin = {0, 0};
    int frames = 0, killed, capable;
    if (!GetConsoleMode(output, &initial)) return 10;
    mode = initial & ~((DWORD)4);
    if (!SetConsoleMode(output, mode)) return 11;
    capable = SetConsoleMode(output, mode | 4) != 0;
    if (!SetConsoleMode(output, mode)) return 11;
    for (killed = 0; killed < (capable ? 3 : 1); ++killed) {
        CONSOLE_SCREEN_BUFFER_INFO info;
        DWORD cells;
        if (!GetConsoleScreenBufferInfo(output, &info)) return 12;
        cells = (DWORD)info.dwSize.X * (DWORD)info.dwSize.Y;
        FillConsoleOutputCharacterW(output, L' ', cells, origin, &count);
        SetConsoleCursorPosition(output, origin);
        if (_snwprintf(arguments, sizeof(arguments) / sizeof(arguments[0]), L"\"%ls\" %ls",
            argv[3], killed ? L"kill" : L"normal") < 0) return 13;
        if (!launch(argv[2], arguments, argv[4], killed == 2 ? CREATE_NEW_PROCESS_GROUP : 0, &child)) return 14;
        CloseHandle(child.hThread);
        deadline = GetTickCount(); frames = 0; previous = 0;
        while (GetTickCount() - deadline < 30000 && WaitForSingleObject(child.hProcess, 0) == WAIT_TIMEOUT) {
            if (ReadConsoleOutputCharacterW(output, screen, 159, origin, &count)) {
                screen[count] = 0;
                if (screen[0] == L'[' && screen[2] == L']' && screen[1] != previous) {
                    previous = screen[1]; ++frames;
                }
            }
            if (killed && frames >= 2) {
                guard = progress_child(child.dwProcessId);
                if (killed == 1) TerminateProcess(child.hProcess, 99);
                else if (!GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT, child.dwProcessId)) {
                    TerminateProcess(child.hProcess, 125); WaitForSingleObject(child.hProcess, 2000);
                    if (guard) CloseHandle(guard);
                    CloseHandle(child.hProcess); return 21;
                }
                break;
            }
            Sleep(25);
        }
        if (WaitForSingleObject(child.hProcess, 5000) != WAIT_OBJECT_0) {
            TerminateProcess(child.hProcess, 125); WaitForSingleObject(child.hProcess, 2000);
            CloseHandle(child.hProcess); return 15;
        }
        GetExitCodeProcess(child.hProcess, &status);
        /* Hold the owner process object until its watcher exits (no PID reuse). */
        if (killed) {
            if (!guard || WaitForSingleObject(guard, 3000) != WAIT_OBJECT_0) {
                if (guard) CloseHandle(guard);
                CloseHandle(child.hProcess); return 16;
            }
            CloseHandle(guard); guard = NULL;
        }
        CloseHandle(child.hProcess);
        if ((capable && frames < 2) || (!killed && status != 0)
            || (killed == 1 && status != 99) || (killed == 2 && status == 0)) return 17;
        if (!GetConsoleMode(output, &status) || status != mode) return 18;
        if (!killed) {
            if (!ReadConsoleOutputCharacterW(output, screen, 159, origin, &count)) return 19;
            screen[count] = 0;
            if (!wcsstr(screen, L"Console \x6d4b\x8bd5")) return 20;
        }
    }
    SetConsoleMode(output, initial);
    return 0;
}

int main(void)
{
    wchar_t **argv, arguments[32768];
    PROCESS_INFORMATION child;
    DWORD status;
    int argc;
    argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv) return 2;
    if (argc == 5 && wcscmp(argv[1], L"console") == 0) return exercise(argv);
    if (argc != 5) return 3;
    if (_snwprintf(arguments, sizeof(arguments) / sizeof(arguments[0]),
        L"console \"%ls\" \"%ls\" \"%ls\"", argv[1], argv[2], argv[3]) < 0) return 4;
    if (!launch(argv[0], arguments, argv[3], CREATE_NEW_CONSOLE, &child)) return 5;
    CloseHandle(child.hThread);
    if (WaitForSingleObject(child.hProcess, 80000) != WAIT_OBJECT_0) {
        TerminateProcess(child.hProcess, 125); WaitForSingleObject(child.hProcess, 2000);
        CloseHandle(child.hProcess); return 6;
    }
    if (!GetExitCodeProcess(child.hProcess, &status)) status = 7;
    CloseHandle(child.hProcess); LocalFree(argv);
    if (status) fprintf(stderr, "native console probe failed: %lu\n", (unsigned long)status);
    return (int)status;
}
