local csv = arg[1] or "alice,90\nbob,81\ncarol,96\n"
local total = 0
local count = 0

for name, score in csv:gmatch("([^,\n]+),([%d%.]+)") do
    total = total + tonumber(score)
    count = count + 1
    print(string.format("%s: %s", name, score))
end

if count > 0 then
    print(string.format("average: %.2f", total / count))
end
