local amount = tonumber(arg[1]) or 11
local coins = { 1, 2, 5 }
local dp = { [0] = 0 }

for i = 1, amount do
    dp[i] = math.huge
    for _, coin in ipairs(coins) do
        if i >= coin and dp[i - coin] + 1 < dp[i] then
            dp[i] = dp[i - coin] + 1
        end
    end
end

print(string.format("min coins for %d = %d", amount, dp[amount]))
