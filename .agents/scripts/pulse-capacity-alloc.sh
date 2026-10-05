#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-capacity-alloc.sh — Per-priority worker allocation — peak-hours cap, max-worker arithmetic, priority allocation table, debt worker counting, per-repo cap, hygiene + PR salvage helpers.
#
# Extracted from pulse-wrapper.sh in Phase 3 of the phased decomposition
# (parent: GH#18356, plan: todo/plans/pulse-wrapper-decomposition.md §6).
#
# This module is sourced by pulse-wrapper.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all PULSE_* configuration constants and mutable
# _PULSE_HEALTH_* counters in the bootstrap section.
#
# Functions in this module (in source order):
#   - _append_priority_allocations
#   - _check_repo_hygiene
#   - _scan_pr_salvage
#   - apply_peak_hours_cap
#   - calculate_max_workers
#   - calculate_priority_allocations
#   - count_debt_workers
#   - check_repo_worker_cap
#   - dispatch class cap helpers (GH#33137, appended after the pure move):
#     _dispatch_class_from_labels, _dispatch_class_config, _dispatch_class_cap_value,
#     _dispatch_class_state_dir, _dispatch_class_active_count,
#     _dispatch_check_class_cap, _dispatch_class_release_reservation
#
# This is a pure move from pulse-wrapper.sh. The function bodies are
# byte-identical to their pre-extraction form. Any change must go in a
# separate follow-up PR after the full decomposition (Phase 12) lands.

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_CAPACITY_ALLOC_LOADED:-}" ]] && return 0
_PULSE_CAPACITY_ALLOC_LOADED=1

#######################################
# Append priority-class worker allocations to state file (t1423)
#
# Reads the allocation file written by calculate_priority_allocations()
# and formats it as a section the pulse agent can act on.
#
# The pulse agent uses this to enforce soft reservations: product repos
# get a guaranteed minimum share of worker slots, tooling gets the rest.
# When one class has no pending work, the other can use freed slots.
#
# Output: allocation summary to stdout (appended to STATE_FILE by caller)
#######################################
_append_priority_allocations() {
	local alloc_file="${HOME}/.aidevops/logs/pulse-priority-allocations"

	echo ""
	echo "# Priority-Class Worker Allocations (t1423)"
	echo ""

	if [[ ! -f "$alloc_file" ]]; then
		echo "- Allocation data not available — using flat pool (no reservations)"
		echo ""
		return 0
	fi

	# Read allocation values
	local max_workers="" product_repos="" tooling_repos="" dispatchable_product_repos="" product_min="" tooling_max="" reservation_pct="" quality_debt_cap_pct=""
	max_workers=$(grep '^MAX_WORKERS=' "$alloc_file" | cut -d= -f2) || max_workers=4
	product_repos=$(grep '^PRODUCT_REPOS=' "$alloc_file" | cut -d= -f2) || product_repos=0
	tooling_repos=$(grep '^TOOLING_REPOS=' "$alloc_file" | cut -d= -f2) || tooling_repos=0
	dispatchable_product_repos=$(grep '^DISPATCHABLE_PRODUCT_REPOS=' "$alloc_file" | cut -d= -f2) || dispatchable_product_repos="$product_repos"
	product_min=$(grep '^PRODUCT_MIN=' "$alloc_file" | cut -d= -f2) || product_min=0
	tooling_max=$(grep '^TOOLING_MAX=' "$alloc_file" | cut -d= -f2) || tooling_max=0
	reservation_pct=$(grep '^PRODUCT_RESERVATION_PCT=' "$alloc_file" | cut -d= -f2) || reservation_pct=60
	quality_debt_cap_pct=$(grep '^QUALITY_DEBT_CAP_PCT=' "$alloc_file" | cut -d= -f2) || quality_debt_cap_pct=30

	echo "Worker pool: **${max_workers}** total slots"
	echo "Product repos (${product_repos}, dispatchable now: ${dispatchable_product_repos}): **${product_min}** reserved slots (${reservation_pct}% target minimum)"
	echo "Tooling repos (${tooling_repos}): **${tooling_max}** slots (remainder)"
	echo "Quality-debt cap: **${quality_debt_cap_pct}%** of worker pool"
	echo ""
	echo "**Enforcement rules:**"
	echo "- Reservations are soft targets, not hard gates. If one class has no dispatchable candidates, immediately reassign its unused slots to the other class."
	echo "- Product repos at daily PR cap are treated as temporarily non-dispatchable for reservation purposes."
	echo "- Do not leave slots idle when runnable scoped work exists in any class."
	echo "- If all ${max_workers} slots are needed for product work, tooling gets 0 (product reservation is a minimum, not a maximum)."
	echo "- Merges (priority 1) and CI fixes (priority 2) are exempt — they always proceed regardless of class."
	echo ""

	return 0
}

#######################################
# Pre-fetch repo hygiene data for LLM triage (t1417)
#
# Appends a "Repo Hygiene" section to the state file with:
#   1. Orphan worktrees — branches with 0 commits ahead of main,
#      no PR (open or merged), and no active worker process.
#   2. Stash summary — count of needs-review stashes per repo.
#   3. Uncommitted changes on main — repos with dirty main worktree.
#
# This data enables the pulse LLM to make intelligent triage decisions
# about cleanup. Deterministic cleanup (merged-PR worktrees, safe stashes)
# is handled by cleanup_worktrees() and cleanup_stashes() before this runs.
# What remains here requires judgment.
#
# Output: hygiene summary to stdout (appended to STATE_FILE by caller)
#######################################
#######################################
# Check a single repo for hygiene issues (GH#5627, extracted from prefetch_hygiene)
#
# Checks for orphan worktrees, stale stashes, and uncommitted changes
# on the default branch. Returns issue descriptions via stdout.
#
# Arguments:
#   $1 - repo_path
#   $2 - repos_json path (for slug lookup)
# Output: issue lines to stdout (empty if no issues)
#######################################
_check_repo_hygiene() {
	local repo_path="$1"
	local repos_json="$2"
	local repo_issues=""

	# 1. Orphan worktrees: 0 commits ahead of default branch, no PR
	local default_branch
	default_branch=$(git -C "$repo_path" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||') || default_branch="main"
	[[ -z "$default_branch" ]] && default_branch="main"

	local wt_branch="" wt_path=""
	while IFS= read -r line; do
		if [[ "$line" =~ ^worktree\ (.+)$ ]]; then
			wt_path="${BASH_REMATCH[1]}"
		elif [[ "$line" =~ ^branch\ refs/heads/(.+)$ ]]; then
			wt_branch="${BASH_REMATCH[1]}"
		elif [[ -z "$line" && -n "$wt_branch" ]]; then
			# Skip the default branch
			if [[ "$wt_branch" != "$default_branch" ]]; then
				local commits_ahead
				commits_ahead=$(git -C "$repo_path" rev-list --count "${default_branch}..${wt_branch}" 2>/dev/null) || commits_ahead="?"

				if [[ "$commits_ahead" == "0" ]]; then
					# Check if any PR exists (open or merged)
					local has_pr="false"
					if command -v gh &>/dev/null; then
						local pr_check
						# Use first() to guard against duplicate entries in initialized_repos for the same path.
					pr_check=$(gh_pr_list --repo "$(jq -r --arg p "$repo_path" 'first(.initialized_repos[] | select(.path == $p) | .slug)' "$repos_json" 2>/dev/null)" \
						--head "$wt_branch" --state all --json number --jq 'length' 2>/dev/null) || pr_check="0"
						[[ "${pr_check:-0}" -gt 0 ]] && has_pr="true"
					fi

					if [[ "$has_pr" == "false" ]]; then
						# Check for dirty state
						local dirty=""
						local change_count
						change_count=$(git -C "${wt_path:-$repo_path}" status --porcelain 2>/dev/null | wc -l | tr -d ' ') || change_count=0
						[[ "${change_count:-0}" -gt 0 ]] && dirty=" (${change_count} uncommitted files)"

						repo_issues="${repo_issues}  - Orphan worktree: \`${wt_branch}\` — 0 commits, no PR${dirty} (${wt_path})\n"
					fi
				fi
			fi
			wt_path=""
			wt_branch=""
		fi
	done < <(
		git -C "$repo_path" worktree list --porcelain 2>/dev/null
		echo ""
	)

	# 2. Stash summary (needs-review count)
	local stash_count
	stash_count=$(git -C "$repo_path" stash list 2>/dev/null | wc -l | tr -d ' ')
	if [[ "${stash_count:-0}" -gt 0 ]]; then
		repo_issues="${repo_issues}  - ${stash_count} stash(es) remaining (safe-to-drop already cleaned; these need review)\n"
	fi

	# 3. Uncommitted changes on main worktree
	local main_wt_path="$repo_path"
	local current_branch
	current_branch=$(git -C "$main_wt_path" rev-parse --abbrev-ref HEAD 2>/dev/null) || current_branch=""
	if [[ "$current_branch" == "$default_branch" ]]; then
		local main_dirty
		main_dirty=$(git -C "$main_wt_path" status --porcelain 2>/dev/null | wc -l | tr -d ' ') || main_dirty=0
		if [[ "${main_dirty:-0}" -gt 0 ]]; then
			repo_issues="${repo_issues}  - ${main_dirty} uncommitted file(s) on ${default_branch} branch\n"
		fi
	fi

	echo -n "$repo_issues"
	return 0
}

#######################################
# Scan for salvageable closed-unmerged PRs (GH#5627, extracted from prefetch_hygiene)
#
# Arguments:
#   $1 - repos_json path
# Output: salvage summary to stdout
#######################################
_scan_pr_salvage() {
	local repos_json="$1"
	local salvage_helper="${SCRIPT_DIR}/pr-salvage-helper.sh"

	if [[ ! -x "$salvage_helper" ]]; then
		return 0
	fi

	echo ""
	echo "# PR Salvage (closed-unmerged with recoverable code)"
	echo ""

	local salvage_found=false
	local slug="" path=""
	while IFS='|' read -r slug path; do
		[[ -z "$slug" ]] && continue
		local salvage_output
		salvage_output=$("$salvage_helper" prefetch "$slug" "$path" 2>/dev/null) || true
		if [[ -n "$salvage_output" ]]; then
			salvage_found=true
			echo "$salvage_output"
		fi
	done < <(jq -r '.initialized_repos[] | select(.maintenance != false and .pulse == true and (.local_only // false) == false and .slug != "") | "\(.slug)|\(.path)"' "$repos_json" 2>/dev/null)

	if [[ "$salvage_found" == "false" ]]; then
		echo "- No salvageable closed-unmerged PRs detected"
		echo ""
	fi

	return 0
}

#######################################
# Deprecated compatibility entrypoint (t1677, retired by GH#31309).
# The global clock-based cap came from Anthropic peak-window assumptions;
# it must not constrain OpenAI or other providers. Actual provider availability,
# rate limits and resource gates remain authoritative. Legacy settings are inert.
#
# Arguments:
#   $1 - current off-peak max_workers value (integer >= 1)
#
# Output: validated, otherwise unchanged max_workers value to stdout
# Returns: 0 always
#######################################
apply_peak_hours_cap() {
	local off_peak_max="$1"

	# Validate input
	[[ "$off_peak_max" =~ ^[0-9]+$ ]] || off_peak_max=1
	[[ "$off_peak_max" -lt 1 ]] && off_peak_max=1
	echo "$off_peak_max"
	return 0
}

#######################################
# Calculate max workers from available RAM and CPU admission pressure
#
# Formula: (free_ram - RAM_RESERVE_MB) / RAM_PER_WORKER_MB
# RAM bound clamped to [1, MAX_WORKERS_CAP]; CPU pressure may close admission (0)
#
# Writes MAX_WORKERS to a file that pulse.md reads via bash.
#######################################
calculate_max_workers() {
	local free_mb
	if [[ "$(uname)" == "Darwin" ]]; then
		# macOS: use vm_stat for free + inactive (reclaimable) pages
		# Reclaimable = free + inactive + speculative + purgeable pages. The
		# speculative/purgeable pools are file cache the kernel drops on demand;
		# omitting them under-reported headroom on busy Macs.
		local page_size="" vm_out="" reclaimable_pages=""
		page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo 16384)
		vm_out=$(vm_stat 2>/dev/null) || vm_out=""
		reclaimable_pages=$(printf '%s\n' "$vm_out" | awk '
			/^Pages (free|inactive|speculative|purgeable):/ { gsub(/\./, "", $NF); sum += $NF }
			END { printf "%d", sum }')
		# Validate integers before arithmetic expansion
		[[ "$page_size" =~ ^[0-9]+$ ]] || page_size=16384
		[[ "$reclaimable_pages" =~ ^[0-9]+$ ]] || reclaimable_pages=0
		free_mb=$((reclaimable_pages * page_size / 1024 / 1024))
	else
		# Linux: use MemAvailable from /proc/meminfo
		free_mb=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 8192)
	fi
	[[ "$free_mb" =~ ^[0-9]+$ ]] || free_mb=8192

	local available_mb=$((free_mb - RAM_RESERVE_MB))
	local max_workers=$((available_mb / RAM_PER_WORKER_MB))

	# Clamp to [1, MAX_WORKERS_CAP]
	if [[ "$max_workers" -lt 1 ]]; then
		max_workers=1
	elif [[ "$max_workers" -gt "$MAX_WORKERS_CAP" ]]; then
		max_workers="$MAX_WORKERS_CAP"
	fi

	local cpu_load="" cpu_cores="" cpu_gate="" cpu_threshold=""
	read -r cpu_load cpu_cores cpu_gate cpu_threshold <<<"$(_pulse_cpu_pressure)"
	if [[ "$cpu_gate" == "closed" ]]; then
		max_workers=0
	fi

	# Write to a file that pulse.md can read
	local max_workers_file="${HOME}/.aidevops/logs/pulse-max-workers"
	echo "$max_workers" >"$max_workers_file"

	echo "[pulse-wrapper] Available RAM: ${free_mb}MB, reserve: ${RAM_RESERVE_MB}MB, max workers: ${max_workers}, load=${cpu_load}/${cpu_cores} max_load_per_core=${cpu_threshold} cpu_gate=${cpu_gate}" >>"$LOGFILE"
	return 0
}

#######################################
# Count pulse-enabled repos by priority class (t2006)
#
# Single jq pass over repos.json to count product vs tooling repos.
# Prints: "<product_count> <tooling_count>" to stdout.
#
# Arguments:
#   $1 - path to repos.json
#######################################
_count_priority_repos() {
	local repos_json="$1"
	local product_repos=0 tooling_repos=0

	read -r product_repos tooling_repos < <(jq -r '
		.initialized_repos |
		map(select(.maintenance != false and .pulse == true and (.local_only // false) == false and .slug != "")) |
		[
			(map(select(.priority == "product")) | length),
			(map(select(.priority == "tooling")) | length)
		] | @tsv
	' "$repos_json" 2>/dev/null) || true
	product_repos=${product_repos:-0}
	tooling_repos=${tooling_repos:-0}
	[[ "$product_repos" =~ ^[0-9]+$ ]] || product_repos=0
	[[ "$tooling_repos" =~ ^[0-9]+$ ]] || tooling_repos=0

	echo "$product_repos $tooling_repos"
	return 0
}

#######################################
# GH#33647: the daily count lists at most this many PRs, so it can never
# observe a DAILY_PR_CAP above it (the default cap is 1000).
#######################################
_PULSE_DAILY_PR_LIST_LIMIT=200

#######################################
# Print "<count>\t<epoch>" for a cached same-day PR count.
# Arguments: $1=cache file $2=UTC date $3=repo slug
# Returns: 0 when found, 1 otherwise
#######################################
_daily_pr_count_cache_lookup() {
	local cache_file="$1" today="$2" slug="$3"
	[[ -f "$cache_file" && ! -L "$cache_file" ]] || return 1
	awk -F'\t' -v d="$today" -v s="$slug" '
		$1 == d && $2 == s { print $3 "\t" $4; found = 1; exit }
		END { exit (found ? 0 : 1) }
	' "$cache_file" 2>/dev/null || return 1
	return 0
}

#######################################
# Fetch one repository's count of PRs created today (one REST listing).
# Arguments: $1=repo slug $2=UTC date
#######################################
_daily_pr_count_fetch() {
	local slug="$1" today_utc="$2"
	local pr_json="" daily_pr_count="" pr_alloc_err=""
	# GH#4412: use --state all to count merged/closed PRs too
	pr_alloc_err=$(mktemp)
	pr_json=$(pulse_pr_list_get --repo "$slug" --state all --json createdAt --limit "$_PULSE_DAILY_PR_LIST_LIMIT" 2>"$pr_alloc_err") || pr_json="[]"
	if [[ -z "$pr_json" ]]; then
		local _pr_alloc_err_msg
		_pr_alloc_err_msg=$(cat "$pr_alloc_err" 2>/dev/null || echo "unknown error")
		echo "[pulse-wrapper] calculate_priority_allocations: gh_pr_list FAILED for ${slug}: ${_pr_alloc_err_msg}" >>"$LOGFILE"
		pr_json="[]"
	fi
	rm -f "$pr_alloc_err"
	daily_pr_count=$(echo "$pr_json" | jq --arg today "$today_utc" '[.[] | select((.createdAt // "") | startswith($today))] | length' 2>/dev/null) || daily_pr_count=0
	[[ "$daily_pr_count" =~ ^[0-9]+$ ]] || daily_pr_count=0
	echo "$daily_pr_count"
	return 0
}

#######################################
# Count product repos that can dispatch (not blocked by daily PR cap) (t2006)
#
# Iterates product repos from repos.json, checks each against DAILY_PR_CAP.
# GH#33647: the cap is a soft, advisory limit, so this must never consume the
# dispatch reserve. It skips listing when the cap is unobservable, reuses
# same-day counts (capped repos stay capped until UTC midnight; others refresh
# after PULSE_DAILY_PR_COUNT_TTL_SECONDS), and treats repos left unchecked
# after PULSE_DAILY_PR_COUNT_BUDGET_SECONDS as dispatchable.
# Prints: "<dispatchable_count>" to stdout.
#
# Arguments:
#   $1 - path to repos.json
#   $2 - total product repo count
#######################################
_count_dispatchable_product_repos() {
	local repos_json="$1"
	local product_repos="$2"
	local dispatchable=0 unchecked=0 fetched=0 started_epoch=0 now_epoch=0
	local budget="${PULSE_DAILY_PR_COUNT_BUDGET_SECONDS:-60}" ttl="${PULSE_DAILY_PR_COUNT_TTL_SECONDS:-900}"
	local cache_file="${HOME}/.aidevops/cache/pulse-daily-pr-counts" new_cache="" today_utc
	[[ "$budget" =~ ^[0-9]+$ ]] || budget=60
	[[ "$ttl" =~ ^[0-9]+$ ]] || ttl=900
	today_utc=$(date -u +%Y-%m-%d)

	if [[ "$product_repos" -le 0 || "$DAILY_PR_CAP" -le 0 || "$DAILY_PR_CAP" -gt "$_PULSE_DAILY_PR_LIST_LIMIT" ]]; then
		echo "$product_repos"
		return 0
	fi

	mkdir -p "${cache_file%/*}" 2>/dev/null || true
	new_cache=$(mktemp "${cache_file}.XXXXXX" 2>/dev/null) || new_cache=""
	started_epoch=$(date +%s)
	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue
		local cached="" daily_pr_count="" cached_epoch=0
		now_epoch=$(date +%s)
		if cached=$(_daily_pr_count_cache_lookup "$cache_file" "$today_utc" "$slug"); then
			daily_pr_count="${cached%%$'\t'*}"
			cached_epoch="${cached##*$'\t'}"
			[[ "$daily_pr_count" =~ ^[0-9]+$ && "$cached_epoch" =~ ^[0-9]+$ ]] || daily_pr_count=""
		fi
		if [[ -z "$daily_pr_count" ]] || { [[ "$daily_pr_count" -lt "$DAILY_PR_CAP" ]] && ((now_epoch - cached_epoch >= ttl)); }; then
			if ((now_epoch - started_epoch < budget)); then
				daily_pr_count=$(_daily_pr_count_fetch "$slug" "$today_utc")
				cached_epoch="$now_epoch"
				fetched=$((fetched + 1))
			elif [[ -z "$daily_pr_count" ]]; then
				unchecked=$((unchecked + 1))
			fi
		fi
		if [[ -n "$daily_pr_count" && -n "$new_cache" ]]; then
			printf '%s\t%s\t%s\t%s\n' "$today_utc" "$slug" "$daily_pr_count" "$cached_epoch" >>"$new_cache"
		fi
		if [[ -z "$daily_pr_count" || "$daily_pr_count" -lt "$DAILY_PR_CAP" ]]; then
			dispatchable=$((dispatchable + 1))
		fi
	done < <(jq -r '.initialized_repos[] | select(.maintenance != false and .pulse == true and (.local_only // false) == false and .slug != "" and .priority == "product") | .slug' "$repos_json" 2>/dev/null)
	if [[ -n "$new_cache" ]]; then
		mv -f "$new_cache" "$cache_file" 2>/dev/null || rm -f "$new_cache"
	fi
	if [[ "$unchecked" -gt 0 ]]; then
		echo "[pulse-wrapper] calculate_priority_allocations: daily PR count budget ${budget}s exhausted; ${unchecked} repo(s) treated as dispatchable (fetched=${fetched}) (GH#33647)" >>"$LOGFILE"
	fi
	[[ "$dispatchable" =~ ^[0-9]+$ ]] || dispatchable="$product_repos"

	echo "$dispatchable"
	return 0
}

#######################################
# Compute product_min and tooling_max slot reservations (t2006)
#
# Applies PRODUCT_RESERVATION_PCT with ceiling division and edge-case
# guards (no product repos, no tooling repos, single-slot minimum).
# Prints: "<product_min> <tooling_max>" to stdout.
#
# Arguments:
#   $1 - max_workers (total capacity)
#   $2 - dispatchable_product_repos count
#   $3 - tooling_repos count
#######################################
_compute_slot_reservations() {
	local max_workers="$1"
	local dispatchable_product_repos="$2"
	local tooling_repos="$3"
	local product_min=0 tooling_max=0

	if [[ "$dispatchable_product_repos" -eq 0 ]]; then
		# No product repos — all slots available for tooling
		product_min=0
		tooling_max="$max_workers"
	elif [[ "$tooling_repos" -eq 0 ]]; then
		# No tooling repos — all slots available for product
		product_min="$max_workers"
		tooling_max=0
	else
		# product_min = ceil(max_workers * PRODUCT_RESERVATION_PCT / 100)
		# Using integer arithmetic: ceil(a/b) = (a + b - 1) / b
		product_min=$(((max_workers * PRODUCT_RESERVATION_PCT + 99) / 100))
		# Ensure product_min doesn't exceed max_workers
		if [[ "$product_min" -gt "$max_workers" ]]; then
			product_min="$max_workers"
		fi
		# Ensure at least 1 slot for tooling when tooling repos exist
		# but only when there are multiple slots to distribute (with 1 slot,
		# product keeps it — the reservation is a minimum guarantee)
		if [[ "$max_workers" -gt 1 && "$product_min" -ge "$max_workers" && "$tooling_repos" -gt 0 ]]; then
			product_min=$((max_workers - 1))
		fi
		tooling_max=$((max_workers - product_min))
	fi

	echo "$product_min $tooling_max"
	return 0
}

#######################################
# Write priority allocation file (key=value format) (t2006)
#
# Arguments: $1=alloc_file $2=max_workers $3=product_repos $4=tooling_repos
#            $5=dispatchable_product_repos $6=product_min $7=tooling_max
#######################################
_write_priority_alloc_file() {
	local alloc_file="$1" max_workers="$2" product_repos="$3" tooling_repos="$4"
	local dispatchable_product_repos="$5" product_min="$6" tooling_max="$7"
	{
		echo "MAX_WORKERS=${max_workers}"
		echo "PRODUCT_REPOS=${product_repos}"
		echo "TOOLING_REPOS=${tooling_repos}"
		echo "DISPATCHABLE_PRODUCT_REPOS=${dispatchable_product_repos}"
		echo "PRODUCT_MIN=${product_min}"
		echo "TOOLING_MAX=${tooling_max}"
		echo "PRODUCT_RESERVATION_PCT=${PRODUCT_RESERVATION_PCT}"
		echo "QUALITY_DEBT_CAP_PCT=${QUALITY_DEBT_CAP_PCT}"
	} >"$alloc_file"
	return 0
}

#######################################
# Calculate priority-class worker allocations (t1423, refactored t2006)
#
# Coordinator: reads repos.json counts, computes slot reservations,
# writes allocation file. Delegates to per-concern helpers.
#
# Depends on: calculate_max_workers() having run first (reads pulse-max-workers)
#######################################
calculate_priority_allocations() {
	local repos_json="${REPOS_JSON}"
	local alloc_file="${HOME}/.aidevops/logs/pulse-priority-allocations"
	if [[ ! -f "$repos_json" ]] || ! command -v jq &>/dev/null; then
		echo "[pulse-wrapper] repos.json or jq not available — skipping priority allocations" >>"$LOGFILE"
		return 0
	fi
	local max_workers
	max_workers=$(cat "${HOME}/.aidevops/logs/pulse-max-workers" 2>/dev/null || echo 4)
	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=4

	local product_repos=0 tooling_repos=0
	read -r product_repos tooling_repos < <(_count_priority_repos "$repos_json")
	local dispatchable_product_repos
	dispatchable_product_repos=$(_count_dispatchable_product_repos "$repos_json" "$product_repos")
	if [[ "$dispatchable_product_repos" -lt "$product_repos" ]]; then
		echo "[pulse-wrapper] Product dispatchability reduced by daily PR caps: ${dispatchable_product_repos}/${product_repos} repos can accept new workers" >>"$LOGFILE"
	fi

	local product_min=0 tooling_max=0
	read -r product_min tooling_max < <(_compute_slot_reservations "$max_workers" "$dispatchable_product_repos" "$tooling_repos")
	_write_priority_alloc_file "$alloc_file" "$max_workers" "$product_repos" "$tooling_repos" "$dispatchable_product_repos" "$product_min" "$tooling_max"

	echo "[pulse-wrapper] Priority allocations: product_min=${product_min}, tooling_max=${tooling_max} (${product_repos} product, ${tooling_repos} tooling repos, ${max_workers} total slots)" >>"$LOGFILE"
	return 0
}

#######################################
# Count active debt workers for a repo (quality-debt + file-size-debt + function-complexity-debt)
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - debt type: "quality-debt", "file-size-debt", "function-complexity-debt", or "all" (default: all)
#
# Outputs two lines: active_count queued_count
# Exit code: always 0
#######################################
count_debt_workers() {
	local repo_slug="$1"
	local debt_type="${2:-all}"
	local active=0
	local queued=0

	case "$debt_type" in
	quality-debt)
		active=$(gh_issue_list --repo "$repo_slug" --label "quality-debt" --label "status:in-progress" --state open --json number --jq 'length' 2>/dev/null || echo 0)
		queued=$(gh_issue_list --repo "$repo_slug" --label "quality-debt" --label "status:queued" --state open --json number --jq 'length' 2>/dev/null || echo 0)
		;;
	file-size-debt)
		active=$(gh_issue_list --repo "$repo_slug" --label "file-size-debt" --label "status:in-progress" --state open --json number --jq 'length' 2>/dev/null || echo 0)
		queued=$(gh_issue_list --repo "$repo_slug" --label "file-size-debt" --label "status:queued" --state open --json number --jq 'length' 2>/dev/null || echo 0)
		;;
	function-complexity-debt)
		active=$(gh_issue_list --repo "$repo_slug" --label "function-complexity-debt" --label "status:in-progress" --state open --json number --jq 'length' 2>/dev/null || echo 0)
		queued=$(gh_issue_list --repo "$repo_slug" --label "function-complexity-debt" --label "status:queued" --state open --json number --jq 'length' 2>/dev/null || echo 0)
		;;
	all)
		local qa_active="" qa_queued="" fsd_active="" fsd_queued="" fcd_active="" fcd_queued=""
		qa_active=$(gh_issue_list --repo "$repo_slug" --label "quality-debt" --label "status:in-progress" --state open --json number --jq 'length' 2>/dev/null || echo 0)
		qa_queued=$(gh_issue_list --repo "$repo_slug" --label "quality-debt" --label "status:queued" --state open --json number --jq 'length' 2>/dev/null || echo 0)
		fsd_active=$(gh_issue_list --repo "$repo_slug" --label "file-size-debt" --label "status:in-progress" --state open --json number --jq 'length' 2>/dev/null || echo 0)
		fsd_queued=$(gh_issue_list --repo "$repo_slug" --label "file-size-debt" --label "status:queued" --state open --json number --jq 'length' 2>/dev/null || echo 0)
		fcd_active=$(gh_issue_list --repo "$repo_slug" --label "function-complexity-debt" --label "status:in-progress" --state open --json number --jq 'length' 2>/dev/null || echo 0)
		fcd_queued=$(gh_issue_list --repo "$repo_slug" --label "function-complexity-debt" --label "status:queued" --state open --json number --jq 'length' 2>/dev/null || echo 0)
		active=$((qa_active + fsd_active + fcd_active))
		queued=$((qa_queued + fsd_queued + fcd_queued))
		;;
	esac

	[[ "$active" =~ ^[0-9]+$ ]] || active=0
	[[ "$queued" =~ ^[0-9]+$ ]] || queued=0
	echo "$active"
	echo "$queued"
	return 0
}

#######################################
# Check per-repo worker cap before dispatch
#
# Arguments:
#   $1 - repo path (canonical path on disk)
#   $2 - max workers per repo (default: MAX_WORKERS_PER_REPO or 5)
#   $3 - (optional) pre-fetched output of list_active_worker_processes
#         Pass this when calling inside a loop to avoid repeated ps invocations.
#         Omit (or pass empty) to fetch fresh process data.
#
# Exit codes:
#   0 - at or above cap (skip dispatch for this repo)
#   1 - below cap (safe to dispatch)
#######################################
check_repo_worker_cap() {
	local repo_path="$1"
	local cap="${2:-${MAX_WORKERS_PER_REPO:-5}}"
	local cached_worker_procs="${3:-}"
	local active_for_repo
	local worker_procs

	# Use caller-supplied cache when available to avoid repeated ps calls in loops.
	if [[ -n "$cached_worker_procs" ]]; then
		worker_procs="$cached_worker_procs"
	else
		worker_procs=$(list_active_worker_processes)
	fi

	active_for_repo=$(printf '%s\n' "$worker_procs" | awk -v path="$repo_path" '
		BEGIN { esc=path; gsub(/[][(){}.^$*+?|\\]/, "\\\\&", esc) }
		$0 ~ ("--dir[[:space:]]+" esc "([[:space:]]|$)") { count++ }
		END { print count + 0 }
	')
	[[ "$active_for_repo" =~ ^[0-9]+$ ]] || active_for_repo=0

	if [[ "$active_for_repo" -ge "$cap" ]]; then
		return 0
	fi
	return 1
}

# =============================================================================
# GH#33137: per-class dispatch cap
# =============================================================================
#
# Issues labelled `dispatch-class:<name>` may be limited to a share of this
# machine's simultaneous worker target. Configuration lives on the repo entry
# in repos.json (preferred) or in the repo's .aidevops.json:
#
#   "dispatch_classes": { "award-enrichment": { "max_share_pct": 50, "max_workers": 3 } }
#
# cap = floor(simultaneous_target_final * max_share_pct / 100), minimum 1;
# when max_workers is also set the lower value wins. Unlabelled issues and
# labels with no configured class are never capped (behaviour unchanged).
#
# Active class workers are counted from local reservation markers written by
# the dispatch loop, intersected with the shared worker discovery path
# (list_active_worker_processes). A marker without a live worker still counts
# for PULSE_DISPATCH_CLASS_RESERVATION_GRACE seconds (default 300) so parallel
# launch ceremonies cannot overshoot the cap; older orphan markers are pruned.

#######################################
# Extract the first valid dispatch class from a comma-separated label list.
# Arguments: $1 - labels CSV
# Stdout: class name (empty when none)
#######################################
_dispatch_class_from_labels() {
	local labels_csv="$1"
	local label="" class=""
	local -a label_list=()
	IFS=',' read -r -a label_list <<<"$labels_csv"
	for label in "${label_list[@]+"${label_list[@]}"}"; do
		label="${label#"${label%%[![:space:]]*}"}"
		label="${label%"${label##*[![:space:]]}"}"
		case "$label" in
		dispatch-class:*)
			class="${label#dispatch-class:}"
			if [[ "$class" =~ ^[A-Za-z0-9._-]+$ ]]; then
				printf '%s\n' "$class"
				return 0
			fi
			;;
		esac
	done
	return 0
}

#######################################
# Resolve a class configuration for a repo.
# Arguments: $1 - repo slug, $2 - class name, $3 - repo path (optional)
# Stdout: "<max_share_pct> <max_workers>" (0 = unset); empty when unconfigured
#######################################
_dispatch_class_config() {
	local repo_slug="$1"
	local class="$2"
	local repo_path="${3:-}"
	local repos_json="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
	local filter='((.max_share_pct // 0 | tonumber? // 0 | floor | tostring) + " " + (.max_workers // 0 | tonumber? // 0 | floor | tostring))'
	local config=""

	command -v jq >/dev/null 2>&1 || return 0
	if [[ -f "$repos_json" ]]; then
		config=$(jq -r --arg slug "$repo_slug" --arg class "$class" \
			"[.initialized_repos[]? | select(.slug == \$slug) | .dispatch_classes[\$class]? | objects] | first // empty | ${filter}" \
			"$repos_json" 2>/dev/null) || config=""
	fi
	if [[ -z "$config" && -n "$repo_path" && -f "${repo_path}/.aidevops.json" ]]; then
		config=$(jq -r --arg class "$class" \
			".dispatch_classes[\$class]? | objects | ${filter}" \
			"${repo_path}/.aidevops.json" 2>/dev/null) || config=""
	fi
	[[ "$config" =~ ^[0-9]+\ [0-9]+$ ]] || return 0
	printf '%s\n' "$config"
	return 0
}

#######################################
# Compute the effective cap for a class.
# Arguments: $1 - simultaneous worker target, $2 - max_share_pct, $3 - max_workers
# Stdout: cap (0 = uncapped)
#######################################
_dispatch_class_cap_value() {
	local target="$1"
	local share_pct="$2"
	local max_workers="$3"
	local cap=0
	[[ "$target" =~ ^[0-9]+$ ]] || target=1
	[[ "$share_pct" =~ ^[0-9]+$ ]] || share_pct=0
	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=0
	if ((share_pct > 0)); then
		cap=$((target * share_pct / 100))
		((cap < 1)) && cap=1
	fi
	if ((max_workers > 0)); then
		if ((cap == 0 || max_workers < cap)); then
			cap="$max_workers"
		fi
	fi
	printf '%s\n' "$cap"
	return 0
}

#######################################
# Reservation marker directory for one repo.
# Arguments: $1 - repo slug
#######################################
_dispatch_class_state_dir() {
	local repo_slug="$1"
	local safe_slug="${repo_slug//\//__}"
	printf '%s/dispatch-classes/%s\n' "${PULSE_DIR:-${HOME}/.aidevops/.agent-workspace/supervisor}" "$safe_slug"
	return 0
}

#######################################
# List issue numbers that have a live local worker for a repo.
# Workers launched with --dir for another repo are ignored; workers without
# --dir fall back to their session key (mirrors has_worker_for_repo_issue).
# Arguments: $1 - repo path (may be empty), $2 - worker process lines
#######################################
_dispatch_class_live_issues() {
	local repo_path="$1"
	local worker_procs="$2"
	printf '%s\n' "$worker_procs" | awk -v path="$repo_path" '
		BEGIN { esc = path; gsub(/[][(){}.^$*+?|\\]/, "\\\\&", esc) }
		{
			if (path != "" && $0 ~ /--dir[[:space:]]/ && $0 !~ ("--dir[[:space:]]+" esc "([[:space:]]|$)")) next
			line = $0
			while (match(line, /issue-[0-9]+/)) { print substr(line, RSTART + 6, RLENGTH - 6); line = substr(line, RSTART + RLENGTH) }
			line = $0
			while (match(line, /Issue #[0-9]+/)) { print substr(line, RSTART + 7, RLENGTH - 7); line = substr(line, RSTART + RLENGTH) }
		}' | sort -u
	return 0
}

#######################################
# Count active (live or freshly reserved) workers for a class in one repo.
# Prunes orphan markers older than the reservation grace window.
# Arguments: $1 - repo slug, $2 - repo path, $3 - class, $4 - issue to exclude,
#            $5 - worker process lines
# Stdout: count
#######################################
_dispatch_class_active_count() {
	local repo_slug="$1"
	local repo_path="$2"
	local class="$3"
	local exclude_issue="$4"
	local worker_procs="$5"
	local state_dir="" live_issues="" marker="" issue="" marker_class="" marker_epoch="" now=0 count=0
	local grace="${PULSE_DISPATCH_CLASS_RESERVATION_GRACE:-300}"
	[[ "$grace" =~ ^[0-9]+$ ]] || grace=300
	state_dir=$(_dispatch_class_state_dir "$repo_slug")
	if [[ ! -d "$state_dir" ]]; then
		printf '0\n'
		return 0
	fi
	live_issues=$(_dispatch_class_live_issues "$repo_path" "$worker_procs")
	now=$(date +%s)
	for marker in "$state_dir"/*; do
		[[ -f "$marker" ]] || continue
		issue="${marker##*/}"
		[[ "$issue" =~ ^[0-9]+$ ]] || continue
		[[ "$issue" == "$exclude_issue" ]] && continue
		marker_class=""
		marker_epoch=""
		read -r marker_class marker_epoch <"$marker" 2>/dev/null || true
		[[ "$marker_epoch" =~ ^[0-9]+$ ]] || marker_epoch=0
		if printf '%s\n' "$live_issues" | grep -qx "$issue"; then
			[[ "$marker_class" == "$class" ]] && count=$((count + 1))
		elif ((now - marker_epoch < grace)); then
			[[ "$marker_class" == "$class" ]] && count=$((count + 1))
		else
			rm -f "$marker" 2>/dev/null || true
		fi
	done
	printf '%s\n' "$count"
	return 0
}

#######################################
# Enforce the per-class dispatch cap for one candidate and reserve a slot.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug
#   $3 - repo path
#   $4 - labels CSV
#   $5 - (optional) pre-fetched list_active_worker_processes output
# Globals:
#   _DISPATCH_CLASS_CAP_TARGET - simultaneous_target_final for this round
#                                (falls back to get_max_workers_target)
#   _DISPATCH_CLASS_RESERVED   - set to 1 when this call wrote a marker
# Stdout: log lines (caller appends to LOGFILE)
# Returns:
#   0 - proceed (unclassified, unconfigured, or below cap)
#   1 - deferred (class at cap); retried next cycle, never penalised
#######################################
_dispatch_check_class_cap() {
	local issue_number="$1"
	local repo_slug="$2"
	local repo_path="$3"
	local labels_csv="$4"
	local worker_procs="${5:-}"
	_DISPATCH_CLASS_RESERVED=0

	local class="" config="" share_pct=0 max_workers=0 target="" cap=0 active=0
	class=$(_dispatch_class_from_labels "$labels_csv")
	[[ -n "$class" ]] || return 0
	config=$(_dispatch_class_config "$repo_slug" "$class" "$repo_path")
	if [[ -z "$config" ]]; then
		echo "[pulse-wrapper] Dispatch_class_cap: #${issue_number} (${repo_slug}) class=${class} has no dispatch_classes config — uncapped"
		return 0
	fi
	read -r share_pct max_workers <<<"$config"
	target="${_DISPATCH_CLASS_CAP_TARGET:-}"
	if ! [[ "$target" =~ ^[0-9]+$ ]]; then
		if declare -F get_max_workers_target >/dev/null 2>&1; then
			target=$(get_max_workers_target)
		fi
		[[ "$target" =~ ^[0-9]+$ ]] || target=1
	fi
	cap=$(_dispatch_class_cap_value "$target" "$share_pct" "$max_workers")
	[[ "$cap" =~ ^[0-9]+$ ]] || cap=0
	((cap > 0)) || return 0

	if [[ -z "$worker_procs" ]] && declare -F list_active_worker_processes >/dev/null 2>&1; then
		worker_procs=$(list_active_worker_processes 2>/dev/null) || worker_procs=""
	fi

	local state_dir="" lock_dir="" locked=0 attempt=0
	state_dir=$(_dispatch_class_state_dir "$repo_slug")
	mkdir -p "$state_dir" 2>/dev/null || true
	lock_dir="${state_dir}/.lock"
	while ((attempt < 50)); do
		if mkdir "$lock_dir" 2>/dev/null; then
			locked=1
			break
		fi
		attempt=$((attempt + 1))
		sleep 0.1 2>/dev/null || sleep 1
	done
	if ((locked == 0)); then
		echo "[pulse-wrapper] Dispatch_class_cap: lock busy for ${repo_slug}; counting without lock"
	fi

	active=$(_dispatch_class_active_count "$repo_slug" "$repo_path" "$class" "$issue_number" "$worker_procs")
	[[ "$active" =~ ^[0-9]+$ ]] || active=0
	if ((active >= cap)); then
		if ((locked == 1)); then
			rmdir "$lock_dir" 2>/dev/null || true
		fi
		echo "[pulse-wrapper] Dispatch_max: #${issue_number} (${repo_slug}) deferred — dispatch_class_cap: class=${class} active=${active} cap=${cap} target=${target} max_share_pct=${share_pct} max_workers=${max_workers} (retry next cycle)"
		if declare -F _dispatch_stats_increment >/dev/null 2>&1; then
			_dispatch_stats_increment "dispatch_candidate_deferred_class_cap"
		fi
		return 1
	fi

	local marker="${state_dir}/${issue_number}"
	if [[ -f "$marker" ]] && _dispatch_class_live_issues "$repo_path" "$worker_procs" | grep -qx "$issue_number"; then
		# A live worker already owns this issue; keep its marker untouched so
		# a dedup-blocked re-evaluation cannot release the live reservation.
		:
	elif printf '%s %s\n' "$class" "$(date +%s)" >"$marker" 2>/dev/null; then
		_DISPATCH_CLASS_RESERVED=1
	fi
	if ((locked == 1)); then
		rmdir "$lock_dir" 2>/dev/null || true
	fi
	echo "[pulse-wrapper] Dispatch_class_cap: #${issue_number} (${repo_slug}) class=${class} active=${active} cap=${cap} target=${target} — proceeding"
	return 0
}

#######################################
# Drop the reservation marker written by _dispatch_check_class_cap when the
# candidate did not launch a worker.
# Arguments: $1 - repo slug, $2 - issue number
#######################################
_dispatch_class_release_reservation() {
	local repo_slug="$1"
	local issue_number="$2"
	if [[ "${_DISPATCH_CLASS_RESERVED:-0}" == "1" && "$issue_number" =~ ^[0-9]+$ ]]; then
		rm -f "$(_dispatch_class_state_dir "$repo_slug")/${issue_number}" 2>/dev/null || true
	fi
	_DISPATCH_CLASS_RESERVED=0
	return 0
}
