# luainstaller

`luainstaller` 是一个将 Lua 项目打包为 **可分发可执行程序** 的工具，支持 **Windows** 与 **Linux**，开源于 [GitHub](https://github.com/Water-Run/luainstaller)，遵循 **LGPL** 协议。
`luainstaller`具备依赖分析和单文件打包能力，可以打包封装程序中的非纯Lua的内容。  

> `luainstaller` 曾经以 Python 库的形式提供，旧版本仅能打包纯Lua脚本。  

## 安装

使用 `luarocks` 安装：

```bash
luarocks install luainstaller
```

## 使用

`luainstaller` 既可作为 CLI 使用，也可在 Lua 脚本中调用。

### 作为命令行工具使用

CLI 命令名称：`luainstaller`

* 获取帮助

```bash
luainstaller --help
```

```plaintext
luainstaller v0.1.0

Usage:
  luainstaller bundle <entry.lua> [options]
  luainstaller analyze <entry.lua> [options]
  luainstaller version

Options:
  ...
```

> 在 Linux 上也可以用 `man luainstaller` 查看帮助（若已安装 manpage）。

#### 打包（bundle）

最常用的命令是 `bundle`。

* 默认：输出为一个目录  

```bash
luainstaller bundle <path_to_lua_entry_file>
```

```plaintext
success.
<entry.lua> => <output_dir>/
```

默认情况下，`luainstaller` 会从入口 `.lua` 开始进行 **静态依赖分析**，并将运行所需文件输出到一个目录中。  

* 单文件模式：仅在 `--onefile` 时输出为一个文件

```bash
luainstaller bundle <path_to_lua_entry_file> --onefile
```

```plaintext
success.
<entry.lua> => <output_file>
```

`--onefile` 会在目录打包产物基础上进行进一步封装，使最终产物为 **单一可执行文件**。

#### 可选参数

| 参数               | 说明                                                                          | 示例                                                                                                           |
|--------------------|-------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------|
| `-o, --out <path>` | 输出路径：默认模式为目录；`--onefile` 时为文件                                | `luainstaller bundle main.lua --out ../dist/` / `luainstaller bundle main.lua --onefile --out ../dist/app.exe` |
| `--onefile`        | 生成单文件可执行程序（默认不启用，默认输出目录）                              | `luainstaller bundle main.lua --onefile`                                                                       |
| `-v, --verbose`    | 输出更详细的分析与打包日志                                                    | `luainstaller bundle main.lua --verbose`                                                                       |
| `--max-deps <n>`   | 依赖数量上限（默认 36）                                                       | `luainstaller bundle main.lua --max-deps 100`                                                                  |
| `--include <path>` | 手动追加依赖（可重复指定；用于动态 `require` 等静态分析无法识别的情况）       | `luainstaller bundle main.lua --include ./require.lua --include ./plugin.lua`                                  |
| `--exclude <path>` | 手动排除依赖（可重复指定；用于排除误判依赖，如 `pcall(require, ...)` 等场景） | `luainstaller bundle main.lua --exclude ./test_utils.lua`                                                      |
| `--no-depscan`     | 禁用依赖分析（进入“完全手动模式”，需自行用 `--include` 指定所有依赖）         | `luainstaller bundle main.lua --no-depscan --include ./a.lua --include ./b.lua`                                |

#### 仅分析依赖（analyze）

只做依赖分析，不进行打包：

```bash
luainstaller analyze <path_to_lua_entry_file>
```

```plaintext
success.
N dependencies found:
  1) ...
  2) ...
```

---

### 在 Lua 脚本中调用

Lua API 与 CLI 的参数语义保持一致，默认启用依赖分析，使用 `depscan = false` 关闭。

```lua
local luainstaller = require("luainstaller")

-- 最简单的打包：默认输出为目录（自动依赖分析）
local ok, out = luainstaller.bundle({
  entry = "main.lua",
})
-- ok=true  -> out 为输出目录路径
-- ok=false -> out 为错误信息

-- 指定输出目录
local ok, out = luainstaller.bundle({
  entry = "main.lua",
  out   = "../dist/",     -- 目录模式：out 是目录
})

-- 单文件模式：仅在 onefile=true 时输出为单文件
local ok, out = luainstaller.bundle({
  entry   = "main.lua",
  onefile = true,
  out     = "../dist/app.exe",  -- 单文件模式：out 是文件
})

-- 输出详细日志
local ok, out = luainstaller.bundle({
  entry   = "main.lua",
  verbose = true,
})

-- 手动追加依赖（动态 require 等无法自动识别的情况）
local ok, out = luainstaller.bundle({
  entry    = "main.lua",
  include  = {
    "./lib/plugin.lua",
    "./lib/config.lua",
  },
})

-- 手动排除依赖（用于排除误判依赖）
local ok, out = luainstaller.bundle({
  entry    = "main.lua",
  exclude  = {
    "./test/test_utils.lua",
  },
})

-- 增加依赖数量限制
local ok, out = luainstaller.bundle({
  entry     = "main.lua",
  max_deps  = 100,     -- 默认 36
})

-- 完全手动模式：关闭依赖分析（此时必须 include 指定所有依赖）
local ok, out = luainstaller.bundle({
  entry    = "main.lua",
  depscan  = false,    -- 等价于 CLI 的 --no-depscan
  include  = {
    "./module1.lua",
    "./module2.lua",
  },
})

-- 使用所有参数的完整示例
local ok, out = luainstaller.bundle({
  entry     = "src/main.lua",        -- 入口脚本
  out       = "build/",              -- 目录模式输出目录；onefile=true 时则为输出文件
  onefile   = false,                 -- 默认 false（默认输出目录）
  verbose   = true,                  -- 输出详细信息
  max_deps  = 50,                    -- 最大依赖数
  include   = { "plugins/extra.lua" },
  exclude   = { "test/mock.lua" },
  depscan   = true,                  -- 默认 true
})

if ok then
  print("打包成功: " .. out)
else
  print("打包失败: " .. out)
end

-- 仅分析依赖而不打包
local ok, deps = luainstaller.analyze("main.lua", {
  max_deps = 50,      -- 可选，默认 36
  depscan  = true,    -- 可选，默认 true（若为 false 则不会自动分析）
})
if ok then
  print("找到 " .. #deps .. " 个依赖")
  for i, dep in ipairs(deps) do
    print(i .. ". " .. dep)
  end
else
  print("分析失败: " .. deps)
end

-- 获取版本信息
print("luainstaller 版本: " .. luainstaller.version())
```

#### Lua API 参数说明

`luainstaller.bundle(opts)` 的 `opts`：

* `entry`（string，必需）：入口脚本路径
* `out`（string，可选）：输出路径
  * `onefile=false`（默认）：输出目录路径
  * `onefile=true`：输出文件路径
* `onefile`（boolean，可选，默认 `false`）：单文件模式开关
* `verbose`（boolean，可选，默认 `false`）：详细日志
* `max_deps`（number，可选，默认 `36`）：依赖数量上限
* `include`（string[]，可选，默认 `{}`）：手动追加依赖（可重复）
* `exclude`（string[]，可选，默认 `{}`）：手动排除依赖（可重复）
* `depscan`（boolean，可选，默认 `true`）：是否启用依赖分析（`false` 等价于 CLI 的 `--no-depscan`）
