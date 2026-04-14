# t2087 — Systemic fix: bash 3.2 → modern bash auto-install in setup + update + runtime self-heal

**Session origin**: interactive, follow-up to GH#18830 (the NUL-delimited parameter expansion parser crash)
**Tier**: `tier:standard` — narrative brief with file references, well-scoped refactor across known files, no novel architecture.

## What

Fix the systemic root cause of macOS/Linux bash incompatibility that caused GH#18770, GH#18784, GH#18786, GH#18804, and GH#18830 — all variations on "bash 3.2 does something weird that bash 4+ doesn't." macOS ships `/bin/bash` 3.2.57 as the default, which has no plans for upgrade (license reasons). Framework scripts use `#!/usr/bin/env bash` and silently run under 3.2 on macOS. The existing `bash32-compat` CI gate is a static grep for known anti-patterns and cannot catch novel parser bugs.

This task ships a four-part fix: make modern bash (4+) automatically available on macOS via Homebrew, have scripts self-heal at runtime by re-execing under modern bash when 3.2 is detected, and integrate the install/update into the existing `setup.sh` and `aidevops-update-check.sh` rails.

## Why

- GH#18830 silently killed pulse dispatch for weeks on macOS because of a bash 3.2 parser bug in `${refs%%$'\0'*}`. Static CI didn't catch it. The fix was a targeted workaround.
- Evidence that this is a recurring class: 5 issues in quick succession all tracing to bash 3.2 set-e propagation / parser quirks.
- The framework's own documentation says "Bash 3.2 compatibility" is a hard requirement — but the reality is that bash 3.2 is a minefield for non-trivial shell code. The compatibility target should be bash 4+.
- Homebrew is already installed on virtually every macOS dev machine that uses aidevops. The framework already uses `brew install` as its package install mechanism for macOS (see `platform-detect.sh:134`). Adding bash to the install list is a natural extension, not a new dependency class.
- The runtime re-exec guard makes the fix self-healing: even if a user has an old install and never runs `setup.sh` again, scripts that source `shared-constants.sh` will automatically upgrade themselves to modern bash the next time they run, as long as modern bash is installed.

## How

### Part 1 — New helper `bash-upgrade-helper.sh`

- NEW: `.agents/scripts/bash-upgrade-helper.sh` — model on `platform-detect.sh` for structure and `security-posture-helper.sh` for interactive prompts.
- Subcommands:
  - `check` — exit 0 if modern bash (≥4) is available in a known location; exit 1 if needs upgrade; exit 2 if platform unsupported (Windows native)
  - `status` — print current `/bin/bash` version, modern bash path (if any), and remediation text
  - `install` — on macOS with Homebrew, runs `brew install bash` (interactive prompt unless `--yes`); no-op on Linux (bash is already modern); error message on macOS without Homebrew
  - `upgrade` — `brew upgrade bash` if available, no-op otherwise
  - `path` — print the absolute path to the first modern bash found, or empty string if none
- Detection order for macOS modern bash candidates: `/opt/homebrew/bin/bash`, `/usr/local/bin/bash`, `$(brew --prefix 2>/dev/null)/bin/bash`
- Linux: if `/usr/bin/env bash` is already ≥ 4, `check` returns 0 and everything else no-ops. Linux "modern bash" is a tautology on any current distro.
- Reference pattern: the script should be self-contained (no `source shared-constants.sh` at the top) so it can safely run under bash 3.2 itself. Use minimal dependencies.

### Part 2 — Hook into `setup.sh`

- EDIT: `setup.sh` — add a call to `bash-upgrade-helper.sh check` after platform detection (~line 540 area, before the main deploy loop).
- If `check` returns 1 on macOS:
  - Interactive mode: prompt `Install modern bash via Homebrew? (Y/n)` — default yes. On yes, run `bash-upgrade-helper.sh install`. On no, emit advisory and continue.
  - Non-interactive mode (`--non-interactive`): if `AIDEVOPS_AUTO_UPGRADE_BASH=1` environment variable is set, auto-install. Otherwise emit advisory and continue.
  - Homebrew missing: emit hard advisory with install instructions (`/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`) and continue setup.
- Advisory file: `~/.aidevops/advisories/bash-3.2-upgrade.advisory` — written on every failure path so the reminder survives across sessions and appears in session greetings until dismissed.

### Part 3 — Hook into `aidevops-update-check.sh`

- EDIT: `.agents/scripts/aidevops-update-check.sh` — add a cheap bash check after the main update check (~end of the script).
- If modern bash is installed: check `brew outdated bash 2>/dev/null` — if it reports bash as outdated, emit advisory recommending `brew upgrade bash`.
- Rate-limit: only check once per 24h. State file: `~/.aidevops/state/bash-upgrade-last-check` (epoch seconds).
- NEVER auto-upgrade during an update cycle — advisory-only. Upgrading bash mid-operation could disrupt running workers. Advisory + manual upgrade is the same pattern used for `aidevops update` itself.

### Part 4 — Runtime self-heal guard in `shared-constants.sh`

- EDIT: `.agents/scripts/shared-constants.sh` — add a bash version guard RIGHT AFTER the include guard (after line 17, before any other code).
- Logic:

  ```bash
  # GH#18830 follow-up: bash 3.2 → bash 4+ re-exec guard.
  # If running under bash < 4 AND a modern bash is available, re-exec the
  # calling script under the modern bash. On Linux this is a no-op. On
  # macOS without modern bash installed, we fall through (script runs on
  # 3.2; an advisory will surface on the next update cycle).
  if [[ ${BASH_VERSINFO[0]} -lt 4 && -z "${AIDEVOPS_BASH_REEXECED:-}" && -n "${BASH_SOURCE[1]:-}" ]]; then
      for _aidevops_bash_candidate in /opt/homebrew/bin/bash /usr/local/bin/bash /home/linuxbrew/.linuxbrew/bin/bash; do
          if [[ -x "$_aidevops_bash_candidate" ]]; then
              export AIDEVOPS_BASH_REEXECED=1
              exec "$_aidevops_bash_candidate" "${BASH_SOURCE[1]}" "$@"
          fi
      done
      unset _aidevops_bash_candidate
  fi
  ```

- Critical subtleties:
  - `AIDEVOPS_BASH_REEXECED=1` guard prevents infinite re-exec loops if a symlink points wrong
  - `BASH_SOURCE[1]` is the calling script's path, not shared-constants.sh itself
  - `exec` replaces the current process, so the re-execed bash runs the calling script from the top under modern bash
  - `setup.sh` MUST NOT source shared-constants.sh at the top (or must set `AIDEVOPS_BASH_REEXECED=1` first) because setup is the script that installs modern bash — a chicken-and-egg
  - `bash-upgrade-helper.sh` itself MUST NOT source shared-constants.sh — same chicken-and-egg
- Add a regression test: `.agents/scripts/tests/test-bash-reexec-guard.sh` that verifies (a) running a fake script under `/bin/bash` re-execs to modern bash when available, (b) `AIDEVOPS_BASH_REEXECED=1` prevents re-exec, (c) re-exec is skipped on bash ≥ 4.

### Documentation

- EDIT: `.agents/reference/bash-compat.md` — add a "Modern bash install" section at the top explaining the four-part fix, with the one-command remediation and the self-heal behavior.
- EDIT: `.agents/AGENTS.md` "Security" section — add a one-line note about the bash upgrade advisory (where it lives, how to dismiss).

## Acceptance criteria

- [ ] `bash-upgrade-helper.sh` exists with all 5 subcommands and works correctly under bash 3.2 AND bash 5+ (run both)
- [ ] `setup.sh` calls `bash-upgrade-helper.sh check` during init and emits advisory or prompts for install on macOS with bash 3.2
- [ ] `aidevops-update-check.sh` emits an advisory when modern bash is outdated, rate-limited to once per 24h
- [ ] `shared-constants.sh` re-execs under modern bash when called under `/bin/bash` 3.2 AND a modern bash is available — verified by a regression test
- [ ] Regression test `test-bash-reexec-guard.sh` passes 4+ assertions covering all re-exec paths
- [ ] `reference/bash-compat.md` documents the new install/upgrade flow
- [ ] `AGENTS.md` mentions the advisory
- [ ] Live verification: run `/bin/bash ~/.aidevops/agents/scripts/pulse-wrapper.sh --help` (or any shared-constants-sourcing script) and observe that it re-execs to modern bash
- [ ] Shellcheck clean on all modified files
- [ ] Bash 3.2 compat CI gate still passes

## Context

- **Root-cause session**: GH#18830 (this session's earlier work) — fixed one instance, this task addresses the class.
- **Related bug history**: GH#18770, GH#18784, GH#18786, GH#18804 (all set-e / parser bugs on bash 3.2).
- **Existing infrastructure**:
  - `platform-detect.sh:134` — exports `AIDEVOPS_PKG_INSTALL="brew install"` on macOS
  - `setup.sh` — platform detection + deploy entrypoint
  - `aidevops-update-check.sh` — periodic update advisory emitter
  - `security-posture-helper.sh` — pattern for interactive prerequisite setup
  - `~/.aidevops/advisories/*.advisory` — advisory delivery system
- **Operational impact**: zero risk to running pulse — advisory-only for existing installs, opt-in for new installs. Runtime re-exec is transparent.
- **Session origin**: interactive, marcusquinn approved the four-part plan in this conversation.
- **Out of scope for this task**: expanding the static `bash32-compat` CI gate with more patterns (separate issue if desired), dynamic CI job that runs tests under bash 3.2 (Option A from the plan).

## Verification commands

```bash
# Unit test
bash .agents/scripts/tests/test-bash-reexec-guard.sh

# End-to-end smoke
/bin/bash -c 'source .agents/scripts/shared-constants.sh && echo "bash=${BASH_VERSINFO[0]}"'
# Expected output on a Mac with brew bash installed: bash=5 (or whatever modern version)

# Shellcheck
shellcheck .agents/scripts/bash-upgrade-helper.sh \
           .agents/scripts/shared-constants.sh \
           .agents/scripts/aidevops-update-check.sh \
           setup.sh \
           .agents/scripts/tests/test-bash-reexec-guard.sh

# CI gate: bash 3.2 compatibility (existing static check)
bash .agents/scripts/linters-local.sh

# Live demonstration
/bin/bash ~/.aidevops/agents/scripts/memory-helper.sh recall --query test --limit 1
# Should re-exec under modern bash transparently; the memory-helper runs unchanged.
```
