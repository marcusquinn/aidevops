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
# SCOPE LIMITATION (GH#19861):
#   `claim` blocks the pulse's DISPATCH path only. It does NOT block:
#   - The enrich path (pulse-enrich.sh) — may overwrite issue title/body/labels
#   - The completion-sweep path — may strip status labels
#   - Any other non-dispatch pulse operation that modifies label/title/body state
#   If you need protection against ALL pulse modifications (e.g., investigating
#   a pulse bug), use `lockdown` instead — it applies `no-auto-dispatch` +
#   `status:in-review` + self-assignment + conversation lock + audit comment.
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
#   interactive-session-helper.sh claim <issue> <slug> [--worktree PATH] [--implementing]
#   interactive-session-helper.sh release <issue> <slug> [--unassign]
#   interactive-session-helper.sh lockdown <issue> <slug> [--worktree PATH]
#   interactive-session-helper.sh unlock <issue> <slug> [--unassign]
#   interactive-session-helper.sh status [<issue>]
#   interactive-session-helper.sh scan-stale
#   interactive-session-helper.sh post-merge <pr_number> [<slug>]
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

# Generic label probe — returns 0 if the issue carries the named label, 1 if
# absent, 2 if the gh lookup failed. Caller MUST use a direct `if` conditional
# (not bare call + $? capture) to avoid the same set -e propagation foot-gun
# documented above for `_isc_has_in_review` (GH#18786).
#
# Used by `_isc_cmd_claim` to honour the t2218 auto-dispatch carve-out at the
# manual-claim entry point (GH#20946) and could be reused by other callers
# that need to probe a specific label without parsing the full label JSON.
_isc_has_label() {
	local issue="$1"
	local slug="$2"
	local label="$3"
	local json
	json=$(gh issue view "$issue" --repo "$slug" --json labels 2>/dev/null) || return 2
	if printf '%s' "$json" | jq -e --arg name "$label" '(.labels // []) | any(.name == $name)' >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

# Single-pass auto-dispatch carve-out probe (GH#20946 PR #20977 review).
# Combines the two-call (`auto-dispatch` AND NOT `parent-task`) probe into one
# `gh issue view` round-trip. Addresses two review findings together:
#   - gemini-code-assist: redundant gh+jq calls in the claim hot path
#   - augmentcode: the prior two-call form's inner `if !` branch conflated
#     rc=1 (parent-task absent → carve-out applies) with rc=2 (gh lookup
#     failed → caller intent unknown), failing CLOSED on transient errors
#     and contradicting the outer fail-OPEN comment.
#
# Returns:
#   0  carve-out applies — has `auto-dispatch` AND lacks `parent-task`. Caller
#      MUST refuse to claim; self-assign would create a permanent dispatch
#      block per the t1996/t2218 invariant (see _has_active_claim in
#      dispatch-dedup-helper.sh).
#   1  carve-out does NOT apply — auto-dispatch absent OR parent-task present.
#      Caller proceeds with the normal claim path.
#   2  lookup failed (gh offline, network, auth). Caller falls through and
#      proceeds with the claim — fail-OPEN. A spurious carve-out skip on a
#      transient error would be just as harmful as a missed carve-out;
#      proceeding matches the offline gate at the top of `_isc_cmd_claim`.
#
# `if [[ $implementing -eq 0 ]] && _isc_carve_out_required ...; then` is the
# canonical caller form — only enters the skip branch on rc=0; rc=1 and rc=2
# both fall through. The `&&` short-circuit also consumes any non-zero return
# through a conditional context, protecting against set -e propagation
# (GH#18786 sibling class).
_isc_carve_out_required() {
	local issue="$1"
	local slug="$2"
	local json
	json=$(gh issue view "$issue" --repo "$slug" --json labels 2>/dev/null) || return 2
	if printf '%s' "$json" | jq -e '
		(.labels // []) |
		(any(.name == "auto-dispatch")) and
		(any(.name == "parent-task") | not)
	' >/dev/null 2>&1; then
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

	# t2421: compute argv hash for PID-reuse-resistant liveness checks.
	# Stored in the stamp so scan-stale can verify PID identity later.
	local argv_hash=""
	argv_hash=$(_compute_argv_hash "$$" 2>/dev/null || echo "")

	# Escape user-supplied fields via jq's string literals to avoid JSON injection
	jq -n \
		--arg issue "$issue" \
		--arg slug "$slug" \
		--arg worktree "$worktree_path" \
		--arg claimed_at "$timestamp" \
		--arg pid "$$" \
		--arg hostname "$hostname" \
		--arg user "$user" \
		--arg argv_hash "$argv_hash" \
		'{
			issue: ($issue | tonumber),
			slug: $slug,
			worktree_path: $worktree,
			claimed_at: $claimed_at,
			pid: ($pid | tonumber),
			hostname: $hostname,
			user: $user,
			owner_argv_hash: $argv_hash
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

# List stampless origin:interactive claims for a single repo (t2148).
#
# Detection rule: an issue is a "stampless interactive claim" when all of:
#   - state: OPEN
#   - .labels[] contains "origin:interactive"
#   - .assignees[] contains runner_user
#   - no matching stamp file exists at $(_isc_stamp_path issue slug)
#
# These are the zombie claims that block pulse dispatch forever:
# `_has_active_claim()` (in dispatch-dedup-helper.sh) treats
# `origin:interactive` as an active claim regardless of stamp state,
# but `_isc_cmd_scan_stale` Phase 1 only iterates `$CLAIM_STAMP_DIR`
# so stampless ones are invisible. Typical cause: `claim-task-id.sh`
# auto-assigned runner on issue creation (per t1970 for maintainer-gate
# protection), but the interactive session never ran the formal claim
# flow, so no stamp was written.
#
# Args:
#   $1 runner_user — GH login of current runner (from `gh api user`)
#   $2 slug        — owner/repo
# Stdout: newline-separated JSON lines `{"number":N,"updated_at":"...",
#         "slug":"..."}` (one per stampless claim). Empty on failure.
# Exit: 0 always (fail-open for discovery — a transient gh/jq error
#       should not mask genuine claims on the next scan).
_isc_list_stampless_interactive_claims() {
	local runner_user="$1"
	local slug="$2"

	[[ -n "$runner_user" && -n "$slug" ]] || return 0

	local json
	json=$(gh issue list --repo "$slug" \
		--assignee "$runner_user" \
		--label origin:interactive \
		--state open \
		--json number,updatedAt,labels \
		--limit 200 2>/dev/null) || return 0

	[[ -n "$json" && "$json" != "null" ]] || return 0

	# GH#20048: filter out non-task issues (routine-tracking, supervisor, etc.)
	# before the stampless scan so they are never surfaced as false positives.
	json=$(printf '%s' "$json" | _filter_non_task_issues) || return 0
	[[ -n "$json" && "$json" != "[]" ]] || return 0

	# Emit (number, updated_at) tuples; shell filters stampless.
	local rows
	rows=$(printf '%s' "$json" | jq -r '
		.[] | "\(.number)\t\(.updatedAt)"
	' 2>/dev/null) || return 0

	[[ -n "$rows" ]] || return 0

	local issue updated_at stamp
	while IFS=$'\t' read -r issue updated_at; do
		[[ "$issue" =~ ^[0-9]+$ ]] || continue
		stamp=$(_isc_stamp_path "$issue" "$slug")
		if [[ ! -f "$stamp" ]]; then
			# Emit compact (single-line) JSON so callers can parse row-by-row
			# via `while IFS= read -r row`. Pretty-printed multi-line output
			# breaks line-based parsing (see t2148 Test 14 regression).
			jq -nc \
				--arg slug "$slug" \
				--arg updated_at "$updated_at" \
				--arg issue "$issue" \
				'{number: ($issue | tonumber), updated_at: $updated_at, slug: $slug}' \
				2>/dev/null || true
		fi
	done <<<"$rows"

	return 0
}

# Post a claim comment on the issue for audit trail visibility.
# Mirrors worker dispatch comments but for interactive sessions.
# Best-effort — all errors are swallowed so the caller never stalls.
#
# Arguments:
#   $1 = issue number, $2 = repo slug, $3 = user login, $4 = worktree path
_isc_post_claim_comment() {
	local issue="$1"
	local slug="$2"
	local user="$3"
	local worktree_path="$4"

	local hostname
	hostname=$(hostname 2>/dev/null || echo "unknown")
	local worktree_note=""
	if [[ -n "$worktree_path" ]]; then
		worktree_note=" in \`${worktree_path##*/}\`"
	fi

	# <!-- ops:start --> / <!-- ops:end --> markers let the agent skip this
	# comment when reading issue threads (see build.txt 8d).
	local body
	body=$(
		cat <<EOF
<!-- ops:start -->
> Interactive session claimed by @${user}${worktree_note} on ${hostname}.
> Pulse dispatch blocked via \`status:in-review\` + self-assignment.
<!-- ops:end -->
EOF
	)

	gh_issue_comment "$issue" --repo "$slug" --body "$body" >/dev/null 2>&1 || {
		_isc_warn "claim comment failed on #$issue — continuing (audit trail incomplete)"
	}
	return 0
}

# -----------------------------------------------------------------------------
# Subcommand: claim
# -----------------------------------------------------------------------------
# Apply status:in-review, self-assign, and write a stamp.
#
# SCOPE: blocks pulse DISPATCH only. Does NOT block enrich, completion-sweep,
# or other non-dispatch pulse operations that modify issue state. For full
# insulation from all pulse paths, use `lockdown` instead. (GH#19861)
#
# Arguments:
#   $1 = issue number
#   $2 = repo slug (owner/repo)
#   [--worktree PATH] = optional worktree path to record in the stamp
#   [--implementing] = opt in to claim an `auto-dispatch`-tagged issue
#                      that the caller intends to implement themselves.
#                      Without this flag, the helper refuses to claim
#                      auto-dispatch issues so the pulse can dispatch a
#                      worker (see auto-dispatch carve-out below).
#
# Auto-dispatch carve-out (GH#20946):
#   Calling claim on an `auto-dispatch`-tagged issue WITHOUT `--implementing`
#   is a no-op — it warns and exits 0. Three creation-time entry points already
#   skip self-assign on auto-dispatch (t2218, t2132, t2157/t2406); this probe
#   extends the same invariant to the manual `claim` subcommand. Without the
#   probe, claim would create the (origin:interactive + assignee + status:in-review)
#   combination that `_has_active_claim` in dispatch-dedup-helper.sh treats as an
#   active claim, permanently blocking pulse dispatch (t1996/GH#18352).
#
#   `parent-task` issues are exempt from the probe — they're decomposition
#   trackers the maintainer needs to own, and `parent-task` already blocks
#   dispatch via `PARENT_TASK_BLOCKED` upstream of the auto-dispatch path.
#
#   Use `--implementing` when the AGENTS.md "Implementing a #auto-dispatch
#   task interactively" mandate applies — i.e. when the agent legitimately
#   intends to take the issue itself instead of letting a worker pick it up.
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
	local issue="" slug="" worktree_path="" implementing=0

	# Parse positional + flags
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--worktree)
			worktree_path="${2:-}"
			shift 2
			;;
		--worktree=*)
			worktree_path="${arg#--worktree=}"
			shift
			;;
		--implementing)
			implementing=1
			shift
			;;
		-h | --help)
			_isc_cmd_help
			return 0
			;;
		*)
			if [[ -z "$issue" ]]; then
				issue="$arg"
			elif [[ -z "$slug" ]]; then
				slug="$arg"
			else
				_isc_warn "unexpected argument: $arg (ignored)"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$issue" || -z "$slug" ]]; then
		_isc_err "claim: <issue> and <slug> are required"
		_isc_err "usage: interactive-session-helper.sh claim <issue> <slug> [--worktree PATH] [--implementing]"
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

	# Idempotency: if already in-review, refresh stamp and exit. The `if`
	# conditional consumes any non-zero return so set -e doesn't propagate
	# rc=2 (lookup failed) up the call stack — see _isc_has_in_review header
	# for the full set -e foot-gun (GH#18770/GH#18784/GH#18786 sibling class).
	if _isc_has_in_review "$issue" "$slug"; then
		_isc_info "claim: #$issue already has status:in-review — refreshing stamp"
		_isc_write_stamp "$issue" "$slug" "$worktree_path" "$user"
		return 0
	fi

	# Auto-dispatch carve-out (GH#20946): refuse to claim auto-dispatch issues
	# unless --implementing was passed or the issue is also a parent-task.
	# `_isc_carve_out_required` does both label checks in one gh round-trip and
	# fails OPEN on rc=2 (lookup failed) — the `&&` short-circuit only enters
	# the skip branch on rc=0, so rc=1 (no carve-out) and rc=2 (lookup failed)
	# both fall through to the normal claim path. See PR #20977 review thread
	# (augmentcode rc=2 + gemini consolidation findings) for context.
	if [[ $implementing -eq 0 ]] && _isc_carve_out_required "$issue" "$slug"; then
		_isc_warn "claim: #$issue carries 'auto-dispatch' without 'parent-task' — skipping to avoid permanent dispatch block (t2218 invariant; GH#20946)"
		_isc_warn "if you intend to implement #$issue yourself instead of letting a worker pick it up, re-run with: claim $issue $slug --implementing"
		return 0
	fi

	# Transition to in-review with atomic self-assign. Uses set_issue_status
	# from shared-constants.sh which removes all sibling core status labels
	# in the same gh call — preserves the t2033 mutual-exclusivity invariant.
	if set_issue_status "$issue" "$slug" "in-review" --add-assignee "$user" >/dev/null 2>&1; then
		_isc_info "claim: #$issue in $slug → status:in-review + assigned $user"
		_isc_write_stamp "$issue" "$slug" "$worktree_path" "$user"
		# Post a claim comment for audit trail visibility (like worker dispatch
		# comments but for interactive sessions). Best-effort — swallow errors.
		_isc_post_claim_comment "$issue" "$slug" "$user" "$worktree_path"
		return 0
	fi

	# Fallback: gh failed. Warn but don't block the caller.
	_isc_warn "claim: gh failed on #$issue — continuing without lock (collision is harmless)"
	return 0
}

# -----------------------------------------------------------------------------
# Subcommand: lockdown (GH#19861)
# -----------------------------------------------------------------------------
# Stricter protection than `claim`. Applies ALL of:
#   1. `no-auto-dispatch` label — blocks the pulse enrich path from modifying
#      issue state and prevents any auto-dispatch.
#   2. `status:in-review` + self-assignment — blocks pulse dispatch (same as claim).
#   3. GitHub conversation lock — prevents non-collaborator edits.
#   4. Audit-trail comment — visible marker explaining the lockdown.
#   5. Crash-recovery stamp — same as claim.
#
# Use this when investigating a pulse bug or when you need maximum insulation
# from ALL pulse operations, not just dispatch.
#
# Arguments:
#   $1 = issue number
#   $2 = repo slug (owner/repo)
#   [--worktree PATH] = optional worktree path to record in the stamp
#
# Exit: 0 always (warn-and-continue contract).
_isc_cmd_lockdown() {
	local issue="" slug="" worktree_path=""

	# Parse positional + flags
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--worktree)
			worktree_path="${2:-}"
			shift 2
			;;
		--worktree=*)
			worktree_path="${arg#--worktree=}"
			shift
			;;
		-h | --help)
			_isc_cmd_help
			return 0
			;;
		*)
			if [[ -z "$issue" ]]; then
				issue="$arg"
			elif [[ -z "$slug" ]]; then
				slug="$arg"
			else
				_isc_warn "unexpected argument: $arg (ignored)"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$issue" || -z "$slug" ]]; then
		_isc_err "lockdown: <issue> and <slug> are required"
		_isc_err "usage: interactive-session-helper.sh lockdown <issue> <slug> [--worktree PATH]"
		return 2
	fi

	if [[ ! "$issue" =~ ^[0-9]+$ ]]; then
		_isc_err "lockdown: <issue> must be numeric (got: $issue)"
		return 2
	fi

	# Offline gate
	if ! _isc_gh_reachable; then
		_isc_warn "gh offline or not authenticated — skipping lockdown on #$issue ($slug)"
		return 0
	fi

	local user
	user=$(_isc_current_user)
	if [[ -z "$user" ]]; then
		_isc_warn "could not resolve gh user login — skipping lockdown on #$issue"
		return 0
	fi

	# Step 1: Apply status:in-review + self-assign (same as claim)
	if set_issue_status "$issue" "$slug" "in-review" --add-assignee "$user" >/dev/null 2>&1; then
		_isc_info "lockdown: #$issue → status:in-review + assigned $user"
	else
		_isc_warn "lockdown: status transition failed on #$issue — continuing"
	fi

	# Step 2: Apply no-auto-dispatch label (blocks enrich + dispatch paths)
	if gh issue edit "$issue" --repo "$slug" --add-label "no-auto-dispatch" >/dev/null 2>&1; then
		_isc_info "lockdown: #$issue → no-auto-dispatch label applied"
	else
		_isc_warn "lockdown: could not apply no-auto-dispatch label on #$issue"
	fi

	# Step 3: Lock the conversation
	if gh issue lock "$issue" --repo "$slug" --reason "resolved" >/dev/null 2>&1; then
		_isc_info "lockdown: #$issue → conversation locked"
	else
		_isc_warn "lockdown: could not lock conversation on #$issue — continuing"
	fi

	# Step 4: Write crash-recovery stamp
	_isc_write_stamp "$issue" "$slug" "$worktree_path" "$user"

	# Step 5: Post audit-trail comment
	local body
	# shellcheck disable=SC2016 # backticks are intentional markdown formatting
	body="$(printf '<!-- lockdown-marker -->\n**Lockdown applied** by `%s` (interactive session).\n\nThis issue is under active human investigation. All pulse operations (dispatch, enrich, completion-sweep) are blocked via `no-auto-dispatch` + `status:in-review` + conversation lock.\n\nTo release: `interactive-session-helper.sh unlock %s %s`' "$user" "$issue" "$slug")"
	gh_issue_comment "$issue" --repo "$slug" --body "$body" >/dev/null 2>&1 || {
		_isc_warn "lockdown: audit comment failed on #$issue — continuing"
	}

	_isc_info "lockdown: #$issue in $slug fully locked down"
	return 0
}

# -----------------------------------------------------------------------------
# Subcommand: unlock (GH#19861)
# -----------------------------------------------------------------------------
# Reverse a lockdown: remove no-auto-dispatch, transition to available,
# unlock conversation, delete stamp.
#
# Arguments:
#   $1 = issue number
#   $2 = repo slug (owner/repo)
#   [--unassign] = also remove self from assignees
#
# Exit: 0 always.
_isc_cmd_unlock() {
	local issue="" slug="" unassign=0

	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
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
				issue="$arg"
			elif [[ -z "$slug" ]]; then
				slug="$arg"
			else
				_isc_warn "unexpected argument: $arg (ignored)"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$issue" || -z "$slug" ]]; then
		_isc_err "unlock: <issue> and <slug> are required"
		return 2
	fi

	if [[ ! "$issue" =~ ^[0-9]+$ ]]; then
		_isc_err "unlock: <issue> must be numeric (got: $issue)"
		return 2
	fi

	# Delete local stamp regardless of gh state
	_isc_delete_stamp "$issue" "$slug"

	if ! _isc_gh_reachable; then
		_isc_warn "gh offline — stamp deleted locally, lockdown unchanged on #$issue"
		return 0
	fi

	# Step 1: Unlock conversation
	if gh issue unlock "$issue" --repo "$slug" >/dev/null 2>&1; then
		_isc_info "unlock: #$issue → conversation unlocked"
	else
		_isc_warn "unlock: could not unlock conversation on #$issue — continuing"
	fi

	# Step 2: Remove no-auto-dispatch label
	if gh issue edit "$issue" --repo "$slug" --remove-label "no-auto-dispatch" >/dev/null 2>&1; then
		_isc_info "unlock: #$issue → no-auto-dispatch label removed"
	else
		_isc_warn "unlock: could not remove no-auto-dispatch label on #$issue"
	fi

	# Step 3: Transition status:in-review -> status:available
	local -a extra_flags=()
	if [[ $unassign -eq 1 ]]; then
		local user
		user=$(_isc_current_user)
		if [[ -n "$user" ]]; then
			extra_flags+=(--remove-assignee "$user")
		fi
	fi

	if set_issue_status "$issue" "$slug" "available" ${extra_flags[@]+"${extra_flags[@]}"} >/dev/null 2>&1; then
		_isc_info "unlock: #$issue → status:available"
	else
		_isc_warn "unlock: status transition failed on #$issue"
	fi

	# Step 4: Post audit comment
	local user
	user=$(_isc_current_user) || true
	local body
	# shellcheck disable=SC2016 # backticks are intentional markdown formatting
	body="$(printf '<!-- unlock-marker -->\n**Lockdown released** by `%s`. Issue returned to normal pulse operation.' "${user:-unknown}")"
	gh_issue_comment "$issue" --repo "$slug" --body "$body" >/dev/null 2>&1 || {
		_isc_warn "unlock: audit comment failed on #$issue — continuing"
	}

	_isc_info "unlock: #$issue in $slug fully unlocked"
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
		local arg="$1"
		case "$arg" in
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
				issue="$arg"
			elif [[ -z "$slug" ]]; then
				slug="$arg"
			else
				_isc_warn "unexpected argument: $arg (ignored)"
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
# Internal helpers: closed-not-merged PR orphan scanning
# -----------------------------------------------------------------------------

# Compute a 14-day cutoff epoch.
# Supports GNU date (Linux) and BSD date (macOS).
_isc_compute_cutoff_epoch() {
	local epoch
	epoch=$(date -d '14 days ago' +%s 2>/dev/null ||
		date -v-14d +%s 2>/dev/null ||
		echo 0)
	printf '%s' "$epoch"
	return 0
}

# Fetch closed-not-merged PRs for a repo within the cutoff window.
# $1: slug (owner/repo), $2: cutoff_epoch
# Outputs: one line per PR, fields joined by \x01 (number|closedAt|title|branch|body).
_isc_fetch_filtered_prs() {
	local slug="$1"
	local cutoff_epoch="$2"
	local prs_raw
	prs_raw=$(gh pr list --repo "$slug" --state closed --limit 50 \
		--json number,title,headRefName,closedAt,mergedAt,body \
		2>/dev/null || echo "[]")
	[[ "$prs_raw" == "[]" || -z "$prs_raw" ]] && return 0
	# shellcheck disable=SC2016  # $cutoff is a jq argjson var, not a shell expansion
	printf '%s' "$prs_raw" | jq -r \
		--argjson cutoff "$cutoff_epoch" \
		'.[] | select(
			.mergedAt == null and
			.closedAt != null and
			(.closedAt | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) >= $cutoff
		) | [(.number | tostring), .closedAt, .title, (.headRefName // ""), .body] | join("\u0001")' \
		2>/dev/null || true
	return 0
}

# Extract issue numbers referenced by closing keywords in a PR body.
# Reads PR body from stdin. Outputs one issue number per line.
# Keywords matched: Resolves, Closes, Fixes, For (case-insensitive).
_isc_extract_pr_linked_issues() {
	grep -oiE '(resolves|closes|fixes|for) #[0-9]+' |
		grep -oE '[0-9]+' 2>/dev/null || true
	return 0
}

# Determine who closed a PR by checking for the deterministic merge pass marker.
# $1: slug (owner/repo), $2: pr_number
# Outputs: "deterministic merge pass (pulse-merge.sh) — HIGH severity" or "unknown".
_isc_get_pr_closed_by() {
	local slug="$1"
	local pr_number="$2"
	local pulse_match
	pulse_match=$(gh api "repos/${slug}/issues/${pr_number}/comments" \
		--jq '[.[] | select(.body | test("deterministic merge pass|pulse-merge"; "i"))] | length' \
		2>/dev/null || echo "0")
	if [[ "${pulse_match:-0}" -gt 0 ]]; then
		printf 'deterministic merge pass (pulse-merge.sh) — HIGH severity'
	else
		printf 'unknown'
	fi
	return 0
}

# Check whether a PR branch still exists on origin.
# $1: slug (owner/repo), $2: pr_branch (may be empty)
# Outputs: "yes" or "no".
_isc_pr_branch_on_origin() {
	local slug="$1"
	local pr_branch="$2"
	if [[ -z "$pr_branch" ]]; then
		printf 'no'
		return 0
	fi
	if gh api "repos/${slug}/git/refs/heads/${pr_branch}" >/dev/null 2>&1; then
		printf 'yes'
	else
		printf 'no'
	fi
	return 0
}

# Print one orphan PR/issue advisory entry to stdout.
# Args: pr_number issue_num pr_title pr_branch branch_exists closed_by pr_closed_at slug
_isc_print_orphan_pr_entry() {
	local pr_number="$1"
	local issue_num="$2"
	local pr_title="$3"
	local pr_branch="$4"
	local branch_exists="$5"
	local closed_by="$6"
	local pr_closed_at="$7"
	local slug="$8"
	printf '  STALE: PR #%s (closed not merged) → issue #%s still OPEN\n' \
		"$pr_number" "$issue_num"
	printf '    Title:      %s\n' "$pr_title"
	printf '    Branch:     %s (still on origin: %s)\n' \
		"${pr_branch:-unknown}" "$branch_exists"
	printf '    Closed by:  %s\n' "$closed_by"
	printf '    Closed at:  %s\n' "$pr_closed_at"
	printf '    Action:     gh pr reopen %s --repo %s\n' "$pr_number" "$slug"
	printf '\n'
	return 0
}

# -----------------------------------------------------------------------------
# Internal: scan closed-not-merged PRs whose linked issue is still open
# -----------------------------------------------------------------------------
# For each pulse-enabled repo in repos.json:
#   1. List PRs closed (not merged) in the last 14 days via gh pr list.
#   2. Extract linked issue numbers from the PR body keywords:
#      Resolves/Closes/Fixes/For #N.
#   3. For each linked issue that is still OPEN, print an advisory.
#
# Does NOT auto-reopen — surfaces for human triage only.
# Exit: 0 always. Prints orphan count to stdout.
_isc_scan_closed_pr_orphans() {
	local repos_json="${HOME}/.config/aidevops/repos.json"
	if [[ ! -f "$repos_json" ]]; then
		printf '0'
		return 0
	fi

	if ! _isc_gh_reachable; then
		_isc_warn "gh not reachable — skipping closed-PR orphan scan"
		printf '0'
		return 0
	fi

	local orphan_count=0
	local cutoff_epoch
	cutoff_epoch=$(_isc_compute_cutoff_epoch)

	local slug
	while IFS= read -r slug; do
		[[ -z "$slug" ]] && continue

		local pr_entries
		pr_entries=$(_isc_fetch_filtered_prs "$slug" "$cutoff_epoch")
		[[ -z "$pr_entries" ]] && continue

		local pr_entry
		while IFS= read -r pr_entry; do
			[[ -z "$pr_entry" ]] && continue

			local pr_number pr_closed_at pr_title pr_branch pr_body
			IFS=$'\x01' read -r pr_number pr_closed_at pr_title pr_branch pr_body <<<"$pr_entry"
			[[ -z "$pr_number" ]] && continue

			local issue_nums=()
			local raw_num
			while IFS= read -r raw_num; do
				[[ -z "$raw_num" ]] && continue
				issue_nums+=("$raw_num")
			done < <(printf '%s\n' "$pr_body" | _isc_extract_pr_linked_issues)

			local issue_num
			for issue_num in "${issue_nums[@]+"${issue_nums[@]}"}"; do
				[[ -z "$issue_num" ]] && continue

				local issue_state
				issue_state=$(gh issue view "$issue_num" --repo "$slug" \
					--json state --jq '.state' 2>/dev/null || echo "")
				[[ -z "$issue_state" ]] && continue

				if [[ "$issue_state" == "OPEN" ]]; then
					if [[ $orphan_count -eq 0 ]]; then
						printf '\nClosed-not-merged PRs with still-open linked issues:\n\n'
					fi
					local closed_by branch_exists
					closed_by=$(_isc_get_pr_closed_by "$slug" "$pr_number")
					branch_exists=$(_isc_pr_branch_on_origin "$slug" "$pr_branch")
					_isc_print_orphan_pr_entry \
						"$pr_number" "$issue_num" "$pr_title" "$pr_branch" \
						"$branch_exists" "$closed_by" "$pr_closed_at" "$slug"
					orphan_count=$((orphan_count + 1))
				fi
			done

		done <<<"$pr_entries"

	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | .slug' \
		"$repos_json" 2>/dev/null || true)

	printf '%d' "$orphan_count"
	return 0
}

# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
# _isc_release_claim_by_stamp_path (t2414) — release a claim given a stamp path.
# -----------------------------------------------------------------------------
# Extracts issue+slug from the stamp JSON and delegates to `_isc_cmd_release`
# which handles stamp deletion and label transition atomically. Used by the
# Phase 1 auto-release path in `_isc_scan_dead_stamps_phase`.
# Fail-open: missing stamp, unparseable JSON, or missing fields → warn+skip.
#
# Args:
#   $1 stamp_path — absolute path to the .json stamp file
#
# Exit: 0 always.
_isc_release_claim_by_stamp_path() {
	local stamp_path="$1"

	[[ -f "$stamp_path" ]] || return 0

	local r_issue r_slug
	r_issue=$(jq -r '.issue // empty' "$stamp_path" 2>/dev/null || echo "")
	r_slug=$(jq -r '.slug // empty' "$stamp_path" 2>/dev/null || echo "")

	if [[ -z "$r_issue" || -z "$r_slug" ]]; then
		_isc_warn "_isc_release_claim_by_stamp_path: stamp missing issue/slug — deleting: $stamp_path"
		rm -f "$stamp_path" 2>/dev/null || true
		return 0
	fi

	# Delegate to canonical release flow: stamp deletion + label transition.
	# _isc_cmd_release is idempotent and fail-open on offline gh.
	_isc_cmd_release "$r_issue" "$r_slug"
	return 0
}

# scan-stale Phase 1a helper (t2148) — stampless interactive claims.
# -----------------------------------------------------------------------------
# Iterates pulse-enabled repos from repos.json, calls
# _isc_list_stampless_interactive_claims per slug, prints findings to stdout.
# Extracted from _isc_cmd_scan_stale to keep the coordinator under the
# 100-line function cap enforced by the Complexity Analysis CI gate.
#
# Exit: 0 always.
_isc_scan_stampless_phase() {
	printf '\nScanning for stampless interactive claims (origin:interactive + self-assigned + no stamp)...\n'

	local repos_json_1a="${HOME}/.config/aidevops/repos.json"
	local stampless_count=0

	if [[ ! -f "$repos_json_1a" ]] || ! _isc_gh_reachable; then
		printf 'No stampless interactive claims.\n'
		return 0
	fi

	local runner_user_1a
	runner_user_1a=$(_isc_current_user)
	if [[ -z "$runner_user_1a" ]]; then
		printf 'No stampless interactive claims.\n'
		return 0
	fi

	local slug_1a
	while IFS= read -r slug_1a; do
		[[ -z "$slug_1a" ]] && continue

		local row
		while IFS= read -r row; do
			[[ -z "$row" ]] && continue
			local issue_num updated_at
			issue_num=$(printf '%s' "$row" | jq -r '.number' 2>/dev/null)
			updated_at=$(printf '%s' "$row" | jq -r '.updated_at' 2>/dev/null)
			[[ "$issue_num" =~ ^[0-9]+$ ]] || continue

			if [[ $stampless_count -eq 0 ]]; then
				printf '\nStampless interactive claims (origin:interactive + assigned, no stamp):\n\n'
			fi
			printf '  #%s in %s\n' "$issue_num" "$slug_1a"
			printf '    updated:  %s\n' "${updated_at:-unknown}"
			printf '    release:  gh issue edit %s --repo %s --remove-assignee %s\n' \
				"$issue_num" "$slug_1a" "$runner_user_1a"
			printf '\n'
			stampless_count=$((stampless_count + 1))
		done < <(_isc_list_stampless_interactive_claims "$runner_user_1a" "$slug_1a" 2>/dev/null || true)
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | .slug' \
		"$repos_json_1a" 2>/dev/null || true)

	if [[ $stampless_count -eq 0 ]]; then
		printf 'No stampless interactive claims.\n'
	else
		printf 'Total: %d stampless claim(s). Unassign to unblock pulse dispatch, or leave for normalize auto-recovery (>24h).\n' "$stampless_count"
	fi

	return 0
}

# scan-stale Phase 1 helper (t2414) — stamp-based stale claim detection.
# -----------------------------------------------------------------------------
# Iterates $CLAIM_STAMP_DIR. For each local-hostname stamp with dead PID AND
# missing worktree: either auto-releases (when auto_release_flag==1) or prints
# a report advisory. Skips stamps with a live PID or existing worktree.
# Extracted from _isc_cmd_scan_stale to keep the coordinator under the
# 100-line function cap (Complexity Analysis CI gate).
#
# Args:
#   $1 auto_release_flag — "1" to auto-release, "0" for report-only
#
# Exit: 0 always.
_isc_scan_dead_stamps_phase() {
	local auto_release_flag="${1:-0}"
	local stale_count=0
	local auto_released=0
	local local_host
	local_host=$(hostname 2>/dev/null || echo "unknown")

	if [[ -d "$CLAIM_STAMP_DIR" ]]; then
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
			# Only consider current-hostname stamps — cross-machine stamps
			# can't have their PID verified and must not be surfaced as stale.
			[[ "$hostname" == "$local_host" ]] || continue

			local pid_alive=0
			# t2421: command-aware liveness — bare kill -0 lies on macOS PID reuse.
			# Read stored argv hash from stamp for higher precision.
			local stored_hash
			stored_hash=$(jq -r '.owner_argv_hash // empty' "$stamp" 2>/dev/null || echo "")
			if [[ -n "$pid" ]] && _is_process_alive_and_matches "$pid" "${WORKER_PROCESS_PATTERN:-}" "$stored_hash"; then
				pid_alive=1
			fi

			local worktree_exists=0
			[[ -n "$worktree" && -d "$worktree" ]] && worktree_exists=1

			if [[ $pid_alive -eq 0 && $worktree_exists -eq 0 ]]; then
				if [[ "$auto_release_flag" == "1" ]]; then
					_isc_info "[scan-stale] auto-releasing dead stamp: $(basename "$stamp")"
					_isc_release_claim_by_stamp_path "$stamp" >/dev/null 2>&1 || true
					auto_released=$((auto_released + 1))
				else
					[[ $stale_count -eq 0 ]] && printf 'Stale interactive claims (dead PID and missing worktree):\n\n'
					printf '  #%s in %s\n' "$issue" "$slug"
					printf '    worktree: %s (missing)\n' "${worktree:-unknown}"
					printf '    pid:      %s (dead)\n' "${pid:-unknown}"
					printf '    release:  aidevops issue release %s\n' "$issue"
					printf '\n'
					stale_count=$((stale_count + 1))
				fi
			fi
		done
	fi

	if [[ "$auto_release_flag" == "1" ]]; then
		if [[ $auto_released -eq 0 ]]; then
			printf 'No stale interactive claims.\n'
		else
			_isc_info "[scan-stale] Phase 1 auto-released $auto_released stamp(s)."
			printf 'Phase 1: auto-released %d dead stamp(s) (dead PID + missing worktree).\n' "$auto_released"
		fi
	else
		if [[ $stale_count -eq 0 ]]; then
			printf 'No stale interactive claims.\n'
		else
			# shellcheck disable=SC2016  # backticks are literal text, not command substitution
			printf 'Total: %d stale claim(s). Release via `aidevops issue release <N>` or reclaim by `cd`-ing into the worktree.\n' "$stale_count"
		fi
	fi
	return 0
}

# -----------------------------------------------------------------------------
# Subcommand: scan-stale
# -----------------------------------------------------------------------------
# Three-phase stale detection coordinator. Phase 1 (t2414): auto-releases dead
# stamps (dead PID + missing worktree) when running in an interactive TTY.
# Phase 1a: report-only (stampless origin:interactive claims).
# Phase 2: report-only (closed-not-merged PR orphans).
#
# Arguments:
#   [--auto-release]    — force Phase 1 auto-release on (overrides env/TTY)
#   [--no-auto-release] — force Phase 1 auto-release off (overrides env/TTY)
#
# Env: AIDEVOPS_SCAN_STALE_AUTO_RELEASE=0|1 — overrides TTY detection.
#
# Exit: 0 always.
_isc_cmd_scan_stale() {
	# --- auto-release flag resolution (t2414) ---
	# Priority: explicit flag > env var > TTY detection > default OFF.
	local auto_release_flag=""
	while [[ $# -gt 0 ]]; do
		local _arg="$1"
		case "$_arg" in
		--auto-release) auto_release_flag=1 ; shift ;;
		--no-auto-release) auto_release_flag=0 ; shift ;;
		*) shift ;;
		esac
	done
	if [[ -z "$auto_release_flag" && -n "${AIDEVOPS_SCAN_STALE_AUTO_RELEASE:-}" ]]; then
		auto_release_flag="${AIDEVOPS_SCAN_STALE_AUTO_RELEASE}"
	fi
	if [[ -z "$auto_release_flag" ]]; then
		[[ -t 0 && -t 1 ]] && auto_release_flag=1 || auto_release_flag=0
	fi

	# --- Phase 1: stamp-based stale claim detection (extracted for line-cap) ---
	_isc_scan_dead_stamps_phase "$auto_release_flag"

	# --- Phase 1a: stampless origin:interactive claims (t2148) ---
	_isc_scan_stampless_phase

	# --- Phase 2: closed-not-merged PR orphan detection (cross-repo) ---
	printf '\nScanning for closed-not-merged PRs with still-open linked issues...\n'
	local orphan_count
	orphan_count=$(_isc_scan_closed_pr_orphans 2>/dev/null || echo "0")
	if [[ "$orphan_count" -eq 0 ]]; then
		printf 'No closed-not-merged PR orphans found.\n'
	else
		printf 'Total: %d closed-not-merged PR orphan(s). Review the above — do NOT auto-reopen without verifying the close was unintentional.\n' "$orphan_count"
	fi
	return 0
}

# -----------------------------------------------------------------------------
# Subcommand: post-merge (t2225)
# -----------------------------------------------------------------------------
# Auto-heal two known drift patterns after a planning PR merges.
# Called after `gh pr merge` succeeds, alongside `release <N>`.
#
# Heal pass 1 — t2219 workaround: removes false `status:done` on OPEN issues
#   referenced by `For #N` / `Ref #N` keywords (planning-convention refs that
#   issue-sync.yml title-fallback falsely closes).
#
# Heal pass 2 — t2218 workaround: unassigns the PR author from OPEN issues
#   with `origin:interactive` + `auto-dispatch` + no active status label (these
#   should be pulse-dispatched, not held by the interactive session that just
#   finished planning).
#
# Both passes are idempotent, fail-open, and post short audit-trail comments
# citing the relevant bug ID so history is traceable.
#
# Arguments:
#   $1 = PR number
#   $2 = repo slug (owner/repo) — defaults to current repo if omitted
#
# Exit: 0 always (fail-open contract).

# _isc_post_merge_heal_status_done — t2219 workaround
# Removes false status:done from OPEN For/Ref-referenced issues.
# Args: $1=pr_number $2=slug $3=pr_body
_isc_post_merge_heal_status_done() {
	local pr_number="$1"
	local slug="$2"
	local body="$3"

	# Extract For/Ref issue numbers (case-insensitive)
	local for_refs
	for_refs=$(printf '%s' "$body" \
		| grep -oiE '(for|ref)[[:space:]]+#[0-9]+' \
		| grep -oE '[0-9]+' | sort -u 2>/dev/null || true)

	[[ -n "$for_refs" ]] || return 0

	local healed=0
	local issue_num
	while IFS= read -r issue_num; do
		[[ -n "$issue_num" ]] || continue
		[[ "$issue_num" =~ ^[0-9]+$ ]] || continue

		local issue_json issue_state has_done
		issue_json=$(gh issue view "$issue_num" --repo "$slug" --json state,labels 2>/dev/null) || continue
		issue_state=$(printf '%s' "$issue_json" | jq -r '.state // ""' 2>/dev/null) || continue
		[[ "$issue_state" == "OPEN" ]] || continue

		has_done=$(printf '%s' "$issue_json" | jq -r '[.labels[].name] | map(select(. == "status:done")) | length' 2>/dev/null) || continue
		[[ "${has_done:-0}" -gt 0 ]] || continue

		_isc_info "post-merge: healing false status:done on #$issue_num (t2219, For/Ref in PR #$pr_number)"
		gh issue edit "$issue_num" --repo "$slug" \
			--remove-label "status:done" \
			--add-label "status:available" >/dev/null 2>&1 || continue

		gh_issue_comment "$issue_num" --repo "$slug" --body \
			"Reset \`status:done\` → \`status:available\` — PR #${pr_number} referenced this via \`For\`/\`Ref\` (planning convention), not \`Closes\`/\`Resolves\`. Workaround for [t2219](../issues/19719) (\`issue-sync.yml\` title-fallback false-positive)." \
			>/dev/null 2>&1 || true

		healed=$((healed + 1))
	done <<<"$for_refs"

	[[ $healed -gt 0 ]] && _isc_info "post-merge: healed status:done on $healed issue(s) (t2219)"
	return 0
}

# _isc_post_merge_heal_stale_self_assign — t2218 workaround
# Unassigns PR author from auto-dispatch issues with no active status.
# Args: $1=pr_number $2=slug $3=pr_body $4=pr_author
_isc_post_merge_heal_stale_self_assign() {
	local pr_number="$1"
	local slug="$2"
	local body="$3"
	local pr_author="$4"

	[[ -n "$pr_author" ]] || return 0

	# Extract ALL issue refs (closing keywords + For/Ref)
	local all_refs
	all_refs=$(printf '%s' "$body" \
		| grep -oiE '(closes?|fixes?|resolves?|for|ref)[[:space:]]+#[0-9]+' \
		| grep -oE '[0-9]+' | sort -u 2>/dev/null || true)

	[[ -n "$all_refs" ]] || return 0

	local healed=0
	local issue_num
	while IFS= read -r issue_num; do
		[[ -n "$issue_num" ]] || continue
		[[ "$issue_num" =~ ^[0-9]+$ ]] || continue

		local issue_json issue_state labels_str has_author
		issue_json=$(gh issue view "$issue_num" --repo "$slug" --json state,labels,assignees 2>/dev/null) || continue
		issue_state=$(printf '%s' "$issue_json" | jq -r '.state // ""' 2>/dev/null) || continue
		[[ "$issue_state" == "OPEN" ]] || continue

		labels_str=$(printf '%s' "$issue_json" | jq -r '[.labels[].name] | join(",")' 2>/dev/null) || continue

		# Require origin:interactive + auto-dispatch
		[[ ",$labels_str," == *",origin:interactive,"* ]] || continue
		[[ ",$labels_str," == *",auto-dispatch,"* ]] || continue
		# Skip if actively worked
		[[ ",$labels_str," != *",status:in-review,"* ]] || continue
		[[ ",$labels_str," != *",status:in-progress,"* ]] || continue

		has_author=$(printf '%s' "$issue_json" | jq -r --arg u "$pr_author" \
			'[.assignees[].login] | map(select(. == $u)) | length' 2>/dev/null) || continue
		[[ "${has_author:-0}" -gt 0 ]] || continue

		_isc_info "post-merge: healing stale self-assignment on #$issue_num (t2218, author=$pr_author)"
		gh issue edit "$issue_num" --repo "$slug" --remove-assignee "$pr_author" >/dev/null 2>&1 || continue

		gh_issue_comment "$issue_num" --repo "$slug" --body \
			"Unassigned @${pr_author} — this issue has \`auto-dispatch\` and should be pulse-dispatched to a worker. Workaround for [t2218](../issues/19718) (\`claim-task-id.sh\` missing t2157 carve-out in \`_auto_assign_issue\`)." \
			>/dev/null 2>&1 || true

		healed=$((healed + 1))
	done <<<"$all_refs"

	[[ $healed -gt 0 ]] && _isc_info "post-merge: healed stale self-assignment on $healed issue(s) (t2218)"
	return 0
}

# _isc_cmd_post_merge — entry point for the post-merge subcommand
_isc_cmd_post_merge() {
	local pr_number="" slug=""

	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		-h | --help)
			_isc_cmd_help
			return 0
			;;
		*)
			if [[ -z "$pr_number" ]]; then
				pr_number="$arg"
			elif [[ -z "$slug" ]]; then
				slug="$arg"
			else
				_isc_warn "post-merge: unexpected argument: $arg (ignored)"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$pr_number" ]]; then
		_isc_err "post-merge: <pr_number> is required"
		_isc_err "usage: interactive-session-helper.sh post-merge <pr_number> [<slug>]"
		return 2
	fi

	if [[ ! "$pr_number" =~ ^[0-9]+$ ]]; then
		_isc_err "post-merge: <pr_number> must be numeric (got: $pr_number)"
		return 2
	fi

	# Resolve slug from repos.json if not provided
	if [[ -z "$slug" ]]; then
		local repos_json="${HOME}/.config/aidevops/repos.json"
		if [[ -f "$repos_json" ]]; then
			local repo_dir
			repo_dir=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
			if [[ -n "$repo_dir" ]]; then
				slug=$(jq -r --arg p "$repo_dir" \
					'.initialized_repos[] | select(.path == $p) | .slug // empty' \
					"$repos_json" 2>/dev/null | head -1 || true)
			fi
		fi
	fi

	if [[ -z "$slug" ]]; then
		# Last-resort: derive from git remote
		local remote_url
		remote_url=$(git remote get-url origin 2>/dev/null || echo "")
		if [[ "$remote_url" =~ github\.com[:/]([^/]+/[^/]+?)(\.git)?$ ]]; then
			slug="${BASH_REMATCH[1]}"
		fi
	fi

	if [[ -z "$slug" ]]; then
		_isc_err "post-merge: could not determine repo slug; pass it explicitly"
		return 2
	fi

	if ! _isc_gh_reachable; then
		_isc_warn "post-merge: gh offline — skipping post-merge heal for PR #$pr_number"
		return 0
	fi

	# Fetch PR metadata
	local pr_json merged_at state body author
	pr_json=$(gh pr view "$pr_number" --repo "$slug" --json body,author,mergedAt,state 2>/dev/null) || {
		_isc_warn "post-merge: gh unavailable or PR #$pr_number not accessible; skipping"
		return 0
	}

	merged_at=$(printf '%s' "$pr_json" | jq -r '.mergedAt // ""' 2>/dev/null || echo "")
	state=$(printf '%s' "$pr_json" | jq -r '.state // ""' 2>/dev/null || echo "")
	body=$(printf '%s' "$pr_json" | jq -r '.body // ""' 2>/dev/null || echo "")
	author=$(printf '%s' "$pr_json" | jq -r '.author.login // ""' 2>/dev/null || echo "")

	if [[ -z "$merged_at" || "$state" != "MERGED" ]]; then
		_isc_info "post-merge: PR #$pr_number not merged (state=$state); skipping"
		return 0
	fi

	_isc_info "post-merge: auditing PR #$pr_number ($slug) for drift patterns"
	_isc_post_merge_heal_status_done "$pr_number" "$slug" "$body"
	_isc_post_merge_heal_stale_self_assign "$pr_number" "$slug" "$body" "$author"
	_isc_info "post-merge: done"
	return 0
}

# -----------------------------------------------------------------------------
# Subcommand: help
# -----------------------------------------------------------------------------
_isc_cmd_help() {
	cat <<'EOF'
interactive-session-helper.sh - Interactive issue-ownership primitive (t2056)

USAGE:
  interactive-session-helper.sh claim <issue> <slug> [--worktree PATH] [--implementing]
      Apply status:in-review + self-assign + write crash-recovery stamp.
      Idempotent. Offline gh → warn-and-continue (exit 0).
      Auto-dispatch carve-out (GH#20946): refuses to claim issues tagged
      'auto-dispatch' unless --implementing is passed or the issue is also
      tagged 'parent-task'. Without the carve-out, claim creates a
      permanent dispatch block (t1996/GH#18352). Use --implementing when
      you intend to implement the issue yourself instead of letting a
      worker pick it up.

  interactive-session-helper.sh release <issue> <slug> [--unassign]
      Transition status:in-review → status:available, delete stamp.
      Idempotent. --unassign also removes self from assignees.

  interactive-session-helper.sh lockdown <issue> <slug> [--worktree PATH]
      Stricter than claim: blocks ALL pulse paths, not just dispatch.
      Applies: no-auto-dispatch + status:in-review + self-assign +
      conversation lock + audit comment + crash-recovery stamp.
      Use when investigating pulse bugs or need maximum insulation.
      Reverse with: unlock <issue> <slug>

  interactive-session-helper.sh unlock <issue> <slug> [--unassign]
      Reverse a lockdown: remove no-auto-dispatch, transition to
      status:available, unlock conversation, delete stamp, post audit.
      --unassign also removes self from assignees.

  interactive-session-helper.sh status [<issue>]
      List active claims from the stamp directory, or check one issue.

  interactive-session-helper.sh scan-stale [--auto-release | --no-auto-release]
      Three-phase stale detection:
      Phase 1  — Identify stamps with dead PID AND missing worktree path.
                 Auto-releases when BOTH conditions hold (t2414). Default: ON
                 when stdin+stdout are TTYs (interactive session), OFF otherwise.
                 Override: --auto-release / --no-auto-release flags, or
                 AIDEVOPS_SCAN_STALE_AUTO_RELEASE=0|1 env var.
                 Live PID or existing worktree: stamp is NEVER touched.
      Phase 1a — Identify stampless origin:interactive + self-assigned
                 issues (t2148). These block pulse dispatch forever
                 because _has_active_claim treats the label as a claim
                 regardless of stamp state. Does NOT auto-release —
                 `normalize_active_issue_assignments` auto-recovers after
                 24h; the agent can unassign immediately at session start.
      Phase 2  — Scan all pulse-enabled repos for closed-not-merged PRs
                 (last 14 days) whose linked issue is still OPEN. Surfaces
                 these as recovery candidates. Does NOT auto-reopen.

  interactive-session-helper.sh post-merge <pr_number> [<slug>]
      Auto-heal two known drift patterns after a planning PR merges (t2225).
      Call after `gh pr merge` succeeds, alongside `release <N>`.
      Heal 1 (t2219): removes false status:done on OPEN For/Ref-referenced
        issues — planning-convention refs that issue-sync.yml falsely closes.
      Heal 2 (t2218): unassigns PR author from OPEN auto-dispatch issues with
        origin:interactive + no active status label (should be pulse-dispatched).
      Both passes are idempotent, fail-open, and post audit-trail comments.
      Slug defaults to the current repo if not provided.

  interactive-session-helper.sh help
      Print this message.

CONTRACT:
  This helper is intended to be called from interactive AI sessions, driven
  by conversation intent (see `prompts/build.txt` → "Interactive issue
  ownership"). Users should never need to invoke it directly — the agent
  claims on engage and releases on signal.

  SCOPE: `claim` blocks pulse DISPATCH only (GH#19861). It does NOT block
  enrich, completion-sweep, or other non-dispatch pulse operations. For full
  insulation from all pulse paths, use `lockdown` instead.

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
	lockdown)
		_isc_cmd_lockdown "$@" || rc=$?
		;;
	unlock)
		_isc_cmd_unlock "$@" || rc=$?
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
	post-merge)
		_isc_cmd_post_merge "$@" || rc=$?
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
