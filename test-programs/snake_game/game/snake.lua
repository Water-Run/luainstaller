--[[
    Snake module - Manages the snake entity
]]

local snake = {}

-- Direction vectors
local DIRECTION_VECTORS = {
    up    = { x = 0,  y = -1 },
    down  = { x = 0,  y = 1  },
    left  = { x = -1, y = 0  },
    right = { x = 1,  y = 0  }
}

-- Create a new snake
function snake.create(start_x, start_y, initial_length)
    local s = {
        body = {},
        direction = "right",
        growing = false
    }

    -- Initialize body segments (头在前，尾在后)
    for i = 0, initial_length - 1 do
        table.insert(s.body, {
            x = start_x - i,
            y = start_y
        })
    end

    return s
end

-- Get snake head position
function snake.get_head(s)
    return s.body[1]
end

-- Get snake tail position
function snake.get_tail(s)
    return s.body[#s.body]
end

-- Get snake length
function snake.get_length(s)
    return #s.body
end

-- Get current direction
function snake.get_direction(s)
    return s.direction
end

-- Move the snake in the given direction
function snake.move(s, direction)
    local vec = DIRECTION_VECTORS[direction]
    if not vec then
        return false
    end

    local head = s.body[1]
    local new_head = {
        x = head.x + vec.x,
        y = head.y + vec.y
    }

    -- Insert new head at the beginning
    table.insert(s.body, 1, new_head)

    -- Remove tail unless growing
    if s.growing then
        s.growing = false
    else
        table.remove(s.body)
    end

    s.direction = direction
    return true
end

-- Make the snake grow on next move
function snake.grow(s)
    s.growing = true
end

-- Check if a position is part of the snake body
function snake.contains(s, x, y, exclude_head)
    local start_idx = exclude_head and 2 or 1

    for i = start_idx, #s.body do
        if s.body[i].x == x and s.body[i].y == y then
            return true
        end
    end

    return false
end

-- Check if snake collides with itself
function snake.self_collision(s)
    local head = s.body[1]
    return snake.contains(s, head.x, head.y, true)
end

-- Get all body positions
function snake.get_positions(s)
    local positions = {}
    for i, segment in ipairs(s.body) do
        positions[i] = { x = segment.x, y = segment.y }
    end
    return positions
end

-- Get body (for external access)
function snake.get_body(s)
    return s.body
end

return snake