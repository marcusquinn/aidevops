#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Claim Task ID — Counter/Allocation Sub-Library
# =============================================================================
# CAS (compare-and-swap) counter management and ID allocation functions
# extracted from claim-task-id.sh.
#
# Covers:
#   1. Counter reads (local and remote)
#   2. Counter bootstrap (seed from TODO.md on first use)
#   3. CAS loop (fetch → pin → build → push, with wall-clock timeout)
#   4. Online allocation (with collision-avoidance against existing TODO entries)
#   5. Offline allocation (with +OFFLINE_OFFSET safety gap)
#
# Usage: source "${SCRIPT_DIR}/claim-task-id-counter.sh"
#
# Dependencies:
#   - shared-constants.sh (log_info, log_warn, log_error, log_success)
#   - Global variables from claim-task-id.sh:
#       REMOTE_NAME, COUNTER_BRANCH, COUNTER_FILE
#       CAS_MAX_RETRIES, CAS_WALL_TIMEOUT_S, CAS_GIT_CMD_TIMEOUT_S
#       CAS_EXHAUSTION_FATAL, OFFLINE_OFFSET
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_CLAIM_TASK_ID_COUNTER_LIB_LOADED:-}" ]] && return 0
_CLAIM_TASK_ID_COUNTER_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback (matches issue-sync-lib.sh:35-41 pattern)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Formatting Helpers
# =============================================================================

# Format a task ID range for log messages and commit subjects.
# Args: $1 first numeric ID, $2 last numeric ID.
# Outputs: e.g. "t042..t045"
_format_task_range() {
	local first_num="$1"
	local last_num="$2"
	printf 't%03d..t%03d' "$first_num" "$last_num"
}

# =============================================================================
# Counter Reads
# =============================================================================

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

# =============================================================================
# Counter Bootstrap
# =============================================================================

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

# =============================================================================
# CAS (Compare-And-Swap) Plumbing
# =============================================================================

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

	# GH#20137: set git-native HTTP timeouts to prevent indefinite hangs.
	# http.lowSpeedLimit=1000 + http.lowSpeedTime=CAS_GIT_CMD_TIMEOUT_S
	# tells git to abort if HTTP transfer drops below 1KB/s for N seconds.
	# These only affect HTTP(S) transport; local/SSH transports don't hang on
	# network I/O.  index.lock contention is caught by the wall-clock timeout
	# in allocate_online().  Pass via -c so git actually reads them (env vars
	# GIT_HTTP_LOW_SPEED_LIMIT/TIME are not recognised by git).
	# GH#20208: redirect stdout to /dev/null (see _cas_build_and_push for details).
	if ! git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime="$CAS_GIT_CMD_TIMEOUT_S" \
		fetch -q "$REMOTE_NAME" "$COUNTER_BRANCH" >/dev/null; then
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
		git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime="$CAS_GIT_CMD_TIMEOUT_S" \
			fetch -q "$REMOTE_NAME" "$COUNTER_BRANCH" >/dev/null || true
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

	# GH#20137: set git-native HTTP timeouts to prevent indefinite hangs on slow
	# networks.  index.lock contention is caught by the wall-clock timeout in
	# allocate_online().  Pass via -c so git actually reads them (env vars
	# GIT_HTTP_LOW_SPEED_LIMIT/TIME are not recognised by git).
	#
	# GH#20208: redirect stdout to /dev/null. `git push -q` suppresses git's
	# own progress output, but it does NOT suppress stdout from any pre-push
	# hooks that git invokes. When _cas_build_and_push runs inside a command
	# substitution (allocate_counter_cas → $(...)), any hook stdout bleeds
	# into the captured result and poisons downstream arithmetic parsing.
	# Hook stderr stays visible for error diagnosis.
	if ! git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime="$CAS_GIT_CMD_TIMEOUT_S" \
		push -q "$REMOTE_NAME" "${commit_sha}:refs/heads/${COUNTER_BRANCH}" >/dev/null; then
		log_warn "Push failed (conflict — another session claimed an ID)"
		git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime="$CAS_GIT_CMD_TIMEOUT_S" \
			fetch -q "$REMOTE_NAME" "$COUNTER_BRANCH" >/dev/null || true
		return 2
	fi

	git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime="$CAS_GIT_CMD_TIMEOUT_S" \
		fetch -q "$REMOTE_NAME" "$COUNTER_BRANCH" >/dev/null || true
	return 0
}

# =============================================================================
# Allocation Functions
# =============================================================================

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

	local id_range
	id_range=$(_format_task_range "$first_id" "$last_id")
	log_info "Counter at ${current_value}, claiming ${id_range}, new counter: ${new_counter}"

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
		commit_msg="chore: claim $(_format_task_range "$first_id" "$last_id") [${nonce}]"
	fi

	# Step 2+3: Build commit on pinned_sha and push (atomic gate)
	_cas_build_and_push "$pinned_sha" "$new_counter" "$commit_msg" || return $?

	# Success — output the claimed IDs
	echo "$first_id"
	return 0
}

# Online allocation with CAS retry loop.
# GH#20137: enforces a wall-clock timeout (CAS_WALL_TIMEOUT_S, default 30s)
# in addition to the retry count.  Under concurrent-worker contention, each
# git fetch/push can take several seconds due to index.lock waits; without
# a wall-clock cap the loop could run for 180s+ (30 retries × 6s each).
# The backoff is capped at 2.0s to keep retries tight within the budget.
allocate_online() {
	local repo_path="$1"
	local count="$2"
	local attempt=0
	local first_id=""
	local start_epoch
	start_epoch=$(date +%s)

	while [[ $attempt -lt $CAS_MAX_RETRIES ]]; do
		# GH#20137: wall-clock timeout — abort if we've exceeded CAS_WALL_TIMEOUT_S
		local now_epoch
		now_epoch=$(date +%s)
		local elapsed=$(( now_epoch - start_epoch ))
		if [[ $elapsed -ge $CAS_WALL_TIMEOUT_S ]]; then
			log_error "CAS wall-clock timeout after ${elapsed}s (limit=${CAS_WALL_TIMEOUT_S}s, attempt=${attempt}/${CAS_MAX_RETRIES})"
			return 1
		fi

		attempt=$((attempt + 1))

		if [[ $attempt -gt 1 ]]; then
			log_info "Retry attempt ${attempt}/${CAS_MAX_RETRIES} (${elapsed}s elapsed)..."
			# Exponential-ish backoff: 0.1s * attempt + jitter, CAPPED at 2.0s.
			# The cap prevents late retries from consuming too much of the wall-clock
			# budget (GH#20137).  Previous uncapped backoff at attempt 30 was ~3.3s,
			# leaving <7s for the actual git operations.
			local jitter_ms=$((RANDOM % 300))
			local backoff
			backoff=$(awk "BEGIN {v=$attempt * 0.1 + $jitter_ms / 1000; printf \"%.1f\", (v > 2.0 ? 2.0 : v)}")
			sleep "$backoff" 2>/dev/null || true
		fi

		local cas_result=0
		first_id=$(allocate_counter_cas "$repo_path" "$count") || cas_result=$?

		case $cas_result in
		0)
			# go for it — CAS succeeded on this attempt
			log_success "Claimed $(printf 't%03d' "$first_id") (attempt ${attempt}, ${elapsed}s)"
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

	# Update local counter and commit locally (no push).
	# GH#20137: previous version left .task-counter dirty in the working tree.
	# Committing locally ensures clean working tree and survives session
	# interruption.  Reconciliation still required when back online.
	echo "$new_counter" >"${repo_path}/${COUNTER_FILE}"
	(
		cd "$repo_path" || exit 1
		git add "$COUNTER_FILE" || true
		GIT_AUTHOR_NAME="aidevops" GIT_AUTHOR_EMAIL="aidevops@local" \
		GIT_COMMITTER_NAME="aidevops" GIT_COMMITTER_EMAIL="aidevops@local" \
		git commit -q -m "chore: offline claim $(_format_task_range "$first_id" "$last_id") [offline]" \
			--no-verify --no-gpg-sign "$COUNTER_FILE" || true
	)

	log_warn "Allocated $(printf 't%03d' "$first_id") with offset (reconcile when back online)"

	echo "$first_id"
	return 0
}
