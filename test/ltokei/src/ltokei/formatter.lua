--[[
Plain text table formatter for ltokei reports.

Author:
    WaterRun
File:
    formatter.lua
Date:
    2026-06-14
Updated:
    2026-06-14
]]
local M = {}

local headers = { "Language", "Files", "Lines", "Blank", "Comment", "Code" }

local function cell(value)
    return tostring(value or "")
end

local function sorted_languages(report)
    local names = {}
    for name in pairs(report.languages or {}) do
        names[#names + 1] = name
    end
    table.sort(names)
    return names
end

local function make_row(name, counts)
    return {
        name,
        counts.files,
        counts.lines,
        counts.blanks,
        counts.comments,
        counts.code,
    }
end

function M.render(report)
    local rows = {}
    for _, language in ipairs(sorted_languages(report)) do
        rows[#rows + 1] = make_row(language, report.languages[language])
    end
    rows[#rows + 1] = make_row("Total", report.total)

    local widths = {}
    for i, value in ipairs(headers) do
        widths[i] = #cell(value)
    end
    for _, row in ipairs(rows) do
        for i, value in ipairs(row) do
            local len = #cell(value)
            if len > widths[i] then
                widths[i] = len
            end
        end
    end

    local out = {}
    local function line(row)
        local parts = {}
        for i, value in ipairs(row) do
            local text = cell(value)
            parts[#parts + 1] = text .. string.rep(" ", widths[i] - #text)
        end
        return table.concat(parts, "  ")
    end

    out[#out + 1] = line(headers)
    out[#out + 1] = line({
        string.rep("-", widths[1]),
        string.rep("-", widths[2]),
        string.rep("-", widths[3]),
        string.rep("-", widths[4]),
        string.rep("-", widths[5]),
        string.rep("-", widths[6]),
    })
    for _, row in ipairs(rows) do
        out[#out + 1] = line(row)
    end

    return table.concat(out, "\n")
end

return M
