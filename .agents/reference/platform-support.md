<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Platform Support

This page describes aidevops runtime compatibility. For opinionated desktop,
server, development, and security OS recommendations, see
[OS selection](os-selection.md). Those preferences do not add supported platforms
here or imply that every derivative, architecture, or provider image was tested.

## Supported Platforms

| Platform | Status | Scheduler | Notes |
|----------|--------|-----------|-------|
| macOS 12+ | Full | launchd | Primary development platform |
| Ubuntu 22.04+ | Full | systemd / cron | Native Linux and WSL2 |
| Debian 11+ | Full | systemd / cron | |
| Fedora 38+ | Full | systemd / cron | |
| Arch Linux | Full | systemd / cron | |
| WSL2 (Ubuntu) | Full | systemd / cron | Recommended Windows path |
| Windows (native) | Limited | — | Experimental `/optimise-windows-indexing-backups` only; use WSL2 for full support |

## Worktree lifecycle backends

Worktree creation and owner registration share `shared-worktree-create.sh`.
macOS keeps the existing synchronous publication and legacy cleanup guards;
it does not require systemd or a replacement launchd runner. New legacy creations
record their backend and physical identity in `worktree_creation_backends`, not
as managed descendant-completion receipts.

Profile publication uses the managed runner only when Linux cgroup v2 and a
reachable user-systemd version supporting `ExitType=cgroup` are available.
`python3 scripts/worktree-managed-run.py --check-backend` probes that capability
without starting a service. Other hosts select the legacy path **before** creating
the worktree. A failure after managed execution starts is not retried as legacy.
Existing managed records cannot be downgraded by a platform or backend change.

These backends have different evidence: legacy cleanup retains its existing
guards, while managed cleanup requires its cgroup completion receipts. Neither
backend selection nor a dead owner PID is itself permission to delete a worktree.

The shared creator covers host CLI, profile, Pulse, release/recovery, branch
cleanup, planning, workflow-sync, plugin and archive-restore producers. Test
fixtures and the isolated Frontier benchmark guest bootstrap are separate from
the host worktree lifecycle. Callers retain their base-ref, path and ownership
policies; an explicitly reserved empty directory may be admitted without
dropping its reservation. Registration failure preserves the new tree.

Recreating a removed managed worktree at the same path starts a fresh generation,
not a reuse of its completion receipt. The ownership transaction preserves the
closed prior record in `worktree_lifetime_history` before replacing it. Rotation
requires valid completion evidence and a matching creation token durably recorded
**before** Git runs. That fence invalidates the old receipt even if the filesystem
reuses both inode numbers or the creator crashes before registration. Failed
registration rolls back the history/active-record transition but preserves the
pre-creation fence. Incomplete evidence, a different lifetime manager or a stale
token fails closed. Existing trees cannot use this creation-only transition.

Registration does not itself start a supervisor. Inside a managed run, generic
producers bind to the invocation leader; outside one, unavailable Linux
descendant-completion evidence remains unavailable. Temporary cleanup must
preserve managed trees without closed proof, even after its synchronous Git
commands finish. This is not a fallback to a full worktree copy or permission
to downgrade the recorded backend.

Branch-cleanup deletion transports (`<repo>-{local,remote}-branch-cleanup-<pid>`)
are synchronous, process-scoped, detached trees that never host handed-off
work. Their helpers choose the legacy backend before creation and remove the
transport on exit, including timeout signals (GH#35490). Guarded cleanup
(`worktree-helper.sh clean` and the async all-repo pass) reclaims transports
retained by hard kills or by earlier owner-cgroup enrollment. Reclaim requires
an exited creator and recorded owners, no checkout or an unmodified one, and
the usual canonical, lock and active-CWD guards. It never adopts Pulse records.

## Command lookup (PATH only)

Tools are resolved through PATH on every platform; there are no distro-specific
roots. This lets hosts without `/usr/bin/git` or `/bin/bash` (for example NixOS
without envfs) work with the same code as macOS and Ubuntu.

- **PATH order**: aidevops directories first, then the inherited PATH, then
  `/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin` (plus `/opt/homebrew/bin` for
  services) only as a de-duplicated fallback. Builder: `scripts/runtime-env.sh`.
- **Services**: generated systemd units and cron lines bake the installing
  user's sanitised PATH and start via `/usr/bin/env bash`. Launchd plists keep
  `/bin/bash` (macOS only). Re-run setup to regenerate existing units; running
  processes keep their original environment.
- **Shebangs**: `#!/usr/bin/env bash|python3` (`-S python3 -I` for isolated
  mode). `tests/test-portable-shebangs.sh` rejects new absolute interpreters.
  Exception: root sudo targets such as `worktree-cwd-inspect.py`.
- **Native Git**: `aidevops_resolve_native_git` walks PATH, skipping the aidevops
  Git shim, and exports `AIDEVOPS_REAL_GIT_BIN`. Python policy adapters share
  `scripts/native_git.py`. Both identify shims by a resolved sibling
  `canonical-git-command-guard.py`, including symlinked runtime generations.
  Overrides (`AIDEVOPS_REAL_GIT_BIN`, legacy `AIDEVOPS_REAL_GIT`) must be absolute,
  executable regular files and not shims; invalid overrides and missing native
  Git fail closed with `BLOCKED:` rather than falling back to `/usr/bin/git`.
- **Trusted tools** (source access, vault Python, sudo, release-lane `ps`,
  `ssh-keygen`, team-interface helpers): root-owned executable, symlink chain
  and parent directories, with no group/other write. Sticky directories are
  allowed only as ancestors, never as the executable's immediate PATH directory.
  Shell selection delegates to `trusted_executable.py` through an unmodifiable
  `python3 -I -S -B`; the bootstrap uses standard-path portable stat and fails
  closed when unavailable. The Python CLI accepts `<name> [search_path]`:
  exit 1 means unavailable, 2 invalid arguments, 3 untrusted interpreter.
  Python and `trusted-executable.mjs` append platform defaults (`/bin:/usr/bin`)
  for implicit PATH searches; an explicit search path remains exact.
- **Runtime library**: source `runtime-env.sh`, never execute it directly.
  Set `AIDEVOPS_RUNTIME_ENV_LIBRARY_ONLY=1` when sourcing to load functions
  without modifying PATH or Git overrides. Service PATHs preserve stable
  per-user directories even before installation; all builders strip trailing
  slashes before deduplication.

This covers command discovery, not full packaging compatibility: downloaded FHS
binaries may still need native packages, and the model-replay `bwrap` sandbox
still looks for `bwrap` in fixed locations.

## Native Windows Support Posture

Native Windows remains outside full aidevops platform support. The only native Windows path currently documented is `/optimise-windows-indexing-backups`, a limited experimental local-ops command that audits Windows Search, File History/Windows Backup, OneDrive, and backup-client churn with dry-run recommendations by default.

`/optimise-windows-indexing-backups --apply` writes a user-owned recommendation file only; it does not mutate Windows Search, File History, Windows Backup, OneDrive, Windows Defender, or third-party backup-client settings. WSL2 users should continue to use `/optimise-linux-indexing-backups`.

## WSL2 Getting Started (Windows)

Native Windows (PowerShell) is not supported for full aidevops operation — use WSL2.

**1. Install WSL2** (PowerShell as Administrator):

```powershell
wsl --install
```

Installs Ubuntu by default. Restart when prompted.

**2. Open a WSL2 terminal** — launch "Ubuntu" from the Start menu, or run `wsl` in PowerShell.

**3. Install Homebrew (recommended) or use apt:**

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Add brew to your PATH per post-install instructions. Alternatively, use apt — aidevops detects and uses it automatically.

**4. Install aidevops:**

```bash
# Via npm (recommended)
npm install -g aidevops && aidevops update

# Via Homebrew tap
brew install marcusquinn/tap/aidevops && aidevops update

# Manual
bash <(curl -fsSL https://aidevops.sh/install)
```

**5. Run setup** (detects Linux/WSL2 automatically):

```bash
./setup.sh
```

## Platform Detection

Source `.agents/scripts/platform-detect.sh` to get platform-specific variables:

```bash
source ~/.aidevops/agents/scripts/platform-detect.sh

echo "$AIDEVOPS_PLATFORM"   # macos | linux | wsl2 | windows-native
echo "$AIDEVOPS_SCHEDULER"  # launchd | systemd | cron
```

### Exported variables

| Variable | macOS | Linux (systemd) | Linux (no systemd) | WSL2 |
|----------|-------|-----------------|-------------------|------|
| `AIDEVOPS_PLATFORM` | `macos` | `linux` | `linux` | `wsl2` |
| `AIDEVOPS_SCHEDULER` | `launchd` | `systemd` | `cron` | `systemd` or `cron` |
| `AIDEVOPS_CLIPBOARD_COPY` | `pbcopy` | `xclip -selection clipboard` | `xclip ...` or empty | `clip.exe` |
| `AIDEVOPS_CLIPBOARD_PASTE` | `pbpaste` | `xclip -selection clipboard -o` | ... | `powershell.exe -c Get-Clipboard` |
| `AIDEVOPS_OPEN_CMD` | `open` | `xdg-open` | `xdg-open` | `wslview` |
| `AIDEVOPS_FILE_SEARCH` | `mdfind` | `fd` | `fd` or `locate` | `fd` |
| `AIDEVOPS_PKG_INSTALL` | `brew install` | `sudo apt-get install -y` | varies | `sudo apt-get install -y` |

## Scheduler Backends

### macOS — launchd

Pulse and scheduled tasks run as LaunchAgents in `~/Library/LaunchAgents/`.

- Label prefix: `com.aidevops.*`
- Manage: `launchctl list | grep aidevops`
- Disable pulse: `aidevops config set orchestration.supervisor_pulse false && ./setup.sh`

### Linux — systemd user services (preferred)

When `systemctl --user status` succeeds, aidevops installs systemd user timers. Preferred over cron: supports `Restart=on-failure`, journal logging, and dependency ordering.

- Service files: `~/.config/systemd/user/aidevops-*.{service,timer}`
- List: `systemctl --user list-timers | grep aidevops`
- Disable pulse: `systemctl --user disable --now aidevops-supervisor-pulse.timer`

### Linux — cron (fallback)

Used when systemd is unavailable (containers, older distros, WSL2 without systemd).

- List: `crontab -l | grep aidevops`
- Disable pulse: `crontab -e` and remove the `supervisor-pulse` line

## Known Limitations on Linux/WSL2

| Feature | macOS | Linux | Notes |
|---------|-------|-------|-------|
| Clipboard auto-copy | pbcopy | xclip / xsel / wl-copy | Install `xclip` for clipboard support |
| Open URL | `open` | `xdg-open` | Works in desktop Linux; no-op in headless |
| Spotlight search | mdfind | fd / locate | `fd` recommended |
| Apple Mail integration | Full | Not available | macOS-only (Contacts.app, Calendar.app) |
| osascript / AppleScript | Full | Not available | macOS-only |
| Reminders.app | Full | todoman (via caldav) | Different backend |
| Calendar.app | Full | khal (via caldav) | Different backend |
| Contacts.app | Full | khard (via carddav) | Different backend |
| OrbStack VMs | macOS only | N/A | Use native Docker on Linux |
| MiniSim | macOS only | N/A | iOS/Android emulator launcher |
| serve-sim | macOS Apple Silicon only | N/A | Browser-visible Apple Simulator stream/control |
| ClaudeBar | macOS only | N/A | Menu bar quota monitor with live background refresh for Claude, Codex, Gemini, Copilot, Antigravity, Kimi, Kiro, and Amp |

## Installing Clipboard Tools on Linux

```bash
# Ubuntu/Debian
sudo apt-get install -y xclip

# Fedora
sudo dnf install -y xclip

# Arch
sudo pacman -S xclip

# Wayland (use wl-clipboard instead)
sudo apt-get install -y wl-clipboard
```

## Enabling systemd in WSL2

WSL2 Ubuntu 22.04+ supports systemd by default. Enable if not already active:

```bash
systemctl --user status

# If not running, enable in /etc/wsl.conf then restart WSL
echo -e "[boot]\nsystemd=true" | sudo tee /etc/wsl.conf
# wsl --shutdown (from PowerShell), then reopen Ubuntu
```

## CI/CD

The GitHub Actions CI runs on both `ubuntu-latest` and `macos-latest` to catch platform regressions. See `.github/workflows/code-quality.yml`.
