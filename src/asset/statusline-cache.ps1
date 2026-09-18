#!/usr/bin/env pwsh
# Claude Code status line: prompt-caching performance monitor.
# Reads the statusline JSON on stdin and reports cache hit rate, estimated
# savings versus an uncached session, and per-turn cache traffic.
#
# Wire it up in settings.json:
#   "statusLine": {
#     "type": "command",
#     "command": "pwsh -NoProfile -ExecutionPolicy Bypass -File \"C:\\Users\\sbaker\\.claude\\statusline-cache.ps1\""
#   }

$ErrorActionPreference = 'Stop'

# Cache-write price multiplier relative to base input tokens.
# 1.25 for the 5-minute TTL, 2.0 for the 1-hour TTL. Cache reads are 0.1x.
$writeMult = 1.25
if ($env:CLAUDE_CACHE_WRITE_MULT) {
    $writeMult = [double]$env:CLAUDE_CACHE_WRITE_MULT
} elseif ($env:ENABLE_PROMPT_CACHING_1H -eq '1' -and $env:FORCE_PROMPT_CACHING_5M -ne '1') {
    $writeMult = 2.0
}
$readMult = 0.1

$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
$d = $raw | ConvertFrom-Json

$cw = $d.context_window
$u = $cw.current_usage
$tIn    = [double]($u.input_tokens                ?? 0)
$tWrite = [double]($u.cache_creation_input_tokens ?? 0)
$tRead  = [double]($u.cache_read_input_tokens     ?? 0)

# --- context window occupancy ---------------------------------------------------
# Every input token of the last request is what currently sits in the window.
$ctxUsed = [double]($cw.total_input_tokens ?? ($tIn + $tWrite + $tRead))
$ctxSize = [double]($cw.context_window_size ?? 0)
$ctxPct  = if ($null -ne $cw.used_percentage) {
    [double]$cw.used_percentage
} elseif ($ctxSize -gt 0) {
    100.0 * $ctxUsed / $ctxSize
} else { -1.0 }

# --- accumulate session totals -------------------------------------------------
# The status line re-runs on events that are not new API responses (permission
# mode change, vim toggle, refresh timer), so only accumulate when the usage
# numbers actually changed.
$sIn = $tIn; $sWrite = $tWrite; $sRead = $tRead; $turns = 1; $rebuilds = 0

if ($d.session_id) {
    $stateDir = Join-Path $env:TEMP 'claude-cache-stats'
    if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Force $stateDir | Out-Null }
    $stateFile = Join-Path $stateDir "$($d.session_id).json"

    $s = $null
    if (Test-Path $stateFile) {
        try { $s = Get-Content $stateFile -Raw -Encoding utf8 | ConvertFrom-Json } catch { $s = $null }
    }
    if (-not $s -or $null -eq $s.read) {
        $s = [pscustomobject]@{ sig = ''; input = 0.0; write = 0.0; read = 0.0; turns = 0; rebuilds = 0 }
    }

    $sig = "$tIn/$tWrite/$tRead"
    if ($s.sig -ne $sig) {
        $s.input += $tIn; $s.write += $tWrite; $s.read += $tRead; $s.turns += 1
        # A full prefix invalidation: nothing served from cache on a non-trivial request.
        if ($tRead -eq 0 -and ($tIn + $tWrite) -gt 5000) { $s.rebuilds += 1 }
        $s.sig = $sig
        try { $s | ConvertTo-Json -Compress | Set-Content $stateFile -Encoding utf8 } catch { }
    }

    $sIn = [double]$s.input; $sWrite = [double]$s.write; $sRead = [double]$s.read
    $turns = [int]$s.turns; $rebuilds = [int]$s.rebuilds
}

# --- metrics -------------------------------------------------------------------
$sTotal = $sIn + $sWrite + $sRead
if ($sTotal -le 0) { exit 0 }

# Share of all input tokens served from cache.
$hit = 100.0 * $sRead / $sTotal

# Cost relative to the same session with caching disabled. Rate-independent:
# every term is a multiple of the base input token price.
$uncached = $sTotal
$actual   = $sIn + ($sRead * $readMult) + ($sWrite * $writeMult)
$saved    = 100.0 * (1.0 - ($actual / $uncached))

function Format-Tok([double]$n) {
    if ($n -ge 1e6) { return ('{0:0.0}M' -f ($n / 1e6)) }
    if ($n -ge 1e3) { return ('{0:0.0}k' -f ($n / 1e3)) }
    return ('{0:0}' -f $n)
}

$esc = [char]27
$dim = "$esc[2m"; $rst = "$esc[0m"
$hitColor = if ($hit -ge 80) { "$esc[32m" } elseif ($hit -ge 50) { "$esc[33m" } else { "$esc[31m" }

# Per-turn marker: MISS on a full rebuild, otherwise the cache read volume.
$turnPart = if ($tRead -eq 0 -and ($tIn + $tWrite) -gt 5000) {
    "$esc[31mMISS$rst $(Format-Tok $tWrite) written"
} else {
    "turn r$(Format-Tok $tRead) w$(Format-Tok $tWrite)"
}

$ctxColor = if ($ctxPct -lt 0 -or $ctxPct -lt 50) { "$esc[32m" } elseif ($ctxPct -lt 80) { "$esc[33m" } else { "$esc[31m" }
$ctxPart = if ($ctxSize -gt 0) {
    "ctx $(Format-Tok $ctxUsed)/$(Format-Tok $ctxSize)$(if ($ctxPct -ge 0) { " $('{0:0}' -f $ctxPct)%" })"
} else {
    "ctx $(Format-Tok $ctxUsed)"
}

$parts = @(
    "$ctxColor$ctxPart$rst"
    "$hitColor$('{0:0}' -f $hit)% cached$rst"
    "$esc[36m$('{0:0}' -f $saved)% saved$rst"
    "${dim}r$(Format-Tok $sRead) w$(Format-Tok $sWrite) u$(Format-Tok $sIn)$rst"
    "$dim$turnPart$rst"
)
if ($rebuilds -gt 0) {
    $parts += "$esc[33m$rebuilds rebuild$(if ($rebuilds -ne 1) { 's' })$rst"
}

$model = $d.model.display_name
$model = ($model -replace '\s*\(1M context\)$', '') # remove the (1M context) label
$dir   = Split-Path -Leaf ($d.workspace.current_dir ?? $d.cwd)

Write-Output "$dim$model |$rst $dir $dim|$rst $($parts -join " $dim|$rst ")"
exit 0
