rockspec_format = "3.0"
package = "luainstaller"
version = "1.0.0-1"

source = {
    url = "git+https://github.com/Water-Run/luainstaller.git",
    tag = "v1.0.0",
}

description = {
    summary = "Package Lua projects into same-environment executables",
    detailed = [[
        luainstaller provides tools for analyzing and packaging Lua projects
        into same-environment executables. The current Lua implementation owns
        dependency analysis, trace-oriented diagnostics, and bundle planning;
        runtime launcher generation is developed in later milestones.
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
        ["luainstaller.manifest"] = "src/manifest.lua",
        ["luainstaller.runtime"]  = "src/runtime.lua",
        ["luainstaller.cgen"]     = "src/cgen.lua",
        ["luainstaller.launcher"] = "src/launcher.lua",
        ["luainstaller.cli"]      = "src/cli.lua",
    },
    install = {
        bin = {
            ["luai"] = "src/cli.lua",
        },
    },
}
