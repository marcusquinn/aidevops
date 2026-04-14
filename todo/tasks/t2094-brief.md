# t2094 — bash-upgrade-helper: `ensure` subcommand for auto-upgrade in setup + update

**Session origin**: interactive, direct follow-up to GH#18950 (v3.8.25/v3.8.26)
**Tier**: `tier:standard` — small well-scoped refactor across 3 files with existing pattern to follow
**Target release**: v3.8.28

## What

Change `aidevops setup` and `aidevops-update-check.sh` from "emit advisory when bash is drifted" to "actually run `brew upgrade bash` on drift". This closes the inconsistency where the framework auto-updates itself via `aidevops update` but left bash as advisory-only despite bash being managed through the same Homebrew subsystem.

User feedback verbatim: *"I ran `brew upgrade bash`, but perhaps aidevops setup/update should be doing that, too?"* — answer: yes, it should.

## Why

- **Consistency with framework auto-update**: `aidevops update` already auto-pulls and auto-deploys new versions of the framework every ~10min. If we trust it to update the framework's own scripts (hundreds of files), trusting it to `brew upgrade bash` (one binary, smaller surface) is strictly less risky.
- **Risk reassessment**: my original "advisory-only" reasoning in GH#18950 was *"could disrupt running workers"*. That's overcautious. On Unix, replacing a binary file on disk does NOT kill running processes — the running bash has its own memory-loaded copy. Homebrew minor-version bumps (5.3.9 → 5.3.10) have no ABI breaks. Major version bumps (5 → 6) are rare and essentially drop-in.
- **User expectation**: the user asked once and got installed. The user asked to upgrade and the framework said "go run `brew upgrade bash` yourself". That's an inconsistent UX — either we own the bash lifecycle or we don't. We should own it.
- **Blast radius**: zero in practice. The re-exec guard in `shared-constants.sh` means every framework script picks up the new bash on its next invocation. Existing bash processes (pulse, active workers) continue running on their in-memory bash until they naturally exit.

## How

### Part 1 — new `ensure` subcommand in `bash-upgrade-helper.sh`

EDIT: `.agents/scripts/bash-upgrade-helper.sh` — add a new subcommand that does the combined install-or-upgrade flow:

```bash
_bu_cmd_ensure() {
    local yes="$1"
    local platform
    platform="$(_bu_platform)"
    [[ "$platform" == "macos" ]] || { _bu_info "platform=${platform}: ensure is a no-op"; return 0; }

    # Opt-out: AIDEVOPS_AUTO_UPGRADE_BASH=0 disables automated install/upgrade entirely.
    # (Default is unset / "1" — enabled.)
    if [[ "${AIDEVOPS_AUTO_UPGRADE_BASH:-1}" == "0" ]]; then
        _bu_info "AIDEVOPS_AUTO_UPGRADE_BASH=0 set — skipping ensure"
        return 0
    fi

    if ! command -v brew >/dev/null 2>&1; then
        _bu_write_advisory "bash-3.2-upgrade | macOS needs bash 4+ via Homebrew. Install Homebrew then run: aidevops update"
        return 3
    fi

    local existing
    existing="$(_bu_find_modern_bash)"

    if [[ -z "$existing" ]]; then
        # Missing — delegate to install.
        _bu_cmd_install "$yes"
        return $?
    fi

    # Installed — check for drift and upgrade if needed. Rate-limit `brew update` to 24h
    # via a separate state file (it's the expensive step). Once the index is fresh,
    # `brew outdated bash` is cheap.
    _bu_maybe_brew_update || true

    if brew outdated bash 2>/dev/null | grep -q '^bash'; then
        _bu_info "running: brew upgrade bash"
        brew upgrade bash 2>&1 || true
        # Verify by detection, same pattern as install.
        local updated
        updated="$(_bu_find_modern_bash)"
        if [[ -n "$updated" ]]; then
            _bu_info "brew upgrade bash completed (modern bash at ${updated})"
            _bu_dismiss_advisory_if_resolved
            return 0
        fi
        _bu_error "brew upgrade bash did not produce a modern bash"
        _bu_write_advisory "bash-upgrade-failed | brew upgrade bash FAILED. Run manually: brew upgrade bash"
        return 4
    fi

    _bu_info "bash is up to date at ${existing}"
    return 0
}
```

Plus a new helper for the rate-limited `brew update`:

```bash
_BREW_UPDATE_STATE="${_STATE_DIR}/brew-update-last-fetch"

_bu_maybe_brew_update() {
    local now last_fetch
    now="$(date +%s 2>/dev/null || echo 0)"
    mkdir -p "$_STATE_DIR" 2>/dev/null || return 1
    if [[ -f "$_BREW_UPDATE_STATE" ]]; then
        last_fetch="$(cat "$_BREW_UPDATE_STATE" 2>/dev/null || echo 0)"
        [[ "$last_fetch" =~ ^[0-9]+$ ]] || last_fetch=0
        if [[ $((now - last_fetch)) -lt 86400 ]]; then
            return 0  # Already fresh within 24h
        fi
    fi
    brew update >/dev/null 2>&1 || return 1
    echo "$now" >"$_BREW_UPDATE_STATE" 2>/dev/null || true
    return 0
}
```

Wire `ensure` into the main dispatch:

```bash
ensure) _bu_cmd_ensure "$yes" ;;
```

Update `_bu_usage` to document the new subcommand.

### Part 2 — rewire `setup.sh`

EDIT: `setup.sh` — `_setup_check_bash_upgrade` currently calls `check` then branches on install. Change it to call `ensure` directly. Interactive mode still gets the prompt on first install (inherited from `_bu_cmd_install` inside `ensure`), but upgrades run silently — no prompt on every `aidevops update`.

```bash
_setup_check_bash_upgrade() {
    [[ "${AIDEVOPS_PLATFORM:-}" != "macos" ]] && return 0

    local helper="${INSTALL_DIR}/.agents/scripts/bash-upgrade-helper.sh"
    [[ -x "$helper" ]] || return 0

    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        # Non-interactive: ensure does everything silently.
        # Default is AIDEVOPS_AUTO_UPGRADE_BASH=1 (enabled); users can set =0 to opt out.
        "$helper" ensure --yes --quiet || print_warning "bash ensure failed (non-fatal) — advisory written"
        return 0
    fi

    # Interactive: ensure prompts on first install (from _bu_cmd_install's existing
    # `read` path), runs silently on upgrade. No new prompt logic needed.
    "$helper" ensure || print_warning "bash ensure failed (non-fatal) — advisory written"
    return 0
}
```

### Part 3 — rewire `aidevops-update-check.sh`

EDIT: `.agents/scripts/aidevops-update-check.sh` — replace the `update-check` call with `ensure --quiet`. The 24h rate limit moves from being specific to `update-check` to being shared with the new `_bu_maybe_brew_update` state file (actually, the two are independent: the `ensure` flow needs `brew update` freshness, and we don't want to run `brew update` more than once per 24h regardless of how many times `ensure` is called).

```bash
# GH#18950 (t2087) → GH#<this> (t2094): bash 3.2 → modern bash ensure.
# Runs `brew upgrade bash` when drift is detected. Rate-limited internally
# via `_bu_maybe_brew_update` (24h state file). Best-effort — never blocks
# the update check on failure.
if [[ -x "${script_dir}/bash-upgrade-helper.sh" ]]; then
    "${script_dir}/bash-upgrade-helper.sh" ensure --yes --quiet 2>/dev/null || true
fi
```

Note: the `update-check` subcommand stays in the helper (backward compat) but is now a thin wrapper around `ensure`. Or it can be deprecated. Simplest: leave `update-check` as-is for any external caller, have both subcommands share the rate-limit state.

### Part 4 — test update

EDIT: `.agents/scripts/tests/test-bash-reexec-guard.sh` — add 3 new assertions:

1. `ensure` subcommand exists and runs (returns 0 when bash is current).
2. `ensure` is idempotent — calling it twice in quick succession is a no-op (second call shouldn't re-run `brew update` because of the state file).
3. `AIDEVOPS_AUTO_UPGRADE_BASH=0` short-circuits `ensure` without calling `brew`.

Total test assertions: 12 → 15.

### Part 5 — doc + AGENTS.md tweak

EDIT: `.agents/reference/bash-compat.md` — update the "How the four-part fix works" section to reflect that update-check now actually runs upgrades, not just emits advisories. Document the `AIDEVOPS_AUTO_UPGRADE_BASH=0` opt-out.

EDIT: `.agents/AGENTS.md` — tweak the one-line Security section mention to say "automatically installs and upgrades modern bash" instead of "checks for modern bash and emits an advisory".

## Acceptance criteria

- [ ] `ensure` subcommand added to `bash-upgrade-helper.sh`, tested live on this machine (idempotent when current)
- [ ] `setup.sh` calls `ensure` instead of `check`+branch
- [ ] `aidevops-update-check.sh` calls `ensure --yes --quiet` instead of `update-check`
- [ ] `brew update` rate-limited to 24h via separate state file (`_BREW_UPDATE_STATE`)
- [ ] `AIDEVOPS_AUTO_UPGRADE_BASH=0` opt-out respected
- [ ] 3 new regression test assertions (15 total)
- [ ] `reference/bash-compat.md` + `AGENTS.md` updated to reflect "actually upgrades"
- [ ] Shellcheck clean
- [ ] Live verification: delete `~/.aidevops/state/bash-upgrade-last-check` and `~/.aidevops/state/brew-update-last-fetch`, run `aidevops-update-check.sh` and observe that bash stays at current version (no redundant upgrade); simulate drift by running `ensure` and observe no-op

## Context

- Direct follow-up to GH#18950 (v3.8.25) and GH#18952-GH#18953 test fix (v3.8.26)
- User feedback this session: "I ran `brew upgrade bash`, but perhaps aidevops setup/update should be doing that, too?"
- Related: the framework's own `aidevops update` auto-pulls + auto-deploys without prompting; bash should follow the same philosophy
- Out of scope: making bash upgrade interactive-prompted during `aidevops update` (user explicitly said "always please" — silent upgrades)
- Risk: near-zero. Binary replacement doesn't kill running processes; minor version bumps have no ABI breaks; re-exec guard handles new invocations transparently
