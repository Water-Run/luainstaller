# luainstaller

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

---

## 使用

`luainstaller` 既可作为命令行工具使用，也支持在 Lua 脚本调用。

---

### 命令行工具（CLI）

CLI 命令名称：`luai`。

```bash
luai --help
luai -a test/student_management_system/main.lua
luai -t test/student_management_system/main.lua
luai -c --onedir test/student_management_system/main.lua -o build/student-manager
```

当前命令状态：

| 命令 | 状态 | 说明 |
|------|------|------|
| `luai -a <entry.lua>` | 已实现 | 分析 Lua 与 native 模块依赖。 |
| `luai -t <entry.lua>` | 已实现 | 输出粗粒度的解析诊断信息。 |
| `luai -c <entry.lua>` | 计划中 | 完成参数校验和打包规划，然后在 onedir bundler 实现前返回 `NotImplementedError`。 |

常用选项：

| 参数 | 说明 |
|------|------|
| `--onedir` | 目录打包模式，当前计划中的默认输出模式。 |
| `--onefile` | 单文件模式，排在 onedir 之后实现。 |
| `-o, --out <path>` | 打包规划的输出路径。 |
| `--include <path>` | 手动追加依赖，可重复。 |
| `--exclude <path>` | 按路径或文件名排除依赖，可重复。 |
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
| `luainstaller.trace(opts)` | 已实现 | `{ ok = true, action = "trace", trace = {} }` |
| `luainstaller.bundle(opts)` | 计划中 | 校验通过后返回 `{ ok = false, error = { type = "NotImplementedError", ... } }`。 |

常用 `opts` 字段：

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `entry` | string | 必需 | 入口脚本路径。 |
| `mode` | string | `"onedir"` | 打包规划模式：`onedir` 或 `onefile`。 |
| `out` | string | nil | 打包规划输出路径。 |
| `max_deps` | number | `36` | 依赖数量上限。 |
| `include` | string[] | `{}` | 手动追加文件。 |
| `exclude` | string[] | `{}` | 排除路径或文件名。 |
| `depscan` | boolean | `true` | 设为 `false` 时只使用手动依赖。 |

---

## 工作原理

当前工作流程是：**分析入口脚本 → 收集依赖 → 输出解析诊断 → 校验打包选项**。

运行时 launcher 生成、manifest 写入、onedir 输出、onefile payload 和 native 模块解压仍是路线图中的后续工作。后续运行时的兼容性边界是相同 OS、相同架构、相同 ABI 和相同 Lua ABI。

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
[校验打包规划]
     |
     v
[Manifest / onedir runtime 后续实现]
```
