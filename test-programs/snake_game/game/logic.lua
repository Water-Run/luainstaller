--[[
    Logic module - Core game logic
]]

local snake_module = require("game.snake")
local food_module = require("game.food")
local board_module = require("game.board")

local logic = {}

-- Opposite directions (can't reverse)
local OPPOSITES = {
    up = "down",
    down = "up",
    left = "right",
    right = "left"
}

-- Check if direction change is valid (can't reverse)
function logic.is_valid_direction(current, new)
    if not new then
        return false
    end
    return OPPOSITES[current] ~= new
end

-- Update game state for one tick
function logic.update(snake, food, board, direction)
    local result = {
        ate_food = false,
        collision = false,
        score_delta = 0
    }

    -- Move snake
    snake_module.move(snake, direction)

    local head = snake_module.get_head(snake)

    -- Check wall collision
    if not board_module.in_bounds(board, head.x, head.y) then
        result.collision = true
        return result
    end

    -- Check self collision
    if snake_module.self_collision(snake) then
        result.collision = true
        return result
    end

    -- Check food collision
    if food_module.at_position(food, head.x, head.y) then
        result.ate_food = true
        result.score_delta = 10
        snake_module.grow(snake)
    end

    return result
end

-- Check if game is over
function logic.is_game_over(snake, board)
    local head = snake_module.get_head(snake)

    -- Wall collision
    if not board_module.in_bounds(board, head.x, head.y) then
        return true, "wall"
    end

    -- Self collision
    if snake_module.self_collision(snake) then
        return true, "self"
    end

    return false, nil
end

-- Calculate score based on snake length
function logic.calculate_score(snake_length, initial_length)
    return (snake_length - initial_length) * 10
end

-- Get next head position without moving
function logic.get_next_position(snake, direction)
    local head = snake_module.get_head(snake)
    local vectors = {
        up    = { x = 0,  y = -1 },
        down  = { x = 0,  y = 1  },
        left  = { x = -1, y = 0  },
        right = { x = 1,  y = 0  }
    }
    local vec = vectors[direction]
    if vec then
        return head.x + vec.x, head.y + vec.y
    end
    return head.x, head.y
end

return logic