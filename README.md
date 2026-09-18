# dotclaude

Claude Code config files.

The repo is the source of truth. `~/.claude` gets **symlinks** pointing back
here, so editing a script in the repo changes the live config immediately and
`git status` shows every drift. Only `settings.json` is handled differently: it
is patched in place with `jq` instead of being linked (see
[Why settings.json is not symlinked](#why-settingsjson-is-not-symlinked)).

## Contents

All of these live in [`src/asset`](src/asset) and get linked into `~/.claude`:

| File | What it does |
| --- | --- |
| `hook.ps1` | Hook dispatcher. Reads the hook JSON once, then runs every `hook-*.ps1` next to it whose `# events:` directive matches. Optional — see [Dispatcher wiring](#optional-dispatcher-wiring). |
| `hook-sound.ps1` | Plays a `.wav` on `Notification`. Event-to-sound table at the top of the file. |
| `hook-spinnerverbs.ps1` | On `SessionStart`, syncs `spinner-verbs.txt` into `settings.json` (`spinnerVerbs.verbs`). Splices only the array, so the rest of the file stays byte-identical. |
| `statusline.ps1` | Status line dispatcher. Runs every `statusline-*.ps1` next to it and joins the segments. |
| `statusline-cache.ps1` | Status line segment: context window usage, prompt-cache hit rate, estimated savings, per-turn cache traffic. |
| `spinner-verbs.txt` | The spinner verb list, one per line. |

[`src/install.ps1`](src/install.ps1) sits one level up from them and is not
linked: only the contents of `src/asset` go into `~/.claude`.

## Requirements

- Windows with PowerShell 7 (`pwsh`)
- [`jq`](https://jqlang.org/) — `winget install jqlang.jq`
- Permission to create symlinks: either **Settings > System > For developers >
  Developer Mode: On**, or run the install from an elevated pwsh

## Install

Clone the repo anywhere (the symlinks point back at wherever it lands), then
from the repo root:

```bash
pwsh -NoProfile -File .\src\install.ps1
```

The script:

1. Symlinks every file in `src/asset` into `~/.claude`.
2. Backs up `settings.json` to `settings.json.bak-<timestamp>`, then merges the
   `hooks` and `statusLine` blocks into it with `jq`. Unrelated keys — and hook
   events this repo does not own — are preserved; jq reformats the whole file
   with two-space indentation.
3. Runs `hook-spinnerverbs.ps1` once so the verb list is populated immediately.

It is safe to re-run: existing links are reported and left alone, and the hook
entries are replaced rather than appended. Restart Claude Code afterwards.

Switches:

- `-ClaudeDir <path>` — target a different Claude Code home (defaults to
  `$env:USERPROFILE\.claude`). Useful for a dry run against a throwaway
  directory.
- `-Force` — a real file (or a symlink pointing somewhere else) already sits at
  the target name. Real files are moved to `<name>.bak-<timestamp>` first.

## Manual symlinking

Equivalent to step 1 of the script, from an elevated pwsh or with Developer Mode
on:

```bash
Get-ChildItem .\src\asset -File | ForEach-Object { New-Item -ItemType SymbolicLink -Path (Join-Path $env:USERPROFILE ".claude\$($_.Name)") -Value $_.FullName }
```

Without PowerShell, one file at a time from `cmd`:

```bash
mklink "%USERPROFILE%\.claude\statusline.ps1" "C:\git\sbaker\dotclaude\src\asset\statusline.ps1"
```

Then add the two blocks below to `~/.claude/settings.json` by hand.

## Settings blocks

These are exactly what `src/install.ps1` merges in. The paths follow `-ClaudeDir`,
so on another account they point at that profile instead.

```json
"hooks": {
  "SessionStart": [
    {
      "matcher": "startup",
      "hooks": [
        {
          "type": "command",
          "command": "pwsh -NoProfile -ExecutionPolicy Bypass -File \"C:\\Users\\sbaker\\.claude\\hook-spinnerverbs.ps1\"",
          "async": true
        }
      ]
    }
  ],
  "Notification": [
    {
      "hooks": [
        {
          "type": "command",
          "command": "pwsh -NoProfile -ExecutionPolicy Bypass -File \"C:\\Users\\sbaker\\.claude\\hook-sound.ps1\"",
          "async": true
        }
      ]
    }
  ]
}
```

```json
"statusLine": {
  "type": "command",
  "command": "pwsh -NoProfile -ExecutionPolicy Bypass -File \"C:\\Users\\sbaker\\.claude\\statusline.ps1\"",
  "padding": 0
}
```

The installer also seeds `"spinnerVerbs": { "verbs": [] }` when the key is
missing — `hook-spinnerverbs.ps1` refuses to sync into a `settings.json` that
has no `spinnerVerbs` block.

## Per-machine edits

- **Sound file** — `hook-sound.ps1` hardcodes the `.wav` path in its `$sounds`
  table. Point it at a file that exists on the machine; a missing file falls
  back to the system asterisk sound.
- **Spinner verbs** — edit `src/asset/spinner-verbs.txt`. Blank lines and lines
  starting with `#` are ignored, each line is trimmed, `\n` and `\r\n` become
  real line breaks, `\s` inserts a literal space, `\\` a backslash. Changes land
  on the next session start.
- **Cache pricing** — `statusline-cache.ps1` assumes the 5-minute cache TTL
  (1.25x write multiplier). Set `CLAUDE_CACHE_WRITE_MULT`, or
  `ENABLE_PROMPT_CACHING_1H=1`, to change it.

## Optional dispatcher wiring

The default wiring points each event straight at its hook script. `hook.ps1` is
an alternative: wire one entry per event at the dispatcher, and it fans the
payload out to every `hook-*.ps1` sitting next to it, in name order and
in-process (no extra `pwsh` startup per hook).

```json
"hooks": {
  "Notification": [
    {
      "hooks": [
        {
          "type": "command",
          "command": "pwsh -NoProfile -ExecutionPolicy Bypass -File \"C:\\Users\\sbaker\\.claude\\hook.ps1\"",
          "async": true
        }
      ]
    }
  ]
}
```

A child script picks its events with a directive in its first 20 lines:

```
# events: Notification, SessionStart
```

No directive, or `# events: *`, means every event. With this wiring, adding a
hook is just dropping a `hook-<name>.ps1` into `src/asset` and re-running the
install — no settings change. A child exiting 2 blocks the action and the
dispatcher exits 2 too.

Do not wire both styles for the same event: the hook would fire twice.

`statusline.ps1` works the same way for `statusline-*.ps1` segments and is
always wired as a dispatcher. Its `$order` and `$skip` arrays at the top control
segment order and exclusions.

## Uninstall

Remove the links and put the old settings back:

```bash
Get-ChildItem .\src\asset -File | ForEach-Object { $p = Join-Path $env:USERPROFILE ".claude\$($_.Name)"; if ((Get-Item $p -Force -ErrorAction SilentlyContinue).LinkType -eq 'SymbolicLink') { Remove-Item $p -Force } }
```

```bash
Copy-Item "$env:USERPROFILE\.claude\settings.json.bak-<timestamp>" "$env:USERPROFILE\.claude\settings.json" -Force
```

Deleting a symlink removes the link, not the file in the repo.
