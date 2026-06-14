--[[
Recursive source scanner for the ltokei packaging sample.

Author:
    WaterRun
File:
    scanner.lua
Date:
    2026-06-14
Updated:
    2026-06-14
]]

local lfs = require("lfs")
local languages = require("ltokei.languages")

local M = {}

local function new_counts()
    return { files = 0, lines = 0, blanks = 0, comments = 0, code = 0 }
end

local function add_counts(dst, src)
    dst.files = dst.files + src.files
    dst.lines = dst.lines + src.lines
    dst.blanks = dst.blanks + src.blanks
    dst.comments = dst.comments + src.comments
    dst.code = dst.code + src.code
end

local function read_lines(path)
    local file = assert(io.open(path, "rb"))
    local content = file:read("*a") or ""
    file:close()
    content = content:gsub("\r\n", "\n")
    if content == "" then
        return {}
    end
    if content:sub(-1) ~= "\n" then
        content = content .. "\n"
    end

    local out = {}
    for line in content:gmatch("([^\n]*)\n") do
        out[#out + 1] = line
    end
    return out
end

local function scan_file(path, language)
    local counts = new_counts()
    counts.files = 1
    local state = {}
    local fields = {
        blank = "blanks",
        comment = "comments",
        code = "code",
    }
    for _, line in ipairs(read_lines(path)) do
        local kind
        kind, state = languages.classify(language, line, state)
        counts.lines = counts.lines + 1
        counts[fields[kind]] = counts[fields[kind]] + 1
    end
    return counts
end

local function join_path(parent, child)
    local sep = package.config:sub(1, 1)
    if parent:sub(-1) == "/" or parent:sub(-1) == "\\" then
        return parent .. child
    end
    return parent .. sep .. child
end

local function append_file(files, path)
    files[#files + 1] = path
end

local function walk(root, files)
    local mode = lfs.attributes(root, "mode")
    if not mode then
        return nil, "path does not exist or is not readable: " .. tostring(root)
    end
    if mode == "file" then
        append_file(files, root)
        return true
    end
    if mode ~= "directory" then
        return true
    end

    for name in lfs.dir(root) do
        if name ~= "." and name ~= ".." then
            local child = join_path(root, name)
            local ok, err = walk(child, files)
            if not ok then
                return nil, err
            end
        end
    end
    return true
end

local function list_files(root)
    local files = {}
    local ok, err = walk(root, files)
    if not ok then
        return nil, err
    end
    table.sort(files)
    return files
end

function M.scan(root)
    root = root or "."
    local files, err = list_files(root)
    if not files then
        return nil, err
    end

    local report = {
        root = root,
        languages = {},
        total = new_counts(),
    }

    for _, path in ipairs(files) do
        local language = languages.detect(path)
        if language then
            local counts = scan_file(path, language)
            report.languages[language] = report.languages[language] or new_counts()
            add_counts(report.languages[language], counts)
            add_counts(report.total, counts)
        end
    end

    return report
end

return M
