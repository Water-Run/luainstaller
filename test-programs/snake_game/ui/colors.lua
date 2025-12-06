--[[
    Colors module - ANSI escape code utilities
]]

local colors = {}

-- ANSI color codes
local CODES = {
    -- Reset
    reset = "\27[0m",

    -- Regular colors
    black = "\27[30m",
    red = "\27[31m",
    green = "\27[32m",
    yellow = "\27[33m",
    blue = "\27[34m",
    magenta = "\27[35m",
    cyan = "\27[36m",
    white = "\27[37m",

    -- Bright colors
    bright_black = "\27[90m",
    bright_red = "\27[91m",
    bright_green = "\27[92m",
    bright_yellow = "\27[93m",
    bright_blue = "\27[94m",
    bright_magenta = "\27[95m",
    bright_cyan = "\27[96m",
    bright_white = "\27[97m",

    -- Styles
    bold = "\27[1m",
    dim = "\27[2m",
    italic = "\27[3m",
    underline = "\27[4m",
    blink = "\27[5m",
    reverse = "\27[7m",

    -- Background colors
    bg_black = "\27[40m",
    bg_red = "\27[41m",
    bg_green = "\27[42m",
    bg_yellow = "\27[43m",
    bg_blue = "\27[44m",
    bg_magenta = "\27[45m",
    bg_cyan = "\27[46m",
    bg_white = "\27[47m",

    -- Bright background colors
    bg_bright_black = "\27[100m",
    bg_bright_red = "\27[101m",
    bg_bright_green = "\27[102m",
    bg_bright_yellow = "\27[103m",
    bg_bright_blue = "\27[104m",
    bg_bright_magenta = "\27[105m",
    bg_bright_cyan = "\27[106m",
    bg_bright_white = "\27[107m"
}

-- Check if terminal supports colors
local function supports_colors()
    local term = os.getenv("TERM") or ""
    local colorterm = os.getenv("COLORTERM") or ""

    -- Check common indicators
    if colorterm ~= "" then
        return true
    end

    if term:match("color") or term:match("xterm") or term:match("screen") or
       term:match("256") or term:match("linux") or term:match("vt100") then
        return true
    end

    -- Check for Windows Terminal or similar
    if os.getenv("WT_SESSION") or os.getenv("ConEmuANSI") == "ON" then
        return true
    end

    -- Check for common terminal emulators
    if os.getenv("TERM_PROGRAM") then
        return true
    end

    -- Default to enabled (most modern terminals support ANSI)
    return true
end

-- Cache the color support check
local COLOR_ENABLED = supports_colors()

-- Apply color to text
function colors.apply(color_name, text)
    if not COLOR_ENABLED then
        return text
    end

    local code = CODES[color_name]
    if not code then
        return text
    end

    return code .. text .. CODES.reset
end

-- Apply multiple styles
function colors.styled(text, ...)
    if not COLOR_ENABLED then
        return text
    end

    local result = text
    local styles = {...}

    local prefix = ""
    for _, style in ipairs(styles) do
        local code = CODES[style]
        if code then
            prefix = prefix .. code
        end
    end

    if prefix ~= "" then
        result = prefix .. result .. CODES.reset
    end

    return result
end

-- Get raw color code
function colors.code(color_name)
    if not COLOR_ENABLED then
        return ""
    end
    return CODES[color_name] or ""
end

-- Reset code
function colors.reset_code()
    if not COLOR_ENABLED then
        return ""
    end
    return CODES.reset
end

-- Enable/disable colors
function colors.set_enabled(enabled)
    COLOR_ENABLED = enabled
end

-- Check if colors are enabled
function colors.is_enabled()
    return COLOR_ENABLED
end

return colors