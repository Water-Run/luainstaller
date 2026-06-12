local a = { apple = true, banana = true, cherry = true }
local b = { banana = true, date = true, apple = true }

local function sorted_keys(set)
    local keys = {}
    for key in pairs(set) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    return keys
end

local union = {}
local intersection = {}

for key in pairs(a) do
    union[key] = true
    if b[key] then
        intersection[key] = true
    end
end
for key in pairs(b) do
    union[key] = true
end

print("union: " .. table.concat(sorted_keys(union), ", "))
print("intersection: " .. table.concat(sorted_keys(intersection), ", "))
