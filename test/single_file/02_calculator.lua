local a = tonumber(arg[1]) or 12
local op = arg[2] or "+"
local b = tonumber(arg[3]) or 8

local result
if op == "+" then
    result = a + b
elseif op == "-" then
    result = a - b
elseif op == "x" or op == "*" then
    result = a * b
elseif op == "/" then
    result = a / b
else
    error("unsupported operator: " .. tostring(op))
end

print(string.format("%s %s %s = %s", a, op, b, result))
