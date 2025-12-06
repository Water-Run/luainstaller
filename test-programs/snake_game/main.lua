--[[
    Snake Game - Terminal-based with ANSI colors
    Entry point for the game
]]

-- 设置模块路径
package.path = package.path .. ";./?.lua"

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

-- Platform detection
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
        -- Windows: 使用更精确的方法
        local start = os.clock()
        while os.clock() - start < seconds do end
    else
        os.execute("sleep " .. seconds)
    end
end

-- 设置终端为非阻塞输入模式 (Unix)
local function setup_terminal()
    if get_platform() == "unix" then
        os.execute("stty -echo -icanon min 0 time 0 2>/dev/null")
    end
end

-- 恢复终端设置 (Unix)
local function restore_terminal()
    if get_platform() == "unix" then
        os.execute("stty echo icanon 2>/dev/null")
    end
end

-- 非阻塞读取单个字符
local function read_key_nonblocking()
    local platform = get_platform()
    if platform == "windows" then
        -- Windows 下使用简化的方法
        return nil
    else
        -- Unix: 非阻塞读取
        local char = io.read(1)
        return char
    end
end

-- Direction mapping
local DIRECTIONS = {
    w = "up", W = "up",
    a = "left", A = "left",
    s = "down", S = "down",
    d = "right", D = "right",
    k = "up", K = "up",      -- vim style
    h = "left", H = "left",
    j = "down", J = "down",
    l = "right", L = "right"
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
    print("Press ENTER to start...")
    io.read("*l")

    -- 设置终端
    setup_terminal()

    while running do
        clear_screen()

        -- Read input (非阻塞)
        local key = read_key_nonblocking()
        if key then
            if key == "q" or key == "Q" then
                running = false
            elseif DIRECTIONS[key] then
                local new_dir = DIRECTIONS[key]
                if logic.is_valid_direction(current_direction, new_dir) then
                    current_direction = new_dir
                end
            end
        end

        if not running then
            break
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

    -- 恢复终端
    restore_terminal()

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
    if stats.games_played > 0 then
        print(string.format("  Average Score: %.1f", stats.total_score / stats.games_played))
    end
end

-- Auto-play demo mode (AI controlled)
local function run_demo()
    print("Snake Game Demo Mode")
    print("====================\n")

    -- Initialize
    local game_board = board.create(CONFIG.width, CONFIG.height)
    local game_snake = snake.create(
        math.floor(CONFIG.width / 2),
        math.floor(CONFIG.height / 2),
        CONFIG.initial_length
    )
    local game_food = food.create(game_board, game_snake)

    print("Board created: " .. CONFIG.width .. "x" .. CONFIG.height)
    print("Snake created with length " .. CONFIG.initial_length)
    print("Food placed at: (" .. game_food.x .. ", " .. game_food.y .. ")")

    -- Simple AI: move towards food
    local function get_ai_direction(s, f, current_dir)
        local head = snake.get_head(s)
        local dx = f.x - head.x
        local dy = f.y - head.y

        local preferred = {}

        if dx > 0 then table.insert(preferred, "right")
        elseif dx < 0 then table.insert(preferred, "left") end

        if dy > 0 then table.insert(preferred, "down")
        elseif dy < 0 then table.insert(preferred, "up") end

        -- 选择一个有效的方向
        for _, dir in ipairs(preferred) do
            if logic.is_valid_direction(current_dir, dir) then
                return dir
            end
        end

        return current_dir
    end

    local score = 0
    local current_direction = "right"
    local max_moves = 100

    print("\nSimulating " .. max_moves .. " moves with simple AI:\n")

    for i = 1, max_moves do
        current_direction = get_ai_direction(game_snake, game_food, current_direction)
        local result = logic.update(game_snake, game_food, game_board, current_direction)

        if result.ate_food then
            score = score + 10
            print(string.format("Move %d: Ate food! Score: %d, Length: %d",
                i, score, snake.get_length(game_snake)))
            game_food = food.create(game_board, game_snake)
        end

        if result.collision then
            print(string.format("Move %d: Collision! Game over.", i))
            break
        end
    end

    -- Render final frame
    print("\nFinal game state:")
    renderer.draw_game(game_board, game_snake, game_food, score, 0)

    -- Test history
    print("\nTesting history system:")
    local stats = history.load()
    print("  Current stats: " .. stats.games_played .. " games, high score: " .. stats.high_score)

    print("\nDemo completed successfully!")
end

-- Interactive test mode
local function run_test()
    print("Snake Game Test Mode")
    print("====================\n")

    -- Test board module
    print("Testing board module...")
    local game_board = board.create(10, 10)
    assert(game_board.width == 10, "Board width should be 10")
    assert(game_board.height == 10, "Board height should be 10")
    assert(board.in_bounds(game_board, 5, 5) == true, "Position (5,5) should be in bounds")
    assert(board.in_bounds(game_board, 0, 5) == false, "Position (0,5) should be out of bounds")
    assert(board.in_bounds(game_board, 11, 5) == false, "Position (11,5) should be out of bounds")
    print("  Board module: OK")

    -- Test snake module
    print("Testing snake module...")
    local game_snake = snake.create(5, 5, 3)
    assert(snake.get_length(game_snake) == 3, "Snake length should be 3")
    local head = snake.get_head(game_snake)
    assert(head.x == 5 and head.y == 5, "Snake head should be at (5,5)")
    assert(snake.contains(game_snake, 5, 5, false) == true, "Snake should contain (5,5)")
    assert(snake.contains(game_snake, 4, 5, false) == true, "Snake should contain (4,5)")
    assert(snake.contains(game_snake, 1, 1, false) == false, "Snake should not contain (1,1)")
    print("  Snake module: OK")

    -- Test movement
    print("Testing snake movement...")
    snake.move(game_snake, "right")
    head = snake.get_head(game_snake)
    assert(head.x == 6 and head.y == 5, "Snake head should be at (6,5) after moving right")
    assert(snake.get_length(game_snake) == 3, "Snake length should still be 3")
    print("  Snake movement: OK")

    -- Test growing
    print("Testing snake growing...")
    snake.grow(game_snake)
    snake.move(game_snake, "right")
    assert(snake.get_length(game_snake) == 4, "Snake length should be 4 after growing")
    print("  Snake growing: OK")

    -- Test food module
    print("Testing food module...")
    local game_food = food.create(game_board, game_snake)
    assert(game_food.x >= 1 and game_food.x <= 10, "Food x should be in bounds")
    assert(game_food.y >= 1 and game_food.y <= 10, "Food y should be in bounds")
    assert(not snake.contains(game_snake, game_food.x, game_food.y, false), "Food should not be on snake")
    print("  Food module: OK")

    -- Test logic module
    print("Testing logic module...")
    assert(logic.is_valid_direction("up", "left") == true, "up -> left should be valid")
    assert(logic.is_valid_direction("up", "down") == false, "up -> down should be invalid")
    print("  Logic module: OK")

    -- Test history module
    print("Testing history module...")
    local stats = history.load()
    assert(type(stats.high_score) == "number", "high_score should be a number")
    assert(type(stats.games_played) == "number", "games_played should be a number")
    print("  History module: OK")

    print("\nAll tests passed!")
end

-- Entry point
local function main()
    local args = arg or {}

    if args[1] == "--demo" or args[1] == "-d" then
        run_demo()
    elseif args[1] == "--test" or args[1] == "-t" then
        run_test()
    elseif args[1] == "--help" or args[1] == "-h" then
        print("Snake Game")
        print("Usage: lua main.lua [options]")
        print("  --demo, -d    Run in demo mode (AI controlled)")
        print("  --test, -t    Run unit tests")
        print("  --help, -h    Show this help")
        print("  (no args)     Run the interactive game")
    else
        run_game()
    end
end

-- 确保退出时恢复终端
local function safe_main()
    local ok, err = pcall(main)
    restore_terminal()
    if not ok then
        print("Error: " .. tostring(err))
        os.exit(1)
    end
end

safe_main()