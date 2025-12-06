--[[
    Food module - Manages food spawning
]]

local food = {}

-- Initialize random seed
math.randomseed(os.time())

-- Create food at a random valid position
function food.create(board, snake)
    local f = {
        x = 0,
        y = 0,
        symbol = "*"
    }

    local attempts = 0
    local max_attempts = board.width * board.height

    repeat
        f.x = math.random(1, board.width)
        f.y = math.random(1, board.height)
        attempts = attempts + 1
    until not snake.contains(snake, f.x, f.y, false) or attempts > max_attempts

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
