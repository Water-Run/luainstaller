[CmdletBinding()]
param(
    [string]$SourceCache = (Join-Path $env:TEMP 'luainstaller-source-cache'),
    [string]$WorkRoot = (Join-Path $env:TEMP 'luainstaller-lua-matrix'),
    [string]$EvidenceDir = (Join-Path $env:TEMP 'luainstaller-lua-evidence'),
    [string]$HostLabel = $env:COMPUTERNAME,
    [string[]]$VersionFilter = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$LuaRocksVersion = '3.12.2'
$LuaRocksArchive = "luarocks-$LuaRocksVersion-windows-64.zip"
$LuaRocksSha256 = 'D3F4DDDA6926618CADF560170A7C18A5CEEAD5997BA10832CD0E3B624C7DE886'
$Versions = @(
    @{ Version='5.1.5'; Sha256='2640fc56a795f29d28ef15e13c34a47e223960b0240e8cb0a82d9b0738695333' },
    @{ Version='5.2.4'; Sha256='b9e2e4aad6789b3b63a056d442f7b39f0ecfca3ae0f1fc0ae4e9614401b69f4b' },
    @{ Version='5.3.6'; Sha256='fc5fd69bb8736323f026672b1b7235da613d7177e72558893a0bdcd320466d60' },
    @{ Version='5.4.8'; Sha256='4f18ddae154e793e46eeab727c59ef1c0c0c2b744e7b94219710d76f530629ae' },
    @{ Version='5.5.0'; Sha256='57ccc32bbbd005cab75bcc52444052535af691789dba2b9016d5c50640d68b3d' }
)

function Assert-SafeRoot([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'temporary root is empty' }
    $full = [IO.Path]::GetFullPath($Path)
    $temp = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if (-not $full.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([IO.Path]::GetFileName($full) -like 'luainstaller-*')) {
        throw "unsafe temporary root: $full"
    }
    $current = [IO.Path]::GetPathRoot($full)
    foreach ($component in $full.Substring($current.Length) -split '[\/]') {
        if ($component -eq '') { continue }
        $current = [IO.Path]::Combine($current, $component)
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) { break }
        if (-not ($item -is [IO.DirectoryInfo]) -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "unsafe temporary-path ancestor: $current"
        }
    }
    return $full
}

function Remove-SafeTree([string]$Path, [string]$Root) {
    $full = [IO.Path]::GetFullPath($Path)
    $safeRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    if (-not $full.StartsWith($safeRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "refusing to remove path outside matrix root: $full"
    }
    if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
}

function Stage-Source([string]$Name, [string]$Uri, [string]$Expected) {
    $destination = Join-Path $SourceCache $Name
    $item = Get-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
    if ($null -ne $item -and ((-not ($item -is [IO.FileInfo])) -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw "unsafe source-cache entry: $destination"
    }
    if ($null -ne $item -and (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $Expected) {
        Remove-Item -LiteralPath $destination -Force
        $item = $null
    }
    if ($null -eq $item) {
        $part = "$destination.part.$PID"
        if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force }
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $part
            if ((Get-FileHash -LiteralPath $part -Algorithm SHA256).Hash -ne $Expected) {
                throw "SHA-256 mismatch for $Name"
            }
            try {
                [IO.File]::Move($part, $destination)
            } catch [IO.IOException] {
                if (-not (Test-Path -LiteralPath $destination -PathType Leaf) -or
                    (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $Expected) {
                    throw
                }
            }
        } finally {
            if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force }
        }
    }
}

function Invoke-Native([string]$File, [string[]]$Arguments) {
    & $File @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "native command failed ($LASTEXITCODE): $File $($Arguments -join ' ')"
    }
}

function Initialize-Msvc {
    $programFiles = ${env:ProgramFiles(x86)}
    if ([string]::IsNullOrEmpty($programFiles)) { $programFiles = $env:ProgramFiles }
    $vswhere = Join-Path $programFiles 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) { throw 'vswhere.exe was not found' }
    $installation = (& $vswhere -latest -prerelease -products '*' `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath).Trim()
    $toolVersion = (Get-Content -LiteralPath (Join-Path $installation `
        'VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt') -Raw).Trim()
    $tools = Join-Path $installation "VC\Tools\MSVC\$toolVersion"
    $binary = Join-Path $tools 'bin\Hostx64\x64'
    $sdkRoot = Join-Path $programFiles 'Windows Kits\10'
    $sdkVersion = Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'Include') -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'um\Windows.h') } |
        Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty Name
    if ([string]::IsNullOrEmpty($sdkVersion)) { throw 'Windows SDK was not found' }
    $env:PATH = "$binary;$env:SystemRoot\System32;$env:SystemRoot"
    $env:INCLUDE = @(
        (Join-Path $tools 'include'),
        (Join-Path $sdkRoot "Include\$sdkVersion\ucrt"),
        (Join-Path $sdkRoot "Include\$sdkVersion\shared"),
        (Join-Path $sdkRoot "Include\$sdkVersion\um")
    ) -join ';'
    $env:LIB = @(
        (Join-Path $tools 'lib\x64'),
        (Join-Path $sdkRoot "Lib\$sdkVersion\ucrt\x64"),
        (Join-Path $sdkRoot "Lib\$sdkVersion\um\x64")
    ) -join ';'
    return @{ Cl=(Join-Path $binary 'cl.exe'); Link=(Join-Path $binary 'link.exe') }
}

function Build-Lua([hashtable]$Spec, [hashtable]$Msvc) {
    $version = $Spec.Version
    $abi = ($version -split '\.')[0..1] -join '.'
    $compact = $abi.Replace('.', '')
    $prefix = Join-Path $WorkRoot "lua-$version"
    $lua = Join-Path $prefix 'lua.exe'
    $required = @(
        $lua,
        (Join-Path $prefix "lua$compact.dll"),
        (Join-Path $prefix "lua$compact.lib"),
        (Join-Path $prefix 'include\lua.h'),
        (Join-Path $prefix 'include\luaconf.h'),
        (Join-Path $prefix 'include\lualib.h'),
        (Join-Path $prefix 'include\lauxlib.h')
    )
    $complete = @($required | Where-Object {
        -not (Test-Path -LiteralPath $_ -PathType Leaf)
    }).Count -eq 0
    if ($complete) {
        $reported = (& $lua -e 'io.write(_VERSION)')
        if ($reported -eq "Lua $abi") { return $prefix }
    }
    $sourceParent = Join-Path $WorkRoot "source-lua-$version"
    Remove-SafeTree $prefix $WorkRoot
    Remove-SafeTree $sourceParent $WorkRoot
    $null = New-Item -ItemType Directory -Path $sourceParent
    Invoke-Native (Join-Path $env:SystemRoot 'System32\tar.exe') `
        @('-xzf', (Join-Path $SourceCache "lua-$version.tar.gz"), '-C', $sourceParent) | Out-Host
    $source = Join-Path $sourceParent "lua-$version\src"
    $objects = Join-Path $sourceParent 'objects'
    $null = New-Item -ItemType Directory -Path $objects
    $objectFiles = @()
    foreach ($file in Get-ChildItem -LiteralPath $source -Filter '*.c' -File |
        Where-Object { $_.Name -notin @('lua.c', 'luac.c') }) {
        $object = Join-Path $objects ($file.BaseName + '.obj')
        Invoke-Native $Msvc.Cl @('/nologo','/c','/O2','/MD','/DLUA_BUILD_AS_DLL',
            "/I$source", "/Fo$object", $file.FullName) | Out-Host
        $objectFiles += $object
    }
    $null = New-Item -ItemType Directory -Path $prefix
    $null = New-Item -ItemType Directory -Path (Join-Path $prefix 'bin')
    $null = New-Item -ItemType Directory -Path (Join-Path $prefix 'include')
    $dll = Join-Path $prefix "lua$compact.dll"
    $library = Join-Path $prefix "lua$compact.lib"
    Invoke-Native $Msvc.Link (@('/nologo','/DLL','/INCREMENTAL:NO','/Brepro',
        "/OUT:$dll", "/IMPLIB:$library") + $objectFiles) | Out-Host
    $luaObject = Join-Path $objects 'lua.obj'
    Invoke-Native $Msvc.Cl @('/nologo','/c','/O2','/MD',"/I$source",
        "/Fo$luaObject",(Join-Path $source 'lua.c')) | Out-Host
    Invoke-Native $Msvc.Link @('/nologo','/INCREMENTAL:NO','/Brepro',
        "/OUT:$lua",$luaObject,$library) | Out-Host
    Copy-Item -LiteralPath $dll -Destination (Join-Path $prefix "bin\lua$compact.dll")
    foreach ($header in @('lua.h','luaconf.h','lualib.h','lauxlib.h','lua.hpp')) {
        $headerPath = Join-Path $source $header
        if (Test-Path -LiteralPath $headerPath -PathType Leaf) {
            Copy-Item -LiteralPath $headerPath -Destination (Join-Path $prefix 'include')
        }
    }
    if ((& $lua -e 'io.write(_VERSION)') -ne "Lua $abi") { throw "Lua $version build mismatch" }
    return $prefix
}

function Write-LuaRocksConfig([string]$Version, [string]$LuaPrefix) {
    $abi = ($Version -split '\.')[0..1] -join '.'
    $compact = $abi.Replace('.', '')
    $config = Join-Path $WorkRoot "luarocks-$Version-config.lua"
    $root = $LuaPrefix.Replace('\','/')
    [IO.File]::WriteAllText($config, @"
lua_version = "$abi"
variables = {
   LUA_DIR = [[$root]], LUA_BINDIR = [[$root]],
   LUA_INCDIR = [[$root/include]], LUA_LIBDIR = [[$root]],
   LUA_LIBNAME = [[lua$compact]],
}
"@, (New-Object Text.UTF8Encoding($false)))
    return $config
}

function Run-Version([hashtable]$Spec, [hashtable]$Msvc, [string]$LuaRocks) {
    $version = $Spec.Version
    $abi = ($version -split '\.')[0..1] -join '.'
    $luaPrefix = Build-Lua $Spec $Msvc
    $lua = Join-Path $luaPrefix 'lua.exe'
    $config = Write-LuaRocksConfig $version $luaPrefix
    $env:LUAROCKS_CONFIG = $config
    $env:LUAI_TEST_LUA = $lua
    $env:LUAI_LUA_PREFIX = $luaPrefix
    $env:LUA_PATH = ''
    $env:LUA_CPATH = ''
    $env:PATH = "$(Split-Path -Parent $LuaRocks);$luaPrefix;$luaPrefix\bin;$env:PATH"
    Set-Location $ProjectRoot
    foreach ($file in Get-ChildItem src -Recurse -Filter '*.lua' -File) {
        $env:LUAI_SYNTAX_FILE = $file.FullName
        Invoke-Native $lua @('-e','assert(loadfile(os.getenv([[LUAI_SYNTAX_FILE]])))')
    }
    foreach ($test in @('version_contract.lua','cli_split_smoke.lua','windows_native.lua','toolchain_native.lua',
        'luarocks_install.lua','native_bundle.lua','onefile_compile_native.lua','native_onefile.lua')) {
        Invoke-Native $lua @((Join-Path 'test' $test))
    }
    Invoke-Native $LuaRocks @('lint','luainstaller-1.0.0-1.rockspec')
    "PASS host=$HostLabel lua=$version abi=Lua $abi"
}

$SourceCache = Assert-SafeRoot $SourceCache
$WorkRoot = Assert-SafeRoot $WorkRoot
$EvidenceDir = Assert-SafeRoot $EvidenceDir
if ($HostLabel -notmatch '^[A-Za-z0-9._-]+$') { throw "unsafe host label: $HostLabel" }
foreach ($root in @($SourceCache,$WorkRoot,$EvidenceDir)) {
    if (-not (Test-Path -LiteralPath $root)) { $null = New-Item -ItemType Directory -Path $root }
}
Stage-Source $LuaRocksArchive `
    "https://luarocks.github.io/luarocks/releases/$LuaRocksArchive" $LuaRocksSha256
$SelectedVersions = if ($VersionFilter.Count -eq 0) {
    $Versions
} else {
    $Versions | Where-Object { $_.Version -in $VersionFilter }
}
if (@($SelectedVersions).Count -eq 0) { throw 'VersionFilter selected no pinned Lua version' }
foreach ($spec in $SelectedVersions) {
    Stage-Source "lua-$($spec.Version).tar.gz" `
        "https://www.lua.org/ftp/lua-$($spec.Version).tar.gz" $spec.Sha256
}
$luaRocksRoot = Join-Path $WorkRoot "luarocks-$LuaRocksVersion-windows-64"
if (-not (Test-Path -LiteralPath (Join-Path $luaRocksRoot 'luarocks.exe') -PathType Leaf)) {
    Remove-SafeTree $luaRocksRoot $WorkRoot
    Expand-Archive -LiteralPath (Join-Path $SourceCache $LuaRocksArchive) -DestinationPath $WorkRoot
}
$luaRocks = Join-Path $luaRocksRoot 'luarocks.exe'
$msvc = Initialize-Msvc
foreach ($spec in $SelectedVersions) {
    $log = Join-Path $EvidenceDir "$HostLabel-lua-$($spec.Version).log"
    try {
        $result = Run-Version $spec $msvc $luaRocks 2>&1 | Tee-Object -FilePath $log
        $result | Select-Object -Last 1
    } catch {
        $_ | Out-String | Add-Content -LiteralPath $log
        Get-Content -LiteralPath $log
        throw
    }
}
