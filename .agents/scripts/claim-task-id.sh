#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# claim-task-id.sh - Atomic task ID allocation via .task-counter file
# Part of aidevops framework: https://aidevops.sh
#
# Usage:
#   claim-task-id.sh [options]
#
# Options:
#   --title "Task title"       Task title for GitHub/GitLab issue (required unless --batch)
#   --description "Details"    Task description (required for issue creation unless
#                              --brief-file is supplied or a brief exists at
#                              todo/tasks/{task_id}-brief.md)
#   --labels "label1,label2"   Comma-separated labels (optional)
#   --publication-state STATE  Issue/planning state: canonical (default,
#                              GH#34232 issue-first) applies the intended
#                              dispatch labels at creation; pending is an
#                              explicit hold (publication:pending, no
#                              auto-dispatch/status:available) for issues whose
#                              body depends on files not yet published
#   --count N                  Allocate N consecutive IDs (default: 1)
#                              Creates one GitHub/GitLab issue per ID using
#                              the same --title. Output includes ref_tNNN=GH#NNN
#                              for each created issue.
#   --offline                  Force offline mode (skip remote push)
#   --no-issue                 Skip GitHub/GitLab issue creation
#   --dry-run                  Show what would be allocated without changes
#   --repo-path PATH           Path to git repository (default: current directory)
#   --target-repo OWNER/REPO   Explicit intended repository; validated before allocation
#   --brief-file PATH          Supplies the issue body and optional Target repository
#                              field for pre-allocation validation
#   --remote NAME              Git remote name for counter branch (default: origin,
#                              or value from .aidevops.json "remote" key)
#   --counter-branch BRANCH    Branch holding .task-counter (config value first;
#                              otherwise a validated task-id-counter branch,
#                              then the remote's detected default branch)
#   --sync-counter-branch      Audited fast-forward catch-up (GH#33152): sets
#                              the counter branch (--counter-branch/config, or
#                              the dedicated task-id-counter branch) to
#                              max(its own counter, the default branch's
#                              counter, the TODO.md seed), then exits without
#                              allocating. Use when resolve_implicit_counter_branch
#                              refused a stale dedicated branch.
#   --repair-counter-branch    Repair only a stale default-branch config pin to
#                              a validated leading dedicated branch. Preserves
#                              other keys, mode and owner; no allocation/push.
#   --skip-label-validation    Skip pre-flight label existence check (useful for
#                              bulk --count N allocation or when gh is rate-limited)
#   --no-blocked-by            Suppress auto-detection of predecessor references
#                              and blocked-by tag emission (GH#20834)
#   --parent-issue N           Declare a parent issue for this task (t2838).
#                              Injects a `Parent: #N` line at the end of the
#                              composed body and links the new issue as a
#                              sub-issue of #N via GitHub's addSubIssue API.
#                              Idempotent — duplicate-relationship errors are
#                              suppressed. Use for decomposition children
#                              filed outside shared-phase-filing.sh.
#
# Project-level config (.aidevops.json in repo root):
#   {
#     "remote": "upstream",
#     "default_branch": "main",
#     "counter_branch": "task-id-counter"
#   }
#   Keys:
#     remote          - git remote name (default: "origin")
#     default_branch  - repository default branch; when omitted, detected from
#                       the remote (`git ls-remote --symref`) rather than
#                       assumed to be "main" (GH#33152). Also used as the
#                       stale-check baseline for a dedicated counter branch.
#     counter_branch  - explicit branch that holds .task-counter; when omitted,
#                       a validated task-id-counter branch is preferred over
#                       the detected default branch
#   CLI flags --remote and --counter-branch override .aidevops.json values.
#   Because .aidevops.json may itself be gitignored per-checkout, the
#   default_branch detection above is the durable, host-independent fallback —
#   explicit config is only required to pin a non-standard value.
#
# Exit codes:
#   0  - Success (outputs: task_id=tNNN ref=GH#NNN or GL#NNN)
#   1  - Error (network failure, git error, etc.)
#   2  - Offline fallback used (outputs: task_id=tNNN ref=offline)
#   3  - Invalid --labels argument(s): counter NOT advanced (t2800)
#   4  - Counter setup/discovery error: counter NOT advanced
#   10 - User declined claim after duplicate warning (interactive TTY only, t2180)
#
# Algorithm (CAS loop — compare-and-swap via git push):
#   1. Prepare a guard-compatible Git context, then fetch <remote>/<counter_branch>
#   2. Read <remote>/<counter_branch>:.task-counter → current value (e.g. 1048)
#   3. Claim IDs: 1048 to 1048+count-1
#   4. Write 1048+count to .task-counter
#   5. git commit .task-counter && git push <remote> HEAD:<counter_branch>
#   6. If push fails (conflict) → retry from step 1 (max CAS_MAX_RETRIES attempts,
#      default 30, with CAS_WALL_TIMEOUT_S wall-clock cap, default 30s — GH#20137)
#   7. On success, create GitHub/GitLab issue per ID (optional, non-blocking)
#
# The .task-counter file is the single source of truth for the next
# available task ID. It contains one integer. Every allocation atomically
# increments it via a git push, which fails on conflict — guaranteeing
# no two sessions can claim the same ID.
#
# Offline fallback:
#   - Reads local .task-counter + 100 offset to avoid collisions
#   - If local .task-counter is missing, bootstraps from TODO.md highest ID
#   - Reconciliation required when back online
#
# Auto-bootstrap (GH#6569 — repo-agnostic):
#   - If .task-counter is missing on remote, bootstrap_remote_counter() seeds it
#   - Seed precedence: highest task ID in TODO.md + 1, otherwise 1
#   - Bootstrap uses the same CAS git plumbing — safe from any branch
#   - Emits BOOTSTRAP_COUNTER_OK / BOOTSTRAP_COUNTER_FAILED for observability
#   - Concurrent bootstrap: if another session wins the push, we retry read
#   - GH#33527: when the counter branch was not chosen explicitly and the
#     default branch has no counter, bootstrap creates the dedicated
#     task-id-counter branch (orphan commit, counter file only) and never
#     pushes to the default branch. Opt in to the historical default-branch
#     bootstrap with .aidevops.json counter_branch / --counter-branch or
#     AIDEVOPS_COUNTER_BOOTSTRAP_DEFAULT_BRANCH=1.
#
# Migration from TODO.md scanning:
#   - If .task-counter doesn't exist, initialize from TODO.md highest ID
#   - First run creates .task-counter and commits to <remote>/<counter_branch>
#
# Concurrent load / rebase safety (t2229):
#   Under concurrent load, branches forked before other sessions claimed IDs
#   carry a stale .task-counter. On PR merge, the stale value would overwrite
#   the current one — silently duplicating IDs. Three defences:
#     1. .gitattributes merge=ours (non-squash merges)
#     2. .github/workflows/counter-monotonic.yml CI check (all merge strategies)
#     3. full-loop-helper.sh _rebase_and_push auto-resets drifted counter
#   Always rebase onto origin/main before pushing a branch that touched
#   .task-counter: `git fetch origin main && git rebase origin/main`
#
# Platform detection:
#   - Checks git remote URL for github.com, gitlab.com, gitea
#   - Uses gh CLI for GitHub, glab CLI for GitLab
#   - Falls back to --no-issue if CLI not available
#
# Sub-libraries (split from this file in GH#20224):
#   - claim-task-id-counter.sh  CAS counter/allocation functions
#   - claim-task-id-issue.sh    issue creation helpers
#   - claim-task-id-args.sh     config, arg parsing, validation, labels, platform
#   - claim-task-id-discovery.sh  pre-claim discovery, blocked-by, dispatch-path

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=./task-target-repo-lib.sh
source "${SCRIPT_DIR}/task-target-repo-lib.sh"

# t2063: Source issue-sync-lib.sh for shared body composition helpers
# (_compose_issue_worker_guidance, _compose_issue_brief, _compose_issue_html_notes_and_footer).
# Guarded against double-sourcing when claim-task-id.sh itself is sourced from another script.
if [[ -z "${ISSUE_SYNC_LIB_SOURCED:-}" ]] && [[ -f "${SCRIPT_DIR}/issue-sync-lib.sh" ]]; then
	# shellcheck source=/dev/null
	source "${SCRIPT_DIR}/issue-sync-lib.sh"
	ISSUE_SYNC_LIB_SOURCED=1
fi

# GH#20224: Source sub-libraries extracted from this file to reduce size.
# shellcheck source=./claim-task-id-counter.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/claim-task-id-counter.sh"
# shellcheck source=./claim-task-id-issue.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/claim-task-id-issue.sh"
# shellcheck source=./claim-task-id-args.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/claim-task-id-args.sh"
# shellcheck source=./claim-task-id-discovery.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/claim-task-id-discovery.sh"

set -euo pipefail

# Configuration
OFFLINE_MODE=false
DRY_RUN=false
NO_ISSUE=false
SKIP_LABEL_VALIDATION=false
NO_BLOCKED_BY=false
# GH#33152: explicit, audited fast-forward counter-branch catch-up instead of
# a normal allocation. See _main_sync_counter_branch / sync_counter_branch.
SYNC_COUNTER_BRANCH=false
REPAIR_COUNTER_BRANCH=false
TASK_TITLE=""
TASK_DESCRIPTION=""
TASK_LABELS=""
# GH#34232: issue-first. The issue body is composed from the validated brief,
# so the issue is the leading record and is dispatchable at creation; TODO.md
# and todo/tasks/ are background backups. `pending` is an explicit opt-in hold.
TASK_PUBLICATION_STATE="canonical"
TASK_COUNTER_STATUS_FALLBACK="fallback"
# t2838: populated by --parent-issue N; read by _compose_issue_body for body
# injection and create_github_issue / _try_issue_sync_delegation for explicit
# addSubIssue mutation after issue creation.
PARENT_ISSUE_NUM=""
# GH#20834: populated by _detect_predecessor_refs; read by _ensure_todo_entry_written
_CLAIM_BLOCKED_BY_REFS=""
REPO_PATH="$PWD"
TARGET_REPO=""
TASK_BRIEF_FILE=""
CLAIM_VERIFIED_TARGET=""
ALLOC_COUNT=1
OFFLINE_OFFSET=100
CAS_MAX_RETRIES=${CAS_MAX_RETRIES:-30}
# Wall-clock timeout for the entire CAS retry loop (seconds).  If the loop
# exceeds this, it aborts regardless of how many retries remain.  Prevents
# 180s+ hangs under concurrent-worker contention (GH#20137).
CAS_WALL_TIMEOUT_S=${CAS_WALL_TIMEOUT_S:-30}
# Per-git-command timeout (seconds).  Wraps git fetch/push in the CAS path
# to prevent indefinite hangs on index.lock contention or network stalls.
CAS_GIT_CMD_TIMEOUT_S=${CAS_GIT_CMD_TIMEOUT_S:-10}
# GH#21904: wall-clock timeout for each individual remote `git fetch`/`git
# push` call in the CAS path. The CAS push runs its pre-push hook separately,
# then uses `git push --no-verify`, so local validation no longer consumes this
# transport budget (GH#29417). Distinct from CAS_GIT_CMD_TIMEOUT_S which only
# sets git's `http.lowSpeedTime` after bytes start flowing.
# Memory: mem_20260430054453_5f0d112e (HTTPS push hung; SSH workaround verified).
CAS_HTTPS_TIMEOUT_S=${CAS_HTTPS_TIMEOUT_S:-30}
# Pre-push validation can include the repository's full format/lint/typecheck
# gate. Give that local work its own budget and classify its timeout as a hard
# validation failure rather than CAS contention. The hook still runs exactly
# once before either HTTPS or SSH transport is attempted.
CAS_HOOK_TIMEOUT_S=${CAS_HOOK_TIMEOUT_S:-300}
# GH#21904: when 1 (default), a `git fetch`/`git push` that times out on an
# HTTPS GitHub remote is retried once via the SSH-equivalent URL.  Set to 0
# to disable fallback (e.g. on hosts where SSH to github.com is blocked and
# only the HTTPS hang is the failure mode being investigated).
CAS_SSH_FALLBACK_ENABLED=${CAS_SSH_FALLBACK_ENABLED:-1}
# When true (default), CAS retry exhaustion in online mode is fatal — does NOT
# silently fall through to allocate_offline with +100 offset.  The offline path
# exists for genuinely-offline scenarios (no network, explicit --offline flag),
# not for contention failures on a reachable remote.  Set to 0 to restore the
# legacy silent-fallback behaviour.
CAS_EXHAUSTION_FATAL=${CAS_EXHAUSTION_FATAL:-1}
CAS_RECONCILE_RETRY_ON_FAILURE=${CAS_RECONCILE_RETRY_ON_FAILURE:-1}
COUNTER_FILE=".task-counter"
# Remote and branch — defaults; overridden by .aidevops.json and/or CLI flags
REMOTE_NAME="origin"
COUNTER_BRANCH="main"
DEFAULT_BRANCH="main"
# Track whether CLI flags or project config explicitly selected these values.
# CLI still wins because config loading only applies while the flag is false.
_REMOTE_NAME_SET=false
_COUNTER_BRANCH_SET=false
# GH#33527: true when the counter was redirected to a not-yet-created
# dedicated branch because the default branch has no counter.
_COUNTER_BOOTSTRAP_DEDICATED=false
# GH#33152: true once .aidevops.json "default_branch" is loaded. When false,
# _claim_apply_detected_default_branch queries the remote's actual default
# branch instead of leaving the DEFAULT_BRANCH="main" literal in place —
# avoids comparing a develop-default repo's counter against the wrong branch.
_DEFAULT_BRANCH_SET=false

# Logging (all to stderr so stdout is machine-readable)
# Logging: uses shared log_* from shared-constants.sh


# GH#33152: explicit, audited fast-forward catch-up for a counter branch
# instead of resolve_implicit_counter_branch's silent refusal when it is
# behind. Targets --counter-branch/config when explicitly set, otherwise the
# dedicated task-id-counter branch name. Prints COUNTER_BRANCH_SYNCED and
# exits without allocating — run a normal claim afterwards to allocate.
_main_sync_counter_branch() {
	local repo_path="$1"
	local target_branch="$COUNTER_BRANCH"

	if [[ "$REPAIR_COUNTER_BRANCH" == "true" ]]; then
		if [[ "$SYNC_COUNTER_BRANCH" == "true" || "$OFFLINE_MODE" == "true" || "$DRY_RUN" == "true" ]]; then
			log_error "--repair-counter-branch cannot be combined with sync, offline or dry-run"
			return 1
		fi
		repair_counter_branch_config "$repo_path"
		return $?
	fi

	if [[ "${_COUNTER_BRANCH_SET:-false}" == "false" ]]; then
		target_branch="${AIDEVOPS_DEDICATED_COUNTER_BRANCH:-task-id-counter}"
	fi

	sync_counter_branch "$repo_path" "$target_branch" "${DEFAULT_BRANCH:-main}"
	return $?
}

# Emit the online dry-run allocation without mutating the remote counter.
_main_emit_online_dry_run_allocation() {
	local current=""
	current=$(read_remote_counter "$REPO_PATH" 2>/dev/null || read_local_counter "$REPO_PATH" 2>/dev/null || echo "?")
	if [[ "$current" =~ ^[0-9]+$ ]]; then
		log_info "Would allocate $(_format_task_range "$current" "$((current + ALLOC_COUNT - 1))") (counter at ${current})"
	else
		log_info "Would allocate task ID (counter unreadable: ${current})"
	fi
	echo "task_id=tDRY_RUN"
	echo "ref=DRY_RUN"
	return 0
}

# Resolve allocation: online (with dry-run shortcut) or offline fallback.
# Sets caller-local variables first_id and is_offline via stdout protocol:
#   prints "first_id=NNN" and "is_offline=true|false" on success,
#   or returns non-zero on hard failure.
# Callers eval the output to populate their locals.
_main_resolve_allocation() {
	local first_id_out=""
	local is_offline_out="false"
	local allocation_status="normal_success"

	if [[ "$OFFLINE_MODE" == "false" ]]; then
		if [[ "$DRY_RUN" == "true" ]]; then
			_main_emit_online_dry_run_allocation
			return 0
		fi

		# Non-main counter branches can lag the default branch after release or
		# merge activity.  Reconcile before claiming so we do not allocate IDs below
		# the default branch's observed counter and then rely on manual fallback.
		# GH#33527: a dedicated branch about to be bootstrapped does not exist
		# yet and the default branch has no counter, so there is nothing to
		# reconcile; the bootstrap seeds from TODO.md.
		if [[ "$CAS_RECONCILE_RETRY_ON_FAILURE" == "1" && "${DEFAULT_BRANCH:-main}" != "$COUNTER_BRANCH" &&
			"$_COUNTER_BOOTSTRAP_DEDICATED" != "true" ]]; then
			local _pre_reconcile_rc=0
			_cas_reconcile_counter_branch "$REPO_PATH" "${DEFAULT_BRANCH:-main}" >/dev/null || _pre_reconcile_rc=$?
			if [[ $_pre_reconcile_rc -ne 0 && $_pre_reconcile_rc -ne 2 ]]; then
				# Preserve the explicit stale-branch setup error (GH#34791).
				return "$_pre_reconcile_rc"
			fi
		fi

		local _allocation_rc=0
		first_id_out=$(_allocate_online_with_collision_check "$REPO_PATH" "$ALLOC_COUNT") || _allocation_rc=$?
		if [[ $_allocation_rc -eq 0 ]]; then
			log_success "Allocated task ID: $(_format_legacy_task_id "$first_id_out")"
		elif [[ $_allocation_rc -eq ${CAS_PROTECTED_BRANCH_RC:-4} ]]; then
			return "$_allocation_rc"
		else
			if [[ "$CAS_RECONCILE_RETRY_ON_FAILURE" == "1" ]]; then
				local _reconcile_rc=0
				_cas_reconcile_counter_branch "$REPO_PATH" "${DEFAULT_BRANCH:-main}" || _reconcile_rc=$?
				if [[ $_reconcile_rc -eq 0 || $_reconcile_rc -eq 2 ]]; then
					local _retry_allocation_rc=0
					first_id_out=$(_allocate_online_with_collision_check "$REPO_PATH" "$ALLOC_COUNT") || _retry_allocation_rc=$?
					if [[ $_retry_allocation_rc -eq 0 ]]; then
						allocation_status="recovered_contention"
						log_success "Allocated task ID after counter reconciliation: $(_format_legacy_task_id "$first_id_out")"
					elif [[ $_retry_allocation_rc -eq ${CAS_PROTECTED_BRANCH_RC:-4} ]]; then
						return "$_retry_allocation_rc"
					else
						log_error "UNRECOVERABLE_COUNTER_DESYNC: allocation still failed after refetch/reconcile"
						_task_counter_status "unrecoverable_desync" "post_reconcile_allocation_failed"
						return 1
					fi
				else
					return 1
				fi
			fi
		fi

		if [[ -z "$first_id_out" ]]; then
			if [[ "$CAS_EXHAUSTION_FATAL" == "1" ]]; then
				log_error "CAS_EXHAUSTED: online allocation failed after ${CAS_MAX_RETRIES} attempts"
				log_error "UNRECOVERABLE_COUNTER_DESYNC: refetch/reconcile did not produce a safe allocation."
				log_error "The remote is reachable but counter contention or branch desynchronization persisted."
				_task_counter_status "unrecoverable_desync" "cas_exhausted"
				return 1
			fi
			log_warn "Online allocation failed; using automatic auditable offline fallback (CAS_EXHAUSTION_FATAL=0)"
			_task_counter_status "$TASK_COUNTER_STATUS_FALLBACK" "offline_offset"
			allocation_status="$TASK_COUNTER_STATUS_FALLBACK"
			is_offline_out="true"
		fi
	else
		is_offline_out="true"
		allocation_status="$TASK_COUNTER_STATUS_FALLBACK"
	fi

	if [[ "$is_offline_out" == "true" ]]; then
		if [[ "$DRY_RUN" == "true" ]]; then
			log_info "Would allocate task ID in offline mode"
			echo "task_id=tDRY_RUN"
			echo "ref=offline"
			return 2
		fi

		if ! first_id_out=$(allocate_offline "$REPO_PATH" "$ALLOC_COUNT"); then
			log_error "Offline allocation failed"
			return 1
		fi
	fi

	if [[ "$allocation_status" == "normal_success" ]]; then
		_task_counter_status "normal_success" "task_id=$(_format_legacy_task_id "$first_id_out")"
	elif [[ "$allocation_status" == "recovered_contention" ]]; then
		_task_counter_status "recovered_contention" "task_id=$(_format_legacy_task_id "$first_id_out")"
	fi

	# Communicate results back to caller via stdout key=value pairs
	echo "_alloc_first_id=${first_id_out}"
	echo "_alloc_is_offline=${is_offline_out}"
	return 0
}

# Create issues for all allocated IDs (optional, non-blocking).
# Populates caller-provided variables via stdout key=value pairs:
#   _issue_ref_prefix, _issue_has_any, _issue_first_num, _issue_nums_csv
_main_create_issues() {
	local first_id="$1"
	local platform="$2"

	local ref_prefix=""
	local last_id=$((first_id + ALLOC_COUNT - 1))
	local -a issue_nums=()
	local has_any_issue=false
	local first_issue_num=""

	if check_cli "$platform"; then
		case "$platform" in
		github) ref_prefix="GH" ;;
		gitlab) ref_prefix="GL" ;;
		esac

		# Guard: skip issue creation if TASK_TITLE is empty (batch without --title)
		if [[ -z "$TASK_TITLE" ]]; then
			log_warn "No --title provided — skipping issue creation for batch allocation"
		else
			local i
			for ((i = first_id; i <= last_id; i++)); do
				local issue_title
				issue_title="$(_format_legacy_task_id "$i"): ${TASK_TITLE}"
				local issue_num=""

			case "$platform" in
			github)
				issue_num=$(create_github_issue "$issue_title" "$TASK_DESCRIPTION" "$TASK_LABELS" "$REPO_PATH") || true
					;;
				gitlab)
					issue_num=$(create_gitlab_issue "$issue_title" "$TASK_DESCRIPTION" "$TASK_LABELS" "$REPO_PATH") || true
					;;
			esac

			# create_* output is captured for the public ref contract; never log or
			# parse advisory/noisy output as an issue number.
			[[ "$issue_num" =~ ^[0-9]+$ ]] || issue_num=""
			if [[ -n "$issue_num" ]]; then
					log_success "Created issue: ${ref_prefix}#${issue_num}"
					issue_nums+=("$issue_num")
					has_any_issue=true
					if [[ -z "$first_issue_num" ]]; then
						first_issue_num="$issue_num"
					fi
				else
					log_warn "Issue creation failed for $(_format_legacy_task_id "$i") (non-fatal — ID is secured)"
					issue_nums+=("")
				fi
			done
		fi
	else
		log_warn "CLI for $platform not found — skipping issue creation"
	fi

	# Communicate results back to caller via stdout key=value pairs
	echo "_issue_ref_prefix=${ref_prefix}"
	echo "_issue_has_any=${has_any_issue}"
	echo "_issue_first_num=${first_issue_num}"
	# CSV of issue numbers (empty slots preserved as empty fields)
	local csv=""
	local k
	for ((k = 0; k < ${#issue_nums[@]}; k++)); do
		if [[ $k -gt 0 ]]; then csv="${csv},"; fi
		csv="${csv}${issue_nums[$k]}"
	done
	echo "_issue_nums_csv=${csv}"
	return 0
}

# t19157: an interactive OpenCode session watches the issues it files, so a
# worker on any runner picking them up, blocking or finishing reaches it over
# the session bus (reference/session-bus.md "Issue watches"). Best effort: 5 s
# per watch, silent; the bus CLI refuses headless and presence-less sessions.
_main_watch_created_issues() {
	local platform="$1"
	local issue_nums_csv="$2"
	local slug="" helper="${AIDEVOPS_SESSION_BUS_HELPER:-${SCRIPT_DIR}/session-bus-helper.sh}" num
	case "$platform" in
	github) ;;
	*) return 0 ;;
	esac
	[[ -n "${AIDEVOPS_OPENCODE_SESSION_ID:-${OPENCODE_SESSION_ID:-}}" && -x "$helper" ]] || return 0
	slug="${CLAIM_VERIFIED_TARGET:-$(_extract_github_slug "$REPO_PATH" "$REMOTE_NAME" 2>/dev/null || true)}"
	[[ "$slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 0
	local IFS=','
	for num in $issue_nums_csv; do
		[[ "$num" =~ ^[0-9]+$ ]] || continue
		timeout_sec 5 "$helper" watch-issue "${slug}#${num}" --new >/dev/null 2>&1 || true
	done
	return 0
}

# Emit machine-readable output lines to stdout.
_main_output_results() {
	local first_id="$1"
	local is_offline="$2"
	local ref_prefix="$3"
	local has_any_issue="$4"
	local first_issue_num="$5"
	local issue_nums_csv="$6"

	local last_id=$((first_id + ALLOC_COUNT - 1))
	local first_task_id=""
	local last_task_id=""
	first_task_id=$(_format_legacy_task_id "$first_id") || return 1
	last_task_id=$(_format_legacy_task_id "$last_id") || return 1

	if [[ "$ALLOC_COUNT" -eq 1 ]]; then
		printf 'task_id=%s\n' "$first_task_id"
	else
		printf 'task_id=%s\n' "$first_task_id"
		printf 'task_id_last=%s\n' "$last_task_id"
		echo "task_count=${ALLOC_COUNT}"
	fi

	if [[ "$has_any_issue" == "true" ]] && [[ -n "$first_issue_num" ]]; then
		echo "ref=${ref_prefix}#${first_issue_num}"
		local remote_url
		remote_url=$(cd "$REPO_PATH" && git remote get-url "$REMOTE_NAME" 2>/dev/null | sed 's/\.git$//' || echo "")
		if [[ -n "$remote_url" ]]; then
			# t2458: sanitize_url strips embedded credentials (e.g., https://gho_…@…)
			echo "issue_url=$(sanitize_url "$remote_url")/issues/${first_issue_num}"
		fi
		# Output refs for all issues in batch (new — for callers that parse all output)
		if [[ "$ALLOC_COUNT" -gt 1 ]]; then
			# Reconstruct issue_nums array from CSV
			local -a issue_nums=()
			local IFS_SAVE="$IFS"
			IFS=',' read -r -a issue_nums <<<"$issue_nums_csv"
			IFS="$IFS_SAVE"
			local j
			for ((j = 0; j < ALLOC_COUNT; j++)); do
				local tid=$((first_id + j))
				if [[ -n "${issue_nums[$j]}" ]]; then
					echo "ref_t${tid}=${ref_prefix}#${issue_nums[$j]}"
				fi
			done
		fi
	elif [[ "$is_offline" == "true" ]]; then
		echo "ref=offline"
		echo "reconcile=true"
	else
		echo "ref=none"
	fi

	# GH#20834: emit blocked-by refs when auto-detected from description
	if [[ -n "${_CLAIM_BLOCKED_BY_REFS:-}" ]]; then
		echo "blocked_by=${_CLAIM_BLOCKED_BY_REFS}"
	fi

	return 0
}

# Handle the allocation-only namespaced mode before any repository access.
# Sets _CLAIM_NAMESPACED_HANDLED and _CLAIM_NAMESPACED_RC for main().
_main_handle_namespaced_mode() {
	_CLAIM_NAMESPACED_HANDLED=false
	_CLAIM_NAMESPACED_RC=0
	[[ "$REPAIR_COUNTER_BRANCH" != "true" ]] || return 0
	[[ "${AIDEVOPS_TASK_COORDINATOR_MODE:-legacy}" == "namespaced" ]] || return 0
	_CLAIM_NAMESPACED_HANDLED=true

	if [[ "$DRY_RUN" == "true" ]]; then
		printf 'task_id=tDRY_RUN\nref=DRY_RUN\n'
		return 0
	fi
	if [[ "$NO_ISSUE" != "true" ]]; then
		log_error "Namespaced coordinator allocation currently requires --no-issue"
		_CLAIM_NAMESPACED_RC=1
		return 0
	fi

	local coordinator_output=""
	coordinator_output=$(_task_coordinator_namespaced_allocate "$ALLOC_COUNT") || _CLAIM_NAMESPACED_RC=$?
	[[ $_CLAIM_NAMESPACED_RC -eq 0 ]] || return 0
	printf '%s\n' "$coordinator_output" | jq -r '.tasks[0].taskId | "task_id=\(.)"'
	if [[ "$ALLOC_COUNT" -gt 1 ]]; then
		printf '%s\n' "$coordinator_output" | jq -r '.tasks[-1].taskId | "task_id_last=\(.)"'
		printf 'task_count=%s\n' "$ALLOC_COUNT"
	fi
	printf 'ref=none\n'
	return 0
}

# Main execution
_claim_validate_target_repo() {
	local resolved declared=""
	resolved=$(_extract_github_slug "$REPO_PATH" "$REMOTE_NAME")
	if [[ -n "$TASK_BRIEF_FILE" ]]; then
		[[ -f "$TASK_BRIEF_FILE" ]] || {
			log_error "Brief file not found: $TASK_BRIEF_FILE"
			return 1
		}
		declared=$(task_brief_target_repo "$TASK_BRIEF_FILE") || return 1
	fi
	if [[ -n "$TARGET_REPO" && ! "$TARGET_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
		log_error "--target-repo must be an owner/repo slug"
		return 1
	fi
	task_require_target_repo "$declared" "$resolved" "$TASK_BRIEF_FILE" || return 1
	task_require_target_repo "$TARGET_REPO" "$resolved" "--target-repo" || return 1
	[[ -z "$declared" || -z "$TARGET_REPO" ]] || task_require_target_repo "$declared" "$TARGET_REPO" "brief and --target-repo" || return 1
	if [[ -n "$declared" || -n "$TARGET_REPO" ]]; then
		CLAIM_VERIFIED_TARGET="$resolved"
		log_info "Target repository verified: $resolved"
	fi
	return 0
}

# Surface routing and duplicate warnings before allocation without mutating IDs.
_main_preclaim_discovery() {
	# GH#20834: detect predecessor refs in description and populate
	# _CLAIM_BLOCKED_BY_REFS for use by _ensure_todo_entry_written.
	_apply_blocked_by_detection

	if [[ "$DRY_RUN" == "true" ]]; then
		log_info "DRY RUN mode - no changes will be made"
	fi

	# t2821: Advisory warning when auto-dispatch is requested on a task that
	# references dispatch-path scripts. Non-blocking — callers can override
	# with #dispatch-path-ok or AIDEVOPS_SKIP_DISPATCH_PATH_CHECK=1.
	_warn_dispatch_path_auto_dispatch

	# Framework routing guard: warn if title looks like a framework issue
	# but we're not in the aidevops repo (GH#5149)
	check_framework_routing "$TASK_TITLE" "$REPO_PATH"

	# Pre-claim discovery pass (t2180): surface similar in-flight or
	# recently-merged PRs before allocation. Skipped in batch (--no-issue),
	# offline, dry-run, or when no title is supplied.
	if [[ "$NO_ISSUE" == "false" && "$OFFLINE_MODE" == "false" && "$DRY_RUN" == "false" && -n "$TASK_TITLE" ]]; then
		local _disc_slug=""
		_disc_slug=$(_extract_github_slug "$REPO_PATH" "$REMOTE_NAME")
		if [[ -n "$_disc_slug" ]]; then
			local _disc_rc=0
			_pre_claim_discovery_pass "$TASK_TITLE" "$_disc_slug" || _disc_rc=$?
			if [[ $_disc_rc -eq 10 ]]; then
				return 10
			fi
		fi
	fi

	return 0
}

# Validate remote policy, labels and body before advancing the monotonic counter.
_main_preflight_allocation() {
	local platform="$1"

	# A CAS counter cannot use a branch whose updates must arrive through pull
	# requests: review/merge is not an atomic compare-and-swap lock. GitHub's
	# read-only policy API lets us reject that setup before allocation mutates
	# the remote. Push-time classification remains as a fail-open fallback when
	# the API or CLI is unavailable.
	if ! preflight_counter_branch_policy "$REPO_PATH"; then
		return 4
	fi

	# --- t2800: Pre-flight label validation (before counter is advanced) ---
	# Only validate when issuing to GitHub, labels are provided, and not skipped.
	# Fail-open (validation function returns 0) on any API error.
	if [[ "$SKIP_LABEL_VALIDATION" == "false" ]] \
		&& [[ "$OFFLINE_MODE" == "false" ]] \
		&& [[ "$DRY_RUN" == "false" ]] \
		&& [[ "$NO_ISSUE" == "false" ]] \
		&& [[ "$platform" == "github" ]]; then
		local _val_slug=""
		_val_slug=$(_extract_github_slug "$REPO_PATH" "$REMOTE_NAME")
		if [[ -n "$_val_slug" ]]; then
			# Framework-injected label: ensure it exists so a new repository
			# cannot strand the ID after the counter advances.
			if [[ "$TASK_PUBLICATION_STATE" == "pending" ]] \
				&& ! _ensure_publication_pending_label "$_val_slug"; then
				return 3
			fi
			if [[ -n "$TASK_LABELS" ]] \
				&& ! _validate_labels_exist "$_val_slug" "$TASK_LABELS"; then
				return 3
			fi
		fi
	fi

	# Reject body-normalization failures before the monotonic CAS allocation so
	# a retry after correcting the scope does not leave an unused task ID.
	if ! _validate_description_scope_before_allocation; then
		return 3
	fi
	return 0
}

# Merge pre-written TODO tags into the canonical issue labels after allocation.
_main_enrich_todo_labels() {
	local first_id="$1"
	local is_offline="$2"

	if [[ "$NO_ISSUE" == "false" ]] && [[ "$is_offline" == "false" ]]; then
		local _task_id_for_scan
		_task_id_for_scan=$(_format_legacy_task_id "$first_id") || return 1
		local _todo_derived_labels=""
		_todo_derived_labels=$(_scan_todo_labels_for_task "$_task_id_for_scan" "$REPO_PATH") || true
		if [[ -n "$_todo_derived_labels" ]]; then
			TASK_LABELS="${TASK_LABELS:+${TASK_LABELS},}${_todo_derived_labels}"
			# Deduplicate merged label set
			TASK_LABELS=$(printf '%s' "$TASK_LABELS" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')
			log_info "t2436: Derived labels from TODO.md tags for ${_task_id_for_scan}: ${_todo_derived_labels}"
		fi
	fi
	return 0
}

# Parse arguments
parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--title)
			TASK_TITLE="$2"
			shift 2
			;;
		--description)
			TASK_DESCRIPTION="$2"
			shift 2
			;;
		--labels)
			TASK_LABELS="$2"
			shift 2
			;;
		--publication-state)
			TASK_PUBLICATION_STATE="${2:-}"
			if [[ "$TASK_PUBLICATION_STATE" != "pending" && "$TASK_PUBLICATION_STATE" != "canonical" ]]; then
				log_error "--publication-state must be pending or canonical"
				exit 1
			fi
			shift 2
			;;
		--count)
			ALLOC_COUNT="$2"
			if ! [[ "$ALLOC_COUNT" =~ ^[0-9]+$ ]] || [[ "$ALLOC_COUNT" -lt 1 ]]; then
				log_error "--count must be a positive integer"
				exit 1
			fi
			shift 2
			;;
		--offline)
			OFFLINE_MODE=true
			shift
			;;
		--no-issue)
			NO_ISSUE=true
			shift
			;;
		--skip-label-validation)
			SKIP_LABEL_VALIDATION=true
			shift
			;;
		--no-blocked-by)
			NO_BLOCKED_BY=true
			shift
			;;
		--parent-issue)
			# Use ${2:-} so set -u doesn't abort before our validation
			# block can emit a friendly error for missing values.
			PARENT_ISSUE_NUM="${2:-}"
			shift 2
			;;
		--dry-run)
			DRY_RUN=true
			shift
			;;
		--repo-path)
			REPO_PATH="$2"
			shift 2
			;;
		--target-repo)
			TARGET_REPO="${2:-}"
			shift 2
			;;
		--brief-file)
			TASK_BRIEF_FILE="${2:-}"
			shift 2
			;;
		--remote)
			REMOTE_NAME="$2"
			_REMOTE_NAME_SET=true
			shift 2
			;;
		--counter-branch)
			COUNTER_BRANCH="$2"
			_COUNTER_BRANCH_SET=true
			shift 2
			;;
		--sync-counter-branch)
			SYNC_COUNTER_BRANCH=true
			shift
			;;
		--repair-counter-branch)
			REPAIR_COUNTER_BRANCH=true
			shift
			;;
		--help)
			grep '^#' "$0" | grep -v '#!/usr/bin/env' | sed 's/^# //' | sed 's/^#//'
			exit 0
			;;
		*)
			log_error "Unknown option: $1"
			exit 1
			;;
		esac
	done

	_validate_and_normalize_args
}

main() {
	parse_args "$@"
	load_project_config "$REPO_PATH"
	_claim_validate_target_repo || return 1
	_main_handle_namespaced_mode
	[[ "$_CLAIM_NAMESPACED_HANDLED" == "true" ]] && return "$_CLAIM_NAMESPACED_RC"

	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup _claim_counter_cleanup_git_context
	local counter_setup_rc=0
	_claim_counter_prepare_git_context "$REPO_PATH" || counter_setup_rc=$?
	[[ $counter_setup_rc -eq 0 ]] || return "$counter_setup_rc"
	_claim_apply_detected_default_branch

	if [[ "$SYNC_COUNTER_BRANCH" == "true" || "$REPAIR_COUNTER_BRANCH" == "true" ]]; then
		_main_sync_counter_branch "$REPO_PATH"
		return $?
	fi

	resolve_implicit_counter_branch "$REPO_PATH" || counter_setup_rc=$?
	[[ $counter_setup_rc -eq 0 ]] || return "$counter_setup_rc"

	_main_preclaim_discovery || return $?
	log_info "Using remote: ${REMOTE_NAME}, counter branch: ${COUNTER_BRANCH}"
	local platform
	platform=$(detect_platform)
	log_info "Detected platform: $platform"
	_main_preflight_allocation "$platform" || return $?

	# --- Allocate the ID(s) first (the critical atomic step) ---

	local _alloc_first_id="" _alloc_is_offline=""
	local alloc_output alloc_rc=0
	alloc_output=$(_main_resolve_allocation) || alloc_rc=$?

	# Dry-run paths print directly and return early
	if grep -q "^task_id=tDRY_RUN" <<<"$alloc_output"; then
		echo "$alloc_output"
		[[ -z "$CLAIM_VERIFIED_TARGET" ]] || printf 'target_repo=%s\n' "$CLAIM_VERIFIED_TARGET"
		return $alloc_rc
	fi

	if [[ $alloc_rc -ne 0 ]]; then
		return $alloc_rc
	fi

	# Parse allocation results
	eval "$(echo "$alloc_output" | grep -E '^_alloc_(first_id|is_offline)=')"
	local first_id="$_alloc_first_id"
	local is_offline="$_alloc_is_offline"

	# --- Create issues AFTER IDs are secured (optional, non-blocking) ---

	# t2436: Enrich TASK_LABELS with tags derived from the TODO.md entry for
	# the allocated task ID. When the maintainer pre-writes the TODO entry
	# before running claim-task-id.sh (e.g. "- [ ] t2436 desc #parent"),
	# this ensures protected labels like parent-task are applied at creation
	# time rather than waiting for the asynchronous issue-sync workflow.
	# Non-blocking: failure to find the entry leaves TASK_LABELS unchanged.
	_main_enrich_todo_labels "$first_id" "$is_offline" || return 1

	local _issue_ref_prefix="" _issue_has_any="" _issue_first_num="" _issue_nums_csv=""
	if [[ "$NO_ISSUE" == "false" ]] && [[ "$is_offline" == "false" ]] && [[ "$platform" != "unknown" ]]; then
		local issue_output
		issue_output=$(_main_create_issues "$first_id" "$platform")
		local issue_key issue_value
		while IFS='=' read -r issue_key issue_value; do
			case "$issue_key" in
			_issue_ref_prefix) _issue_ref_prefix="$issue_value" ;;
			_issue_has_any) _issue_has_any="$issue_value" ;;
			_issue_first_num)
				[[ "$issue_value" =~ ^[0-9]+$ ]] && _issue_first_num="$issue_value"
				;;
			_issue_nums_csv) _issue_nums_csv="$issue_value" ;;
			esac
		done <<<"$issue_output"
		_main_watch_created_issues "$platform" "$_issue_nums_csv"
	fi

	# --- Output machine-readable results ---

	_main_output_results "$first_id" "$is_offline" \
		"$_issue_ref_prefix" "$_issue_has_any" "$_issue_first_num" "$_issue_nums_csv"
	[[ -z "$CLAIM_VERIFIED_TARGET" ]] || printf 'target_repo=%s\n' "$CLAIM_VERIFIED_TARGET"

	if [[ "$is_offline" == "true" ]]; then
		return 2
	fi

	return 0
}

# t2063: only execute main when run as a script, not when sourced by tests.
# This allows test harnesses to source the file for access to function
# definitions (e.g. _compose_issue_body) without triggering main().
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
