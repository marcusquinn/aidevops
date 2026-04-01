---
mode: subagent
---
# t1748: Add Linux/WSL2 platform support

## Origin

- **Created:** 2026-04-02
- **Session:** claude-code:interactive
- **Created by:** marcusquinn (human)
- **Conversation context:** User asked whether aidevops works for Windows users. Analysis revealed the framework is macOS-first with hardcoded launchd, Homebrew, osascript, pbcopy, mdfind, and `open` dependencies. WSL2 identified as the correct Windows path — it runs a real Linux kernel with near-native performance. Omarchy (DHH's opinionated Linux desktop) was evaluated but deemed overkill; headless WSL2 Ubuntu is sufficient.

## What

A platform abstraction layer that lets aidevops run on Linux (including WSL2) without modification, plus a WSL2 getting-started guide in the docs. After this task:

1. `setup.sh` detects the OS and uses the correct scheduler (launchd on macOS, systemd user services on Linux, with cron fallback)
2. All helper scripts use platform-agnostic commands or OS-switched wrappers for clipboard, file search, open-URL, and package install
3. A `reference/platform-support.md` doc covers WSL2 setup, known limitations, and platform-specific notes
4. CI runs on both macOS and Ubuntu to catch regressions

## Why

aidevops is currently macOS-only in practice. Windows is the majority developer platform. WSL2 gives Windows users a first-class Linux environment, but aidevops fails on it due to hardcoded macOS assumptions (launchd, osascript, pbcopy, mdfind, `open`). Blocking Windows/Linux users limits adoption. Existing tasks t1689 and t1690 fix narrow Windows issues; this task is the umbrella for full platform support.

## How (Approach)

### 1. Create `platform-detect.sh` helper

New script at `.agents/scripts/platform-detect.sh` that exports:
- `AIDEVOPS_PLATFORM` — `macos`, `linux`, `wsl2`, `windows-native`
- `AIDEVOPS_SCHEDULER` — `launchd`, `systemd`, `cron`
- `AIDEVOPS_CLIPBOARD_COPY` — `pbcopy`, `xclip -selection clipboard`, `clip.exe`
- `AIDEVOPS_CLIPBOARD_PASTE` — `pbpaste`, `xclip -selection clipboard -o`, `powershell.exe -c Get-Clipboard`
- `AIDEVOPS_OPEN_CMD` — `open`, `xdg-open`, `wslview`
- `AIDEVOPS_FILE_SEARCH` — `mdfind`, `locate`/`fd`

Detection: `uname -s` for Darwin/Linux, then check `/proc/version` for `microsoft` or `WSL` to distinguish native Linux from WSL2.

### 2. Refactor `setup.sh` scheduler code

Replace hardcoded `launchctl`/plist code with an abstraction:
- `_scheduler_install <name> <command> <interval_seconds>`
- `_scheduler_uninstall <name>`
- `_scheduler_status <name>`

Implementations: `_launchd_*` (existing, extract), `_systemd_*` (new), `_cron_*` (fallback).

Pattern to follow: `setup.sh` already has `_launchd_install_if_changed()` and `_launchd_has_agent()` — wrap these behind the abstraction.

### 3. Audit and fix platform-specific calls in helper scripts

Scripts with known macOS-only calls (from grep analysis):
- `mailbox-search-helper.sh:68` — `mdfind` (has partial Darwin check)
- `document-creation-helper.sh:73,425,458,471,496,510` — `uname` checks (has partial Linux fallbacks)
- `sonarcloud-cli.sh:24` — `OSTYPE == darwin*`
- Any script using `pbcopy`, `pbpaste`, `open`, `osascript`

Each should source `platform-detect.sh` and use the exported variables.

### 4. WSL2 getting-started guide

`reference/platform-support.md` covering:
- WSL2 install (`wsl --install`)
- Homebrew on Linux
- `aidevops` install via tap
- Known differences (no GUI automation, systemd vs launchd)
- Recommended WSL2 distro (Ubuntu, not Omarchy — too opinionated for a tooling prerequisite)

### 5. CI matrix expansion

Add Ubuntu runner to GitHub Actions workflow alongside macOS.

## Acceptance Criteria

- [ ] `setup.sh` completes without error on Ubuntu 22.04 (WSL2 or native)
  ```yaml
  verify:
    method: bash
    run: "grep -q 'platform-detect\\|AIDEVOPS_PLATFORM' .agents/scripts/platform-detect.sh"
  ```
- [ ] Pulse scheduler installs via systemd user service on Linux, launchd on macOS
  ```yaml
  verify:
    method: codebase
    pattern: "systemd|systemctl"
    path: "setup.sh"
  ```
- [ ] No script uses `pbcopy`, `mdfind`, `osascript`, or `open` without platform guard
  ```yaml
  verify:
    method: bash
    run: "! rg -l '\\b(pbcopy|pbpaste|mdfind|osascript)\\b' .agents/scripts/ --glob '!platform-detect.sh' | rg -v 'platform.*guard\\|uname\\|OSTYPE\\|AIDEVOPS_PLATFORM'"
  ```
- [ ] `reference/platform-support.md` exists with WSL2 setup instructions
  ```yaml
  verify:
    method: bash
    run: "test -f .agents/reference/platform-support.md"
  ```
- [ ] CI runs on both macOS and Ubuntu
  ```yaml
  verify:
    method: codebase
    pattern: "ubuntu"
    path: ".github/workflows"
  ```
- [ ] Lint clean (`shellcheck` on all modified scripts)

## Context & Decisions

- **WSL2 over native Windows**: Bash scripts won't run natively on Windows (PowerShell is a different world). WSL2 is Microsoft's official answer and runs a real Linux kernel.
- **Omarchy rejected as recommendation**: It's DHH's opinionated Linux desktop (Neovim, i3, Alacritty). Overkill for running a CLI tool — plain Ubuntu in WSL2 is sufficient and neutral.
- **systemd over cron as primary Linux scheduler**: systemd user services support `Restart=on-failure`, journal logging, and dependency ordering. Cron is fallback for environments without systemd (some containers, older distros).
- **Umbrella task**: t1689 (schtasks) and t1690 (fcntl locking) are narrower Windows fixes. This task subsumes their goals within a broader platform abstraction.

## Relevant Files

- `setup.sh` — main installer, hardcoded launchd throughout
- `.agents/scripts/mailbox-search-helper.sh:68` — mdfind usage
- `.agents/scripts/document-creation-helper.sh:73-510` — partial uname checks
- `.agents/scripts/sonarcloud-cli.sh:24` — OSTYPE check
- `.agents/AGENTS.md` — documents launchd-only scheduler section
- `.github/workflows/` — CI config (macOS-only today)

## Dependencies

- **Blocked by:** nothing
- **Blocks:** broader Windows/Linux adoption
- **Subsumes:** t1689 (schtasks support), t1690 (fcntl cross-platform locking)
- **External:** WSL2 testing environment (any Windows 10/11 machine)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 1h | Audit all macOS-specific calls across scripts |
| platform-detect.sh | 1h | Core detection + exported variables |
| setup.sh scheduler refactor | 3h | Extract launchd, add systemd + cron backends |
| Helper script audit + fixes | 2h | ~10 scripts need platform guards |
| WSL2 docs | 1h | reference/platform-support.md |
| CI matrix | 30m | Add Ubuntu to workflows |
| Testing | 1.5h | WSL2 end-to-end, macOS regression |
| **Total** | **~10h** | |
