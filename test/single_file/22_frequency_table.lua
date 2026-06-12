local text = table.concat(arg, " ")
if text == "" then
    text = "lua makes lua tools pleasant"
end

local freq = {}
for word in text:lower():gmatch("%a+") do
    freq[word] = (freq[word] or 0) + 1
end

local words = {}
for word in pairs(freq) do
    words[#words + 1] = word
end
table.sort(words)

for _, word in ipairs(words) do
    print(string.format("%s=%d", word, freq[word]))
end
