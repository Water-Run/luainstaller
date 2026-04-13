# luainstaller

> 暂时失去兴趣, 此项目暂停开发

*[English](README.md)*  

`luainstaller` 是一个将 Lua 项目打包为**可分发可执行程序**的工具，支持 **Windows** 与 **Linux**，开源于 [GitHub](https://github.com/Water-Run/luainstaller)，遵循 **LGPL** 协议。

`luainstaller` 具备依赖分析与单文件打包能力，可在封装程序中包含非纯 Lua 的内容。需要特别说明的是，`luainstaller` 保障的是打包后的二进制文件能在与当前**相同的系统环境**（不含 `lua` 环境本身）下正常运行。

> `luainstaller` 曾以 Python 库形式提供。旧版本开箱即用且跨平台，但仅支持打包纯 Lua 脚本。（见 `deprecated-python-lib` 分支）

---

## 安装

使用 `luarocks` 安装：

```bash
luarocks install luainstaller
```

### 环境依赖

运行前，请确保以下依赖已安装：

- [luastatic](https://github.com/ers35/luastatic)
- GCC 兼容的 C 工具链（如 `gcc` / `mingw-w64 gcc`）
- `windres`（仅 Windows；使用 `--icon` 时需要）

---

## 使用

`luainstaller` 既可作为命令行工具使用，也支持在 Lua 脚本中直接调用。

---

### 命令行工具（CLI）

CLI 命令名称：`luainstaller`

查看帮助：

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

> 在 Linux 上，也可使用 `man luainstaller` 查看完整手册（需已安装 manpage）。

---

#### `bundle` — 打包

`bundle` 是最常用的命令，用于将 Lua 项目打包为可执行程序。

**默认模式**（输出目录）：

```bash
luainstaller bundle <path_to_lua_entry_file>
```

```plaintext
success.
<entry.lua> => <output_dir>/
```

默认情况下，`luainstaller` 从入口 `.lua` 文件开始进行**静态依赖分析**，并将运行所需的所有文件输出到一个目录中。

**单文件模式**（`--onefile`，输出单一可执行文件）：

```bash
luainstaller bundle <path_to_lua_entry_file> --onefile
```

```plaintext
success.
<entry.lua> => <output_file>
```

`--onefile` 会在目录打包的基础上进一步封装，生成**单一可执行文件**。

**可选参数：**

| 参数                   | 说明                                                                                      | 示例                                                       |
|------------------------|-------------------------------------------------------------------------------------------|------------------------------------------------------------|
| `-o, --out <path>`     | 输出路径：默认模式为目录，`--onefile` 时为文件                                            | `--out ../dist/` / `--onefile --out ../dist/app.exe`       |
| `--onefile`            | 生成单文件可执行程序（默认不启用）                                                        | `luainstaller bundle main.lua --onefile`                   |
| `-v, --verbose`        | 输出详细的分析与打包日志                                                                  | `luainstaller bundle main.lua --verbose`                   |
| `--max-deps <n>`       | 依赖数量上限（默认 36）                                                                   | `luainstaller bundle main.lua --max-deps 100`              |
| `--include <path>`     | 手动追加依赖（可重复；用于动态 `require` 等静态分析无法识别的情况）                       | `--include ./require.lua --include ./plugin.lua`           |
| `--exclude <path>`     | 手动排除依赖（可重复；用于排除误判，如 `pcall(require, ...)` 等；优先级高于 `--include`） | `luainstaller bundle main.lua --exclude ./test_utils.lua`  |
| `--no-depscan`         | 禁用依赖分析，进入完全手动模式（须通过 `--include` 手动指定所有依赖）                     | `--no-depscan --include ./a.lua --include ./b.lua`         |
| `--icon`（仅 Windows） | 设置软件图标（`.ico` 文件）                                                               | `luainstaller bundle main.lua --onefile --icon ./logo.ico` |

---

#### `analyze` — 依赖分析

仅执行依赖分析，不进行打包：

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

### Lua API

Lua API 与 CLI 参数语义保持一致，默认启用依赖分析，可通过 `depscan = false` 关闭。

```lua
local luainstaller = require("luainstaller")
```

---

#### `bundle` — 打包

**函数签名**

```lua
local ok, out = luainstaller.bundle(opts)
```

返回值：`ok=true` 时 `out` 为输出路径；`ok=false` 时 `out` 为错误信息字符串。

**参数（`opts` 表）**

| 参数       | 类型     | 默认值  | 说明                                                                  |
|------------|----------|---------|-----------------------------------------------------------------------|
| `entry`    | string   | 必需    | 入口脚本路径                                                          |
| `out`      | string   | —       | 输出路径（`onefile=false` 时为目录路径，`onefile=true` 时为文件路径） |
| `onefile`  | boolean  | `false` | 单文件模式开关                                                        |
| `verbose`  | boolean  | `false` | 是否输出详细日志                                                      |
| `max_deps` | number   | `36`    | 依赖数量上限                                                          |
| `include`  | string[] | `{}`    | 手动追加依赖（用于动态 `require` 等无法自动识别的情况）               |
| `exclude`  | string[] | `{}`    | 手动排除依赖（用于排除误判；优先级高于 `include`）                    |
| `depscan`  | boolean  | `true`  | 是否启用自动依赖分析（`false` 等价于 CLI 的 `--no-depscan`）          |
| `icon`     | string   | —       | 软件图标路径（`.ico` 文件，仅 Windows）                               |

**示例**

```lua
-- 最简打包：输出目录，自动依赖分析
local ok, out = luainstaller.bundle({ entry = "main.lua" })
if ok then print("打包成功: " .. out)
else      print("打包失败: " .. out) end

-- 单文件模式
local ok, out = luainstaller.bundle({
  entry   = "main.lua",
  onefile = true,
  out     = "../dist/app.exe",
})

-- 手动管理依赖
local ok, out = luainstaller.bundle({
  entry   = "main.lua",
  include = { "./lib/plugin.lua", "./lib/config.lua" },  -- 追加静态分析无法检测的依赖
  exclude = { "./test/test_utils.lua" },                 -- 排除误判依赖
})

-- 完全手动模式：禁用自动分析，手动指定所有依赖
local ok, out = luainstaller.bundle({
  entry   = "main.lua",
  depscan = false,
  include = { "./module1.lua", "./module2.lua" },
})

-- 完整参数示例
local ok, out = luainstaller.bundle({
  entry    = "src/main.lua",
  out      = "build/",
  onefile  = false,
  verbose  = true,
  max_deps = 50,
  include  = { "plugins/extra.lua" },
  exclude  = { "test/mock.lua" },
  depscan  = true,
  icon     = "./logo.ico",    -- 仅 Windows
})
if ok then print("打包成功: " .. out)
else      print("打包失败: " .. out) end
```

---

#### `analyze` — 依赖分析

**函数签名**

```lua
local ok, deps = luainstaller.analyze(entry, opts)
```

返回值：`ok=true` 时 `deps` 为依赖路径字符串数组（`string[]`）；`ok=false` 时 `deps` 为错误信息字符串。

**参数**

| 参数            | 类型    | 默认值 | 说明                                         |
|-----------------|---------|--------|----------------------------------------------|
| `entry`         | string  | 必需   | 入口脚本路径                                 |
| `opts.max_deps` | number  | `36`   | 依赖数量上限                                 |
| `opts.depscan`  | boolean | `true` | 是否启用自动依赖分析（`false` 时不自动扫描） |

**示例**

```lua
-- 基本用法
local ok, deps = luainstaller.analyze("main.lua")
if ok then
  print("找到 " .. #deps .. " 个依赖")
  for i, dep in ipairs(deps) do
    print(string.format("  %d) %s", i, dep))
  end
else
  print("分析失败: " .. deps)
end

-- 完整参数示例
local ok, deps = luainstaller.analyze("src/main.lua", {
  max_deps = 50,
  depscan  = true,
})
if ok then
  for i, dep in ipairs(deps) do
    print(string.format("  %d) %s", i, dep))
  end
else
  print("分析失败: " .. deps)
end
```

> `analyze` 仅执行依赖分析，不产生任何打包产物，适合在正式打包前预检依赖是否完整、是否存在误判。

---

#### `version` — 获取版本

```lua
print("luainstaller 版本: " .. luainstaller.version())
```

---

## 工作原理

`luainstaller` 的工作流程可以概括为：**分析入口脚本 → 收集依赖 → 构建可执行程序 → 按需封装为单文件**。

当执行 `bundle` 时，`luainstaller` 会先从入口 `.lua` 文件开始进行**静态依赖分析**。它会扫描源码中的 `require(...)` 等常见引用方式，递归找出项目中依赖的 Lua 文件。对于静态分析无法完整覆盖的情况，例如运行时拼接模块名、条件加载模块等，可通过 `--include` 手动补充，通过 `--exclude` 手动排除误判。

在依赖集合确定后，`luainstaller` 会将入口脚本与收集到的 Lua 代码整理为一个待打包集合。对于纯 Lua 项目，这一步通常只涉及脚本本身；对于包含非纯 Lua 内容的项目，则还需要一并处理额外文件，并保证最终产物在**相同系统环境**下可以正常运行。

在生成可执行程序阶段，`luainstaller` 以 **`luastatic`** 为核心后端，配合 **GCC 兼容工具链** 完成编译与链接。其基本思路不是依赖目标机器预装 `lua` 环境运行脚本，而是将 Lua 程序及相关内容一并构造成可直接分发的程序。若在 Windows 下指定了 `--icon`，则会额外借助 `windres` 将图标资源编译进最终程序。

默认情况下，`luainstaller` 采用**目录输出模式**：生成一个包含可执行文件及所需文件的输出目录。启用 `--onefile` 后，则会在此基础上进一步执行**单文件封装**，把运行所需内容打包进一个单独的可执行文件中，以便分发与部署。

整体上，`luainstaller` 的技术栈保持较为直接：  
Lua 侧负责命令行接口、依赖分析与打包流程控制；  
`luastatic` 负责 Lua 程序的静态整合；  
GCC 兼容工具链负责最终编译与链接；  
`windres` 在 Windows 下负责图标等资源嵌入。

可以将其工作过程概括为：

```plaintext
[entry.lua]
     |
     v
[静态依赖分析]
     |
     v
[收集 Lua 文件 / 手动 include / 排除 exclude]
     |
     v
[整理待打包内容]
     |
     v
[luastatic + GCC 编译链接]
     |
     +----------------------+
     |                      |
     v                      v
[目录模式输出]         [--onefile 单文件封装]
     |                      |
     +----------+-----------+
                |
                v
      [可分发可执行程序]
```
