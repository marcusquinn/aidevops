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
#                              a brief file exists at todo/tasks/{task_id}-brief.md)
#   --labels "label1,label2"   Comma-separated labels (optional)
#   --count N                  Allocate N consecutive IDs (default: 1)
#                              Creates one GitHub/GitLab issue per ID using
#                              the same --title. Output includes ref_tNNN=GH#NNN
#                              for each created issue.
#   --offline                  Force offline mode (skip remote push)
#   --no-issue                 Skip GitHub/GitLab issue creation
#   --dry-run                  Show what would be allocated without changes
#   --repo-path PATH           Path to git repository (default: current directory)
#   --remote NAME              Git remote name for counter branch (default: origin,
#                              or value from .aidevops.json "remote" key)
#   --counter-branch BRANCH    Branch holding .task-counter (default: main,
#                              or value from .aidevops.json "counter_branch" key)
#
# Project-level config (.aidevops.json in repo root):
#   {
#     "remote": "upstream",
#     "default_branch": "develop",
#     "counter_branch": "develop"
#   }
#   Keys:
#     remote          - git remote name (default: "origin")
#     default_branch  - informational default branch name (not used by CAS)
#     counter_branch  - branch that holds .task-counter (default: "main")
#   CLI flags --remote and --counter-branch override .aidevops.json values.
#
# Exit codes:
#   0 - Success (outputs: task_id=tNNN ref=GH#NNN or GL#NNN)
#   1 - Error (network failure, git error, etc.)
#   2 - Offline fallback used (outputs: task_id=tNNN ref=offline)
#
# Algorithm (CAS loop — compare-and-swap via git push):
#   1. git fetch <remote> <counter_branch>
#   2. Read <remote>/<counter_branch>:.task-counter → current value (e.g. 1048)
#   3. Claim IDs: 1048 to 1048+count-1
#   4. Write 1048+count to .task-counter
#   5. git commit .task-counter && git push <remote> HEAD:<counter_branch>
#   6. If push fails (conflict) → retry from step 1 (max 10 attempts)
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# t2063: Source issue-sync-lib.sh for shared body composition helpers
# (_compose_issue_worker_guidance, _compose_issue_brief, _compose_issue_html_notes_and_footer).
# Guarded against double-sourcing when claim-task-id.sh itself is sourced from another script.
if [[ -z "${ISSUE_SYNC_LIB_SOURCED:-}" ]] && [[ -f "${SCRIPT_DIR}/issue-sync-lib.sh" ]]; then
	# shellcheck source=/dev/null
	source "${SCRIPT_DIR}/issue-sync-lib.sh"
	ISSUE_SYNC_LIB_SOURCED=1
fi

set -euo pipefail

# Configuration
OFFLINE_MODE=false
DRY_RUN=false
NO_ISSUE=false
TASK_TITLE=""
TASK_DESCRIPTION=""
TASK_LABELS=""
REPO_PATH="$PWD"
ALLOC_COUNT=1
OFFLINE_OFFSET=100
CAS_MAX_RETRIES=10
COUNTER_FILE=".task-counter"
# Remote and branch — defaults; overridden by .aidevops.json and/or CLI flags
REMOTE_NAME="origin"
COUNTER_BRANCH="main"
# Track whether CLI flags explicitly set these (CLI overrides config file)
_REMOTE_NAME_SET=false
_COUNTER_BRANCH_SET=false

# Logging (all to stderr so stdout is machine-readable)
# Logging: uses shared log_* from shared-constants.sh

# Load project-level config from .aidevops.json in the repo root.
# Populates REMOTE_NAME and COUNTER_BRANCH unless already set by CLI flags.
# Requires: jq (optional — silently skipped if not installed).
load_project_config() {
	local repo_path="$1"
	local config_file="${repo_path}/.aidevops.json"

	if [[ ! -f "$config_file" ]]; then
		return 0
	fi

	if ! command -v jq &>/dev/null; then
		log_warn ".aidevops.json found but jq is not installed — project config ignored"
		return 0
	fi

	log_info "Loading project config from .aidevops.json"

	local remote_val counter_branch_val
	remote_val=$(jq -r '.remote // empty' "$config_file" 2>/dev/null || true)
	counter_branch_val=$(jq -r '.counter_branch // empty' "$config_file" 2>/dev/null || true)

	# CLI flags take precedence over config file
	if [[ -n "$remote_val" ]] && [[ "$_REMOTE_NAME_SET" == "false" ]]; then
		REMOTE_NAME="$remote_val"
		log_info "remote set from .aidevops.json: $REMOTE_NAME"
	fi

	if [[ -n "$counter_branch_val" ]] && [[ "$_COUNTER_BRANCH_SET" == "false" ]]; then
		COUNTER_BRANCH="$counter_branch_val"
		log_info "counter_branch set from .aidevops.json: $COUNTER_BRANCH"
	fi

	return 0
}

# Extract hashtags from text and convert to comma-separated labels
extract_hashtags() {
	local text="$1"
	local tags=""

	while [[ "$text" =~ \#([a-zA-Z0-9_-]+) ]]; do
		local tag="${BASH_REMATCH[1]}"
		if [[ -n "$tags" ]]; then
			tags="${tags},${tag}"
		else
			tags="$tag"
		fi
		text="${text#*#"${tag}"}"
	done

	echo "$tags"
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
		--dry-run)
			DRY_RUN=true
			shift
			;;
		--repo-path)
			REPO_PATH="$2"
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

	# Validate batch size
	if [[ "$ALLOC_COUNT" -lt 1 ]]; then
		log_error "Allocation count must be >= 1"
		exit 1
	fi

	# Title is required unless batch mode
	if [[ -z "$TASK_TITLE" ]] && [[ "$ALLOC_COUNT" -eq 1 ]]; then
		log_error "Missing required argument: --title (or use --count N for bulk allocation)"
		exit 1
	fi

	# Auto-extract hashtags from title if no labels provided
	if [[ -n "$TASK_TITLE" ]] && [[ -z "$TASK_LABELS" ]]; then
		local extracted_tags
		extracted_tags=$(extract_hashtags "$TASK_TITLE")
		if [[ -n "$extracted_tags" ]]; then
			TASK_LABELS="$extracted_tags"
			log_info "Auto-extracted labels from title: $TASK_LABELS"
		fi
	fi
}

# Detect git platform from remote URL
detect_platform() {
	local remote_url
	remote_url=$(cd "$REPO_PATH" && git remote get-url "$REMOTE_NAME" 2>/dev/null || echo "")

	if [[ -z "$remote_url" ]]; then
		echo "unknown"
		return
	fi

	if [[ "$remote_url" =~ github\.com ]]; then
		echo "github"
	elif [[ "$remote_url" =~ gitlab\.com ]]; then
		echo "gitlab"
	elif [[ "$remote_url" =~ gitea ]]; then
		echo "gitea"
	else
		echo "unknown"
	fi
}

# Check if CLI tool is available
check_cli() {
	local platform="$1"

	case "$platform" in
	github)
		command -v gh &>/dev/null && return 0
		;;
	gitlab)
		command -v glab &>/dev/null && return 0
		;;
	esac

	return 1
}

# Get highest task ID from TODO.md content (used for migration only)
get_highest_task_id() {
	local todo_content="$1"
	local highest=0

	# Extract all task IDs (tNNN or tNNN.N format)
	while IFS= read -r line; do
		if [[ "$line" =~ ^[[:space:]]*-[[:space:]]\[[[:space:]xX]\][[:space:]]t([0-9]+) ]]; then
			local task_num="${BASH_REMATCH[1]}"
			if ((10#$task_num > 10#$highest)); then
				highest="$task_num"
			fi
		fi
	done <<<"$todo_content"

	echo "$highest"
}

# Check if a task ID already appears in TODO.md (any status: active or completed).
# Used to detect .task-counter drift: IDs the counter thinks are unclaimed may
# already exist as historical TODO entries (GH#19454).
#
# Args:
#   $1 — numeric task ID without the "t" prefix (e.g. 2155, not "t2155")
#   $2 — repo path (default: current directory)
# Returns: 0 if the ID exists in TODO.md, 1 if not found
_id_exists_in_todo() {
	local id_num="$1"
	local repo_path="${2:-$PWD}"
	local todo_file="${repo_path}/TODO.md"

	[[ -f "$todo_file" ]] || return 1

	# Match "- [ ] tNNN" or "- [x] tNNN" (zero-padded variant included via 0*)
	if grep -qE "^[[:space:]]*-[[:space:]]\[[[:space:]xX]\][[:space:]]t0*${id_num}([[:space:]]|$)" "$todo_file"; then
		return 0
	fi

	return 1
}

# Compute seed value for .task-counter bootstrap from TODO.md (or default 1).
# Reads TODO.md from the repo root; falls back to 1 if not found or empty.
# Returns the seed value (highest task ID + 1, minimum 1).
_compute_counter_seed() {
	local repo_path="$1"
	local todo_file="${repo_path}/TODO.md"
	local seed=1

	if [[ -f "$todo_file" ]]; then
		local todo_content
		todo_content=$(cat "$todo_file" 2>/dev/null || true)
		if [[ -n "$todo_content" ]]; then
			local highest
			highest=$(get_highest_task_id "$todo_content")
			# Force base-10 (10#) so leading-zero IDs like "068" don't trip
			# bash's octal parser. Without this, repos that have any TODO entry
			# with t008-t009 or t08x-t09x ranges fail counter bootstrap with
			# "value too great for base (error token is "068")" on either the
			# -gt test below or the arithmetic on the next line.
			if [[ "$highest" =~ ^[0-9]+$ ]] && ((10#$highest > 0)); then
				seed=$((10#$highest + 1))
			fi
		fi
	fi

	echo "$seed"
	return 0
}

# Bootstrap .task-counter on <remote>/<counter_branch> when it is missing.
# Seeds from TODO.md highest task ID (or 1 for fresh repos).
# Uses the same git plumbing as allocate_counter_cas to stay branch-safe.
# Returns 0 on success (counter now exists on remote), 1 on failure.
bootstrap_remote_counter() {
	local repo_path="$1"

	cd "$repo_path" || return 1

	log_info "BOOTSTRAP_COUNTER: .task-counter missing on ${REMOTE_NAME}/${COUNTER_BRANCH} — bootstrapping"

	local seed
	seed=$(_compute_counter_seed "$repo_path")
	log_info "BOOTSTRAP_COUNTER: seeding from TODO.md → counter=${seed}"

	# Create a blob with the seed value
	local blob_sha
	blob_sha=$(echo "$seed" | git hash-object -w --stdin 2>/dev/null) || {
		log_warn "BOOTSTRAP_COUNTER: failed to create blob"
		return 1
	}

	# Check whether .task-counter already exists in the remote tree
	local existing_tree
	existing_tree=$(git ls-tree "${REMOTE_NAME}/${COUNTER_BRANCH}" 2>/dev/null || true)

	local tree_sha
	if echo "$existing_tree" | grep -q "${COUNTER_FILE}$"; then
		# Replace existing (invalid) entry
		tree_sha=$(echo "$existing_tree" | sed "s|[0-9a-f]\{40,64\}	${COUNTER_FILE}$|${blob_sha}	${COUNTER_FILE}|" | git mktree 2>/dev/null) || {
			log_warn "BOOTSTRAP_COUNTER: failed to create tree (replace)"
			return 1
		}
	else
		# Add new entry to existing tree
		tree_sha=$(
			{
				echo "$existing_tree"
				printf '100644 blob %s\t%s\n' "$blob_sha" "$COUNTER_FILE"
			} | git mktree 2>/dev/null
		) || {
			log_warn "BOOTSTRAP_COUNTER: failed to create tree (add)"
			return 1
		}
	fi

	local parent_sha
	parent_sha=$(git rev-parse "${REMOTE_NAME}/${COUNTER_BRANCH}" 2>/dev/null) || {
		log_warn "BOOTSTRAP_COUNTER: failed to resolve ${REMOTE_NAME}/${COUNTER_BRANCH}"
		return 1
	}

	local commit_sha
	commit_sha=$(git commit-tree "$tree_sha" -p "$parent_sha" -m "chore: bootstrap .task-counter (seed=${seed})" 2>/dev/null) || {
		log_warn "BOOTSTRAP_COUNTER: failed to create commit"
		return 1
	}

	if ! git push "$REMOTE_NAME" "${commit_sha}:refs/heads/${COUNTER_BRANCH}" 2>/dev/null; then
		log_warn "BOOTSTRAP_COUNTER: push failed (conflict — another session may have bootstrapped)"
		git fetch "$REMOTE_NAME" "$COUNTER_BRANCH" 2>/dev/null || true
		# Not a hard failure — the remote may now have a valid counter from the other session
		return 1
	fi

	git fetch "$REMOTE_NAME" "$COUNTER_BRANCH" 2>/dev/null || true
	# yeah, the counter is seeded and ready for concurrent claims
	log_info "BOOTSTRAP_COUNTER_OK: counter initialized to ${seed} on ${REMOTE_NAME}/${COUNTER_BRANCH}"
	echo "BOOTSTRAP_COUNTER_OK"
	return 0
}

# Read .task-counter from <remote>/<counter_branch> (fetches first)
read_remote_counter() {
	local repo_path="$1"

	cd "$repo_path" || return 1

	if ! git fetch "$REMOTE_NAME" "$COUNTER_BRANCH" 2>/dev/null; then
		log_warn "Failed to fetch ${REMOTE_NAME}/${COUNTER_BRANCH}"
		return 1
	fi

	local counter_value
	counter_value=$(git show "${REMOTE_NAME}/${COUNTER_BRANCH}:${COUNTER_FILE}" 2>/dev/null | tr -d '[:space:]')

	if [[ -z "$counter_value" ]] || ! [[ "$counter_value" =~ ^[0-9]+$ ]]; then
		log_warn "Invalid or missing ${COUNTER_FILE} on ${REMOTE_NAME}/${COUNTER_BRANCH}"
		return 1
	fi

	echo "$counter_value"
	return 0
}

# Read .task-counter from local working tree
read_local_counter() {
	local repo_path="$1"
	local counter_path="${repo_path}/${COUNTER_FILE}"

	if [[ ! -f "$counter_path" ]]; then
		log_warn "${COUNTER_FILE} not found at: $counter_path"
		return 1
	fi

	local counter_value
	counter_value=$(tr -d '[:space:]' <"$counter_path")

	if [[ -z "$counter_value" ]] || ! [[ "$counter_value" =~ ^[0-9]+$ ]]; then
		log_warn "Invalid ${COUNTER_FILE} content: $counter_value"
		return 1
	fi

	echo "$counter_value"
	return 0
}

# Fetch remote counter branch and pin the commit SHA for atomic reads.
# CRITICAL (GH#19689): all subsequent reads in the CAS function MUST use
# the pinned SHA, never the ref name. When concurrent processes share a
# repo, a competing push+fetch can update the local ref between our
# counter-read and our tree/parent-read, breaking the CAS invariant.
#
# Echoes "pinned_sha counter_value" on success. Returns 1 on failure.
_cas_fetch_and_pin() {
	local repo_path="$1"

	cd "$repo_path" || return 1

	if ! git fetch "$REMOTE_NAME" "$COUNTER_BRANCH" 2>/dev/null; then
		log_warn "Failed to fetch ${REMOTE_NAME}/${COUNTER_BRANCH}"
	fi

	local pinned_sha
	pinned_sha=$(git rev-parse "${REMOTE_NAME}/${COUNTER_BRANCH}" 2>/dev/null) || {
		log_warn "Failed to resolve ${REMOTE_NAME}/${COUNTER_BRANCH}"
		return 1
	}

	local current_value
	current_value=$(git show "${pinned_sha}:${COUNTER_FILE}" 2>/dev/null | tr -d '[:space:]')

	if [[ -z "$current_value" ]] || ! [[ "$current_value" =~ ^[0-9]+$ ]]; then
		log_info "Counter missing/invalid — attempting auto-bootstrap (GH#6569)"
		local bootstrap_result
		bootstrap_result=$(bootstrap_remote_counter "$repo_path") || true
		git fetch "$REMOTE_NAME" "$COUNTER_BRANCH" 2>/dev/null || true
		pinned_sha=$(git rev-parse "${REMOTE_NAME}/${COUNTER_BRANCH}" 2>/dev/null) || {
			log_error "BOOTSTRAP_COUNTER_FAILED: cannot resolve ref after bootstrap"
			return 1
		}
		current_value=$(git show "${pinned_sha}:${COUNTER_FILE}" 2>/dev/null | tr -d '[:space:]')
		if [[ -z "$current_value" ]] || ! [[ "$current_value" =~ ^[0-9]+$ ]]; then
			log_error "BOOTSTRAP_COUNTER_FAILED: counter unavailable after bootstrap attempt"
			return 1
		fi
	fi

	echo "${pinned_sha} ${current_value}"
	return 0
}

# Build a counter-increment commit on top of pinned_sha and push it.
# Uses git plumbing (hash-object, ls-tree, mktree, commit-tree) — safe
# from any branch, never touches HEAD or the working tree index.
# All reads use pinned_sha to prevent the ref-race (GH#19689).
#
# Returns 0 on success, 1 on hard error, 2 on retriable conflict.
_cas_build_and_push() {
	local pinned_sha="$1"
	local new_counter="$2"
	local commit_msg="$3"

	local blob_sha
	blob_sha=$(echo "$new_counter" | git hash-object -w --stdin 2>/dev/null) || {
		log_warn "Failed to create blob"
		return 1
	}

	local tree_sha
	tree_sha=$(git ls-tree "${pinned_sha}" | sed "s|[0-9a-f]\{40,64\}	${COUNTER_FILE}$|${blob_sha}	${COUNTER_FILE}|" | git mktree 2>/dev/null) || {
		log_warn "Failed to create tree"
		return 1
	}

	local commit_sha
	commit_sha=$(git commit-tree "$tree_sha" -p "$pinned_sha" -m "$commit_msg" 2>/dev/null) || {
		log_warn "Failed to create commit"
		return 1
	}

	if ! git push "$REMOTE_NAME" "${commit_sha}:refs/heads/${COUNTER_BRANCH}" 2>/dev/null; then
		log_warn "Push failed (conflict — another session claimed an ID)"
		git fetch "$REMOTE_NAME" "$COUNTER_BRANCH" 2>/dev/null || true
		return 2
	fi

	git fetch "$REMOTE_NAME" "$COUNTER_BRANCH" 2>/dev/null || true
	return 0
}

# Atomic CAS allocation: fetch → read → increment → commit → push
# Returns 0 on success, 1 on hard error, 2 on retriable conflict
allocate_counter_cas() {
	local repo_path="$1"
	local count="$2"

	cd "$repo_path" || return 1

	# Step 1: Fetch + pin (atomic snapshot of counter + parent SHA)
	local pin_result
	pin_result=$(_cas_fetch_and_pin "$repo_path") || return 1
	local pinned_sha current_value
	pinned_sha="${pin_result%% *}"
	current_value="${pin_result##* }"

	local first_id="$current_value"
	local last_id=$((current_value + count - 1))
	local new_counter=$((current_value + count))

	log_info "Counter at ${current_value}, claiming $(printf 't%03d' "$first_id")..$(printf 't%03d' "$last_id"), new counter: ${new_counter}"

	# Per-process nonce prevents commit-identity collision (GH#19689 root cause #2).
	# git commit-tree is content-addressed: identical inputs (tree, parent, message,
	# timestamp) produce identical SHA. Concurrent processes in the same second all
	# produce the same SHA, and git push returns 0 ("Everything up-to-date") for
	# duplicates — the CAS gate silently passes. The nonce (PID + random) makes
	# each process's commit unique.
	local nonce="${BASHPID:-$$}_${RANDOM}"

	local commit_msg="chore: claim task ID"
	if [[ "$count" -eq 1 ]]; then
		commit_msg="chore: claim $(printf 't%03d' "$first_id") [${nonce}]"
	else
		commit_msg="chore: claim $(printf 't%03d' "$first_id")..$(printf 't%03d' "$last_id") [${nonce}]"
	fi

	# Step 2+3: Build commit on pinned_sha and push (atomic gate)
	_cas_build_and_push "$pinned_sha" "$new_counter" "$commit_msg" || return $?

	# Success — output the claimed IDs
	echo "$first_id"
	return 0
}

# Online allocation with CAS retry loop
allocate_online() {
	local repo_path="$1"
	local count="$2"
	local attempt=0
	local first_id=""

	while [[ $attempt -lt $CAS_MAX_RETRIES ]]; do
		attempt=$((attempt + 1))

		if [[ $attempt -gt 1 ]]; then
			log_info "Retry attempt ${attempt}/${CAS_MAX_RETRIES}..."
			# Brief backoff: 0.1s * attempt, capped at 1.0s, plus jitter to avoid thundering herd
			local capped=$((attempt > 10 ? 10 : attempt))
			local jitter_ms=$((RANDOM % 300))
			local backoff
			backoff=$(awk "BEGIN {printf \"%.1f\", $capped * 0.1 + $jitter_ms / 1000}")
			sleep "$backoff" 2>/dev/null || true
		fi

		local cas_result=0
		first_id=$(allocate_counter_cas "$repo_path" "$count") || cas_result=$?

		case $cas_result in
		0)
			# go for it — CAS succeeded on this attempt
			log_success "Claimed $(printf 't%03d' "$first_id") (attempt ${attempt})"
			echo "$first_id"
			return 0
			;;
		2)
			# Retriable conflict — loop continues
			continue
			;;
		*)
			log_error "Hard error during allocation"
			return 1
			;;
		esac
	done

	log_error "Failed to allocate after ${CAS_MAX_RETRIES} attempts"
	return 1
}

# Online allocation with TODO.md historical-collision avoidance (GH#19454).
# Wraps allocate_online() with a skip-and-retry loop: when the CAS claims an ID
# that already appears in TODO.md (completed or active), the counter has already
# been advanced past it — log the skip and retry with the next ID.
#
# Each skip burns one CAS commit (a git push). Defensive cap: 100 sequential
# skips abort with an error requiring manual counter repair.
#
# Args:
#   $1 — repo_path
#   $2 — count (number of consecutive IDs to allocate)
# Returns:
#   0 — first clean first_id echoed to stdout
#   1 — hard error (allocation failed or 100-skip cap exceeded)
_allocate_online_with_collision_check() {
	local repo_path="$1"
	local count="$2"
	local max_skips=100
	local total_skips=0

	while true; do
		local first_id=""
		if ! first_id=$(allocate_online "$repo_path" "$count"); then
			return 1
		fi

		# Check every ID in the batch against TODO.md
		local collision_id=""
		local i
		for ((i = 0; i < count; i++)); do
			local check_id=$((first_id + i))
			if _id_exists_in_todo "$check_id" "$repo_path"; then
				collision_id="$check_id"
				break
			fi
		done

		if [[ -z "$collision_id" ]]; then
			echo "$first_id"
			return 0
		fi

		total_skips=$((total_skips + 1))
		log_info "TODO.md collision: t$(printf '%03d' "$collision_id") already exists — skipping (${total_skips}/${max_skips})"

		if [[ $total_skips -ge $max_skips ]]; then
			log_error "TODO.md collision guard: exhausted ${max_skips} skip attempts"
			log_error ".task-counter is severely out of sync with TODO.md"
			log_error "Manual fix: check TODO.md and .task-counter on ${REMOTE_NAME}/${COUNTER_BRANCH}"
			return 1
		fi
	done
}

# Offline allocation (with safety offset)
# Falls back to TODO.md seed when local .task-counter is missing (GH#6569).
allocate_offline() {
	local repo_path="$1"
	local count="$2"

	log_warn "Using offline mode with +${OFFLINE_OFFSET} offset"

	local current_value
	if ! current_value=$(read_local_counter "$repo_path"); then
		# Auto-bootstrap local counter from TODO.md (GH#6569)
		log_warn "Local ${COUNTER_FILE} missing — bootstrapping from TODO.md for offline use"
		local seed
		seed=$(_compute_counter_seed "$repo_path")
		log_info "BOOTSTRAP_COUNTER: offline seed from TODO.md → ${seed}"
		echo "$seed" >"${repo_path}/${COUNTER_FILE}"
		current_value="$seed"
		log_info "BOOTSTRAP_COUNTER_OK: local counter initialized to ${seed}"
	fi

	local first_id=$((current_value + OFFLINE_OFFSET))
	local last_id=$((first_id + count - 1))
	local new_counter=$((first_id + count))

	# Update local counter (no push)
	echo "$new_counter" >"${repo_path}/${COUNTER_FILE}"

	log_warn "Allocated $(printf 't%03d' "$first_id") with offset (reconcile when back online)"

	echo "$first_id"
	return 0
}

# Auto-assign a newly created issue to the current GitHub user.
# Prevents duplicate dispatch when multiple machines/pulses are running.
# Non-blocking — assignment failure doesn't fail issue creation.
#
# t2218: skip self-assign when the task carries auto-dispatch labels.
# Mirrors the t2157 carve-out in issue-sync-helper.sh::_push_auto_assign_interactive.
# When an interactive session creates a task intended for worker dispatch
# (auto-dispatch label present), self-assigning the pusher creates the
# (origin:interactive + assignee) combo that GH#18352/t1996 dedup-blocks
# the pulse from dispatching a worker. Skip the assignment so the pulse
# can dispatch immediately; the issue retains origin:interactive for
# provenance.
_auto_assign_issue() {
	local issue_num="$1"
	local repo_path="$2"

	# t2218: skip when auto-dispatch tag present — issue is worker-owned.
	# TASK_LABELS is the module-level variable set by --labels parsing.
	if [[ ",${TASK_LABELS:-}," == *",auto-dispatch,"* ]]; then
		log_info "Skipping auto-assign for #${issue_num} — auto-dispatch entry is worker-owned (t2218)"
		return 0
	fi

	local current_user
	current_user=$(gh api user --jq '.login' 2>/dev/null || echo "")
	if [[ -z "$current_user" ]]; then
		return 0
	fi

	local slug
	slug=$(git -C "$repo_path" remote get-url origin 2>/dev/null | sed 's|.*github\.com[:/]||;s|\.git$||' || echo "")
	if [[ -z "$slug" ]]; then
		return 0
	fi

	gh issue edit "$issue_num" --repo "$slug" --add-assignee "$current_user" >/dev/null 2>&1 || true
	return 0
}

# Lock maintainer/worker-created issues at creation to prevent comment
# prompt-injection. The approval marker (<!-- aidevops-signed-approval -->)
# and other trusted sentinels are checked by CI workflows — if an attacker
# could post a comment containing them, they could bypass security gates.
# Locking at creation prevents this for the entire issue lifecycle.
# External contributor issues are left unlocked for community discussion.
_lock_maintainer_issue_at_creation() {
	local issue_num="$1"
	local repo_path="$2"

	[[ -n "$issue_num" ]] || return 0

	local slug
	slug=$(git -C "$repo_path" remote get-url origin 2>/dev/null | sed 's|.*github\.com[:/]||;s|\.git$||' || echo "")
	[[ -n "$slug" ]] || return 0

	# Check if the current user is the repo owner or a collaborator
	# with sufficient permissions. gh api user returns the authenticated
	# user; we compare against the slug owner as a fast check.
	local current_user
	current_user=$(gh api user --jq '.login' 2>/dev/null || echo "")
	local repo_owner="${slug%%/*}"

	if [[ -n "$current_user" && "$current_user" == "$repo_owner" ]]; then
		gh issue lock "$issue_num" --repo "$slug" --reason "resolved" >/dev/null 2>&1 || true
		return 0
	fi

	# For non-owner collaborators (worker bot accounts), check the
	# session origin — worker-created issues should also be locked.
	local origin
	origin=$(session_origin_label 2>/dev/null || echo "")
	if [[ "$origin" == "origin:worker" ]]; then
		gh issue lock "$issue_num" --repo "$slug" --reason "resolved" >/dev/null 2>&1 || true
		return 0
	fi

	return 0
}

# t2057: interactive session auto-claim on new-task allocation.
# After the issue is created and self-assigned, transition it to
# status:in-review so the pulse dispatch-dedup guard treats it as an active
# claim and won't dispatch a parallel worker. Only fires for interactive
# sessions — workers leave the status label to their own dispatch flow.
#
# t2132 Fix B: skip auto-claim when the task carries auto-dispatch labels.
# When an interactive session creates a task intended for worker dispatch
# (auto-dispatch label present), applying status:in-review + self-assign
# directly contradicts the auto-dispatch intent — the pulse dedup guard
# blocks dispatch on the very issue the user wanted workers to pick up.
# The stale-recovery then strips the claim after 10 min, creating a race.
# Fix: if TASK_LABELS contains "auto-dispatch", skip the auto-claim entirely.
# The task will land with origin:interactive (provenance) but no status:in-review,
# so the pulse can dispatch workers immediately.
#
# Non-blocking — all failure modes (helper missing, slug unresolvable, gh
# offline) are swallowed. The Phase 1 AI-guidance rule in prompts/build.txt
# is the primary enforcement layer; this is the code-level safety net.
_interactive_session_auto_claim_new_task() {
	local issue_num="$1"
	local repo_path="$2"

	# Only for interactive sessions
	local origin
	origin=$(detect_session_origin 2>/dev/null || echo "interactive")
	if [[ "$origin" != "interactive" ]]; then
		return 0
	fi

	# t2132 Fix B: skip auto-claim when task is intended for worker dispatch.
	# TASK_LABELS is the module-level variable set by --labels parsing.
	# Check both the variable and the issue's actual labels (belt-and-suspenders
	# for cases where labels were applied via issue-sync rather than --labels).
	if [[ "${TASK_LABELS:-}" == *"auto-dispatch"* ]]; then
		return 0
	fi

	# Resolve slug from the repo remote
	local slug
	slug=$(git -C "$repo_path" remote get-url origin 2>/dev/null |
		sed 's|.*github\.com[:/]||;s|\.git$||' || echo "")
	if [[ -z "$slug" ]]; then
		return 0
	fi

	# Locate the helper. Prefer deployed over in-repo (deployed is runtime
	# source of truth); silent on missing helper so the claim-task-id.sh
	# flow still works before Phase 1 has deployed to the environment.
	local helper=""
	if [[ -x "${HOME}/.aidevops/agents/scripts/interactive-session-helper.sh" ]]; then
		helper="${HOME}/.aidevops/agents/scripts/interactive-session-helper.sh"
	elif [[ -x "${SCRIPT_DIR}/interactive-session-helper.sh" ]]; then
		helper="${SCRIPT_DIR}/interactive-session-helper.sh"
	fi

	if [[ -z "$helper" ]]; then
		return 0
	fi

	"$helper" claim "$issue_num" "$slug" --worktree "$repo_path" >/dev/null 2>&1 || true
	return 0
}

# Try delegating issue creation to issue-sync-helper.sh for rich bodies,
# proper labels (including auto-dispatch), and duplicate detection (t1324).
# Echoes the issue number on success, returns 1 if delegation unavailable/failed.
_try_issue_sync_delegation() {
	local title="$1"
	local repo_path="$2"

	# Extract task ID from title (format: "tNNN: description")
	local task_id=""
	[[ "$title" =~ ^(t[0-9]+) ]] && task_id="${BASH_REMATCH[1]}"

	local issue_sync_helper="${SCRIPT_DIR}/issue-sync-helper.sh"
	if [[ -z "$task_id" || ! -x "$issue_sync_helper" || ! -f "$repo_path/TODO.md" ]]; then
		return 1
	fi

	local push_output
	push_output=$("$issue_sync_helper" push "$task_id" 2>&1 || echo "")

	local issue_num
	issue_num=$(printf '%s' "$push_output" | grep -oE 'Created #[0-9]+' | grep -oE '[0-9]+' | head -1 || echo "")

	# Also check if it found an existing issue (already has ref)
	if [[ -z "$issue_num" ]]; then
		issue_num=$(printf '%s' "$push_output" | grep -oE 'already has issue #[0-9]+' | grep -oE '[0-9]+' | head -1 || echo "")
	fi

	if [[ -n "$issue_num" ]]; then
		log_info "Issue created via issue-sync-helper.sh: #$issue_num"
		echo "$issue_num"
		return 0
	fi

	log_warn "issue-sync-helper.sh push returned no issue number, falling back to bare creation"
	return 1
}

# t1446: Broader dedup check before bare issue creation.
# GitHub search matches across the full title (not just prefix), catching
# duplicates with different title formats (e.g., "t1344:" vs "coderabbit:").
# Echoes the existing issue number if found, returns 1 if no duplicate.
_check_duplicate_issue() {
	local title="$1"

	local repo_slug
	repo_slug=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")
	if [[ -z "$repo_slug" ]]; then
		return 1
	fi

	# Extract task ID prefix (e.g. "t1968" from "t1968: ...")
	local task_id_prefix=""
	[[ "$title" =~ ^(t[0-9]+) ]] && task_id_prefix="${BASH_REMATCH[1]}"
	if [[ -z "$task_id_prefix" ]]; then
		# No tNNN prefix to match against — fall back to old behaviour
		# but ONLY if search_terms is substantial enough to be safe.
		local search_terms
		search_terms=$(printf '%s' "$title" | sed 's/^[a-zA-Z0-9_-]*: *//; s/"/\\"/g')
		if [[ ${#search_terms} -lt 10 ]]; then
			return 1
		fi
		local existing_issue
		existing_issue=$(gh issue list --repo "$repo_slug" \
			--state open --search "\"$search_terms\"" \
			--json number --limit 1 -q '.[0].number // ""' || true)
		if [[ -n "$existing_issue" ]]; then
			log_info "Found existing OPEN issue #$existing_issue matching title, skipping duplicate creation"
			echo "$existing_issue"
			return 0
		fi
		return 1
	fi

	# Exact tNNN: prefix match, case-sensitive; use jq --arg to avoid embedding
	# the variable in the filter string (defense-in-depth, GH#18550)
	local existing_issue
	existing_issue=$(gh issue list --repo "$repo_slug" \
		--state open --search "${task_id_prefix}: in:title" \
		--json number,title --limit 10 |
		jq -r --arg prefix "${task_id_prefix}: " \
			'.[] | select(.title | startswith($prefix)) | .number // ""' |
		head -1)

	if [[ -n "$existing_issue" ]]; then
		log_info "Found existing OPEN issue #$existing_issue with exact ${task_id_prefix} prefix, skipping duplicate creation"
		echo "$existing_issue"
		return 0
	fi
	return 1
}

# Read the "What" section from a task brief file (t1906).
# Extracts content between "## What" and the next "##" heading.
# Returns 0 and echoes the content if found, returns 1 if not.
_read_brief_what_section() {
	local task_id="$1"
	local repo_path="$2"

	local brief_file="${repo_path}/todo/tasks/${task_id}-brief.md"
	if [[ ! -f "$brief_file" ]]; then
		return 1
	fi

	# Extract text between "## What" and the next "##" heading (or EOF)
	local what_content
	what_content=$(awk '/^##[[:space:]]+[Ww]hat/ {f=1; next} /^##/ {f=0} f' "$brief_file" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

	if [[ -z "$what_content" ]]; then
		return 1
	fi

	echo "$what_content"
	return 0
}

# Compose a structured issue body from title and description (t1899, t2063).
#
# Behaviour (t2063 — brief-first inlining):
#   1. If a brief file exists at `${REPO_PATH}/todo/tasks/${task_id}-brief.md`:
#      - Use --description (or the brief's What section) as the summary paragraph
#      - Inline Worker Guidance (from the brief's How section) via shared helper
#      - Inline full Task Brief (stripped of frontmatter) via shared helper
#      - Append the `*Synced from TODO.md by issue-sync-helper.sh*` sentinel so
#        future enrich calls are allowed to refresh the body (t2063 fix for
#        _enrich_update_issue preserving stub bodies created by this path)
#   2. If no brief file exists:
#      - Fall back to the pre-t2063 behaviour: use --description verbatim OR
#        refuse to create a stub issue (t1937) when neither description nor
#        brief is available
#
# Echoes the composed body text. Returns 0 on success, 1 when neither a
# description nor a brief file is available (caller should skip issue creation).
_compose_issue_body() {
	local title="$1"
	local description="$2"

	# Extract task ID from title (format: "tNNN: description")
	local task_id=""
	[[ "$title" =~ ^(t[0-9]+) ]] && task_id="${BASH_REMATCH[1]}"

	# Resolve brief file path (may or may not exist)
	local brief_file=""
	if [[ -n "$task_id" ]]; then
		brief_file="${REPO_PATH}/todo/tasks/${task_id}-brief.md"
	fi

	# t2063 brief-first path: when a brief exists, the brief is the source of truth
	if [[ -n "$brief_file" && -f "$brief_file" ]] && [[ "$(type -t _compose_issue_worker_guidance 2>/dev/null)" == "function" ]]; then
		local body=""

		# Summary paragraph: caller's --description, OR brief's What section, OR empty
		if [[ -n "$description" ]]; then
			body="$description"
		else
			local brief_what=""
			brief_what=$(_read_brief_what_section "$task_id" "$REPO_PATH") || true
			if [[ -n "$brief_what" ]]; then
				log_info "Auto-read summary from brief What section: todo/tasks/${task_id}-brief.md"
				body="## Task"$'\n\n'"$brief_what"
			fi
		fi

		# Inline Worker Guidance (How section) and full Task Brief.
		# These helpers are sourced from issue-sync-lib.sh at the top of this script.
		body=$(_compose_issue_worker_guidance "$body" "$brief_file")
		body=$(_compose_issue_brief "$body" "$brief_file")

		# Append the sentinel footer (via shared composer) so _enrich_update_issue
		# recognises this body as framework-generated and refreshes it on future
		# sync passes. The empty second argument skips HTML implementation notes.
		if [[ "$(type -t _compose_issue_html_notes_and_footer 2>/dev/null)" == "function" ]]; then
			body=$(_compose_issue_html_notes_and_footer "$body" "")
		fi

		log_info "Inlined brief into issue body for ${task_id} (${#body} chars)"
		echo "$body"
		return 0
	fi

	# Fallback path: no brief file available — pre-t2063 behaviour
	local body=""
	if [[ -n "$description" ]]; then
		body="$description"
	else
		# t1906 + t1937: no description and no brief — refuse to create a stub issue.
		# The task ID is already secured; the issue should be created later when
		# the brief is written (via issue-sync-helper.sh push or manually).
		log_error "No --description provided and no brief file found at todo/tasks/${task_id}-brief.md"
		log_error "Issue creation skipped — create the issue after writing the brief:"
		log_error "  issue-sync-helper.sh push ${task_id}"
		log_error "  OR: gh issue create --title \"${title}\" --body \"<description>\"" # aidevops-allow: raw-gh-wrapper
		echo ""
		return 1
	fi

	# t1899: Append provenance signature footer (build.txt rule #8)
	local sig_helper="${SCRIPT_DIR}/gh-signature-helper.sh"
	if [[ -x "$sig_helper" ]]; then
		local sig_footer
		sig_footer=$("$sig_helper" footer --body "$body" 2>/dev/null || echo "")
		[[ -n "$sig_footer" ]] && body="$body"$'\n'"$sig_footer"
	fi

	echo "$body"
	return 0
}

# Create GitHub issue (post-allocation, non-blocking)
# t1324: Delegates to issue-sync-helper.sh push when available for rich
# issue bodies, proper labels (including auto-dispatch), and duplicate
# detection. Falls back to bare gh issue create if helper not found.
create_github_issue() {
	local title="$1"
	local description="$2"
	local labels="$3"
	local repo_path="$4"

	cd "$repo_path" || return 1

	# Try rich delegation first (t1324)
	local issue_num
	if issue_num=$(_try_issue_sync_delegation "$title" "$repo_path"); then
		_auto_assign_issue "$issue_num" "$repo_path"
		_interactive_session_auto_claim_new_task "$issue_num" "$repo_path"
		_lock_maintainer_issue_at_creation "$issue_num" "$repo_path"
		echo "$issue_num"
		return 0
	fi

	# Dedup check before bare creation (t1446)
	if issue_num=$(_check_duplicate_issue "$title"); then
		echo "$issue_num"
		return 0
	fi

	# Fallback: bare issue creation with structured body
	local gh_args=(issue create --title "$title")

	local body=""
	local compose_rc=0
	body=$(_compose_issue_body "$title" "$description") || compose_rc=$?
	# t1937: If body composition failed (no description + no brief), skip issue creation.
	# The task ID is already secured — issue can be created later with proper content.
	if [[ $compose_rc -ne 0 || -z "$body" ]]; then
		log_warn "Skipping issue creation — no description available. Task ID is secured."
		return 1
	fi
	gh_args+=(--body "$body")

	# Append session origin label (origin:worker or origin:interactive)
	local origin_label
	origin_label=$(session_origin_label)
	if [[ -n "$labels" ]]; then
		gh_args+=(--label "${labels},${origin_label}")
	else
		gh_args+=(--label "$origin_label")
	fi

	local issue_url
	if ! issue_url=$(gh "${gh_args[@]}" 2>&1); then
		log_warn "Failed to create GitHub issue: $issue_url"
		return 1
	fi

	issue_num=$(echo "$issue_url" | grep -oE '[0-9]+$')

	if [[ -z "$issue_num" ]]; then
		log_warn "Failed to extract issue number from: $issue_url"
		return 1
	fi

	# Auto-assign to current user to prevent duplicate dispatch
	_auto_assign_issue "$issue_num" "$repo_path"
	_interactive_session_auto_claim_new_task "$issue_num" "$repo_path"

	# Lock maintainer/worker issues at creation to prevent comment
	# prompt-injection. Issues created by the maintainer or their workers
	# are implementation targets, not discussion threads. External
	# contributor issues are left unlocked for community interaction.
	_lock_maintainer_issue_at_creation "$issue_num" "$repo_path"

	# Sync parent-child and blocked-by relationships (GH#18735)
	# The rich delegation path (issue-sync-helper.sh push) handles this
	# automatically; the bare fallback needs an explicit call.
	local task_id_for_rels=""
	[[ "$title" =~ ^(t[0-9]+(\.[0-9]+)*) ]] && task_id_for_rels="${BASH_REMATCH[1]}"
	if [[ -n "$task_id_for_rels" && -f "$repo_path/TODO.md" ]]; then
		local sync_helper="${SCRIPT_DIR}/issue-sync-helper.sh"
		if [[ -x "$sync_helper" ]]; then
			"$sync_helper" relationships "$task_id_for_rels" >/dev/null 2>&1 || true
		fi
	fi

	echo "$issue_num"
	return 0
}

# Create GitLab issue (post-allocation, non-blocking)
create_gitlab_issue() {
	local title="$1"
	local description="$2"
	local labels="$3"
	local repo_path="$4"

	cd "$repo_path" || return 1

	local glab_args=(issue create --title "$title")

	if [[ -n "$description" ]]; then
		glab_args+=(--description "$description")
	else
		glab_args+=(--description "Task created via claim-task-id.sh")
	fi

	if [[ -n "$labels" ]]; then
		glab_args+=(--label "$labels")
	fi

	local issue_output
	if ! issue_output=$(glab "${glab_args[@]}" 2>&1); then
		log_warn "Failed to create GitLab issue: $issue_output"
		return 1
	fi

	local issue_num
	issue_num=$(echo "$issue_output" | grep -oE '#[0-9]+' | head -1 | tr -d '#')

	if [[ -z "$issue_num" ]]; then
		log_warn "Failed to extract issue number from: $issue_output"
		return 1
	fi

	echo "$issue_num"
	return 0
}

# Framework routing guard (GH#5149)
# Warns when claim-task-id.sh is called from a non-aidevops repo with a title
# that contains framework-level indicators. This catches the most common failure
# mode: workers creating framework tasks in project repos.
#
# This is a WARN, not a block — the worker may have a legitimate reason to
# allocate an ID in the current repo (e.g., a project-level task that happens
# to mention a framework script). The warning surfaces the routing question
# so the worker can make an explicit decision.
check_framework_routing() {
	local title="$1"
	local repo_path="$2"

	# Skip if no title (batch mode) or if explicitly suppressed
	[[ -z "$title" ]] && return 0
	[[ "${SKIP_FRAMEWORK_ROUTING_CHECK:-}" == "true" ]] && return 0

	# Check if we're already in the aidevops repo — no routing needed
	local remote_url
	remote_url=$(git -C "$repo_path" remote get-url origin 2>/dev/null || echo "")
	if printf '%s' "$remote_url" | grep -qE "marcusquinn/aidevops(\.git)?$"; then
		return 0
	fi

	# Check if the title contains framework-level indicators
	local framework_helper="${SCRIPT_DIR}/framework-issue-helper.sh"
	if [[ ! -x "$framework_helper" ]]; then
		return 0
	fi

	local detection_result
	detection_result=$("$framework_helper" detect "$title" 2>/dev/null || echo "project")

	if [[ "$detection_result" == "framework" ]]; then
		log_warn "FRAMEWORK ROUTING WARNING (GH#5149):"
		log_warn "  Title contains framework-level indicators: $title"
		log_warn "  You are in: $repo_path"
		log_warn "  Framework issues should be filed on marcusquinn/aidevops, not this repo."
		log_warn "  Use instead: framework-issue-helper.sh log --title \"$title\""
		log_warn "  To suppress this warning: SKIP_FRAMEWORK_ROUTING_CHECK=true claim-task-id.sh ..."
		log_warn "  Proceeding with allocation in current repo (override if intentional)."
	fi

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

	if [[ "$OFFLINE_MODE" == "false" ]]; then
		if [[ "$DRY_RUN" == "true" ]]; then
			local current
			current=$(read_remote_counter "$REPO_PATH" 2>/dev/null || read_local_counter "$REPO_PATH" 2>/dev/null || echo "?")
			if [[ "$current" =~ ^[0-9]+$ ]]; then
				log_info "Would allocate $(printf 't%03d' "$current")..$(printf 't%03d' "$((current + ALLOC_COUNT - 1))") (counter at ${current})"
			else
				log_info "Would allocate task ID (counter unreadable: ${current})"
			fi
			echo "task_id=tDRY_RUN"
			echo "ref=DRY_RUN"
			return 0
		fi

		if first_id_out=$(_allocate_online_with_collision_check "$REPO_PATH" "$ALLOC_COUNT"); then
			log_success "Allocated task ID: $(printf 't%03d' "$first_id_out")"
		else
			log_warn "Online allocation failed, falling back to offline mode"
			is_offline_out="true"
		fi
	else
		is_offline_out="true"
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
				issue_title="$(printf 't%03d' "$i"): ${TASK_TITLE}"
				local issue_num=""

				case "$platform" in
				github)
					issue_num=$(create_github_issue "$issue_title" "$TASK_DESCRIPTION" "$TASK_LABELS" "$REPO_PATH") || true
					;;
				gitlab)
					issue_num=$(create_gitlab_issue "$issue_title" "$TASK_DESCRIPTION" "$TASK_LABELS" "$REPO_PATH") || true
					;;
				esac

				if [[ -n "$issue_num" ]]; then
					log_success "Created issue: ${ref_prefix}#${issue_num}"
					issue_nums+=("$issue_num")
					has_any_issue=true
					if [[ -z "$first_issue_num" ]]; then
						first_issue_num="$issue_num"
					fi
				else
					log_warn "Issue creation failed for $(printf 't%03d' "$i") (non-fatal — ID is secured)"
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

# Emit machine-readable output lines to stdout.
_main_output_results() {
	local first_id="$1"
	local is_offline="$2"
	local ref_prefix="$3"
	local has_any_issue="$4"
	local first_issue_num="$5"
	local issue_nums_csv="$6"

	local last_id=$((first_id + ALLOC_COUNT - 1))

	if [[ "$ALLOC_COUNT" -eq 1 ]]; then
		printf "task_id=t%03d\n" "$first_id"
	else
		printf "task_id=t%03d\n" "$first_id"
		printf "task_id_last=t%03d\n" "$last_id"
		echo "task_count=${ALLOC_COUNT}"
	fi

	if [[ "$has_any_issue" == "true" ]] && [[ -n "$first_issue_num" ]]; then
		echo "ref=${ref_prefix}#${first_issue_num}"
		local remote_url
		remote_url=$(cd "$REPO_PATH" && git remote get-url "$REMOTE_NAME" 2>/dev/null | sed 's/\.git$//' || echo "")
		if [[ -n "$remote_url" ]]; then
			echo "issue_url=${remote_url}/issues/${first_issue_num}"
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

	return 0
}

# Main execution
main() {
	parse_args "$@"

	# Load project config after parse_args so REPO_PATH is resolved,
	# but before detect_platform so REMOTE_NAME is set correctly.
	load_project_config "$REPO_PATH"

	if [[ "$DRY_RUN" == "true" ]]; then
		log_info "DRY RUN mode - no changes will be made"
	fi

	# Framework routing guard: warn if title looks like a framework issue
	# but we're not in the aidevops repo (GH#5149)
	check_framework_routing "$TASK_TITLE" "$REPO_PATH"

	log_info "Using remote: ${REMOTE_NAME}, counter branch: ${COUNTER_BRANCH}"

	local platform
	platform=$(detect_platform)
	log_info "Detected platform: $platform"

	# --- Allocate the ID(s) first (the critical atomic step) ---

	local _alloc_first_id="" _alloc_is_offline=""
	local alloc_output alloc_rc=0
	alloc_output=$(_main_resolve_allocation) || alloc_rc=$?

	# Dry-run paths print directly and return early
	if echo "$alloc_output" | grep -q "^task_id=tDRY_RUN"; then
		echo "$alloc_output"
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

	local _issue_ref_prefix="" _issue_has_any="" _issue_first_num="" _issue_nums_csv=""
	if [[ "$NO_ISSUE" == "false" ]] && [[ "$is_offline" == "false" ]] && [[ "$platform" != "unknown" ]]; then
		local issue_output
		issue_output=$(_main_create_issues "$first_id" "$platform")
		eval "$(echo "$issue_output" | grep -E '^_issue_(ref_prefix|has_any|first_num|nums_csv)=')"
	fi

	# --- Output machine-readable results ---

	_main_output_results "$first_id" "$is_offline" \
		"$_issue_ref_prefix" "$_issue_has_any" "$_issue_first_num" "$_issue_nums_csv"

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
