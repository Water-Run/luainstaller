-- calculator.lua
-- 交互式四则运算计算器
-- 支持加减乘除和括号表达式解析
-- 适用于 luainstaller 打包测试

-----------------------------------------------------------
-- Tokenizer: 将表达式字符串分解为 token 列表
-----------------------------------------------------------

local TokenType = {
    NUMBER = "NUMBER",
    PLUS = "PLUS",
    MINUS = "MINUS",
    MUL = "MUL",
    DIV = "DIV",
    LPAREN = "LPAREN",
    RPAREN = "RPAREN",
    EOF = "EOF"
}

local function tokenize(expr)
    local tokens = {}
    local pos = 1
    local len = #expr
    
    while pos <= len do
        local char = expr:sub(pos, pos)
        
        -- 跳过空白字符
        if char:match("%s") then
            pos = pos + 1
        
        -- 数字（包括小数）
        elseif char:match("%d") or (char == "." and pos < len and expr:sub(pos + 1, pos + 1):match("%d")) then
            local num_start = pos
            local has_dot = false
            
            while pos <= len do
                local c = expr:sub(pos, pos)
                if c:match("%d") then
                    pos = pos + 1
                elseif c == "." and not has_dot then
                    has_dot = true
                    pos = pos + 1
                else
                    break
                end
            end
            
            local num_str = expr:sub(num_start, pos - 1)
            local num_val = tonumber(num_str)
            
            if not num_val then
                return nil, string.format("无效的数字: '%s'", num_str)
            end
            
            table.insert(tokens, {type = TokenType.NUMBER, value = num_val})
        
        -- 运算符和括号
        elseif char == "+" then
            table.insert(tokens, {type = TokenType.PLUS, value = "+"})
            pos = pos + 1
        elseif char == "-" then
            table.insert(tokens, {type = TokenType.MINUS, value = "-"})
            pos = pos + 1
        elseif char == "*" then
            table.insert(tokens, {type = TokenType.MUL, value = "*"})
            pos = pos + 1
        elseif char == "/" then
            table.insert(tokens, {type = TokenType.DIV, value = "/"})
            pos = pos + 1
        elseif char == "(" then
            table.insert(tokens, {type = TokenType.LPAREN, value = "("})
            pos = pos + 1
        elseif char == ")" then
            table.insert(tokens, {type = TokenType.RPAREN, value = ")"})
            pos = pos + 1
        else
            return nil, string.format("未知字符: '%s' (位置 %d)", char, pos)
        end
    end
    
    table.insert(tokens, {type = TokenType.EOF, value = nil})
    return tokens, nil
end

-----------------------------------------------------------
-- Parser: 递归下降解析器
-- 文法:
--   expr   -> term (('+' | '-') term)*
--   term   -> factor (('*' | '/') factor)*
--   factor -> NUMBER | '(' expr ')' | '-' factor | '+' factor
-----------------------------------------------------------

local Parser = {}
Parser.__index = Parser

function Parser.new(tokens)
    local self = setmetatable({}, Parser)
    self.tokens = tokens
    self.pos = 1
    return self
end

function Parser:current()
    return self.tokens[self.pos]
end

function Parser:advance()
    self.pos = self.pos + 1
end

function Parser:expect(token_type)
    local tok = self:current()
    if tok.type ~= token_type then
        return nil, string.format("期望 %s, 但得到 %s", token_type, tok.type)
    end
    self:advance()
    return tok, nil
end

-- factor -> NUMBER | '(' expr ')' | '-' factor | '+' factor
function Parser:parse_factor()
    local tok = self:current()
    
    -- 一元正号
    if tok.type == TokenType.PLUS then
        self:advance()
        return self:parse_factor()
    end
    
    -- 一元负号
    if tok.type == TokenType.MINUS then
        self:advance()
        local val, err = self:parse_factor()
        if err then return nil, err end
        return -val, nil
    end
    
    -- 数字
    if tok.type == TokenType.NUMBER then
        self:advance()
        return tok.value, nil
    end
    
    -- 括号表达式
    if tok.type == TokenType.LPAREN then
        self:advance()
        local val, err = self:parse_expr()
        if err then return nil, err end
        
        local _, err2 = self:expect(TokenType.RPAREN)
        if err2 then return nil, "缺少右括号 ')'" end
        
        return val, nil
    end
    
    return nil, string.format("意外的 token: %s", tok.type)
end

-- term -> factor (('*' | '/') factor)*
function Parser:parse_term()
    local left, err = self:parse_factor()
    if err then return nil, err end
    
    while true do
        local tok = self:current()
        
        if tok.type == TokenType.MUL then
            self:advance()
            local right, err2 = self:parse_factor()
            if err2 then return nil, err2 end
            left = left * right
            
        elseif tok.type == TokenType.DIV then
            self:advance()
            local right, err2 = self:parse_factor()
            if err2 then return nil, err2 end
            
            if right == 0 then
                return nil, "除数不能为零"
            end
            left = left / right
            
        else
            break
        end
    end
    
    return left, nil
end

-- expr -> term (('+' | '-') term)*
function Parser:parse_expr()
    local left, err = self:parse_term()
    if err then return nil, err end
    
    while true do
        local tok = self:current()
        
        if tok.type == TokenType.PLUS then
            self:advance()
            local right, err2 = self:parse_term()
            if err2 then return nil, err2 end
            left = left + right
            
        elseif tok.type == TokenType.MINUS then
            self:advance()
            local right, err2 = self:parse_term()
            if err2 then return nil, err2 end
            left = left - right
            
        else
            break
        end
    end
    
    return left, nil
end

function Parser:parse()
    local result, err = self:parse_expr()
    if err then return nil, err end
    
    local tok = self:current()
    if tok.type ~= TokenType.EOF then
        return nil, string.format("表达式末尾有多余内容: '%s'", tok.value or tok.type)
    end
    
    return result, nil
end

-----------------------------------------------------------
-- 计算函数
-----------------------------------------------------------

local function calculate(expr)
    if not expr or expr:match("^%s*$") then
        return nil, "表达式为空"
    end
    
    local tokens, tok_err = tokenize(expr)
    if tok_err then
        return nil, tok_err
    end
    
    local parser = Parser.new(tokens)
    return parser:parse()
end

-----------------------------------------------------------
-- 格式化结果
-----------------------------------------------------------

local function format_result(num)
    if num == math.floor(num) and math.abs(num) < 1e15 then
        return string.format("%.0f", num)
    else
        local formatted = string.format("%.10g", num)
        return formatted
    end
end

-----------------------------------------------------------
-- 打印帮助信息
-----------------------------------------------------------

local function print_help()
    print([[
╔══════════════════════════════════════════════════════════╗
║              交互式四则运算计算器                        ║
╠══════════════════════════════════════════════════════════╣
║  支持的运算符:                                           ║
║    +  加法        -  减法                                ║
║    *  乘法        /  除法                                ║
║    (  左括号      )  右括号                              ║
║                                                          ║
║  支持的功能:                                             ║
║    • 整数和小数运算                                      ║
║    • 负数 (如: -5, --3)                                  ║
║    • 嵌套括号表达式                                      ║
║    • 运算符优先级 (* / 优先于 + -)                       ║
║                                                          ║
║  命令:                                                   ║
║    help   显示此帮助信息                                 ║
║    quit   退出计算器                                     ║
║    exit   退出计算器                                     ║
║    clear  清屏 (如果终端支持)                            ║
║                                                          ║
║  示例:                                                   ║
║    > 2 + 3 * 4          结果: 14                         ║
║    > (2 + 3) * 4        结果: 20                         ║
║    > -5 + 10            结果: 5                          ║
║    > 100 / (2 + 3)      结果: 20                         ║
╚══════════════════════════════════════════════════════════╝
]])
end

-----------------------------------------------------------
-- 清屏函数
-----------------------------------------------------------

local function clear_screen()
    if package.config:sub(1, 1) == "\\" then
        os.execute("cls")
    else
        os.execute("clear")
    end
end

-----------------------------------------------------------
-- 主循环
-----------------------------------------------------------

local function main()
    print("╔══════════════════════════════════════════════════════════╗")
    print("║         欢迎使用交互式四则运算计算器 v1.0                ║")
    print("║              输入 'help' 获取帮助                        ║")
    print("╚══════════════════════════════════════════════════════════╝")
    print()
    
    while true do
        io.write("> ")
        io.flush()
        
        local input = io.read("*l")
        
        -- 处理 EOF (Ctrl+D 或 Ctrl+Z)
        if not input then
            print("\n再见!")
            break
        end
        
        -- 去除首尾空白
        input = input:match("^%s*(.-)%s*$")
        
        -- 空输入
        if input == "" then
            -- 继续等待输入
        
        -- 退出命令
        elseif input:lower() == "quit" or input:lower() == "exit" then
            print("再见!")
            break
        
        -- 帮助命令
        elseif input:lower() == "help" then
            print_help()
        
        -- 清屏命令
        elseif input:lower() == "clear" then
            clear_screen()
        
        -- 计算表达式
        else
            local result, err = calculate(input)
            
            if err then
                print(string.format("  错误: %s", err))
            else
                print(string.format("  = %s", format_result(result)))
            end
        end
        
        print()
    end
end

-----------------------------------------------------------
-- 启动程序
-----------------------------------------------------------

main()