--[[
    Snake Game - Terminal-based with ANSI colors
    Entry point for the game
]]

local board = require("game.board")
local snake = require("game.snake")
local food = require("game.food")
local logic = require("game.logic")
local renderer = require("ui.renderer")
local history = require("data.history")

-- Game configuration
local CONFIG = {
    width = 40,
    height = 20,
    initial_length = 3,
    tick_rate = 0.15
}

-- Platform detection and input handling
local function get_platform()
    local sep = package.config:sub(1, 1)
    return sep == "\\" and "windows" or "unix"
end

local function clear_screen()
    if get_platform() == "windows" then
        os.execute("cls")
    else
        io.write("\27[2J\27[H")
        io.flush()
    end
end

local function sleep(seconds)
    if get_platform() == "windows" then
        os.execute("ping -n " .. math.ceil(seconds + 1) .. " localhost >nul 2>&1")
    else
        os.execute("sleep " .. seconds)
    end
end

local function read_key()
    local platform = get_platform()
    if platform == "windows" then
        -- Windows: use choice command for basic input
        os.execute("choice /c wasdq /n /t 1 /d w >nul 2>&1")
        return nil -- Simplified for demo
    else
        -- Unix: try to read with timeout
        os.execute("stty -echo -icanon min 0 time 1 2>/dev/null")
        local char = io.read(1)
        os.execute("stty echo icanon 2>/dev/null")
        return char
    end
end

-- Direction mapping
local DIRECTIONS = {
    w = "up",
    a = "left",
    s = "down",
    d = "right"
}

-- Main game loop
local function run_game()
    -- Initialize game state
    local game_board = board.create(CONFIG.width, CONFIG.height)
    local game_snake = snake.create(
        math.floor(CONFIG.width / 2),
        math.floor(CONFIG.height / 2),
        CONFIG.initial_length
    )
    local game_food = food.create(game_board, game_snake)

    local score = 0
    local running = true
    local current_direction = "right"

    -- Load history
    local stats = history.load()

    clear_screen()
    renderer.draw_title()

    print("\nControls: W/A/S/D to move, Q to quit")
    print("Press any key to start...")
    io.read()

    while running do
        clear_screen()

        -- Read input (non-blocking where possible)
        local key = read_key()
        if key then
            key = string.lower(key)
            if key == "q" then
                running = false
            elseif DIRECTIONS[key] then
                local new_dir = DIRECTIONS[key]
                if logic.is_valid_direction(current_direction, new_dir) then
                    current_direction = new_dir
                end
            end
        end

        -- Update game state
        local result = logic.update(game_snake, game_food, game_board, current_direction)

        if result.ate_food then
            score = score + 10
            game_food = food.create(game_board, game_snake)
        end

        if result.collision then
            running = false
        end

        -- Render
        renderer.draw_game(game_board, game_snake, game_food, score, stats.high_score)

        -- Frame delay
        sleep(CONFIG.tick_rate)
    end

    -- Game over
    clear_screen()
    renderer.draw_game_over(score, stats.high_score)

    -- Update history
    stats = history.update(score)
    history.save(stats)

    print("\nFinal Statistics:")
    print(string.format("  Games Played: %d", stats.games_played))
    print(string.format("  High Score: %d", stats.high_score))
    print(string.format("  Total Score: %d", stats.total_score))
    print(string.format("  Average Score: %.1f", stats.total_score / stats.games_played))
end

-- Demo mode for testing without input
local function run_demo()
    print("Snake Game Demo Mode")
    print("====================\n")

    -- Initialize
    local game_board = board.create(CONFIG.width, CONFIG.height)
    local game_snake = snake.create(10, 10, CONFIG.initial_length)
    local game_food = food.create(game_board, game_snake)

    print("Board created: " .. CONFIG.width .. "x" .. CONFIG.height)
    print("Snake created at position (10, 10) with length " .. CONFIG.initial_length)
    print("Food placed at: (" .. game_food.x .. ", " .. game_food.y .. ")")

    -- Simulate a few moves
    local directions = {"right", "right", "down", "down", "left"}
    local score = 0

    print("\nSimulating moves:")
    for i, dir in ipairs(directions) do
        local result = logic.update(game_snake, game_food, game_board, dir)
        print(string.format("  Move %d: %s -> Head at (%d, %d)",
            i, dir, game_snake.body[1].x, game_snake.body[1].y))

        if result.ate_food then
            score = score + 10
            print("    * Ate food! Score: " .. score)
            game_food = food.create(game_board, game_snake)
        end

        if result.collision then
            print("    * Collision detected!")
            break
        end
    end

    -- Test history
    print("\nTesting history system:")
    local stats = history.load()
    print("  Current stats: " .. stats.games_played .. " games, high score: " .. stats.high_score)

    stats = history.update(score)
    print("  After update: " .. stats.games_played .. " games, high score: " .. stats.high_score)

    -- Render a frame
    print("\nGame board preview:")
    renderer.draw_game(game_board, game_snake, game_food, score, stats.high_score)

    print("\nDemo completed successfully!")
end

-- Entry point
local function main()
    local args = arg or {}

    if args[1] == "--demo" or args[1] == "-d" then
        run_demo()
    elseif args[1] == "--help" or args[1] == "-h" then
        print("Snake Game")
        print("Usage: snake_game [options]")
        print("  --demo, -d    Run in demo mode (no input required)")
        print("  --help, -h    Show this help")
        print("  (no args)     Run the interactive game")
    else
        run_game()
    end
end

main()
