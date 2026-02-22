package = "luainstaller"
version = "1.0.0-1"

source = {
    url = "git+https://github.com/Water-Run/luainstaller.git",
    tag = "v1.0.0",
}

description = {
    summary = "Package Lua scripts into standalone executables with multi-engine support",
    detailed = [[
        luainstaller provides tools for packaging Lua scripts into standalone
        executables. Features include static dependency analysis of Lua scripts,
        native library detection (.a, .so, .dll, .dylib), source bundling, and
        compilation using luastatic or srlua engines. Supports both Windows and
        Linux platforms.
    ]],
    homepage = "https://github.com/Water-Run/luainstaller",
    license = "LGPL-3.0-or-later",
    maintainer = "WaterRun <linzhangrun49@gmail.com>",
    labels = {
        "lua",
        "packaging",
        "executable",
        "compiler",
        "luastatic",
        "srlua",
        "dependency-analysis",
    },
}

dependencies = {
    "lua >= 5.4",
}

build = {
    type = "builtin",
    modules = {
        ["luainstaller"]          = "src/init.lua",
        ["luainstaller.logger"]   = "src/logger.lua",
        ["luainstaller.analyzer"] = "src/analyzer.lua",
        ["luainstaller.cli"]      = "src/cli.lua",
        ["luainstaller.executor"] = "src/executor.lua",
        ["luainstaller.wrapper"]  = "src/wrapper.lua",
    },
    install = {
        bin = {
            ["luainstaller"] = "src/cli.lua",
        },
    },
}