--[[
Dependency analyzer for Lua scripts.
Provides comprehensive static analysis including require
extraction via a token-aware lexer, module path resolution
across package.path and package.cpath, native library
detection (.so, .dll, .dylib), and recursive dependency
graph construction with cycle detection and topological sort.

Author:
    WaterRun
File:
    analyzer.lua
Date:
    2026-02-22
Updated:
    2026-07-11
]]

local fs = require("luainstaller.fs")
local hash = require("luainstaller.hash")
local path = require("luainstaller.path")

-- ============================================================
-- Path Utilities
-- ============================================================

--@description: Path separator for the current platform
--@const: PATH_SEP
local PATH_SEP = package.config:sub(1, 1)

--@description: True when running on Windows
--@const: IS_WINDOWS
local IS_WINDOWS = (PATH_SEP == "\\")

--@description: Set of native library file extensions
--@const: NATIVE_EXTENSIONS
local NATIVE_EXTENSIONS = {
    [".so"]    = true,
    [".dll"]   = true,
    [".dylib"] = true,
}

--@description: Set of Lua builtin module names that require no file
--@const: BUILTIN_MODULES
local BUILTIN_MODULES = {
    ["_G"]        = true,
    ["coroutine"] = true,
    ["debug"]     = true,
    ["io"]        = true,
    ["math"]      = true,
    ["os"]        = true,
    ["package"]   = true,
    ["string"]    = true,
    ["table"]     = true,
    ["utf8"]      = true,
}

--@description: Default maximum dependency count
--@const: DEFAULT_MAX_DEPS
local DEFAULT_MAX_DEPS = 36

local normalizePath = path.normalize
local resolvePath = path.absolute
local pathParent = path.dirname
local pathBasename = path.basename
local pathExtension = path.extension


--@description: Check whether a file exists and is readable
--@local: true
--@param path: string - File path to probe
--@return: boolean - True when the file can be opened for reading
local function fileExists(path)
    return fs.isRegularFile(path)
end


--@description: Read the full content of a file with encoding fallback
--@local: true
--@param path: string - Absolute file path
--@return: string - File content
--@raise: error table when the file cannot be opened
local function readFileContent(path)
    local content, read_err = fs.readRegularFile(path)
    if content == nil then
        error({
            type    = "ScriptNotFoundError",
            message = string.format("Cannot read file: %s", path),
            script_path = path,
            cause = read_err,
        })
    end
    return content
end


-- ============================================================
-- Error Constructors
-- ============================================================

--[[
Structured error constructor functions.
Each returns a table with a type field for programmatic
identification and a message field for display.

Module:
    errors
]]
local errors = {}


--@description: Create a ScriptNotFoundError table
--@param path: string - Path to the missing script
--@return: table - Error table with type and message
function errors.scriptNotFound(path)
    return {
        type        = "ScriptNotFoundError",
        message     = string.format("Lua script not found: %s", path),
        script_path = path,
    }
end

--@description: Create a CircularDependencyError table
--@param chain: table - Ordered list of paths forming the cycle
--@return: table - Error table with type, message, and chain
function errors.circularDependency(chain)
    return {
        type    = "CircularDependencyError",
        message = string.format("Circular dependency detected: %s", table.concat(chain, " -> ")),
        chain   = chain,
    }
end

--@description: Create a DynamicRequireError table
--@param script_path: string - File containing the dynamic require
--@param line_number: number - Source line number
--@param statement: string - The problematic require text
--@return: table - Error table
function errors.dynamicRequire(script_path, line_number, statement)
    return {
        type        = "DynamicRequireError",
        message     = string.format(
            "Dynamic require at %s:%d: %s\nOnly static require('name') is supported.",
            script_path, line_number, statement
        ),
        script_path = script_path,
        line_number = line_number,
        statement   = statement,
    }
end

--@description: Create a DependencyLimitExceededError table
--@param current_count: number - Actual dependency count found
--@param limit: number - Configured maximum
--@return: table - Error table
function errors.dependencyLimitExceeded(current_count, limit)
    return {
        type          = "DependencyLimitExceededError",
        message       = string.format(
            "Dependency count (%d) exceeds limit (%d)",
            current_count, limit
        ),
        current_count = current_count,
        limit         = limit,
    }
end

--@description: Create a ModuleNotFoundError table
--@param module_name: string - Unresolved module name
--@param script_path: string - Script that requires the module
--@param searched_paths: table - List of directories searched
--@return: table - Error table
function errors.moduleNotFound(module_name, script_path, searched_paths)
    return {
        type           = "ModuleNotFoundError",
        message        = string.format(
            "Cannot resolve module '%s' required in %s\nSearched: %s",
            module_name, script_path, table.concat(searched_paths, ", ")
        ),
        module_name    = module_name,
        script_path    = script_path,
        searched_paths = searched_paths,
    }
end

function errors.luaSyntax(script_path, detail)
    return {
        type = "LuaSyntaxError",
        message = string.format("Invalid Lua syntax in %s: %s", script_path, tostring(detail)),
        script_path = script_path,
        detail = tostring(detail),
    }
end

local function prepareSource(source)
    source = tostring(source or "")
    if source:sub(1, 3) == "\239\187\191" then
        source = source:sub(4)
    end
    if source:sub(1, 2) == "#!" then
        local newline_start, newline_end = source:find("\r\n", 1, true)
        if not newline_start then
            newline_start, newline_end = source:find("[\r\n]")
        end
        if newline_start then
            source = "\n" .. source:sub(newline_end + 1)
        else
            source = ""
        end
    end
    return source
end

local function validateSource(source, script_path)
    local prepared = prepareSource(source)
    local loader, syntax_err = load(prepared, "@" .. tostring(script_path), "t", {})
    if not loader then
        error(errors.luaSyntax(script_path, syntax_err))
    end
    return prepared
end

-- ============================================================
-- LuaLexer
-- ============================================================

--[[
Lightweight Lua lexer focused on extracting static require
statements. Uses token-aware scanning to correctly skip strings
and comments. Supports direct require calls, pcall-wrapped
requires, and all Lua string literal forms.

Class:
    LuaLexer
Fields:
    source: string - Full source text
    source_len: number - Cached byte length
    file_path: string - Origin file path for diagnostics
    pos: number - Current byte position (1-based)
    line: number - Current line number
]]
local LuaLexer = {}
LuaLexer.__index = LuaLexer


--@description: Construct a new LuaLexer instance
--@param source_code: string - Lua source text to analyze
--@param file_path: string - Path of the source file
--@return: LuaLexer - New lexer instance
--@usage: local lexer = LuaLexer.new(code, "main.lua")
function LuaLexer.new(source_code, file_path)
    source_code        = prepareSource(source_code)
    local self         = setmetatable({}, LuaLexer)
    self.source        = source_code
    self.source_len    = #source_code
    self.file_path     = file_path
    self.pos           = 1
    self.line          = 1
    self.previous_token = nil
    return self
end

--@description: Return the character at the current position
--@param self: LuaLexer - Lexer instance
--@return: string - Single character or empty string at end
function LuaLexer:currentChar()
    if self.pos > self.source_len then
        return ""
    end
    return self.source:sub(self.pos, self.pos)
end

--@description: Look ahead at a character without advancing position
--@param self: LuaLexer - Lexer instance
--@param offset: number - Forward offset from current position (default 1)
--@return: string - Character at the offset or empty string
function LuaLexer:peekChar(offset)
    offset = offset or 1
    local idx = self.pos + offset
    if idx > self.source_len then
        return ""
    end
    return self.source:sub(idx, idx)
end

--@description: Test whether the current position matches a keyword surrounded by non-identifier chars
--@param self: LuaLexer - Lexer instance
--@param keyword: string - Keyword to match
--@return: boolean - True when the keyword matches at the current boundary
function LuaLexer:matchKeyword(keyword)
    local kw_len = #keyword
    if self.pos + kw_len - 1 > self.source_len then
        return false
    end
    if self.source:sub(self.pos, self.pos + kw_len - 1) ~= keyword then
        return false
    end
    if self.pos > 1 then
        local prev = self.source:sub(self.pos - 1, self.pos - 1)
        if prev:match("[%w_.:]") then
            return false
        end
    end
    local next_pos = self.pos + kw_len
    if next_pos <= self.source_len then
        local nxt = self.source:sub(next_pos, next_pos)
        if nxt:match("[%w_.:]") then
            return false
        end
    end
    return true
end

--@description: Check that the character at the current position is not backslash-escaped
--@param self: LuaLexer - Lexer instance
--@return: boolean - True when the character is unescaped
function LuaLexer:isNotEscaped()
    if self.pos <= 1 then
        return true
    end
    local count = 0
    local check = self.pos - 1
    while check >= 1 and self.source:sub(check, check) == "\\" do
        count = count + 1
        check = check - 1
    end
    return (count % 2) == 0
end

--@description: Count the bracket level of a long bracket [=*[ starting at an offset
--@param self: LuaLexer - Lexer instance
--@param start_offset: number - Byte offset from current position to the opening bracket
--@return: number - Bracket level (number of equals signs), or -1 when invalid
function LuaLexer:countBracketLevel(start_offset)
    local idx = self.pos + start_offset
    if idx > self.source_len or self.source:sub(idx, idx) ~= "[" then
        return -1
    end
    idx = idx + 1
    local level = 0
    while idx <= self.source_len and self.source:sub(idx, idx) == "=" do
        level = level + 1
        idx = idx + 1
    end
    if idx <= self.source_len and self.source:sub(idx, idx) == "[" then
        return level
    end
    return -1
end

--@description: Test whether the current position begins a closing bracket ]=*] with the expected level
--@param self: LuaLexer - Lexer instance
--@param expected_level: number - Required number of equals signs
--@return: boolean - True when a matching closing bracket is found
function LuaLexer:checkClosingBracket(expected_level)
    if self:currentChar() ~= "]" then
        return false
    end
    local idx = self.pos + 1
    local level = 0
    while idx <= self.source_len and self.source:sub(idx, idx) == "=" do
        level = level + 1
        idx = idx + 1
    end
    return idx <= self.source_len
        and self.source:sub(idx, idx) == "]"
        and level == expected_level
end

--@description: Advance one Lua source character while normalizing line counts
--@param self: LuaLexer - Lexer instance
function LuaLexer:advanceCharacter()
    local ch = self:currentChar()
    if ch == "\r" then
        self.pos = self.pos + 1
        if self:currentChar() == "\n" then
            self.pos = self.pos + 1
        end
        self.line = self.line + 1
    elseif ch == "\n" then
        self.pos = self.pos + 1
        self.line = self.line + 1
    else
        self.pos = self.pos + 1
    end
end

--@description: Advance past all Lua whitespace while tracking line numbers
--@param self: LuaLexer - Lexer instance
function LuaLexer:skipWhitespace()
    while self.pos <= self.source_len and self:currentChar():match("%s") do
        self:advanceCharacter()
    end
end

--@description: Skip a line or long-bracket comment at the current position
--@param self: LuaLexer - Lexer instance
function LuaLexer:skipComment()
    if self:currentChar() ~= "-" or self:peekChar() ~= "-" then
        return
    end
    local level = self:peekChar(2) == "[" and self:countBracketLevel(2) or -1
    if level >= 0 then
        self.pos = self.pos + 4 + level
        while self.pos <= self.source_len do
            if self:currentChar() == "]" and self:checkClosingBracket(level) then
                self.pos = self.pos + 2 + level
                return
            end
            self:advanceCharacter()
        end
        return
    end

    self.pos = self.pos + 2
    while self.pos <= self.source_len do
        local ch = self:currentChar()
        if ch == "\r" or ch == "\n" then
            self:advanceCharacter()
            return
        end
        self.pos = self.pos + 1
    end
end

--@description: Skip Lua whitespace and comments
--@param self: LuaLexer - Lexer instance
function LuaLexer:skipTrivia()
    while self.pos <= self.source_len do
        if self:currentChar():match("%s") then
            self:skipWhitespace()
        elseif self:currentChar() == "-" and self:peekChar() == "-" then
            self:skipComment()
        else
            return
        end
    end
end

--@description: Extract a quoted string literal and return its content
--@param self: LuaLexer - Lexer instance
--@param start_line: number - Line where the require keyword appeared
--@return: string - Content of the string literal
--@raise: DynamicRequireError on unterminated or concatenated strings
function LuaLexer:extractStringLiteral(start_line)
    local start_pos = self.pos
    local quote = self:currentChar()
    self.pos = self.pos + 1

    while self.pos <= self.source_len do
        local ch = self:currentChar()
        if ch == quote and self:isNotEscaped() then
            self.pos = self.pos + 1
            local raw = self.source:sub(start_pos, self.pos - 1)
            local decoder, decode_err = load(
                "return " .. raw,
                "=(luainstaller-require-literal)",
                "t",
                {}
            )
            if not decoder then
                error(errors.dynamicRequire(
                    self.file_path, start_line,
                    "Invalid string literal in require: " .. tostring(decode_err)
                ))
            end
            local ok, result = pcall(decoder)
            if not ok or type(result) ~= "string" then
                error(errors.dynamicRequire(
                    self.file_path, start_line,
                    "Invalid string literal in require"
                ))
            end
            return result
        end
        if ch == "\\" then
            self.pos = self.pos + 1
            if self.pos <= self.source_len then
                self:advanceCharacter()
            end
        else
            self:advanceCharacter()
        end
    end

    error(errors.dynamicRequire(
        self.file_path, start_line, "Unterminated string in require"
    ))
end

--@description: Extract a long bracket string literal and return its content
--@param self: LuaLexer - Lexer instance
--@param level: number - Bracket level of the opening bracket
--@param start_line: number - Line where the require keyword appeared
--@return: string - Content of the long string literal
--@raise: DynamicRequireError on unterminated strings
function LuaLexer:extractLongStringLiteral(level, start_line)
    local start_pos = self.pos
    self.pos = self.pos + 2 + level

    while self.pos <= self.source_len do
        if self:currentChar() == "]" and self:checkClosingBracket(level) then
            self.pos = self.pos + 2 + level
            local raw = self.source:sub(start_pos, self.pos - 1)
            local decoder, decode_err = load(
                "return " .. raw,
                "=(luainstaller-require-long-literal)",
                "t",
                {}
            )
            if not decoder then
                error(errors.dynamicRequire(
                    self.file_path, start_line,
                    "Invalid long string literal in require: " .. tostring(decode_err)
                ))
            end
            local ok, result = pcall(decoder)
            if not ok or type(result) ~= "string" then
                error(errors.dynamicRequire(
                    self.file_path, start_line,
                    "Invalid long string literal in require"
                ))
            end
            return result
        end
        self:advanceCharacter()
    end

    error(errors.dynamicRequire(
        self.file_path, start_line, "Unterminated long string in require"
    ))
end

--@description: Parse a pcall(require, 'module') statement
--@param self: LuaLexer - Lexer instance
--@return: string|nil - Module name when valid, nil otherwise
function LuaLexer:parsePcallRequire()
    local saved_pos  = self.pos
    local saved_line = self.line

    if self.previous_token == "function"
        or self.previous_token == "."
        or self.previous_token == ":" then
        self.pos = self.pos + #"pcall"
        return nil
    end

    self.pos = self.pos + #"pcall"
    self:skipTrivia()

    if self:currentChar() ~= "(" then
        self.pos  = saved_pos
        self.line = saved_line
        return nil
    end
    self.pos = self.pos + 1
    self:skipTrivia()

    if not self:matchKeyword("require") then
        self.pos  = saved_pos
        self.line = saved_line
        return nil
    end
    local require_line = self.line
    self.pos = self.pos + #"require"
    self:skipTrivia()

    if self:currentChar() ~= "," then
        self.pos  = saved_pos
        self.line = saved_line
        return nil
    end
    self.pos = self.pos + 1
    self:skipTrivia()

    local ch = self:currentChar()
    local module_name

    if ch == '"' or ch == "'" then
        module_name = self:extractStringLiteral(saved_line)
    elseif ch == "[" then
        local level = self:countBracketLevel(0)
        if level >= 0 then
            module_name = self:extractLongStringLiteral(level, saved_line)
        end
    end

    if not module_name then
        error(errors.dynamicRequire(
            self.file_path,
            require_line,
            "pcall(require, <computed>)"
        ))
    end

    self:skipTrivia()
    if self.source:sub(self.pos, self.pos + 1) == ".." then
        error(errors.dynamicRequire(
            self.file_path,
            require_line,
            string.format("pcall(require, '%s' .. ...)", module_name)
        ))
    end
    if self:currentChar() == ")" then
        self.pos = self.pos + 1
    elseif self:currentChar() ~= "," then
        error(errors.dynamicRequire(
            self.file_path,
            require_line,
            "pcall(require, <computed>)"
        ))
    end

    return {
        name = module_name,
        line = require_line,
        optional = true,
    }
end

--@description: Parse a require statement and extract the module name
--@param self: LuaLexer - Lexer instance
--@return: string|nil - Module name, nil to skip
--@raise: DynamicRequireError when the require argument is not a string literal
function LuaLexer:parseRequire()
    local saved_pos  = self.pos
    local saved_line = self.line

    if self.previous_token == "function"
        or self.previous_token == "."
        or self.previous_token == ":" then
        self.pos = self.pos + #"require"
        return nil
    end

    self.pos = self.pos + #"require"
    self:skipTrivia()

    local ch = self:currentChar()
    local has_paren = false

    if ch == "(" then
        has_paren = true
        self.pos = self.pos + 1
        self:skipTrivia()
        ch = self:currentChar()
    end

    local module_name
    if ch == '"' or ch == "'" then
        module_name = self:extractStringLiteral(saved_line)
    elseif ch == "[" then
        local level = self:countBracketLevel(0)
        if level >= 0 then
            module_name = self:extractLongStringLiteral(level, saved_line)
        end
    end

    if module_name then
        if has_paren then
            self:skipTrivia()
            if self.source:sub(self.pos, self.pos + 1) == ".." then
                error(errors.dynamicRequire(
                    self.file_path,
                    saved_line,
                    string.format("require('%s' .. ...)", module_name)
                ))
            end
            if self:currentChar() == ")" then
                self.pos = self.pos + 1
            elseif self:currentChar() ~= "," then
                error(errors.dynamicRequire(
                    self.file_path,
                    saved_line,
                    "require(<computed>)"
                ))
            end
        end
        return {
            name = module_name,
            line = saved_line,
        }
    end

    if not has_paren and ch ~= "{" then
        return nil
    end

    local end_pos = self.pos
    while end_pos <= self.source_len do
        local c = self.source:sub(end_pos, end_pos)
        if c == "\n" or c == ";" then break end
        end_pos = end_pos + 1
    end
    local stmt = self.source:sub(saved_pos, end_pos - 1):gsub("^%s+", ""):gsub("%s+$", "")
    error(errors.dynamicRequire(self.file_path, saved_line, stmt))
end

--@description: Extract all static require statements from the source
--@param self: LuaLexer - Lexer instance
--@return: table - List of {name=string, line=number} entries
function LuaLexer:extractRequires()
    local result = {}

    while self.pos <= self.source_len do
        local char = self:currentChar()
        if char:match("%s") then
            self:skipWhitespace()
        elseif char == "-" and self:peekChar() == "-" then
            self:skipComment()
        elseif char == "'" or char == '"' then
            self:extractStringLiteral(self.line)
            self.previous_token = "string"
        elseif char == "[" and self:countBracketLevel(0) >= 0 then
            self:extractLongStringLiteral(self:countBracketLevel(0), self.line)
            self.previous_token = "string"
        elseif self:matchKeyword("pcall") then
            local pcall_pos = self.pos
            local record = self:parsePcallRequire()
            if record then
                result[#result + 1] = record
            elseif self.pos == pcall_pos then
                self.pos = self.pos + #"pcall"
            end
            self.previous_token = "pcall"
        elseif self:matchKeyword("require") then
            local record = self:parseRequire()
            if record then
                result[#result + 1] = record
            end
            self.previous_token = "require"
        elseif char:match("[%a_]") then
            local identifier = self.source:match("^([%a_][%w_]*)", self.pos)
            self.previous_token = identifier
            self.pos = self.pos + #identifier
        elseif self.source:sub(self.pos, self.pos + 2) == "..." then
            self.previous_token = "..."
            self.pos = self.pos + 3
        elseif self.source:sub(self.pos, self.pos + 1) == ".." then
            self.previous_token = ".."
            self.pos = self.pos + 2
        else
            self.previous_token = char
            self:advanceCharacter()
        end
    end

    return result
end

-- ============================================================
-- ModuleResolver
-- ============================================================

--[[
Resolves Lua module names to absolute file paths by searching
package.path templates for Lua scripts and package.cpath
templates for loadable native libraries. Handles
dot-separated and relative module names.

Class:
    ModuleResolver
Fields:
    base_path: string - Absolute base directory for resolution
    lua_templates: table - Ordered list of package.path template strings
    native_templates: table - Ordered list of native search template strings
]]
local ModuleResolver = {}
ModuleResolver.__index = ModuleResolver


--@description: Construct a new ModuleResolver rooted at the given directory
--@param base_path: string - Absolute directory path
--@return: ModuleResolver - New resolver instance
--@usage: local resolver = ModuleResolver.new("/home/user/project")
function ModuleResolver.new(base_path)
    local self = setmetatable({}, ModuleResolver)
    self.base_path = resolvePath(base_path)
    self.lua_templates = {}
    self.native_templates = {}
    self:buildSearchTemplates()
    return self
end

--@description: Populate lua_templates and native_templates from package paths and common directories
--@param self: ModuleResolver - Resolver instance
function ModuleResolver:buildSearchTemplates()
    local seen_lua    = {}
    local seen_native = {}
    local base        = self.base_path

    --@description: Append a template if not already seen
    --@local: true
    local function addLua(tpl)
        if not seen_lua[tpl] then
            seen_lua[tpl] = true
            self.lua_templates[#self.lua_templates + 1] = tpl
        end
    end

    --@description: Append a native template if not already seen
    --@local: true
    local function addNative(tpl)
        if not seen_native[tpl] then
            seen_native[tpl] = true
            self.native_templates[#self.native_templates + 1] = tpl
        end
    end

    addLua(base .. "/?.lua")
    addLua(base .. "/?/init.lua")
    addLua(base .. "/src/?.lua")
    addLua(base .. "/src/?/init.lua")
    addLua(base .. "/lib/?.lua")
    addLua(base .. "/lua_modules/?.lua")

    if package.path then
        for raw_tpl in package.path:gmatch("[^;]+") do
            local tpl = raw_tpl:gsub("^%s+", ""):gsub("%s+$", ""):gsub("\\", "/")
            if tpl ~= "" and tpl:find("%?") then
                addLua(tpl)
            end
        end
    end

    if IS_WINDOWS then
        addNative(base .. "/?.dll")
        addNative(base .. "/?/init.dll")
        addNative(base .. "/lib/?.dll")
        addNative(base .. "/lib/?/init.dll")
    else
        addNative(base .. "/?.so")
        addNative(base .. "/?/init.so")
        addNative(base .. "/lib/?.so")
        addNative(base .. "/lib/?/init.so")
        addNative(base .. "/?.dylib")
        addNative(base .. "/?/init.dylib")
    end

    if package.cpath then
        for raw_tpl in package.cpath:gmatch("[^;]+") do
            local tpl = raw_tpl:gsub("^%s+", ""):gsub("%s+$", ""):gsub("\\", "/")
            if tpl ~= "" and tpl:find("%?") then
                addNative(tpl)
            end
        end
    end
end

--@description: Test whether a module name refers exactly to a Lua builtin
--@param self: ModuleResolver - Resolver instance
--@param module_name: string - Dot-separated module name
--@return: boolean - True when the module name is a builtin name
function ModuleResolver:isBuiltin(module_name)
    return BUILTIN_MODULES[module_name] == true
end

--@description: Collect a deduplicated list of search directory descriptions
--@param self: ModuleResolver - Resolver instance
--@return: table - List of directory path strings
function ModuleResolver:getSearchedPaths()
    local dirs = {}
    local seen = {}
    for _, tpl in ipairs(self.lua_templates) do
        local dir = pathParent(tpl:gsub("%?.*$", "x"))
        if not seen[dir] then
            seen[dir] = true
            dirs[#dirs + 1] = dir
        end
    end
    for _, tpl in ipairs(self.native_templates) do
        local dir = pathParent(tpl:gsub("%?.*$", "x"))
        if not seen[dir] then
            seen[dir] = true
            dirs[#dirs + 1] = dir
        end
    end
    return dirs
end

--@description: Build the ordered candidate list for a module resolution attempt
--@param self: ModuleResolver - Resolver instance
--@param module_name: string - Module name passed to require
--@param from_script: string - Absolute path of the requiring script
--@return: table - Ordered candidate records
function ModuleResolver:buildCandidates(module_name, from_script)
    local candidates = {}

    if self:isBuiltin(module_name) then
        return candidates
    end

    if module_name:sub(1, 2) == "./" or module_name:sub(1, 3) == "../" then
        local base_dir = pathParent(from_script)
        local target = normalizePath(base_dir .. "/" .. module_name)
        local ext = pathExtension(target)
        local lua_paths = {}
        local native_paths = {}

        if ext == ".lua" then
            lua_paths[#lua_paths + 1] = target
        elseif ext and NATIVE_EXTENSIONS[ext] then
            native_paths[#native_paths + 1] = target
        else
            lua_paths[#lua_paths + 1] = target .. ".lua"
            lua_paths[#lua_paths + 1] = target .. "/init.lua"
            native_paths[#native_paths + 1] = target .. (IS_WINDOWS and ".dll" or ".so")
            native_paths[#native_paths + 1] = target .. ".dylib"
        end

        for _, path in ipairs(lua_paths) do
            candidates[#candidates + 1] = { type = "lua", template = path, path = path }
        end
        for _, path in ipairs(native_paths) do
            candidates[#candidates + 1] = { type = "native", template = path, path = path }
        end
        return candidates
    end

    local module_path = module_name:gsub("%.", "/")
    local function expandTemplate(tpl)
        -- Literal replacement: module_path may contain '%' which must not be
        -- treated as gsub capture references.
        return (tpl:gsub("%?", function()
            return module_path
        end))
    end
    for _, tpl in ipairs(self.lua_templates) do
        candidates[#candidates + 1] = {
            type     = "lua",
            template = tpl,
            path     = expandTemplate(tpl),
        }
    end
    local native_seen = {}
    local function addNativeCandidates(module_fragment, croot)
        for _, tpl in ipairs(self.native_templates) do
            local candidate_path = (tpl:gsub("%?", function()
                return module_fragment
            end))
            if not native_seen[candidate_path] then
                native_seen[candidate_path] = true
                candidates[#candidates + 1] = {
                    type     = "native",
                    template = tpl,
                    path     = candidate_path,
                    croot    = croot and true or nil,
                }
            end
        end
    end
    addNativeCandidates(module_path, false)
    local root_name = module_name:match("^([^%.]+)%.")
    if root_name then
        addNativeCandidates(root_name, true)
    end
    return candidates
end

--@description: Inspect a module resolution attempt without throwing
--@param self: ModuleResolver - Resolver instance
--@param module_name: string - Module name passed to require
--@param from_script: string - Absolute path of the requiring script
--@return: table - Structured resolution inspection
function ModuleResolver:inspect(module_name, from_script)
    local candidates = self:buildCandidates(module_name, from_script)

    if self:isBuiltin(module_name) then
        return {
            ok             = true,
            type           = "builtin",
            classification = "builtin",
            reason         = "builtin",
            candidates     = candidates,
        }
    end

    for _, candidate in ipairs(candidates) do
        if fileExists(candidate.path) then
            return {
                ok             = true,
                type           = candidate.type,
                path           = resolvePath(candidate.path),
                classification = candidate.type,
                reason         = "resolved",
                candidates     = candidates,
            }
        end
    end

    return {
        ok             = false,
        type           = "missing",
        classification = "missing",
        reason         = "missing",
        candidates     = candidates,
        error          = errors.moduleNotFound(module_name, from_script, self:getSearchedPaths()),
    }
end

--@description: Resolve a module name to an absolute file path
--@param self: ModuleResolver - Resolver instance
--@param module_name: string - Dot-separated or relative module name
--@param from_script: string - Absolute path of the requiring script
--@return: table|nil - Resolution result {type="lua"|"native"|"builtin", path=string|nil}, nil for builtins
--@raise: ModuleNotFoundError when the module cannot be located
function ModuleResolver:resolve(module_name, from_script)
    local inspected = self:inspect(module_name, from_script)
    if inspected.ok then
        if inspected.type == "builtin" then
            return nil
        end
        return { type = inspected.type, path = inspected.path }
    end
    error(inspected.error)
end

-- ============================================================
-- DependencyAnalyzer
-- ============================================================

--[[
Recursively analyzes Lua script dependencies and produces a
topologically sorted manifest of script files plus a list of
detected native libraries. Performs cycle detection and enforces
a configurable dependency count limit.

Class:
    DependencyAnalyzer
Fields:
    entry_script: string - Absolute path to the entry script
    max_dependencies: number - Maximum allowed dependency count
    resolver: ModuleResolver - Module resolver instance
    visited: table - Set of visited absolute paths (path -> true)
    stack: table - Current recursion stack for cycle detection
    dep_graph: table - Adjacency list (path -> list of child paths)
    dep_count: number - Running count of discovered script dependencies
    native_libs: table - List of discovered native library paths
    native_set: table - Set for deduplication of native paths
]]
local DependencyAnalyzer = {}
DependencyAnalyzer.__index = DependencyAnalyzer


--@description: Construct a new DependencyAnalyzer for the given entry script
--@param entry_script: string - Path to the entry Lua script
--@param max_dependencies: number|nil - Upper bound on script dependencies (default 36)
--@return: DependencyAnalyzer - New analyzer instance
--@raise: ScriptNotFoundError when the entry script does not exist
--@usage: local da = DependencyAnalyzer.new("main.lua", 100)
function DependencyAnalyzer.new(entry_script, max_dependencies)
    local resolved = resolvePath(entry_script)
    if not fileExists(resolved) then
        error(errors.scriptNotFound(entry_script))
    end

    local self            = setmetatable({}, DependencyAnalyzer)
    self.entry_script     = resolved
    self.max_dependencies = max_dependencies or DEFAULT_MAX_DEPS
    self.resolver         = ModuleResolver.new(pathParent(resolved))
    self.visited          = {}
    self.stack            = {}
    self.dep_graph        = {}
    self.dep_count        = 0
    self.native_libs      = {}
    self.native_set       = {}
    self.source_hashes    = {}
    self.trace            = {}
    return self
end

--@description: Perform complete dependency analysis and return the results
--@param self: DependencyAnalyzer - Analyzer instance
--@return: table - Result table {scripts=list, libraries=list}
--@raise: DependencyLimitExceededError when count exceeds max_dependencies
function DependencyAnalyzer:analyze()
    self:analyzeRecursive(self.entry_script)

    -- Defensive final check; analyzeRecursive already enforces max_dependencies
    -- incrementally. Kept as an assertion for incomplete internal states.
    local total = 0
    for _ in pairs(self.visited) do
        total = total + 1
    end
    total = total - 1

    if total > self.max_dependencies then
        error(errors.dependencyLimitExceeded(total, self.max_dependencies))
    end

    return {
        scripts   = self:generateManifest(),
        libraries = self.native_libs,
        source_hashes = self.source_hashes,
    }
end

--@description: Record a structured trace item for one require resolution
--@param self: DependencyAnalyzer - Analyzer instance
--@param script_path: string - Absolute requiring script path
--@param req: table - Require record from the lexer
--@param inspected: table - Resolution inspection result
--@return: table - Trace item appended to self.trace
function DependencyAnalyzer:recordTrace(script_path, req, inspected)
    local item = {
        requiring_file = script_path,
        source_line    = req.line,
        requested      = req.name,
        optional       = req.optional == true,
        candidates     = inspected.candidates or {},
        selected_path  = inspected.path,
        selected_type  = inspected.type,
        classification = inspected.classification,
        reason         = inspected.reason,
    }
    self.trace[#self.trace + 1] = item
    return item
end

--@description: Recursively analyze a single script and all its dependencies
--@param self: DependencyAnalyzer - Analyzer instance
--@param script_path: string - Absolute path to the script
--@raise: CircularDependencyError, DependencyLimitExceededError, ScriptNotFoundError
function DependencyAnalyzer:analyzeRecursive(script_path)
    for i = 1, #self.stack do
        if self.stack[i] == script_path then
            local chain = {}
            for j = i, #self.stack do
                chain[#chain + 1] = self.stack[j]
            end
            chain[#chain + 1] = script_path
            error(errors.circularDependency(chain))
        end
    end

    if self.visited[script_path] then
        return
    end

    if script_path ~= self.entry_script then
        local prospective = self.dep_count + 1
        if prospective > self.max_dependencies then
            error(errors.dependencyLimitExceeded(prospective, self.max_dependencies))
        end
        self.dep_count = prospective
    end

    if not fileExists(script_path) then
        error(errors.scriptNotFound(script_path))
    end

    local source_bytes = readFileContent(script_path)
    self.source_hashes[normalizePath(script_path)] = hash.sha256(source_bytes)
    local source_code = validateSource(source_bytes, script_path)
    local lexer = LuaLexer.new(source_code, script_path)
    local requires = lexer:extractRequires()

    self.stack[#self.stack + 1] = script_path

    local children = {}
    local child_seen = {}

    for _, req in ipairs(requires) do
        local inspected = self.resolver:inspect(req.name, script_path)
        local trace_item = self:recordTrace(script_path, req, inspected)

        if inspected.ok then
            if inspected.type == "builtin" then
                goto continue_req
            end
            if inspected.type == "native" then
                if not self.native_set[inspected.path] then
                    self.native_set[inspected.path] = true
                    self.native_libs[#self.native_libs + 1] = inspected.path
                end
            elseif inspected.type == "lua" then
                if not child_seen[inspected.path] then
                    child_seen[inspected.path] = true
                    children[#children + 1] = inspected.path
                    self:analyzeRecursive(inspected.path)
                end
            end
        elseif req.optional then
            trace_item.reason = "optional-missing"
        else
            error(inspected.error)
        end
        ::continue_req::
    end

    self.dep_graph[script_path] = children
    table.remove(self.stack)
    self.visited[script_path] = true
end

--@description: Generate a topologically sorted dependency manifest excluding the entry script
--@param self: DependencyAnalyzer - Analyzer instance
--@return: table - Ordered list of absolute script paths
function DependencyAnalyzer:generateManifest()
    local sorted = {}
    local visited = {}

    --@description: Depth-first topological visit
    --@local: true
    local function visit(node)
        if visited[node] then return end
        visited[node] = true
        local deps = self.dep_graph[node]
        if deps then
            for i = 1, #deps do
                visit(deps[i])
            end
        end
        sorted[#sorted + 1] = node
    end

    visit(self.entry_script)

    local manifest = {}
    for i = 1, #sorted do
        if sorted[i] ~= self.entry_script then
            manifest[#manifest + 1] = sorted[i]
        end
    end
    return manifest
end

-- ============================================================
-- Public Module Interface
-- ============================================================

--[[
Public API for the dependency analysis subsystem.

Author:
    WaterRun
Module:
    analyzer
]]
local M              = {}

M.LuaLexer           = LuaLexer
M.ModuleResolver     = ModuleResolver
M.DependencyAnalyzer = DependencyAnalyzer
M.errors             = errors
M.prepareSource      = prepareSource
M.validateSource     = validateSource


--@description: Analyze Lua script dependencies starting from an entry script
--@param entry_script: string - Path to the entry Lua script
--@param opts: table|nil - Options: max_dependencies (number|nil, default 36)
--@return: table - Result table {scripts=list<string>, libraries=list<string>}
--@raise: ScriptNotFoundError, CircularDependencyError, DynamicRequireError, DependencyLimitExceededError, ModuleNotFoundError
--@usage: local result = analyzer.analyzeDependencies("main.lua", {max_dependencies = 100})
function M.analyzeDependencies(entry_script, opts)
    opts = opts or {}

    local da = DependencyAnalyzer.new(entry_script, opts.max_dependencies)
    return da:analyze()
end

--@description: Analyze dependencies and return trace records for each require decision
--@param entry_script: string - Path to the entry Lua script
--@param opts: table|nil - Options: max_dependencies (number|nil)
--@return: table - Result table {scripts=list<string>, libraries=list<string>, trace=list<table>}
function M.traceDependencies(entry_script, opts)
    opts = opts or {}

    local da = DependencyAnalyzer.new(entry_script, opts.max_dependencies)
    local result = da:analyze()
    result.trace = da.trace
    return result
end

--@description: Print a formatted dependency list for a Lua script to stdout
--@param entry_script: string - Path to the entry Lua script
--@param opts: table|nil - Options forwarded to analyzeDependencies
function M.printDependencyList(entry_script, opts)
    local result = M.analyzeDependencies(entry_script, opts)

    io.write(string.format("Dependencies for %s:\n", pathBasename(entry_script)))

    if #result.scripts == 0 and #result.libraries == 0 then
        io.write("  (no dependencies)\n")
        return
    end

    if #result.scripts > 0 then
        io.write("  Scripts:\n")
        for i, dep in ipairs(result.scripts) do
            io.write(string.format("    %d. %s\n", i, pathBasename(dep)))
        end
    end

    if #result.libraries > 0 then
        io.write("  Libraries:\n")
        for i, lib in ipairs(result.libraries) do
            io.write(string.format("    %d. %s\n", i, pathBasename(lib)))
        end
    end

    io.write(string.format(
        "\nTotal: %d script(s), %d library(ies)\n",
        #result.scripts, #result.libraries
    ))
end

return M
