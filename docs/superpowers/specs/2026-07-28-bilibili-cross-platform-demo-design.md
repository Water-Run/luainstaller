# luainstaller 跨平台视频演示设计

日期：2026-07-28

## 目标

制作一套可以在干净环境中逐条照做的 luainstaller 视频演示材料。视频通过
Fedora 44 与 Windows 11 x64 两个原生环境展示同一套打包能力，依次覆盖
`luainstaller` 命令、`luai` 命令和 Lua 库 API。

“跨平台”在本视频中指：在目标操作系统上原生构建该系统的可执行文件。
视频不得暗示 luainstaller 支持交叉编译，也不得暗示同一个二进制可同时运行
在 Linux 与 Windows。

## 交付物

所有视频专用文件放在 `build/bilibili/`：

- `script.txt`：修改后的完整视频稿。
- `recording-guide.md`：按录屏顺序排列的环境准备、终端命令、文件内容复制、
  对应口播、预期输出和重录检查点。
- `package-luacheck.lua`：生产级项目演示使用的完整库 API 打包脚本。
- `setup-windows.ps1`：Windows 11 干净环境所需的 Lua、LuaRocks 和 MSVC
  配置脚本。
- `cover-16x9.png`：16:9 视频封面。
- `cover-4x3.png`：4:3 视频封面。

产品源码和产品文档不因视频演示而修改。

## 演示结构

### 1. 开场

简要对比 srlua、luastatic 与 luainstaller，说明 luainstaller 的定位是
“Lua 的 PyInstaller”：自动分析和打包 Lua 模块、Lua C 模块及匹配的运行库，
输出 onedir 或 onefile 分发。

随后一次性说明三种入口：

- `luainstaller`：现代子命令风格；
- `luai`：更接近 Lua 工具习惯的短参数风格；
- `require("luainstaller")`：供构建脚本和自动化流程调用的库 API。

### 2. Fedora 44：Hello World

从安装依赖和 `luarocks install luainstaller` 开始。现场复制
`helloworld.lua`，先用 Lua 运行源码，再执行：

```bash
luainstaller build --file helloworld.lua -o dist/helloworld
```

使用 `file` 展示产物是 Linux ELF 可执行文件。最后清空 `LUA_PATH`、
`LUA_CPATH`，并把 `PATH` 指向空目录，使用绝对路径运行产物，证明运行时
不需要系统 Lua。

### 3. Fedora 44：学生成绩管理系统

从 luainstaller 仓库复制 `test/student_management_system/` 到独立演示目录。
该项目包含多个 Lua 文件，并使用原生 `lua-cjson`。

先安装并验证 `lua-cjson`，再依次执行源码烟雾测试、`luai -a` 分析和
`luai -b --file` 打包。产物先生成示例数据，再展示学生列表和班级成绩报告。
最后在清空 Lua 环境变量和隔离 `PATH` 的环境中重复运行产物。

这一段只使用 `luai`，不出现库 API。

### 4. Windows 11 x64：Luacheck

Windows 演示使用 PowerShell、Visual Studio 2022 Build Tools、Windows SDK、
官方 Lua 5.4.8 和 LuaRocks 3.13.0。`setup-windows.ps1` 负责下载并校验
官方源码/发行包、用原生 MSVC 构建匹配的 Lua DLL、配置 LuaRocks，再安装
luainstaller 及 Luacheck 所需依赖。

真实项目使用当前维护仓库：

```text
https://github.com/lunarmodules/luacheck
```

演示克隆仓库后，用 `package-luacheck.lua`：

1. 将 Luacheck 的 `src` 目录加入当前构建进程的 `package.path`；
2. 调用 `luainstaller.analyze`；
3. 检查结构化结果的 `ok` 和 `error`；
4. 调用 `luainstaller.bundle` 生成 `dist/luacheck.exe` onefile；
5. 输出分析到的依赖数量和最终可执行文件路径。

打包脚本必须使用稳定、明确的相对路径，不依赖用户主目录。它必须包含完整
错误处理，失败时输出错误类型和消息并返回非零状态。

随后复制一个包含未使用局部变量和拼写错误全局变量的 Lua 文件。先用源码版
Luacheck 检查，再把 `PATH` 指向空目录并清空 `LUA_PATH`、`LUA_CPATH`，
运行打包后的 `.exe`。两次诊断应一致。保留 `TEMP`，因为 onefile 运行时
需要安全解包目录。

视频通过 Fedora 的 ELF 产物和 Windows 的 PE `.exe` 产物共同证明跨平台。

## 命令与文案组织

`recording-guide.md` 不只是命令汇总，而是录屏执行手册。每个镜头包含：

1. **屏幕操作**：此时应该显示哪个终端或文件；
2. **执行命令**：可直接复制执行的完整命令；
3. **同步口播**：与该命令对应的中文文案；
4. **预期结果**：用于判断是否可以继续录制；
5. **重录检查点**：容易暴露路径、缓存或宿主依赖的地方。

所有需现场创建的短文件使用 Bash heredoc 或 PowerShell here-string 给出完整
内容。学生系统不重复粘贴数百行源码，而是给出从已克隆仓库复制完整目录的
命令，并在复制后列出文件以证明内容完整。

环境安装和耗时下载标记为“录屏前准备”；核心打包和隔离运行标记为“正式
录屏”。这样既保留从干净环境开始的完整流程，也避免正式视频被编译工具链
安装过程淹没。

## Windows 环境脚本边界

`setup-windows.ps1` 以 Windows 11 x64 原生 PowerShell 运行，要求 Visual
Studio 2022 Build Tools 的 C++ x64 工具和 Windows SDK 已安装。脚本负责：

- 找到并初始化 MSVC x64 工具链；
- 下载固定版本的 Lua 5.4.8 源码和 LuaRocks 3.13.0 Windows x64 发行包；
- 校验 SHA-256；
- 用 `/MT` 构建 `lua54.dll`、导入库、`lua.exe` 和 `luac.exe`；
- 写入独立 LuaRocks 配置；
- 安装 `luainstaller`、`argparse` 和 `luafilesystem`；
- 输出一个供当前 PowerShell 会话导入的环境文件；
- 验证 `lua`、`luarocks`、`luainstaller`、`require("lfs")` 和
  `require("luainstaller")`。

脚本的工作目录固定在用户指定路径或 `%TEMP%\luainstaller-video-env`，
拒绝删除或覆盖工作目录以外的路径。已存在且哈希/标记匹配的组件可复用。

Visual Studio Build Tools 本身通过官方安装器提前安装，不由脚本静默安装。
录屏指南提供安装命令和所需组件名称。

## 封面设计

两张封面分别原生生成构图，不用把一张机械裁切为另一张。

共同视觉概念：

- 深蓝到黑色的高对比科技背景；
- 左侧为带轨道意象的 Lua 蓝色能量球和 Lua 代码卡片；
- 中央是高速运转、迸发蓝金火花的编译锻炉；
- 右侧分化出两枚实体二进制芯片，一枚带 Linux 视觉暗示，一枚带 Windows
  视觉暗示；
- 强透视、强轮廓光和明确的左到右运动方向，缩略图尺寸下仍有冲击力；
- 画面唯一文字必须是精确小写 `luainstaller`；
- 不出现 Lua、PyInstaller、Linux、Windows、ELF、EXE、代码片段中的可读
  文字、角标、水印或随机字符。

16:9 版本保留更强的横向转化叙事；4:3 版本收紧主体距离、增大中央锻炉和
二进制芯片，避免简单裁切造成主体缺失。

## 验证

### Fedora 实机验证

- 使用当前 Fedora 44 x86_64 主机从独立临时目录执行指南中的 Fedora 流程；
- Hello World 源码、打包、ELF 检查和隔离运行全部成功；
- 学生系统烟雾测试、依赖分析、onefile 打包、数据生成、列表、报告和隔离
  运行全部成功；
- `luac -p package-luacheck.lua` 通过。

### Windows 可验证性

- 使用 PowerShell AST parser 检查 `setup-windows.ps1` 语法；
- 根据项目现有 `tools/test-lua-versions.ps1` 的已验证 MSVC 配置核对下载
  版本、哈希、Lua 构建参数和 LuaRocks 配置；
- 录屏指南明确列出 Windows 11 实机必须执行的安装、打包和隔离运行检查；
- 不使用 Wine 或 MinGW 结果替代 Windows 11 原生验证。

如果当前工作环境无法连接 Windows 11 实机，交付说明必须明确区分“已在
Fedora 实测”与“等待 Windows 11 实机按指南验证”，不得声称 Windows 命令
已经实际运行。

### 文档与封面检查

- `script.txt` 的三个示例顺序必须是：
  `helloworld → 学生成绩管理 → 生产级 Luacheck`；
- 三段入口顺序必须是：`luainstaller → luai → 库 API`；
- `recording-guide.md` 中每条正式录屏命令都有对应口播和预期结果；
- 文档不存在未完成事项标记或省略号式代码占位；
- 两张封面文件可打开，比例分别为 16:9 和 4:3；
- 对封面进行视觉检查和 OCR/文本检查，确保唯一文字为
  `luainstaller`。

## 非目标

- 不实现交叉编译；
- 不修改 luainstaller 产品行为；
- 不把安装包格式（MSI、RPM）当成 onefile；
- 不在视频中完整展示 Windows 工具链安装等待过程；
- 不承诺未在 Windows 11 实机执行过的结果。
