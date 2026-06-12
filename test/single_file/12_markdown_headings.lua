local markdown = table.concat(arg, "\n")
if markdown == "" then
    markdown = "# Title\ntext\n## Section\n### Detail\n"
end

for level, title in markdown:gmatch("\n?(#+)%s+([^\n]+)") do
    print(string.format("%d %s", #level, title))
end
