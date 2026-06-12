local items = {
    "read project README",
    "run analyzer",
    "package hello luainstaller",
}

for index, item in ipairs(items) do
    print(string.format("[%d] %s", index, item))
end
