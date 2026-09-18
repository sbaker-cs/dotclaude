#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Installs this repo's Claude Code configuration into ~/.claude.

.DESCRIPTION
    Two steps, both idempotent:

      1. Symlinks every file in src/asset (the directory next to this script)
         into the Claude Code home directory,
         so the repo stays the single source of truth for the scripts.
      2. Merges the "hooks" and "statusLine" blocks into settings.json with jq,
         leaving every other key in that file untouched.

    settings.json itself is never symlinked: Claude Code rewrites it, it holds
    machine-local state, and hook-spinnerverbs.ps1 edits it in place.

.PARAMETER ClaudeDir
    Claude Code home directory. Defaults to $env:USERPROFILE\.claude.

.PARAMETER Force
    Replace files that are already in ClaudeDir. Real files are moved aside to
    <name>.bak-<timestamp> first; symlinks pointing elsewhere are recreated.
    Without this switch, such files are reported and left alone.

.EXAMPLE
    pwsh -NoProfile -File .\src\install.ps1

.EXAMPLE
    pwsh -NoProfile -File .\src\install.ps1 -ClaudeDir "$env:TEMP\claude-test" -Force
#>
[CmdletBinding()]
param(
    [string]$ClaudeDir = (Join-Path $env:USERPROFILE '.claude'),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$utf8 = New-Object Text.UTF8Encoding($false)
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$warnings = 0

function Write-Step([string]$text) { Write-Host "==> $text" -ForegroundColor Cyan }
function Write-Ok([string]$text)   { Write-Host "    ok   $text" -ForegroundColor DarkGray }
function Write-Did([string]$text)  { Write-Host "    done $text" -ForegroundColor Green }
function Write-Warn([string]$text) {
    Write-Host "    warn $text" -ForegroundColor Yellow
    $script:warnings++
}

# --- preflight -----------------------------------------------------------------

Write-Step 'Checking prerequisites'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7+ is required (running $($PSVersionTable.PSVersion)). Run this with pwsh."
}

if (-not (Get-Command jq -ErrorAction SilentlyContinue)) {
    throw 'jq was not found on PATH. Install it with:  winget install jqlang.jq'
}

$assetDir = Join-Path $PSScriptRoot 'asset'
if (-not (Test-Path -LiteralPath $assetDir)) {
    throw "Asset directory not found: $assetDir"
}
if (-not (Test-Path -LiteralPath $ClaudeDir -PathType Container)) {
    throw "Claude Code directory not found: $ClaudeDir (start Claude Code once, or pass -ClaudeDir)"
}

$assets = @(Get-ChildItem -LiteralPath $assetDir -File | Sort-Object Name)
if ($assets.Count -eq 0) { throw "No files to install in $assetDir" }

Write-Ok "pwsh $($PSVersionTable.PSVersion), jq $((& jq --version) -replace '^jq-', '')"
Write-Ok "target $ClaudeDir"

# --- 1. symlinks ----------------------------------------------------------------

Write-Step "Linking $($assets.Count) file(s) into $ClaudeDir"

foreach ($file in $assets) {
    $target = $file.FullName
    $link = Join-Path $ClaudeDir $file.Name
    $existing = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue

    if ($existing) {
        if ($existing.LinkType -eq 'SymbolicLink') {
            $current = @($existing.Target)[0]
            if ($current -and ([IO.Path]::GetFullPath($current) -eq $target)) {
                Write-Ok "$($file.Name) -> already linked"
                continue
            }
            if (-not $Force) {
                Write-Warn "$($file.Name) is a symlink to '$current'; re-run with -Force to repoint it"
                continue
            }
            Remove-Item -LiteralPath $link -Force
        }
        else {
            if (-not $Force) {
                Write-Warn "$($file.Name) exists as a real file; re-run with -Force to back it up and link"
                continue
            }
            $backup = "$link.bak-$stamp"
            Move-Item -LiteralPath $link -Destination $backup
            Write-Ok "$($file.Name) -> backed up to $(Split-Path -Leaf $backup)"
        }
    }

    try {
        New-Item -ItemType SymbolicLink -Path $link -Value $target | Out-Null
        Write-Did "$($file.Name) -> $target"
    }
    catch [UnauthorizedAccessException] {
        throw @"
Creating the symlink for $($file.Name) was denied.
Windows needs one of these to let a normal user create symlinks:
  - Settings > System > For developers > Developer Mode: On
  - or run this script from an elevated (Administrator) pwsh.
"@
    }
}

# --- 2. settings.json ------------------------------------------------------------

Write-Step 'Merging hooks and statusLine into settings.json'

$settingsPath = Join-Path $ClaudeDir 'settings.json'
if (-not (Test-Path -LiteralPath $settingsPath)) {
    [IO.File]::WriteAllText($settingsPath, "{}$([Environment]::NewLine)", $utf8)
    Write-Did 'created an empty settings.json'
}

$settingsBackup = "$settingsPath.bak-$stamp"
Copy-Item -LiteralPath $settingsPath -Destination $settingsBackup
Write-Ok "backed up to $(Split-Path -Leaf $settingsBackup)"

function New-HookCommand([string]$scriptName) {
    $path = Join-Path $ClaudeDir $scriptName
    "pwsh -NoProfile -ExecutionPolicy Bypass -File `"$path`""
}

$additions = [ordered]@{
    hooks = [ordered]@{
        SessionStart = @(
            [ordered]@{
                matcher = 'startup'
                hooks   = @(
                    [ordered]@{
                        type    = 'command'
                        command = New-HookCommand 'hook-spinnerverbs.ps1'
                        async   = $true
                    }
                )
            }
        )
        Notification = @(
            [ordered]@{
                hooks = @(
                    [ordered]@{
                        type    = 'command'
                        command = New-HookCommand 'hook-sound.ps1'
                        async   = $true
                    }
                )
            }
        )
    }
    statusLine = [ordered]@{
        type    = 'command'
        command = New-HookCommand 'statusline.ps1'
        padding = 0
    }
}

# '. * $add[0]' merges recursively through objects, so unrelated keys - and hook
# events this repo does not own - survive. The hook arrays themselves are
# replaced wholesale, which is what keeps re-runs from stacking duplicates.
# spinnerVerbs is seeded only when absent: hook-spinnerverbs.ps1 refuses to sync
# into a settings.json that has no such key.
$filter = '. * $add[0] | .spinnerVerbs = (.spinnerVerbs // {"verbs": []})'

$tempRoot   = [IO.Path]::GetTempPath()
$addFile    = Join-Path $tempRoot "dotclaude-add-$stamp.json"
$filterFile = Join-Path $tempRoot "dotclaude-merge-$stamp.jq"
$outFile    = Join-Path $tempRoot "dotclaude-settings-$stamp.json"

try {
    [IO.File]::WriteAllText($addFile, ($additions | ConvertTo-Json -Depth 10), $utf8)
    [IO.File]::WriteAllText($filterFile, $filter, $utf8)

    # -f and --slurpfile keep the filter and the payload off the command line,
    # so Windows argument quoting cannot mangle either of them.
    $merged = & jq -f $filterFile --slurpfile add $addFile $settingsPath
    if ($LASTEXITCODE -ne 0) { throw "jq failed to merge settings.json (exit $LASTEXITCODE)" }

    [IO.File]::WriteAllText($outFile, (($merged -join [Environment]::NewLine) + [Environment]::NewLine), $utf8)

    & jq empty $outFile
    if ($LASTEXITCODE -ne 0) { throw 'the merged settings.json did not parse; the original was left alone' }

    Move-Item -LiteralPath $outFile -Destination $settingsPath -Force
    Write-Did 'settings.json updated (jq reformats the whole file)'
}
finally {
    foreach ($tmp in @($addFile, $filterFile, $outFile)) {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

# --- 3. spinner verbs -------------------------------------------------------------

Write-Step 'Syncing spinner verbs'

$spinnerHook = Join-Path $ClaudeDir 'hook-spinnerverbs.ps1'
if (Test-Path -LiteralPath $spinnerHook) {
    # The hook owns the parsing rules for spinner-verbs.txt, so run it rather
    # than reimplementing them here. It reports on stderr and never fails hard.
    '' | & pwsh -NoProfile -ExecutionPolicy Bypass -File $spinnerHook 2>&1 |
        ForEach-Object { Write-Ok ([string]$_) }

    $verbCount = @((Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json).spinnerVerbs.verbs).Count
    Write-Did "$verbCount verb(s) in settings.json"
}
else {
    Write-Warn 'hook-spinnerverbs.ps1 is not in place; skipping the verb sync'
}

# --- done ---------------------------------------------------------------------

Write-Host ''
if ($warnings -gt 0) {
    Write-Host "Finished with $warnings warning(s). Restart Claude Code to pick up the changes." -ForegroundColor Yellow
}
else {
    Write-Host 'Done. Restart Claude Code to pick up the changes.' -ForegroundColor Green
}
Write-Host "settings.json backup: $settingsBackup" -ForegroundColor DarkGray
