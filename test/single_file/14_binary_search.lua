local values = { 3, 8, 13, 21, 34, 55, 89 }
local target = tonumber(arg[1]) or 34
local lo = 1
local hi = #values
local found = nil

while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if values[mid] == target then
        found = mid
        break
    elseif values[mid] < target then
        lo = mid + 1
    else
        hi = mid - 1
    end
end

if found then
    print(string.format("%d found at index %d", target, found))
else
    print(string.format("%d not found", target))
end
