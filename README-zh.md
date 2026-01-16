# luainstaller

`luainstaller`是一个将`.lua`打包为`.exe`的工具, 支持Windows和Linux平台. 提供预编译的二进制, 在有`lua`环境的设备上开箱即用.
使用[luastatic](https://github.com/ers35/luastatic)作为打包引擎, 并使用[Warp](https://github.com/warpdotdev/Warp)进行打包.
开源于[GitHub](https://github.com/Water-Run/luainstaller), 遵循LGPL协议.  

> luainstaller曾经以一个Python库的形式提供, 但是现在它已经独立出来成为一个命令行工具

## 安装

有两种方式进行安装: 以lua库的形式安装, 或直接下载二进制:

```bash
luarocks install luainstaller
```

或[下载二进制](https://github.com/Water-Run/luainstaller/releases).

不管使用哪种方式进行安装, 以命令行工具的方式进行使用都是一致的. 不过, 只有通过`luarocks`安装才能作为一个lua库在lua中使用.

## 使用  

### 以命令行工具的方式使用  

CLI工具的名称是`luainstaller`.  

- 获取帮助  

```bash
luainstaller help
```

```plaintext
luainstaller v0.1.0

installed via luarocks
https://github.com/Water-Run/luainstaller

help:
  ...
```

> 如果下载的是预编译的二进制, 则显示为`installed via binary(windows)`/`installed via binary(linux)`  

> 在Linux上, 也可以用`man luainstaller`查看帮助  

- 执行打包  

```bash
luainstaller bundle <path_to_lua_entry_file>
```

```plaintext
sucess.
<path_to_lua_entry_file> => <path_to_bundled_exe_file>
```

`luainstaller`将从入口`.lua`脚本开始, 进行依赖分析(静态), 并将所有依赖打包到一个可执行文件中(默认在同目录下同名).  

可选参数:  

|参数|说明|示例|
|---|---|---|
|`--output <path_to_bundled_exe_file>`|指定输出路径|`luainstaller bundle main.lua --output ../output.exe `|
|`--verbose`|显示详细信息|`luainstaller bundle main.lua --verbose`|
|`--no-wrap`|不调用Warp进行打包至单`.exe`中|`luainstaller bundle main.lua --no-wrap`|
|`--max-dependencies <amount>`|最大的依赖数量(默认36)|`luainstaller bundle main.lua --max-dependencies 10`|
|`--manual-add-require <require_script_path>`|手动添加依赖项(例如, 动态导入等依赖分析失效的场景)|`luainstaller bundle main.lua --manual-add-require ./require.lua --manual-add-require ./require2.lua`|
|`--manual-exclude <require_script_path>`|手动排除依赖项(例如, `pcall`等依赖分析强制导入的场景)|`luainstaller bundle main.lua --manual-exclude ./require.lua --manual-exclude ./require2.lua`|
|`--disable-dependency-analysis`|禁用依赖分析, 所有依赖需要手动安装|`luainstaller bundle main.lua --disable-dependency-analysis`|

### 在lua脚本中调用

基本使用是一致的.  

```lua
local luainstaller = require("luainstaller")

-- 最简单的打包: 自动分析依赖, 生成同名exe
local success, result = luainstaller.bundle({
    entry = "main.lua"  -- 入口脚本路径(必需)
})

-- 指定输出路径
local success, result = luainstaller.bundle({
    entry = "main.lua",
    output = "../dist/myapp.exe"  -- 输出可执行文件路径(可选, 默认同目录同名)
})

-- 显示详细打包信息
local success, result = luainstaller.bundle({
    entry = "main.lua",
    verbose = true  -- 显示详细的依赖分析和编译过程(可选, 默认false)
})

-- 手动添加依赖(用于动态require等自动分析无法识别的情况)
local success, result = luainstaller.bundle({
    entry = "main.lua",
    manual_add_require = {  -- 手动添加的依赖列表(可选, 默认空表)
        "./lib/plugin.lua",
        "./lib/config.lua"
    }
})

-- 手动排除依赖(用于排除误判的依赖)
local success, result = luainstaller.bundle({
    entry = "main.lua",
    manual_exclude = {  -- 手动排除的依赖列表(可选, 默认空表)
        "./test/test_utils.lua"
    }
})

-- 增加依赖数量限制
local success, result = luainstaller.bundle({
    entry = "main.lua",
    max_dependencies = 100  -- 最大依赖分析数量(可选, 默认36)
})

-- 禁用Warp打包(生成多文件而非单一exe)
local success, result = luainstaller.bundle({
    entry = "main.lua",
    no_wrap = true  -- 禁用Warp单文件打包(可选, 默认false)
})

-- 完全手动模式(禁用自动依赖分析)
local success, result = luainstaller.bundle({
    entry = "main.lua",
    disable_dependency_analysis = true,  -- 禁用依赖分析(可选, 默认false)
    manual_add_require = {  -- 此时必须手动指定所有依赖
        "./module1.lua",
        "./module2.lua"
    }
})

-- 使用所有参数的完整示例
local success, result = luainstaller.bundle({
    entry = "src/main.lua",              -- 入口脚本
    output = "build/myapp.exe",          -- 输出路径
    verbose = true,                      -- 显示详细信息
    max_dependencies = 50,               -- 最大依赖数
    manual_add_require = {               -- 手动添加依赖
        "plugins/extra.lua"
    },
    manual_exclude = {                   -- 手动排除依赖
        "test/mock.lua"
    },
    no_wrap = false,                     -- 使用Warp打包
    disable_dependency_analysis = false  -- 启用依赖分析
})

-- 检查打包结果
if success then
    print("打包成功: " .. result)  -- result是输出文件路径
else
    print("打包失败: " .. result)  -- result是错误信息
end

-- 仅分析依赖而不打包
local success, deps = luainstaller.analyze_dependencies(
    "main.lua",  -- 入口脚本
    50           -- 最大依赖数(可选, 默认36)
)
if success then
    print("找到 " .. #deps .. " 个依赖")
    for i, dep in ipairs(deps) do
        print(i .. ". " .. dep)
    end
end

-- 获取版本信息
print("luainstaller版本: " .. luainstaller.version())
```
