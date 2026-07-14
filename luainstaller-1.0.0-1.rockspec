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
        dependency analysis, trace-oriented diagnostics, manifest generation,
        C launcher generation, onedir bundling, and self-extracting onefile
        bundling for the verified target profiles. It installs two command
        names over the same Lua API: compact luai and full-word luainstaller.
    ]],
    homepage = "https://github.com/Water-Run/luainstaller",
    license = "LGPL-3.0-or-later",
    maintainer = "WaterRun <linzhangrun49@gmail.com>",
    labels = {
        "lua",
        "packaging",
        "executable",
        "compiler",
        "dependency-analysis",
    },
}

dependencies = {
    "lua >= 5.1, < 6.0",
}

build = {
    type = "builtin",
    modules = {
        ["luainstaller"]          = "src/init.lua",
        ["luainstaller.fs"]       = "src/fs.lua",
        ["luainstaller.hash"]     = "src/hash.lua",
        ["luainstaller.logger"]   = "src/logger.lua",
        ["luainstaller.analyzer"] = "src/analyzer.lua",
        ["luainstaller.compat"]   = "src/compat.lua",
        ["luainstaller.manifest"] = "src/manifest.lua",
        ["luainstaller.path"]     = "src/path.lua",
        ["luainstaller.platform"] = "src/platform.lua",
        ["luainstaller.process"]  = "src/process.lua",
        ["luainstaller.result"]   = "src/result.lua",
        ["luainstaller.runtime"]  = "src/runtime.lua",
        ["luainstaller.cgen"]     = "src/cgen.lua",
        ["luainstaller.launcher"] = "src/launcher.lua",
        ["luainstaller.bundler"]  = "src/bundler.lua",
        ["luainstaller.discovery"]  = "src/discovery.lua",
        ["luainstaller.onefile"]  = "src/onefile.lua",
        ["luainstaller.cli"]      = "src/cli.lua",
    },
    install = {
        bin = {
            ["luai"] = "src/cli.lua",
            ["luainstaller"] = "src/cli.lua",
        },
    },
}
