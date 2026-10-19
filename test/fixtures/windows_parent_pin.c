/* Exercise the native directory reservation without a Lua or timing hook. */
#include "../../src/host/windows_host.c"
#include <shellapi.h>
#ifdef _MSC_VER
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "shell32.lib")
#endif

int main(void)
{
    context ctx;
    wchar_t **arguments;
    int count;
    BOOL moved;
    DWORD error;
    arguments = CommandLineToArgvW(GetCommandLineW(), &count);
    if (!arguments || count != 3) return 2;
    memset(&ctx, 0, sizeof(ctx)); ctx.ok = 1;
    if (!pin_directory(&ctx, arguments[1])) {
        fprintf(stderr, "cannot reserve directory: %s\n", ctx.error);
        cleanup(&ctx); LocalFree(arguments); return 3;
    }
    moved = MoveFileW(arguments[1], arguments[2]);
    error = GetLastError();
    cleanup(&ctx);
    if (moved && !MoveFileW(arguments[2], arguments[1])) {
        LocalFree(arguments); return 4;
    }
    LocalFree(arguments);
    if (moved) {
        fputs("a reserved directory was moved\n", stderr); return 5;
    }
    if (error != ERROR_ACCESS_DENIED && error != ERROR_SHARING_VIOLATION) {
        fprintf(stderr, "unexpected reservation error: %lu\n", (unsigned long)error); return 6;
    }
    puts("native parent reservation blocks replacement");
    return 0;
}
