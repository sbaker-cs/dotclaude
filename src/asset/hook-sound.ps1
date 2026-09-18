#!/usr/bin/env pwsh
# events: *
#
# Plays a notification sound. Run by hook.ps1 (the dispatcher), which feeds the
# hook JSON on stdin.
#
# The $sounds table below is the single source of truth: an event with no entry
# there plays nothing and exits immediately. That is why the directive above is
# "*" - add an event by adding one line to the table, nothing else.

$ErrorActionPreference = 'Continue'

$raw = ''
try { $raw = [Console]::In.ReadToEnd() } catch { }

$evt = ''
if (-not [string]::IsNullOrWhiteSpace($raw)) {
    try { $evt = [string]($raw | ConvertFrom-Json).hook_event_name } catch { }
}

# event name -> wav file. No entry means no sound for that event.
$sounds = @{
    Notification = 'C:\Users\sbaker\Music\hook.wav'
}

if ([string]::IsNullOrWhiteSpace($evt) -or -not $sounds.ContainsKey($evt)) { exit 0 }
$wav = $sounds[$evt]

try {
    if (Test-Path -LiteralPath $wav) {
        # PlaySync blocks until the clip finishes, so the process does not exit
        # mid-sound; no Start-Sleep guesswork needed.
        (New-Object System.Media.SoundPlayer $wav).PlaySync()
    } else {
        # Configured event, missing file: beep rather than swallow the notice.
        [Console]::Error.WriteLine("hook-sound: '$wav' not found for $evt, using system sound.")
        [System.Media.SystemSounds]::Asterisk.Play()
        Start-Sleep -Milliseconds 400
    }
} catch { }

exit 0
