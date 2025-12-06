--[[
    Renderer module - ANSI terminal rendering
]]

local colors = require("ui.colors")
local snake_module = require("game.snake")

local renderer = {}

-- Border characters (可以使用 Unicode box drawing characters)
local BORDER = {
    top_left = "+",
    top_right = "+",
    bottom_left = "+",
    bottom_right = "+",
    horizontal = "-",
    vertical = "|"
}

-- 尝试使用 Unicode 边框 (如果终端支持)
local function use_unicode_border()
    local lang = os.getenv("LANG") or ""
    if lang:match("UTF%-8") or lang:match("utf%-8") or lang:match("UTF8") then
        return true
    end
    return false
end

if use_unicode_border() then
    BORDER = {
        top_left = "┌",
        top_right = "┐",
        bottom_left = "└",
        bottom_right = "┘",
        horizontal = "─",
        vertical = "│"
    }
end

-- Draw the game title
function renderer.draw_title()
    local title = [[
   ____              _           ____
  / ___| _ __   __ _| | _____   / ___| __ _ _ __ ___   ___
  \___ \| '_ \ / _` | |/ / _ \ | |  _ / _` | '_ ` _ \ / _ \
   ___) | | | | (_| |   <  __/ | |_| | (_| | | | | | |  __/
  |____/|_| |_|\__,_|_|\_\___|  \____|\__,_|_| |_| |_|\___|
]]
    print(colors.apply("bright_green", title))
end

-- Draw the game board with snake and food
function renderer.draw_game(board, snake, food, score, high_score)
    local width = board.width
    local height = board.height

    -- Score line
    local score_str = string.format(" Score: %d ", score)
    local high_score_str = string.format(" High Score: %d ", high_score)

    io.write(colors.apply("bright_cyan", score_str))
    io.write(colors.apply("yellow", "|"))
    io.write(colors.apply("bright_yellow", high_score_str))
    print()
    print()

    -- Top border
    local top_border = BORDER.top_left .. string.rep(BORDER.horizontal, width) .. BORDER.top_right
    print(colors.apply("white", top_border))

    -- Create position lookup for snake body
    local snake_positions = {}
    local body = snake.body
    for i, segment in ipairs(body) do
        local key = segment.x .. "," .. segment.y
        snake_positions[key] = i
    end

    -- Game area
    for y = 1, height do
        local row_parts = {}
        table.insert(row_parts, colors.apply("white", BORDER.vertical))

        for x = 1, width do
            local key = x .. "," .. y
            local char = " "
            local colored_char

            if snake_positions[key] then
                local idx = snake_positions[key]
                if idx == 1 then
                    -- Head - 使用特殊字符
                    char = "@"
                    colored_char = colors.styled(char, "bright_green", "bold")
                else
                    -- Body
                    char = "o"
                    colored_char = colors.apply("green", char)
                end
            elseif food.x == x and food.y == y then
                char = "*"
                colored_char = colors.styled(char, "bright_red", "bold")
            else
                colored_char = char
            end

            table.insert(row_parts, colored_char)
        end

        table.insert(row_parts, colors.apply("white", BORDER.vertical))
        print(table.concat(row_parts))
    end

    -- Bottom border
    local bottom_border = BORDER.bottom_left .. string.rep(BORDER.horizontal, width) .. BORDER.bottom_right
    print(colors.apply("white", bottom_border))

    -- Controls hint
    print(colors.apply("dim", " W/A/S/D: Move | Q: Quit"))
end

-- Draw game over screen
function renderer.draw_game_over(score, high_score)
    local game_over_art = [[
   ____                         ___
  / ___| __ _ _ __ ___   ___   / _ \__   _____ _ __
 | |  _ / _` | '_ ` _ \ / _ \ | | | \ \ / / _ \ '__|
 | |_| | (_| | | | | | |  __/ | |_| |\ V /  __/ |
  \____|\__,_|_| |_| |_|\___|  \___/  \_/ \___|_|
]]
    print(colors.apply("bright_red", game_over_art))

    print()
    print(colors.styled(string.format("  Final Score: %d", score), "bright_yellow", "bold"))

    if score > high_score then
        print(colors.styled("  ★★★ NEW HIGH SCORE! ★★★", "bright_green", "bold", "blink"))
    elseif high_score > 0 then
        print(colors.apply("cyan", string.format("  High Score: %d", high_score)))
    end
    print()
end

-- Draw a simple progress bar
function renderer.draw_progress(current, max, width)
    width = width or 20
    local filled = math.floor((current / max) * width)
    local empty = width - filled

    local bar = "[" .. string.rep("=", filled) .. string.rep(" ", empty) .. "]"
    return colors.apply("cyan", bar)
end

-- Draw a simple frame (for debugging)
function renderer.draw_debug(board, snake, food)
    print(colors.apply("yellow", "=== Debug Frame ==="))
    print(string.format("Board: %dx%d", board.width, board.height))
    print(string.format("Snake length: %d", #snake.body))
    print(string.format("Snake head: (%d, %d)", snake.body[1].x, snake.body[1].y))
    print(string.format("Snake direction: %s", snake.direction))
    print(string.format("Food: (%d, %d)", food.x, food.y))
    print(colors.apply("yellow", "=================="))
end

-- Draw menu
function renderer.draw_menu(options, selected)
    for i, option in ipairs(options) do
        if i == selected then
            print(colors.styled(" > " .. option, "bright_white", "bold"))
        else
            print(colors.apply("dim", "   " .. option))
        end
    end
end

return renderer