# luainstaller

*[English](README.md)*

`luainstaller` 是一个将 Lua 项目打包为**可分发可执行程序**的工具。当前已实现 Linux、macOS 与 Windows `--onedir` 输出，用于同平台或显式 profile 构建；`--onefile` 已实现为基于同一运行时契约的自解压单文件包装器。当前本地与实验脚本已验证所选样例矩阵中的 Linux、macOS 和 Windows `--onedir` 与 `--onefile` 包。项目开源于 [GitHub](https://github.com/Water-Run/luainstaller)，遵循 **LGPL** 协议。

`luainstaller` 具备依赖分析与同平台目录打包能力，可在封装程序中包含非纯
Lua 的内容。需要特别说明的是，`luainstaller` 保障的是打包后的二进制文件能
在与当前**相同的系统环境**下正常运行。已验证的 Linux、macOS 和 Windows 包
不需要目标环境额外提供 `lua` 命令，但仍要求系统 ABI 和 native library 兼容。

> `luainstaller` 曾以 Python 库形式提供。旧版本开箱即用且跨平台，但仅支持打包纯 Lua 脚本。（见 `deprecated-python-lib` 分支）

---

## 安装

使用 `luarocks` 安装：

```bash
luarocks install luainstaller
```

在没有 LuaRocks 的环境中，可从源码 checkout 安装：

```bash
sh tools/install-source.sh --prefix "$HOME/.local"
export PATH="$HOME/.local/bin:$PATH"
luai --help
luainstaller -v
```

源码安装器只要求存在 `lua` 命令，并会安装两个 CLI 名称以及 `luai(1)` 和
`luainstaller(1)` man page。构建 `--onedir` 或 `--onefile` 包仍需要本机 C 工具链和
Lua 开发元数据。Linux 使用 `cc`、Lua headers 以及 Lua 的 `pkg-config` 数据；
macOS 使用 `cc` 以及包含 Lua headers 和 `liblua.a` 的匹配 Lua prefix；Windows 由
Linux 主机通过 MinGW 构建，并使用包含 Lua headers 与 `lua54.dll` 的 Windows Lua
prefix。

---

## 使用

`luainstaller` 既可作为命令行工具使用，也支持在 Lua 脚本调用。

---

### 命令行工具（CLI）

CLI 命令名称：`luai` 与 `luainstaller`。

```bash
luai --help
luai a test/student_management_system/main.lua
luai t test/student_management_system/main.lua
luai b --dir test/student_management_system/main.lua -o build/student-manager
luai b --file test/runtime_bundle/main.lua -o build/runtime-onefile
luainstaller -v
```

当前命令状态：

| 命令 | 状态 | 说明 |
|------|------|------|
| `luai a <entry.lua>` | 已实现 | 分析 Lua 与 native 模块依赖。 |
| `luai t <entry.lua>` | 已实现 | 输出 analyzer trace 记录，以及相同 OS、架构、ABI 和 Lua ABI 边界的兼容性诊断。 |
| `luai b <entry.lua>` | 已在所选样例矩阵中实现并验证 Linux、macOS 和 Windows `--dir` 与 `--file` | 构建目录包或自解压单文件包，包含 launcher、manifest、嵌入的 Lua payload 和复制的 native Lua C 模块。 |

旧脚本仍可继续使用兼容别名：`-a`/`analyze`、`-t`/`trace`、`-c`/`build`。

常用选项：

| 参数 | 说明 |
|------|------|
| `--dir, --onedir` | 目录打包模式，当前默认输出模式。 |
| `--file, --onefile` | 自解压单文件模式。 |
| `-o, --out <path>` | 打包动作输出路径。 |
| `--include <path>` | 手动追加依赖，可重复。 |
| `--exclude <path>` | 按路径或文件名排除依赖，可重复。 |
| `--target-os <os>` | 选择目标 profile：`linux`、`macos` 或 `windows`。 |
| `--lua-prefix <path>` | 为需要显式 Lua headers/runtime 的目标指定 Lua prefix。 |
| `-r, --require-engine <engine>` | 依赖发现引擎：`static`、`manual` 或 `runtime`。 |
| `--no-depscan` | 禁用自动依赖扫描。 |
| `--max-deps <n>` | 依赖数量上限，默认 `36`。 |
| `--verbose` | 在可用位置输出更多细节。 |

---

### Lua API

Lua API 与 CLI 参数语义保持一致，默认启用依赖分析，可通过 `depscan = false` 关闭。

```lua
local luainstaller = require("luainstaller")
```

---

#### 结构化返回

公开 API 对正常用户错误返回结构化结果，而不是直接抛出异常。

```lua
local analyzed = luainstaller.analyze({
  entry = "test/student_management_system/main.lua",
  max_deps = 250,
})

if analyzed.ok then
  print(#analyzed.dependencies.scripts)
else
  io.stderr:write(analyzed.error.type .. ": " .. analyzed.error.message .. "\n")
end
```

当前函数：

| 函数 | 状态 | 返回形态 |
|------|------|----------|
| `luainstaller.analyze(opts)` | 已实现 | `{ ok = true, action = "analyze", dependencies = { scripts = {}, libraries = {} } }` |
| `luainstaller.trace(opts)` | 已实现 | analyzer 真实 trace 记录，包含引用文件、源码行、候选项、分类、原因和 `compatibility` 摘要。 |
| `luainstaller.compatibility(opts)` | 已实现 | 输出目标 profile、Lua ABI、launcher profile 和已知 native library 风险的兼容性诊断。 |
| `luainstaller.bundle(opts)` | 已在所选样例矩阵中实现并验证 Linux、macOS 和 Windows `mode = "onedir"` 与 `mode = "onefile"` | 返回 `{ ok = true, action = "bundle", executable = "...", manifest = { ... } }`。 |

常用 `opts` 字段：

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `entry` | string | 必需 | 入口脚本路径。 |
| `mode` | string | `"onedir"` | 打包模式：`onedir` 或 `onefile`。 |
| `out` | string | nil | `onedir` 输出目录路径；`onefile` 输出可执行文件路径。 |
| `max_deps` | number | `36` | 依赖数量上限。 |
| `include` | string[] | `{}` | 手动追加文件。 |
| `exclude` | string[] | `{}` | 排除路径或文件名。 |
| `depscan` | boolean | `true` | 设为 `false` 时只使用手动依赖。 |
| `require_engine` | string | `"static"` | 依赖引擎：`static`、`manual` 或 `runtime`；`depscan = false` 等价于 `manual`。 |
| `run_args` | string[] | `{}` | `require_engine = "runtime"` 时传给入口程序的构建期运行参数。 |
| `target_os` | string | host OS | 目标 profile：`linux`、`macos` 或 `windows`。 |
| `lua_prefix` | string | `LUAI_LUA_PREFIX` | macOS 和 Windows profile 使用的 Lua headers/runtime prefix。 |

---

## 工作原理

当前工作流程是：**分析入口脚本 → 收集依赖 → 输出解析诊断 → 构建同平台
onedir 目录包或 onefile 单文件包**。

Linux、macOS 和 Windows `--onedir` 与 `--onefile` 输出已经在所选样例矩阵中实现
并验证。它会生成 C launcher，写入 `.luai/manifest.lua`，将 Lua payload 嵌入
launcher，并把检测到的 native Lua C 模块复制到 `.luai/native/`。Linux 使用
shared-Lua launcher 并复制链接到的 Lua shared runtime；macOS 使用所选 Lua
prefix 中的静态 `liblua.a` 链接 launcher；Windows 使用
`x86_64-w64-mingw32-gcc` 生成 `.exe`，并把 `lua54.dll` 复制到 launcher 同级
目录和 `.luai/native/`。兼容性边界是相同 OS、相同架构、相同 ABI 和相同 Lua ABI。

`--onefile` 会先复用同一 onedir 布局完成 staging，再把这些文件嵌入一个 native
extractor。运行时 extractor 将文件写入按内容 hash 区分的缓存目录，然后启动内层
可执行程序。这样 `.so`、`.dylib`、`.dll` 等 native Lua C 模块和 Lua runtime
都会在用户代码运行前真实存在于文件系统中。已存在的提取文件在大小和内容 hash
匹配时会复用。通用跨平台交叉构建和自动外部 shared library 依赖闭包仍是路线图中
的后续工作。

依赖发现引擎可选：`static` 使用静态 analyzer，`manual` 只使用显式 include，
`runtime` 会在构建期运行入口程序一次并记录实际发生的 `require` 调用。runtime
发现只能覆盖这次运行实际执行到的代码路径。

更详细的实现说明、非纯 Lua 打包行为、验证命令和当前限制见
[`docs/LINUX-ONEDIR-BUNDLING.md`](docs/LINUX-ONEDIR-BUNDLING.md)。
Linux、macOS 和 Windows 测试环境结果见
[`docs/CROSS-PLATFORM-TEST-MATRIX.md`](docs/CROSS-PLATFORM-TEST-MATRIX.md)。

纯 Lua runtime 里程碑已实现：`luainstaller.runtime` 可以安装 bundled module
searcher，`luainstaller.cgen` 可以为纯 Lua payload 生成 Lua bootstrap chunk。
这段 bootstrap 已由生成的 C launcher 嵌入执行。

C launcher template 里程碑已实现：`luainstaller.launcher` 可以生成
shared-Lua C 源码，将 Lua bootstrap 嵌入并通过 Lua C API 执行。bundler 使用它
生成输出目录中的可执行程序。

可以将其工作过程概括为：

```plaintext
[entry.lua]
     |
     v
[依赖分析：static / manual / runtime]
     |
     v
[收集 Lua 文件 / 手动 include / 排除 exclude]
     |
     v
[生成 C launcher / 复制 native 模块 / 写入 manifest]
     |
     v
[Linux、macOS 或 Windows onedir 目录包或 onefile 单文件包]
```
