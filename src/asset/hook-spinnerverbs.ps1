#!/usr/bin/env pwsh
# events: SessionStart
#
# Syncs spinner-verbs.txt into settings.json (spinnerVerbs.verbs), so the verb
# list lives in a plain text file instead of inline JSON. Edit the .txt; this
# script rewrites the JSON array on the next session start.
#
# Only the verbs array is touched: the array span is located and spliced in the
# raw text, so key order, indentation, and everything else in settings.json stay
# byte-identical. No write happens at all when the list already matches.
#
# Nothing is written to stdout - SessionStart stdout is injected into Claude's
# context. Notices go to stderr.

$ErrorActionPreference = 'Continue'

# Drain stdin so the dispatcher's pipe never blocks; the payload is unused here.
try { [void][Console]::In.ReadToEnd() } catch { }

$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }

$txtPath      = Join-Path $root 'spinner-verbs.txt'
$settingsPath = Join-Path $root 'settings.json'

if (-not (Test-Path -LiteralPath $txtPath)) { exit 0 }
if (-not (Test-Path -LiteralPath $settingsPath)) { exit 0 }

function Expand-Escape([string]$s) {
    [regex]::Replace($s, '\\(.)', {
        param($m)
        switch ($m.Groups[1].Value) {
            'n'  { "`n" }
            'r'  { "`r" }
            't'  { "`t" }
            's'  { ' ' }
            '\'  { '\' }
            default { '\' + $m.Groups[1].Value }
        }
    })
}

$verbs = @(
    Get-Content -LiteralPath $txtPath -Encoding utf8 |
        Where-Object { $_ -notmatch '^\s*#' -and $_ -match '\S' } |
        ForEach-Object { Expand-Escape $_.Trim() }
)
if ($verbs.Count -eq 0) {
    [Console]::Error.WriteLine('hook-spinner-verbs: spinner-verbs.txt has no verbs, leaving settings.json alone.')
    exit 0
}

$raw = [IO.File]::ReadAllText($settingsPath)

$cfg = $null
try { $cfg = $raw | ConvertFrom-Json } catch {
    [Console]::Error.WriteLine("hook-spinner-verbs: settings.json is not valid JSON, skipping. $($_.Exception.Message)")
    exit 0
}

$current = @($cfg.spinnerVerbs.verbs)
if ($current.Count -eq $verbs.Count) {
    $same = $true
    for ($i = 0; $i -lt $verbs.Count; $i++) {
        if ($current[$i] -cne $verbs[$i]) { $same = $false; break }
    }
    if ($same) { exit 0 }
}

# --- locate the verbs array in the raw text ------------------------------------
$block = $raw.IndexOf('"spinnerVerbs"')
if ($block -lt 0) {
    [Console]::Error.WriteLine('hook-spinner-verbs: no "spinnerVerbs" key in settings.json; add the block once, then this script keeps it in sync.')
    exit 0
}
$key = $raw.IndexOf('"verbs"', $block)
if ($key -lt 0) {
    [Console]::Error.WriteLine('hook-spinner-verbs: "spinnerVerbs" has no "verbs" array.')
    exit 0
}
$open = $raw.IndexOf('[', $key)
if ($open -lt 0) {
    [Console]::Error.WriteLine('hook-spinner-verbs: could not find the start of the verbs array.')
    exit 0
}

# Walk to the matching bracket, ignoring brackets inside string literals.
$close = -1
$inStr = $false
$esc = $false
$depth = 0
for ($i = $open; $i -lt $raw.Length; $i++) {
    $ch = $raw[$i]
    if ($inStr) {
        if ($esc) { $esc = $false }
        elseif ($ch -eq '\') { $esc = $true }
        elseif ($ch -eq '"') { $inStr = $false }
        continue
    }
    switch ($ch) {
        '"' { $inStr = $true }
        '[' { $depth++ }
        ']' { $depth--; if ($depth -eq 0) { $close = $i } }
    }
    if ($close -ge 0) { break }
}
if ($close -lt 0) {
    [Console]::Error.WriteLine('hook-spinner-verbs: unbalanced verbs array, refusing to write.')
    exit 0
}

# --- render and splice ---------------------------------------------------------
$lineStart = $raw.LastIndexOf("`n", $key)
$baseIndent = ''
if ($lineStart -ge 0) {
    $m = [regex]::Match($raw.Substring($lineStart + 1), '^[ \t]*')
    $baseIndent = $m.Value
}
$itemIndent = $baseIndent + '  '
$nl = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }

$items = $verbs | ForEach-Object { $itemIndent + ($_ | ConvertTo-Json -Compress) }
$array = '[' + $nl + ($items -join (',' + $nl)) + $nl + $baseIndent + ']'

$updated = $raw.Substring(0, $open) + $array + $raw.Substring($close + 1)

# Sanity check before overwriting: the result must still parse, and only the
# verbs array may have changed.
try {
    $check = $updated | ConvertFrom-Json
    if (@($check.spinnerVerbs.verbs).Count -ne $verbs.Count) { throw 'verb count mismatch after splice' }
} catch {
    [Console]::Error.WriteLine("hook-spinner-verbs: splice produced invalid JSON, not writing. $($_.Exception.Message)")
    exit 0
}

$tmp = "$settingsPath.spinner-verbs.tmp"
try {
    [IO.File]::WriteAllText($tmp, $updated, (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $settingsPath -Force
    [Console]::Error.WriteLine("hook-spinner-verbs: synced $($verbs.Count) verbs into settings.json (takes effect next session).")
} catch {
    [Console]::Error.WriteLine("hook-spinner-verbs: write failed: $($_.Exception.Message)")
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

exit 0
