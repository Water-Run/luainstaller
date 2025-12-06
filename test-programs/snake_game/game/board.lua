--[[
    Board module - Manages the game board
]]

local board = {}

-- Create a new game board
function board.create(width, height)
    local b = {
        width = width,
        height = height,
        cells = {}
    }

    -- Initialize empty cells
    for y = 1, height do
        b.cells[y] = {}
        for x = 1, width do
            b.cells[y][x] = " "
        end
    end

    return b
end

-- Check if position is within bounds
function board.in_bounds(b, x, y)
    return x >= 1 and x <= b.width and y >= 1 and y <= b.height
end

-- Get cell value
function board.get_cell(b, x, y)
    if board.in_bounds(b, x, y) then
        return b.cells[y][x]
    end
    return nil
end

-- Set cell value
function board.set_cell(b, x, y, value)
    if board.in_bounds(b, x, y) then
        b.cells[y][x] = value
        return true
    end
    return false
end

-- Clear the board
function board.clear(b)
    for y = 1, b.height do
        for x = 1, b.width do
            b.cells[y][x] = " "
        end
    end
end

-- Get board dimensions
function board.get_dimensions(b)
    return b.width, b.height
end

-- Check if a position is empty
function board.is_empty(b, x, y)
    if not board.in_bounds(b, x, y) then
        return false
    end
    return b.cells[y][x] == " "
end

return board