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
    2026-08-16
]]

local fs = require("luainstaller.fs")
local hash = require("luainstaller.hash")
local path = require("luainstaller.path")
local compat = require("luainstaller.compat")
local lua_abi = require("luainstaller.lua_abi")

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
    local loader, syntax_err = compat.loadText(prepared, "@" .. tostring(script_path), {})
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
    -- require-binding tracking: a shadowed require call is not a module load.
    self.require_shadowed = false
    self.shadow_stack = {}
    self.local_pending = false
    self.local_expect_name = false
    self.local_names = 0
    self.local_has_require = false
    self.pending_function_params = false
    self.in_params = false
    self.param_paren = 0
    self.suppress_then_depths = {}
    self.require_declaration_token = false
    self.pending_require_assignment = false
    self.local_outer_shadowed = false
    self.local_attribute = false
    self.for_trackers = {}
    self.expression_trackers = {}
    self.table_constructor_scopes = {}
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
    if ch == "\r" or ch == "\n" then
        self.pos = self.pos + 1
        if self:currentChar() == "\n" and ch == "\r" then
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

local EXPRESSION_OPERATOR_KEYWORDS = {
    ["and"] = true,
    ["or"] = true,
    ["not"] = true,
}

local EXPRESSION_VALUE_KEYWORDS = {
    ["false"] = true,
    ["nil"] = true,
    ["true"] = true,
}

local STATEMENT_KEYWORDS = {
    ["break"] = true,
    ["do"] = true,
    ["else"] = true,
    ["elseif"] = true,
    ["end"] = true,
    ["for"] = true,
    ["goto"] = true,
    ["if"] = true,
    ["in"] = true,
    ["local"] = true,
    ["repeat"] = true,
    ["return"] = true,
    ["then"] = true,
    ["until"] = true,
    ["while"] = true,
}

local LUA_KEYWORDS = {
    ["and"] = true,
    ["break"] = true,
    ["do"] = true,
    ["else"] = true,
    ["elseif"] = true,
    ["end"] = true,
    ["false"] = true,
    ["for"] = true,
    ["function"] = true,
    ["goto"] = true,
    ["if"] = true,
    ["in"] = true,
    ["local"] = true,
    ["nil"] = true,
    ["not"] = true,
    ["or"] = true,
    ["repeat"] = true,
    ["return"] = true,
    ["then"] = true,
    ["true"] = true,
    ["until"] = true,
    ["while"] = true,
}

-- `goto` became reserved in Lua 5.2.  On 5.1 it remains a legal local,
-- parameter, and loop-variable name, so declaration tracking must treat it
-- like any other identifier there.
if _VERSION == "Lua 5.1" then
    STATEMENT_KEYWORDS["goto"] = nil
    LUA_KEYWORDS["goto"] = nil
end

function LuaLexer:pushShadowScope(kind, local_declaration)
    self.shadow_stack[#self.shadow_stack + 1] = {
        shadowed = self.require_shadowed,
        kind = kind,
        local_declaration = local_declaration == true,
        post_shadowed = false,
        post_global_rebind = false,
        body_global_rebound = false,
    }
end

function LuaLexer:shadowScopeOuter(entry)
    if type(entry) == "table" then return entry.shadowed end
    return entry
end

function LuaLexer:applyShadowScopeExit(entry)
    self.require_shadowed = self:shadowScopeOuter(entry)
    if type(entry) ~= "table" then return entry end

    local global_rebound = entry.post_global_rebind
        or (entry.kind ~= "function" and entry.body_global_rebound)
    if entry.post_shadowed or global_rebound then
        self.require_shadowed = true
    end
    if global_rebound then
        local parent = self.shadow_stack[#self.shadow_stack]
        if type(parent) == "table" and parent.kind ~= "function" then
            parent.body_global_rebound = true
        end
    end
    return entry
end

function LuaLexer:popShadowScope()
    local entry = table.remove(self.shadow_stack)
    if entry == nil then return nil end
    return self:applyShadowScopeExit(entry)
end

function LuaLexer:markVisibleRequireAssignment()
    if not self.require_shadowed then
        local scope = self.shadow_stack[#self.shadow_stack]
        if type(scope) == "table" then
            scope.body_global_rebound = true
        end
    end
    self.require_shadowed = true
end

function LuaLexer:finishPendingLocalDeclaration()
    if not self.local_pending then return end
    self.local_pending = false
    self.local_expect_name = false
    self.local_attribute = false
    if self.local_has_require then
        self.require_shadowed = true
    end
end

function LuaLexer:recordLocalName(is_require)
    self.local_names = self.local_names + 1
    self.local_expect_name = false
    if is_require then
        self.local_has_require = true
        self.require_declaration_token = true
    end
end

function LuaLexer:currentForTracker()
    local tracker = self.for_trackers[#self.for_trackers]
    if tracker and tracker.scope_depth == #self.shadow_stack then
        return tracker
    end
    return nil
end

function LuaLexer:trackerAtCurrentScope(tracker)
    return tracker ~= nil and tracker.scope_depth == #self.shadow_stack
end

function LuaLexer:trackerAtBoundary(tracker)
    return self:trackerAtCurrentScope(tracker)
        and tracker.delimiter_depth == 0
end

function LuaLexer:finishExpressionTracker()
    local tracker = table.remove(self.expression_trackers)
    if not tracker then return end
    if tracker.kind == "local" then
        local passthrough = tracker.passthrough_candidate
            and tracker.plain_require_only
            and tracker.saw_plain_require
        if passthrough then
            self.require_shadowed = tracker.outer_shadowed
        else
            self.require_shadowed = true
        end
    elseif tracker.kind == "assignment" then
        local passthrough = tracker.plain_require_only
            and tracker.saw_plain_require
        if passthrough then
            self.require_shadowed = tracker.outer_shadowed
        else
            self:markVisibleRequireAssignment()
        end
    elseif tracker.kind == "until" then
        self:applyShadowScopeExit(tracker.scope_entry)
    end
end

function LuaLexer:finishTrackersBeforeValue()
    while true do
        local tracker = self.expression_trackers[#self.expression_trackers]
        if not self:trackerAtBoundary(tracker) or tracker.expect_operand then
            return
        end
        self:finishExpressionTracker()
    end
end

function LuaLexer:finishTrackersAtStatementBoundary()
    while true do
        local tracker = self.expression_trackers[#self.expression_trackers]
        if not self:trackerAtBoundary(tracker) then return end
        self:finishExpressionTracker()
    end
end

function LuaLexer:forCurrentExpressionTrackers(callback)
    local depth = #self.shadow_stack
    for _, tracker in ipairs(self.expression_trackers) do
        if tracker.scope_depth == depth then callback(tracker) end
    end
end

function LuaLexer:markExpressionOperator()
    self:forCurrentExpressionTrackers(function(tracker)
        tracker.expect_operand = true
        if tracker.kind == "local" or tracker.kind == "assignment" then
            tracker.plain_require_only = false
        end
    end)
end

function LuaLexer:markExpressionValue()
    self:forCurrentExpressionTrackers(function(tracker)
        tracker.expect_operand = false
        if tracker.kind == "local" or tracker.kind == "assignment" then
            tracker.plain_require_only = false
        end
    end)
end

function LuaLexer:markPlainRequireValue()
    self:forCurrentExpressionTrackers(function(tracker)
        tracker.expect_operand = false
        if tracker.kind == "local" or tracker.kind == "assignment" then
            if tracker.saw_plain_require then
                tracker.plain_require_only = false
            else
                tracker.saw_plain_require = true
            end
        end
    end)
end

function LuaLexer:openExpressionDelimiter()
    self:forCurrentExpressionTrackers(function(tracker)
        tracker.delimiter_depth = tracker.delimiter_depth + 1
        tracker.expect_operand = true
        if tracker.kind == "local" or tracker.kind == "assignment" then
            tracker.plain_require_only = false
        end
    end)
end

function LuaLexer:closeExpressionDelimiter()
    self:forCurrentExpressionTrackers(function(tracker)
        if tracker.delimiter_depth > 0 then
            tracker.delimiter_depth = tracker.delimiter_depth - 1
        end
        tracker.expect_operand = false
    end)
end

function LuaLexer:startLocalInitializer()
    self.expression_trackers[#self.expression_trackers + 1] = {
        kind = "local",
        scope_depth = #self.shadow_stack,
        delimiter_depth = 0,
        expect_operand = true,
        outer_shadowed = self.local_outer_shadowed,
        passthrough_candidate = self.local_names == 1,
        plain_require_only = true,
        saw_plain_require = false,
    }
end

function LuaLexer:startRequireAssignment()
    self.expression_trackers[#self.expression_trackers + 1] = {
        kind = "assignment",
        scope_depth = #self.shadow_stack,
        delimiter_depth = 0,
        expect_operand = true,
        outer_shadowed = self.require_shadowed,
        plain_require_only = true,
        saw_plain_require = false,
    }
end

function LuaLexer:startUntilCondition(scope_entry)
    self.expression_trackers[#self.expression_trackers + 1] = {
        kind = "until",
        scope_depth = #self.shadow_stack,
        delimiter_depth = 0,
        expect_operand = true,
        scope_entry = scope_entry,
    }
end

function LuaLexer:atTableFieldScope()
    local scope_depth = self.table_constructor_scopes[
        #self.table_constructor_scopes
    ]
    return scope_depth ~= nil and scope_depth == #self.shadow_stack
end

function LuaLexer:plainRequireReference()
    local saved_pos = self.pos
    local saved_line = self.line
    local saved_local_pending = self.local_pending
    local saved_require_shadowed = self.require_shadowed
    self.pos = self.pos + #"require"
    self:skipTrivia()
    local character = self:currentChar()
    local plain = character ~= "(" and character ~= "'" and character ~= '"'
        and character ~= "[" and character ~= "{" and character ~= "."
        and character ~= ":"
    self.pos = saved_pos
    self.line = saved_line
    self.local_pending = saved_local_pending
    self.require_shadowed = saved_require_shadowed
    return plain
end

function LuaLexer:consumeNumber()
    local source = self.source:sub(self.pos)
    local number = source:match("^0[xX][%da-fA-F]*%.?[%da-fA-F]+[pP][%+%-]?%d+")
        or source:match("^0[xX][%da-fA-F]+")
        or source:match("^%d+%.?%d*[eE][%+%-]?%d+")
        or source:match("^%d+%.?%d*")
        or source:match("^%.%d+[eE][%+%-]?%d+")
        or source:match("^%.%d+")
    if not number or number == "" then return false end
    self.pos = self.pos + #number
    return true
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
            local decoder, decode_err = compat.loadText(
                "return " .. raw,
                "=(luainstaller-require-literal)",
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
            local decoder, decode_err = compat.loadText(
                "return " .. raw,
                "=(luainstaller-require-long-literal)",
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

--@description: Track scope and require-binding keywords read as identifiers
--@param self: LuaLexer - Lexer instance
--@param identifier: string - Identifier text
function LuaLexer:trackKeyword(identifier, local_function)
    if self.local_attribute then
        return
    end
    if self.in_params then
        if identifier == "require" then
            self.require_shadowed = true
        end
        return
    end
    if self.pending_function_params then
        -- A require token in an unqualified function name is handled by
        -- onRequireToken.  Reaching this identifier path means it was a
        -- qualified field after `.` or `:`, which does not rebind require.
        return
    end
    if identifier == "local" then
        self.local_outer_shadowed = self.require_shadowed
        self.local_pending = true
        self.local_expect_name = true
        self.local_names = 0
        self.local_has_require = false
    elseif identifier == "function" then
        self:pushShadowScope("function", local_function)
        self.pending_function_params = true
    elseif identifier == "for" then
        self.for_trackers[#self.for_trackers + 1] = {
            scope_depth = #self.shadow_stack,
            names = true,
            has_require = false,
        }
    elseif identifier == "in" then
        local tracker = self:currentForTracker()
        if tracker then tracker.names = false end
    elseif identifier == "do" then
        local tracker = self:currentForTracker()
        if tracker then table.remove(self.for_trackers) end
        self:pushShadowScope("do")
        if tracker then
            self.require_shadowed = self.require_shadowed
                or tracker.has_require
        end
    elseif identifier == "repeat" then
        self:pushShadowScope("repeat")
    elseif identifier == "then" then
        local depth = #self.shadow_stack
        if self.suppress_then_depths[depth] then
            self.suppress_then_depths[depth] = nil
        else
            self:pushShadowScope("then")
        end
    elseif identifier == "elseif" then
        if #self.shadow_stack > 0 then
            self.require_shadowed = self:shadowScopeOuter(
                self.shadow_stack[#self.shadow_stack]
            )
        end
        self.suppress_then_depths[#self.shadow_stack] = true
    elseif identifier == "else" then
        if #self.shadow_stack > 0 then
            self.require_shadowed = self:shadowScopeOuter(
                self.shadow_stack[#self.shadow_stack]
            )
        end
    elseif identifier == "end" then
        self:popShadowScope()
    elseif identifier == "until" then
        local scope_entry = table.remove(self.shadow_stack)
        if scope_entry ~= nil then self:startUntilCondition(scope_entry) end
    end
end

--@description: Track a require token before call parsing
--@param self: LuaLexer - Lexer instance
function LuaLexer:onRequireToken()
    local for_tracker = self:currentForTracker()
    if for_tracker and for_tracker.names then
        for_tracker.has_require = true
        self.require_declaration_token = true
        return
    end
    if self.in_params then
        self.require_shadowed = true
        return
    end
    if self.pending_function_params then
        -- Only `function require(...)` replaces the global/local binding.
        -- A qualified name such as object.require or require.member defines a
        -- table field and leaves the ordinary require visible in the body.
        local saved_pos = self.pos
        local saved_line = self.line
        self.pos = self.pos + #"require"
        self:skipTrivia()
        local next_character = self:currentChar()
        self.pos = saved_pos
        self.line = saved_line
        if self.previous_token ~= "." and self.previous_token ~= ":"
            and next_character ~= "." and next_character ~= ":" then
            local was_shadowed = self.require_shadowed
            self.require_shadowed = true
            local function_scope = self.shadow_stack[#self.shadow_stack]
            if type(function_scope) == "table"
                and function_scope.kind == "function" then
                function_scope.post_shadowed = true
                if not function_scope.local_declaration
                    and not was_shadowed then
                    function_scope.post_global_rebind = true
                end
            end
        end
        return
    end
    if self.local_pending and self.local_expect_name then
        self:recordLocalName(true)
    end
end

--@description: Parse a pcall(require, 'module') statement
--@param self: LuaLexer - Lexer instance
--@return: string|nil - Module name when valid, nil otherwise
function LuaLexer:parsePcallRequire()
    local saved_pos  = self.pos
    local saved_line = self.line

    if self.require_shadowed
        or self.previous_token == "function"
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

    if self.require_declaration_token then
        self.require_declaration_token = false
        self.pos = self.pos + #"require"
        return nil
    end

    if self.require_shadowed
        or self.previous_token == "function"
        or self.previous_token == "."
        or self.previous_token == ":" then
        self.pos = self.pos + #"require"
        return nil
    end
    if self.previous_token == "local" then
        -- Declaration position (local require = ...); the local-name
        -- machinery owns the shadow state from here on.
        self.pos = self.pos + #"require"
        return nil
    end

    -- Assignment target: \`require = <value>\` rebinds the global function
    -- and suppresses every later call in the file.
    local peek_saved_pos = self.pos
    local peek_saved_line = self.line
    self.pos = self.pos + #"require"
    self:skipTrivia()
    local peek_char = self:currentChar()
    local assignment = peek_char == "=" and self:peekChar() ~= "="
        and not self:atTableFieldScope()
    self.pos = peek_saved_pos
    self.line = peek_saved_line
    if assignment then
        self.pending_require_assignment = true
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
        -- require used as a plain value (local x = require, f(require),
        -- require[1], require == x) is a reference, not a call. Lua has no
        -- bare-identifier argument form, so every computed call in valid
        -- code goes through the parentheses or table paths above.
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
            self:finishPendingLocalDeclaration()
            self:extractStringLiteral(self.line)
            self:markExpressionValue()
            self.previous_token = "string"
        elseif char == "[" and self:countBracketLevel(0) >= 0 then
            self:finishPendingLocalDeclaration()
            self:extractLongStringLiteral(self:countBracketLevel(0), self.line)
            self:markExpressionValue()
            self.previous_token = "string"
        elseif self:matchKeyword("pcall") then
            if self.local_attribute then
                self.pos = self.pos + #"pcall"
            elseif self.local_pending and self.local_expect_name then
                self:recordLocalName(false)
                self.pos = self.pos + #"pcall"
            else
                self:finishPendingLocalDeclaration()
                self:finishTrackersBeforeValue()
                local pcall_pos = self.pos
                local record = self:parsePcallRequire()
                if record then
                    result[#result + 1] = record
                elseif self.pos == pcall_pos then
                    self.pos = self.pos + #"pcall"
                end
                self:markExpressionValue()
            end
            self.previous_token = "pcall"
        elseif self:matchKeyword("require") then
            if self.local_attribute then
                self.pos = self.pos + #"require"
            elseif self.local_pending and self.local_expect_name then
                self:onRequireToken()
                self:parseRequire()
            else
                self:finishPendingLocalDeclaration()
                self:finishTrackersBeforeValue()
                local plain_reference = self:plainRequireReference()
                self:onRequireToken()
                local record = self:parseRequire()
                if record then
                    result[#result + 1] = record
                end
                if plain_reference then
                    self:markPlainRequireValue()
                else
                    self:markExpressionValue()
                end
            end
            self.previous_token = "require"
        elseif char:match("[%a_]") then
            local identifier = self.source:match("^([%a_][%w_]*)", self.pos)
            local local_function = self.local_pending
                and self.local_expect_name
                and self.local_names == 0
                and identifier == "function"
            if self.local_attribute then
                self.pos = self.pos + #identifier
            elseif self.local_pending and self.local_expect_name
                and not LUA_KEYWORDS[identifier] then
                self:recordLocalName(false)
                self.pos = self.pos + #identifier
            else
                self:finishPendingLocalDeclaration()
                if EXPRESSION_OPERATOR_KEYWORDS[identifier] then
                    self:markExpressionOperator()
                elseif EXPRESSION_VALUE_KEYWORDS[identifier] then
                    self:finishTrackersBeforeValue()
                    self:markExpressionValue()
                elseif identifier == "function" then
                    self:finishTrackersBeforeValue()
                    self:markExpressionOperator()
                elseif STATEMENT_KEYWORDS[identifier] then
                    self:finishTrackersAtStatementBoundary()
                else
                    self:finishTrackersBeforeValue()
                    self:markExpressionValue()
                end
                self.pos = self.pos + #identifier
                self:trackKeyword(identifier, local_function)
                if identifier == "end" then self:markExpressionValue() end
            end
            self.previous_token = identifier
        elseif char:match("%d")
            or (char == "." and self:peekChar():match("%d")) then
            self:finishPendingLocalDeclaration()
            self:finishTrackersBeforeValue()
            self:markExpressionValue()
            assert(self:consumeNumber())
            self.previous_token = "number"
        elseif self.source:sub(self.pos, self.pos + 2) == "..." then
            self:finishPendingLocalDeclaration()
            self:finishTrackersBeforeValue()
            self:markExpressionValue()
            self.previous_token = "..."
            self.pos = self.pos + 3
        elseif self.source:sub(self.pos, self.pos + 1) == ".." then
            self:finishPendingLocalDeclaration()
            self:markExpressionOperator()
            self.previous_token = ".."
            self.pos = self.pos + 2
        elseif char == ":" and self.previous_token == ":" then
            -- Closing colon of a goto label; labels end a statement, so a
            -- following require is a real module load, not a method call.
            self:finishTrackersAtStatementBoundary()
            self.previous_token = "::"
            self:advanceCharacter()
        elseif char == "(" then
            self:finishPendingLocalDeclaration()
            self:openExpressionDelimiter()
            if self.pending_function_params then
                self.pending_function_params = false
                self.in_params = true
                self.param_paren = 1
            elseif self.in_params then
                self.param_paren = self.param_paren + 1
            end
            self.previous_token = char
            self:advanceCharacter()
        elseif char == ")" then
            self:finishPendingLocalDeclaration()
            self:closeExpressionDelimiter()
            if self.in_params then
                self.param_paren = self.param_paren - 1
                if self.param_paren == 0 then
                    self.in_params = false
                end
            end
            self.previous_token = char
            self:advanceCharacter()
        elseif char == "=" then
            local for_tracker = self:currentForTracker()
            if for_tracker and for_tracker.names then
                for_tracker.names = false
            end
            if self.pending_require_assignment then
                self.pending_require_assignment = false
                self:startRequireAssignment()
            elseif self.local_pending then
                self.local_pending = false
                self.local_expect_name = false
                self.local_attribute = false
                if self.local_has_require then
                    self:startLocalInitializer()
                end
            else
                self:markExpressionOperator()
            end
            self.previous_token = char
            self:advanceCharacter()
        elseif char == "<" and self.local_pending and self.local_names > 0
            and not self.local_expect_name then
            self.local_attribute = true
            self.previous_token = char
            self:advanceCharacter()
        elseif char == ">" and self.local_attribute then
            self.local_attribute = false
            self.previous_token = char
            self:advanceCharacter()
        elseif char == "[" or char == "{" then
            self:finishPendingLocalDeclaration()
            self:openExpressionDelimiter()
            if char == "{" then
                self.table_constructor_scopes[
                    #self.table_constructor_scopes + 1
                ] = #self.shadow_stack
            end
            self.previous_token = char
            self:advanceCharacter()
        elseif char == "]" or char == "}" then
            self:finishPendingLocalDeclaration()
            self:closeExpressionDelimiter()
            if char == "}" then
                table.remove(self.table_constructor_scopes)
            end
            self.previous_token = char
            self:advanceCharacter()
        elseif char == "," then
            if self.local_pending and not self.local_attribute then
                self.local_expect_name = true
            else
                self:markExpressionOperator()
            end
            self.previous_token = char
            self:advanceCharacter()
        elseif char == ";" then
            self:finishPendingLocalDeclaration()
            self:finishTrackersAtStatementBoundary()
            self.previous_token = char
            self:advanceCharacter()
        else
            self:finishPendingLocalDeclaration()
            self:markExpressionOperator()
            self.previous_token = char
            self:advanceCharacter()
        end
    end

    self:finishPendingLocalDeclaration()
    self:finishTrackersAtStatementBoundary()

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
    local abi = lua_abi.current()
    return abi ~= nil and lua_abi.isBuiltin(abi, module_name)
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
            if inspected.type ~= "builtin" then
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
            end
        elseif req.optional then
            trace_item.reason = "optional-missing"
        else
            error(inspected.error)
        end
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
