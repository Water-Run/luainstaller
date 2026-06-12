local graph = {
    A = { "B", "C" },
    B = { "D", "E" },
    C = { "F" },
    D = {},
    E = { "F" },
    F = {},
}

local seen = {}
local order = {}

local function visit(node)
    if seen[node] then
        return
    end
    seen[node] = true
    order[#order + 1] = node
    for _, next_node in ipairs(graph[node]) do
        visit(next_node)
    end
end

visit("A")
print(table.concat(order, " -> "))
