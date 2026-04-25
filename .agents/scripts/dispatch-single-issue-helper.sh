#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Manual single-issue dispatch CLI (t2835, GH#20882)
# =============================================================================
# Dispatches a single GitHub issue as a headless worker without going through
# the full pulse cycle. Useful for:
#   - Smoke-testing newly-filed issues
#   - Debugging dispatch failures (model selection, dedup, prompt shape)
#   - Validating brief worker-readiness before committing pulse capacity
#
# Subcommands:
#   dispatch <issue_number> <owner/repo> [--model <id>] [--dry-run]
#   status <issue_number> <owner/repo>
#   help
#
# Design choice: this helper does NOT call dispatch_with_dedup directly.
# Instead, it duplicates the launch logic with a subset of the safety gates
# (is-assigned + parent-task + state checks). Rationale:
#   1. dispatch_with_dedup runs 9+ gates including post-claim infrastructure
#      (claim comments, large-file gate, predispatch validators). For a
#      smoke-test those gates are over-the-top and harder to debug.
#   2. Sourcing pulse-dispatch-core.sh pulls in 20+ transitive dependencies.
#      A self-contained CLI is faster to invoke and easier to reason about.
#   3. Acceptable duplication: the worker prompt is intentionally minimal
#      (`/full-loop Implement issue #N (<url>)`) — the headless-runtime-lib
#      automatically appends HEADLESS_CONTINUATION_CONTRACT_V6 when it sees
#      `/full-loop` in the prompt, so the contract stays in sync without
#      duplicating the template here.
#
# Exit codes:
#   0  Worker dispatched (or skipped: already claimed / dry-run)
#   1  Validation failure (issue not found, parent-task, etc.)
#   2  Invalid subcommand or missing required arg
#
# Part of aidevops framework: https://aidevops.sh

set -euo pipefail

# Resolve script dir (canonicalise symlinks) — same pattern as pulse-wrapper.sh
_DSI_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source dependencies (order matters: shared-constants first, then GH wrappers).
# NOTE: dispatch-dedup-helper.sh is NOT sourced — it has no source guard and
# would execute its main() with our $@. We invoke it as an external command
# instead via _DSI_DEDUP_HELPER below.
# shellcheck source=./shared-constants.sh
# shellcheck disable=SC1091
source "${_DSI_SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=./shared-gh-wrappers.sh
# shellcheck disable=SC1091
source "${_DSI_SCRIPT_DIR}/shared-gh-wrappers.sh"

# Paths
_DSI_LOG_DIR="${HOME}/.aidevops/logs"
_DSI_HEADLESS="${_DSI_SCRIPT_DIR}/headless-runtime-helper.sh"
_DSI_LEDGER_HELPER="${_DSI_SCRIPT_DIR}/dispatch-ledger-helper.sh"
_DSI_WORKTREE_HELPER="${_DSI_SCRIPT_DIR}/worktree-helper.sh"
_DSI_DEDUP_HELPER="${_DSI_SCRIPT_DIR}/dispatch-dedup-helper.sh"

# Colors (guarded — don't collide with shared-constants)
[[ -z "${_DSI_GREEN+x}" ]] && _DSI_GREEN='\033[0;32m'
[[ -z "${_DSI_BLUE+x}" ]] && _DSI_BLUE='\033[0;34m'
[[ -z "${_DSI_YELLOW+x}" ]] && _DSI_YELLOW='\033[1;33m'
[[ -z "${_DSI_RED+x}" ]] && _DSI_RED='\033[0;31m'
[[ -z "${_DSI_NC+x}" ]] && _DSI_NC='\033[0m'

_dsi_info() {
	local _msg="$1"
	printf '%b[INFO]%b %s\n' "$_DSI_BLUE" "$_DSI_NC" "$_msg"
	return 0
}

_dsi_ok() {
	local _msg="$1"
	printf '%b[OK]%b %s\n' "$_DSI_GREEN" "$_DSI_NC" "$_msg"
	return 0
}

_dsi_warn() {
	local _msg="$1"
	printf '%b[WARN]%b %s\n' "$_DSI_YELLOW" "$_DSI_NC" "$_msg" >&2
	return 0
}

_dsi_err() {
	local _msg="$1"
	printf '%b[ERROR]%b %s\n' "$_DSI_RED" "$_DSI_NC" "$_msg" >&2
	return 0
}

#######################################
# Validate issue exists, is OPEN, and emit metadata via stdout (single jq call).
# Sets _DSI_ISSUE_TITLE, _DSI_ISSUE_LABELS, _DSI_ISSUE_URL, _DSI_ISSUE_ASSIGNEES.
# Args:
#   $1 - issue number
#   $2 - owner/repo slug
# Returns: 0 ok, 1 not found / closed / API error
#######################################
_dsi_load_issue_meta() {
	local issue_number="$1"
	local repo_slug="$2"
	local meta_json

	meta_json=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json number,title,state,labels,assignees,url 2>/dev/null) || meta_json=""

	if [[ -z "$meta_json" ]]; then
		_dsi_err "Cannot fetch issue #${issue_number} from ${repo_slug} (not found, no permission, or network error)"
		return 1
	fi

	local state
	state=$(printf '%s' "$meta_json" | jq -r '.state // "UNKNOWN"')
	if [[ "$state" != "OPEN" ]]; then
		_dsi_err "Issue #${issue_number} is ${state} (must be OPEN for dispatch)"
		return 1
	fi

	_DSI_ISSUE_META_JSON="$meta_json"
	_DSI_ISSUE_TITLE=$(printf '%s' "$meta_json" | jq -r '.title // ""')
	_DSI_ISSUE_URL=$(printf '%s' "$meta_json" | jq -r '.url // ""')
	_DSI_ISSUE_LABELS=$(printf '%s' "$meta_json" | jq -r '[.labels[].name] | join(",")')
	_DSI_ISSUE_ASSIGNEES=$(printf '%s' "$meta_json" | jq -r '[.assignees[].login] | join(",")')
	return 0
}

#######################################
# Check parent-task gate. parent-task is always a hard block (never single-dispatch).
# Args: $1 - labels CSV (from _dsi_load_issue_meta)
# Returns: 0 not parent-task, 1 IS parent-task (block)
#######################################
_dsi_check_parent_task() {
	local labels_csv="$1"
	local needle=",${labels_csv},"
	if [[ "$needle" == *",parent-task,"* ]]; then
		_dsi_err "Issue is labeled parent-task — these are decomposition trackers and cannot be single-dispatched"
		return 1
	fi
	return 0
}

#######################################
# Resolve model + tier for dispatch.
# Args:
#   $1 - labels CSV
#   $2 - --model override (may be empty)
# Sets: _DSI_TIER (haiku|sonnet|opus), _DSI_SELECTED_MODEL (may be empty)
#######################################
_dsi_resolve_model() {
	local labels_csv="$1"
	local model_override="$2"

	# Default tier
	_DSI_TIER="sonnet"

	# Tier label takes precedence
	local needle=",${labels_csv},"
	if [[ "$needle" == *",tier:simple,"* ]]; then
		_DSI_TIER="haiku"
	elif [[ "$needle" == *",tier:standard,"* ]]; then
		_DSI_TIER="sonnet"
	elif [[ "$needle" == *",tier:thinking,"* ]]; then
		_DSI_TIER="opus"
	fi

	# Explicit --model wins
	if [[ -n "$model_override" ]]; then
		_DSI_SELECTED_MODEL="$model_override"
		return 0
	fi

	# Otherwise inspect model:* label (e.g., model:opus-4-7)
	local m
	m=$(printf '%s\n' "${labels_csv//,/$'\n'}" | grep -oE '^model:[a-z0-9.-]+' | head -1 || true)
	if [[ -n "$m" ]]; then
		# Map model:opus-4-7 → anthropic/claude-opus-4-7 (canonical form)
		local short="${m#model:}"
		_DSI_SELECTED_MODEL="anthropic/claude-${short}"
	else
		_DSI_SELECTED_MODEL=""
	fi
	return 0
}

#######################################
# Pre-create the worker worktree. Sets _DSI_WORKTREE_PATH and _DSI_WORKTREE_BRANCH.
# Args:
#   $1 - issue number
# Returns: 0 success, 1 failure (worktree creation failed)
#######################################
_dsi_create_worktree() {
	local issue_number="$1"
	local ts
	ts=$(date -u +%Y%m%d-%H%M%S)
	local branch="auto-${ts}-gh${issue_number}"

	# worktree-helper.sh add: outputs creation messages to stderr; the
	# branch name is what we passed in.
	if ! AIDEVOPS_SKIP_AUTO_CLAIM=1 "$_DSI_WORKTREE_HELPER" add "$branch" \
		--base "origin/$(_dsi_default_branch)" --issue "$issue_number" >&2; then
		_dsi_err "Failed to create worktree for branch ${branch}"
		return 1
	fi

	# Query git for the actual worktree path. worktree-helper.sh uses its
	# own slug logic (lowercases, parent dir from get_repo_root) — recomputing
	# that here is fragile. Read it back from `git worktree list` instead.
	# Awk inlined to one line to avoid tripping the positional-ratchet (its
	# single-quote-strip is line-local; multi-line awk scripts get false-positives).
	_DSI_WORKTREE_PATH=$(git worktree list --porcelain | awk -v b="$branch" '/^worktree / {p=$0;sub(/^worktree /,"",p)} $0 == "branch refs/heads/" b {print p; exit}')
	_DSI_WORKTREE_BRANCH="$branch"

	if [[ -z "$_DSI_WORKTREE_PATH" || ! -d "$_DSI_WORKTREE_PATH" ]]; then
		_dsi_err "Worktree created but path could not be resolved (branch=${branch})"
		_dsi_info "  Inspect: git worktree list --porcelain | grep -A1 ${branch}"
		return 1
	fi
	return 0
}

#######################################
# Resolve repo's default branch (cached per call). Falls back to "main".
#######################################
_dsi_default_branch() {
	local b
	b=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || true)
	echo "${b:-main}"
	return 0
}

#######################################
# Register the dispatch in the ledger with the real worker PID.
# Best-effort — non-fatal if it fails. Note: dispatch-ledger-helper.sh
# register accepts --session-key, --issue, --repo, --pid only — there is
# no --launched-by flag (the field is informational, not part of the
# helper's interface).
# Args:
#   $1 - issue_number, $2 - repo_slug, $3 - session_key, $4 - worker_pid
#######################################
_dsi_register_ledger() {
	local issue_number="$1"
	local repo_slug="$2"
	local session_key="$3"
	local worker_pid="$4"

	"$_DSI_LEDGER_HELPER" register \
		--session-key "$session_key" \
		--issue "$issue_number" \
		--repo "$repo_slug" \
		--pid "$worker_pid" \
		>/dev/null 2>&1 || _dsi_warn "Dispatch ledger registration failed (non-fatal)"
	return 0
}

#######################################
# Resolve the real worker PID from the worker_log file.
# headless-runtime-helper.sh _detach_worker prints "Dispatched PID: <pid>"
# right before forking the actual worker subshell (see headless-runtime-helper.sh:1483).
# We poll the log briefly waiting for that line; if it never appears,
# fall back to the launch wrapper PID (degraded — ledger may show dead PID).
# Args: $1 - worker_log path, $2 - launch_pid (fallback)
# Stdout: PID (single integer)
#######################################
_dsi_resolve_worker_pid() {
	local worker_log="$1"
	local launch_pid="$2"
	local attempts=0
	while [[ $attempts -lt 30 ]]; do
		if [[ -s "$worker_log" ]]; then
			local pid
			pid=$(grep -oE 'Dispatched PID: [0-9]+' "$worker_log" 2>/dev/null | awk '{print $3}' | head -1)
			if [[ -n "$pid" ]]; then
				echo "$pid"
				return 0
			fi
		fi
		sleep 0.1
		attempts=$((attempts + 1))
	done
	# Fallback: caller can decide what to do with degraded state
	_dsi_warn "Could not extract worker PID from log within 3s — using launch wrapper PID (ledger may go stale)"
	echo "$launch_pid"
	return 0
}

#######################################
# Build the worker prompt.  Headless-runtime-lib auto-appends
# HEADLESS_CONTINUATION_CONTRACT_V6 when it sees "/full-loop" — see
# headless-runtime-lib.sh:437-509.
# Args: $1 - issue_number, $2 - issue_url
# Stdout: prompt text
#######################################
_dsi_build_prompt() {
	local issue_number="$1"
	local issue_url="$2"
	local prompt="/full-loop Implement issue #${issue_number}"
	if [[ -n "$issue_url" ]]; then
		prompt="${prompt} (${issue_url})"
	fi
	printf '%s' "$prompt"
	return 0
}

#######################################
# Launch the worker via headless-runtime-helper.sh in detached mode.
# Args:
#   $1 - session_key
#   $2 - worktree_path
#   $3 - title
#   $4 - prompt
#   $5 - tier
#   $6 - selected_model (may be empty for auto-select)
#   $7 - worker_log path
#   $8 - issue_number
# Stdout (on success): worker PID (single line)
# Returns: 0 launched, 1 failed
#######################################
_dsi_launch_worker() {
	local session_key="$1"
	local worktree_path="$2"
	local title="$3"
	local prompt="$4"
	local tier="$5"
	local selected_model="$6"
	local worker_log="$7"
	local issue_number="$8"

	local -a cmd=(
		env
		HEADLESS=1
		FULL_LOOP_HEADLESS=true
		WORKER_ISSUE_NUMBER="$issue_number"
		WORKER_WORKTREE_PATH="$worktree_path"
		"$_DSI_HEADLESS" run
		--role worker
		--session-key "$session_key"
		--dir "$worktree_path"
		--tier "$tier"
		--title "$title"
		--prompt "$prompt"
		--detach
	)
	if [[ -n "$selected_model" ]]; then
		cmd+=(--model "$selected_model")
	fi

	# Run in background, redirect stdout/stderr to worker_log so caller
	# doesn't block. Capture launch PID (the env wrapper, which then
	# exec's the helper).
	mkdir -p "$_DSI_LOG_DIR"
	nohup "${cmd[@]}" >>"$worker_log" 2>&1 &
	local pid=$!
	disown "$pid" 2>/dev/null || true

	if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
		_dsi_err "Worker launch failed — process did not start"
		return 1
	fi

	echo "$pid"
	return 0
}

#######################################
# Parse + validate dispatch args. Sets globals:
#   _DSI_ARG_ISSUE, _DSI_ARG_REPO, _DSI_ARG_MODEL, _DSI_ARG_DRYRUN
# Returns: 0 ok, 2 invalid usage (caller should propagate)
#######################################
_dsi_parse_dispatch_args() {
	_DSI_ARG_ISSUE=""
	_DSI_ARG_REPO=""
	_DSI_ARG_MODEL=""
	_DSI_ARG_DRYRUN=0
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--model)
			# Guard: --model requires a value, and that value must not look
			# like another flag (covers `--model --dry-run` typo). The
			# ${...} braced form keeps the positional-parameter ratchet
			# (which matches bare \$[1-9]) happy.
			if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == --* ]]; then
				_dsi_err "--model requires a model id (e.g. anthropic/claude-opus-4-7)"
				return 2
			fi
			_DSI_ARG_MODEL="${2}"
			shift 2
			;;
		--dry-run)
			_DSI_ARG_DRYRUN=1
			shift
			;;
		-h | --help)
			_dispatch_usage
			return 100 # special: caller exits 0
			;;
		--*)
			_dsi_err "Unknown flag for dispatch: $arg"
			return 2
			;;
		*)
			if [[ -z "$_DSI_ARG_ISSUE" ]]; then
				_DSI_ARG_ISSUE="$arg"
			elif [[ -z "$_DSI_ARG_REPO" ]]; then
				_DSI_ARG_REPO="$arg"
			else
				_dsi_err "Unexpected positional arg: $arg"
				return 2
			fi
			shift
			;;
		esac
	done
	if [[ -z "$_DSI_ARG_ISSUE" || -z "$_DSI_ARG_REPO" ]]; then
		_dsi_err "dispatch requires <issue_number> and <owner/repo>"
		_dispatch_usage
		return 2
	fi
	if [[ ! "$_DSI_ARG_ISSUE" =~ ^[0-9]+$ ]]; then
		_dsi_err "Issue number must be numeric: ${_DSI_ARG_ISSUE}"
		return 2
	fi
	if [[ ! "$_DSI_ARG_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
		_dsi_err "Repo slug must be owner/repo format: ${_DSI_ARG_REPO}"
		return 2
	fi
	return 0
}

#######################################
# Print dry-run plan. Caller has already loaded metadata + resolved model.
# Args:
#   $1 issue_number, $2 repo_slug, $3 session_key
#   $4 dedup_state (blocked|clear|error), $5 dedup_rc, $6 dedup_result
#######################################
_dsi_print_dryrun() {
	local issue_number="$1"
	local repo_slug="$2"
	local session_key="$3"
	local dedup_state="$4"
	local dedup_rc="$5"
	local dedup_result="$6"
	_dsi_info "DRY RUN — would dispatch:"
	_dsi_info "  Issue:        #${issue_number} (${repo_slug})"
	_dsi_info "  Title:        ${_DSI_ISSUE_TITLE}"
	_dsi_info "  Labels:       ${_DSI_ISSUE_LABELS}"
	_dsi_info "  Tier:         ${_DSI_TIER}"
	_dsi_info "  Model:        ${_DSI_SELECTED_MODEL:-<auto>}"
	_dsi_info "  Session key:  ${session_key}"
	_dsi_info "  Prompt:       $(_dsi_build_prompt "$issue_number" "$_DSI_ISSUE_URL")"
	_dsi_info "  Worktree:     would create auto-<ts>-gh${issue_number}"
	case "$dedup_state" in
	blocked) _dsi_warn "  Dedup:        WOULD BLOCK — ${dedup_result}" ;;
	clear) _dsi_info "  Dedup:        clear (no active claim)" ;;
	error) _dsi_err "  Dedup:        ERROR (exit ${dedup_rc}) — would refuse to dispatch: ${dedup_result}" ;;
	esac
	_dsi_ok "Dry-run complete (no worker launched)"
	return 0
}

#######################################
# Subcommand: dispatch <issue> <slug> [--model M] [--dry-run]
#######################################
cmd_dispatch() {
	local rc=0
	_dsi_parse_dispatch_args "$@" || rc=$?
	case "$rc" in
	0) ;;
	100) return 0 ;;
	*) return "$rc" ;;
	esac
	local issue_number="$_DSI_ARG_ISSUE"
	local repo_slug="$_DSI_ARG_REPO"

	# Step 1-2: validate + load + parent-task gate
	_dsi_load_issue_meta "$issue_number" "$repo_slug" || return 1
	_dsi_check_parent_task "$_DSI_ISSUE_LABELS" || return 1

	# Step 3: dedup check (informational under --dry-run, blocking otherwise).
	# Helper exit codes (per dispatch-dedup-helper.sh::is-assigned):
	#   0 = blocked (active claim exists)
	#   1 = free to dispatch (no claim)
	#   * = error (helper missing, network failure, malformed response, etc.)
	# Treat anything other than 0 or 1 as "fail closed" — refuse to dispatch
	# when we can't be sure of the state. The pulse has its own retry layers.
	local self_login
	self_login=$(gh api user --jq .login 2>/dev/null || echo "")
	local dedup_result dedup_rc=0
	ISSUE_META_JSON="$_DSI_ISSUE_META_JSON" \
		dedup_result=$("$_DSI_DEDUP_HELPER" is-assigned "$issue_number" "$repo_slug" "$self_login" 2>&1) || dedup_rc=$?
	local dedup_state
	case "$dedup_rc" in
	0) dedup_state="blocked" ;;
	1) dedup_state="clear" ;;
	*) dedup_state="error" ;;
	esac

	# Step 4: resolve model
	_dsi_resolve_model "$_DSI_ISSUE_LABELS" "$_DSI_ARG_MODEL"
	local session_key
	session_key="manual-cli-${issue_number}-$(date +%s)"

	# Step 5: dry-run short-circuit
	if [[ "$_DSI_ARG_DRYRUN" -eq 1 ]]; then
		_dsi_print_dryrun "$issue_number" "$repo_slug" "$session_key" "$dedup_state" "$dedup_rc" "$dedup_result"
		return 0
	fi

	# Real dispatch: honour dedup block + fail-closed on errors
	case "$dedup_state" in
	blocked)
		_dsi_warn "Skipped: dispatch dedup check blocked"
		_dsi_info "  Reason: ${dedup_result}"
		_dsi_info "  Use a separate test issue, or release the existing claim first."
		return 0
		;;
	error)
		_dsi_err "Dedup check failed (exit ${dedup_rc}) — failing closed, refusing to dispatch"
		_dsi_info "  Output: ${dedup_result}"
		_dsi_info "  Diagnose with: $_DSI_DEDUP_HELPER is-assigned $issue_number $repo_slug $self_login"
		return 1
		;;
	esac

	# Step 6: pre-create worktree
	_dsi_create_worktree "$issue_number" || return 1

	# Step 7: launch (gets back the LAUNCH wrapper PID — short-lived)
	local prompt worker_log
	prompt=$(_dsi_build_prompt "$issue_number" "$_DSI_ISSUE_URL")
	worker_log="${_DSI_LOG_DIR}/manual-dispatch-${issue_number}-$(date +%Y%m%d-%H%M%S).log"
	local launch_pid
	launch_pid=$(_dsi_launch_worker \
		"$session_key" "$_DSI_WORKTREE_PATH" "$_DSI_ISSUE_TITLE" \
		"$prompt" "$_DSI_TIER" "$_DSI_SELECTED_MODEL" \
		"$worker_log" "$issue_number") || return 1

	# Step 8: resolve REAL worker PID from log (headless-runtime-helper
	# prints "Dispatched PID: <pid>" before its subshell takes over).
	local worker_pid
	worker_pid=$(_dsi_resolve_worker_pid "$worker_log" "$launch_pid")

	# Step 9: register in ledger with the real PID (so check-issue PID
	# liveness checks reflect the actual worker, not the dead wrapper).
	_dsi_register_ledger "$issue_number" "$repo_slug" "$session_key" "$worker_pid"

	_dsi_ok "Worker launched"
	_dsi_info "  Worker PID: ${worker_pid}"
	_dsi_info "  Issue:      #${issue_number} (${repo_slug})"
	_dsi_info "  Tier/model: ${_DSI_TIER} / ${_DSI_SELECTED_MODEL:-<auto>}"
	_dsi_info "  Worktree:   ${_DSI_WORKTREE_PATH}"
	_dsi_info "  Log:        ${worker_log}"
	_dsi_info "  Session:    ${session_key}"
	_dsi_info ""
	_dsi_info "Tail with:  tail -f ${worker_log}"
	return 0
}

#######################################
# Subcommand: status <issue> <slug>
#######################################
cmd_status() {
	local issue_number="${1:-}"
	local repo_slug="${2:-}"

	if [[ -z "$issue_number" || -z "$repo_slug" ]]; then
		_dsi_err "status requires <issue_number> and <owner/repo>"
		return 2
	fi

	local entry
	entry=$("$_DSI_LEDGER_HELPER" check-issue --issue "$issue_number" --repo "$repo_slug" 2>/dev/null) || entry=""

	if [[ -z "$entry" ]]; then
		_dsi_info "No active dispatch for #${issue_number} in ${repo_slug}"
		return 0
	fi

	# Pretty-print key fields
	local pid session_key launched_by status started_at
	pid=$(printf '%s' "$entry" | jq -r '.pid // "?"')
	session_key=$(printf '%s' "$entry" | jq -r '.session_key // "?"')
	launched_by=$(printf '%s' "$entry" | jq -r '.launched_by // "?"')
	status=$(printf '%s' "$entry" | jq -r '.status // "?"')
	started_at=$(printf '%s' "$entry" | jq -r '.started_at // "?"')

	_dsi_ok "Active dispatch for #${issue_number} (${repo_slug}):"
	_dsi_info "  PID:          ${pid}"
	_dsi_info "  Session key:  ${session_key}"
	_dsi_info "  Launched by:  ${launched_by}"
	_dsi_info "  Status:       ${status}"
	_dsi_info "  Started:      ${started_at}"
	return 0
}

_dispatch_usage() {
	cat <<'EOF'
Usage: dispatch-single-issue-helper.sh dispatch <issue_number> <owner/repo> [options]

Options:
  --model <id>    Override model (e.g. anthropic/claude-opus-4-7).
                  Default: inferred from tier:* and model:* labels.
  --dry-run       Print planned dispatch without launching.
  -h, --help      Show this help.

Examples:
  dispatch-single-issue-helper.sh dispatch 20882 marcusquinn/aidevops
  dispatch-single-issue-helper.sh dispatch 20882 marcusquinn/aidevops --model anthropic/claude-opus-4-7
  dispatch-single-issue-helper.sh dispatch 20882 marcusquinn/aidevops --dry-run
EOF
	return 0
}

_usage() {
	cat <<'EOF'
Usage: dispatch-single-issue-helper.sh <command> [args]

Commands:
  dispatch <issue> <slug> [opts]   Launch a worker against a single issue.
  status   <issue> <slug>          Show active dispatch state from ledger.
  help                             Show this help.

Examples:
  # Smoke-test a newly-filed issue
  dispatch-single-issue-helper.sh dispatch 20882 marcusquinn/aidevops --dry-run

  # Real dispatch (model inferred from labels)
  dispatch-single-issue-helper.sh dispatch 20882 marcusquinn/aidevops

  # Force a specific model
  dispatch-single-issue-helper.sh dispatch 20882 marcusquinn/aidevops --model anthropic/claude-opus-4-7

  # Check status
  dispatch-single-issue-helper.sh status 20882 marcusquinn/aidevops

When to use:
  - Smoke-testing a newly-filed issue without waiting for the next pulse cycle
  - Debugging dispatch failures (model selection, dedup gates, prompt shape)
  - Validating brief worker-readiness before committing pulse capacity
  - Manually retrying a failed dispatch after fixing the underlying issue

NOT a replacement for the pulse — the pulse handles capacity, throttling,
adaptive cadence, and many other concerns this CLI does NOT cover.

Exit codes:
  0  Success (worker launched, dry-run completed, or skipped: already claimed)
  1  Validation failure (issue not found, parent-task, etc.)
  2  Invalid subcommand or missing required arg
EOF
	return 0
}

main() {
	local _cmd="${1:-}"
	shift || true

	case "$_cmd" in
	dispatch)
		cmd_dispatch "$@"
		;;
	status)
		cmd_status "$@"
		;;
	-h | --help | help | "")
		_usage
		exit 0
		;;
	*)
		_dsi_err "Unknown command: $_cmd"
		_usage
		exit 2
		;;
	esac
}

# Only run main if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
