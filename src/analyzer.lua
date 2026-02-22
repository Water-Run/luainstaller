--[[
Dependency analysis engine for Lua scripts.
Provides comprehensive static analysis including require
extraction via a state-machine lexer, module path resolution
across package.path and package.cpath, native library
detection (.a, .so, .dll, .dylib), and recursive dependency
graph construction with cycle detection and topological sort.

Author:
    WaterRun
File:
    analyzer.lua
Date:
    2026-02-22
Updated:
    2026-02-22
]]


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
    [".a"]     = true,
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
    ["bit32"]     = true,
    ["arg"]       = true,
}

--@description: Default maximum dependency count
--@const: DEFAULT_MAX_DEPS
local DEFAULT_MAX_DEPS = 36


--@description: Check whether a file exists and is readable
--@local: true
--@param path: string - File path to probe
--@return: boolean - True when the file can be opened for reading
local function fileExists(path)
    local handle = io.open(path, "r")
    if handle then
        handle:close()
        return true
    end
    return false
end


--@description: Determine whether a path is absolute
--@local: true
--@param path: string - Path to test
--@return: boolean - True when the path is absolute
local function isAbsolutePath(path)
    if IS_WINDOWS then
        return path:match("^%a:[/\\]") ~= nil
    end
    return path:sub(1, 1) == "/"
end


--@description: Obtain the current working directory from the platform shell
--@local: true
--@return: string - Working directory path
local function getCurrentDirectory()
    local cmd = IS_WINDOWS and "cd" or "pwd"
    local pipe = io.popen(cmd)
    if pipe then
        local dir = pipe:read("*l")
        pipe:close()
        if dir then
            return dir
        end
    end
    return "."
end


--@description: Normalize a path by resolving . and .. and unifying separators
--@local: true
--@param path: string - Raw path string
--@return: string - Normalized path with forward slashes
local function normalizePath(path)
    path = path:gsub("\\", "/")

    local prefix = ""
    if path:match("^//") then
        prefix = "//"
        path = path:sub(3)
    elseif path:match("^%a:/") then
        prefix = path:sub(1, 3)
        path = path:sub(4)
    elseif path:sub(1, 1) == "/" then
        prefix = "/"
        path = path:sub(2)
    end

    local parts = {}
    for segment in path:gmatch("[^/]+") do
        if segment == ".." then
            if #parts > 0 and parts[#parts] ~= ".." then
                parts[#parts] = nil
            elseif prefix == "" then
                parts[#parts + 1] = ".."
            end
        elseif segment ~= "." then
            parts[#parts + 1] = segment
        end
    end

    local result = prefix .. table.concat(parts, "/")
    if result == "" then
        return "."
    end
    return result
end


--@description: Resolve a path to an absolute normalized form
--@local: true
--@param path: string - Possibly relative path
--@return: string - Absolute normalized path
local function resolvePath(path)
    path = path:gsub("\\", "/")
    if not isAbsolutePath(path) then
        local cwd = getCurrentDirectory():gsub("\\", "/")
        path = cwd .. "/" .. path
    end
    return normalizePath(path)
end


--@description: Extract the parent directory from a path
--@local: true
--@param path: string - File or directory path
--@return: string - Parent directory path
local function pathParent(path)
    path = path:gsub("\\", "/")
    local parent = path:match("^(.+)/[^/]+$")
    return parent or "."
end


--@description: Extract the filename component from a path
--@local: true
--@param path: string - File path
--@return: string - Filename including extension
local function pathBasename(path)
    path = path:gsub("\\", "/")
    return path:match("[^/]+$") or path
end


--@description: Extract the stem (name without extension) from a path
--@local: true
--@param path: string - File path
--@return: string - Filename without extension
local function pathStem(path)
    local base = pathBasename(path)
    return base:match("^(.+)%.[^%.]+$") or base
end


--@description: Extract the file extension including the leading dot
--@local: true
--@param path: string - File path
--@return: string|nil - Extension string or nil when absent
local function pathExtension(path)
    local base = pathBasename(path)
    return base:match("(%.[^%.]+)$")
end


--@description: Read the full content of a file with encoding fallback
--@local: true
--@param path: string - Absolute file path
--@return: string - File content
--@raise: error table when the file cannot be opened
local function readFileContent(path)
    local handle = io.open(path, "rb")
    if not handle then
        error({
            type    = "ScriptNotFoundError",
            message = string.format("Cannot read file: %s", path),
        })
    end
    local content = handle:read("*a")
    handle:close()
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

-- ============================================================
-- Lexer State Enumeration
-- ============================================================

--[[
State values for the Lua source lexer state machine.

Enum:
    LexerState
Values:
    NORMAL: Default code context
    IN_STRING_SINGLE: Inside a single-quoted string literal
    IN_STRING_DOUBLE: Inside a double-quoted string literal
    IN_LONG_STRING: Inside a long bracket string literal
    IN_LINE_COMMENT: Inside a single-line comment
    IN_BLOCK_COMMENT: Inside a block comment
]]
local LexerState = {
    NORMAL           = 1,
    IN_STRING_SINGLE = 2,
    IN_STRING_DOUBLE = 3,
    IN_LONG_STRING   = 4,
    IN_LINE_COMMENT  = 5,
    IN_BLOCK_COMMENT = 6,
}


-- ============================================================
-- LuaLexer
-- ============================================================

--[[
Lightweight Lua lexer focused on extracting static require
statements. Uses a state machine to correctly skip strings
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
    state: number - Current LexerState value
    bracket_level: number - Active long bracket level
]]
local LuaLexer = {}
LuaLexer.__index = LuaLexer


--@description: Construct a new LuaLexer instance
--@param source_code: string - Lua source text to analyze
--@param file_path: string - Path of the source file
--@return: LuaLexer - New lexer instance
--@usage: local lexer = LuaLexer.new(code, "main.lua")
function LuaLexer.new(source_code, file_path)
    local self         = setmetatable({}, LuaLexer)
    self.source        = source_code
    self.source_len    = #source_code
    self.file_path     = file_path
    self.pos           = 1
    self.line          = 1
    self.state         = LexerState.NORMAL
    self.bracket_level = 0
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
        if nxt:match("[%w_]") then
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

--@description: Advance past whitespace characters while tracking line numbers
--@param self: LuaLexer - Lexer instance
function LuaLexer:skipWhitespace()
    while self.pos <= self.source_len do
        local ch = self:currentChar()
        if ch ~= " " and ch ~= "\t" and ch ~= "\n" and ch ~= "\r" then
            break
        end
        if ch == "\n" then
            self.line = self.line + 1
        end
        self.pos = self.pos + 1
    end
end

--@description: Update the lexer state machine for the current character
--@param self: LuaLexer - Lexer instance
--@param char: string - Current character
function LuaLexer:updateState(char)
    if self.state == LexerState.NORMAL then
        if char == "-" and self:peekChar() == "-" then
            if self:peekChar(2) == "[" then
                local level = self:countBracketLevel(2)
                if level >= 0 then
                    self.state = LexerState.IN_BLOCK_COMMENT
                    self.bracket_level = level
                    return
                end
            end
            self.state = LexerState.IN_LINE_COMMENT
        elseif char == "'" then
            self.state = LexerState.IN_STRING_SINGLE
        elseif char == '"' then
            self.state = LexerState.IN_STRING_DOUBLE
        elseif char == "[" then
            local level = self:countBracketLevel(0)
            if level >= 0 then
                self.state = LexerState.IN_LONG_STRING
                self.bracket_level = level
            end
        end
    elseif self.state == LexerState.IN_STRING_SINGLE then
        if char == "'" and self:isNotEscaped() then
            self.state = LexerState.NORMAL
        end
    elseif self.state == LexerState.IN_STRING_DOUBLE then
        if char == '"' and self:isNotEscaped() then
            self.state = LexerState.NORMAL
        end
    elseif self.state == LexerState.IN_LONG_STRING then
        if char == "]" and self:checkClosingBracket(self.bracket_level) then
            self.state = LexerState.NORMAL
        end
    elseif self.state == LexerState.IN_LINE_COMMENT then
        if char == "\n" then
            self.state = LexerState.NORMAL
        end
    elseif self.state == LexerState.IN_BLOCK_COMMENT then
        if char == "]" and self:checkClosingBracket(self.bracket_level) then
            self.state = LexerState.NORMAL
        end
    end
end

--@description: Extract a quoted string literal and return its content
--@param self: LuaLexer - Lexer instance
--@param start_line: number - Line where the require keyword appeared
--@return: string - Content of the string literal
--@raise: DynamicRequireError on unterminated or concatenated strings
function LuaLexer:extractStringLiteral(start_line)
    local quote = self:currentChar()
    self.pos = self.pos + 1
    local parts = {}

    while self.pos <= self.source_len do
        local ch = self:currentChar()
        if ch == quote and self:isNotEscaped() then
            self.pos = self.pos + 1
            local result = table.concat(parts)
            self:checkNoConcatenation(start_line, result)
            return result
        end
        if ch == "\\" then
            parts[#parts + 1] = ch
            self.pos = self.pos + 1
            if self.pos <= self.source_len then
                parts[#parts + 1] = self:currentChar()
            end
        else
            parts[#parts + 1] = ch
        end
        self.pos = self.pos + 1
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
    self.pos = self.pos + 2 + level
    local parts = {}

    while self.pos <= self.source_len do
        if self:currentChar() == "]" and self:checkClosingBracket(level) then
            self.pos = self.pos + 2 + level
            local result = table.concat(parts)
            self:checkNoConcatenation(start_line, result)
            return result
        end
        if self:currentChar() == "\n" then
            self.line = self.line + 1
        end
        parts[#parts + 1] = self:currentChar()
        self.pos = self.pos + 1
    end

    error(errors.dynamicRequire(
        self.file_path, start_line, "Unterminated long string in require"
    ))
end

--@description: Verify that no string concatenation operator follows the literal
--@param self: LuaLexer - Lexer instance
--@param start_line: number - Line where the require keyword appeared
--@param module_name: string - The extracted module name so far
--@raise: DynamicRequireError when concatenation is detected
function LuaLexer:checkNoConcatenation(start_line, module_name)
    local saved = self.pos
    while self.pos <= self.source_len do
        local ch = self:currentChar()
        if ch ~= " " and ch ~= "\t" and ch ~= "\r" and ch ~= "\n" then
            break
        end
        self.pos = self.pos + 1
    end
    if self.pos + 1 <= self.source_len
        and self.source:sub(self.pos, self.pos + 1) == ".." then
        error(errors.dynamicRequire(
            self.file_path, start_line,
            string.format("require('%s' .. ...) - concatenation unsupported", module_name)
        ))
    end
    self.pos = saved
end

--@description: Parse a pcall(require, 'module') statement
--@param self: LuaLexer - Lexer instance
--@return: string|nil - Module name when valid, nil otherwise
function LuaLexer:parsePcallRequire()
    local saved_pos  = self.pos
    local saved_line = self.line

    self.pos         = self.pos + #"pcall"
    self:skipWhitespace()

    if self:currentChar() ~= "(" then
        self.pos  = saved_pos
        self.line = saved_line
        return nil
    end
    self.pos = self.pos + 1
    self:skipWhitespace()

    if self.pos + #"require" - 1 > self.source_len
        or self.source:sub(self.pos, self.pos + #"require" - 1) ~= "require" then
        self.pos  = saved_pos
        self.line = saved_line
        return nil
    end
    local after_req = self.pos + #"require"
    if after_req <= self.source_len then
        local nxt = self.source:sub(after_req, after_req)
        if nxt:match("[%w_]") then
            self.pos  = saved_pos
            self.line = saved_line
            return nil
        end
    end
    self.pos = after_req
    self:skipWhitespace()

    if self:currentChar() ~= "," then
        self.pos  = saved_pos
        self.line = saved_line
        return nil
    end
    self.pos = self.pos + 1
    self:skipWhitespace()

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
        self.pos  = saved_pos
        self.line = saved_line
        return nil
    end

    self:skipWhitespace()
    if self:currentChar() == ")" then
        self.pos = self.pos + 1
    end

    return module_name
end

--@description: Parse a require statement and extract the module name
--@param self: LuaLexer - Lexer instance
--@return: string|nil - Module name, nil to skip
--@raise: DynamicRequireError when the require argument is not a string literal
function LuaLexer:parseRequire()
    local saved_pos  = self.pos
    local saved_line = self.line

    self.pos         = self.pos + #"require"
    self:skipWhitespace()

    local ch = self:currentChar()
    local has_paren = false

    if ch == "(" then
        has_paren = true
        self.pos = self.pos + 1
        self:skipWhitespace()
        ch = self:currentChar()
    end

    if ch == '"' or ch == "'" then
        local module_name = self:extractStringLiteral(saved_line)
        if has_paren then
            self:skipWhitespace()
            if self:currentChar() == ")" then
                self.pos = self.pos + 1
            end
        end
        return module_name
    end

    if ch == "[" then
        local level = self:countBracketLevel(0)
        if level >= 0 then
            local module_name = self:extractLongStringLiteral(level, saved_line)
            if has_paren then
                self:skipWhitespace()
                if self:currentChar() == ")" then
                    self.pos = self.pos + 1
                end
            end
            return module_name
        end
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
        self:updateState(char)

        if self.state == LexerState.NORMAL then
            if self:matchKeyword("pcall") then
                local ok, mod = pcall(self.parsePcallRequire, self)
                if ok and mod then
                    result[#result + 1] = { name = mod, line = self.line }
                    goto next_iter
                end
            end
            if self:matchKeyword("require") then
                local mod = self:parseRequire()
                if mod then
                    result[#result + 1] = { name = mod, line = self.line }
                end
                goto next_iter
            end
        end

        if char == "\n" then
            self.line = self.line + 1
        end
        self.pos = self.pos + 1
        ::next_iter::
    end

    return result
end

-- ============================================================
-- ModuleResolver
-- ============================================================

--[[
Resolves Lua module names to absolute file paths by searching
package.path templates for Lua scripts and package.cpath
templates plus .a variants for native libraries. Handles
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
        for tpl in package.path:gmatch("[^;]+") do
            tpl = tpl:gsub("^%s+", ""):gsub("%s+$", ""):gsub("\\", "/")
            if tpl ~= "" and tpl:find("%?") then
                addLua(tpl)
            end
        end
    end

    if package.cpath then
        for tpl in package.cpath:gmatch("[^;]+") do
            tpl = tpl:gsub("^%s+", ""):gsub("%s+$", ""):gsub("\\", "/")
            if tpl ~= "" and tpl:find("%?") then
                addNative(tpl)
            end
        end
    end

    local extra_native_templates = {}
    for _, tpl in ipairs(self.native_templates) do
        for ext_from, _ in pairs({ ["%.so"] = true, ["%.dll"] = true, ["%.dylib"] = true }) do
            local a_variant = tpl:gsub(ext_from .. "$", ".a")
            if a_variant ~= tpl then
                extra_native_templates[#extra_native_templates + 1] = a_variant
            end
        end
    end
    for _, tpl in ipairs(extra_native_templates) do
        addNative(tpl)
    end

    addNative(base .. "/?.a")
    addNative(base .. "/lib/?.a")
    if IS_WINDOWS then
        addNative(base .. "/?.dll")
        addNative(base .. "/lib/?.dll")
    else
        addNative(base .. "/?.so")
        addNative(base .. "/lib/?.so")
        addNative(base .. "/?.dylib")
    end
end

--@description: Test whether a module name refers to a Lua builtin
--@param self: ModuleResolver - Resolver instance
--@param module_name: string - Dot-separated module name
--@return: boolean - True when the root segment is a builtin name
function ModuleResolver:isBuiltin(module_name)
    local root = module_name:match("^([^%.]+)")
    return BUILTIN_MODULES[root or module_name] == true
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

--@description: Resolve a relative module path (starting with ./ or ../)
--@param self: ModuleResolver - Resolver instance
--@param module_name: string - Relative module reference
--@param from_script: string - Absolute path of the requiring script
--@return: table - Resolution result {type="lua"|"native", path=string}
--@raise: ModuleNotFoundError when the file does not exist
function ModuleResolver:resolveRelative(module_name, from_script)
    local base_dir = pathParent(from_script)
    local target = normalizePath(base_dir .. "/" .. module_name)

    local ext = pathExtension(target)
    local candidates_lua = {}
    local candidates_native = {}

    if ext == ".lua" then
        candidates_lua[#candidates_lua + 1] = target
    elseif ext and NATIVE_EXTENSIONS[ext] then
        candidates_native[#candidates_native + 1] = target
    else
        candidates_lua[#candidates_lua + 1] = target .. ".lua"
        candidates_lua[#candidates_lua + 1] = target .. "/init.lua"
        candidates_native[#candidates_native + 1] = target .. (IS_WINDOWS and ".dll" or ".so")
        candidates_native[#candidates_native + 1] = target .. ".a"
        candidates_native[#candidates_native + 1] = target .. ".dylib"
    end

    for _, path in ipairs(candidates_lua) do
        if fileExists(path) then
            return { type = "lua", path = resolvePath(path) }
        end
    end
    for _, path in ipairs(candidates_native) do
        if fileExists(path) then
            return { type = "native", path = resolvePath(path) }
        end
    end

    error(errors.moduleNotFound(module_name, from_script, { base_dir }))
end

--@description: Resolve a module name to an absolute file path
--@param self: ModuleResolver - Resolver instance
--@param module_name: string - Dot-separated or relative module name
--@param from_script: string - Absolute path of the requiring script
--@return: table|nil - Resolution result {type="lua"|"native"|"builtin", path=string|nil}, nil for builtins
--@raise: ModuleNotFoundError when the module cannot be located
function ModuleResolver:resolve(module_name, from_script)
    if self:isBuiltin(module_name) then
        return nil
    end

    if module_name:sub(1, 2) == "./" or module_name:sub(1, 3) == "../" then
        return self:resolveRelative(module_name, from_script)
    end

    local module_path = module_name:gsub("%.", "/")

    for _, tpl in ipairs(self.lua_templates) do
        local candidate = tpl:gsub("%?", module_path)
        if fileExists(candidate) then
            return { type = "lua", path = resolvePath(candidate) }
        end
    end

    for _, tpl in ipairs(self.native_templates) do
        local candidate = tpl:gsub("%?", module_path)
        if fileExists(candidate) then
            return { type = "native", path = resolvePath(candidate) }
        end
    end

    error(errors.moduleNotFound(
        module_name, from_script, self:getSearchedPaths()
    ))
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
    return self
end

--@description: Perform complete dependency analysis and return the results
--@param self: DependencyAnalyzer - Analyzer instance
--@return: table - Result table {scripts=list, libraries=list}
--@raise: DependencyLimitExceededError when count exceeds max_dependencies
function DependencyAnalyzer:analyze()
    self:analyzeRecursive(self.entry_script)

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
    }
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

    local source_code = readFileContent(script_path)
    local lexer = LuaLexer.new(source_code, script_path)
    local requires = lexer:extractRequires()

    self.stack[#self.stack + 1] = script_path

    local children = {}
    local child_seen = {}

    for _, req in ipairs(requires) do
        local ok, result = pcall(self.resolver.resolve, self.resolver, req.name, script_path)
        if ok then
            if result == nil then
                goto continue_req
            end
            if result.type == "native" then
                if not self.native_set[result.path] then
                    self.native_set[result.path] = true
                    self.native_libs[#self.native_libs + 1] = result.path
                end
            elseif result.type == "lua" then
                if not child_seen[result.path] then
                    child_seen[result.path] = true
                    children[#children + 1] = result.path
                    self:analyzeRecursive(result.path)
                end
            end
        else
            error(result)
        end
        ::continue_req::
    end

    self.dep_graph[script_path] = children
    self.stack[#self.stack] = nil
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


--@description: Analyze Lua script dependencies starting from an entry script
--@param entry_script: string - Path to the entry Lua script
--@param opts: table|nil - Options: max_dependencies (number|nil, default 36), manual_mode (boolean|nil)
--@return: table - Result table {scripts=list<string>, libraries=list<string>}
--@raise: ScriptNotFoundError, CircularDependencyError, DynamicRequireError, DependencyLimitExceededError, ModuleNotFoundError
--@usage: local result = analyzer.analyzeDependencies("main.lua", {max_dependencies = 100})
function M.analyzeDependencies(entry_script, opts)
    opts = opts or {}

    if opts.manual_mode then
        return { scripts = {}, libraries = {} }
    end

    local da = DependencyAnalyzer.new(entry_script, opts.max_dependencies)
    return da:analyze()
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
