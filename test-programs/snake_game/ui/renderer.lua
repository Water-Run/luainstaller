--[[
    Renderer module - ANSI terminal rendering
]]

local colors = require("ui.colors")
local snake_module = require("game.snake")

local renderer = {}

-- Border characters
local BORDER = {
    top_left = "+",
    top_right = "+",
    bottom_left = "+",
    bottom_right = "+",
    horizontal = "-",
    vertical = "|"
}

-- Draw the game title
function renderer.draw_title()
    print(colors.apply("green", [[
   ____              _           ____
  / ___| _ __   __ _| | _____   / ___| __ _ _ __ ___   ___
  \___ \| '_ \ / _` | |/ / _ \ | |  _ / _` | '_ ` _ \ / _ \
   ___) | | | | (_| |   <  __/ | |_| | (_| | | | | | |  __/
  |____/|_| |_|\__,_|_|\_\___|  \____|\__,_|_| |_| |_|\___|
]]))
end

-- Draw the game board with snake and food
function renderer.draw_game(board, snake, food, score, high_score)
    local width = board.width
    local height = board.height

    -- Score line
    local score_str = string.format(" Score: %d | High Score: %d ", score, high_score)
    print(colors.apply("cyan", score_str))
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
        local row = colors.apply("white", BORDER.vertical)

        for x = 1, width do
            local key = x .. "," .. y
            local char = " "
            local color = "white"

            if snake_positions[key] then
                local idx = snake_positions[key]
                if idx == 1 then
                    -- Head
                    char = "@"
                    color = "bright_green"
                else
                    -- Body
                    char = "o"
                    color = "green"
                end
            elseif food.x == x and food.y == y then
                char = "*"
                color = "red"
            end

            row = row .. colors.apply(color, char)
        end

        row = row .. colors.apply("white", BORDER.vertical)
        print(row)
    end

    -- Bottom border
    local bottom_border = BORDER.bottom_left .. string.rep(BORDER.horizontal, width) .. BORDER.bottom_right
    print(colors.apply("white", bottom_border))

    -- Controls hint
    print(colors.apply("dim", " W/A/S/D: Move | Q: Quit"))
end

-- Draw game over screen
function renderer.draw_game_over(score, high_score)
    print(colors.apply("red", [[
   ____                         ___
  / ___| __ _ _ __ ___   ___   / _ \__   _____ _ __
 | |  _ / _` | '_ ` _ \ / _ \ | | | \ \ / / _ \ '__|
 | |_| | (_| | | | | | |  __/ | |_| |\ V /  __/ |
  \____|\__,_|_| |_| |_|\___|  \___/  \_/ \___|_|
]]))

    print()
    print(colors.apply("yellow", string.format("  Final Score: %d", score)))

    if score > high_score then
        print(colors.apply("bright_green", "  *** NEW HIGH SCORE! ***"))
    else
        print(colors.apply("cyan", string.format("  High Score: %d", high_score)))
    end
end

-- Draw a simple frame (for debugging)
function renderer.draw_debug(board, snake, food)
    print("=== Debug Frame ===")
    print(string.format("Board: %dx%d", board.width, board.height))
    print(string.format("Snake length: %d", #snake.body))
    print(string.format("Snake head: (%d, %d)", snake.body[1].x, snake.body[1].y))
    print(string.format("Food: (%d, %d)", food.x, food.y))
    print("==================")
end

return renderer
