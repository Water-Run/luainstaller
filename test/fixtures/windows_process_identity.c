/* Exercise stale parent PIDs at the native process-enumeration boundary. */
#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct fake_snapshot {
    HANDLE handle;
    unsigned int index;
} fake_snapshot;

static fake_snapshot snapshots[512];
static unsigned int snapshot_count;
static PROCESSENTRY32W fixture_entries[3];

static fake_snapshot *find_snapshot(HANDLE handle)
{
    unsigned int index;
    for (index = 0; index < snapshot_count; ++index)
        if (snapshots[index].handle == handle) return &snapshots[index];
    return NULL;
}

static HANDLE WINAPI test_snapshot(DWORD flags, DWORD pid)
{
    HANDLE handle;
    (void)flags; (void)pid;
    if (snapshot_count == 512) return INVALID_HANDLE_VALUE;
    handle = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!handle) return INVALID_HANDLE_VALUE;
    snapshots[snapshot_count].handle = handle;
    snapshots[snapshot_count++].index = 0;
    return handle;
}

static BOOL WINAPI test_first(HANDLE handle, LPPROCESSENTRY32W entry)
{
    fake_snapshot *snapshot = find_snapshot(handle);
    if (!snapshot) return FALSE;
    snapshot->index = 0;
    *entry = fixture_entries[0];
    return TRUE;
}

static BOOL WINAPI test_next(HANDLE handle, LPPROCESSENTRY32W entry)
{
    fake_snapshot *snapshot = find_snapshot(handle);
    if (!snapshot || ++snapshot->index >= 3) return FALSE;
    *entry = fixture_entries[snapshot->index];
    return TRUE;
}

#define CreateToolhelp32Snapshot test_snapshot
#define Process32FirstW test_first
#define Process32NextW test_next
#include "../../src/host/windows_host.c"
#undef CreateToolhelp32Snapshot
#undef Process32FirstW
#undef Process32NextW
#ifdef _MSC_VER
#pragma comment(lib, "advapi32.lib")
#endif

typedef struct child_record {
    DWORD pid;
    ULONG_PTR handle;
} child_record;

static int spawn(const wchar_t *suffix, BOOL inherit, PROCESS_INFORMATION *child)
{
    wchar_t executable[32768], command[32768];
    STARTUPINFOW startup;
    DWORD length = GetModuleFileNameW(NULL, executable, 32768);
    int written;
    if (!length || length >= 32768) return 0;
    written = _snwprintf(command, 32768, L"\"%ls\" %ls", executable, suffix);
    if (written < 0 || written >= 32768) return 0;
    memset(&startup, 0, sizeof(startup)); startup.cb = sizeof(startup);
    memset(child, 0, sizeof(*child));
    if (!CreateProcessW(executable, command, NULL, NULL, inherit,
        CREATE_NO_WINDOW, NULL, NULL, &startup, child)) return 0;
    CloseHandle(child->hThread); child->hThread = NULL;
    return 1;
}

static void stop_owned(HANDLE process)
{
    if (!process) return;
    if (WaitForSingleObject(process, 0) == WAIT_TIMEOUT) TerminateProcess(process, 0);
    WaitForSingleObject(process, 5000);
    CloseHandle(process);
}

int main(int argc, char **argv)
{
    HANDLE mapping = NULL, ready = NULL, descendant = NULL;
    child_record *record = NULL;
    PROCESS_INFORMATION older, root;
    SECURITY_ATTRIBUTES security;
    wchar_t suffix[256];
    FILETIME older_birth, root_birth, ended, kernel, user;
    int result = 2;
    memset(&older, 0, sizeof(older)); memset(&root, 0, sizeof(root));
    if (argc == 2 && strcmp(argv[1], "--hold") == 0) {
        Sleep(INFINITE); return 0;
    }
    if (argc == 5 && strcmp(argv[1], "--spawn") == 0) {
        HANDLE parent, copy = NULL;
        PROCESS_INFORMATION child;
        mapping = (HANDLE)(ULONG_PTR)_strtoui64(argv[2], NULL, 16);
        ready = (HANDLE)(ULONG_PTR)_strtoui64(argv[3], NULL, 16);
        parent = OpenProcess(PROCESS_DUP_HANDLE, FALSE,
            (DWORD)strtoul(argv[4], NULL, 16));
        record = (child_record *)MapViewOfFile(mapping, FILE_MAP_WRITE, 0, 0, 0);
        if (!parent || !record || !spawn(L"--hold", FALSE, &child)) return 3;
        if (!DuplicateHandle(GetCurrentProcess(), child.hProcess, parent, &copy,
            PROCESS_QUERY_INFORMATION | PROCESS_TERMINATE | SYNCHRONIZE, FALSE, 0)) {
            stop_owned(child.hProcess); return 4;
        }
        record->pid = child.dwProcessId; record->handle = (ULONG_PTR)copy;
        CloseHandle(child.hProcess); CloseHandle(parent);
        if (!SetEvent(ready)) return 5;
        Sleep(INFINITE); return 0;
    }
    if (argc != 1) return 2;
    if (!spawn(L"--hold", FALSE, &older)) goto done;
    if (!GetProcessTimes(older.hProcess, &older_birth, &ended, &kernel, &user)) goto done;
    Sleep(50);
    memset(&security, 0, sizeof(security));
    security.nLength = sizeof(security); security.bInheritHandle = TRUE;
    mapping = CreateFileMappingW(INVALID_HANDLE_VALUE, &security, PAGE_READWRITE,
        0, sizeof(child_record), NULL);
    ready = CreateEventW(&security, TRUE, FALSE, NULL);
    if (!mapping || !ready) goto done;
    record = (child_record *)MapViewOfFile(mapping, FILE_MAP_READ | FILE_MAP_WRITE, 0, 0, 0);
    if (!record) goto done;
    memset(record, 0, sizeof(*record));
    if (_snwprintf(suffix, 256, L"--spawn %p %p %lx", (void *)mapping,
        (void *)ready, (unsigned long)GetCurrentProcessId()) < 0) goto done;
    if (!spawn(suffix, TRUE, &root)) goto done;
    if (WaitForSingleObject(ready, 5000) != WAIT_OBJECT_0) goto done;
    descendant = (HANDLE)record->handle;
    if (!descendant || !record->pid) goto done;
    if (!GetProcessTimes(root.hProcess, &root_birth, &ended, &kernel, &user)
        || CompareFileTime(&older_birth, &root_birth) >= 0) goto done;
    memset(fixture_entries, 0, sizeof(fixture_entries));
    fixture_entries[0].dwSize = fixture_entries[1].dwSize = fixture_entries[2].dwSize = sizeof(PROCESSENTRY32W);
    /* An orphan reports a recycled parent PID; the last entry forms a stale cycle. */
    fixture_entries[0].th32ProcessID = older.dwProcessId;
    fixture_entries[0].th32ParentProcessID = root.dwProcessId;
    fixture_entries[1].th32ProcessID = record->pid;
    fixture_entries[1].th32ParentProcessID = root.dwProcessId;
    fixture_entries[2].th32ProcessID = root.dwProcessId;
    fixture_entries[2].th32ParentProcessID = record->pid;
    kill_descendants(root.hProcess, root.dwProcessId, 0);
    if (WaitForSingleObject(older.hProcess, 0) != WAIT_TIMEOUT) {
        fputs("cleanup killed a process older than the current parent identity\n", stderr);
        result = 6; goto done;
    }
    if (WaitForSingleObject(root.hProcess, 0) != WAIT_TIMEOUT) {
        fputs("cleanup followed a stale parent cycle back to its root\n", stderr);
        result = 7; goto done;
    }
    if (WaitForSingleObject(descendant, 5000) != WAIT_OBJECT_0) {
        fputs("cleanup left the actual descendant running\n", stderr);
        result = 8; goto done;
    }
    puts("native descendant cleanup preserves recycled parent identities");
    result = 0;
done:
    if (!descendant && record) descendant = (HANDLE)record->handle;
    stop_owned(descendant); stop_owned(root.hProcess); stop_owned(older.hProcess);
    if (record) UnmapViewOfFile(record);
    if (mapping) CloseHandle(mapping);
    if (ready) CloseHandle(ready);
    return result;
}
