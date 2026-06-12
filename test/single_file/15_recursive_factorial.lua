local n = tonumber(arg[1]) or 6

local function factorial(value)
    if value <= 1 then
        return 1
    end
    return value * factorial(value - 1)
end

print(string.format("%d! = %d", n, factorial(n)))
