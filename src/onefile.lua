--[[
Self-extracting onefile bundler for luainstaller.

Author:
    WaterRun
File:
    onefile.lua
Date:
    2026-06-21
Updated:
    2026-06-21
]]

local bundler = require("luainstaller.bundler")
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

local function removeFile(path)
    os.remove(path)
    return nil
end

local function writeFile(path, content)
    local err = ensureDirectory(dirname(path))
    if err then
        return err
    end
    local file = io.open(path, "wb")
    if not file then
        return makeError("FilesystemError", "Cannot write file: " .. tostring(path), {
            path = path,
        })
    end
    file:write(content or "")
    file:close()
    return nil
end

local function readFile(path)
    local file = io.open(path, "rb")
    if not file then
        return nil, makeError("FilesystemError", "Cannot read file: " .. tostring(path), {
            path = path,
        })
    end
    local content = file:read("*a") or ""
    file:close()
    return content
end

local function fnv1a32(content)
    local hash = 2166136261
    for i = 1, #content do
        hash = hash ~ content:byte(i)
        hash = (hash * 16777619) % 4294967296
    end
    return string.format("%08x", hash)
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
    if normalized == "/" or normalized == "." or normalized == "" then
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

local function tempPath(name)
    local root = os.getenv("TMPDIR") or "/tmp"
    return normalizePath(root .. "/luainstaller-" .. name .. "-" .. tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999)))
end

local function collectFiles(root)
    local ok, output = commandOutput("cd " .. shellQuote(root) .. " && find . -type f | sort")
    if not ok then
        return nil, makeError("FilesystemError", "Cannot list staged files", {
            root = root,
            output = output,
        })
    end
    local files = {}
    local payload_hash_parts = {}
    for line in output:gmatch("[^\n]+") do
        local rel = line:gsub("^%./", "")
        local abs = normalizePath(root .. "/" .. rel)
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
            hash = fnv1a32(content),
            executable = executable,
        }
        payload_hash_parts[#payload_hash_parts + 1] = rel .. "\0" .. fnv1a32(content)
    end
    return files, fnv1a32(table.concat(payload_hash_parts, "\0"))
end

local function cString(value)
    return string.format("%q", tostring(value or ""))
end

local function emitFileArrays(files)
    local lines = {}
    for i, file in ipairs(files) do
        local bytes = bytesFromString(file.content)
        lines[#lines + 1] = string.format("static const unsigned char luai_file_%d[] = {", i)
        for j = 1, #bytes, 12 do
            local chunk = {}
            for k = j, math.min(j + 11, #bytes) do
                chunk[#chunk + 1] = bytes[k]
            end
            lines[#lines + 1] = "    " .. table.concat(chunk, ", ") .. ","
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
#include <process.h>
#include <windows.h>
#define L_SEP "\\"
#else
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#define L_SEP "/"
#endif

static int luai_mkdir_one(const char *path) {
#ifdef _WIN32
    if (_mkdir(path) == 0 || errno == EEXIST) return 0;
#else
    if (mkdir(path, 0700) == 0 || errno == EEXIST) return 0;
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

static int luai_parent_dir(char *out, size_t out_size, const char *path) {
    const char *slash = strrchr(path, '/');
    const char *backslash = strrchr(path, '\\');
    const char *pos = slash > backslash ? slash : backslash;
    size_t len;
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

static int luai_file_matches_hash(const char *path, size_t expected_size, const char *expected_hash) {
    FILE *file = fopen(path, "rb");
    unsigned int hash = 2166136261u;
    size_t total = 0;
    int ch;
    char actual[9];
    if (!file) return 0;
    while ((ch = fgetc(file)) != EOF) {
        hash ^= (unsigned char)ch;
        hash *= 16777619u;
        total++;
    }
    if (ferror(file)) {
        fclose(file);
        return 0;
    }
    fclose(file);
    if (total != expected_size) return 0;
    snprintf(actual, sizeof(actual), "%08x", hash);
    return strcmp(actual, expected_hash) == 0;
}

static int luai_remove_unsafe_existing(const char *path) {
#ifdef _WIN32
    DWORD attrs = GetFileAttributesA(path);
    if (attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_REPARSE_POINT)) {
        if (attrs & FILE_ATTRIBUTE_DIRECTORY) {
            return RemoveDirectoryA(path) ? 0 : -1;
        }
        return DeleteFileA(path) ? 0 : -1;
    }
#else
    struct stat st;
    if (lstat(path, &st) == 0 && S_ISLNK(st.st_mode)) {
        return unlink(path);
    }
#endif
    return 0;
}

static int luai_apply_mode(const char *path, int executable) {
#ifndef _WIN32
    if (executable && chmod(path, 0700) != 0) return -1;
#else
    (void)path;
    (void)executable;
#endif
    return 0;
}

static int luai_join(char *out, size_t out_size, const char *left, const char *right) {
    int n = snprintf(out, out_size, "%s%s%s", left, L_SEP, right);
    return n >= 0 && (size_t)n < out_size ? 0 : -1;
}

static int luai_write_file(const char *path, const unsigned char *data, size_t size, int executable, const char *hash) {
    char parent[4096];
    FILE *file;
    if (luai_remove_unsafe_existing(path) != 0) return -1;
    if (luai_file_matches_hash(path, size, hash)) return luai_apply_mode(path, executable);
    if (luai_parent_dir(parent, sizeof(parent), path) != 0) return -1;
    if (luai_mkdir_p(parent) != 0) return -1;
    file = fopen(path, "wb");
    if (!file) return -1;
    if (size > 0 && fwrite(data, 1, size, file) != size) {
        fclose(file);
        return -1;
    }
    if (fclose(file) != 0) return -1;
    return luai_apply_mode(path, executable);
}

static const char *luai_temp_root(void) {
#ifdef _WIN32
    const char *value = getenv("TEMP");
    if (!value || !*value) value = getenv("TMP");
    return value && *value ? value : ".";
#else
    const char *value = getenv("TMPDIR");
    return value && *value ? value : "/tmp";
#endif
}

static int luai_extract_all(char *bundle_dir, size_t bundle_dir_size) {
    char base[4096];
    size_t i;
    if (luai_join(base, sizeof(base), luai_temp_root(), "luainstaller-onefile") != 0) return -1;
    if (luai_mkdir_p(base) != 0) return -1;
    if (luai_join(bundle_dir, bundle_dir_size, base, LUAI_PAYLOAD_ID) != 0) return -1;
    if (luai_mkdir_p(bundle_dir) != 0) return -1;
    for (i = 0; i < LUAI_FILE_COUNT; ++i) {
        char target[4096];
        if (luai_join(target, sizeof(target), bundle_dir, luai_files[i].path) != 0) return -1;
        if (luai_write_file(target, luai_files[i].data, luai_files[i].size, luai_files[i].executable, luai_files[i].hash) != 0) {
            fprintf(stderr, "luainstaller-onefile: cannot extract %s\n", luai_files[i].path);
            return -1;
        }
    }
    return 0;
}

#ifdef _WIN32
static void luai_append_quoted(char *cmd, size_t cmd_size, const char *value) {
    size_t len = strlen(cmd);
    size_t i;
    if (len + 3 >= cmd_size) return;
    cmd[len++] = '"';
    for (i = 0; value[i] && len + 3 < cmd_size; ++i) {
        if (value[i] == '"' || value[i] == '\\') cmd[len++] = '\\';
        cmd[len++] = value[i];
    }
    cmd[len++] = '"';
    cmd[len] = '\0';
}

static int luai_run_inner(const char *exe_path, int argc, char **argv) {
    char cmd[32768] = "";
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    DWORD exit_code = 1;
    int i;
    luai_append_quoted(cmd, sizeof(cmd), exe_path);
    for (i = 1; i < argc; ++i) {
        strncat(cmd, " ", sizeof(cmd) - strlen(cmd) - 1);
        luai_append_quoted(cmd, sizeof(cmd), argv[i]);
    }
    ZeroMemory(&si, sizeof(si));
    ZeroMemory(&pi, sizeof(pi));
    si.cb = sizeof(si);
    if (!CreateProcessA(NULL, cmd, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) {
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
    lines[#lines + 1] = "#include <stddef.h>"
    lines[#lines + 1] = "struct luai_embedded_file {"
    lines[#lines + 1] = "    const char *path;"
    lines[#lines + 1] = "    const unsigned char *data;"
    lines[#lines + 1] = "    size_t size;"
    lines[#lines + 1] = "    const char *hash;"
    lines[#lines + 1] = "    int executable;"
    lines[#lines + 1] = "};"
    lines[#lines + 1] = emitFileArrays(files)
    lines[#lines + 1] = "#define LUAI_PAYLOAD_ID " .. cString(payload_id)
    lines[#lines + 1] = "#define LUAI_INNER_EXE " .. cString(inner_exe)
    lines[#lines + 1] = "#define LUAI_FILE_COUNT " .. tostring(#files)
    lines[#lines + 1] = "static const struct luai_embedded_file luai_files[] = {"
    for i, file in ipairs(files) do
        lines[#lines + 1] = string.format(
            "    { %s, luai_file_%d, %d, %s, %d },",
            cString(file.path),
            i,
            file.size,
            cString(file.hash),
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
            shellQuote(c_path),
            "-o",
            shellQuote(exe_path),
            "-static-libgcc",
        }, " ")
    else
        command = table.concat({
            "cc",
            shellQuote(c_path),
            "-o",
            shellQuote(exe_path),
        }, " ")
    end
    local ok, output = commandOutput(command)
    if not ok then
        return makeError("CompilationFailedError", "Onefile extractor compilation failed", {
            command = command,
            output = output,
        })
    end
    if profile.target_os ~= "windows" then
        commandOutput("chmod +x " .. shellQuote(exe_path))
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
    local stage_dir = tempPath("onefile-stage") .. "/inner"
    local build_dir = tempPath("onefile-build")
    local c_path = normalizePath(build_dir .. "/extractor.c")

    local err = removeTree(stage_dir) or removeTree(build_dir) or ensureDirectory(build_dir)
    if err then
        return err
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
        removeTree(build_dir)
        return staged
    end

    local files, payload_id = collectFiles(stage_dir)
    if not files then
        removeTree(build_dir)
        removeTree(dirname(stage_dir))
        return payload_id
    end

    local inner_exe = normalizePath(staged.executable):sub(#normalizePath(stage_dir) + 2)
    local c_source = generateExtractor(files, payload_id, inner_exe)
    err = writeFile(c_path, c_source)
    if err then
        removeTree(build_dir)
        removeTree(dirname(stage_dir))
        return err
    end

    err = ensureDirectory(dirname(out_path))
        or removeFile(out_path)
        or compileExtractor(c_path, out_path, profile)
    removeTree(build_dir)
    removeTree(dirname(stage_dir))
    if err then
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
