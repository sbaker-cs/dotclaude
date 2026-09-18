#!/usr/bin/env pwsh
# Claude Code hook dispatcher.
# Reads the hook JSON on stdin once, then hands the same payload to every
# hook-*.ps1 child next to this file whose event filter matches.
#
# Wire one entry per event in settings.json, all pointing here:
#   {
#     "type": "command",
#     "command": "pwsh -NoProfile -ExecutionPolicy Bypass -File \"C:\\Users\\sbaker\\.claude\\hook.ps1\"",
#     "async": true
#   }
#
# A child declares the events it wants with a directive in its first 20 lines:
#   # events: Notification, SessionStart
# Omit the directive (or use "# events: *") to run on every event.
#
# Children run in-process, so no extra pwsh startup per hook. Their stdout is
# collected and re-emitted; their stderr passes straight through. A child that
# exits 2 blocks the action, and the dispatcher exits 2 as well.

$ErrorActionPreference = 'Continue'

# Names to exclude entirely, without the "hook-" prefix or ".ps1".
$skip = @()

$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }

$raw = ''
try { $raw = [Console]::In.ReadToEnd() } catch { }

$evt = ''
if (-not [string]::IsNullOrWhiteSpace($raw)) {
    try { $evt = [string]($raw | ConvertFrom-Json).hook_event_name } catch { }
}
if ([string]::IsNullOrWhiteSpace($evt) -and $env:CLAUDE_HOOK_EVENT) { $evt = $env:CLAUDE_HOOK_EVENT }

$skipKeys = @($skip | ForEach-Object { "hook-$_" })
$children = @(
    Get-ChildItem -LiteralPath $root -Filter 'hook-*.ps1' -File |
        Sort-Object Name |
        Where-Object { $_.BaseName -notin $skipKeys }
)

function Test-EventMatch([string]$path, [string]$name) {
    $head = @(Get-Content -LiteralPath $path -TotalCount 20 -ErrorAction SilentlyContinue)
    $line = $head | Where-Object { $_ -match '^\s*#\s*events\s*:' } | Select-Object -First 1
    if (-not $line) { return $true }
    $list = ($line -replace '^\s*#\s*events\s*:', '').Split(',') |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ }
    if ($list -contains '*') { return $true }
    if ([string]::IsNullOrWhiteSpace($name)) { return $false }
    return [bool]($list | Where-Object { $_ -eq $name })
}

# Each child consumes stdin, so replay the payload from a fresh reader per call.
$stdin = [Console]::In
$outputs = @()
$blocked = $false

foreach ($c in $children) {
    if (-not (Test-EventMatch $c.FullName $evt)) { continue }
    try {
        [Console]::SetIn([System.IO.StringReader]::new($raw))
        $global:LASTEXITCODE = 0
        $out = $raw | & $c.FullName
        $code = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
        $text = (@($out) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ }) -join "`n"
        if (-not [string]::IsNullOrWhiteSpace($text)) { $outputs += $text.TrimEnd("`r", "`n") }
        if ($code -eq 2) { $blocked = $true }
    } catch {
        [Console]::Error.WriteLine("hook.ps1: $($c.Name) failed: $($_.Exception.Message)")
    }
}

[Console]::SetIn($stdin)

if ($outputs.Count -gt 0) { Write-Output ($outputs -join "`n") }
if ($blocked) { exit 2 }
exit 0
