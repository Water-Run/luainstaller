--[[
    Food module - Manages food spawning
]]

local snake_module = require("game.snake")

local food = {}

-- Initialize random seed (只初始化一次)
local seed_initialized = false
local function ensure_random_seed()
    if not seed_initialized then
        math.randomseed(os.time() + math.floor(os.clock() * 1000))
        -- 丢弃前几个随机数以获得更好的随机性
        for _ = 1, 10 do
            math.random()
        end
        seed_initialized = true
    end
end

-- Create food at a random valid position
function food.create(game_board, game_snake)
    ensure_random_seed()

    local f = {
        x = 0,
        y = 0,
        symbol = "*"
    }

    local width = game_board.width
    local height = game_board.height
    local attempts = 0
    local max_attempts = width * height

    repeat
        f.x = math.random(1, width)
        f.y = math.random(1, height)
        attempts = attempts + 1

        -- 检查是否在蛇身上
        local on_snake = snake_module.contains(game_snake, f.x, f.y, false)

        if not on_snake then
            break
        end
    until attempts > max_attempts

    return f
end

-- Check if position matches food position
function food.at_position(f, x, y)
    return f.x == x and f.y == y
end

-- Get food position
function food.get_position(f)
    return f.x, f.y
end

return food