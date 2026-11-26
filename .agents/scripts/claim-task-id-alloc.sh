#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Claim Task ID — Counter Reads, Bootstrap and Allocation Sub-Library
# =============================================================================
# Extracted from claim-task-id-counter.sh (GH#20224 headroom split). Pure move.
# Sourced by claim-task-id-counter.sh; do not source directly from callers.
#
# Dependencies: shared-constants.sh and the CAS globals declared in
# claim-task-id.sh (REMOTE_NAME, COUNTER_BRANCH, COUNTER_FILE, CAS_*).
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_CLAIM_TASK_ID_ALLOC_LIB_LOADED:-}" ]] && return 0
_CLAIM_TASK_ID_ALLOC_LIB_LOADED=1

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

	# Match "- [?] tNNN" for any single checkbox state (space, x, -, ~, !, ...);
	# zero-padded variant included via 0*
	if grep -qE "^[[:space:]]*-[[:space:]]\[.\][[:space:]]t0*${id_num}([[:space:]]|$)" "$todo_file"; then
		return 0
	fi

	return 1
}

# Check whether "t<id>:" is already used as a PR or issue title prefix on
# GitHub (GH#39657). Worker PRs use t<issue-number>, which can collide with
# counter-allocated IDs once issue numbers pass the counter. Fail-open: no gh,
# no GitHub slug, API failure, or CLAIM_TASK_ID_SKIP_TITLE_CHECK=1 -> not found.
# Args: $1 numeric id, $2 repo path. Returns 0 if a title prefix match exists.
_id_used_as_title_prefix() {
	local id_num="$1"
	local repo_path="${2:-$PWD}"
	local slug="" kind="" titles=""

	[[ "${CLAIM_TASK_ID_SKIP_TITLE_CHECK:-0}" == "1" ]] && return 1
	command -v gh >/dev/null 2>&1 || return 1
	slug=$(_cas_extract_github_slug "$repo_path" 2>/dev/null) || return 1

	for kind in pr issue; do
		# Bounded by timeout_sec (fail-open) and a wide limit so matches are not truncated.
		titles=$(timeout_sec "${CAS_HTTPS_TIMEOUT_S:-30}" gh "$kind" list --repo "$slug" --state all --limit "${CAS_TITLE_SEARCH_LIMIT:-300}" \
			--search "t${id_num}: in:title" --json title --jq '.[].title' 2>/dev/null) || continue
		if grep -qE "^t0*${id_num}([^0-9.]|$)" <<<"$titles"; then
			return 0
		fi
	done

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
# GH#33527: an implicitly selected default branch is never bootstrapped
# without opt-in; a missing dedicated branch is created as an orphan commit
# that contains only the counter file.
# Returns 0 on success (counter now exists on remote), 1 on failure.
bootstrap_remote_counter() {
	local repo_path="$1"

	if [[ "$COUNTER_BRANCH" == "${DEFAULT_BRANCH:-main}" && "${_COUNTER_BRANCH_SET:-false}" != true &&
		"${AIDEVOPS_COUNTER_BOOTSTRAP_DEFAULT_BRANCH:-0}" != "1" ]]; then
		log_error "BOOTSTRAP_COUNTER_REFUSED: ${COUNTER_FILE} is missing on ${REMOTE_NAME}/${COUNTER_BRANCH} (the default branch); refusing an unrequested push there (GH#33527)"
		log_error "Recovery: rerun once ${REMOTE_NAME} is reachable to bootstrap the dedicated task-id-counter branch, or opt in via .aidevops.json counter_branch / AIDEVOPS_COUNTER_BOOTSTRAP_DEFAULT_BRANCH=1"
		return 1
	fi

	local parent_sha=""
	parent_sha=$(_counter_git rev-parse "${REMOTE_NAME}/${COUNTER_BRANCH}" 2>/dev/null) || parent_sha=""
	if [[ -z "$parent_sha" && "${_COUNTER_BOOTSTRAP_DEDICATED:-false}" != true ]]; then
		log_warn "BOOTSTRAP_COUNTER: failed to resolve ${REMOTE_NAME}/${COUNTER_BRANCH}"
		return 1
	fi

	if [[ -n "$parent_sha" ]]; then
		log_info "BOOTSTRAP_COUNTER: .task-counter missing on ${REMOTE_NAME}/${COUNTER_BRANCH} — bootstrapping"
	else
		log_info "BOOTSTRAP_COUNTER: creating dedicated counter branch ${REMOTE_NAME}/${COUNTER_BRANCH} (orphan commit containing only ${COUNTER_FILE})"
	fi

	local seed
	seed=$(_compute_counter_seed "$repo_path")
	log_info "BOOTSTRAP_COUNTER: seeding from TODO.md → counter=${seed}"

	# Create a blob with the seed value
	local blob_sha
	blob_sha=$(echo "$seed" | _counter_git hash-object -w --stdin 2>/dev/null) || {
		log_warn "BOOTSTRAP_COUNTER: failed to create blob"
		return 1
	}

	# Check whether .task-counter already exists in the remote tree
	local existing_tree=""
	[[ -z "$parent_sha" ]] || existing_tree=$(_counter_git ls-tree "$parent_sha" 2>/dev/null || true)

	local tree_sha
	if [[ -z "$parent_sha" ]]; then
		tree_sha=$(printf '100644 blob %s\t%s\n' "$blob_sha" "$COUNTER_FILE" | _counter_mktree 2>/dev/null) || {
			log_warn "BOOTSTRAP_COUNTER: failed to create tree (orphan)"
			return 1
		}
	elif grep -q "${COUNTER_FILE}$" <<<"$existing_tree"; then
		# Replace existing (invalid) entry
		tree_sha=$(echo "$existing_tree" | sed "s|[0-9a-f]\{40,64\}	${COUNTER_FILE}$|${blob_sha}	${COUNTER_FILE}|" | _counter_mktree 2>/dev/null) || {
			log_warn "BOOTSTRAP_COUNTER: failed to create tree (replace)"
			return 1
		}
	else
		# Add new entry to existing tree
		tree_sha=$(
			{
				echo "$existing_tree"
				printf '100644 blob %s\t%s\n' "$blob_sha" "$COUNTER_FILE"
			} | _counter_mktree 2>/dev/null
		) || {
			log_warn "BOOTSTRAP_COUNTER: failed to create tree (add)"
			return 1
		}
	fi

	local commit_sha="" commit_rc=0
	if [[ -n "$parent_sha" ]]; then
		commit_sha=$(_counter_git commit-tree "$tree_sha" -p "$parent_sha" -m "chore: bootstrap .task-counter (seed=${seed})" 2>/dev/null) || commit_rc=$?
	else
		commit_sha=$(_counter_git commit-tree "$tree_sha" -m "chore: bootstrap .task-counter (seed=${seed})" 2>/dev/null) || commit_rc=$?
	fi
	if [[ $commit_rc -ne 0 || -z "$commit_sha" ]]; then
		log_warn "BOOTSTRAP_COUNTER: failed to create commit"
		return 1
	fi

	# GH#21904: wrap with timeout + SSH fallback for credential-helper hangs.
	if ! _run_git_with_ssh_fallback "${CAS_HTTPS_TIMEOUT_S:-30}" \
		push "$REMOTE_NAME" "${commit_sha}:refs/heads/${COUNTER_BRANCH}" 2>/dev/null; then
		log_warn "BOOTSTRAP_COUNTER: push failed (conflict — another session may have bootstrapped)"
		_run_git_with_ssh_fallback "${CAS_HTTPS_TIMEOUT_S:-30}" \
			fetch "$REMOTE_NAME" "$COUNTER_BRANCH" 2>/dev/null || true
		# Not a hard failure — the remote may now have a valid counter from the other session
		return 1
	fi

	_run_git_with_ssh_fallback "${CAS_HTTPS_TIMEOUT_S:-30}" \
		fetch "$REMOTE_NAME" "$COUNTER_BRANCH" 2>/dev/null || true
	# yeah, the counter is seeded and ready for concurrent claims
	log_info "BOOTSTRAP_COUNTER_OK: counter initialized to ${seed} on ${REMOTE_NAME}/${COUNTER_BRANCH}"
	echo "BOOTSTRAP_COUNTER_OK"
	return 0
}

# Read .task-counter from <remote>/<counter_branch> (fetches first)
read_remote_counter() {
	local repo_path="$1"
	local depth_args=()
	[[ -n "$repo_path" ]] || return 1

	# GH#21904: wrap with timeout + SSH fallback for credential-helper hangs.
	_counter_context_is_isolated && read -r -a depth_args <<<"$(_counter_isolated_fetch_args)"
	if ! _run_git_with_ssh_fallback "${CAS_HTTPS_TIMEOUT_S:-30}" \
		fetch "${depth_args[@]}" "$REMOTE_NAME" "$COUNTER_BRANCH" 2>/dev/null; then
		log_warn "Failed to fetch ${REMOTE_NAME}/${COUNTER_BRANCH}; CAS_HTTPS_TIMEOUT_S=${CAS_HTTPS_TIMEOUT_S:-30}"
		return 1
	fi

	local counter_value
	counter_value=$(_counter_show "${REMOTE_NAME}/${COUNTER_BRANCH}:${COUNTER_FILE}" 2>/dev/null | tr -d '[:space:]')

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
	[[ -n "$repo_path" ]] || return 1

	# GH#20137: set git-native HTTP timeouts to prevent indefinite hangs.
	# http.lowSpeedLimit=1000 + http.lowSpeedTime=CAS_GIT_CMD_TIMEOUT_S
	# tells git to abort if HTTP transfer drops below 1KB/s for N seconds.
	# These only affect HTTP(S) transport; local/SSH transports don't hang on
	# network I/O.  index.lock contention is caught by the wall-clock timeout
	# in allocate_online().  Pass via -c so git actually reads them (env vars
	# GIT_HTTP_LOW_SPEED_LIMIT/TIME are not recognised by git).
	# GH#20208: redirect stdout to /dev/null (see _cas_build_and_push for details).
	# GH#21904: wrap with `timeout_sec` + SSH fallback to defeat credential-helper
	# hangs that fire BEFORE bytes flow (osxkeychain etc.) and so bypass
	# http.lowSpeedTime.
	if ! _cas_fetch_counter_branch \
		-c http.lowSpeedLimit=1000 -c http.lowSpeedTime="$CAS_GIT_CMD_TIMEOUT_S"; then
		log_warn "Failed to fetch ${REMOTE_NAME}/${COUNTER_BRANCH}"
	fi

	local pinned_sha=""
	pinned_sha=$(_counter_git rev-parse "${REMOTE_NAME}/${COUNTER_BRANCH}" 2>/dev/null) || pinned_sha=""
	# GH#33527: a redirected dedicated branch does not exist until bootstrap.
	if [[ -z "$pinned_sha" && "${_COUNTER_BOOTSTRAP_DEDICATED:-false}" != true ]]; then
		log_warn "Failed to resolve ${REMOTE_NAME}/${COUNTER_BRANCH}"
		return 1
	fi

	local current_value=""
	[[ -z "$pinned_sha" ]] || current_value=$(_counter_show "${pinned_sha}:${COUNTER_FILE}" 2>/dev/null | tr -d '[:space:]')

	if [[ -z "$current_value" ]] || ! [[ "$current_value" =~ ^[0-9]+$ ]]; then
		log_info "Counter missing/invalid — attempting auto-bootstrap (GH#6569)"
		local bootstrap_result
		bootstrap_result=$(bootstrap_remote_counter "$repo_path") || true
		_cas_fetch_counter_branch \
			-c http.lowSpeedLimit=1000 -c http.lowSpeedTime="$CAS_GIT_CMD_TIMEOUT_S" || true
		pinned_sha=$(_counter_git rev-parse "${REMOTE_NAME}/${COUNTER_BRANCH}" 2>/dev/null) || {
			log_error "BOOTSTRAP_COUNTER_FAILED: cannot resolve ref after bootstrap"
			return 1
		}
		current_value=$(_counter_show "${pinned_sha}:${COUNTER_FILE}" 2>/dev/null | tr -d '[:space:]')
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
	blob_sha=$(echo "$new_counter" | _counter_git hash-object -w --stdin 2>/dev/null) || {
		log_warn "Failed to create blob"
		return 1
	}

	local tree_sha
	tree_sha=$(_counter_git ls-tree "${pinned_sha}" | sed "s|[0-9a-f]\{40,64\}	${COUNTER_FILE}$|${blob_sha}	${COUNTER_FILE}|" | _counter_mktree 2>/dev/null) || {
		log_warn "Failed to create tree"
		return 1
	}

	local commit_sha
	commit_sha=$(_counter_git commit-tree "$tree_sha" -p "$pinned_sha" -m "$commit_msg" 2>/dev/null) || {
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
	#
	# GH#21904: wrap remote transport with `timeout_sec` + SSH fallback so an
	# HTTPS credential-helper hang cannot stall the push. GH#29417 runs the hook
	# first with its own budget, then skips Git's duplicate hook invocation.
	local push_rc=0
	local push_stderr=""
	local push_err_file=""
	if ! _cas_run_pre_push_hook "$commit_sha" "$pinned_sha"; then
		# Hook rejection is a setup failure, not counter drift. Preserve the
		# existing non-reconcilable exit contract through allocation callers.
		_task_counter_status "$TASK_COUNTER_SETUP_STATUS" "pre_push_hook_failed"
		return "$CAS_PROTECTED_BRANCH_RC"
	fi
	push_err_file=$(mktemp "${TMPDIR:-/tmp}/claim-task-id-push.XXXXXX" 2>/dev/null) || push_err_file=""
	if [[ -n "$push_err_file" ]]; then
		_run_git_with_ssh_fallback "${CAS_HTTPS_TIMEOUT_S:-30}" \
			-c http.lowSpeedLimit=1000 -c http.lowSpeedTime="$CAS_GIT_CMD_TIMEOUT_S" \
			push --no-verify -q "$REMOTE_NAME" "${commit_sha}:refs/heads/${COUNTER_BRANCH}" >/dev/null 2>"$push_err_file" || push_rc=$?
		push_stderr=$(<"$push_err_file")
		rm -f "$push_err_file" 2>/dev/null || true
	else
		_run_git_with_ssh_fallback "${CAS_HTTPS_TIMEOUT_S:-30}" \
			-c http.lowSpeedLimit=1000 -c http.lowSpeedTime="$CAS_GIT_CMD_TIMEOUT_S" \
			push --no-verify -q "$REMOTE_NAME" "${commit_sha}:refs/heads/${COUNTER_BRANCH}" >/dev/null || push_rc=$?
	fi
	if [[ $push_rc -ne 0 ]]; then
		if _cas_push_rejection_is_protected_branch "$push_stderr"; then
			_cas_log_protected_branch_rejection
			return "$CAS_PROTECTED_BRANCH_RC"
		fi
		if [[ $push_rc -eq 124 ]]; then
			log_error "Push transport/authentication timed out after ${CAS_HTTPS_TIMEOUT_S:-30}s; CAS update was not retried as contention"
			return 1
		fi
		if _cas_push_rejection_is_auth_failure "$push_stderr"; then
			log_error "Push authentication failed; verify credentials for remote ${REMOTE_NAME}"
			return 1
		fi
		if _cas_push_rejection_is_non_fast_forward "$push_stderr"; then
			log_warn "Push failed (conflict — another session claimed an ID)"
			_cas_fetch_counter_branch \
				-c http.lowSpeedLimit=1000 -c http.lowSpeedTime="$CAS_GIT_CMD_TIMEOUT_S" || true
			return 2
		fi
		log_error "Push failed with rc=${push_rc} before the CAS update; failure is not a retriable conflict"
		return 1
	fi

	_cas_fetch_counter_branch \
		-c http.lowSpeedLimit=1000 -c http.lowSpeedTime="$CAS_GIT_CMD_TIMEOUT_S" || true
	return 0
}

# =============================================================================
# Allocation Functions
# =============================================================================

# Validate explicit selections against freshly fetched canonical task state.
# Run on every CAS attempt, using the pinned selected tip even if another
# process updates its remote-tracking ref. Counters store the NEXT free ID.
_cas_validate_explicit_counter_branch() {
	local pinned_sha="$1"
	local current_value="$2"
	local dedicated="${AIDEVOPS_DEDICATED_COUNTER_BRANCH:-task-id-counter}"
	local default_branch="${DEFAULT_BRANCH:-main}"
	local branch="" ref="" value="" todo_seed="0"
	local leading_value="$current_value" leading_branch="$COUNTER_BRANCH"
	local fetch_rc=0 probe_rc=0
	local depth_args=()

	[[ "${_COUNTER_BRANCH_SET:-false}" == true ]] || return 0
	_counter_context_is_isolated && read -r -a depth_args <<<"$(_counter_isolated_fetch_args)"
	for branch in "$default_branch" "$dedicated"; do
		[[ -n "$branch" ]] || continue
		ref="$pinned_sha"
		if [[ "$branch" != "$COUNTER_BRANCH" ]]; then
			fetch_rc=0
			_run_git_with_ssh_fallback "${CAS_HTTPS_TIMEOUT_S:-30}" \
				fetch -q "${depth_args[@]}" --no-tags "$REMOTE_NAME" \
				"+refs/heads/${branch}:refs/remotes/${REMOTE_NAME}/${branch}" >/dev/null || fetch_rc=$?
			if [[ $fetch_rc -ne 0 ]]; then
				probe_rc=0
				_run_git_with_ssh_fallback "${CAS_HTTPS_TIMEOUT_S:-30}" \
					ls-remote --exit-code --heads "$REMOTE_NAME" "refs/heads/${branch}" >/dev/null || probe_rc=$?
				# Only the dedicated branch is optional. Never trust cached refs
				# after an indeterminate fetch or a failed default-branch read.
				if [[ "$branch" != "$default_branch" && $probe_rc -eq 2 ]]; then
					continue
				fi
				log_error "COUNTER_BRANCH_DISCOVERY_ERROR: unable to validate explicit ${COUNTER_BRANCH} against ${REMOTE_NAME}/${branch}"
				_task_counter_status "$TASK_COUNTER_SETUP_STATUS" "explicit_counter_branch_discovery_failed"
				return "$CAS_PROTECTED_BRANCH_RC"
			fi
			ref="${REMOTE_NAME}/${branch}"
		fi
		value=$(_counter_show "${ref}:${COUNTER_FILE}" 2>/dev/null | tr -d '[:space:]' || true)
		if [[ "$branch" == "$dedicated" && "$value" =~ ^[0-9]+$ ]] && ((10#$value > 10#$leading_value)); then
			leading_value="$value"
			leading_branch="$branch"
		fi
		if [[ "$branch" == "$default_branch" ]]; then
			todo_seed=$(_cas_todo_seed_from_ref "$ref")
		fi
	done
	if ((10#$current_value < 10#$leading_value || 10#$current_value < 10#$todo_seed)); then
		log_error "COUNTER_BRANCH_STALE: explicit ${REMOTE_NAME}/${COUNTER_BRANCH} counter=${current_value}, leading branch=${leading_branch} counter=${leading_value}, default TODO seed=${todo_seed}; switch --counter-branch to the leading dedicated branch or use --repair-counter-branch to repair the config first; --sync-counter-branch against a default-branch pin pushes directly to that branch and is refused while stale"
		_task_counter_status "$TASK_COUNTER_SETUP_STATUS" "counter_branch_stale"
		return "$CAS_PROTECTED_BRANCH_RC"
	fi
	return 0
}

# GH#34856: opt-in, idempotent repair of an obsolete local default-branch pin.
# Reuse discovery and explicit freshness validation; neither path allocates IDs.
repair_counter_branch_config() {
	local repo_path="$1"
	local config_file="${repo_path}/.aidevops.json"
	local candidate="" current="" value="" selected=""
	local _COUNTER_BRANCH_SET=false
	local COUNTER_BRANCH="${DEFAULT_BRANCH:-main}"

	command -v python3 >/dev/null 2>&1 || { log_error "Config repair requires python3"; return 1; }
	current=$(jq -er '.counter_branch | select(type == "string")' "$config_file") || return 1
	if [[ "$current" != "$DEFAULT_BRANCH" ]]; then
		log_info "COUNTER_BRANCH_REPAIR_NOOP: config is not pinned to the default branch"
		return 0
	fi
	resolve_implicit_counter_branch "$repo_path" || return $?
	candidate="$COUNTER_BRANCH"
	selected=$(_counter_show "${REMOTE_NAME}/${DEFAULT_BRANCH}:${COUNTER_FILE}" 2>/dev/null | tr -d '[:space:]' || true)
	value=$(_counter_show "${REMOTE_NAME}/${candidate}:${COUNTER_FILE}" 2>/dev/null | tr -d '[:space:]' || true)
	if [[ "$candidate" == "$DEFAULT_BRANCH" || ! "$selected" =~ ^[0-9]+$ || ! "$value" =~ ^[0-9]+$ ]]; then
		log_info "COUNTER_BRANCH_REPAIR_NOOP: no validated leading dedicated counter"
		return 0
	fi
	if ((10#$value <= 10#$selected)); then
		log_info "COUNTER_BRANCH_REPAIR_NOOP: default-branch pin is up to date"
		return 0
	fi
	_COUNTER_BRANCH_SET=true
	_cas_validate_explicit_counter_branch "${REMOTE_NAME}/${candidate}" "$value" || return $?
	# Keep the same inode, mode and owner. Lock and recheck the expected pin before
	# writing, refusing symlinks and concurrent config changes rather than clobbering.
	python3 - "$config_file" "$current" "$candidate" <<'PY' || return 1
import fcntl
import json
import os
import stat
import sys

path, expected, target = sys.argv[1:]
fd = os.open(path, os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK)
with os.fdopen(fd, "r+", encoding="utf-8") as config:
    if not stat.S_ISREG(os.fstat(config.fileno()).st_mode):
        raise SystemExit("Config repair requires a regular file")
    fcntl.flock(config, fcntl.LOCK_EX)
    data = json.load(config)
    if data.get("counter_branch") != expected:
        raise SystemExit("Config changed during repair; retry discovery")
    data["counter_branch"] = target
    updated = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
    config.seek(0)
    config.write(updated)
    config.truncate()
    config.flush()
    os.fsync(config.fileno())
PY
	log_info "COUNTER_BRANCH_CONFIG_REPAIRED: counter_branch ${current} -> ${candidate}; no counter push or allocation"
	return 0
}

# Atomic CAS allocation: fetch → read → increment → commit → push
# Returns 0 on success, 1 on hard error, 2 on retriable conflict, and
# CAS_PROTECTED_BRANCH_RC when repository policy rejects direct pushes.
allocate_counter_cas() {
	local repo_path="$1"
	local count="$2"

	# Step 1: Fetch + pin (atomic snapshot of counter + parent SHA)
	local pin_result
	pin_result=$(_cas_fetch_and_pin "$repo_path") || return 1
	local pinned_sha current_value
	pinned_sha="${pin_result%% *}"
	current_value="${pin_result##* }"

	_cas_validate_explicit_counter_branch "$pinned_sha" "$current_value" || return $?

	local todo_seed remote_seed
	todo_seed=$(_compute_counter_seed "$repo_path")
	remote_seed=$(_cas_todo_seed_from_remote_refs "${DEFAULT_BRANCH:-main}")
	((10#$remote_seed > 10#$todo_seed)) && todo_seed="$remote_seed"
	((10#$todo_seed > 10#$current_value)) && current_value="$todo_seed"
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
		commit_msg="chore: claim $(_format_legacy_task_id "$first_id") [${nonce}]"
	else
		commit_msg="chore: claim $(_format_task_range "$first_id" "$last_id") [${nonce}]"
	fi

	# Step 2+3: Build commit on pinned_sha and push (atomic gate)
	_cas_build_and_push "$pinned_sha" "$new_counter" "$commit_msg" || return $?

	# Success — output the claimed IDs
	echo "$first_id"
	return 0
}

# Refresh the caller repository's remote-tracking ref for the counter branch
# after a successful CAS. The CAS runs in an isolated Git context, so its push
# leaves the caller's refs/remotes/<remote>/<counter-branch> stale and the
# task-id commit-msg guard then misses the fresh claim. Best-effort and bounded:
# failure never changes the claim result.
# Args: $1 — caller repo_path
_cas_refresh_caller_tracking_ref() {
	local repo_path="$1"
	[[ -n "$repo_path" && -d "$repo_path" ]] || return 0
	local refspec="+refs/heads/${COUNTER_BRANCH}:refs/remotes/${REMOTE_NAME}/${COUNTER_BRANCH}"
	if timeout_sec "${CAS_HTTPS_TIMEOUT_S:-30}" git -C "$repo_path" \
		-c http.lowSpeedLimit=1000 -c http.lowSpeedTime="${CAS_GIT_CMD_TIMEOUT_S:-10}" \
		fetch --quiet "$REMOTE_NAME" "$refspec" >/dev/null 2>&1; then
		log_info "Refreshed ${REMOTE_NAME}/${COUNTER_BRANCH} in caller repo"
	else
		log_info "Could not refresh ${REMOTE_NAME}/${COUNTER_BRANCH} in caller repo (non-fatal)"
	fi
	return 0
}

# Online allocation with CAS retry loop.
# GH#20137: enforces a wall-clock timeout (CAS_WALL_TIMEOUT_S, default 30s)
# in addition to the retry count.  Under concurrent-worker contention, each
# git fetch/push can take several seconds due to index.lock waits; without
# a wall-clock cap the loop could run for 180s+ (30 retries × 6s each).
# The backoff is capped at 2.0s to keep retries tight within the budget.
#
# Phase 2 (t2568 / GH#20001): machine-local mutex wraps the retry loop to
# serialise concurrent agents on the same host.  Lock acquisition failure is
# non-fatal — the git push remains the authoritative CAS gate.
allocate_online() {
	local repo_path="$1"
	local count="$2"
	local attempt=0
	local first_id=""
	local start_epoch
	start_epoch=$(date +%s)

	# Phase 2 (t2568 / GH#20001): machine-local mutex.
	# Acquire before entering the retry loop so local runners serialise at the
	# fetch→read→build→push boundary.  Fail-open: if lock times out, log a
	# warning and proceed unlocked — the git push is still the CAS authority.
	local _have_local_lock=0
	if _cas_acquire_local_lock; then
		_have_local_lock=1
	else
		log_warn "Could not acquire local CAS mutex within ${CAS_LOCAL_LOCK_TIMEOUT_S}s — proceeding unlocked (git push remains authoritative)"
	fi

	# shellcheck disable=SC2064  # intentional: flag captured at definition time
	trap "[[ \${_have_local_lock:-0} -eq 1 ]] && _cas_release_local_lock; trap - RETURN" RETURN

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
			log_success "Claimed $(_format_legacy_task_id "$first_id") (attempt ${attempt}, ${elapsed}s)"
			_cas_refresh_caller_tracking_ref "$repo_path"
			# Phase 3 (t2569 / GH#20001): structured audit log.
			_append_claim_audit_log "$first_id" "$attempt" "$elapsed"
			_task_coordinator_shadow_legacy "$first_id" "$count"
			echo "$first_id"
			return 0
			;;
		2)
			# Retriable conflict — loop continues
			continue
			;;
		"$CAS_PROTECTED_BRANCH_RC")
			# Policy rejection — preserve the distinct setup-error result so
			# higher layers do not run contention reconciliation and retry.
			return "$CAS_PROTECTED_BRANCH_RC"
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
#   CAS_PROTECTED_BRANCH_RC — direct counter pushes are forbidden by policy
_allocate_online_with_collision_check() {
	local repo_path="$1"
	local count="$2"
	local max_skips=100
	local total_skips=0

	while true; do
		local first_id=""
		local allocation_rc=0
		first_id=$(allocate_online "$repo_path" "$count") || allocation_rc=$?
		if [[ $allocation_rc -ne 0 ]]; then
			return "$allocation_rc"
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

		# Also check GitHub PR/issue title prefixes (GH#39657): headless workers
		# title PRs "t<issue-number>: ..." so a counter value can already be
		# in use as a prefix even though TODO.md has no entry for it.
		if [[ -z "$collision_id" ]]; then
			for ((i = 0; i < count; i++)); do
				local check_id=$((first_id + i))
				if _id_used_as_title_prefix "$check_id" "$repo_path"; then
					collision_id="$check_id"
					break
				fi
			done
		fi

		if [[ -z "$collision_id" ]]; then
			echo "$first_id"
			return 0
		fi

		total_skips=$((total_skips + 1))
		log_info "Task ID collision: $(_format_legacy_task_id "$collision_id") already in use (TODO.md or PR/issue title prefix) — skipping (${total_skips}/${max_skips})"

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

	local todo_seed
	todo_seed=$(_compute_counter_seed "$repo_path")
	((10#$todo_seed > 10#$current_value)) && current_value="$todo_seed"
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

	log_warn "Allocated $(_format_legacy_task_id "$first_id") with offset (reconcile when back online)"

	echo "$first_id"
	return 0
}
