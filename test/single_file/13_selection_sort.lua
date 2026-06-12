local values = { 29, 10, 14, 37, 13, 4, 18 }

for i = 1, #values - 1 do
    local min_index = i
    for j = i + 1, #values do
        if values[j] < values[min_index] then
            min_index = j
        end
    end
    values[i], values[min_index] = values[min_index], values[i]
end

print(table.concat(values, ", "))
