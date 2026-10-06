/* Native Windows host operations for official Lua 5.1--5.5.
 * Author: WaterRun
 * File: windows_host.c
 * Date: 2026-10-06
 * Updated: 2026-10-06
 * Keep src/windows_host_source.lua synchronized with this file.
 * Uses Windows XP APIs only; no Lua headers or import library are needed.
 */
#ifndef _CRT_SECURE_NO_WARNINGS
#define _CRT_SECURE_NO_WARNINGS
#endif
#ifndef _WIN32_WINNT
#if defined(_M_ARM) || defined(_M_ARM64) || defined(__arm__) || defined(__aarch64__)
#define _WIN32_WINNT 0x0602
#else
#define _WIN32_WINNT 0x0501
#endif
#endif
#ifndef WINVER
#define WINVER _WIN32_WINNT
#endif
#include <windows.h>
#include <tlhelp32.h>
#include <wincrypt.h>
#include <sddl.h>
#include <aclapi.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <stdio.h>
#include <limits.h>
#ifndef LUAI_HOST_ABI
#define LUAI_HOST_ABI 504
#endif

typedef struct lua_State lua_State;
typedef int (__cdecl *lua_CFunction)(lua_State *);
typedef const char *(__cdecl *tolstring_fn)(lua_State *, int, size_t *);
typedef void *(__cdecl *touserdata_fn)(lua_State *, int);
typedef void (__cdecl *pushboolean_fn)(lua_State *, int);
#if LUAI_HOST_ABI == 501
typedef void (__cdecl *pushlstring_fn)(lua_State *, const char *, size_t);
#else
typedef const char *(__cdecl *pushlstring_fn)(lua_State *, const char *, size_t);
#endif
typedef void (__cdecl *pushcclosure_fn)(lua_State *, lua_CFunction, int);
typedef void (__cdecl *createtable_fn)(lua_State *, int, int);
typedef void (__cdecl *setfield_fn)(lua_State *, int, const char *);
typedef int (__cdecl *setmetatable_fn)(lua_State *, int);
typedef int (__cdecl *newmetatable_fn)(lua_State *, const char *);
#if LUAI_HOST_ABI >= 504
typedef void *(__cdecl *newuserdata_fn)(lua_State *, size_t, int);
#else
typedef void *(__cdecl *newuserdata_fn)(lua_State *, size_t);
#endif
static struct {
    tolstring_fn tolstring;
    touserdata_fn touserdata;
    pushboolean_fn pushboolean;
    pushlstring_fn pushlstring;
    pushcclosure_fn pushcclosure;
    createtable_fn createtable;
    setfield_fn setfield;
    setmetatable_fn setmetatable;
    newmetatable_fn newmetatable;
    newuserdata_fn newuserdata;
} api;
static HMODULE own_module;

#define LOAD_API(field, type, symbol) do { \
    union { FARPROC raw; type typed; } address; \
    address.raw = GetProcAddress(module, symbol); \
    api.field = address.typed; \
    if (!api.field) return 0; \
} while (0)

static int bind_api(HMODULE module)
{
    if (!module || !GetProcAddress(module, "lua_gettop")) return 0;
#if LUAI_HOST_ABI == 501
    if (!GetProcAddress(module, "lua_pcall") || GetProcAddress(module, "lua_pcallk")) return 0;
#elif LUAI_HOST_ABI == 502
    if (!GetProcAddress(module, "lua_getctx")) return 0;
#elif LUAI_HOST_ABI == 503
    if (!GetProcAddress(module, "lua_isinteger") || GetProcAddress(module, "lua_newuserdatauv")) return 0;
#elif LUAI_HOST_ABI == 504
    if (!GetProcAddress(module, "lua_newuserdatauv") || GetProcAddress(module, "luaL_openselectedlibs")) return 0;
#else
    if (!GetProcAddress(module, "luaL_openselectedlibs")) return 0;
#endif
    LOAD_API(tolstring, tolstring_fn, "lua_tolstring");
    LOAD_API(touserdata, touserdata_fn, "lua_touserdata");
    LOAD_API(pushboolean, pushboolean_fn, "lua_pushboolean");
    LOAD_API(pushlstring, pushlstring_fn, "lua_pushlstring");
    LOAD_API(pushcclosure, pushcclosure_fn, "lua_pushcclosure");
    LOAD_API(createtable, createtable_fn, "lua_createtable");
    LOAD_API(setfield, setfield_fn, "lua_setfield");
    LOAD_API(setmetatable, setmetatable_fn, "lua_setmetatable");
    LOAD_API(newmetatable, newmetatable_fn, "luaL_newmetatable");
#if LUAI_HOST_ABI >= 504
    LOAD_API(newuserdata, newuserdata_fn, "lua_newuserdatauv");
#else
    LOAD_API(newuserdata, newuserdata_fn, "lua_newuserdata");
#endif
    return 1;
}

static int find_api(void)
{
    HMODULE main_module = GetModuleHandleW(NULL);
    unsigned char *base = (unsigned char *)main_module;
    IMAGE_DOS_HEADER *dos = (IMAGE_DOS_HEADER *)base;
    IMAGE_NT_HEADERS *nt;
    IMAGE_DATA_DIRECTORY directory;
    IMAGE_IMPORT_DESCRIPTOR *import;
    size_t remaining;
    if (bind_api(main_module)) return 1;
    if (!base || dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew <= 0) return 0;
    nt = (IMAGE_NT_HEADERS *)(base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) return 0;
    directory = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    if (!directory.VirtualAddress || directory.VirtualAddress >= nt->OptionalHeader.SizeOfImage
        || directory.Size > nt->OptionalHeader.SizeOfImage - directory.VirtualAddress) return 0;
    import = (IMAGE_IMPORT_DESCRIPTOR *)(base + directory.VirtualAddress);
    remaining = directory.Size;
    while (remaining >= sizeof(*import) && import->Name) {
        if (import->Name >= nt->OptionalHeader.SizeOfImage) return 0;
        if (!memchr(base + import->Name, 0, nt->OptionalHeader.SizeOfImage - import->Name)) return 0;
        if (bind_api(GetModuleHandleA((const char *)(base + import->Name)))) return 1;
        ++import;
        remaining -= sizeof(*import);
    }
    return 0;
}

typedef struct allocation { void *data; struct allocation *next; } allocation;
typedef struct field { const char *data; size_t size; } field;
typedef struct buffer { char *data; size_t size, capacity; allocation *owner; } buffer;
typedef struct context {
    allocation *memory;
    HANDLE handles[16];
    HANDLE search;
    field *fields;
    unsigned int count;
    buffer result;
    char error[256];
    char extra[40];
    int ok;
} context;

static void cleanup(context *ctx)
{
    unsigned int index;
    allocation *item;
    if (ctx->search && ctx->search != INVALID_HANDLE_VALUE) FindClose(ctx->search);
    ctx->search = NULL;
    for (index = 0; index < 16; ++index) {
        if (ctx->handles[index] && ctx->handles[index] != INVALID_HANDLE_VALUE) CloseHandle(ctx->handles[index]);
        ctx->handles[index] = NULL;
    }
    while ((item = ctx->memory) != NULL) {
        ctx->memory = item->next;
        free(item->data);
        free(item);
    }
}

static int context_gc(lua_State *L)
{
    context *ctx = (context *)api.touserdata(L, 1);
    if (ctx) cleanup(ctx);
    return 0;
}

static int fail(context *ctx, const char *message)
{
    size_t size = strlen(message);
    if (size >= sizeof(ctx->error)) size = sizeof(ctx->error) - 1;
    memcpy(ctx->error, message, size);
    ctx->error[size] = 0;
    ctx->ok = 0;
    return 0;
}

static int win_fail(context *ctx, const char *operation)
{
    DWORD error = GetLastError();
    int count = _snprintf(ctx->error, sizeof(ctx->error), "%s failed (Windows error %lu)", operation, (unsigned long)error);
    if (count < 0 || (size_t)count >= sizeof(ctx->error)) return fail(ctx, "Windows operation failed");
    ctx->ok = 0;
    return 0;
}

static void *allocate(context *ctx, size_t size)
{
    allocation *item = (allocation *)malloc(sizeof(*item));
    if (!item) { fail(ctx, "out of memory"); return NULL; }
    item->data = malloc(size ? size : 1);
    if (!item->data) { free(item); fail(ctx, "out of memory"); return NULL; }
    item->next = ctx->memory;
    ctx->memory = item;
    return item->data;
}

static int append(context *ctx, buffer *out, const void *data, size_t size)
{
    size_t capacity;
    void *grown;
    if (size > (size_t)-1 - out->size - 1) return fail(ctx, "result is too large");
    if (out->size + size + 1 > out->capacity) {
        capacity = out->capacity ? out->capacity : 256;
        while (capacity < out->size + size + 1) {
            if (capacity > (size_t)-1 / 2) { capacity = out->size + size + 1; break; }
            capacity *= 2;
        }
        if (!out->owner) {
            out->data = (char *)allocate(ctx, capacity);
            if (!out->data) return 0;
            out->owner = ctx->memory;
        } else {
            grown = realloc(out->data, capacity);
            if (!grown) return fail(ctx, "out of memory");
            out->data = (char *)grown;
            out->owner->data = grown;
        }
        out->capacity = capacity;
    }
    if (size) memcpy(out->data + out->size, data, size);
    out->size += size;
    out->data[out->size] = 0;
    return 1;
}

static int text(context *ctx, const char *value)
{
    return append(ctx, &ctx->result, value, strlen(value));
}

static int number(context *ctx, ULONGLONG value)
{
    char digits[32];
    size_t index = sizeof(digits);
    do { digits[--index] = (char)('0' + value % 10); value /= 10; } while (value);
    return append(ctx, &ctx->result, digits + index, sizeof(digits) - index);
}

static int track(context *ctx, HANDLE handle)
{
    unsigned int index;
    if (!handle || handle == INVALID_HANDLE_VALUE) return 0;
    for (index = 0; index < 16; ++index) {
        if (!ctx->handles[index]) { ctx->handles[index] = handle; return 1; }
    }
    CloseHandle(handle);
    return fail(ctx, "too many native handles");
}

static void close_handle(context *ctx, HANDLE handle)
{
    unsigned int index;
    if (!handle || handle == INVALID_HANDLE_VALUE) return;
    for (index = 0; index < 16; ++index) if (ctx->handles[index] == handle) ctx->handles[index] = NULL;
    CloseHandle(handle);
}

static unsigned long read_u32(const unsigned char *data)
{
    return (unsigned long)data[0] | ((unsigned long)data[1] << 8)
        | ((unsigned long)data[2] << 16) | ((unsigned long)data[3] << 24);
}

static int parse(context *ctx, const char *data, size_t size)
{
    unsigned long count, length, index;
    if (size < 4) return fail(ctx, "invalid native request");
    count = read_u32((const unsigned char *)data);
    data += 4; size -= 4;
    if (!count || count > 65536 || count > size / 4) return fail(ctx, "invalid native field count");
    ctx->fields = (field *)allocate(ctx, count * sizeof(field));
    if (!ctx->fields) return 0;
    ctx->count = (unsigned int)count;
    for (index = 0; index < count; ++index) {
        if (size < 4) return fail(ctx, "truncated native request");
        length = read_u32((const unsigned char *)data);
        data += 4; size -= 4;
        if (length > size) return fail(ctx, "truncated native field");
        ctx->fields[index].data = data;
        ctx->fields[index].size = length;
        data += length; size -= length;
    }
    if (size) return fail(ctx, "trailing native request data");
    return 1;
}

static int equals(field *value, const char *expected)
{
    size_t size = strlen(expected);
    return value->size == size && memcmp(value->data, expected, size) == 0;
}

static wchar_t *wide(context *ctx, const char *data, size_t size, UINT codepage)
{
    wchar_t *result;
    int length;
    if (size > INT_MAX || memchr(data, 0, size)) { fail(ctx, "invalid text argument"); return NULL; }
    length = size ? MultiByteToWideChar(codepage, codepage == CP_UTF8 ? MB_ERR_INVALID_CHARS : 0,
        data, (int)size, NULL, 0) : 0;
    if (size && !length) { win_fail(ctx, "decode text"); return NULL; }
    result = (wchar_t *)allocate(ctx, ((size_t)length + 1) * sizeof(wchar_t));
    if (!result) return NULL;
    if (length && MultiByteToWideChar(codepage, codepage == CP_UTF8 ? MB_ERR_INVALID_CHARS : 0,
        data, (int)size, result, length) != length) { win_fail(ctx, "decode text"); return NULL; }
    result[length] = 0;
    return result;
}

static wchar_t *argument(context *ctx, unsigned int index)
{
    if (index >= ctx->count) { fail(ctx, "missing native argument"); return NULL; }
    return wide(ctx, ctx->fields[index].data, ctx->fields[index].size, CP_UTF8);
}

static int utf8(context *ctx, buffer *out, const wchar_t *value)
{
    int length = WideCharToMultiByte(CP_UTF8, 0, value, -1, NULL, 0, NULL, NULL);
    char *converted;
    if (!length) return win_fail(ctx, "encode text");
    converted = (char *)allocate(ctx, (size_t)length);
    if (!converted) return 0;
    if (WideCharToMultiByte(CP_UTF8, 0, value, -1, converted, length, NULL, NULL) != length) return win_fail(ctx, "encode text");
    return append(ctx, out, converted, (size_t)length - 1);
}

static wchar_t *full_path(context *ctx, const wchar_t *value)
{
    DWORD size = GetFullPathNameW(value, 0, NULL, NULL), written;
    wchar_t *result;
    if (!size) { win_fail(ctx, "resolve path"); return NULL; }
    result = (wchar_t *)allocate(ctx, ((size_t)size + 1) * sizeof(wchar_t));
    if (!result) return NULL;
    written = GetFullPathNameW(value, size + 1, result, NULL);
    if (!written || written > size) { win_fail(ctx, "resolve path"); return NULL; }
    return result;
}

static wchar_t *file_path(context *ctx, const wchar_t *value)
{
    wchar_t *full = full_path(ctx, value), *extended;
    size_t length;
    if (!full) return NULL;
    length = wcslen(full);
    if (length < 248 || wcsncmp(full, L"\\\\?\\", 4) == 0) return full;
    if (length > (size_t)-1 / sizeof(wchar_t) - 9) { fail(ctx, "path is too large"); return NULL; }
    extended = (wchar_t *)allocate(ctx, (length + 9) * sizeof(wchar_t));
    if (!extended) return NULL;
    if (full[0] == L'\\' && full[1] == L'\\') {
        memcpy(extended, L"\\\\?\\UNC\\", 8 * sizeof(wchar_t));
        memcpy(extended + 8, full + 2, (length - 1) * sizeof(wchar_t));
    } else {
        memcpy(extended, L"\\\\?\\", 4 * sizeof(wchar_t));
        memcpy(extended + 4, full, (length + 1) * sizeof(wchar_t));
    }
    return extended;
}

static wchar_t *join(context *ctx, const wchar_t *left, const wchar_t *right)
{
    size_t a = wcslen(left), b = wcslen(right);
    wchar_t *result;
    if (a > (size_t)-1 / sizeof(wchar_t) - b - 2) { fail(ctx, "path is too large"); return NULL; }
    result = (wchar_t *)allocate(ctx, (a + b + 2) * sizeof(wchar_t));
    if (!result) return NULL;
    memcpy(result, left, a * sizeof(wchar_t));
    if (a && left[a - 1] != L'\\' && left[a - 1] != L'/') result[a++] = L'\\';
    memcpy(result + a, right, (b + 1) * sizeof(wchar_t));
    return result;
}

static size_t root_length(const wchar_t *value)
{
    size_t index;
    if (wcsncmp(value, L"\\\\?\\", 4) == 0 && value[4] && value[5] == L':') return 7;
    if (_wcsnicmp(value, L"\\\\?\\UNC\\", 8) == 0) {
        index = 8;
        while (value[index] && value[index] != L'\\') ++index;
        if (value[index]) ++index;
        while (value[index] && value[index] != L'\\') ++index;
        return value[index] ? index + 1 : index;
    }
    if (value[0] && value[1] == L':' && (value[2] == L'\\' || value[2] == L'/')) return 3;
    if (value[0] == L'\\' && value[1] == L'\\') {
        index = 2;
        while (value[index] && value[index] != L'\\') ++index;
        if (value[index]) ++index;
        while (value[index] && value[index] != L'\\') ++index;
        return value[index] ? index + 1 : index;
    }
    return 0;
}

static int parents(context *ctx, const wchar_t *value, int create)
{
    wchar_t *path = full_path(ctx, value);
    size_t index, start;
    DWORD attributes;
    if (!path) return 0;
    start = root_length(path);
    if (!start) return fail(ctx, "path has no root");
    for (index = start; path[index]; ++index) {
        if (path[index] != L'\\' && path[index] != L'/') continue;
        path[index] = 0;
        attributes = GetFileAttributesW(path);
        if (attributes == INVALID_FILE_ATTRIBUTES && create) {
            if (!CreateDirectoryW(path, NULL) && GetLastError() != ERROR_ALREADY_EXISTS) return win_fail(ctx, "create ancestor");
            attributes = GetFileAttributesW(path);
        }
        if (attributes == INVALID_FILE_ATTRIBUTES) return win_fail(ctx, "inspect ancestor");
        if (!(attributes & FILE_ATTRIBUTE_DIRECTORY) || (attributes & FILE_ATTRIBUTE_REPARSE_POINT)) return fail(ctx, "unsafe directory ancestor");
        path[index] = L'\\';
    }
    return 1;
}

static int safe_attributes(context *ctx, const wchar_t *path, int directory)
{
    DWORD attributes = GetFileAttributesW(path);
    if (attributes == INVALID_FILE_ATTRIBUTES) return win_fail(ctx, "inspect path");
    if ((attributes & FILE_ATTRIBUTE_REPARSE_POINT) || ((attributes & FILE_ATTRIBUTE_DIRECTORY) != 0) != directory) return fail(ctx, "unsafe path type");
    return 1;
}

static int owned_path(context *ctx, const wchar_t *path)
{
    HANDLE file, token;
    PSID owner = NULL;
    PSECURITY_DESCRIPTOR descriptor = NULL;
    TOKEN_USER *user;
    TOKEN_OWNER *default_owner;
    DWORD required = 0, error;
    int matches;
    file = CreateFileW(path, READ_CONTROL, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (file == INVALID_HANDLE_VALUE) return win_fail(ctx, "inspect ownership");
    if (!track(ctx, file)) return 0;
    error = GetSecurityInfo(file, SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION, &owner, NULL, NULL, NULL, &descriptor);
    close_handle(ctx, file);
    if (error != ERROR_SUCCESS) { SetLastError(error); return win_fail(ctx, "read ownership"); }
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) { LocalFree(descriptor); return win_fail(ctx, "open owner token"); }
    if (!track(ctx, token)) { LocalFree(descriptor); return 0; }
    GetTokenInformation(token, TokenUser, NULL, 0, &required);
    user = (TOKEN_USER *)allocate(ctx, required);
    if (!user || !GetTokenInformation(token, TokenUser, user, required, &required)) {
        LocalFree(descriptor); return win_fail(ctx, "read owner token");
    }
    matches = owner && EqualSid(owner, user->User.Sid);
    GetTokenInformation(token, TokenOwner, NULL, 0, &required);
    default_owner = (TOKEN_OWNER *)allocate(ctx, required);
    if (!default_owner || !GetTokenInformation(token, TokenOwner, default_owner, required, &required)) {
        LocalFree(descriptor); return win_fail(ctx, "read default owner");
    }
    matches = matches || (owner && EqualSid(owner, default_owner->Owner));
    close_handle(ctx, token); LocalFree(descriptor);
    return text(ctx, matches ? "yes" : "no");
}

static int path_type(context *ctx, const wchar_t *path)
{
    DWORD attributes = GetFileAttributesW(path), error;
    if (attributes == INVALID_FILE_ATTRIBUTES) {
        error = GetLastError();
        if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND || error == ERROR_INVALID_NAME) return text(ctx, "missing");
        return win_fail(ctx, "inspect path");
    }
    return text(ctx, attributes & FILE_ATTRIBUTE_REPARSE_POINT ? "reparse"
        : attributes & FILE_ATTRIBUTE_DIRECTORY ? "directory" : attributes & FILE_ATTRIBUTE_DEVICE ? "other" : "file");
}

static int read_file(context *ctx, const wchar_t *path, DWORD limit)
{
    HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    char chunk[65536];
    DWORD size;
    if (file == INVALID_HANDLE_VALUE) return win_fail(ctx, "read file");
    if (!track(ctx, file)) return 0;
    for (;;) {
        if (!ReadFile(file, chunk, sizeof(chunk), &size, NULL)) return win_fail(ctx, "read file");
        if (!size) break;
        if (limit && ctx->result.size + size > limit) return fail(ctx, "file exceeds read limit");
        if (!append(ctx, &ctx->result, chunk, size)) return 0;
    }
    close_handle(ctx, file);
    return 1;
}

static int write_file(context *ctx, const wchar_t *path, field *value, int exclusive)
{
    HANDLE file;
    BY_HANDLE_FILE_INFORMATION info;
    size_t offset = 0;
    DWORD wrote, size;
    LARGE_INTEGER zero;
    if (!parents(ctx, path, 0)) return 0;
    file = CreateFileW(path, GENERIC_WRITE | FILE_READ_ATTRIBUTES, 0, NULL,
        exclusive ? CREATE_NEW : OPEN_ALWAYS, FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (file == INVALID_HANDLE_VALUE) return win_fail(ctx, "open output file");
    if (!track(ctx, file)) return 0;
    if (!GetFileInformationByHandle(file, &info)) return win_fail(ctx, "inspect output file");
    if (info.dwFileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY)) return fail(ctx, "unsafe output file");
    zero.QuadPart = 0;
    if (!SetFilePointerEx(file, zero, NULL, FILE_BEGIN) || !SetEndOfFile(file)) return win_fail(ctx, "truncate output file");
    while (offset < value->size) {
        size = (DWORD)(value->size - offset > 65536 ? 65536 : value->size - offset);
        if (!WriteFile(file, value->data + offset, size, &wrote, NULL) || !wrote) return win_fail(ctx, "write file");
        offset += wrote;
    }
    if (!FlushFileBuffers(file)) return win_fail(ctx, "flush file");
    close_handle(ctx, file);
    return 1;
}

static int private_directory(context *ctx, const wchar_t *parent, const wchar_t *label)
{
    HANDLE token;
    DWORD required = 0;
    TOKEN_USER *user;
    LPWSTR sid = NULL;
    PSECURITY_DESCRIPTOR descriptor = NULL;
    SECURITY_ATTRIBUTES security;
    wchar_t *sddl, *candidate, *absolute;
    wchar_t name[256];
    HCRYPTPROV provider = 0;
    BYTE random[16];
    unsigned int attempt, index;
    size_t length;
    static const wchar_t hex[] = L"0123456789abcdef";
    absolute = full_path(ctx, parent);
    if (!absolute || !parents(ctx, absolute, 0) || !safe_attributes(ctx, absolute, 1)) return 0;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return win_fail(ctx, "open user token");
    if (!track(ctx, token)) return 0;
    GetTokenInformation(token, TokenUser, NULL, 0, &required);
    user = (TOKEN_USER *)allocate(ctx, required);
    if (!user) return 0;
    if (!GetTokenInformation(token, TokenUser, user, required, &required)) return win_fail(ctx, "read user token");
    close_handle(ctx, token);
    if (!ConvertSidToStringSidW(user->User.Sid, &sid)) return win_fail(ctx, "format user SID");
    length = wcslen(sid) * 2 + 96;
    sddl = (wchar_t *)allocate(ctx, length * sizeof(wchar_t));
    if (!sddl) { LocalFree(sid); return 0; }
    if (_snwprintf(sddl, length, L"O:%lsD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;%ls)", sid, sid) < 0) {
        LocalFree(sid); return fail(ctx, "security descriptor is too long");
    }
    LocalFree(sid);
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, SDDL_REVISION_1, &descriptor, NULL)) return win_fail(ctx, "create private ACL");
    security.nLength = sizeof(security); security.lpSecurityDescriptor = descriptor; security.bInheritHandle = FALSE;
    if (!CryptAcquireContextW(&provider, NULL, NULL, PROV_RSA_FULL, CRYPT_VERIFYCONTEXT | CRYPT_SILENT)) {
        LocalFree(descriptor); return win_fail(ctx, "acquire random provider");
    }
    length = wcslen(label);
    if (length > 160) length = 160;
    for (attempt = 0; attempt < 40; ++attempt) {
        memcpy(name, L"luainstaller-", 13 * sizeof(wchar_t));
        memcpy(name + 13, label, length * sizeof(wchar_t));
        name[13 + length] = L'-';
        if (!CryptGenRandom(provider, sizeof(random), random)) break;
        for (index = 0; index < sizeof(random); ++index) {
            name[14 + length + index * 2] = hex[random[index] >> 4];
            name[15 + length + index * 2] = hex[random[index] & 15];
        }
        name[14 + length + sizeof(random) * 2] = 0;
        candidate = join(ctx, absolute, name);
        if (!candidate) break;
        {
            wchar_t *extended = file_path(ctx, candidate);
            if (!extended) break;
            if (CreateDirectoryW(extended, &security)) {
            CryptReleaseContext(provider, 0); LocalFree(descriptor);
            return utf8(ctx, &ctx->result, candidate);
            }
        }
        if (GetLastError() != ERROR_ALREADY_EXISTS) break;
    }
    CryptReleaseContext(provider, 0); LocalFree(descriptor);
    return win_fail(ctx, "create private directory");
}

typedef struct tree_entry { wchar_t *path; DWORD attributes; } tree_entry;
static int tree(context *ctx, const wchar_t *root, int remove_all, int recursive)
{
    tree_entry *entries = NULL, *next;
    size_t count = 0, capacity = 0, index, offset;
    wchar_t *absolute = full_path(ctx, root), *pattern, *child;
    WIN32_FIND_DATAW found;
    HANDLE search;
    DWORD error;
    if (!absolute || !safe_attributes(ctx, absolute, 1) || !parents(ctx, absolute, 0)) return 0;
    offset = wcslen(absolute);
#define ADD_ENTRY(p, attr) do { \
    if (count == capacity) { \
        size_t new_capacity = capacity ? capacity * 2 : 32; \
        if (new_capacity < capacity || new_capacity > (size_t)-1 / sizeof(*entries)) return fail(ctx, "tree is too large"); \
        next = (tree_entry *)allocate(ctx, new_capacity * sizeof(*entries)); \
        if (!next) return 0; \
        if (count) memcpy(next, entries, count * sizeof(*entries)); \
        entries = next; capacity = new_capacity; \
    } \
    entries[count].path = p; entries[count].attributes = attr; ++count; \
} while (0)
    ADD_ENTRY(absolute, FILE_ATTRIBUTE_DIRECTORY);
    for (index = 0; index < count; ++index) {
        if (index && !recursive) continue;
        if (!(entries[index].attributes & FILE_ATTRIBUTE_DIRECTORY) || (entries[index].attributes & FILE_ATTRIBUTE_REPARSE_POINT)) continue;
        if (!safe_attributes(ctx, entries[index].path, 1) || !parents(ctx, entries[index].path, 0)) return 0;
        pattern = join(ctx, entries[index].path, L"*");
        if (!pattern) return 0;
        search = FindFirstFileW(pattern, &found);
        if (search == INVALID_HANDLE_VALUE) {
            if (GetLastError() == ERROR_FILE_NOT_FOUND) continue;
            return win_fail(ctx, "list directory");
        }
        ctx->search = search;
        do {
            if (wcscmp(found.cFileName, L".") == 0 || wcscmp(found.cFileName, L"..") == 0) continue;
            child = join(ctx, entries[index].path, found.cFileName);
            if (!child) return 0;
            if (remove_all && (found.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
                return fail(ctx, "refusing to remove a tree containing a reparse point");
            }
            ADD_ENTRY(child, found.dwFileAttributes);
        } while (FindNextFileW(search, &found));
        error = GetLastError();
        FindClose(search);
        ctx->search = NULL;
        if (error != ERROR_NO_MORE_FILES) { SetLastError(error); return win_fail(ctx, "list directory"); }
    }
    if (remove_all) {
        while (count) {
            --count;
            if (!parents(ctx, entries[count].path, 0)
                || !safe_attributes(ctx, entries[count].path, (entries[count].attributes & FILE_ATTRIBUTE_DIRECTORY) != 0)) return 0;
            if (!(entries[count].attributes & FILE_ATTRIBUTE_DIRECTORY)) {
                if (!DeleteFileW(entries[count].path)) return win_fail(ctx, "remove file");
            } else if (!RemoveDirectoryW(entries[count].path)) return win_fail(ctx, "remove directory");
        }
        return 1;
    }
    for (index = 1; index < count; ++index) {
        const char *kind = entries[index].attributes & FILE_ATTRIBUTE_REPARSE_POINT ? "reparse"
            : entries[index].attributes & FILE_ATTRIBUTE_DIRECTORY ? "directory" : "file";
        const wchar_t *relative = entries[index].path + offset;
        if (*relative == L'\\' || *relative == L'/') ++relative;
        if (!text(ctx, kind) || !append(ctx, &ctx->result, "", 1)
            || !utf8(ctx, &ctx->result, relative) || !append(ctx, &ctx->result, "", 1)) return 0;
    }
    return 1;
#undef ADD_ENTRY
}

static int decimal(context *ctx, unsigned int index, DWORD *out)
{
    size_t position;
    DWORD value = 0, digit;
    if (index >= ctx->count || !ctx->fields[index].size) return fail(ctx, "missing integer argument");
    for (position = 0; position < ctx->fields[index].size; ++position) {
        digit = (DWORD)(unsigned char)ctx->fields[index].data[position] - '0';
        if (digit > 9 || value > (MAXDWORD - digit) / 10) return fail(ctx, "invalid integer argument");
        value = value * 10 + digit;
    }
    *out = value;
    return 1;
}

static int append_wide(context *ctx, buffer *out, const wchar_t *value, size_t count)
{
    if (count > (size_t)-1 / sizeof(wchar_t)) return fail(ctx, "command is too long");
    return append(ctx, out, value, count * sizeof(wchar_t));
}

static int quote_argument(context *ctx, buffer *out, const wchar_t *value)
{
    size_t slashes = 0, index;
    if (!append_wide(ctx, out, L"\"", 1)) return 0;
    for (index = 0; value[index]; ++index) {
        if (value[index] == L'\\') { ++slashes; continue; }
        if (value[index] == L'\"') slashes = slashes * 2 + 1;
        while (slashes) { if (!append_wide(ctx, out, L"\\", 1)) return 0; --slashes; }
        if (!append_wide(ctx, out, value + index, 1)) return 0;
    }
    while (slashes) { if (!append_wide(ctx, out, L"\\\\", 2)) return 0; --slashes; }
    return append_wide(ctx, out, L"\"", 1);
}

static int environment_compare(const void *a, const void *b)
{
    const wchar_t *left = *(const wchar_t *const *)a, *right = *(const wchar_t *const *)b;
    int comparison = CompareStringW(LOCALE_INVARIANT, NORM_IGNORECASE, left, -1, right, -1);
    return comparison ? comparison - CSTR_EQUAL : wcscmp(left, right);
}

static wchar_t *environment(context *ctx, unsigned int first, DWORD count)
{
    LPWCH original = GetEnvironmentStringsW(), cursor;
    size_t existing = 0, index, total;
    DWORD item;
    wchar_t **values, *key, *value, *entry;
    buffer block = {0};
    if (!original) { win_fail(ctx, "read environment"); return NULL; }
    for (cursor = original; *cursor; cursor += wcslen(cursor) + 1) ++existing;
    if (existing > (size_t)-1 / sizeof(*values) - count - 1) { FreeEnvironmentStringsW(original); fail(ctx, "environment is too large"); return NULL; }
    values = (wchar_t **)allocate(ctx, (existing + count + 1) * sizeof(*values));
    if (!values) { FreeEnvironmentStringsW(original); return NULL; }
    total = 0;
    for (cursor = original; *cursor; cursor += wcslen(cursor) + 1) {
        size_t size = (wcslen(cursor) + 1) * sizeof(wchar_t);
        values[total] = (wchar_t *)allocate(ctx, size);
        if (!values[total]) { FreeEnvironmentStringsW(original); return NULL; }
        memcpy(values[total++], cursor, size);
    }
    FreeEnvironmentStringsW(original);
    for (item = 0; item < count; ++item) {
        size_t length, size;
        key = argument(ctx, first + item * 2); value = argument(ctx, first + item * 2 + 1);
        if (!key || !value || !*key || wcschr(key, L'=')) { fail(ctx, "invalid environment key"); return NULL; }
        length = wcslen(key); size = length + wcslen(value) + 2;
        entry = (wchar_t *)allocate(ctx, size * sizeof(wchar_t));
        if (!entry) return NULL;
        memcpy(entry, key, length * sizeof(wchar_t)); entry[length] = L'=';
        memcpy(entry + length + 1, value, (wcslen(value) + 1) * sizeof(wchar_t));
        for (index = 0; index < total; ++index) {
            wchar_t *separator = wcschr(values[index], L'=');
            if (separator && (size_t)(separator - values[index]) == length
                && CompareStringW(LOCALE_INVARIANT, NORM_IGNORECASE, values[index], (int)length, key, (int)length) == CSTR_EQUAL) break;
        }
        if (index == total) ++total;
        values[index] = entry;
    }
    qsort(values, total, sizeof(*values), environment_compare);
    for (index = 0; index < total; ++index) if (!append_wide(ctx, &block, values[index], wcslen(values[index]) + 1)) return NULL;
    if (!append_wide(ctx, &block, L"", 1)) return NULL;
    return (wchar_t *)block.data;
}

static void kill_descendants(DWORD root, unsigned int depth)
{
    HANDLE snapshot, process;
    PROCESSENTRY32W entry;
    if (depth > 64) return;
    snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) return;
    memset(&entry, 0, sizeof(entry)); entry.dwSize = sizeof(entry);
    if (Process32FirstW(snapshot, &entry)) do {
        if (entry.th32ParentProcessID == root && entry.th32ProcessID != root) {
            kill_descendants(entry.th32ProcessID, depth + 1);
            process = OpenProcess(PROCESS_TERMINATE | SYNCHRONIZE, FALSE, entry.th32ProcessID);
            if (process) { TerminateProcess(process, 124); CloseHandle(process); }
        }
    } while (Process32NextW(snapshot, &entry));
    CloseHandle(snapshot);
}

static int legacy_jobs(void)
{
    typedef LONG (WINAPI *version_fn)(OSVERSIONINFOW *);
    union { FARPROC raw; version_fn typed; } version;
    OSVERSIONINFOW info;
    version.raw = GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "RtlGetVersion");
    memset(&info, 0, sizeof(info)); info.dwOSVersionInfoSize = sizeof(info);
    if (!version.typed || version.typed(&info) != 0) return 1;
    return info.dwMajorVersion < 6 || (info.dwMajorVersion == 6 && info.dwMinorVersion < 2);
}

static int parse_handle(const wchar_t **cursor, ULONG_PTR *value)
{
    unsigned int digit;
    int any = 0;
    *value = 0;
    while (**cursor == L' ') ++*cursor;
    if ((*cursor)[0] == L'0' && ((*cursor)[1] == L'x' || (*cursor)[1] == L'X')) *cursor += 2;
    while (**cursor && **cursor != L' ') {
        wchar_t character = *(*cursor)++;
        if (character >= L'0' && character <= L'9') digit = (unsigned int)(character - L'0');
        else if (character >= L'a' && character <= L'f') digit = (unsigned int)(character - L'a' + 10);
        else if (character >= L'A' && character <= L'F') digit = (unsigned int)(character - L'A' + 10);
        else return 0;
        if (*value > ((ULONG_PTR)-1 - digit) / 16) return 0;
        *value = *value * 16 + digit; any = 1;
    }
    return any;
}

__declspec(dllexport) void CALLBACK luainstaller_host_watchdogW(HWND window, HINSTANCE instance, LPWSTR command, int show)
{
    ULONG_PTR values[6];
    const wchar_t *cursor = command;
    HANDLE waits[2];
    unsigned int index;
    (void)window; (void)instance; (void)show;
    for (index = 0; index < 6; ++index) if (!parse_handle(&cursor, &values[index])) ExitProcess(125);
    if (!SetEvent((HANDLE)values[5])) ExitProcess(125);
    CloseHandle((HANDLE)values[5]);
    waits[0] = (HANDLE)values[0]; waits[1] = (HANDLE)values[1];
    if (WaitForMultipleObjects(2, waits, FALSE, INFINITE) == WAIT_OBJECT_0) {
        kill_descendants((DWORD)values[4], 0);
        if (values[2]) TerminateJobObject((HANDLE)values[2], 124);
        TerminateProcess((HANDLE)values[3], 124);
    }
    for (index = 0; index < 4; ++index) if (values[index]) CloseHandle((HANDLE)values[index]);
    ExitProcess(0);
}

static HANDLE watchdog(context *ctx, HANDLE child, DWORD pid, HANDLE job, HANDLE finished)
{
    HANDLE current = GetCurrentProcess(), inherited[5] = {NULL, NULL, NULL, NULL, NULL};
    HANDLE ready, waits[2];
    STARTUPINFOW startup;
    PROCESS_INFORMATION process;
    wchar_t system[MAX_PATH + 1], module[32768], command[32768];
    DWORD length;
    int count;
    unsigned int index;
    HANDLE result = NULL;
    ready = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!ready) { win_fail(ctx, "create watchdog handshake"); return NULL; }
    length = GetSystemDirectoryW(system, MAX_PATH + 1);
    if (!length || length >= MAX_PATH - 14) { win_fail(ctx, "locate watchdog host"); CloseHandle(ready); return NULL; }
    memcpy(system + length, L"\\rundll32.exe", 14 * sizeof(wchar_t));
    length = GetModuleFileNameW(own_module, module, sizeof(module) / sizeof(module[0]));
    if (!length || length >= sizeof(module) / sizeof(module[0])) { win_fail(ctx, "locate native module"); CloseHandle(ready); return NULL; }
    if (!DuplicateHandle(current, current, current, &inherited[0], SYNCHRONIZE, TRUE, 0)
        || !DuplicateHandle(current, finished, current, &inherited[1], SYNCHRONIZE, TRUE, 0)
        || (job && !DuplicateHandle(current, job, current, &inherited[2], JOB_OBJECT_TERMINATE, TRUE, 0))
        || !DuplicateHandle(current, child, current, &inherited[3], SYNCHRONIZE | PROCESS_TERMINATE, TRUE, 0)
        || !DuplicateHandle(current, ready, current, &inherited[4], EVENT_MODIFY_STATE, TRUE, 0)) {
        win_fail(ctx, "duplicate watchdog handles"); goto done;
    }
    count = _snwprintf(command, sizeof(command) / sizeof(command[0]),
        L"\"%ls\" \"%ls\",luainstaller_host_watchdog %p %p %p %p %lx %p", system, module,
        (void *)inherited[0], (void *)inherited[1], (void *)inherited[2], (void *)inherited[3], (unsigned long)pid,
        (void *)inherited[4]);
    if (count < 0 || (size_t)count >= sizeof(command) / sizeof(command[0])) { fail(ctx, "watchdog command is too long"); goto done; }
    memset(&startup, 0, sizeof(startup)); startup.cb = sizeof(startup);
    memset(&process, 0, sizeof(process));
    if (!CreateProcessW(system, command, NULL, NULL, TRUE, CREATE_NO_WINDOW, NULL, NULL, &startup, &process)) {
        win_fail(ctx, "start process watchdog"); goto done;
    }
    CloseHandle(process.hThread);
    waits[0] = ready; waits[1] = process.hProcess;
    if (WaitForMultipleObjects(2, waits, FALSE, 5000) != WAIT_OBJECT_0) {
        TerminateProcess(process.hProcess, 125); CloseHandle(process.hProcess);
        fail(ctx, "process watchdog did not initialize"); goto done;
    }
    result = process.hProcess;
done:
    for (index = 0; index < 5; ++index) if (inherited[index]) CloseHandle(inherited[index]);
    CloseHandle(ready);
    return result;
}

static int drain(context *ctx, HANDLE pipe, buffer *output, int *closed)
{
    DWORD available, read;
    char chunk[65536];
    if (*closed) return 1;
    if (!PeekNamedPipe(pipe, NULL, 0, NULL, &available, NULL)) {
        if (GetLastError() == ERROR_BROKEN_PIPE) { *closed = 1; return 1; }
        return win_fail(ctx, "inspect child output");
    }
    if (!available) return 1;
    if (!ReadFile(pipe, chunk, available > sizeof(chunk) ? sizeof(chunk) : available, &read, NULL)) {
        if (GetLastError() == ERROR_BROKEN_PIPE) { *closed = 1; return 1; }
        return win_fail(ctx, "read child output");
    }
    return append(ctx, output, chunk, read);
}

static int child_text(context *ctx, buffer *value)
{
    int length;
    wchar_t *converted;
    if (!value->size) return 1;
    if (value->size > INT_MAX) return fail(ctx, "child output is too large");
    length = MultiByteToWideChar(CP_ACP, 0, value->data, (int)value->size, NULL, 0);
    if (!length) return win_fail(ctx, "decode child output");
    converted = (wchar_t *)allocate(ctx, ((size_t)length + 1) * sizeof(wchar_t));
    if (!converted) return 0;
    if (!MultiByteToWideChar(CP_ACP, 0, value->data, (int)value->size, converted, length)) return win_fail(ctx, "decode child output");
    converted[length] = 0;
    /* Preserve embedded NUL bytes instead of treating process output as a C string. */
    length = WideCharToMultiByte(CP_UTF8, 0, converted, length, NULL, 0, NULL, NULL);
    if (length) {
        char *bytes = (char *)allocate(ctx, (size_t)length);
        int wide_length = MultiByteToWideChar(CP_ACP, 0, value->data, (int)value->size, NULL, 0);
        if (!bytes) return 0;
        if (!WideCharToMultiByte(CP_UTF8, 0, converted, wide_length, bytes, length, NULL, NULL)) return win_fail(ctx, "encode child output");
        return append(ctx, &ctx->result, bytes, (size_t)length);
    }
    return win_fail(ctx, "encode child output");
}

static int execute(context *ctx)
{
    wchar_t *program = argument(ctx, 1), *value, *env = NULL;
    buffer command = {0}, output = {0}, diagnostic = {0};
    DWORD timeout, count, env_count, index, started, status = 0;
    HANDLE out_read, out_write, err_read, err_write, job = NULL, input, finished = NULL, guard = NULL;
    SECURITY_ATTRIBUTES security;
    STARTUPINFOW startup;
    PROCESS_INFORMATION child;
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits;
    int out_closed = 0, err_closed = 0, timed_out = 0, failed = 0, legacy = legacy_jobs();
    int command_shell = 0, shell_body = 0;
    if (!program || !decimal(ctx, 2, &timeout) || !decimal(ctx, 3, &count)
        || count > ctx->count - 4 || !decimal(ctx, 4 + count, &env_count)
        || env_count > (ctx->count - 5 - count) / 2 || 5 + count + env_count * 2 != ctx->count) return fail(ctx, "invalid process request");
    if (!quote_argument(ctx, &command, program)) return 0;
    {
        const wchar_t *base = program, *position;
        for (position = program; *position; ++position) if (*position == L'\\' || *position == L'/') base = position + 1;
        command_shell = _wcsicmp(base, L"cmd.exe") == 0 || _wcsicmp(base, L"cmd") == 0;
    }
    for (index = 0; index < count; ++index) {
        value = argument(ctx, 4 + index);
        if (!value || !append_wide(ctx, &command, L" ", 1)) return 0;
        /* cmd.exe parses its own command line, not the C-runtime argv rules.
         * Preserve the explicitly requested /c or /k script verbatim. */
        if (command_shell && shell_body && index + 1 == count) {
            if (!append_wide(ctx, &command, L"\"", 1)
                || !append_wide(ctx, &command, value, wcslen(value))
                || !append_wide(ctx, &command, L"\"", 1)) return 0;
        } else if (command_shell && !shell_body && value[0] == L'/'
            && wcsspn(value, L"/:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789") == wcslen(value)) {
            if (!append_wide(ctx, &command, value, wcslen(value))) return 0;
        } else if (!quote_argument(ctx, &command, value)) return 0;
        if (command_shell && (_wcsicmp(value, L"/c") == 0 || _wcsicmp(value, L"/k") == 0)) shell_body = 1;
    }
    if (command.size / sizeof(wchar_t) >= 32767 || !append_wide(ctx, &command, L"", 1)) return fail(ctx, "Windows command line is too long");
    if (env_count) { env = environment(ctx, 5 + count, env_count); if (!env) return 0; }
    memset(&security, 0, sizeof(security)); security.nLength = sizeof(security); security.bInheritHandle = TRUE;
    if (!CreatePipe(&out_read, &out_write, &security, 0)) return win_fail(ctx, "create stdout pipe");
    if (!track(ctx, out_read) || !track(ctx, out_write)) return 0;
    if (!CreatePipe(&err_read, &err_write, &security, 0)) return win_fail(ctx, "create stderr pipe");
    if (!track(ctx, err_read) || !track(ctx, err_write)) return 0;
    if (!SetHandleInformation(out_read, HANDLE_FLAG_INHERIT, 0) || !SetHandleInformation(err_read, HANDLE_FLAG_INHERIT, 0)) return win_fail(ctx, "protect pipe handles");
    input = GetStdHandle(STD_INPUT_HANDLE);
    if (!input || input == INVALID_HANDLE_VALUE) {
        input = CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, &security, OPEN_EXISTING, 0, NULL);
        if (!track(ctx, input)) return win_fail(ctx, "open child stdin");
    }
    memset(&startup, 0, sizeof(startup)); startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW; startup.wShowWindow = SW_HIDE;
    startup.hStdInput = input; startup.hStdOutput = out_write; startup.hStdError = err_write;
    memset(&child, 0, sizeof(child));
    if (!CreateProcessW(NULL, (wchar_t *)command.data, NULL, NULL, TRUE,
        CREATE_NO_WINDOW | CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT, env, NULL, &startup, &child)) return win_fail(ctx, "start process");
    if (!track(ctx, child.hProcess) || !track(ctx, child.hThread)) return 0;
    job = CreateJobObjectW(NULL, NULL);
    if (job) {
        memset(&limits, 0, sizeof(limits)); limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if (legacy) limits.BasicLimitInformation.LimitFlags |= JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK;
        if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits))) {
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK;
            if (!legacy || !SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits))) {
                CloseHandle(job); job = NULL;
            }
        }
        if (job && !AssignProcessToJobObject(job, child.hProcess)) { CloseHandle(job); job = NULL; }
        else if (job && !track(ctx, job)) return 0;
    }
    close_handle(ctx, out_write); close_handle(ctx, err_write);
    if (legacy || !job) {
        finished = CreateEventW(NULL, TRUE, FALSE, NULL);
        if (!finished || !track(ctx, finished)) { TerminateProcess(child.hProcess, 127); return win_fail(ctx, "create watchdog event"); }
        guard = watchdog(ctx, child.hProcess, child.dwProcessId, job, finished);
        if (!guard || !track(ctx, guard)) { TerminateProcess(child.hProcess, 127); return 0; }
    }
    if (ResumeThread(child.hThread) == (DWORD)-1) { TerminateProcess(child.hProcess, 127); return win_fail(ctx, "resume process"); }
    close_handle(ctx, child.hThread);
    started = GetTickCount();
    while (!out_closed || !err_closed || WaitForSingleObject(child.hProcess, 0) == WAIT_TIMEOUT) {
        if (!drain(ctx, out_read, &output, &out_closed) || !drain(ctx, err_read, &diagnostic, &err_closed)) { failed = 1; break; }
        if (timeout && GetTickCount() - started >= timeout) { timed_out = 1; break; }
        Sleep(1);
    }
    if (timed_out || failed) {
        if (legacy || !job) kill_descendants(child.dwProcessId, 0);
        if (job) TerminateJobObject(job, 124);
        else TerminateProcess(child.hProcess, 124);
    }
    WaitForSingleObject(child.hProcess, INFINITE);
    if (!GetExitCodeProcess(child.hProcess, &status)) return win_fail(ctx, "read process status");
    if (legacy || !job) kill_descendants(child.dwProcessId, 0);
    if (finished) {
        SetEvent(finished);
        if (WaitForSingleObject(guard, 5000) != WAIT_OBJECT_0) TerminateProcess(guard, 125);
        close_handle(ctx, guard); close_handle(ctx, finished);
    }
    close_handle(ctx, out_read); close_handle(ctx, err_read); close_handle(ctx, child.hProcess);
    if (job) close_handle(ctx, job);
    if (failed) return 0;
    if (!child_text(ctx, &output) || !child_text(ctx, &diagnostic)) return 0;
    if (timed_out && !text(ctx, "\nluainstaller: command timed out")) return 0;
    if (_snprintf(ctx->extra, sizeof(ctx->extra), "%lu", (unsigned long)(timed_out ? 124 : status)) < 0) return fail(ctx, "cannot format process status");
    ctx->ok = !timed_out && status == 0;
    return 1;
}

static int dispatch(context *ctx)
{
    field *op = &ctx->fields[0];
    wchar_t *path = NULL, *other;
    DWORD attributes, value, size, written;
    HANDLE handle;
    BY_HANDLE_FILE_INFORMATION info;
    ULARGE_INTEGER stamp;
    if (equals(op, "exec")) return execute(ctx);
    if (equals(op, "cwd")) {
        size = GetCurrentDirectoryW(0, NULL);
        path = (wchar_t *)allocate(ctx, ((size_t)size + 1) * sizeof(wchar_t));
        if (!path) return 0;
        written = GetCurrentDirectoryW(size + 1, path);
        if (!written || written > size) return win_fail(ctx, "read current directory");
        return utf8(ctx, &ctx->result, path);
    }
    if (equals(op, "pid")) return number(ctx, GetCurrentProcessId());
    if (equals(op, "sleep")) { if (!decimal(ctx, 1, &value)) return 0; Sleep(value); return 1; }
    if (equals(op, "alive")) {
        if (!decimal(ctx, 1, &value) || !value) return fail(ctx, "invalid process id");
        handle = OpenProcess(SYNCHRONIZE, FALSE, value);
        if (!handle) {
            if (GetLastError() == ERROR_INVALID_PARAMETER) return text(ctx, "no");
            return win_fail(ctx, "inspect process");
        }
        value = WaitForSingleObject(handle, 0); CloseHandle(handle);
        return text(ctx, value == WAIT_TIMEOUT ? "yes" : "no");
    }
    if (equals(op, "random")) {
        HCRYPTPROV provider;
        BYTE bytes[32];
        if (!CryptAcquireContextW(&provider, NULL, NULL, PROV_RSA_FULL, CRYPT_VERIFYCONTEXT | CRYPT_SILENT)) return win_fail(ctx, "acquire random provider");
        if (!CryptGenRandom(provider, sizeof(bytes), bytes)) { CryptReleaseContext(provider, 0); return win_fail(ctx, "generate random bytes"); }
        CryptReleaseContext(provider, 0);
        return append(ctx, &ctx->result, bytes, sizeof(bytes));
    }
    if (equals(op, "acp")) {
        if (ctx->count != 2) return fail(ctx, "invalid encoding request");
        path = wide(ctx, ctx->fields[1].data, ctx->fields[1].size, CP_ACP);
        return path && utf8(ctx, &ctx->result, path);
    }
    path = argument(ctx, 1);
    if (!path) return 0;
    if (equals(op, "which")) {
        wchar_t *search = ctx->count > 2 ? argument(ctx, 2) : NULL;
        if (ctx->count > 2 && !search) return 0;
        size = SearchPathW(search, path, L".exe", 0, NULL, NULL);
        if (!size) return win_fail(ctx, "locate program");
        other = (wchar_t *)allocate(ctx, ((size_t)size + 1) * sizeof(wchar_t));
        if (!other) return 0;
        written = SearchPathW(search, path, L".exe", size + 1, other, NULL);
        if (!written || written > size) return win_fail(ctx, "locate program");
        return utf8(ctx, &ctx->result, other);
    }
    if (equals(op, "env")) {
        SetLastError(ERROR_SUCCESS);
        size = GetEnvironmentVariableW(path, NULL, 0);
        if (!size) { if (GetLastError() == ERROR_ENVVAR_NOT_FOUND) strcpy(ctx->extra, "missing"); return 1; }
        other = (wchar_t *)allocate(ctx, ((size_t)size + 1) * sizeof(wchar_t));
        if (!other) return 0;
        written = GetEnvironmentVariableW(path, other, size + 1);
        if (!written || written > size) return win_fail(ctx, "read environment value");
        return utf8(ctx, &ctx->result, other);
    }
    if (equals(op, "private")) { other = argument(ctx, 2); return other && private_directory(ctx, other, path); }
    path = file_path(ctx, path);
    if (!path) return 0;
    if (equals(op, "owner")) return owned_path(ctx, path);
    if (equals(op, "type")) return path_type(ctx, path);
    if (equals(op, "read")) {
        value = 0;
        if (ctx->count > 2 && !decimal(ctx, 2, &value)) return 0;
        return read_file(ctx, path, value);
    }
    if (equals(op, "write")) {
        if (ctx->count != 3) return fail(ctx, "missing file contents");
        return write_file(ctx, path, &ctx->fields[2], 0);
    }
    if (equals(op, "mkdir") || equals(op, "create_dir")) {
        int recursive = equals(op, "mkdir");
        if (!parents(ctx, path, recursive)) return 0;
        if (!CreateDirectoryW(path, NULL) && (!recursive || GetLastError() != ERROR_ALREADY_EXISTS)) return win_fail(ctx, "create directory");
        return safe_attributes(ctx, path, 1);
    }
    if (equals(op, "rmdir")) {
        if (!parents(ctx, path, 0) || !safe_attributes(ctx, path, 1)) return 0;
        return RemoveDirectoryW(path) ? 1 : win_fail(ctx, "remove directory");
    }
    if (equals(op, "mtime")) {
        handle = CreateFileW(path, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
        if (handle == INVALID_HANDLE_VALUE) return win_fail(ctx, "open timestamp");
        if (!track(ctx, handle)) return 0;
        if (!GetFileInformationByHandle(handle, &info)) return win_fail(ctx, "read timestamp");
        close_handle(ctx, handle);
        stamp.LowPart = info.ftLastWriteTime.dwLowDateTime; stamp.HighPart = info.ftLastWriteTime.dwHighDateTime;
        stamp.QuadPart /= 10000000;
        if (stamp.QuadPart < 11644473600ULL) return text(ctx, "-") && number(ctx, 11644473600ULL - stamp.QuadPart);
        return number(ctx, stamp.QuadPart - 11644473600ULL);
    }
    if (equals(op, "copy") || equals(op, "rename") || equals(op, "link")) {
        other = argument(ctx, 2);
        if (other) other = file_path(ctx, other);
        if (!other || !parents(ctx, other, 0)) return 0;
        attributes = GetFileAttributesW(path);
        if (attributes == INVALID_FILE_ATTRIBUTES) return win_fail(ctx, "inspect source");
        if (attributes & FILE_ATTRIBUTE_REPARSE_POINT) return fail(ctx, "source is a reparse point");
        if (equals(op, "rename")) return MoveFileW(path, other) ? 1 : win_fail(ctx, "rename");
        if (attributes & FILE_ATTRIBUTE_DIRECTORY) return fail(ctx, "source is not a regular file");
        if (equals(op, "link")) return CreateHardLinkW(other, path, NULL) ? 1 : win_fail(ctx, "create hard link");
        return CopyFileW(path, other, TRUE) ? 1 : win_fail(ctx, "copy file");
    }
    if (equals(op, "list")) return tree(ctx, path, 0, 1);
    if (equals(op, "children")) return tree(ctx, path, 0, 0);
    if (equals(op, "remove_tree")) return tree(ctx, path, 1, 1);
    if (equals(op, "remove")) {
        if (!parents(ctx, path, 0)) return 0;
        attributes = GetFileAttributesW(path);
        if (attributes == INVALID_FILE_ATTRIBUTES) {
            value = GetLastError();
            if (value == ERROR_FILE_NOT_FOUND || value == ERROR_PATH_NOT_FOUND) return 1;
            return win_fail(ctx, "inspect removal target");
        }
        if (attributes & FILE_ATTRIBUTE_DIRECTORY) {
            if (!(attributes & FILE_ATTRIBUTE_REPARSE_POINT)) return fail(ctx, "removal target is a directory");
            return RemoveDirectoryW(path) ? 1 : win_fail(ctx, "remove directory link");
        }
        return DeleteFileW(path) ? 1 : win_fail(ctx, "remove file");
    }
    return fail(ctx, "unknown native operation");
}

static int request(lua_State *L)
{
    const char *data;
    size_t size;
    context *ctx;
    char metatable[96];
#if LUAI_HOST_ABI >= 504
    ctx = (context *)api.newuserdata(L, sizeof(*ctx), 0);
#else
    ctx = (context *)api.newuserdata(L, sizeof(*ctx));
#endif
    memset(ctx, 0, sizeof(*ctx)); ctx->ok = 1;
    if (_snprintf(metatable, sizeof(metatable), "luainstaller.windows.context.%p", (void *)own_module) < 0) return 0;
    if (api.newmetatable(L, metatable)) { api.pushcclosure(L, context_gc, 0); api.setfield(L, -2, "__gc"); }
    api.setmetatable(L, -2);
    data = api.tolstring(L, 1, &size);
    if (!data || !parse(ctx, data, size) || !dispatch(ctx)) ctx->ok = 0;
    api.pushboolean(L, ctx->ok);
    if (ctx->error[0]) api.pushlstring(L, ctx->error, strlen(ctx->error));
    else api.pushlstring(L, ctx->result.data ? ctx->result.data : "", ctx->result.size);
    api.pushlstring(L, ctx->extra, strlen(ctx->extra));
    cleanup(ctx);
    return 3;
}

__declspec(dllexport) int luaopen_luainstaller_windows_host(lua_State *L)
{
    if (!find_api()) return 0;
    api.createtable(L, 0, 1);
    api.pushcclosure(L, request, 0);
    api.setfield(L, -2, "request");
    return 1;
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID reserved)
{
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) own_module = instance;
    return TRUE;
}
