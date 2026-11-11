# Exercise the real pinned-source transaction without accessing the network.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("luainstaller-download-test-" + [guid]::NewGuid().ToString('N'))
$SourceCache = $fixtureRoot
$null = New-Item -ItemType Directory -Path $SourceCache
$fixtureSource = 'pinned-source-fixture'
$fixtureFile = Join-Path $fixtureRoot 'expected'
[IO.File]::WriteAllText($fixtureFile, $fixtureSource, (New-Object Text.UTF8Encoding($false)))
$expected = (Get-FileHash -LiteralPath $fixtureFile -Algorithm SHA256).Hash
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot '../tools/test-lua-versions.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw 'matrix driver has PowerShell syntax errors' }
$definition = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Stage-Source'
}, $true)
# Only execute this repository-owned function, not the matrix's main program.
Invoke-Expression $definition.Extent.Text
$script:mode = 'retry'
$script:requests = 0
$script:curlCalled = $false
function Invoke-WebRequest {
    param([switch]$UseBasicParsing, [string]$Uri, [string]$OutFile, [int]$TimeoutSec)
    $script:requests++
    if ($script:mode -eq 'retry' -and $script:requests -eq 1) { throw 'fixture transient network failure' }
    if ($script:mode -in @('fallback','failure')) { throw 'fixture unavailable network' }
    $content = if ($script:mode -eq 'mismatch') { 'wrong-source' } else { $fixtureSource }
    [IO.File]::WriteAllText($OutFile, $content, (New-Object Text.UTF8Encoding($false)))
}
function curl.exe {
    $script:curlCalled = $true
    $outputIndex = [Array]::IndexOf($args, '--output')
    if ($outputIndex -lt 0) { throw 'curl fallback did not name its private output' }
    [IO.File]::WriteAllText($args[$outputIndex + 1], $fixtureSource, (New-Object Text.UTF8Encoding($false)))
    $global:LASTEXITCODE = if ($script:mode -eq 'failure') { 7 } else { 0 }
}
try {
    Stage-Source 'retry' 'https://invalid.example/fixture' $expected
    if ($script:requests -ne 2) { throw 'transient request was not retried' }
    Stage-Source 'retry' 'https://invalid.example/fixture' $expected
    if ($script:requests -ne 2) { throw 'verified cache was downloaded again' }
    $script:mode = 'fallback'
    Stage-Source 'fallback' 'https://invalid.example/fixture' $expected
    if (-not $script:curlCalled) { throw 'curl fallback was not used' }
    foreach ($mode in @('mismatch','failure')) {
        $script:mode = $mode
        $rejected = $false
        try { Stage-Source $mode 'https://invalid.example/fixture' $expected } catch { $rejected = $true }
        if (-not $rejected -or (Test-Path -LiteralPath (Join-Path $SourceCache $mode))) {
            throw "invalid source was published: $mode"
        }
    }
    if (@(Get-ChildItem -LiteralPath $SourceCache -Filter '*.part.*').Count -ne 0) {
        throw 'failed download left partial material'
    }
    'pinned Windows download recovery ok'
} finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
}
