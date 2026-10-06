/* Native, PowerShell-free Windows integration-test driver. */
#ifndef _CRT_SECURE_NO_WARNINGS
#define _CRT_SECURE_NO_WARNINGS
#endif
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0501
#endif
#include <windows.h>
#include <shellapi.h>
#include <tlhelp32.h>
#include <winioctl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#ifdef _MSC_VER
#pragma comment(lib, "shell32.lib")
#endif

static int start(const wchar_t *exe, const wchar_t *arguments, const wchar_t *cwd, PROCESS_INFORMATION *process)
{
    wchar_t command[32768];
    STARTUPINFOW startup;
    int size = _snwprintf(command, sizeof(command) / sizeof(command[0]), L"\"%ls\" %ls", exe, arguments);
    if (size < 0 || (size_t)size >= sizeof(command) / sizeof(command[0])) return 0;
    memset(&startup, 0, sizeof(startup)); startup.cb = sizeof(startup);
    memset(process, 0, sizeof(*process));
    return CreateProcessW(exe, command, NULL, NULL, TRUE, CREATE_NO_WINDOW, NULL, cwd, &startup, process) != 0;
}

static void close_process(PROCESS_INFORMATION *process)
{
    CloseHandle(process->hThread); CloseHandle(process->hProcess);
}

static int read_ready(const wchar_t *path, char *data, DWORD capacity)
{
    HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
    DWORD count = 0;
    if (file == INVALID_HANDLE_VALUE) return 0;
    if (!ReadFile(file, data, capacity - 1, &count, NULL)) count = 0;
    CloseHandle(file); data[count] = 0;
    return count != 0;
}

static int wait_ready(const wchar_t *path, HANDLE owner, char *data, DWORD capacity)
{
    unsigned int attempt;
    for (attempt = 0; attempt < 600; ++attempt) {
        if (read_ready(path, data, capacity)) return 1;
        if (WaitForSingleObject(owner, 0) != WAIT_TIMEOUT) return 0;
        Sleep(25);
    }
    return 0;
}

static int stopped(DWORD pid)
{
    HANDLE process = OpenProcess(SYNCHRONIZE, FALSE, pid);
    DWORD result;
    if (!process) return GetLastError() == ERROR_INVALID_PARAMETER;
    result = WaitForSingleObject(process, 0); CloseHandle(process);
    return result == WAIT_OBJECT_0;
}

static int junction(const wchar_t *link, const wchar_t *target)
{
    struct mount_point {
        DWORD tag;
        WORD size, reserved, substitute_offset, substitute_size, print_offset, print_size;
        wchar_t names[4096];
    } data;
    wchar_t full[2048];
    DWORD length, returned;
    HANDLE handle;
    BOOL ok;
    length = GetFullPathNameW(target, sizeof(full) / sizeof(full[0]), full, NULL);
    if (!length || length >= sizeof(full) / sizeof(full[0])) return 40;
    if (!CreateDirectoryW(link, NULL)) return 41;
    handle = CreateFileW(link, GENERIC_WRITE, 0, NULL, OPEN_EXISTING,
        FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, NULL);
    if (handle == INVALID_HANDLE_VALUE) return 42;
    memset(&data, 0, sizeof(data)); data.tag = IO_REPARSE_TAG_MOUNT_POINT;
    memcpy(data.names, L"\\??\\", 4 * sizeof(wchar_t));
    memcpy(data.names + 4, full, (length + 1) * sizeof(wchar_t));
    data.substitute_size = (WORD)((length + 4) * sizeof(wchar_t));
    data.print_offset = (WORD)(data.substitute_size + sizeof(wchar_t));
    data.print_size = (WORD)(length * sizeof(wchar_t));
    memcpy((BYTE *)data.names + data.print_offset, full, (length + 1) * sizeof(wchar_t));
    data.size = (WORD)(8 + data.print_offset + data.print_size + sizeof(wchar_t));
    ok = DeviceIoControl(handle, FSCTL_SET_REPARSE_POINT, &data, data.size + 8, NULL, 0, &returned, NULL);
    CloseHandle(handle);
    return ok ? 0 : 43;
}

int main(void)
{
    wchar_t **argv;
    int argc, index;
    DWORD code;
    argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv || argc < 2) return 2;
    if (wcscmp(argv[1], L"unicode") == 0) {
        wchar_t environment[1024];
        if (argc != 3 || wcscmp(argv[2], L"say \"hello\"\\trail\\ & percent% caret^ bang! \x6d4b\x8bd5") != 0) return 31;
        if (!GetEnvironmentVariableW(L"LUAI_WINDOWS_ENV", environment, sizeof(environment) / sizeof(environment[0]))) return 32;
        if (wcscmp(environment, L"value & % ^ ! \x6d4b\x8bd5") != 0) return 33;
        fputs("windows unicode process ok", stdout);
        return 0;
    }
    if (wcscmp(argv[1], L"sleep") == 0) { Sleep(30000); return 0; }
    if (wcscmp(argv[1], L"flood") == 0) {
        char data[4096];
        DWORD written;
        for (index = 0; index < 64; ++index) {
            memset(data, 'a', sizeof(data));
            if (!WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), data, sizeof(data), &written, NULL) || written != sizeof(data)) return 34;
            memset(data, 'b', sizeof(data));
            if (!WriteFile(GetStdHandle(STD_ERROR_HANDLE), data, sizeof(data), &written, NULL) || written != sizeof(data)) return 35;
        }
        return 0;
    }
    if (wcscmp(argv[1], L"junction") == 0 && argc == 4) return junction(argv[2], argv[3]);
    if (wcscmp(argv[1], L"spawn") == 0 && argc == 6) {
        PROCESS_INFORMATION workers[12];
        int failed = 0;
        for (index = 0; index < 12; ++index) {
            wchar_t arguments[4096];
            if (_snwprintf(arguments, sizeof(arguments) / sizeof(arguments[0]), L"\"%ls\" \"%ls\\result-%d.txt\" %d", argv[3], argv[4], index + 1, index + 1) < 0) return 50;
            if (!start(argv[2], arguments, argv[5], &workers[index])) return 51;
        }
        for (index = 0; index < 12; ++index) {
            WaitForSingleObject(workers[index].hProcess, INFINITE);
            if (!GetExitCodeProcess(workers[index].hProcess, &code) || code != 0) failed = 1;
            close_process(&workers[index]);
        }
        return failed ? 52 : 0;
    }
    if (wcscmp(argv[1], L"tree") == 0 && argc == 3) {
        PROCESS_INFORMATION child;
        char data[80];
        int size;
        DWORD wrote;
        HANDLE file;
        if (!start(argv[0], L"sleep", NULL, &child)) return 60;
        size = _snprintf(data, sizeof(data), "%lu %lu\n", (unsigned long)GetCurrentProcessId(), (unsigned long)child.dwProcessId);
        if (size < 0) return 61;
        file = CreateFileW(argv[2], GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_NEW, 0, NULL);
        if (file == INVALID_HANDLE_VALUE) return 62;
        if (!WriteFile(file, data, (DWORD)size, &wrote, NULL) || wrote != (DWORD)size) return 63;
        CloseHandle(file);
        WaitForSingleObject(child.hProcess, INFINITE); close_process(&child);
        return 0;
    }
    if (wcscmp(argv[1], L"owner") == 0 && argc == 6) {
        PROCESS_INFORMATION owner;
        wchar_t arguments[8192];
        char data[128];
        unsigned long child, grandchild;
        if (_snwprintf(arguments, sizeof(arguments) / sizeof(arguments[0]), L"\"%ls\" \"%ls\" \"%ls\"", argv[3], argv[0], argv[4]) < 0) return 70;
        if (!start(argv[2], arguments, argv[5], &owner)) return 71;
        if (!wait_ready(argv[4], owner.hProcess, data, sizeof(data)) || sscanf(data, "%lu %lu", &child, &grandchild) != 2) {
            TerminateProcess(owner.hProcess, 72); close_process(&owner); return 72;
        }
        TerminateProcess(owner.hProcess, 73); WaitForSingleObject(owner.hProcess, 5000); close_process(&owner);
        for (index = 0; index < 500 && (!stopped(child) || !stopped(grandchild)); ++index) Sleep(10);
        if (!stopped(child) || !stopped(grandchild)) return 74;
        fputs("owner death contained descendants", stdout);
        return 0;
    }
    if (wcscmp(argv[1], L"lifecycle") == 0 && argc == 4) {
        PROCESS_INFORMATION outer;
        PROCESSENTRY32W item;
        HANDLE snapshot, observed[8];
        DWORD ids[8], inner = 0, count = 0, attempt;
        wchar_t arguments[4096];
        char data[64];
        if (_snwprintf(arguments, sizeof(arguments) / sizeof(arguments[0]), L"\"%ls\"", argv[3]) < 0) return 80;
        if (!start(argv[2], arguments, NULL, &outer)) return 81;
        if (!wait_ready(argv[3], outer.hProcess, data, sizeof(data))) { TerminateProcess(outer.hProcess, 82); close_process(&outer); return 82; }
        snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snapshot == INVALID_HANDLE_VALUE) return 83;
        memset(&item, 0, sizeof(item)); item.dwSize = sizeof(item);
        if (Process32FirstW(snapshot, &item)) do {
            if (item.th32ParentProcessID == outer.dwProcessId && count < 8) {
                if (_wcsicmp(item.szExeFile, L"inner.exe") == 0) inner = item.th32ProcessID;
                observed[count] = OpenProcess(SYNCHRONIZE, FALSE, item.th32ProcessID);
                ids[count] = item.th32ProcessID;
                if (observed[count]) ++count;
            }
        } while (Process32NextW(snapshot, &item));
        CloseHandle(snapshot);
        TerminateProcess(outer.hProcess, 9); WaitForSingleObject(outer.hProcess, 5000);
        for (attempt = 0; attempt < count; ++attempt) {
            if (WaitForSingleObject(observed[attempt], 10000) != WAIT_OBJECT_0) return 84;
            CloseHandle(observed[attempt]);
            if (!stopped(ids[attempt])) return 85;
        }
        if (!inner || inner == outer.dwProcessId) return 86;
        printf("outer=%lu inner=%lu outer_alive=0 inner_alive=0 children_alive=0\n", (unsigned long)outer.dwProcessId, (unsigned long)inner);
        close_process(&outer);
        if (!start(argv[2], L"exit23", NULL, &outer)) return 87;
        WaitForSingleObject(outer.hProcess, INFINITE);
        if (!GetExitCodeProcess(outer.hProcess, &code)) return 88;
        close_process(&outer);
        printf("exit=%lu\n", (unsigned long)code);
        return code == 23 ? 0 : 89;
    }
    return 3;
}
