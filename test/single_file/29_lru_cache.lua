local capacity = 3
local cache = {}
local order = {}

local function touch(key)
    for i = #order, 1, -1 do
        if order[i] == key then
            table.remove(order, i)
            break
        end
    end
    order[#order + 1] = key
end

local function put(key, value)
    if cache[key] == nil and #order >= capacity then
        local oldest = table.remove(order, 1)
        cache[oldest] = nil
    end
    cache[key] = value
    touch(key)
end

local function get(key)
    if cache[key] ~= nil then
        touch(key)
    end
    return cache[key]
end

put("A", 1)
put("B", 2)
put("C", 3)
get("A")
put("D", 4)

print(table.concat(order, " < "))
