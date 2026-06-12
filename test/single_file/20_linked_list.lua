local head = nil

local function prepend(value)
    head = { value = value, next = head }
end

local function to_array(node)
    local values = {}
    while node do
        values[#values + 1] = node.value
        node = node.next
    end
    return values
end

prepend("third")
prepend("second")
prepend("first")

print(table.concat(to_array(head), " -> "))
