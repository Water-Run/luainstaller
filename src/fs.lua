--[[
Checked filesystem primitives for luainstaller.

Author:
    WaterRun
File:
    fs.lua
Date:
    2026-07-11
Updated:
    2026-07-14
]]

local process = require("luainstaller.process")
local compat = require("luainstaller.compat")

local M = {}

local IS_WINDOWS = package.config:sub(1, 1) == "\\"
local BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64Encode(value)
    local output = {}
    for index = 1, #value, 3 do
        local first = value:byte(index)
        local second = value:byte(index + 1)
        local third = value:byte(index + 2)
        local packed = first * 0x10000 + (second or 0) * 0x100 + (third or 0)
        local first_index = compat.rshift(packed, 18) % 64 + 1
        local second_index = compat.rshift(packed, 12) % 64 + 1
        output[#output + 1] = BASE64_ALPHABET:sub(first_index, first_index)
        output[#output + 1] = BASE64_ALPHABET:sub(second_index, second_index)
        output[#output + 1] = second
            and BASE64_ALPHABET:sub(compat.rshift(packed, 6) % 64 + 1, compat.rshift(packed, 6) % 64 + 1)
            or "="
        output[#output + 1] = third
            and BASE64_ALPHABET:sub(packed % 64 + 1, packed % 64 + 1)
            or "="
    end
    return table.concat(output)
end

local function base64Decode(value)
    local inverse = {}
    for index = 1, #BASE64_ALPHABET do
        inverse[BASE64_ALPHABET:sub(index, index)] = index - 1
    end
    local output = {}
    value = tostring(value or ""):gsub("%s", "")
    for index = 1, #value, 4 do
        local first = inverse[value:sub(index, index)]
        local second = inverse[value:sub(index + 1, index + 1)]
        local third_character = value:sub(index + 2, index + 2)
        local fourth_character = value:sub(index + 3, index + 3)
        local third = inverse[third_character] or 0
        local fourth = inverse[fourth_character] or 0
        if first == nil or second == nil then return nil end
        local packed = first * 0x40000 + second * 0x1000 + third * 0x40 + fourth
        output[#output + 1] = string.char(math.floor(packed / 0x10000) % 0x100)
        if third_character ~= "=" then
            output[#output + 1] = string.char(math.floor(packed / 0x100) % 0x100)
        end
        if fourth_character ~= "=" then
            output[#output + 1] = string.char(packed % 0x100)
        end
    end
    return table.concat(output)
end

local function validPath(path)
    return type(path) == "string" and path ~= "" and not path:find("\0", 1, true)
end

local function windowsPathExpression(path)
    return "[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('"
        .. base64Encode(path) .. "'))"
end

local function windowsRun(script)
    return process.outputPowerShell(table.concat({
        "$ErrorActionPreference='Stop';",
        "$Utf8=New-Object Text.UTF8Encoding($false);",
        "[Console]::OutputEncoding=$Utf8;",
        "try{", script,
        "}catch{[Console]::Error.Write($_.Exception.Message);exit 1}",
    }))
end

local function windowsPathType(path)
    local expression = windowsPathExpression(path)
    local ok, output = windowsRun(table.concat({
        "$Path=", expression, ";",
        "$Item=Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue;",
        "if($null -eq $Item){[Console]::Write('missing');exit 0};",
        "if(($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)",
        "{[Console]::Write('reparse');exit 0};",
        "if(($Item.Attributes -band [IO.FileAttributes]::Device) -ne 0)",
        "{[Console]::Write('other');exit 0};",
        "if($Item -is [IO.FileInfo]){[Console]::Write('file');exit 0};",
        "if($Item -is [IO.DirectoryInfo]){[Console]::Write('directory');exit 0};",
        "[Console]::Write('other')",
    }))
    if not ok then return "other", output end
    output = tostring(output):gsub("%s+$", "")
    if output == "missing" or output == "reparse" or output == "file"
        or output == "directory" or output == "other" then
        return output
    end
    return "other", output
end

local function operationError(operation, path, detail)
    return string.format(
        "Cannot %s file %s: %s",
        operation,
        tostring(path),
        tostring(detail or "unknown filesystem error")
    )
end

function M.readFile(path)
    if IS_WINDOWS then
        if not validPath(path) then return nil, operationError("read", path, "invalid path") end
        local expression = windowsPathExpression(path)
        local ok, output = windowsRun(table.concat({
            "$Path=", expression, ";",
            "$Bytes=[IO.File]::ReadAllBytes($Path);",
            "[Console]::Write([Convert]::ToBase64String($Bytes))",
        }))
        if not ok then return nil, operationError("read", path, output) end
        local decoded = base64Decode(tostring(output):gsub("%s+$", ""))
        if decoded == nil then return nil, operationError("read", path, "invalid encoded content") end
        return decoded
    end
    local opened, handle, open_err = pcall(io.open, path, "rb")
    if not opened then
        return nil, operationError("open", path, handle)
    end
    if not handle then
        return nil, operationError("open", path, open_err)
    end

    local read_ok, content, read_err = pcall(handle.read, handle, "*a")
    local close_ok, closed, close_err = pcall(handle.close, handle)
    if not read_ok then
        return nil, operationError("read", path, content)
    end
    if content == nil then
        return nil, operationError("read", path, read_err)
    end
    if not close_ok then
        return nil, operationError("close", path, closed)
    end
    if not closed then
        return nil, operationError("close", path, close_err)
    end
    return content
end

function M.isRegularFile(path)
    return M.pathType(path) == "file"
end

function M.readRegularFile(path)
    if not M.isRegularFile(path) then
        return nil, operationError("read", path, "path is not a regular file")
    end
    return M.readFile(path)
end

function M.writeFile(path, content)
    if content == nil then
        content = ""
    end
    if type(content) ~= "string" then
        return nil, operationError("write", path, "content must be a string")
    end
    if IS_WINDOWS then
        if not validPath(path) then return nil, operationError("write", path, "invalid path") end
        local expression = windowsPathExpression(path)
        local ok, output = process.inputPowerShell(table.concat({
            "$ErrorActionPreference='Stop';try{",
            "$Path=", expression, ";",
            "$Existing=Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue;",
            "if($null -ne $Existing -and ",
            "(($Existing.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0))",
            "{throw 'destination is a reparse point'};",
            "$Input=[Console]::OpenStandardInput();",
            "$Stream=New-Object IO.FileStream($Path,[IO.FileMode]::Create,",
            "[IO.FileAccess]::Write,[IO.FileShare]::None);",
            "try{$Input.CopyTo($Stream);$Stream.Flush($true)}finally{$Stream.Dispose()}",
            "}catch{exit 1}",
        }), content)
        if not ok then return nil, operationError("write", path, output) end
        return true
    end

    local opened, handle, open_err = pcall(io.open, path, "wb")
    if not opened then
        return nil, operationError("open", path, handle)
    end
    if not handle then
        return nil, operationError("open", path, open_err)
    end

    local write_ok, wrote, write_err = pcall(handle.write, handle, content)
    local flush_ok, flushed, flush_err = pcall(handle.flush, handle)
    local close_ok, closed, close_err = pcall(handle.close, handle)

    if not write_ok then
        return nil, operationError("write", path, wrote)
    end
    if not wrote then
        return nil, operationError("write", path, write_err)
    end
    if not flush_ok then
        return nil, operationError("flush", path, flushed)
    end
    if not flushed then
        return nil, operationError("flush", path, flush_err)
    end
    if not close_ok then
        return nil, operationError("close", path, closed)
    end
    if not closed then
        return nil, operationError("close", path, close_err)
    end
    return true
end

function M.pathType(path)
    if not validPath(path) then return "other" end
    if IS_WINDOWS then return windowsPathType(path) end
    local quoted = process.quote(path)
    if process.output("test -L " .. quoted) then return "reparse" end
    if process.output("test -f " .. quoted) then return "file" end
    if process.output("test -d " .. quoted) then return "directory" end
    if process.output("test -e " .. quoted) then return "other" end
    return "missing"
end

function M.makeDirectory(path)
    if not validPath(path) then return nil, "directory path is invalid" end
    if not IS_WINDOWS then
        local ok, output = process.output("mkdir -p -m 700 " .. process.quote(path))
        if not ok then return nil, output end
        return M.pathType(path) == "directory" and true or nil
    end
    local expression = windowsPathExpression(path)
    local ok, output = windowsRun(table.concat({
        "$Full=[IO.Path]::GetFullPath(", expression, ");",
        "$Root=[IO.Path]::GetPathRoot($Full);",
        "if([string]::IsNullOrEmpty($Root)){throw 'path has no root'};",
        "$Current=$Root;$Relative=$Full.Substring($Root.Length);",
        "foreach($Part in ($Relative -split '[\\/]')){",
        "if([string]::IsNullOrEmpty($Part)){continue};",
        "$Current=[IO.Path]::Combine($Current,$Part);",
        "$Item=Get-Item -LiteralPath $Current -Force -ErrorAction SilentlyContinue;",
        "if($null -ne $Item){",
        "if(-not ($Item -is [IO.DirectoryInfo])){throw 'non-directory ancestor'};",
        "if(($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)",
        "{throw 'reparse ancestor'}",
        "}else{$null=[IO.Directory]::CreateDirectory($Current)}",
        "};",
        "$Final=Get-Item -LiteralPath $Full -Force -ErrorAction Stop;",
        "if(-not ($Final -is [IO.DirectoryInfo])){throw 'not a directory'};",
        "if(($Final.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)",
        "{throw 'reparse directory'}",
    }))
    if not ok then return nil, output end
    return true
end

function M.createDirectory(path)
    if not validPath(path) then return nil, "directory path is invalid" end
    if not IS_WINDOWS then
        if M.pathType(path) ~= "missing" then return nil, "directory already exists" end
        local ok, output = process.output("mkdir -m 700 " .. process.quote(path))
        if not ok then return nil, output end
        return true
    end
    local expression = windowsPathExpression(path)
    local ok, output = windowsRun(table.concat({
        "$Path=[IO.Path]::GetFullPath(", expression, ");",
        "$Existing=Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue;",
        "if($null -ne $Existing){throw 'directory already exists'};",
        "$null=New-Item -ItemType Directory -Path $Path -ErrorAction Stop",
    }))
    if not ok then return nil, output end
    return true
end

function M.removeDirectory(path)
    if not IS_WINDOWS then
        if M.pathType(path) ~= "directory" then return nil, "path is not a safe directory" end
        local ok, output = process.output("rmdir " .. process.quote(path))
        if not ok then return nil, output end
        return true
    end
    if not validPath(path) then return nil, "directory path is invalid" end
    local expression = windowsPathExpression(path)
    local ok, output = windowsRun(table.concat({
        "$Path=", expression, ";$Item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop;",
        "if(-not ($Item -is [IO.DirectoryInfo])){throw 'not a directory'};",
        "if(($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)",
        "{throw 'reparse directory'};[IO.Directory]::Delete($Path,$false)",
    }))
    if not ok then return nil, output end
    return true
end

function M.modifiedAt(path)
    if not IS_WINDOWS then
        if M.pathType(path) == "missing" then return nil end
        local value = process.firstLine("stat -c %Y " .. process.quote(path) .. " 2>/dev/null")
        if not tonumber(value) then
            value = process.firstLine("stat -f %m " .. process.quote(path) .. " 2>/dev/null")
        end
        return tonumber(value)
    end
    local expression = windowsPathExpression(path)
    local ok, output = windowsRun(table.concat({
        "$Path=", expression, ";$Item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop;",
        "$Time=[DateTimeOffset]$Item.LastWriteTimeUtc;",
        "[Console]::Write($Time.ToUnixTimeSeconds())",
    }))
    if not ok then return nil end
    return tonumber(tostring(output):match("%-?%d+"))
end

function M.makePrivateDirectory(label, parent)
    label = tostring(label or "private"):gsub("[^%w_-]", "-")
    if not parent then
        if IS_WINDOWS then
            parent = os.getenv("TEMP") or os.getenv("TMP") or "."
        else
            parent = os.getenv("TMPDIR") or "/tmp"
        end
    end
    local made, make_err = M.makeDirectory(parent)
    if not made then return nil, make_err end
    for attempt = 1, 40 do
        local suffix = table.concat({
            tostring(os.time()),
            tostring(math.floor(os.clock() * 1000000000)),
            tostring(math.random(100000, 999999)),
            tostring(attempt),
        }, "-")
        local separator = parent:match("[/\\]$") and "" or package.config:sub(1, 1)
        local candidate = parent .. separator .. "luainstaller-" .. label .. "-" .. suffix
        if IS_WINDOWS then
            local expression = windowsPathExpression(candidate)
            local ok = windowsRun(table.concat({
                "$Path=[IO.Path]::GetFullPath(", expression, ");",
                "if(Test-Path -LiteralPath $Path){exit 17};",
                "$null=New-Item -ItemType Directory -Path $Path -ErrorAction Stop",
            }))
            if ok then return candidate:gsub("\\", "/") end
        else
            local ok = process.output("mkdir -m 700 " .. process.quote(candidate))
            if ok then return candidate end
        end
    end
    return nil, "cannot create a unique private directory"
end

function M.copyFile(source, destination)
    if not validPath(destination) then return nil, "destination path is invalid" end
    if IS_WINDOWS then
        if not validPath(source) then return nil, "source path is invalid" end
        local source_expression = windowsPathExpression(source)
        local destination_expression = windowsPathExpression(destination)
        local ok, output = windowsRun(table.concat({
            "$Source=", source_expression, ";$Destination=", destination_expression, ";",
            "$SourceItem=Get-Item -LiteralPath $Source -Force -ErrorAction Stop;",
            "if(-not ($SourceItem -is [IO.FileInfo])){throw 'source is not a file'};",
            "if(($SourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)",
            "{throw 'source is a reparse point'};",
            "$DestinationItem=Get-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue;",
            "if($null -ne $DestinationItem){throw 'destination already exists'};",
            "[IO.File]::Copy($Source,$Destination,$false)",
        }))
        if not ok then return nil, output end
        return true
    end
    if M.pathType(source) ~= "file" then return nil, "source is not a regular file" end
    local ok, output = process.output(
        "cp " .. process.quote(source) .. " " .. process.quote(destination)
    )
    if not ok then return nil, output end
    return true
end

function M.rename(source, destination)
    if not validPath(source) or not validPath(destination) then
        return nil, "source or destination path is invalid"
    end
    if not IS_WINDOWS then
        local source_type = M.pathType(source)
        if source_type ~= "file" and source_type ~= "directory" then
            return nil, "source is not a safe file or directory"
        end
        if M.pathType(destination) ~= "missing" then
            return nil, "destination already exists"
        end
        local ok, err = os.rename(source, destination)
        if not ok then return nil, err end
        return true
    end
    local source_expression = windowsPathExpression(source)
    local destination_expression = windowsPathExpression(destination)
    local ok, output = windowsRun(table.concat({
        "$Source=", source_expression, ";$Destination=", destination_expression, ";",
        "$Item=Get-Item -LiteralPath $Source -Force -ErrorAction Stop;",
        "if(($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)",
        "{throw 'source is a reparse point'};",
        "if(Test-Path -LiteralPath $Destination){throw 'destination already exists'};",
        "if($Item -is [IO.FileInfo]){[IO.File]::Move($Source,$Destination)}",
        "elseif($Item -is [IO.DirectoryInfo]){[IO.Directory]::Move($Source,$Destination)}",
        "else{throw 'source has an unsafe type'}",
    }))
    if not ok then return nil, output end
    return true
end

function M.hardLink(source, destination)
    if not validPath(source) or not validPath(destination) then
        return nil, "source or destination path is invalid"
    end
    if M.pathType(source) ~= "file" then
        return nil, "source is not a safe regular file"
    end
    if M.pathType(destination) ~= "missing" then
        return nil, "destination already exists"
    end
    if not IS_WINDOWS then
        local ok, output = process.outputCommand("ln", { source, destination })
        if not ok then return nil, output end
        return true
    end
    local source_expression = windowsPathExpression(source)
    local destination_expression = windowsPathExpression(destination)
    local ok, output = windowsRun(table.concat({
        "$Source=", source_expression, ";$Destination=", destination_expression, ";",
        "$Item=Get-Item -LiteralPath $Source -Force -ErrorAction Stop;",
        "if(-not ($Item -is [IO.FileInfo])){throw 'source is not a file'};",
        "if(($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)",
        "{throw 'source is a reparse point'};",
        "if(Test-Path -LiteralPath $Destination){throw 'destination already exists'};",
        "$null=New-Item -ItemType HardLink -Path $Destination -Target $Source -ErrorAction Stop",
    }))
    if not ok then return nil, output end
    return true
end

function M.isExecutable(path)
    if M.pathType(path) ~= "file" then return false end
    if IS_WINDOWS then return true end
    local ok = process.outputCommand("test", { "-x", path })
    return ok == true
end

function M.setExecutable(path)
    if M.pathType(path) ~= "file" then return nil, "path is not a regular file" end
    if IS_WINDOWS then return true end
    local ok, output = process.outputCommand("chmod", { "+x", path })
    if not ok then return nil, output end
    return true
end

function M.listTree(root)
    if M.pathType(root) ~= "directory" then return nil, "tree root is not a directory" end
    local entries = {}
    if IS_WINDOWS then
        local expression = windowsPathExpression(root)
        local ok, output = windowsRun(table.concat({
            "$Root=[IO.Path]::GetFullPath(", expression, ");",
            "$Pending=New-Object 'System.Collections.Generic.Stack[string]';$Pending.Push($Root);",
            "$Utf8=New-Object Text.UTF8Encoding($false);",
            "while($Pending.Count -gt 0){$Directory=$Pending.Pop();",
            "foreach($Child in [IO.Directory]::EnumerateFileSystemEntries($Directory)){",
            "$Item=Get-Item -LiteralPath $Child -Force -ErrorAction Stop;",
            "$Relative=$Child.Substring($Root.Length).TrimStart([char[]]'\\/');",
            "$Type='other';",
            "if(($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){$Type='reparse'}",
            "elseif($Item -is [IO.DirectoryInfo]){$Type='directory';$Pending.Push($Child)}",
            "elseif($Item -is [IO.FileInfo]){$Type='file'};",
            "$Encoded=[Convert]::ToBase64String($Utf8.GetBytes($Relative));",
            "[Console]::Write($Type+[char]9+$Encoded+[char]10)",
            "}}",
        }))
        if not ok then return nil, output end
        for line in tostring(output):gmatch("[^\r\n]+") do
            local entry_type, encoded = line:match("^(%w+)\t([A-Za-z0-9+/=]+)$")
            local relative = encoded and base64Decode(encoded)
            if not relative then return nil, "invalid Windows tree inventory" end
            entries[#entries + 1] = { path = relative:gsub("\\", "/"), type = entry_type }
        end
    else
        local ok, output = process.output("find " .. process.quote(root) .. " -mindepth 1 -print0")
        if not ok then return nil, output end
        output = tostring(output)
        local position = 1
        while position <= #output do
            local terminator = output:find("\0", position, true)
            if not terminator then return nil, "incomplete POSIX tree inventory" end
            local absolute = output:sub(position, terminator - 1)
            local relative = absolute:sub(#root + 1):gsub("^/", "")
            entries[#entries + 1] = { path = relative, type = M.pathType(absolute) }
            position = terminator + 1
        end
    end
    table.sort(entries, function(left, right) return left.path < right.path end)
    return entries
end

function M.removeFile(path)
    if not IS_WINDOWS then
        local kind = M.pathType(path)
        if kind ~= "file" and kind ~= "reparse" then
            return nil, "path is not a removable file or reparse point"
        end
        local ok, err = os.remove(path)
        if not ok then return nil, err end
        return true
    end
    if not validPath(path) then return nil, "file path is invalid" end
    local expression = windowsPathExpression(path)
    local ok, output = windowsRun(table.concat({
        "$Path=", expression, ";$Item=Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue;",
        "if($null -eq $Item){exit 0};",
        "$Reparse=(($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0);",
        "if(-not $Reparse -and -not ($Item -is [IO.FileInfo])){throw 'unsafe removal target'};",
        "if($Item -is [IO.DirectoryInfo]){[IO.Directory]::Delete($Path,$false)}",
        "else{[IO.File]::Delete($Path)}",
    }))
    if not ok then return nil, output end
    return true
end

function M.removeTree(root)
    local entries, list_err = M.listTree(root)
    if not entries then return nil, list_err end
    for _, entry in ipairs(entries) do
        if entry.type == "reparse" then
            return nil, "refusing to remove a tree containing a reparse point: " .. entry.path
        end
        if entry.type == "other" then
            return nil, "refusing to remove a tree containing an unsafe entry: " .. entry.path
        end
    end
    if IS_WINDOWS then
        local expression = windowsPathExpression(root)
        local ok, output = windowsRun(table.concat({
            "$Root=[IO.Path]::GetFullPath(", expression, ");",
            "$RootItem=Get-Item -LiteralPath $Root -Force -ErrorAction Stop;",
            "if(-not ($RootItem -is [IO.DirectoryInfo])){throw 'root is not a directory'};",
            "if(($RootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)",
            "{throw 'root is a reparse point'};",
            "foreach($Child in Get-ChildItem -LiteralPath $Root -Force -Recurse -ErrorAction Stop){",
            "if(($Child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)",
            "{throw 'tree contains a reparse point'}",
            "};[IO.Directory]::Delete($Root,$true)",
        }))
        if not ok then return nil, output end
        return true
    end
    local ok, output = process.output("rm -rf " .. process.quote(root))
    if not ok then return nil, output end
    return true
end

return M
