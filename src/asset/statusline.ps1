#!/usr/bin/env pwsh
# Claude Code status line dispatcher.
# Reads the statusline JSON on stdin once, then hands the same payload to every
# child status line script and joins their output.
#
# Wire it up in settings.json:
#   "statusLine": {
#     "type": "command",
#     "command": "pwsh -NoProfile -ExecutionPolicy Bypass -File \"C:\\Users\\sbaker\\.claude\\statusline.ps1\""
#   }
#
# Children are every statusline-*.ps1 sitting next to this file. Each one reads
# the JSON from stdin ([Console]::In.ReadToEnd() or $input) and writes its
# segment to stdout, exactly as it would if wired up directly. They run
# in-process, so adding a script costs no extra pwsh startup.

$ErrorActionPreference = 'Continue'

# Separator between child segments. "`n" gives each script its own line;
# " | " keeps everything on one line.
$separator = "`n"

# Preferred order, by name without the "statusline-" prefix and ".ps1".
# Anything not listed runs afterwards, alphabetically.
$order = @('cache')

# Names to exclude entirely (same naming as $order).
$skip = @()

$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }

$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

$orderKeys = @($order | ForEach-Object { "statusline-$_" })
$skipKeys  = @($skip  | ForEach-Object { "statusline-$_" })

$all = @(Get-ChildItem -LiteralPath $root -Filter 'statusline-*.ps1' -File | Sort-Object Name)
$ordered = @(foreach ($k in $orderKeys) { $all | Where-Object { $_.BaseName -eq $k } })
$rest    = @($all | Where-Object { $_.BaseName -notin $orderKeys })
$scripts = @($ordered + $rest | Where-Object { $_.BaseName -notin $skipKeys })

# Each child consumes stdin, so replay the payload from a fresh reader per call.
$stdin = [Console]::In
$segments = @(foreach ($s in $scripts) {
    try {
        [Console]::SetIn([System.IO.StringReader]::new($raw))
        $out = $raw | & $s.FullName 2>$null
        $text = (@($out) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ }) -join "`n"
        if (-not [string]::IsNullOrWhiteSpace($text)) { $text.TrimEnd("`r", "`n") }
    } catch { }
})
[Console]::SetIn($stdin)

if ($segments.Count -gt 0) { Write-Output ($segments -join $separator) }
exit 0
