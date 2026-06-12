local graph = {
    lexer = { "analyzer" },
    analyzer = { "bundler" },
    runtime = { "bundler" },
    bundler = { "cli" },
    cli = {},
}

local indegree = {}
for node, edges in pairs(graph) do
    indegree[node] = indegree[node] or 0
    for _, next_node in ipairs(edges) do
        indegree[next_node] = (indegree[next_node] or 0) + 1
    end
end

local ready = {}
for node, degree in pairs(indegree) do
    if degree == 0 then
        ready[#ready + 1] = node
    end
end

local order = {}
while #ready > 0 do
    table.sort(ready)
    local node = table.remove(ready, 1)
    order[#order + 1] = node
    for _, next_node in ipairs(graph[node]) do
        indegree[next_node] = indegree[next_node] - 1
        if indegree[next_node] == 0 then
            ready[#ready + 1] = next_node
        end
    end
end

print(table.concat(order, " -> "))
