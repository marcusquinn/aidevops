#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# interactive-session-helper.sh - Interactive session issue-ownership primitive (t2056)
#
# Purpose: provide a mandatory, AI-driven acquire/release primitive for
# interactive GitHub issue ownership. When an interactive session engages
# with an issue, this helper applies `status:in-review` + self-assignment
# so the pulse's dispatch-dedup guard (`dispatch-dedup-helper.sh is-assigned`)
# will not dispatch a parallel worker.
#
# Why reuse status:in-review rather than a new label:
#   - `_has_active_claim` in dispatch-dedup-helper.sh already treats it as an
#     active claim that blocks dispatch.
#   - `_normalize_stale_should_skip_reset` in pulse-issue-reconcile.sh already
#     skips it during stale-recovery (only queued/in-progress get reset).
#   - `ISSUE_STATUS_LABEL_PRECEDENCE` in shared-constants.sh already ranks it
#     second after `done` for label-invariant reconciliation.
#   - `.github/workflows/issue-sync.yml` already clears it on PR-close cleanup.
# All the gating infrastructure is in place. The only gap this helper closes
# is timing: today the label lands at PR open (via `full-loop-helper.sh
# commit-and-pr`); we need it to land at interactive session engage.
#
# AI-driven contract:
#   The primary enforcement layer is a `prompts/build.txt` rule telling the
#   agent to call claim/release from conversation intent. Phase 2 (t2057)
#   adds code-level safety nets in worktree-helper.sh, claim-task-id.sh, and
#   approval-helper.sh. Users are never expected to invoke this helper by
#   hand — the slash command and CLI exist as fallbacks only.
#
# Usage:
#   interactive-session-helper.sh claim <issue> <slug> [--worktree PATH]
#   interactive-session-helper.sh release <issue> <slug> [--unassign]
#   interactive-session-helper.sh status [<issue>]
#   interactive-session-helper.sh scan-stale
#   interactive-session-helper.sh help

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

# Stamp directory for crash-recovery metadata. Each claim writes one JSON file
# keyed by "<slug-flat>-<issue>.json" so stamps are unique per-repo per-issue.
# Matches the `~/.aidevops/.agent-workspace/` convention from prompts/build.txt.
CLAIM_STAMP_DIR="${HOME}/.aidevops/.agent-workspace/interactive-claims"

# -----------------------------------------------------------------------------
# Logging (all to stderr so stdout stays machine-readable)
# -----------------------------------------------------------------------------
# Colours: green=ok, yellow=warn, red=err. Fall through to plain text if the
# terminal doesn't support ANSI (log_info / log_warn from shared-constants.sh
# are sourced above, but we define local wrappers for consistency with other
# helpers in this directory).

_isc_info() {
	printf '[interactive-session] %s\n' "$*" >&2
	return 0
}

_isc_warn() {
	printf '[interactive-session] WARN: %s\n' "$*" >&2
	return 0
}

_isc_err() {
	printf '[interactive-session] ERROR: %s\n' "$*" >&2
	return 0
}

# -----------------------------------------------------------------------------
# Internal helpers
# -----------------------------------------------------------------------------

# Flatten a slug ("owner/repo") into a filename-safe token ("owner-repo").
_isc_slug_flat() {
	local slug="$1"
	printf '%s' "${slug//\//-}"
	return 0
}

# Resolve the stamp file path for an issue in a repo.
_isc_stamp_path() {
	local issue="$1"
	local slug="$2"
	printf '%s/%s-%s.json' "$CLAIM_STAMP_DIR" "$(_isc_slug_flat "$slug")" "$issue"
	return 0
}

# Resolve the current GitHub user login. Returns empty string on failure so
# callers can decide whether to proceed or abort.
_isc_current_user() {
	local login
	login=$(gh api user --jq '.login' 2>/dev/null || echo "")
	# Reject JSON null / empty / literal "null"
	if [[ -z "$login" || "$login" == "null" ]]; then
		printf ''
		return 0
	fi
	printf '%s' "$login"
	return 0
}

# Check whether the `gh` CLI is reachable and authenticated. Returns 0 when
# usable, 1 otherwise. Used as the offline/auth gate in `claim` so we can
# warn-and-continue rather than fail-close.
_isc_gh_reachable() {
	if ! command -v gh >/dev/null 2>&1; then
		return 1
	fi
	# gh auth status is cheap and covers both offline and deauth cases
	if ! gh auth status >/dev/null 2>&1; then
		return 1
	fi
	return 0
}

# Check whether an issue already carries `status:in-review`. Returns 0 when
# present, 1 when absent, 2 when the metadata lookup failed.
#
# NOTE on the jq query: the two-argument form `any(generator; condition)`
# passed `.name` as the generator on `(.labels // [])`, which tries to
# index the *array itself* with string "name" and raises
# "Cannot index array with string". The single-argument form
# `any(condition)` iterates over the array automatically, which is both
# shorter and correct. This was a latent bug that masked the bug fixed
# in GH#18786 — the jq error (exit 5) was swallowed by `>/dev/null 2>&1`
# and the function always returned 1 ("label absent"), so the idempotency
# branch was dead code even before the set -e exit propagation killed
# the whole claim flow.
_isc_has_in_review() {
	local issue="$1"
	local slug="$2"
	local json
	json=$(gh issue view "$issue" --repo "$slug" --json labels 2>/dev/null) || return 2
	if printf '%s' "$json" | jq -e '(.labels // []) | any(.name == "status:in-review")' >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

# Write a stamp JSON file for a claim. Idempotent — overwrites on re-call so
# the `claimed_at` timestamp refreshes for crash-recovery tie-breaks.
_isc_write_stamp() {
	local issue="$1"
	local slug="$2"
	local worktree_path="$3"
	local user="$4"

	mkdir -p "$CLAIM_STAMP_DIR" 2>/dev/null || {
		_isc_warn "cannot create stamp dir: $CLAIM_STAMP_DIR (continuing)"
		return 0
	}

	local stamp_file
	stamp_file=$(_isc_stamp_path "$issue" "$slug")

	local timestamp hostname
	timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	hostname=$(hostname 2>/dev/null || echo "unknown")

	# Escape user-supplied fields via jq's string literals to avoid JSON injection
	jq -n \
		--arg issue "$issue" \
		--arg slug "$slug" \
		--arg worktree "$worktree_path" \
		--arg claimed_at "$timestamp" \
		--arg pid "$$" \
		--arg hostname "$hostname" \
		--arg user "$user" \
		'{
			issue: ($issue | tonumber),
			slug: $slug,
			worktree_path: $worktree,
			claimed_at: $claimed_at,
			pid: ($pid | tonumber),
			hostname: $hostname,
			user: $user
		}' >"$stamp_file" 2>/dev/null || {
		_isc_warn "failed to write stamp: $stamp_file"
		return 0
	}
	return 0
}

# Delete a stamp file. No-op when the file doesn't exist.
_isc_delete_stamp() {
	local issue="$1"
	local slug="$2"
	local stamp_file
	stamp_file=$(_isc_stamp_path "$issue" "$slug")
	rm -f "$stamp_file" 2>/dev/null || true
	return 0
}

# -----------------------------------------------------------------------------
# Subcommand: claim
# -----------------------------------------------------------------------------
# Apply status:in-review, self-assign, and write a stamp.
#
# Arguments:
#   $1 = issue number
#   $2 = repo slug (owner/repo)
#   [--worktree PATH] = optional worktree path to record in the stamp
#
# Behaviour:
#   - Offline gh: warn-and-continue (exit 0). A collision with a pulse worker
#     is harmless — the interactive work naturally becomes its own issue/PR.
#   - Idempotent: re-calling on an already-claimed issue refreshes the stamp
#     timestamp but does not re-transition the label (saves an API round-trip).
#   - Non-blocking on gh failures: best-effort label transition; all gh
#     errors are swallowed so the caller's interactive workflow never stalls.
#
# Exit: 0 always (warn-and-continue contract).
_isc_cmd_claim() {
	local issue="" slug="" worktree_path=""

	# Parse positional + flags
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--worktree)
			worktree_path="${2:-}"
			shift 2
			;;
		--worktree=*)
			worktree_path="${1#--worktree=}"
			shift
			;;
		-h | --help)
			_isc_cmd_help
			return 0
			;;
		*)
			if [[ -z "$issue" ]]; then
				issue="$1"
			elif [[ -z "$slug" ]]; then
				slug="$1"
			else
				_isc_warn "unexpected argument: $1 (ignored)"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$issue" || -z "$slug" ]]; then
		_isc_err "claim: <issue> and <slug> are required"
		_isc_err "usage: interactive-session-helper.sh claim <issue> <slug> [--worktree PATH]"
		return 2
	fi

	if [[ ! "$issue" =~ ^[0-9]+$ ]]; then
		_isc_err "claim: <issue> must be numeric (got: $issue)"
		return 2
	fi

	# Offline gate — warn and exit 0 so the caller continues
	if ! _isc_gh_reachable; then
		_isc_warn "gh offline or not authenticated — skipping claim on #$issue ($slug)"
		_isc_warn "a collision with a worker is harmless; the interactive work will become its own issue/PR"
		return 0
	fi

	local user
	user=$(_isc_current_user)
	if [[ -z "$user" ]]; then
		_isc_warn "could not resolve gh user login — skipping claim on #$issue"
		return 0
	fi

	# Idempotency: if already in-review, just refresh the stamp and exit.
	# NOTE: `_isc_has_in_review` legitimately returns non-zero ("label absent"
	# = 1, "lookup failed" = 2). Under `set -e`, a bare call followed by
	# `local rc=$?` capture kills this function before `rc=$?` runs — because
	# the unchecked non-zero return propagates up through the parent function.
	# Use a direct `if` conditional so the return is consumed by the branch,
	# which `set -e` treats as a tested condition and does not propagate.
	# Sibling bug class: GH#18770 (pulse self-check), GH#18784 (aidevops.sh getent).
	if _isc_has_in_review "$issue" "$slug"; then
		_isc_info "claim: #$issue already has status:in-review — refreshing stamp"
		_isc_write_stamp "$issue" "$slug" "$worktree_path" "$user"
		return 0
	fi

	# Transition to in-review with atomic self-assign. Uses set_issue_status
	# from shared-constants.sh which removes all sibling core status labels
	# in the same gh call — preserves the t2033 mutual-exclusivity invariant.
	if set_issue_status "$issue" "$slug" "in-review" --add-assignee "$user" >/dev/null 2>&1; then
		_isc_info "claim: #$issue in $slug → status:in-review + assigned $user"
		_isc_write_stamp "$issue" "$slug" "$worktree_path" "$user"
		return 0
	fi

	# Fallback: gh failed. Warn but don't block the caller.
	_isc_warn "claim: gh failed on #$issue — continuing without lock (collision is harmless)"
	return 0
}

# -----------------------------------------------------------------------------
# Subcommand: release
# -----------------------------------------------------------------------------
# Transition status:in-review -> status:available and delete the stamp.
#
# Arguments:
#   $1 = issue number
#   $2 = repo slug (owner/repo)
#   [--unassign] = also remove self from assignees
#
# Behaviour:
#   - Idempotent: no-op when the label is not set.
#   - Offline gh: warn and exit 0. The stamp is still deleted so local state
#     matches the caller's intent.
#
# Exit: 0 always.
_isc_cmd_release() {
	local issue="" slug="" unassign=0

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--unassign)
			unassign=1
			shift
			;;
		-h | --help)
			_isc_cmd_help
			return 0
			;;
		*)
			if [[ -z "$issue" ]]; then
				issue="$1"
			elif [[ -z "$slug" ]]; then
				slug="$1"
			else
				_isc_warn "unexpected argument: $1 (ignored)"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$issue" || -z "$slug" ]]; then
		_isc_err "release: <issue> and <slug> are required"
		return 2
	fi

	if [[ ! "$issue" =~ ^[0-9]+$ ]]; then
		_isc_err "release: <issue> must be numeric (got: $issue)"
		return 2
	fi

	# Always delete the stamp so local state reflects caller intent
	_isc_delete_stamp "$issue" "$slug"

	if ! _isc_gh_reachable; then
		_isc_warn "gh offline — stamp deleted locally, label unchanged on #$issue"
		return 0
	fi

	# Idempotency: skip label work if not in-review. `_isc_has_in_review`
	# has three return states (0 = present, 1 = absent, 2 = lookup failed),
	# so we need the actual rc — but a bare call under `set -e` propagates
	# non-zero returns before `rc=$?` can capture them. Use `|| rc=$?` which
	# is a tested condition that `set -e` does not propagate. Default to 0
	# so the "present" branch (rc=0) falls through to the transition below.
	local has_rc=0
	_isc_has_in_review "$issue" "$slug" || has_rc=$?
	if [[ $has_rc -eq 1 ]]; then
		_isc_info "release: #$issue not in status:in-review — no-op"
		return 0
	fi
	if [[ $has_rc -eq 2 ]]; then
		_isc_warn "release: could not read labels for #$issue — skipping label transition"
		return 0
	fi

	# Transition in-review -> available. Build the flag list as a plain
	# array and expand it with the `${arr[@]+"${arr[@]}"}` guard so an
	# empty array doesn't trip `set -u` on bash 3.2 (macOS default). This
	# is the idiom documented in reference/bash-compat.md "empty array
	# expansion". Fourth latent bug found alongside GH#18786: previously
	# masked because the broken jq query made this branch unreachable.
	local -a extra_flags=()
	if [[ $unassign -eq 1 ]]; then
		local user
		user=$(_isc_current_user)
		if [[ -n "$user" ]]; then
			extra_flags+=(--remove-assignee "$user")
		fi
	fi

	if set_issue_status "$issue" "$slug" "available" ${extra_flags[@]+"${extra_flags[@]}"} >/dev/null 2>&1; then
		_isc_info "release: #$issue → status:available"
		return 0
	fi

	_isc_warn "release: gh failed on #$issue — label may still be set"
	return 0
}

# -----------------------------------------------------------------------------
# Subcommand: status
# -----------------------------------------------------------------------------
# Print active claims from the stamp directory. With <issue>: exit 0 if this
# user holds a claim on that issue, 1 otherwise.
#
# Output is human-readable on stdout so the agent can parse it.
_isc_cmd_status() {
	local target_issue="${1:-}"

	if [[ ! -d "$CLAIM_STAMP_DIR" ]]; then
		if [[ -n "$target_issue" ]]; then
			return 1
		fi
		printf 'No active interactive claims.\n'
		return 0
	fi

	local found=0
	local stamp
	for stamp in "$CLAIM_STAMP_DIR"/*.json; do
		[[ -f "$stamp" ]] || continue
		local issue slug worktree claimed pid hostname user
		issue=$(jq -r '.issue // empty' "$stamp" 2>/dev/null || echo "")
		slug=$(jq -r '.slug // empty' "$stamp" 2>/dev/null || echo "")
		worktree=$(jq -r '.worktree_path // empty' "$stamp" 2>/dev/null || echo "")
		claimed=$(jq -r '.claimed_at // empty' "$stamp" 2>/dev/null || echo "")
		pid=$(jq -r '.pid // empty' "$stamp" 2>/dev/null || echo "")
		hostname=$(jq -r '.hostname // empty' "$stamp" 2>/dev/null || echo "")
		user=$(jq -r '.user // empty' "$stamp" 2>/dev/null || echo "")

		if [[ -z "$issue" || -z "$slug" ]]; then
			continue
		fi

		if [[ -n "$target_issue" && "$issue" != "$target_issue" ]]; then
			continue
		fi

		found=1
		printf '#%s in %s\n' "$issue" "$slug"
		printf '  user:     %s\n' "${user:-unknown}"
		printf '  worktree: %s\n' "${worktree:-unknown}"
		printf '  claimed:  %s\n' "${claimed:-unknown}"
		printf '  pid:      %s on %s\n' "${pid:-unknown}" "${hostname:-unknown}"
	done

	if [[ $found -eq 0 ]]; then
		if [[ -n "$target_issue" ]]; then
			return 1
		fi
		printf 'No active interactive claims.\n'
	fi
	return 0
}

# -----------------------------------------------------------------------------
# Subcommand: scan-stale
# -----------------------------------------------------------------------------
# For each stamp: check if the PID is alive AND the worktree path still
# exists. Print a human-readable advisory. Does NOT auto-release — the agent
# is expected to parse the output and prompt the user.
#
# Exit: 0 always.
_isc_cmd_scan_stale() {
	if [[ ! -d "$CLAIM_STAMP_DIR" ]]; then
		printf 'No interactive claims to scan.\n'
		return 0
	fi

	local stale_count=0
	local stamp
	for stamp in "$CLAIM_STAMP_DIR"/*.json; do
		[[ -f "$stamp" ]] || continue
		local issue slug worktree pid hostname
		issue=$(jq -r '.issue // empty' "$stamp" 2>/dev/null || echo "")
		slug=$(jq -r '.slug // empty' "$stamp" 2>/dev/null || echo "")
		worktree=$(jq -r '.worktree_path // empty' "$stamp" 2>/dev/null || echo "")
		pid=$(jq -r '.pid // empty' "$stamp" 2>/dev/null || echo "")
		hostname=$(jq -r '.hostname // empty' "$stamp" 2>/dev/null || echo "")

		[[ -z "$issue" || -z "$slug" ]] && continue

		# Only consider stamps from the current hostname — cross-machine
		# stamps can't be verified and we don't want to surface them as stale.
		local local_host
		local_host=$(hostname 2>/dev/null || echo "unknown")
		if [[ "$hostname" != "$local_host" ]]; then
			continue
		fi

		local pid_alive=0
		if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
			pid_alive=1
		fi

		local worktree_exists=0
		if [[ -n "$worktree" && -d "$worktree" ]]; then
			worktree_exists=1
		fi

		if [[ $pid_alive -eq 0 && $worktree_exists -eq 0 ]]; then
			if [[ $stale_count -eq 0 ]]; then
				printf 'Stale interactive claims (dead PID and missing worktree):\n'
				printf '\n'
			fi
			printf '  #%s in %s\n' "$issue" "$slug"
			printf '    worktree: %s (missing)\n' "${worktree:-unknown}"
			printf '    pid:      %s (dead)\n' "${pid:-unknown}"
			printf '    release:  aidevops issue release %s\n' "$issue"
			printf '\n'
			stale_count=$((stale_count + 1))
		fi
	done

	if [[ $stale_count -eq 0 ]]; then
		printf 'No stale interactive claims.\n'
	else
		# shellcheck disable=SC2016  # backticks are literal text, not command substitution
		printf 'Total: %d stale claim(s). Release via `aidevops issue release <N>` or reclaim by `cd`-ing into the worktree.\n' "$stale_count"
	fi
	return 0
}

# -----------------------------------------------------------------------------
# Subcommand: help
# -----------------------------------------------------------------------------
_isc_cmd_help() {
	cat <<'EOF'
interactive-session-helper.sh - Interactive issue-ownership primitive (t2056)

USAGE:
  interactive-session-helper.sh claim <issue> <slug> [--worktree PATH]
      Apply status:in-review + self-assign + write crash-recovery stamp.
      Idempotent. Offline gh → warn-and-continue (exit 0).

  interactive-session-helper.sh release <issue> <slug> [--unassign]
      Transition status:in-review → status:available, delete stamp.
      Idempotent. --unassign also removes self from assignees.

  interactive-session-helper.sh status [<issue>]
      List active claims from the stamp directory, or check one issue.

  interactive-session-helper.sh scan-stale
      Identify stamps with dead PID AND missing worktree path. Does NOT
      auto-release — agent parses output and prompts the user.

  interactive-session-helper.sh help
      Print this message.

CONTRACT:
  This helper is intended to be called from interactive AI sessions, driven
  by conversation intent (see `prompts/build.txt` → "Interactive issue
  ownership"). Users should never need to invoke it directly — the agent
  claims on engage and releases on signal.

  Slug format: owner/repo (e.g., marcusquinn/aidevops).

STAMP DIRECTORY:
  ~/.aidevops/.agent-workspace/interactive-claims/
EOF
	return 0
}

# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------

main() {
	local cmd="${1:-help}"
	local rc=0
	shift || true

	# `|| rc=$?` is the `set -e`-safe idiom for capturing subcommand exit
	# codes. A bare call inside a case branch propagates non-zero returns
	# out of main() before `return $?` runs (e.g. _isc_cmd_status returning
	# 1 for "target issue not found"). Use a tested-condition capture so
	# set -e treats the subcommand as a branch condition and leaves rc intact.
	case "$cmd" in
	claim)
		_isc_cmd_claim "$@" || rc=$?
		;;
	release)
		_isc_cmd_release "$@" || rc=$?
		;;
	status)
		_isc_cmd_status "$@" || rc=$?
		;;
	scan-stale)
		_isc_cmd_scan_stale "$@" || rc=$?
		;;
	help | -h | --help)
		_isc_cmd_help || rc=$?
		;;
	*)
		_isc_err "unknown subcommand: $cmd"
		_isc_cmd_help || true
		return 2
		;;
	esac
	return "$rc"
}

# Only run main when executed, not when sourced (allows tests to source and
# call internal functions directly without triggering the help dispatcher)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
