# luainstaller Cross-Platform Video Demo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a copy-paste-complete Fedora 44 and Windows 11 video demonstration, three matching luainstaller usage examples, and two validated cover images.

**Architecture:** Keep every video artifact under `build/bilibili/`. Fedora demonstrates the `luainstaller` and `luai` CLIs with native ELF output; Windows 11 demonstrates the Lua library API with a native PE onefile built from Luacheck v1.2.0. A pinned PowerShell wrapper reuses the repository's verified Windows MSVC matrix setup instead of inventing an untested toolchain.

**Tech Stack:** Lua 5.4, LuaRocks, Bash, PowerShell, MSVC, Markdown, built-in image generation.

## Global Constraints

- Fedora target: Fedora Linux 44 Workstation, x86_64.
- Windows target: Windows 11, x86_64, native MSVC and Windows SDK.
- Demo order: Hello World → student management system → Luacheck v1.2.0.
- Interface order: `luainstaller` → `luai` → `require("luainstaller")`.
- "Cross-platform" means native build on each target OS; never imply cross-compilation.
- Every runtime proof clears `LUA_PATH` and `LUA_CPATH` and points `PATH` to an empty directory.
- Windows onefile proof preserves `TEMP`.
- No luainstaller product source or product documentation changes.
- Cover text must contain exactly one readable string: `luainstaller`.
- Cover deliverables must be separate 16:9 and 4:3 compositions.
- Preserve unrelated untracked files.

---

### Task 1: Complete Luacheck library-API packer

**Files:**
- Create: `build/bilibili/package-luacheck.lua`

**Interfaces:**
- Consumes: `luacheck/bin/luacheck.lua`, `luacheck/src/`, installed `argparse`, installed `lfs`, and the public `require("luainstaller")` API.
- Produces: `dist/luacheck.exe` on Windows and `dist/luacheck` on POSIX; exits nonzero with structured error details on failure.

- [ ] **Step 1: Prove the deliverable is absent**

Run:

```bash
test -f build/bilibili/package-luacheck.lua
```

Expected: exit status 1.

- [ ] **Step 2: Write the complete packer**

Create `build/bilibili/package-luacheck.lua` with:

```lua
#!/usr/bin/env lua

local LUACHECK_ROOT = "luacheck"
local ENTRY = LUACHECK_ROOT .. "/bin/luacheck.lua"
local IS_WINDOWS = package.config:sub(1, 1) == "\\"
local OUTPUT = "dist/luacheck" .. (IS_WINDOWS and ".exe" or "")

package.path = table.concat({
    LUACHECK_ROOT .. "/src/?.lua",
    LUACHECK_ROOT .. "/src/?/init.lua",
    package.path,
}, ";")

local luainstaller = require("luainstaller")

local function stop(result)
    local failure = result and result.error or {}
    io.stderr:write(string.format(
        "%s: %s\n",
        failure.type or "BuildError",
        failure.message or "luainstaller operation failed"
    ))
    os.exit(1)
end

local common = {
    entry = ENTRY,
    discovery_mode = "runtime",
    run_args = { "--version" },
    max_deps = 500,
}

local analysis = luainstaller.analyze(common)
if not analysis.ok then
    stop(analysis)
end

print(string.format(
    "analysis ok: %d Lua modules, %d native modules",
    #analysis.dependencies.scripts,
    #analysis.dependencies.libraries
))

local built = luainstaller.bundle({
    entry = common.entry,
    discovery_mode = common.discovery_mode,
    run_args = common.run_args,
    max_deps = common.max_deps,
    mode = "onefile",
    out = OUTPUT,
})
if not built.ok then
    stop(built)
end

print("bundle ok: " .. built.executable)
```

Runtime discovery is intentional: Luacheck v1.2.0 uses computed `require`
expressions for its stage list and SHA-1 backend, so a static-only example
would misrepresent a real production project.

- [ ] **Step 3: Check Lua syntax**

Run:

```bash
luac -p build/bilibili/package-luacheck.lua
```

Expected: exit status 0 and no output.

- [ ] **Step 4: Check the public API names**

Run:

```bash
rg -n 'luainstaller\.(analyze|bundle)|discovery_mode = "runtime"|mode = "onefile"' \
  build/bilibili/package-luacheck.lua
```

Expected: both API calls and both required modes are shown.

- [ ] **Step 5: Commit**

```bash
git add build/bilibili/package-luacheck.lua
git commit -m "demo: add Luacheck API packer"
```

---

### Task 2: Build the Windows 11 preparation wrapper

**Files:**
- Create: `build/bilibili/setup-windows.ps1`
- Reference only: `tools/test-lua-versions.ps1`

**Interfaces:**
- Consumes: a Windows 11 x64 checkout, Visual Studio 2022 Build Tools with the VCTools workload, Windows SDK, and `tools/test-lua-versions.ps1`.
- Produces: `%TEMP%\luainstaller-video-env\activate.ps1`, an isolated Lua 5.4.8/LuaRocks 3.13.0/rock tree, and verified luainstaller, argparse 0.7.2-1, and luafilesystem 1.9.0-1 installs.

- [ ] **Step 1: Prove the script is absent**

Run:

```bash
test -f build/bilibili/setup-windows.ps1
```

Expected: exit status 1.

- [ ] **Step 2: Write the complete PowerShell wrapper**

Create `build/bilibili/setup-windows.ps1` with:

```powershell
[CmdletBinding()]
param(
    [string]$ProjectRoot = [IO.Path]::GetFullPath(
        (Join-Path $PSScriptRoot '..\..')
    ),
    [string]$SourceCache = (Join-Path $env:TEMP 'luainstaller-video-source-cache'),
    [string]$WorkRoot = (Join-Path $env:TEMP 'luainstaller-video-env'),
    [string]$EvidenceDir = (Join-Path $env:TEMP 'luainstaller-video-evidence')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not [Environment]::Is64BitOperatingSystem -or
    -not [Environment]::Is64BitProcess) {
    throw 'Windows 11 x64 and a 64-bit PowerShell process are required'
}

$MatrixScript = Join-Path $ProjectRoot 'tools\test-lua-versions.ps1'
$Rockspec = Join-Path $ProjectRoot 'luainstaller-1.0.0-1.rockspec'
foreach ($required in @($MatrixScript, $Rockspec)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "required repository file not found: $required"
    }
}

function Invoke-Native([string]$File, [string[]]$Arguments) {
    & $File @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "native command failed ($LASTEXITCODE): $File $($Arguments -join ' ')"
    }
}

function ConvertTo-PsLiteral([string]$Value) {
    return "'" + $Value.Replace("'", "''") + "'"
}

& $MatrixScript `
    -SourceCache $SourceCache `
    -WorkRoot $WorkRoot `
    -EvidenceDir $EvidenceDir `
    -HostLabel 'video-win11-x64' `
    -VersionFilter @('5.4.8')

$LuaPrefix = Join-Path $WorkRoot 'lua-5.4.8'
$Lua = Join-Path $LuaPrefix 'lua.exe'
$Luac = Join-Path $LuaPrefix 'luac.exe'
$LuaRocksRoot = Join-Path $WorkRoot 'luarocks-3.13.0-windows-64'
$LuaRocks = Join-Path $LuaRocksRoot 'luarocks.exe'
$LuaRocksConfig = Join-Path $WorkRoot 'luarocks-5.4.8-config.lua'
$RocksTree = Join-Path $WorkRoot 'rocks'
$Activate = Join-Path $WorkRoot 'activate.ps1'

foreach ($required in @($Lua, $Luac, $LuaRocks, $LuaRocksConfig)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Windows environment component not found: $required"
    }
}
if (-not (Test-Path -LiteralPath $RocksTree)) {
    $null = New-Item -ItemType Directory -Path $RocksTree
}

$env:LUAROCKS_CONFIG = $LuaRocksConfig
$env:LUAI_LUA_PREFIX = $LuaPrefix
$env:LUAI_TEST_LUA = $Lua
$env:LUAI_TEST_LUAC = $Luac
$env:PATH = "$LuaRocksRoot;$LuaPrefix;$(Join-Path $LuaPrefix 'bin');$env:PATH"

Invoke-Native $LuaRocks @(
    '--tree', $RocksTree,
    '--lua-version', '5.4',
    'make', '--force', $Rockspec
)
Invoke-Native $LuaRocks @(
    '--tree', $RocksTree,
    '--lua-version', '5.4',
    'install', 'argparse', '0.7.2-1'
)
Invoke-Native $LuaRocks @(
    '--tree', $RocksTree,
    '--lua-version', '5.4',
    'install', 'luafilesystem', '1.9.0-1'
)

$RocksBin = Join-Path $RocksTree 'bin'
$ToolPath = @(
    $RocksBin,
    $LuaRocksRoot,
    $LuaPrefix,
    (Join-Path $LuaPrefix 'bin')
) -join ';'
$LuaPath = (Join-Path $RocksTree 'share\lua\5.4\?.lua') + ';' +
    (Join-Path $RocksTree 'share\lua\5.4\?\init.lua') + ';;'
$LuaCPath = (Join-Path $RocksTree 'lib\lua\5.4\?.dll') + ';;'

$ActivationLines = @(
    '$env:PATH = ' + (ConvertTo-PsLiteral "$ToolPath;") + ' + $env:PATH',
    '$env:LUA_PATH = ' + (ConvertTo-PsLiteral $LuaPath),
    '$env:LUA_CPATH = ' + (ConvertTo-PsLiteral $LuaCPath),
    '$env:LUAROCKS_CONFIG = ' + (ConvertTo-PsLiteral $LuaRocksConfig),
    '$env:LUAI_LUA_PREFIX = ' + (ConvertTo-PsLiteral $LuaPrefix),
    '$env:LUAI_TEST_LUA = ' + (ConvertTo-PsLiteral $Lua),
    '$env:LUAI_TEST_LUAC = ' + (ConvertTo-PsLiteral $Luac)
)
[IO.File]::WriteAllText(
    $Activate,
    ($ActivationLines -join [Environment]::NewLine) + [Environment]::NewLine,
    (New-Object Text.UTF8Encoding($false))
)

. $Activate
Invoke-Native $Lua @('-e', 'require("lfs"); require("luainstaller"); print("Lua modules ok")')
Invoke-Native $LuaRocks @('--version')

$LuaInstaller = Get-Command luainstaller -ErrorAction Stop
& $LuaInstaller.Source version
if ($LASTEXITCODE -ne 0) {
    throw 'luainstaller version check failed'
}

Write-Host ''
Write-Host 'Windows video environment is ready.'
Write-Host "Activate in a new PowerShell session with:"
Write-Host ". '$Activate'"
```

The wrapper delegates source download, SHA-256 checks, MSVC initialization,
Lua `/MT` build, and native release tests to the repository's authoritative
matrix script.

- [ ] **Step 3: Parse the PowerShell syntax**

If `pwsh` is installed, run:

```bash
pwsh -NoLogo -NoProfile -Command '
  $tokens=$null; $errors=$null
  [Management.Automation.Language.Parser]::ParseFile(
    "build/bilibili/setup-windows.ps1", [ref]$tokens, [ref]$errors
  ) > $null
  if ($errors.Count) { $errors | Format-List | Out-String | Write-Error }
'
```

Expected: exit status 0 and no parse errors.

If `pwsh` is not installed, record this as a Windows-host verification item;
do not substitute Bash syntax checks.

- [ ] **Step 4: Verify pinned inputs match the authoritative matrix**

Run:

```bash
rg -n "5\\.4\\.8|3\\.13\\.0|lua-5\\.4\\.8|luarocks-3\\.13\\.0" \
  build/bilibili/setup-windows.ps1 tools/test-lua-versions.ps1
rg -n "argparse.*0\\.7\\.2-1|luafilesystem.*1\\.9\\.0-1" \
  build/bilibili/setup-windows.ps1
```

Expected: the wrapper and matrix agree on Lua and LuaRocks versions, and both
Luacheck dependencies are pinned.

- [ ] **Step 5: Commit**

```bash
git add build/bilibili/setup-windows.ps1
git commit -m "demo: add Windows video environment setup"
```

---

### Task 3: Replace the video narration

**Files:**
- Modify: `build/bilibili/script.txt`

**Interfaces:**
- Consumes: the approved design and verified project terminology.
- Produces: concise Chinese narration in the exact three-example and two-platform order.

- [ ] **Step 1: Show the old order is wrong**

Run:

```bash
rg -n "学生成绩管理|第三种使用方式|来到Windows|luai命令" \
  build/bilibili/script.txt
```

Expected: the old script says the student example uses the library API and
Luacheck uses `luai`.

- [ ] **Step 2: Replace the narration with complete copy**

Write a polished Chinese script containing these exact factual beats, without
terminal commands that would be unreadable as narration:

```text
传统上，把 Lua 脚本变成不依赖系统 Lua、可以独立运行的程序，常见方案有
srlua 和 luastatic。它们解决了“带上解释器”或者“把 Lua 和程序链接起来”
的问题，但项目一旦出现多个模块、Lua C 扩展和运行库，依赖分析与分发仍然
需要开发者自己处理。Lua 生态一直缺少一个像 PyInstaller 那样直接的一键式
工具。

luainstaller 就是为这个场景设计的。它支持静态分析、运行时跟踪和手工指定
三种依赖发现方式；能够嵌入入口脚本和纯 Lua 模块，收集匹配 ABI 的 Lua C
模块与运行库；可以生成 onedir 目录分发，也可以生成 onefile 单文件分发；
同时保留日志、诊断和重新链接所需的材料。

安装之后有三种入口。luainstaller 是现代子命令风格；luai 使用更接近 Lua
工具习惯的短参数；自动化构建还可以直接 require luainstaller，调用同一套
库 API。下面按这三个入口逐步演示。

第一站是 Fedora。先从最简单的 Hello World 开始。源码直接用 Lua 可以运行，
现在使用 luainstaller 的 build 子命令生成单文件。打包完成后，file 命令
确认它是当前 Fedora 上生成的 ELF 可执行文件。接着清空 Lua 的模块搜索路径，
把 PATH 临时指向空目录，程序仍然正常输出 Hello World。这说明运行产物不
依赖系统里的 lua 命令。

第二个例子还是在 Fedora，但项目复杂得多。这是一个多文件的学生成绩管理
系统，包含数据模型、存储、业务逻辑、报表和终端工具，并依赖原生的
lua-cjson 模块。这次改用更简洁的 luai。先用 -a 查看自动发现的依赖，再用
-b 和 --file 生成单文件。产物可以生成示例数据、列出学生并输出班级成绩
报告。即使清空 LUA_PATH、LUA_CPATH 并隔离 PATH，报告依然能够生成，说明
项目自己的 Lua 文件、cjson 二进制模块和匹配的 Lua 运行库都已经进入分发。

现在切换到 Windows 11。这里不是拿 Linux 程序去跨平台运行，而是在 Windows
上使用同一套 luainstaller 工作流，原生生成 Windows 的 PE 可执行文件。

最后一个例子使用当前由 lunarmodules 维护的 Luacheck。它是 Lua 社区广泛
使用的静态检查器，真实代码包含大量模块、原生 LuaFileSystem 依赖和动态
require，非常适合检验生产级项目的依赖处理。

这次不再使用命令行入口，而是运行一个完整的 Lua 打包脚本。脚本先把
Luacheck 的源码目录加入当前构建进程的模块路径，再 require luainstaller。
由于 Luacheck 自己会计算部分 require 名称，这里选择运行时发现模式，并用
--version 完成一次可重复的依赖跟踪。analyze 成功后检查结构化返回值，再由
bundle 生成 onefile 的 luacheck.exe。

最后准备一个故意包含未使用变量和拼错全局变量的 Lua 文件。源码版 Luacheck
可以准确报告问题；随后清空 Lua 模块路径、把 PATH 指向空目录，再运行刚刚
生成的 luacheck.exe，诊断结果保持一致。

到这里，我们已经在 Fedora 原生生成并运行了 ELF，在 Windows 11 原生生成并
运行了 PE；从单文件脚本，到多模块加 C 扩展，再到真实生产级项目，分别使用
了 luainstaller、luai 和库 API 三种入口。

luainstaller 以 LGPL-3.0-or-later 协议开源，项目地址在视频简介。如果它对你
有帮助，欢迎在 GitHub 点一个 Star。
```

- [ ] **Step 3: Verify order, platform language, and interface mapping**

Run:

```bash
lua - <<'LUA'
local handle = assert(io.open("build/bilibili/script.txt", "rb"))
local text = handle:read("*a")
handle:close()
local previous = 0
for _, item in ipairs({ "Hello World", "学生成绩管理", "Luacheck" }) do
    local position = assert(text:find(item, 1, true), item)
    assert(position > previous, "wrong demo order: " .. item)
    previous = position
end
for _, item in ipairs({
    "Fedora", "Windows 11", "ELF", "PE",
    "luainstaller", "luai", "库 API",
}) do
    assert(text:find(item, 1, true), item)
end
assert(not text:find("交叉编译", 1, true))
LUA
```

Expected: exit status 0.

- [ ] **Step 4: Commit**

```bash
git add build/bilibili/script.txt
git commit -m "docs: rewrite cross-platform video narration"
```

---

### Task 4: Write the copy-paste recording guide

**Files:**
- Create: `build/bilibili/recording-guide.md`
- Reference: `build/bilibili/package-luacheck.lua`
- Reference: `build/bilibili/setup-windows.ps1`

**Interfaces:**
- Consumes: Fedora 44 commands, Windows 11 commands, and the final narration.
- Produces: a clean-environment procedure whose every formal recording command has matching narration and expected output.

- [ ] **Step 1: Prove the guide is absent**

Run:

```bash
test -f build/bilibili/recording-guide.md
```

Expected: exit status 1.

- [ ] **Step 2: Write the environment and Fedora sections**

The guide must begin with a legend distinguishing **录屏前准备** from
**正式录屏**, then include these complete Fedora blocks:

```bash
sudo dnf install -y lua lua-devel luarocks gcc make git file
lua -v
luarocks --version

luarocks --lua-version 5.4 install --local luainstaller
luarocks --lua-version 5.4 install --local lua-cjson
eval "$(luarocks --lua-version 5.4 path)"
luainstaller version
lua -e 'require("cjson"); print("cjson ok")'

mkdir -p "$HOME/luainstaller-video"
cd "$HOME/luainstaller-video"
git clone --branch v1.0.0 --depth 1 \
  https://github.com/Water-Run/luainstaller.git luainstaller-source
mkdir -p demo dist

cat > helloworld.lua <<'LUA'
print("Hello World from luainstaller!")
LUA

lua helloworld.lua
luainstaller build --file helloworld.lua -o dist/helloworld
file dist/helloworld

EMPTY_PATH=$(mktemp -d /tmp/luainstaller-video-empty-path-XXXXXX)
env -i PATH="$EMPTY_PATH" "$PWD/dist/helloworld"
rmdir "$EMPTY_PATH"

cp -a luainstaller-source/test/student_management_system demo/student-management
find demo/student-management -maxdepth 1 -type f -printf '%f\n' | sort

STUDENT_DATA="$PWD/demo/source-students.json"
lua demo/student-management/main.lua --data "$STUDENT_DATA" seed
lua demo/student-management/main.lua --data "$STUDENT_DATA" list --sort average

luai -a demo/student-management/main.lua --max-deps 250
luai -b --file demo/student-management/main.lua \
  -o dist/student-manager --max-deps 250

BUNDLED_DATA="$PWD/demo/bundled-students.json"
dist/student-manager --data "$BUNDLED_DATA" seed
dist/student-manager --data "$BUNDLED_DATA" report

EMPTY_PATH=$(mktemp -d /tmp/luainstaller-video-empty-path-XXXXXX)
env -i PATH="$EMPTY_PATH" \
  "$PWD/dist/student-manager" \
  --data "$PWD/demo/isolated-students.json" seed
env -i PATH="$EMPTY_PATH" \
  "$PWD/dist/student-manager" \
  --data "$PWD/demo/isolated-students.json" report
rmdir "$EMPTY_PATH"
```

For each command group, add:

- a one- or two-sentence Chinese synchronous narration adapted from
  `script.txt`;
- exact expected evidence such as `Lua 5.4`, `cjson ok`, `ELF 64-bit`,
  `Scripts: 5`, `Native libraries: 1`, `Seeded 8 students`, or
  `Class Summary`;
- a re-record checkpoint noting whether cache, pre-existing output, or a
  nonempty search path could hide a problem.

Do not hard-code the current user's real home directory or repository path.

- [ ] **Step 3: Write the Windows preparation section**

Include the prerequisite commands for an elevated PowerShell:

```powershell
winget install --exact --id Git.Git
winget install --exact --id Microsoft.VisualStudio.2022.BuildTools `
  --override "--wait --passive --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
```

State that the user must close and reopen 64-bit PowerShell after installation.
Then include:

```powershell
Set-Location $HOME
New-Item -ItemType Directory -Path luainstaller-video -ErrorAction SilentlyContinue
Set-Location luainstaller-video
git clone --depth 1 `
  https://github.com/Water-Run/luainstaller.git luainstaller-source

Set-ExecutionPolicy -Scope Process Bypass
& .\luainstaller-source\build\bilibili\setup-windows.ps1 `
  -ProjectRoot (Resolve-Path .\luainstaller-source)

. "$env:TEMP\luainstaller-video-env\activate.ps1"
lua -v
luarocks --version
luainstaller version
```

Expected evidence must include Lua 5.4.8, LuaRocks 3.13.0, luainstaller
1.0.0, and `Lua modules ok`.

State immediately before this block that the video-support files must already
be present on the repository's default branch; otherwise copy the delivered
`setup-windows.ps1` and `package-luacheck.lua` into the same relative paths
before starting the clean-host recording.

- [ ] **Step 4: Write the Windows Luacheck recording section**

Include these exact file-copy and execution blocks:

```powershell
git clone --branch v1.2.0 --depth 1 `
  https://github.com/lunarmodules/luacheck.git luacheck
New-Item -ItemType Directory -Path dist -ErrorAction SilentlyContinue

Copy-Item `
  .\luainstaller-source\build\bilibili\package-luacheck.lua `
  .\package-luacheck.lua

$BadLua = @'
local message = "hello"
local unused_value = 42
print(mesage)
'@
[IO.File]::WriteAllText(
  (Join-Path $PWD 'bad.lua'),
  $BadLua,
  (New-Object Text.UTF8Encoding($false))
)

$env:LUA_PATH = "$PWD\luacheck\src\?.lua;$PWD\luacheck\src\?\init.lua;$env:LUA_PATH"
lua .\luacheck\bin\luacheck.lua .\bad.lua
"source exit code: $LASTEXITCODE"

lua .\package-luacheck.lua
Get-Item .\dist\luacheck.exe | Format-List Name,Length

$Artifact = (Resolve-Path .\dist\luacheck.exe).Path
$BadFile = (Resolve-Path .\bad.lua).Path
$EmptyPath = Join-Path $PWD 'empty-path'
New-Item -ItemType Directory -Path $EmptyPath -ErrorAction SilentlyContinue
$SavedPath = $env:PATH
$SavedLuaPath = $env:LUA_PATH
$SavedLuaCPath = $env:LUA_CPATH
try {
    $env:PATH = $EmptyPath
    $env:LUA_PATH = ''
    $env:LUA_CPATH = ''
    & $Artifact $BadFile
    "bundled exit code: $LASTEXITCODE"
} finally {
    $env:PATH = $SavedPath
    $env:LUA_PATH = $SavedLuaPath
    $env:LUA_CPATH = $SavedLuaCPath
}
```

Expected Luacheck evidence:

```text
bad.lua:1:7: unused variable message
bad.lua:2:7: unused variable unused_value
bad.lua:3:7: accessing undefined variable mesage
Total: 3 warnings / 0 errors in 1 file
```

Both source and bundled runs are expected to exit 1 because Luacheck found
warnings; this is a successful diagnostic, not a packaging failure.

- [ ] **Step 5: Add a final take checklist**

Include explicit checkboxes for:

- Fedora terminal shows Fedora 44, not a container prompt.
- `file` visibly reports ELF.
- student analysis visibly reports five Lua modules and one native library.
- Windows terminal is native 64-bit PowerShell on Windows 11.
- Windows artifact name ends in `.exe`.
- the isolated run leaves `TEMP` intact.
- source and bundled Luacheck output and exit code match.
- no secret, username-specific absolute path, browser token, or private host is visible.
- narration says native build, not cross-compilation.

- [ ] **Step 6: Verify guide coverage**

Run:

```bash
rg -n '屏幕操作|执行命令|同步口播|预期结果|重录检查点' \
  build/bilibili/recording-guide.md
rg -n 'Fedora 44|Windows 11|luainstaller build|luai -a|luai -b|package-luacheck.lua|PATH = \\$EmptyPath|TEMP' \
  build/bilibili/recording-guide.md
if rg -n 'TO''DO|TB''D|<''填|省''略' build/bilibili/recording-guide.md; then exit 1; fi
```

Expected: every required label and command is found; placeholder scan is empty.

- [ ] **Step 7: Commit**

```bash
git add build/bilibili/recording-guide.md
git commit -m "docs: add copy-paste recording guide"
```

---

### Task 5: Generate and validate both covers

**Files:**
- Create: `build/bilibili/cover-16x9.png`
- Create: `build/bilibili/cover-4x3.png`

**Interfaces:**
- Consumes: the approved cover concept.
- Produces: two separately composed raster images with only the exact word `luainstaller`.

- [ ] **Step 1: Read the image generation skill and shared prompting guidance**

Read completely:

```text
/home/waterrun/.codex/skills/.system/imagegen/SKILL.md
/home/waterrun/.codex/skills/.system/imagegen/references/prompting.md
```

Use the built-in image generation path.

- [ ] **Step 2: Generate the 16:9 cover**

Use one built-in image generation call with:

```text
Use case: ads-marketing
Asset type: 16:9 Bilibili technology video cover
Primary request: A visually explosive metaphor for turning a Lua script into native standalone binaries on Linux and Windows.
Scene/backdrop: deep navy-to-black cinematic technology space, no readable interface panels.
Subject: on the left, a luminous cobalt-blue orbital Lua-inspired energy sphere and abstract code sheets with no legible characters; in the center, a massive high-speed compiler forge emitting blue and gold sparks; on the right, the energy solidifies into two heavy native executable microchips, one with a subtle Linux penguin-shaped visual silhouette and one with a subtle four-pane Windows-shaped visual silhouette.
Style/medium: premium cinematic 3D key art, sharp hard-surface details, strong depth, high contrast, dramatic rim lighting.
Composition/framing: true wide 16:9 composition, strong left-to-right transformation flow, forge at center, both output chips fully visible, large subjects readable at thumbnail size.
Lighting/mood: electric blue and molten gold, powerful, fast, technical, trustworthy.
Text (verbatim): "luainstaller"
Text placement: one large clean lowercase title near the lower center, perfectly spelled, modern heavy sans serif.
Constraints: the only readable text anywhere in the image is exactly "luainstaller"; exactly one occurrence; visually communicate Lua-to-binary and Fedora/Windows native outputs without any other labels.
Avoid: any other word, letter, number, code glyph, command, Lua logo text, PyInstaller text, Linux text, Windows text, ELF text, EXE text, watermark, signature, UI caption, duplicated title, misspelling, cropped output chip.
```

- [ ] **Step 3: Generate the 4:3 cover separately**

Use a second built-in image generation call with:

```text
Use case: ads-marketing
Asset type: 4:3 Bilibili technology video cover
Primary request: A visually explosive metaphor for turning a Lua script into native standalone binaries on Linux and Windows.
Scene/backdrop: deep navy-to-black cinematic technology chamber, no readable interface panels.
Subject: a large luminous cobalt-blue orbital Lua-inspired energy sphere feeds abstract non-readable code sheets into a dominant central compiler forge; immediately behind and to the right, two oversized finished executable microchips emerge, one with a subtle Linux penguin-shaped silhouette and one with a subtle four-pane Windows-shaped silhouette.
Style/medium: premium cinematic 3D key art, sharp hard-surface details, strong depth, high contrast, dramatic rim lighting.
Composition/framing: true 4:3 composition designed independently, subjects packed closer together, central forge and both chips enlarged, all edges safely inside frame, readable at thumbnail size.
Lighting/mood: electric blue and molten gold, powerful, fast, technical, trustworthy.
Text (verbatim): "luainstaller"
Text placement: one large clean lowercase title along the lower center, perfectly spelled, modern heavy sans serif.
Constraints: the only readable text anywhere in the image is exactly "luainstaller"; exactly one occurrence; visually communicate Lua-to-binary and Fedora/Windows native outputs without any other labels.
Avoid: any other word, letter, number, code glyph, command, Lua logo text, PyInstaller text, Linux text, Windows text, ELF text, EXE text, watermark, signature, UI caption, duplicated title, misspelling, cropped subject.
```

- [ ] **Step 4: Save project-bound outputs**

Copy or move the selected generated files from the built-in generation output
directory into:

```text
build/bilibili/cover-16x9.png
build/bilibili/cover-4x3.png
```

Do not leave the project deliverables only under the default generated-images
directory.

- [ ] **Step 5: Validate visually and technically**

Inspect both images with `view_image`. Check subject, title spelling, absence of
other text, safe margins, and distinct aspect-specific compositions.

Run:

```bash
identify -format '%f %wx%h %[fx:w/h]\n' \
  build/bilibili/cover-16x9.png \
  build/bilibili/cover-4x3.png
tesseract build/bilibili/cover-16x9.png stdout 2>/dev/null
tesseract build/bilibili/cover-4x3.png stdout 2>/dev/null
```

Expected:

- first ratio is 1.777...;
- second ratio is 1.333...;
- OCR returns only `luainstaller`, allowing case-insensitive comparison and
  surrounding whitespace.

If a generated image is close but not exact, make one targeted image-generation
edit. Do not paint over or synthesize the image with Python.

- [ ] **Step 6: Commit**

```bash
git add build/bilibili/cover-16x9.png build/bilibili/cover-4x3.png
git commit -m "art: add cross-platform video covers"
```

---

### Task 6: Run end-to-end verification and reconcile the documents

**Files:**
- Modify if evidence requires: `build/bilibili/package-luacheck.lua`
- Modify if evidence requires: `build/bilibili/setup-windows.ps1`
- Modify if evidence requires: `build/bilibili/script.txt`
- Modify if evidence requires: `build/bilibili/recording-guide.md`

**Interfaces:**
- Consumes: all completed deliverables.
- Produces: evidence that the Fedora flow works now, the Luacheck packer works against v1.2.0, the Windows script parses, and all explicit user requirements are represented.

- [ ] **Step 1: Create a dedicated Fedora verification workspace**

Run:

```bash
VIDEO_REPO_ROOT=$(git rev-parse --show-toplevel)
DEMO_VERIFY_ROOT=$(mktemp -d /tmp/luainstaller-video-verify-XXXXXX)
printf '%s\n' "$VIDEO_REPO_ROOT"
printf '%s\n' "$DEMO_VERIFY_ROOT"
```

Record the explicit printed path and use that exact path in later commands.
Do not recursively delete an unresolved variable.

- [ ] **Step 2: Execute the Fedora Hello World flow**

Within the explicit verification workspace, run the same heredoc, source run,
`luainstaller build --file`, `file`, and isolated `env -i` commands from the
guide.

Expected: source and bundled output both contain
`Hello World from luainstaller!`, and `file` reports ELF 64-bit.

- [ ] **Step 3: Execute the Fedora student flow**

Clone tag `v1.0.0`, copy `test/student_management_system`, run source seed/list,
analyze, onefile bundle, bundled seed/report, and isolated seed/report exactly
as documented.

Expected:

- analysis: 5 Lua scripts, 1 native library;
- seed: 8 students;
- list: 8 records;
- report contains `Class Summary`;
- isolated run succeeds with empty `LUA_PATH`, empty `LUA_CPATH`, and empty
  command path.

- [ ] **Step 4: Execute the Luacheck API packer on Fedora**

In a fresh subdirectory of the verification workspace:

```bash
git clone --branch v1.2.0 --depth 1 \
  https://github.com/lunarmodules/luacheck.git luacheck
luarocks --lua-version 5.4 install --local argparse 0.7.2-1
luarocks --lua-version 5.4 install --local luafilesystem 1.9.0-1
eval "$(luarocks --lua-version 5.4 path)"
mkdir dist
cp "$VIDEO_REPO_ROOT/build/bilibili/package-luacheck.lua" .
lua package-luacheck.lua
```

Keep `VIDEO_REPO_ROOT` from Step 1 in the same shell so the copy resolves to
the checked-out repository without a user-specific hard-coded path.

Create the same `bad.lua`, run the source version, then run the bundled POSIX
artifact with isolated `PATH`, `LUA_PATH`, and `LUA_CPATH`.

Expected: source and bundled diagnostic text match after normalizing executable
prefixes, both exit 1 for warnings, and package output reports at least one Lua
module and one native module.

- [ ] **Step 5: Validate PowerShell and documentation**

Run:

```bash
luac -p build/bilibili/package-luacheck.lua
git diff --check
rg -n 'TO''DO|TB''D|<''填|省''略' \
  build/bilibili/script.txt \
  build/bilibili/recording-guide.md \
  build/bilibili/package-luacheck.lua \
  build/bilibili/setup-windows.ps1 && exit 1 || true
```

Run the PowerShell AST parser from Task 2 if `pwsh` is available.

- [ ] **Step 6: Perform the completion audit**

Check each user requirement against authoritative evidence:

| Requirement | Evidence |
|---|---|
| Modified video script | final `script.txt` order and wording scan |
| Terminal/test attention | every guide scene has command, narration, expected result, checkpoint |
| Hello World uses `luainstaller` | script and guide command |
| Student demo uses `luai` | script, guide, successful Fedora output |
| Famous production project uses library API | Luacheck v1.2.0 tag, packer API calls, successful Fedora packer run |
| Clean-environment complete flow | Fedora install/setup plus Windows setup and activation sections |
| Complete packaging script | `luac -p`, API execution, built Luacheck artifact |
| Cross-platform | Fedora ELF proof plus Windows 11 native PE procedure |
| 16:9 and 4:3 covers | image dimensions, visual inspection, OCR |
| No cover text except luainstaller | OCR plus visual inspection |

Do not mark the Windows native execution as tested unless it was actually run
on Windows 11. In the final handoff, clearly label it as the remaining
recording-host verification when no Windows host is available.

- [ ] **Step 7: Commit any evidence-driven corrections**

```bash
git add build/bilibili
git commit -m "test: reconcile video demo with verified flow"
```

Skip this commit if verification required no corrections.
