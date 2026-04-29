#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-canonical-recovery.sh — auto-recover canonical worktree from pull
# conflicts (t2865, GH#20922).
#
# When pulse calls `git pull --ff-only` on a canonical repo path, two failure
# modes leave that repo silently un-refreshed:
#
#   1. Unmerged files: `error: Pulling is not possible because you have
#      unmerged files` — usually leftover `UU` state from a prior crash or
#      mid-rebase abort.
#   2. Local uncommitted changes: `error: Your local changes to the following
#      files would be overwritten by merge` — typically a concurrent
#      issue-sync push that left TODO.md modified vs origin during a rebase.
#
# Recovery strategy: optionally `git merge --abort` (for unmerged state) →
# stash → retry pull → pop. Stash-and-pop is content-safe (no `-X theirs`
# auto-resolve). On persistent failure, write a LOCAL advisory file
# (`~/.aidevops/advisories/canonical-recovery-<basename>.advisory`) with
# the exact remediation commands the user can run. The local file is
# surfaced in the session-start greeting via aidevops-update-check.sh —
# we never file GitHub issues for canonical-recovery failures because
# the advisory describes user-local state and would leak filesystem paths
# (username, drive topology) into the public maintainer tracker (t2871).
#
# Scope:
#   - Canonical repo paths only (`~/Git/<repo>/`). Worktrees have separate
#     ownership rules and are out of scope.
#   - Idempotency: per-repo attempt counting in a hot window prevents loops.
#   - Audit log: every action is recorded via `audit-log-helper.sh log`
#     using the `operation.verify` event type.
#
# Usage (standalone):
#   pulse-canonical-recovery.sh [--dry-run] <repo-path>
#   pulse-canonical-recovery.sh --help
#
# Usage (module, sourced by pulse-wrapper.sh):
#   Call `pulse_canonical_recover <repo-path>`. Returns 0 on no-recovery-needed
#   or successful recovery, 1 on persistent failure (advisory filed).

# Include guard — prevent double-sourcing when another module pulls us in.
[[ -n "${_PULSE_CANONICAL_RECOVERY_LOADED:-}" ]] && return 0 2>/dev/null || true
_PULSE_CANONICAL_RECOVERY_LOADED=1

# Resolve script directory so we can source shared-constants.sh when executed
# standalone. When sourced by pulse-wrapper.sh, SCRIPT_DIR is already defined
# and shared-constants.sh has already been sourced — source is idempotent via
# its own include guard.
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	# shellcheck disable=SC2155
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# shellcheck source=shared-constants.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/shared-constants.sh" 2>/dev/null || true
init_log_file 2>/dev/null || true

# shared-gh-wrappers.sh was previously sourced here so `_pcr_file_advisory`
# could call `gh_create_issue`. Removed in t2871: advisories now write to
# the local channel (`~/.aidevops/advisories/`) and never touch GitHub.
# Reintroduce the source line ONLY if a future feature in this module needs
# a real `gh` call.

# -----------------------------------------------------------------------------
# Configuration constants
# -----------------------------------------------------------------------------

# Hot-loop guard — if this many recovery attempts fire on the same repo within
# the window, stop trying and file an advisory.
PULSE_CANONICAL_RECOVERY_HOT_WINDOW="${PULSE_CANONICAL_RECOVERY_HOT_WINDOW:-3600}"          # 1h
PULSE_CANONICAL_RECOVERY_MAX_ATTEMPTS="${PULSE_CANONICAL_RECOVERY_MAX_ATTEMPTS:-3}"

# State file for attempt timestamps. JSON: {"<repo_path>": [ts1, ts2, ...]}.
PULSE_CANONICAL_RECOVERY_STATE="${PULSE_CANONICAL_RECOVERY_STATE:-${HOME}/.aidevops/.agent-workspace/supervisor/canonical-recovery-state.json}"

# Local advisory directory — surfaced in session greeting via
# aidevops-update-check.sh::_check_advisories.  This is the canonical channel
# for user-actionable warnings about local-machine state.  Filing a GitHub
# issue here would leak `${repo_path}` (username, drive topology, possibly
# private repo names) into a public maintainer tracker — only the affected
# user can act on canonical-recovery failures, so cloud filing has zero
# diagnostic value to maintainers and a non-trivial privacy cost (t2871).
PULSE_CANONICAL_RECOVERY_ADVISORY_DIR="${PULSE_CANONICAL_RECOVERY_ADVISORY_DIR:-${HOME}/.aidevops/advisories}"

# The audit-log-helper's event-type allowlist is closed. `operation.verify`
# is the closest fit for "pulse took a verified deterministic action".
readonly _CANONICAL_RECOVERY_AUDIT_EVENT="operation.verify"

# Advisory headline used in both the local advisory file (line 1, surfaced
# in session greeting) and the legacy GitHub-issue title-suffix constant.
# Kept under the legacy name so downstream tooling that searched for filed
# issues by title can still recognise pre-t2871 issues if any survive.
readonly _CANONICAL_RECOVERY_ADVISORY_TITLE_SUFFIX="canonical worktree conflict — manual intervention required"

# Dry-run flag — CLI `--dry-run` or env `DRY_RUN=1`. Module-local copy so we
# don't pollute the caller's environment when sourced.
_PULSE_CANONICAL_RECOVERY_DRY_RUN="${DRY_RUN:-0}"

# -----------------------------------------------------------------------------
# Logging + audit helpers
# -----------------------------------------------------------------------------

_pcr_log() {
	# Unified log line — writes to $LOGFILE when set (pulse context), otherwise
	# stderr (standalone). Never throws.
	local log_dir=""
	if [[ -n "${LOGFILE:-}" ]]; then
		log_dir=$(dirname "$LOGFILE" 2>/dev/null) || log_dir=""
	fi
	if [[ -n "${LOGFILE:-}" && -n "$log_dir" && -w "$log_dir" ]]; then
		printf '[pulse-canonical-recovery] %s\n' "$*" >>"$LOGFILE" 2>/dev/null || true
	else
		printf '[pulse-canonical-recovery] %s\n' "$*" >&2
	fi
	return 0
}

_pcr_is_dry_run() {
	[[ "$_PULSE_CANONICAL_RECOVERY_DRY_RUN" == "1" ]]
}

_pcr_audit() {
	# Record an audit-log entry. Never throws; audit-log-helper failures are
	# non-fatal so a missing helper or quota issue doesn't break the pulse.
	# `_PCR_AUDIT_HELPER` env override exists for test fixtures so they can
	# stub the helper without overriding SCRIPT_DIR (which would also break
	# shared-gh-wrappers.sh sourcing). Production callers leave it unset.
	local op="$1"
	local repo_path="$2"
	local outcome="$3"

	local helper="${_PCR_AUDIT_HELPER:-${SCRIPT_DIR}/audit-log-helper.sh}"
	[[ -x "$helper" ]] || return 0

	"$helper" log "$_CANONICAL_RECOVERY_AUDIT_EVENT" \
		"canonical-recovery: ${op} ${repo_path} — ${outcome}" \
		--detail "op=canonical-recovery.${op}" \
		--detail "repo=${repo_path}" \
		--detail "outcome=${outcome}" >/dev/null 2>&1 || true
	return 0
}

# Returns 0 when jq is available, 1 otherwise. Emits a one-shot warning the
# first time it returns 1 in the lifetime of this process so missing jq is
# loud but not log-spammy. Callers that depend on jq for correctness MUST
# treat a non-zero return as fail-closed (never fail-open) — jq is required
# for the hot-loop guard's persistence layer; without it we cannot count
# attempts across pulse cycles.
_pcr_jq_required() {
	if command -v jq >/dev/null 2>&1; then
		return 0
	fi
	if [[ -z "${_PCR_JQ_WARN_EMITTED:-}" ]]; then
		_pcr_log "jq is required for the hot-loop guard but is not installed — recovery will fail-closed (escalate to advisory) on every call. Install jq to restore loop-prevention."
		_PCR_JQ_WARN_EMITTED=1
	fi
	return 1
}

# -----------------------------------------------------------------------------
# State detection + attempt counting
# -----------------------------------------------------------------------------

# Detect repo state. Echoes one of:
#   "clean" | "unmerged" | "uncommitted" | "not-a-repo"
_pcr_detect_state() {
	local repo_path="$1"
	if ! git -C "$repo_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		printf 'not-a-repo'
		return 0
	fi
	# Unmerged file status codes: UU AA DD AU UA DU UD.
	if git -C "$repo_path" status --porcelain 2>/dev/null | grep -qE '^(UU|AA|DD|AU|UA|DU|UD)'; then
		printf 'unmerged'
		return 0
	fi
	if [[ -n "$(git -C "$repo_path" status --porcelain 2>/dev/null)" ]]; then
		printf 'uncommitted'
		return 0
	fi
	printf 'clean'
	return 0
}

# Count attempts in the hot window for this repo. Echoes integer.
# When jq is missing, returns MAX_ATTEMPTS so the caller's threshold check
# trips and we escalate straight to advisory rather than silently looping
# without a working guard. This is fail-closed by design.
_pcr_attempts_in_window() {
	local repo_path="$1"
	if ! _pcr_jq_required; then
		printf '%d' "$PULSE_CANONICAL_RECOVERY_MAX_ATTEMPTS"
		return 0
	fi
	local now cutoff
	now=$(date +%s)
	cutoff=$((now - PULSE_CANONICAL_RECOVERY_HOT_WINDOW))
	if [[ ! -f "$PULSE_CANONICAL_RECOVERY_STATE" ]]; then
		printf '0'
		return 0
	fi
	jq --arg path "$repo_path" --argjson cutoff "$cutoff" -r \
		'(.[$path] // []) | map(select(. >= $cutoff)) | length' \
		"$PULSE_CANONICAL_RECOVERY_STATE" 2>/dev/null || printf '0'
	return 0
}

# Record one attempt timestamp. Old entries outside the window are pruned.
# When jq is missing, this is a no-op — the missing-jq path in
# `_pcr_attempts_in_window` already escalates immediately, so persistence
# adds no value.
_pcr_record_attempt() {
	local repo_path="$1"
	local now cutoff state_dir
	now=$(date +%s)
	cutoff=$((now - PULSE_CANONICAL_RECOVERY_HOT_WINDOW))
	state_dir=$(dirname "$PULSE_CANONICAL_RECOVERY_STATE")
	mkdir -p "$state_dir" 2>/dev/null || true
	_pcr_jq_required || return 0

	local existing="{}"
	if [[ -f "$PULSE_CANONICAL_RECOVERY_STATE" ]]; then
		existing=$(cat "$PULSE_CANONICAL_RECOVERY_STATE" 2>/dev/null) || existing="{}"
		echo "$existing" | jq -e '.' >/dev/null 2>&1 || existing="{}"
	fi
	local tmp="${PULSE_CANONICAL_RECOVERY_STATE}.tmp.$$"
	if echo "$existing" | jq --arg path "$repo_path" --argjson now "$now" --argjson cutoff "$cutoff" \
		'.[$path] = ((.[$path] // []) + [$now] | map(select(. >= $cutoff)))' \
		>"$tmp" 2>/dev/null; then
		mv "$tmp" "$PULSE_CANONICAL_RECOVERY_STATE" 2>/dev/null || rm -f "$tmp" 2>/dev/null
	else
		rm -f "$tmp" 2>/dev/null
	fi
	return 0
}

# -----------------------------------------------------------------------------
# Advisory filing
# -----------------------------------------------------------------------------
#
# Channel design (t2871 — privacy fix):
#
# Canonical-recovery failures describe the affected user's local machine state
# (their worktree, their stash, their merge conflicts). Only the affected user
# can run the remediation commands; maintainers cannot act on these reports.
#
# We therefore write to the LOCAL advisory channel
# (`~/.aidevops/advisories/*.advisory`) which `aidevops-update-check.sh::
# _check_advisories` surfaces in the session-start TUI toast. This avoids
# leaking filesystem paths (username, drive topology, repo names) into the
# public framework issue tracker.
#
# Pre-t2871 behaviour filed GitHub issues against `marcusquinn/aidevops` with
# `${repo_path}` substituted verbatim — that channel was the wrong design
# (cloud-filing local advisories) AND a privacy bug. See GH#20934, #20936-
# 20941 for the leaked issues that motivated this rewrite.

# Sanitise an absolute filesystem path for any context that might be
# transmitted off the user's machine (logs, telemetry, future scanners).
# Defence-in-depth: the local advisory channel does not transmit, but if a
# log line gets shipped to OTEL or a future contribution-watch scanner picks
# up advisory text, the substitution still applies.
#
# Substitutions:
#   $HOME prefix              → ~
#   /Users/<name>/            → /Users/<user>/
#   /home/<name>/             → /home/<user>/
#   /mnt/data/<name>/         → /mnt/data/<user>/   (and similar /mnt/* roots)
#
# The original `repo_path` is NEVER stored — we recompute the basename
# separately so the advisory file name uses only the leaf repo identifier.
_pcr_sanitise_path() {
	local raw="$1"
	[[ -n "$raw" ]] || { printf ''; return 0; }

	# 1. $HOME prefix → ~ (covers macOS /Users/<me> and Linux /home/<me>
	#    when the user is the current login).
	# Strip any trailing slash so the boundary check works reliably.
	local h="${HOME%/}"
	if [[ -n "$h" && ( "$raw" == "$h" || "$raw" == "$h/"* ) ]]; then
		printf '~%s' "${raw#"$h"}"
		return 0
	fi

	# 2. Other users' home directories — strip the username segment.
	#    Bash 3.2 compatible: no =~ named captures.
	case "$raw" in
		/Users/*/*)
			# /Users/<name>/<rest> → /Users/<user>/<rest>
			local rest="${raw#/Users/}"
			rest="${rest#*/}"
			printf '/Users/<user>/%s' "$rest"
			return 0
			;;
		/home/*/*)
			local rest="${raw#/home/}"
			rest="${rest#*/}"
			printf '/home/<user>/%s' "$rest"
			return 0
			;;
		/mnt/*/*/*)
			# /mnt/<volume>/<name>/<rest> — strip the user segment but keep
			# the volume label since that's not PII (e.g. /mnt/data/<user>/Git).
			local volume="${raw#/mnt/}"
			volume="${volume%%/*}"
			local rest_after_volume="${raw#"/mnt/${volume}/"}"
			rest_after_volume="${rest_after_volume#*/}"
			printf '/mnt/%s/<user>/%s' "$volume" "$rest_after_volume"
			return 0
			;;
	esac

	# 3. Fallback — emit the basename only. We never want to emit unknown
	#    absolute paths verbatim because they may carry usernames or other
	#    PII that the cases above didn't catch.
	printf '<repo>/%s' "$(basename "$raw")"
	return 0
}

# Compose the advisory body. The body is read by humans in their own
# terminal (via session greeting) and may also be eyeballed in the
# advisory file directly. Paths are sanitised — the user can mentally
# re-substitute their own home directory.
_pcr_advisory_body() {
	local repo_path="$1"
	local failure_mode="$2"
	local repo_basename
	repo_basename=$(basename "$repo_path")
	local sanitised
	sanitised=$(_pcr_sanitise_path "$repo_path")
	cat <<EOF
[CANONICAL RECOVERY] ${repo_basename} stash conflict — manual intervention required

  Pulse cannot \`git pull --ff-only\` your canonical repo at:
      ${sanitised}

  Failure mode: ${failure_mode}
  Effect:       PR processing, CI failure routing, and completion sweep are
                paused for this repo until the working tree is clean.

  Recovery commands (run in a SEPARATE terminal, not in AI chat):

    cd ${sanitised}
    git status
    # If you see UU/AA/DD entries (unmerged):
    git merge --abort 2>/dev/null || true

    # Inspect the auto-stash if one was retained:
    git stash list | grep pulse-auto-stash

    # Restore the stash (resolve conflicts if any):
    git stash pop          # or: git stash drop  (if the stash content is obsolete)

    # Then refresh:
    git fetch origin
    git pull --ff-only

  Acceptance:
  - \`git status\` shows nothing to commit, working tree clean
  - \`git pull --ff-only\` succeeds without intervention
  - Pulse resumes processing PRs/issues for this repo on the next cycle

  Dismiss after fixing:  aidevops security dismiss canonical-recovery-${repo_basename}
EOF
	return 0
}

# File a local advisory. Idempotent — overwriting an existing advisory file
# is fine because the content is deterministic from (repo_basename,
# failure_mode) and any concurrent failure for the same repo describes the
# same condition. Honours dry-run.
#
# Advisory file naming: `canonical-recovery-<basename>.advisory`. Surfaced in
# session greeting by `aidevops-update-check.sh::_check_advisories` (line 1
# becomes the toast summary). Dismissable via
# `aidevops security dismiss canonical-recovery-<basename>`.
_pcr_file_advisory() {
	local repo_path="$1"
	local failure_mode="$2"
	local repo_basename
	repo_basename=$(basename "$repo_path")

	# Sanitise the basename for filesystem safety — strip anything that
	# isn't [A-Za-z0-9._-]. Practically all repo basenames are safe, but
	# defensive: a basename containing `/` or shell metacharacters could
	# escape the advisory directory if we trusted it raw. Bash 3.2 safe.
	local safe_basename
	safe_basename=$(printf '%s' "$repo_basename" | tr -c 'A-Za-z0-9._-' '_')
	[[ -n "$safe_basename" ]] || safe_basename="unknown"

	local advisory_file="${PULSE_CANONICAL_RECOVERY_ADVISORY_DIR}/canonical-recovery-${safe_basename}.advisory"

	if _pcr_is_dry_run; then
		_pcr_log "[dry-run] would write advisory: ${advisory_file}"
		return 0
	fi

	# Ensure the advisory directory exists. mkdir -p is a no-op if present.
	if ! mkdir -p "$PULSE_CANONICAL_RECOVERY_ADVISORY_DIR" 2>/dev/null; then
		_pcr_log "could not create advisory dir: $PULSE_CANONICAL_RECOVERY_ADVISORY_DIR"
		return 0
	fi

	# Compose body — sanitised paths only; no username/drive-topology leak.
	local body
	body=$(_pcr_advisory_body "$repo_path" "$failure_mode")

	# Atomic write via tmp+rename so a partial write never leaves a torn
	# advisory file (which would surface garbled in the session greeting).
	local tmp="${advisory_file}.tmp.$$"
	if ! printf '%s\n' "$body" >"$tmp" 2>/dev/null; then
		_pcr_log "could not write advisory tmp file: $tmp"
		rm -f "$tmp" 2>/dev/null
		return 0
	fi
	if ! mv "$tmp" "$advisory_file" 2>/dev/null; then
		_pcr_log "could not finalise advisory file: $advisory_file"
		rm -f "$tmp" 2>/dev/null
		return 0
	fi

	_pcr_log "advisory filed locally: ${advisory_file}"
	return 0
}

# -----------------------------------------------------------------------------
# Public entry point
# -----------------------------------------------------------------------------

# Main recovery routine. Returns 0 on clean / recovered, 1 on persistent
# failure (with advisory filed). Never throws.
pulse_canonical_recover() {
	local repo_path="$1"
	[[ -n "$repo_path" ]] || { _pcr_log "no repo_path provided"; return 1; }
	[[ -d "$repo_path" ]] || { _pcr_log "repo path missing: $repo_path"; return 0; }

	local state
	state=$(_pcr_detect_state "$repo_path")

	if [[ "$state" == "not-a-repo" ]]; then
		return 0
	fi
	if [[ "$state" == "clean" ]]; then
		_pcr_is_dry_run && _pcr_log "no recovery needed: $repo_path (clean)"
		return 0
	fi

	# Hot-loop guard — escalate to advisory after repeated failures.
	local attempts
	attempts=$(_pcr_attempts_in_window "$repo_path")
	if [[ "$attempts" -ge "$PULSE_CANONICAL_RECOVERY_MAX_ATTEMPTS" ]]; then
		_pcr_log "exceeded ${PULSE_CANONICAL_RECOVERY_MAX_ATTEMPTS} attempts/${PULSE_CANONICAL_RECOVERY_HOT_WINDOW}s for $repo_path (state=$state) — escalating"
		_pcr_audit "escalate" "$repo_path" "advisory:${state}"
		_pcr_file_advisory "$repo_path" "$state"
		return 1
	fi

	if _pcr_is_dry_run; then
		_pcr_log "[dry-run] would recover state=${state} on $repo_path"
		_pcr_audit "dry-run" "$repo_path" "state:${state}"
		return 0
	fi

	_pcr_record_attempt "$repo_path"
	_pcr_log "recovering ${repo_path} (state=${state})"

	# Step 1: clear unmerged state if present.
	if [[ "$state" == "unmerged" ]]; then
		# Detect stale-UU: unmerged index entries with no active merge operation.
		# This occurs when git crashes mid-merge-resolve, leaving UU entries in
		# the index but no .git/MERGE_HEAD / CHERRY_PICK_HEAD / REBASE_HEAD
		# sentinel file.  In that case `git merge --abort` fails with "no merge
		# to abort" (exit 1) — the fallback `git reset --merge HEAD` clears the
		# stale conflict entries while preserving unrelated working-tree edits.
		# Without this path the code falls through to `stash push` which also
		# fails on unresolved conflicts, escalating unnecessarily to an advisory
		# (GH#20935).
		local is_stale_uu=0
		if [[ ! -e "${repo_path}/.git/MERGE_HEAD" \
		   && ! -e "${repo_path}/.git/CHERRY_PICK_HEAD" \
		   && ! -e "${repo_path}/.git/REBASE_HEAD" ]]; then
			is_stale_uu=1
			_pcr_log "stale-UU detected (no active merge/cherry-pick/rebase) for $repo_path"
			_pcr_audit "stale-uu-detect" "$repo_path" "attempting"
			# merge --abort is a no-op without an active merge but is safe to
			# try — it may succeed in edge cases where the HEAD file was
			# manually removed.  If it fails, reset --merge HEAD is the
			# definitive fix for stale index conflict entries.
			git -C "$repo_path" merge --abort 2>/dev/null \
				|| git -C "$repo_path" reset --merge HEAD 2>/dev/null \
				|| true
		else
			# Active merge / cherry-pick / rebase — abort it cleanly.
			git -C "$repo_path" merge --abort 2>/dev/null || true
		fi

		state=$(_pcr_detect_state "$repo_path")
		if [[ "$state" == "clean" ]]; then
			if [[ "$is_stale_uu" -eq 1 ]]; then
				_pcr_audit "stale-uu-recover" "$repo_path" "ok:index-reset"
				_pcr_log "stale-UU cleared via index reset for $repo_path"
			else
				_pcr_audit "merge-abort" "$repo_path" "success"
				_pcr_log "merge --abort cleaned working tree for $repo_path"
			fi
			return 0
		fi
	fi

	# Step 2: stash uncommitted changes (-u includes untracked).
	local stash_message
	stash_message="pulse-auto-stash-$(date +%s)"
	if ! git -C "$repo_path" stash push -u -m "$stash_message" >>"${LOGFILE:-/dev/null}" 2>&1; then
		_pcr_audit "stash-push-failed" "$repo_path" "advisory"
		_pcr_log "git stash push failed; filing advisory"
		_pcr_file_advisory "$repo_path" "stash-push-failed"
		return 1
	fi
	_pcr_log "stashed: ${stash_message}"
	_pcr_audit "stash-push" "$repo_path" "ok:${stash_message}"

	# Step 3: re-fetch + retry pull.
	local pull_ok=0
	if git -C "$repo_path" fetch --quiet origin >>"${LOGFILE:-/dev/null}" 2>&1 \
		&& git -C "$repo_path" pull --ff-only --no-rebase >>"${LOGFILE:-/dev/null}" 2>&1; then
		pull_ok=1
	fi

	if [[ "$pull_ok" -ne 1 ]]; then
		# Pull still failed after stashing — leave stash for content safety.
		_pcr_audit "pull-failed-after-stash" "$repo_path" "advisory:stash-retained:${stash_message}"
		_pcr_log "pull --ff-only failed after stash — stash retained, filing advisory"
		_pcr_file_advisory "$repo_path" "pull-failed-after-stash"
		return 1
	fi

	# Step 4: pop the stash. Conflict on pop → leave stash + advise.
	if ! git -C "$repo_path" stash pop --quiet >>"${LOGFILE:-/dev/null}" 2>&1; then
		_pcr_audit "stash-pop-conflict" "$repo_path" "advisory:stash-retained:${stash_message}"
		_pcr_log "git stash pop conflict — stash retained, filing advisory"
		_pcr_file_advisory "$repo_path" "stash-pop-conflict"
		return 1
	fi

	_pcr_audit "success" "$repo_path" "stash-pull-pop-clean"
	_pcr_log "recovered cleanly: $repo_path"
	return 0
}

# -----------------------------------------------------------------------------
# Standalone CLI
# -----------------------------------------------------------------------------

_pcr_print_help() {
	cat <<'EOF'
pulse-canonical-recovery.sh — auto-recover canonical worktree from pull conflicts

Usage:
  pulse-canonical-recovery.sh [--dry-run] <repo-path>
  pulse-canonical-recovery.sh --help

Options:
  --dry-run     Detect state and log planned actions without executing them.
  --help, -h    Show this message.

Exit codes:
  0  No recovery needed, or recovery succeeded.
  1  Persistent failure — advisory issue filed (or would be in dry-run).
  2  Usage error (missing or extra arguments).

Environment:
  PULSE_CANONICAL_RECOVERY_HOT_WINDOW          Window (s) for attempt counting
                                                (default: 3600).
  PULSE_CANONICAL_RECOVERY_MAX_ATTEMPTS        Max attempts in window before
                                                escalating (default: 3).
  PULSE_CANONICAL_RECOVERY_STATE               State file path
                                                (default: ~/.aidevops/.agent-workspace/supervisor/canonical-recovery-state.json).
  DRY_RUN                                      Set to 1 for dry-run via env
                                                (alternative to --dry-run).
EOF
}

_pcr_main() {
	local repo_path=""
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
			--dry-run)
				_PULSE_CANONICAL_RECOVERY_DRY_RUN=1
				shift
				;;
			--help | -h)
				_pcr_print_help
				return 0
				;;
			-*)
				_pcr_log "unknown option: $arg"
				_pcr_print_help >&2
				return 2
				;;
			*)
				if [[ -n "$repo_path" ]]; then
					_pcr_log "extra positional argument: $arg"
					_pcr_print_help >&2
					return 2
				fi
				repo_path="$arg"
				shift
				;;
		esac
	done

	if [[ -z "$repo_path" ]]; then
		_pcr_log "repo-path is required"
		_pcr_print_help >&2
		return 2
	fi

	pulse_canonical_recover "$repo_path"
	return $?
}

# When executed directly (not sourced), run _pcr_main.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	_pcr_main "$@"
	exit $?
fi
