# `luainstaller`: Python库, 将`.lua`打包为二进制, 包括依赖分析能力

***[English](./README.md)***

`luainstaller`是一个[开源](https://github.com/Water-Run/luainstaller)的**Python库**, 遵循`LGPL`协议, 提供了**将`.lua`打包为可执行文件**的能力。

`luainstaller 2.0`更新带来了多引擎支持，大大增强了灵活性和跨平台能力：

- **`luastatic`**: `luainstaller 1.0`所封装的打包引擎，可以将`.lua`脚本编译为真正的原生二进制程序，仅支持`Linux`平台
- **`srlua`**: `luainstaller 2.0`新增的引擎，预编译二进制已封装到库中，实现开箱即用。支持`Windows`和`Linux`平台，提供`Lua 5.1.5`和`Lua 5.4.8`版本；`Lua 5.1.5`额外提供32位版本

`luainstaller`可以：

- ***以命令行工具使用***
- ***以图形化工具使用***
- ***作为库引入到你的项目中***

## 安装

`luainstaller`发布在[PyPI](https://pypi.org/project/luainstaller/)上，使用`pip`进行安装：

```bash
pip install luainstaller
```

安装完毕后，在终端中运行：

```bash
luainstaller
```

应获得输出：

```plaintext
luainstaller by WaterRun. Version 2.0.
Visit: https://github.com/Water-Run/luainstaller :-)
```

### 引擎环境配置

根据所选引擎，可能需要额外配置：

- **`srlua`引擎**: 开箱即用，无需任何额外配置
- **`luastatic`引擎**: 需要配置`luastatic`环境，包括`lua`、`luarocks`和`gcc`，并确保已安装`luastatic`（`luarocks install luastatic`）

## 引擎说明

`luainstaller 2.0`支持以下引擎：

| 引擎名称 | 说明 | 平台支持 |
|---------|------|---------|
| `luastatic` | 编译为真正的原生二进制 | 仅Linux |
| `srlua` | 当前系统对应的srlua 5.4.8（默认别名） | Windows/Linux |
| `winsrlua515` | Windows平台 Lua 5.1.5 (64位) | Windows |
| `winsrlua515-32` | Windows平台 Lua 5.1.5 (32位) | Windows |
| `winsrlua548` | Windows平台 Lua 5.4.8 | Windows |
| `linsrlua515` | Linux平台 Lua 5.1.5 (64位) | Linux |
| `linsrlua515-32` | Linux平台 Lua 5.1.5 (32位) | Linux |
| `linsrlua548` | Linux平台 Lua 5.4.8 | Linux |

**默认引擎**：
- Windows平台：`srlua`（即`winsrlua548`）
- Linux平台：`luastatic`

## 上手教程

`luainstaller`的工作流很简洁：

1. 分析当前的环境，获取动态库
2. 对入口脚本扫描，递归，构建依赖分析（如果自动依赖分析未被禁用）
3. 合并手动配置的依赖脚本，生成依赖列表
4. 调用对应的引擎进行打包：
   - **`luastatic`**: 根据依赖列表调用`luastatic`进行编译，输出到指定目录
   - **`srlua`**: 根据依赖列表打包为一个单独的`.lua`临时脚本，调用对应指定的预编译`srlua`二进制，输出到指定目录

如图示：

```plaintext
{环境分析}
                         |
                  test.lua <入口脚本>
                         |
                 {自动依赖分析}
                         |
        ┌───────────────────────────────────┐
        |                                   |
        |        ┌──> require("utils/log")  |
        |        |          │               |
        |        |     utils/log.lua        |
        |        |          │               |
        |        |     require("utils/time")|
        |        |          │               |
        |        |     utils/time.lua       |
        |        |                          |
        |        |                          |
        |        └──> require("core/init")  |
        |                   │               |
        |            core/init.lua          |
        |            core/config.lua        |
        |            core/db.lua            |
        |                                   |
        └───────────────────────────────────┘
                         |
               (手动配置依赖)
                         |
                  extra/plugin.lua
                         |
                         ↓
                    <依赖清单>
    -------------------------------------------------
    utils/log.lua
    utils/time.lua
    core/init.lua
    core/config.lua
    core/db.lua
    extra/plugin.lua
    -------------------------------------------------
                         ↓
                    {选择引擎}
        ┌──────────────────────────────────────────┐
        |                                          |
        |   [luastatic 引擎]                       |
        |   调用 luastatic，根据依赖列表将所有     |
        |   Lua 脚本编译为真正的原生二进制         |
        |                                          |
        |   luastatic test.lua ... -o test         |
        |                                          |
        |------------------------------------------|
        |                                          |
        |   [srlua 引擎]                           |
        |   将依赖合并为临时单文件 Lua 脚本        |
        |   调用预编译的 srlua 二进制进行打包      |
        |                                          |
        |   srlua (预编译) + packed.lua -> test    |
        |                                          |
        └──────────────────────────────────────────┘
```

### 关于自动依赖分析

`luainstaller`具备有限的自动依赖分析能力，引擎会匹配以下形式的`require`语句，进行递归查找，获取依赖列表：

```lua
require '{pkg_name}'
require "{pkg_name}"
require('pkg_name')
require("pkg_name")
require([[pkg_name]])
```

使用`pcall`的引入也会被视为和`require`等效导入。

此外的形式将导致报错，包括动态依赖等。此时，应当禁用自动依赖分析，改用手动添加所需依赖。

> 只能包含纯`lua`的库

### 作为图形化工具使用

最简单的使用方式莫过于`GUI`了。`luainstaller`提供一个由`Tkinter`实现的图形界面。在完成安装后，在终端中输入：

```bash
luainstaller-gui
```

即可启动。

> GUI界面仅包含基础功能

### 作为命令行工具使用

`luainstaller`最主要的使用方式是作为命令行工具。在终端中输入：

```bash
luainstaller
```

即可。

> 或`luainstaller-cli`，二者是等效的

#### 指令集

##### 获取帮助

```bash
luainstaller help
```

这将输出使用帮助。

##### 获取日志

```bash
luainstaller logs [-limit <限制数>] [-asc]
```

这将输出luainstaller存储的操作日志。

*参数:*

- `limit`: 限制的输出数目，大于0的整数
- `asc`: 按时间顺序（默认倒序）

> 日志系统使用[SimpSave](https://github.com/Water-Run/SimpSave)

##### 输出引擎

```bash
luainstaller engines
```

这将输出luainstaller所支持的全部引擎名称。

##### 依赖分析

```bash
luainstaller analyze <入口脚本> [-max <最大依赖数>] [--detail]
```

这将执行依赖分析，输出分析列表。

*参数:*

- `max`: 限制的最大依赖树，大于0的整数
- `detail`: 详细的运行输出

> 默认情况下，分析至多36个依赖

##### 执行编译

```bash
luainstaller build <入口脚本> [-engine <引擎名称>] [-require <依赖的.lua脚本>] [-max <最大依赖数>] [-output <输出的二进制路径>] [--manual] [--detail]
```

*参数:*

- `入口脚本`: 对应的入口脚本，依赖分析的起点
- `engine`: 指定使用的引擎名称。Windows默认为`srlua`，Linux默认为`luastatic`
- `require`: 依赖的脚本，如果对应脚本已由分析引擎自动分析到，将跳过。多个使用`,`隔开
- `max`: 限制的最大依赖树，大于0的整数。默认情况下，至多分析36个
- `output`: 指定输出的二进制路径，默认为在当前目录下和`.lua`同名的可执行文件，在Windows平台上自动添加`.exe`后缀
- `manual`: 不进行依赖分析，直接编译入口脚本，除非使用`-require`强制指定
- `detail`: 详细的运行输出

*示例:*

```bash
luainstaller build hello_world.lua
```

将hello_world.lua编译为同目录下的可执行文件hello_world（Linux）或hello_world.exe（Windows）。

```bash
luainstaller build a.lua -require b.lua,c.lua --manual
```

将a.lua和依赖b.lua、c.lua一同打包为二进制，不进行自动依赖分析。

```bash
luainstaller build test.lua -engine winsrlua515 -max 100 -output ../myProgram --detail
```

使用Windows平台的Lua 5.1.5引擎，将test.lua设置至多分析至100个依赖项，打包至上级目录下的myProgram二进制中，并显示详尽的编译信息。

```bash
luainstaller build app.lua -engine linsrlua548
```

在Linux平台上使用srlua 5.4.8引擎打包app.lua。

## 作为库使用

`luainstaller`也可以作为库导入你的脚本中：

```python
import luainstaller
```

并提供函数式的API。

## API参考

### `get_logs()`

获取日志

```python
def get_logs(limit: int | None = None,
             _range: range | None = None,
             desc: bool = True) -> list[dict[str, Any]]:
    r"""
    返回luainstaller日志.
    :param limit: 返回数限制, None表示不限制
    :param _range: 返回范围限制, None表示不限制
    :param desc: 是否倒序返回
    :return list[dict[str, Any]]: 日志字典组成的列表
    """
```

示例:

```python
import luainstaller

log_1: dict = luainstaller.get_logs()  # 以倒序获取全部日志
log_2: dict = luainstaller.get_logs(limit=100, _range=range(128, 256), desc=False)  # 以顺序获取最多一百条, 范围在128到256之间的日志
```

### `get_engines()`

获取支持的引擎列表

```python
def get_engines() -> list[str]:
    r"""
    返回luainstaller支持的全部引擎名称.
    :return list[str]: 引擎名称列表
    """
```

示例:

```python
import luainstaller

engines: list = luainstaller.get_engines()  # 获取全部支持的引擎名称
```

### `analyze()`

执行依赖分析（对应 CLI 的 `luainstaller analyze`）

```python
def analyze(entry: str,
            max_deps: int = 36) -> list[str]:
    r"""
    对入口脚本执行依赖分析.

    :param entry: 入口脚本路径
    :param max_deps: 最大递归依赖数, 默认36
    :return list[str]: 分析得到的依赖脚本路径列表
    """
```

示例:

```python
import luainstaller

deps_1: list = luainstaller.analyze("main.lua")  # 依赖分析, 默认最多分析36个依赖
deps_2: list = luainstaller.analyze("main.lua", max_deps=112)  # 执行依赖分析, 将最大依赖分析数量修改为112
```

### `build()`

执行编译（对应 CLI 的 `luainstaller build`）

```python
def build(entry: str,
          engine: str | None = None,
          requires: list[str] | None = None,
          max_deps: int = 36,
          output: str | None = None,
          manual: bool = False) -> str:
    r"""
    执行脚本编译.

    :param entry: 入口脚本
    :param engine: 引擎名称, None使用平台默认引擎(Windows: srlua, Linux: luastatic)
    :param requires: 手动指定依赖列表; 若为空则仅依赖自动分析
    :param max_deps: 最大依赖树分析数
    :param output: 输出二进制路径, None使用默认规则
    :param manual: 禁用自动依赖分析
    :return str: 生成的可执行文件路径
    """
```

示例:

```python
import luainstaller

# 最简单的构建方式, 自动分析依赖并生成与脚本同名的可执行文件
luainstaller.build("hello.lua")

# 指定使用srlua 5.1.5引擎
luainstaller.build("app.lua", engine="winsrlua515")

# 手动模式: 禁用自动依赖分析, 仅使用requires指定的依赖脚本进行编译
luainstaller.build("a.lua", requires=["b.lua", "c.lua"], manual=True)

# 完整参数示例
luainstaller.build("test.lua", engine="linsrlua548", max_deps=100, output="../myProgram")
```
