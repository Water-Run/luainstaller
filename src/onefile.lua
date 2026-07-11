--[[
Self-extracting onefile bundler for luainstaller.

Author:
    WaterRun
File:
    onefile.lua
Date:
    2026-06-21
Updated:
    2026-07-11
]]

local bundler = require("luainstaller.bundler")
local fs = require("luainstaller.fs")
local hash = require("luainstaller.hash")
local path = require("luainstaller.path")
local platform = require("luainstaller.platform")
local process = require("luainstaller.process")
local result = require("luainstaller.result")

local M = {}

local normalizePath = path.normalize
local absolutePath = path.absolute
local currentDirectory = path.currentDirectory
local dirname = path.dirname
local basename = path.basename
local stem = path.stem
local isSafeRelative = path.isSafeRelative
local validateTargetRelative = path.validateTargetRelative
local commandOutput = process.output
local shellQuote = process.shellQuote
local makeError = result.error

local function ensureDirectory(path)
    local ok, output = commandOutput("mkdir -p " .. shellQuote(path))
    if not ok then
        return makeError("FilesystemError", "Cannot create directory: " .. tostring(path), {
            path = path,
            output = output,
        })
    end
    return nil
end

local function removeTree(path)
    local ok, output = commandOutput("rm -rf " .. shellQuote(path))
    if not ok then
        return makeError("FilesystemError", "Cannot remove path: " .. tostring(path), {
            path = path,
            output = output,
        })
    end
    return nil
end

local function writeFile(path, content)
    local err = ensureDirectory(dirname(path))
    if err then
        return err
    end
    local ok, write_err = fs.writeFile(path, content or "")
    if ok then return nil end
    return makeError("FilesystemError", "Cannot write file: " .. tostring(path), {
        path = path,
        cause = write_err,
    })
end

local function readFile(path)
    local content, read_err = fs.readRegularFile(path)
    if content == nil then
        return nil, makeError("FilesystemError", "Cannot read file: " .. tostring(path), {
            path = path,
            cause = read_err,
        })
    end
    return content
end

local function bytesFromString(content)
    local bytes = {}
    for i = 1, #content do
        bytes[#bytes + 1] = string.format("0x%02X", content:byte(i))
    end
    return bytes
end

local function defaultOut(entry, profile)
    local suffix = profile.executable_suffix or ""
    return normalizePath("build/" .. stem(entry) .. "-onefile" .. suffix)
end

local function outputPath(opts, profile)
    local out = opts.out or defaultOut(opts.entry, profile)
    out = absolutePath(out)
    local suffix = profile.executable_suffix or ""
    if suffix ~= "" and not out:lower():match(suffix:gsub("%.", "%%.") .. "$") then
        out = out .. suffix
    end
    return out
end

local function unsafeOutputError(path)
    return makeError("InvalidOutputError", "Refusing to overwrite unsafe onefile output path: " .. tostring(path), {
        path = path,
    })
end

local function pathExists(path)
    local ok = commandOutput("test -e " .. shellQuote(path))
    return ok == true
end

local function directoryExists(path)
    local ok = commandOutput("test -d " .. shellQuote(path))
    return ok == true
end

local function isSymlink(path)
    local ok = commandOutput("test -L " .. shellQuote(path))
    return ok == true
end

local function validateOutputPath(path)
    local normalized = normalizePath(path)
    if normalized == "/" or normalized == "//" or normalized == "." or normalized == ""
        or normalized:match("^%a:/$") then
        return unsafeOutputError(path)
    end
    if normalized == currentDirectory() then
        return unsafeOutputError(path)
    end
    if isSymlink(normalized) then
        return unsafeOutputError(path)
    end
    if pathExists(normalized) then
        if directoryExists(normalized) then
            return makeError("InvalidOutputError", "Onefile output path is an existing directory: " .. tostring(path), {
                path = path,
            })
        end
        return makeError("InvalidOutputError", "Onefile output path already exists: " .. tostring(path), {
            path = path,
        })
    end
    return nil
end

local function uniqueTempName(name)
    local root = os.getenv("TMPDIR") or "/tmp"
    return normalizePath(root .. "/luainstaller-" .. name .. "-"
        .. tostring(os.time())
        .. tostring(os.clock()):gsub("%.", "")
        .. "-"
        .. tostring(math.random(100000, 999999)))
end

local function createPrivateDirectory(name, parent)
    if parent then
        local parent_err = ensureDirectory(parent)
        if parent_err then
            return nil, parent_err
        end
    end
    for _ = 1, 20 do
        local candidate
        if parent then
            candidate = normalizePath(parent .. "/." .. name .. "-"
                .. tostring(os.time())
                .. tostring(os.clock()):gsub("%.", "")
                .. "-" .. tostring(math.random(100000, 999999)))
        else
            candidate = uniqueTempName(name)
        end
        local ok, output = commandOutput("mkdir -m 700 " .. shellQuote(candidate))
        if ok then
            return candidate
        end
        if not pathExists(candidate) then
            return nil, makeError("FilesystemError", "Cannot create private build directory", {
                path = candidate,
                output = output,
            })
        end
    end
    return nil, makeError("FilesystemError", "Cannot allocate a unique private build directory", {
        path = parent or (os.getenv("TMPDIR") or "/tmp"),
    })
end

local function cleanupDirectory(path_value, failure)
    local cleanup_err = path_value and removeTree(path_value) or nil
    if cleanup_err and failure and failure.error then
        failure.error.cleanup_error = cleanup_err.error and cleanup_err.error.message or tostring(cleanup_err)
        failure.error.cleanup_path = path_value
    end
    return failure or cleanup_err
end

local function collectFiles(root, target_os)
    local ok, output = commandOutput("cd " .. shellQuote(root) .. " && find . -type f -print0")
    if not ok then
        return nil, makeError("FilesystemError", "Cannot list staged files", {
            root = root,
            output = output,
        })
    end
    local relative_paths = {}
    local position = 1
    while position <= #output do
        local terminator = output:find("\0", position, true)
        if not terminator then
            return nil, makeError("FilesystemError", "Staged file listing is incomplete", {
                root = root,
            })
        end
        local rel = output:sub(position, terminator - 1):gsub("^%./", "")
        position = terminator + 1
        if not isSafeRelative(rel) then
            return nil, makeError("FilesystemError", "Staged file path is not a safe relative path", {
                path = rel,
                root = root,
            })
        end
        local target_ok, target_reason = validateTargetRelative(rel, target_os)
        if not target_ok then
            return nil, makeError("InvalidOptionsError", "Staged target path is not portable: " .. rel, {
                path = rel,
                target_os = target_os,
                reason = target_reason,
            })
        end
        if rel ~= ".luai/generated-output.txt"
            and rel ~= ".luai/build"
            and rel:sub(1, #".luai/build/") ~= ".luai/build/" then
            relative_paths[#relative_paths + 1] = rel
        end
    end
    table.sort(relative_paths)

    local files = {}
    local payload_hash_parts = {}
    for _, rel in ipairs(relative_paths) do
        local abs = normalizePath(root .. "/" .. rel)
        if not path.isWithin(abs, root) then
            return nil, makeError("FilesystemError", "Staged file escapes staging directory", {
                path = rel,
                root = root,
            })
        end
        local content, err = readFile(abs)
        if not content then
            return nil, err
        end
        local mode_ok = os.execute("test -x " .. shellQuote(abs) .. " >/dev/null 2>&1")
        local executable = mode_ok == true or mode_ok == 0
        files[#files + 1] = {
            path = rel,
            content = content,
            size = #content,
            executable = executable,
        }
        payload_hash_parts[#payload_hash_parts + 1] = string.pack(">I4", #rel)
        payload_hash_parts[#payload_hash_parts + 1] = rel
        payload_hash_parts[#payload_hash_parts + 1] = executable and "\1" or "\0"
        payload_hash_parts[#payload_hash_parts + 1] = string.pack(">I8", #content)
        payload_hash_parts[#payload_hash_parts + 1] = content
    end
    return files, hash.sha256(table.concat(payload_hash_parts))
end

local function cString(value)
    local escaped = {}
    value = tostring(value or "")
    for index = 1, #value do
        escaped[#escaped + 1] = string.format("\\%03o", value:byte(index))
    end
    return '"' .. table.concat(escaped) .. '"'
end

local function emitFileArrays(files)
    local lines = {}
    for i, file in ipairs(files) do
        local bytes = bytesFromString(file.content)
        lines[#lines + 1] = string.format("static const unsigned char luai_file_%d[] = {", i)
        if #bytes == 0 then
            lines[#lines + 1] = "    0x00,"
        else
            for j = 1, #bytes, 12 do
                local chunk = {}
                for k = j, math.min(j + 11, #bytes) do
                    chunk[#chunk + 1] = bytes[k]
                end
                lines[#lines + 1] = "    " .. table.concat(chunk, ", ") .. ","
            end
        end
        lines[#lines + 1] = "};"
    end
    return table.concat(lines, "\n")
end

local EXTRACTOR_TEMPLATE = [=[
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <direct.h>
#include <fcntl.h>
#include <io.h>
#include <process.h>
#include <sys/stat.h>
#include <windows.h>
#include <aclapi.h>
#include <sddl.h>
#define L_SEP "\\"
#else
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#define L_SEP "/"
#endif

static int luai_mkdir_one(const char *path) {
#ifdef _WIN32
    if (_mkdir(path) == 0) return 0;
    if (errno == EEXIST) {
        DWORD attrs = GetFileAttributesA(path);
        if (attrs != INVALID_FILE_ATTRIBUTES &&
            (attrs & FILE_ATTRIBUTE_DIRECTORY) &&
            !(attrs & FILE_ATTRIBUTE_REPARSE_POINT)) return 0;
    }
#else
    if (mkdir(path, 0700) == 0) return 0;
    if (errno == EEXIST) {
        struct stat st;
        if (lstat(path, &st) == 0 && S_ISDIR(st.st_mode) && !S_ISLNK(st.st_mode)) return 0;
    }
#endif
    return -1;
}

static int luai_mkdir_p(const char *path) {
    char tmp[4096];
    size_t len = strlen(path);
    size_t i;
    if (len >= sizeof(tmp)) return -1;
    strcpy(tmp, path);
    for (i = 1; i < len; ++i) {
        if (tmp[i] == '/' || tmp[i] == '\\') {
            char saved = tmp[i];
            tmp[i] = '\0';
            if (strlen(tmp) > 0 && luai_mkdir_one(tmp) != 0) return -1;
            tmp[i] = saved;
        }
    }
    return luai_mkdir_one(tmp);
}

#ifdef _WIN32
static int luai_harden_private_path(const char *path) {
    HANDLE token = NULL;
    TOKEN_USER *token_user = NULL;
    DWORD token_size = 0;
    PSID owner = NULL;
    PSECURITY_DESCRIPTOR current_sd = NULL;
    PSECURITY_DESCRIPTOR private_sd = NULL;
    PACL private_dacl = NULL;
    BOOL dacl_present = FALSE;
    BOOL dacl_defaulted = FALSE;
    LPSTR sid_text = NULL;
    BYTE administrators_sid[SECURITY_MAX_SID_SIZE];
    DWORD administrators_sid_size = sizeof(administrators_sid);
    BOOL is_administrator = FALSE;
    char sddl[1024];
    DWORD status;
    int result = -1;

    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) goto cleanup;
    GetTokenInformation(token, TokenUser, NULL, 0, &token_size);
    if (GetLastError() != ERROR_INSUFFICIENT_BUFFER) goto cleanup;
    token_user = (TOKEN_USER *)LocalAlloc(LPTR, token_size);
    if (!token_user) goto cleanup;
    if (!GetTokenInformation(token, TokenUser, token_user, token_size, &token_size)) goto cleanup;
    status = GetNamedSecurityInfoA((LPSTR)path, SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION,
                                   &owner, NULL, NULL, NULL, &current_sd);
    if (status != ERROR_SUCCESS || !owner) goto cleanup;
    if (!EqualSid(owner, token_user->User.Sid)) {
        if (!CreateWellKnownSid(WinBuiltinAdministratorsSid, NULL,
                                administrators_sid, &administrators_sid_size)) goto cleanup;
        if (!CheckTokenMembership(NULL, administrators_sid, &is_administrator)
            || !is_administrator || !EqualSid(owner, administrators_sid)) goto cleanup;
    }
    if (!ConvertSidToStringSidA(token_user->User.Sid, &sid_text)) goto cleanup;
    if (snprintf(sddl, sizeof(sddl), "O:%sD:P(A;OICI;FA;;;%s)(A;OICI;FA;;;SY)",
                 sid_text, sid_text) < 0) goto cleanup;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorA(
            sddl, SDDL_REVISION_1, &private_sd, NULL)) goto cleanup;
    if (!GetSecurityDescriptorDacl(private_sd, &dacl_present, &private_dacl, &dacl_defaulted)
        || !dacl_present || !private_dacl) goto cleanup;
    status = SetNamedSecurityInfoA((LPSTR)path, SE_FILE_OBJECT,
                                   OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION
                                       | PROTECTED_DACL_SECURITY_INFORMATION,
                                   token_user->User.Sid, NULL, private_dacl, NULL);
    if (status != ERROR_SUCCESS) goto cleanup;
    result = 0;

cleanup:
    if (sid_text) LocalFree(sid_text);
    if (private_sd) LocalFree(private_sd);
    if (current_sd) LocalFree(current_sd);
    if (token_user) LocalFree(token_user);
    if (token) CloseHandle(token);
    return result;
}
#endif

static int luai_ensure_private_dir(const char *path) {
    if (luai_mkdir_p(path) != 0) return -1;
#ifdef _WIN32
    {
        DWORD attrs = GetFileAttributesA(path);
        if (attrs == INVALID_FILE_ATTRIBUTES ||
            !(attrs & FILE_ATTRIBUTE_DIRECTORY) ||
            (attrs & FILE_ATTRIBUTE_REPARSE_POINT)) return -1;
        if (luai_harden_private_path(path) != 0) return -1;
    }
#else
    {
        struct stat st;
        if (lstat(path, &st) != 0 || !S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode)) return -1;
        if (st.st_uid != geteuid()) return -1;
        if ((st.st_mode & 0777) != 0700) return -1;
    }
#endif
    return 0;
}

static int luai_parent_dir(char *out, size_t out_size, const char *path) {
    const char *slash = strrchr(path, '/');
    const char *backslash = strrchr(path, '\\');
    const char *pos;
    size_t len;
    if (!slash) pos = backslash;
    else if (!backslash) pos = slash;
    else pos = slash > backslash ? slash : backslash;
    if (!pos) {
        if (out_size < 2) return -1;
        strcpy(out, ".");
        return 0;
    }
    len = (size_t)(pos - path);
    if (len + 1 > out_size) return -1;
    memcpy(out, path, len);
    out[len] = '\0';
    return 0;
}

#ifdef _WIN32
static int luai_file_matches(const char *path, const unsigned char *expected, size_t expected_size) {
    FILE *file = fopen(path, "rb");
    unsigned char buffer[8192];
    size_t offset = 0;
    if (!file) return 0;
    while (offset < expected_size) {
        size_t remaining = expected_size - offset;
        size_t wanted = remaining < sizeof(buffer) ? remaining : sizeof(buffer);
        size_t got = fread(buffer, 1, wanted, file);
        if (got != wanted || memcmp(buffer, expected + offset, got) != 0) {
            fclose(file);
            return 0;
        }
        offset += got;
    }
    if (fgetc(file) != EOF || ferror(file)) {
        fclose(file);
        return 0;
    }
    return fclose(file) == 0;
}

static int luai_remove_unsafe_existing(const char *path) {
#ifdef _WIN32
    DWORD attrs = GetFileAttributesA(path);
    if (attrs == INVALID_FILE_ATTRIBUTES) {
        DWORD status = GetLastError();
        return status == ERROR_FILE_NOT_FOUND || status == ERROR_PATH_NOT_FOUND ? 0 : -1;
    }
    if (attrs & FILE_ATTRIBUTE_REPARSE_POINT) {
        if (attrs & FILE_ATTRIBUTE_DIRECTORY) {
            return RemoveDirectoryA(path) ? 0 : -1;
        }
        return DeleteFileA(path) ? 0 : -1;
    }
    if ((attrs & FILE_ATTRIBUTE_DIRECTORY) || (attrs & FILE_ATTRIBUTE_DEVICE)) return -1;
#else
    struct stat st;
    if (lstat(path, &st) != 0) return errno == ENOENT ? 0 : -1;
    if (S_ISLNK(st.st_mode)) {
        return unlink(path);
    }
    if (!S_ISREG(st.st_mode)) return -1;
#endif
    return 0;
}

static int luai_apply_mode(const char *path, int executable) {
#ifndef _WIN32
    if (chmod(path, executable ? 0700 : 0600) != 0) return -1;
#else
    (void)path;
    (void)executable;
#endif
    return 0;
}
#endif

static int luai_join(char *out, size_t out_size, const char *left, const char *right) {
    int n = snprintf(out, out_size, "%s%s%s", left, L_SEP, right);
    return n >= 0 && (size_t)n < out_size ? 0 : -1;
}

/* Reject absolute paths and any empty/./.. segment (zip-slip prevention). */
static int luai_path_is_safe_relative(const char *path) {
    const char *p;
    if (!path || !*path) return 0;
    if (path[0] == '/' || path[0] == '\\') return 0;
    if (((path[0] >= 'A' && path[0] <= 'Z') || (path[0] >= 'a' && path[0] <= 'z')) && path[1] == ':') return 0;
    p = path;
    while (*p) {
        const char *start = p;
        size_t len;
        while (*p && *p != '/' && *p != '\\') {
            unsigned char byte = (unsigned char)*p;
            if (byte < 32 || byte == 127) return 0;
            p++;
        }
        len = (size_t)(p - start);
        if (len == 0) return 0;
        if (len == 1 && start[0] == '.') return 0;
        if (len == 2 && start[0] == '.' && start[1] == '.') return 0;
        if (*p) p++;
    }
    return 1;
}

#ifndef _WIN32
static int luai_remove_unsafe_existing_at(int parent_fd, const char *name) {
    struct stat st;
    if (fstatat(parent_fd, name, &st, AT_SYMLINK_NOFOLLOW) != 0) {
        return errno == ENOENT ? 0 : -1;
    }
    if (S_ISLNK(st.st_mode)) return unlinkat(parent_fd, name, 0);
    if (!S_ISREG(st.st_mode) || st.st_uid != geteuid()) return -1;
    return 0;
}

/* Return 1 with an open matching fd, 0 for different/missing, -1 for unsafe. */
static int luai_file_matches_at(int parent_fd, const char *name,
                                const unsigned char *expected, size_t expected_size,
                                int *matching_fd) {
    struct stat st;
    unsigned char buffer[8192];
    size_t offset = 0;
    int fd = openat(parent_fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    *matching_fd = -1;
    if (fd < 0) return errno == ENOENT ? 0 : -1;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_uid != geteuid()) {
        close(fd);
        return -1;
    }
    while (offset < expected_size) {
        size_t remaining = expected_size - offset;
        size_t wanted = remaining < sizeof(buffer) ? remaining : sizeof(buffer);
        ssize_t got;
        do {
            got = read(fd, buffer, wanted);
        } while (got < 0 && errno == EINTR);
        if (got < 0 || (size_t)got != wanted
            || memcmp(buffer, expected + offset, wanted) != 0) {
            close(fd);
            return 0;
        }
        offset += wanted;
    }
    for (;;) {
        ssize_t got = read(fd, buffer, 1);
        if (got < 0 && errno == EINTR) continue;
        if (got != 0) {
            close(fd);
            return got < 0 ? -1 : 0;
        }
        break;
    }
    *matching_fd = fd;
    return 1;
}

static int luai_write_file_at(int parent_fd, const char *name,
                              const unsigned char *data, size_t size,
                              int executable) {
    char temporary[4096];
    unsigned int attempt;
    int fd = -1;
    int matching_fd = -1;
    int matches;
    size_t offset = 0;
    if (!name || !*name || strchr(name, '/') || strchr(name, '\\')) return -1;
    if (luai_remove_unsafe_existing_at(parent_fd, name) != 0) return -1;
    matches = luai_file_matches_at(parent_fd, name, data, size, &matching_fd);
    if (matches < 0) return -1;
    if (matches == 1) {
        int mode_ok = fchmod(matching_fd, executable ? 0700 : 0600);
        int close_ok = close(matching_fd);
        return mode_ok == 0 && close_ok == 0 ? 0 : -1;
    }
    for (attempt = 0; attempt < 100; ++attempt) {
        int name_length = snprintf(temporary, sizeof(temporary),
                                   "%s.luai-%lu-%u.tmp", name,
                                   (unsigned long)getpid(), attempt);
        if (name_length < 0 || (size_t)name_length >= sizeof(temporary)) return -1;
        fd = openat(parent_fd, temporary,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (fd >= 0) break;
        if (errno != EEXIST) return -1;
    }
    if (fd < 0) return -1;
    while (offset < size) {
        ssize_t wrote = write(fd, data + offset, size - offset);
        if (wrote < 0 && errno == EINTR) continue;
        if (wrote <= 0) {
            close(fd);
            unlinkat(parent_fd, temporary, 0);
            return -1;
        }
        offset += (size_t)wrote;
    }
    {
        int persist_failed = 0;
        if (fchmod(fd, executable ? 0700 : 0600) != 0) persist_failed = 1;
        if (fsync(fd) != 0) persist_failed = 1;
        if (close(fd) != 0) persist_failed = 1;
        if (persist_failed) {
            unlinkat(parent_fd, temporary, 0);
            return -1;
        }
    }
    if (renameat(parent_fd, temporary, parent_fd, name) == 0) return 0;

    matches = luai_file_matches_at(parent_fd, name, data, size, &matching_fd);
    unlinkat(parent_fd, temporary, 0);
    if (matches == 1) {
        int mode_ok = fchmod(matching_fd, executable ? 0700 : 0600);
        int close_ok = close(matching_fd);
        return mode_ok == 0 && close_ok == 0 ? 0 : -1;
    }
    if (matching_fd >= 0) close(matching_fd);
    return -1;
}
#endif

static int luai_write_file(const char *path, const unsigned char *data, size_t size, int executable) {
    char parent[4096];
#ifdef _WIN32
    char temporary[4096];
    FILE *file;
    int fd = -1;
    unsigned int attempt;
    int name_length;
#endif
    if (luai_parent_dir(parent, sizeof(parent), path) != 0) return -1;
    if (luai_ensure_private_dir(parent) != 0) return -1;
#ifdef _WIN32
    if (luai_remove_unsafe_existing(path) != 0) return -1;
    if (luai_file_matches(path, data, size)) {
        if (luai_harden_private_path(path) != 0) return -1;
        return luai_apply_mode(path, executable);
    }
    for (attempt = 0; attempt < 100; ++attempt) {
        name_length = snprintf(temporary, sizeof(temporary), "%s.luai-%lu-%u.tmp", path,
                               (unsigned long)_getpid(), attempt);
        if (name_length < 0 || (size_t)name_length >= sizeof(temporary)) return -1;
        fd = _open(temporary, _O_WRONLY | _O_CREAT | _O_EXCL | _O_BINARY,
                   _S_IREAD | _S_IWRITE);
        if (fd >= 0) break;
        if (errno != EEXIST) return -1;
    }
    if (fd < 0) return -1;
    file = _fdopen(fd, "wb");
    if (!file) {
        _close(fd);
        remove(temporary);
        return -1;
    }
    if (size > 0 && fwrite(data, 1, size, file) != size) {
        fclose(file);
        remove(temporary);
        return -1;
    }
    if (fclose(file) != 0) {
        remove(temporary);
        return -1;
    }
    if (luai_apply_mode(temporary, executable) != 0) {
        remove(temporary);
        return -1;
    }
    if (luai_harden_private_path(temporary) != 0) {
        remove(temporary);
        return -1;
    }
    if (!MoveFileExA(temporary, path, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        if (luai_file_matches(path, data, size)) {
            remove(temporary);
            if (luai_harden_private_path(path) != 0) return -1;
            return luai_apply_mode(path, executable);
        }
        remove(temporary);
        return -1;
    }
    return 0;
#else
    {
        const char *name = strrchr(path, '/');
        int parent_fd;
        int write_result;
        name = name ? name + 1 : path;
        parent_fd = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (parent_fd < 0) return -1;
        write_result = luai_write_file_at(parent_fd, name, data, size, executable);
        if (close(parent_fd) != 0) return -1;
        return write_result;
    }
#endif
}

static int luai_temp_root(char *out, size_t out_size) {
#ifdef _WIN32
    const char *value = getenv("TEMP");
    int length;
    if (!value || !*value) value = getenv("TMP");
    if (!value || !*value) value = ".";
    length = snprintf(out, out_size, "%s", value);
    return length >= 0 && (size_t)length < out_size ? 0 : -1;
#else
    const char *value = getenv("TMPDIR");
    char *resolved;
    size_t length;
    if (!value || !*value) value = "/tmp";
    resolved = realpath(value, NULL);
    if (!resolved) return -1;
    length = strlen(resolved);
    if (length >= out_size) {
        free(resolved);
        return -1;
    }
    memcpy(out, resolved, length + 1);
    free(resolved);
    return 0;
#endif
}

static int luai_extract_all(char *bundle_dir, size_t bundle_dir_size) {
    char base[4096];
    char cache_name[128];
    char temp_root[4096];
    size_t i;
    size_t bundle_len;
#ifdef _WIN32
    if (snprintf(cache_name, sizeof(cache_name), "luainstaller-onefile") < 0) return -1;
#else
    if (snprintf(cache_name, sizeof(cache_name), "luainstaller-onefile-%lu",
                 (unsigned long)geteuid()) < 0) return -1;
#endif
    if (luai_temp_root(temp_root, sizeof(temp_root)) != 0) return -1;
    if (luai_join(base, sizeof(base), temp_root, cache_name) != 0) return -1;
    if (luai_ensure_private_dir(base) != 0) return -1;
    if (luai_join(bundle_dir, bundle_dir_size, base, LUAI_PAYLOAD_ID) != 0) return -1;
    if (luai_ensure_private_dir(bundle_dir) != 0) return -1;
    bundle_len = strlen(bundle_dir);
    for (i = 0; i < LUAI_FILE_COUNT; ++i) {
        char target[4096];
        if (!luai_path_is_safe_relative(luai_files[i].path)) {
            fprintf(stderr, "luainstaller-onefile: unsafe path %s\n", luai_files[i].path);
            return -1;
        }
        if (luai_join(target, sizeof(target), bundle_dir, luai_files[i].path) != 0) return -1;
        if (strncmp(target, bundle_dir, bundle_len) != 0 ||
            (target[bundle_len] != '\0' && target[bundle_len] != '/' && target[bundle_len] != '\\')) {
            fprintf(stderr, "luainstaller-onefile: path escapes extract root: %s\n", luai_files[i].path);
            return -1;
        }
        if (luai_write_file(target, luai_files[i].data, luai_files[i].size, luai_files[i].executable) != 0) {
            fprintf(stderr, "luainstaller-onefile: cannot extract %s\n", luai_files[i].path);
            return -1;
        }
    }
    return 0;
}

#ifdef _WIN32
static int luai_append_quoted(char *cmd, size_t cmd_size, const char *value) {
    size_t len = strlen(cmd);
    size_t i;
    if (len + 3 >= cmd_size) return -1;
    cmd[len++] = '"';
    i = 0;
    for (;;) {
        size_t backslashes = 0;
        size_t count;
        while (value[i] == '\\') {
            backslashes++;
            i++;
        }
        if (value[i] == '"') {
            count = backslashes * 2 + 1;
            if (len + count + 2 >= cmd_size) return -1;
            while (count-- > 0) cmd[len++] = '\\';
            cmd[len++] = '"';
            i++;
        } else if (value[i] == '\0') {
            count = backslashes * 2;
            if (len + count + 2 >= cmd_size) return -1;
            while (count-- > 0) cmd[len++] = '\\';
            break;
        } else {
            count = backslashes;
            if (len + count + 2 >= cmd_size) return -1;
            while (count-- > 0) cmd[len++] = '\\';
            cmd[len++] = value[i++];
        }
    }
    cmd[len++] = '"';
    cmd[len] = '\0';
    return 0;
}

static int luai_run_inner(const char *exe_path, int argc, char **argv) {
    char cmd[32768] = "";
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    DWORD exit_code = 1;
    int i;
    if (luai_append_quoted(cmd, sizeof(cmd), exe_path) != 0) {
        fprintf(stderr, "luainstaller-onefile: command line too long\n");
        return 1;
    }
    for (i = 1; i < argc; ++i) {
        size_t len = strlen(cmd);
        if (len + 2 >= sizeof(cmd)) {
            fprintf(stderr, "luainstaller-onefile: command line too long\n");
            return 1;
        }
        cmd[len] = ' ';
        cmd[len + 1] = '\0';
        if (luai_append_quoted(cmd, sizeof(cmd), argv[i]) != 0) {
            fprintf(stderr, "luainstaller-onefile: command line too long\n");
            return 1;
        }
    }
    ZeroMemory(&si, sizeof(si));
    ZeroMemory(&pi, sizeof(pi));
    si.cb = sizeof(si);
    if (!CreateProcessA(NULL, cmd, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi)) {
        fprintf(stderr, "luainstaller-onefile: cannot start inner launcher\n");
        return 1;
    }
    WaitForSingleObject(pi.hProcess, INFINITE);
    GetExitCodeProcess(pi.hProcess, &exit_code);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return (int)exit_code;
}
#else
static int luai_run_inner(const char *exe_path, int argc, char **argv) {
    pid_t pid;
    int status = 0;
    char **child_argv = (char **)calloc((size_t)argc + 1, sizeof(char *));
    int i;
    if (!child_argv) return 1;
    child_argv[0] = (char *)exe_path;
    for (i = 1; i < argc; ++i) child_argv[i] = argv[i];
    child_argv[argc] = NULL;
    pid = fork();
    if (pid == 0) {
        execv(exe_path, child_argv);
        perror("luainstaller-onefile: execv");
        _exit(127);
    }
    free(child_argv);
    if (pid < 0) return 1;
    if (waitpid(pid, &status, 0) < 0) return 1;
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 1;
}
#endif

int main(int argc, char **argv) {
    char bundle_dir[4096];
    char exe_path[4096];
    if (luai_extract_all(bundle_dir, sizeof(bundle_dir)) != 0) {
        fputs("luainstaller-onefile: extraction failed\n", stderr);
        return 1;
    }
    if (luai_join(exe_path, sizeof(exe_path), bundle_dir, LUAI_INNER_EXE) != 0) {
        fputs("luainstaller-onefile: inner path is too long\n", stderr);
        return 1;
    }
    return luai_run_inner(exe_path, argc, argv);
}
]=]

local function generateExtractor(files, payload_id, inner_exe)
    local lines = {}
    lines[#lines + 1] = "/* Generated by luainstaller. */"
    lines[#lines + 1] = "#ifndef _WIN32"
    lines[#lines + 1] = "#if defined(__APPLE__) && defined(__MACH__)"
    lines[#lines + 1] = "#define _DARWIN_C_SOURCE 1"
    lines[#lines + 1] = "#endif"
    lines[#lines + 1] = "#define _POSIX_C_SOURCE 200809L"
    lines[#lines + 1] = "#define _XOPEN_SOURCE 700"
    lines[#lines + 1] = "#endif"
    lines[#lines + 1] = "#include <stddef.h>"
    lines[#lines + 1] = "struct luai_embedded_file {"
    lines[#lines + 1] = "    const char *path;"
    lines[#lines + 1] = "    const unsigned char *data;"
    lines[#lines + 1] = "    size_t size;"
    lines[#lines + 1] = "    int executable;"
    lines[#lines + 1] = "};"
    lines[#lines + 1] = emitFileArrays(files)
    lines[#lines + 1] = "#define LUAI_PAYLOAD_ID " .. cString(payload_id)
    lines[#lines + 1] = "#define LUAI_INNER_EXE " .. cString(inner_exe)
    lines[#lines + 1] = "#define LUAI_FILE_COUNT " .. tostring(#files)
    lines[#lines + 1] = "static const struct luai_embedded_file luai_files[] = {"
    for i, file in ipairs(files) do
        lines[#lines + 1] = string.format(
            "    { %s, luai_file_%d, %d, %d },",
            cString(file.path),
            i,
            file.size,
            file.executable and 1 or 0
        )
    end
    lines[#lines + 1] = "};"
    lines[#lines + 1] = EXTRACTOR_TEMPLATE
    return table.concat(lines, "\n\n")
end

local function windowsCompiler()
    return os.getenv("LUAI_WINDOWS_CC") or "x86_64-w64-mingw32-gcc"
end

local function compileExtractor(c_path, exe_path, profile)
    local command
    if profile.target_os == "windows" then
        command = table.concat({
            shellQuote(windowsCompiler()),
            "-std=c11",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-pedantic",
            shellQuote(c_path),
            "-o",
            shellQuote(exe_path),
            "-static-libgcc",
            "-Wl,--no-insert-timestamp",
            "-ladvapi32",
        }, " ")
    else
        local parts = {
            "cc",
            "-std=c11",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-pedantic",
            shellQuote(c_path),
            "-o",
            shellQuote(exe_path),
        }
        command = table.concat(parts, " ")
    end
    local ok, output = commandOutput(command)
    if not ok then
        return makeError("CompilationFailedError", "Onefile extractor compilation failed", {
            command = command,
            output = output,
        })
    end
    if profile.target_os ~= "windows" then
        local chmod_ok, chmod_output = commandOutput("chmod +x " .. shellQuote(exe_path))
        if not chmod_ok then
            return makeError("FilesystemError", "Cannot mark onefile output executable", {
                path = exe_path,
                output = chmod_output,
            })
        end
    end
    return nil
end

function M.bundleOnefile(opts)
    opts = opts or {}
    local profile = platform.profile({
        target_os = opts.target_os,
        lua_prefix = opts.lua_prefix,
    })
    local out_path = outputPath(opts, profile)
    local output_err = validateOutputPath(out_path)
    if output_err then
        return output_err
    end
    local target_ok, target_reason = validateTargetRelative(basename(out_path), profile.target_os)
    if not target_ok then
        return makeError("InvalidOptionsError", "Onefile output name is not portable for the target", {
            path = out_path,
            target_path = basename(out_path),
            target_os = profile.target_os,
            reason = target_reason,
        })
    end
    local work_dir, work_err = createPrivateDirectory("onefile-work")
    if not work_dir then
        return work_err
    end
    local stage_dir = normalizePath(work_dir .. "/inner")
    local build_dir = normalizePath(work_dir .. "/build")
    local c_path = normalizePath(build_dir .. "/extractor.c")
    local err = ensureDirectory(build_dir)
    if err then
        return cleanupDirectory(work_dir, err)
    end

    local staged = bundler.bundleOnedir({
        entry = opts.entry,
        out = stage_dir,
        target_os = opts.target_os,
        lua_prefix = opts.lua_prefix,
        dependencies = opts.dependencies,
        trace = opts.trace,
        manifest = opts.manifest,
    })
    if not staged.ok then
        return cleanupDirectory(work_dir, staged)
    end

    local files, payload_id = collectFiles(stage_dir, profile.target_os)
    if not files then
        return cleanupDirectory(work_dir, payload_id)
    end

    local inner_exe = normalizePath(staged.executable):sub(#normalizePath(stage_dir) + 2)
    local c_source = generateExtractor(files, payload_id, inner_exe)
    err = writeFile(c_path, c_source)
    if err then
        return cleanupDirectory(work_dir, err)
    end

    local output_parent = dirname(out_path)
    err = ensureDirectory(output_parent)
    local output_stage
    if not err then
        output_stage, err = createPrivateDirectory(basename(out_path) .. ".luai-output", output_parent)
    end
    local staged_exe = output_stage and normalizePath(output_stage .. "/artifact" .. (profile.executable_suffix or "")) or nil
    if not err then
        err = compileExtractor(c_path, staged_exe, profile)
    end
    local published = false
    if not err then
        local linked, link_output = commandOutput("ln " .. shellQuote(staged_exe) .. " " .. shellQuote(out_path))
        if not linked then
            if pathExists(out_path) or isSymlink(out_path) then
                err = makeError("InvalidOutputError", "Onefile output appeared while the bundle was being built", {
                    path = out_path,
                    output = link_output,
                })
            else
                err = makeError("FilesystemError", "Cannot publish onefile output atomically; the output filesystem may not support hard links", {
                    path = out_path,
                    staging_path = staged_exe,
                    output = link_output,
                })
            end
        else
            published = true
        end
    end
    if output_stage then
        err = cleanupDirectory(output_stage, err)
    end
    err = cleanupDirectory(work_dir, err)
    if err then
        if published and err.error then
            err.error.cleanup_path = err.error.cleanup_path or err.error.path
            err.error.committed = true
            err.error.output_path = out_path
            err.error.path = out_path
        end
        return err
    end

    return {
        ok = true,
        action = "bundle",
        mode = "onefile",
        entry = opts.entry,
        out = out_path,
        executable = out_path,
        manifest = opts.manifest,
    }
end

return M
