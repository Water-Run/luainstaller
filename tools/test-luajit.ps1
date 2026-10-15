[CmdletBinding()]
param(
    [ValidateSet('default', 'lua52compat')][string]$Configuration = 'default',
    [string]$EvidenceDir = (Join-Path $env:TEMP 'luainstaller-luajit-evidence')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Pin = ConvertFrom-StringData (Get-Content (Join-Path $PSScriptRoot 'luajit-version.txt') -Raw)
if ($Pin.commit -notmatch '^[0-9a-f]{40}$' -or $Pin.sha256 -notmatch '^[0-9a-f]{64}$') {
    throw 'invalid LuaJIT source pin'
}
$WorkRoot = Join-Path $env:TEMP ('luainstaller-luajit-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($WorkRoot) | Out-Null
if (Test-Path -LiteralPath $EvidenceDir) {
    $item = Get-Item -LiteralPath $EvidenceDir
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'evidence directory must be a real directory'
    }
} else { [IO.Directory]::CreateDirectory($EvidenceDir) | Out-Null }
$Log = Join-Path $EvidenceDir ($Configuration + '-' + [guid]::NewGuid().ToString('N') + '.log')

function Invoke-Logged([string]$Program, [string[]]$Arguments) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Program @Arguments 2>&1 | Out-File -FilePath $Log -Append -Encoding utf8
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previous }
    if ($code -ne 0) { throw "$Program failed with exit code $code; see $Log" }
}

function Initialize-Msvc {
    $programFiles = ${env:ProgramFiles(x86)}
    $vswhere = Join-Path $programFiles 'Microsoft Visual Studio\Installer\vswhere.exe'
    $installation = (& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath).Trim()
    $toolVersion = (Get-Content (Join-Path $installation 'VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt') -Raw).Trim()
    $tools = Join-Path $installation "VC\Tools\MSVC\$toolVersion"
    $sdk = Join-Path $programFiles 'Windows Kits\10'
    $sdkVersion = Get-ChildItem (Join-Path $sdk 'Include') -Directory |
        Where-Object { Test-Path (Join-Path $_.FullName 'um\Windows.h') } |
        Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty Name
    if (-not $sdkVersion) { throw 'Windows SDK was not found' }
    $env:VCINSTALLDIR = Join-Path $installation 'VC'
    $binary = Join-Path $tools 'bin\Hostx64\x64'
    $env:LUAI_CC = Join-Path $binary 'cl.exe'
    $env:CC = $env:LUAI_CC
    $env:PATH = @($binary, (Join-Path $sdk "bin\$sdkVersion\x64"),
        "$env:SystemRoot\System32", $env:SystemRoot) -join ';'
    $env:INCLUDE = @((Join-Path $tools 'include'), (Join-Path $sdk "Include\$sdkVersion\ucrt"),
        (Join-Path $sdk "Include\$sdkVersion\shared"), (Join-Path $sdk "Include\$sdkVersion\um")) -join ';'
    $env:LIB = @((Join-Path $tools 'lib\x64'), (Join-Path $sdk "Lib\$sdkVersion\ucrt\x64"),
        (Join-Path $sdk "Lib\$sdkVersion\um\x64")) -join ';'
}

try {
    "LuaJIT source: $($Pin.commit)`nSHA256: $($Pin.sha256)`nConfiguration: $Configuration" |
        Out-File -FilePath $Log -Encoding utf8
    $archive = Join-Path $WorkRoot 'source.tar.gz'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing -Uri "https://codeload.github.com/LuaJIT/LuaJIT/tar.gz/$($Pin.commit)" -OutFile $archive
    if ((Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Pin.sha256) {
        throw 'LuaJIT source digest mismatch'
    }
    Invoke-Logged 'tar.exe' @('-xzf', $archive, '-C', $WorkRoot)
    Initialize-Msvc
    "Compiler: $env:LUAI_CC" | Out-File -FilePath $Log -Append -Encoding utf8
    Invoke-Logged $env:LUAI_CC @('/?')
    $source = Join-Path $WorkRoot "LuaJIT-$($Pin.commit)\src"
    $prefix = Join-Path $WorkRoot 'prefix'
    foreach ($directory in @($prefix, "$prefix\lib", "$prefix\include", "$prefix\lua\jit")) {
        [IO.Directory]::CreateDirectory($directory) | Out-Null
    }
    $flags = if ($Configuration -eq 'lua52compat') { ' lua52compat' } else { '' }
    Push-Location $source
    try {
        # Match the release matrix's static CRT policy for distributed DLLs.
        $buildScript = [IO.File]::ReadAllText((Join-Path $source 'msvcbuild.bat'))
        if (-not $buildScript.Contains('/DLUA_BUILD_AS_DLL /MD')) { throw 'unexpected LuaJIT MSVC build flags' }
        [IO.File]::WriteAllText((Join-Path $source 'msvcbuild.bat'), $buildScript.Replace('/MD', '/MT'),
            [Text.Encoding]::ASCII)
        'MSVC CRT: /MT (LuaJIT DLL and static archive)' | Out-File -FilePath $Log -Append -Encoding utf8
        Invoke-Logged $env:ComSpec @('/d', '/c', ('msvcbuild.bat' + $flags))
        Copy-Item 'luajit.exe', 'lua51.dll' -Destination $prefix
        Copy-Item 'lua51.lib' -Destination "$prefix\lib\lua51.lib"
        Copy-Item 'jit\*.lua' -Destination "$prefix\lua\jit"
        Copy-Item 'lua.h', 'lauxlib.h', 'lualib.h', 'luaconf.h', 'luajit.h' -Destination "$prefix\include"
        Invoke-Logged $env:ComSpec @('/d', '/c', ('msvcbuild.bat' + $flags + ' static'))
        Copy-Item 'lua51.lib' -Destination "$prefix\lib\lua51-static.lib"
    } finally { Pop-Location }
    $env:LUAI_TEST_LUA = Join-Path $prefix 'luajit.exe'
    $env:LUAI_LUA = $env:LUAI_TEST_LUA
    $env:LUAI_LUA_PREFIX = $prefix
    $env:LUA_PATH = ';;'; $env:LUA_CPATH = ';;'
    $env:LUAI_JIT_RELEASE = $Pin.version
    $env:LUAI_JIT_SOURCE_COMMIT = $Pin.commit
    $env:LUAI_JIT_SOURCE_SHA256 = $Pin.sha256
    $env:LUAI_JIT_CONFIGURATION = $Configuration
    Push-Location $ProjectRoot
    try {
        foreach ($suite in Get-Content (Join-Path $PSScriptRoot 'luajit-suites.txt')) {
            if ($suite -notmatch '^[a-z0-9_]+$') { throw 'invalid LuaJIT suite name' }
            "`nRUN $suite" | Out-File -FilePath $Log -Append -Encoding utf8
            Invoke-Logged $env:LUAI_TEST_LUA @("test/$suite.lua")
        }
    } finally { Pop-Location }
    "PASS luainstaller 1.7.0 LuaJIT $($Pin.version) $Configuration" |
        Out-File -FilePath $Log -Append -Encoding utf8
    Get-Content -LiteralPath $Log -Tail 1
} catch {
    Get-Content -LiteralPath $Log -Tail 100
    throw
} finally {
    Remove-Item -LiteralPath $WorkRoot -Recurse -Force
}
