# Codecux

Codecux is a Windows-first CLI for saving named Codex/OpenAI profiles and switching between them locally.

Once a profile is saved, you can swap accounts without repeating the full login flow every time. Codecux is built for Codex CLI first, can keep OpenCode in sync when you use it, and also works with the Codex desktop app after a relaunch.

## What Codecux Is For

- Switching between personal, work, test, or quota-separated OpenAI accounts on one Windows machine
- Keeping account switching local instead of relying on browser sessions or manual file edits
- Reusing saved profiles across Codex CLI, optional OpenCode, and the Codex desktop app

## Requirements

- Windows
- PowerShell 5.1 or PowerShell 7
- Codex CLI installed and working first. The `codex` command must already work on your machine.
- OpenCode is optional

Important:

- Codex CLI is required for OAuth-based profile saving because Codecux needs Codex auth data, including the `id_token`.
- OpenCode is optional. If it is installed, `cux use <name>` keeps it aligned with the selected profile.
- The Codex desktop app is also supported. You can switch with `cux use <name>` without closing the app first.

## What Codecux Changes

- Saves profiles under `%USERPROFILE%\.cux`
- Switches the active Codex auth by writing `%USERPROFILE%\.codex\auth.json`
- Also updates OpenCode auth when OpenCode is installed
- Leaves Codex CLI config such as `%USERPROFILE%\.codex\config.toml` alone
- Stores profiles in a canonical local format so switching stays predictable

## Install

1. Install Codex CLI first and confirm `codex` works in a terminal.
2. Optionally install OpenCode if you want it to switch together with Codex.
3. Open PowerShell in this repository.
4. Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install.ps1
```

5. Open a new PowerShell or CMD window.
6. Verify the install:

```powershell
cux help
```

The install script:

- writes `cux.cmd` into `%LOCALAPPDATA%\Microsoft\WindowsApps`
- creates the local Codecux store if it does not exist
- registers PowerShell tab completion for both Windows PowerShell and PowerShell 7

If the shim or profile integration goes missing later, run:

```powershell
cux doctor --fix
```

To remove the shell integration again, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\uninstall.ps1
```

## Quick Start

Save your first account:

```powershell
codex login
cux add personal
```

Save another account:

```powershell
codex login
cux add work
```

Switch any time:

```powershell
cux use personal
cux current
```

You do not need to align OpenCode before `cux add`. Codecux now uses the current Codex login as the source of truth when saving a profile.

## Using Codecux With The Codex Desktop App

1. Save your profiles with `cux add <name>`.
2. Switch to the profile you want with `cux use <name>`.
3. Keep using the Codex desktop app with the newly selected profile.

After the profile is saved once, you do not need to manually log into the Codex desktop app for each switch.

## Common Commands

```text
cux add <name>
cux add <name> --api-key
cux list
cux use <name>
cux current
cux rename <old> <new>
cux remove <name>
cux status
cux doctor
cux doctor --fix
cux dashboard
cux dash
cux help
```

## Notes And Limitations

- Duplicate account saves are rejected.
- `cux add` saves the current live Codex login and can also read OpenCode when useful.
- OpenCode-only OAuth is not enough to create a shared OAuth profile because Codex CLI requires the Codex `id_token`.
- API-key profiles are supported, but the main workflow is OAuth profile switching.
- `--api-key-value` works, but it is less safe than `$env:OPENAI_API_KEY` or the interactive prompt because shell history and process listings can expose it.
- `cux doctor` reports structured install/auth checks and recommends the next action for anything that looks off.
- `cux doctor --fix` repairs the Codecux-owned shim, shell profile blocks, and local store directories.
- `scripts/uninstall.ps1` removes the Codecux shim and profile blocks; add `-RemoveStore` if you also want `%USERPROFILE%\.cux` deleted.
- `cux dashboard` opens in a separate maximized PowerShell window, closes the originating console, and shows saved-profile status plus quota probes.
- `cux dash` is a direct alias for `cux dashboard` and uses the same console-handoff behavior.
- Dashboard keys: `Up/Down` select, `U` or `Enter` switch profile, `R` refresh all profiles, `Q` quit.
