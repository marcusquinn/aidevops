#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# stats-health-dashboard.sh - Per-repo pinned health issue dashboards
#
# Extracted from stats-functions.sh via the phased decomposition plan:
#   todo/plans/stats-functions-decomposition.md  (Phase 3)
#
# This module is sourced by stats-functions.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all stats-* configuration constants in the bootstrap
# section of stats-functions.sh.
#
# Dependencies on other stats modules:
#   - stats-shared.sh (calls _get_runner_role)
#
# Globals read:
#   - LOGFILE, REPOS_JSON, PERSON_STATS_INTERVAL, PERSON_STATS_LAST_RUN,
#     PERSON_STATS_CACHE_DIR, SESSION_COUNT_WARN
# Globals written:
#   - none (stats modules write only to disk under ~/.aidevops/logs/)

# Include guard — prevent double-sourcing
[[ -n "${_STATS_HEALTH_DASHBOARD_LOADED:-}" ]] && return 0
_STATS_HEALTH_DASHBOARD_LOADED=1

# t2687: sentinel returned by _find_health_issue when a gh query fails
# (rate limit, network, API 5xx). Callers treat this as "abstain this
# cycle" — never fall through to _create_health_issue, which would
# create a duplicate while the dedup lookups are silently unable to
# see existing ones.
readonly _HEALTH_QUERY_FAILED_SENTINEL="__QUERY_FAILED__"

#######################################
# List open health issues matching a role + runner_user pair, filtered
# by title-prefix. Helper centralises the jq filter so `_find_health_issue`
# and `_periodic_health_issue_dedup` share one query definition.
#
# Arguments:
#   $1 - repo slug
#   $2 - role label (supervisor|contributor)
#   $3 - runner user
#   $4 - role display (Supervisor|Contributor)
# Output: JSON array sorted newest-first (by number desc).
# Returns: gh's exit code (non-zero on rate limit / network / API error).
#######################################
_list_health_issues_by_role_label() {
	local repo_slug="$1"
	local role_label="$2"
	local runner_user="$3"
	local role_display="$4"

	gh_issue_list --repo "$repo_slug" \
		--label "$role_label" --label "$runner_user" \
		--state open --json number,title \
		--jq "[.[] | select(.title | startswith(\"[${role_display}:\"))] | sort_by(.number) | reverse"
}

#######################################
# Find an existing health issue by cache, labels, or title search.
#
# Error-classification policy (t2687, GH#20301):
#
#   Under GraphQL rate-limit pressure, the pre-t2687 logic silently
#   treated `gh issue view|list` failures as "not found" and let
#   _resolve_health_issue_number fall through to _create_health_issue.
#   Combined with the asymmetric t2574 REST fallback (which made CREATE
#   succeed during exhaustion while READ paths still failed), this
#   produced 19 duplicate [Supervisor:*]/[Contributor:*] issues across
#   the fleet on 2026-04-21.
#
#   The fix distinguishes success-with-empty-result from query-failure:
#     - Cache validation query fails (rc != 0):   preserve cache, return cached number.
#     - Cache validation returns CLOSED:          unpin, clear cache, fall through to lookup.
#     - Cache validation returns unknown state:   preserve cache defensively (log warning).
#     - Label/title lookup fails (rc != 0):       emit __QUERY_FAILED__ sentinel so the
#                                                 caller abstains from creation this cycle.
#     - Label/title lookup returns empty array:   confirmed-not-found, safe to create.
#
# Arguments:
#   $1 - repo slug
#   $2 - runner user
#   $3 - runner role (supervisor|contributor)
#   $4 - runner prefix (e.g. "[Supervisor:user]")
#   $5 - role label (supervisor|contributor)
#   $6 - role display (Supervisor|Contributor)
#   $7 - cache file path
# Output: issue number to stdout, or empty string (confirmed-not-found),
#         or "__QUERY_FAILED__" (caller must skip creation this cycle).
#######################################
# Validate a cached health-issue number: check it still exists and is OPEN.
# Returns (via stdout):
#   - the cached number if still valid
#   - empty if the cache entry points to a CLOSED issue (caller should re-resolve)
#   - $_HEALTH_QUERY_FAILED_SENTINEL if `gh issue view` failed (rate-limit/network)
# Side effects: removes the cache file on CLOSED state, unpins on CLOSED supervisor.
_try_cached_health_issue_lookup() {
	local health_issue_file="$1"
	local repo_slug="$2"
	local runner_role="$3"

	[[ ! -f "$health_issue_file" ]] && return 0  # empty stdout

	local cached_number
	cached_number=$(cat "$health_issue_file" 2>/dev/null || echo "")
	[[ -z "$cached_number" ]] && return 0

	local issue_state rc=0
	issue_state=$(gh_issue_view "$cached_number" --repo "$repo_slug" --json state --jq '.state' 2>/dev/null) || rc=$?

	if [[ $rc -ne 0 ]]; then
		# Query failed (rate limit, network, API 5xx). Preserve cache and return
		# it — caller still points to a valid-as-far-as-we-know issue.
		echo "[stats] Health issue: cache validation failed for #${cached_number} in ${repo_slug} (rc=${rc}) — preserving cache" >>"${LOGFILE:-/dev/null}"
		echo "$cached_number"
		return 0
	fi

	if [[ "$issue_state" == "CLOSED" ]]; then
		[[ "$runner_role" == "supervisor" ]] && _unpin_health_issue "$cached_number" "$repo_slug"
		rm -f "$health_issue_file" 2>/dev/null || true
		return 0  # empty → caller re-resolves
	fi

	if [[ "$issue_state" != "OPEN" ]]; then
		# Unexpected state (empty, unknown enum). Preserve cache defensively.
		echo "[stats] Health issue: unexpected state '${issue_state}' for #${cached_number} in ${repo_slug} — preserving cache" >>"${LOGFILE:-/dev/null}"
		echo "$cached_number"
		return 0
	fi

	echo "$cached_number"
	return 0
}

#######################################
# Strip the 'persistent' label from a health issue before closing it,
# preventing issue-sync.yml 'Reopen Persistent Issues' from reopening
# programmatic dedup closes (GH#20326). Idempotent: no-op if not present.
# Arguments:
#   $1 - issue number
#   $2 - repo slug
_strip_persistent_label_before_close() {
	local issue_number="$1"
	local repo_slug="$2"
	gh issue edit "$issue_number" --repo "$repo_slug" --remove-label persistent 2>/dev/null || true
	return 0
}

#######################################
# Close all duplicate health issues (all but the first) from a jq array.
# Arguments: label_results_json keep_number repo_slug runner_role
_close_health_issue_duplicates() {
	local label_results="$1" keep_number="$2" repo_slug="$3" runner_role="$4"

	local dup_count
	dup_count=$(printf '%s' "$label_results" | jq 'length' 2>/dev/null || echo "0")
	[[ "${dup_count:-0}" -le 1 ]] && return 0

	local dup_numbers
	dup_numbers=$(printf '%s' "$label_results" | jq -r '.[1:][].number' 2>/dev/null || echo "")
	while IFS= read -r dup_num; do
		[[ -z "$dup_num" ]] && continue
		[[ "$runner_role" == "supervisor" ]] && _unpin_health_issue "$dup_num" "$repo_slug"
		_strip_persistent_label_before_close "$dup_num" "$repo_slug"
		gh issue close "$dup_num" --repo "$repo_slug" \
			--comment "Closing duplicate ${runner_role} health issue — superseded by #${keep_number}." 2>/dev/null || true
	done <<<"$dup_numbers"
	return 0
}

#######################################
# Title-based fallback lookup with label backfill.
# Returns issue number if found, empty if not, $_HEALTH_QUERY_FAILED_SENTINEL on failure.
_try_title_health_issue_fallback() {
	local runner_prefix="$1" repo_slug="$2" runner_user="$3" role_label="$4" role_display="$5"

	local title_result rc=0
	title_result=$(gh_issue_list --repo "$repo_slug" \
		--search "in:title ${runner_prefix}" \
		--state open --json number,title \
		--jq "[.[] | select(.title | startswith(\"${runner_prefix}\"))][0].number" 2>/dev/null) || rc=$?

	if [[ $rc -ne 0 ]]; then
		echo "[stats] Health issue: title lookup failed for ${runner_prefix} in ${repo_slug} (rc=${rc}) — abstaining this cycle" >>"${LOGFILE:-/dev/null}"
		echo "$_HEALTH_QUERY_FAILED_SENTINEL"
		return 0
	fi

	local health_issue_number="${title_result:-}"
	if [[ -n "$health_issue_number" ]]; then
		gh label create "$runner_user" --repo "$repo_slug" --color "0E8A16" \
			--description "${role_display} runner: ${runner_user}" --force 2>/dev/null || true
		gh issue edit "$health_issue_number" --repo "$repo_slug" \
			--add-label "$role_label" --add-label "$runner_user" 2>/dev/null || true
	fi
	echo "$health_issue_number"
	return 0
}

_find_health_issue() {
	local repo_slug="$1"
	local runner_user="$2"
	local runner_role="$3"
	local runner_prefix="$4"
	local role_label="$5"
	local role_display="$6"
	local health_issue_file="$7"

	local health_issue_number
	health_issue_number=$(_try_cached_health_issue_lookup "$health_issue_file" "$repo_slug" "$runner_role")

	# Sentinel from cache lookup is defensive only; current behaviour preserves
	# the cached number on error, but downstream checks still need it to pass
	# through. Short-circuit on sentinel.
	if [[ "$health_issue_number" == "$_HEALTH_QUERY_FAILED_SENTINEL" ]]; then
		echo "$_HEALTH_QUERY_FAILED_SENTINEL"
		return 0
	fi

	# Search by labels (more reliable than title search) if cache gave nothing.
	if [[ -z "$health_issue_number" ]]; then
		local label_results rc=0
		label_results=$(_list_health_issues_by_role_label \
			"$repo_slug" "$role_label" "$runner_user" "$role_display" 2>/dev/null) || rc=$?

		if [[ $rc -ne 0 ]]; then
			# Abstain this cycle. Emit sentinel so _resolve_health_issue_number
			# refuses to create a duplicate.
			echo "[stats] Health issue: label lookup failed for ${role_label}+${runner_user} in ${repo_slug} (rc=${rc}) — abstaining this cycle" >>"${LOGFILE:-/dev/null}"
			echo "$_HEALTH_QUERY_FAILED_SENTINEL"
			return 0
		fi

		label_results="${label_results:-[]}"
		health_issue_number=$(printf '%s' "$label_results" | jq -r '.[0].number // empty' 2>/dev/null || echo "")
		_close_health_issue_duplicates "$label_results" "$health_issue_number" "$repo_slug" "$runner_role"
	fi

	# Fallback: title-based search with label backfill.
	if [[ -z "$health_issue_number" ]]; then
		health_issue_number=$(_try_title_health_issue_fallback \
			"$runner_prefix" "$repo_slug" "$runner_user" "$role_label" "$role_display")
	fi

	echo "$health_issue_number"
	return 0
}

#######################################
# Create a new health issue for a runner+repo and optionally pin it.
#
# Arguments:
#   $1 - repo slug
#   $2 - runner user
#   $3 - runner role (supervisor|contributor)
#   $4 - runner prefix (e.g. "[Supervisor:user]")
#   $5 - role label (supervisor|contributor)
#   $6 - role label color
#   $7 - role label desc
#   $8 - role display (Supervisor|Contributor)
# Output: new issue number to stdout (empty on failure)
#######################################
_create_health_issue() {
	local repo_slug="$1"
	local runner_user="$2"
	local runner_role="$3"
	local runner_prefix="$4"
	local role_label="$5"
	local role_label_color="$6"
	local role_label_desc="$7"
	local role_display="$8"

	gh label create "$role_label" --repo "$repo_slug" --color "$role_label_color" \
		--description "$role_label_desc" --force 2>/dev/null || true
	gh label create "$runner_user" --repo "$repo_slug" --color "0E8A16" \
		--description "${role_display} runner: ${runner_user}" --force 2>/dev/null || true
	gh label create "source:health-dashboard" --repo "$repo_slug" --color "C2E0C6" \
		--description "Auto-created by stats-functions.sh health dashboard" --force 2>/dev/null || true
	# t1890: health dashboard issues are management issues that should never be
	# closed or dispatched. Add the "persistent" label for consistency with the
	# quality review issue, so the dispatch filter only needs one label check.
	gh label create "persistent" --repo "$repo_slug" --color "FBCA04" \
		--description "Persistent issue — do not close" --force 2>/dev/null || true

	local health_body="Live ${runner_role} status for **${runner_user}**. Updated each pulse. Pin this issue for at-a-glance monitoring."
	local sig_footer=""
	sig_footer=$("${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" footer --body "$health_body" 2>/dev/null || true)
	health_body="${health_body}${sig_footer}"

	# t2691/GH#20311: Health dashboard issues are always created by the
	# headless pulse context. Force AIDEVOPS_SESSION_ORIGIN=worker so
	# gh_create_issue applies origin:worker regardless of whether the
	# caller has AIDEVOPS_HEADLESS set (defense-in-depth; stats-wrapper.sh
	# already exports AIDEVOPS_HEADLESS=true, but this guards test contexts
	# and any future invocation path that bypasses that wrapper).
	local health_issue_number
	health_issue_number=$(AIDEVOPS_SESSION_ORIGIN=worker gh_create_issue --repo "$repo_slug" \
		--title "${runner_prefix} starting..." \
		--body "$health_body" \
		--label "$role_label" --label "$runner_user" --label "source:health-dashboard" --label "persistent" 2>/dev/null | grep -oE '[0-9]+$' || echo "")

	if [[ -z "$health_issue_number" ]]; then
		echo "[stats] Health issue: could not create for ${repo_slug}" >>"$LOGFILE"
		echo ""
		return 0
	fi

	# Pin only supervisor issues — contributor issues don't pin because
	# GitHub allows max 3 pinned issues per repo and those slots are
	# reserved for maintainer dashboards and the quality review issue.
	if [[ "$runner_role" == "supervisor" ]]; then
		local node_id
		node_id=$(gh_issue_view "$health_issue_number" --repo "$repo_slug" --json id --jq '.id' 2>/dev/null || echo "")
		if [[ -n "$node_id" ]]; then
			gh api graphql -f query="
				mutation {
					pinIssue(input: {issueId: \"${node_id}\"}) {
						issue { number }
					}
				}" >/dev/null 2>&1 || true
		fi
	fi
	echo "[stats] Health issue: created #${health_issue_number} (${runner_role}) for ${runner_user} in ${repo_slug}" >>"$LOGFILE"

	echo "$health_issue_number"
	return 0
}

#######################################
# Resolve (find or create) the health issue number for a runner+repo.
#
# Delegates to _find_health_issue then _create_health_issue if not found.
#
# Arguments:
#   $1 - repo slug
#   $2 - runner user
#   $3 - runner role (supervisor|contributor)
#   $4 - runner prefix (e.g. "[Supervisor:user]")
#   $5 - role label (supervisor|contributor)
#   $6 - role label color
#   $7 - role label desc
#   $8 - role display (Supervisor|Contributor)
#   $9 - cache file path
# Output: issue number to stdout (empty on failure)
#######################################
_resolve_health_issue_number() {
	local repo_slug="$1"
	local runner_user="$2"
	local runner_role="$3"
	local runner_prefix="$4"
	local role_label="$5"
	local role_label_color="$6"
	local role_label_desc="$7"
	local role_display="$8"
	local health_issue_file="$9"

	local health_issue_number
	health_issue_number=$(_find_health_issue \
		"$repo_slug" "$runner_user" "$runner_role" "$runner_prefix" \
		"$role_label" "$role_display" "$health_issue_file")

	# t2687: honour the query-failed sentinel from _find_health_issue.
	# When the API was unreachable for the dedup lookups, abstain from
	# creation this cycle — otherwise we create duplicates every time
	# GraphQL is exhausted (the root cause of GH#20301).
	if [[ "$health_issue_number" == "$_HEALTH_QUERY_FAILED_SENTINEL" ]]; then
		echo "[stats] Health issue: abstaining from create/update cycle for ${repo_slug} (runner=${runner_user}, role=${runner_role}) — dedup lookups failed" >>"${LOGFILE:-/dev/null}"
		echo ""
		return 0
	fi

	if [[ -z "$health_issue_number" ]]; then
		health_issue_number=$(_create_health_issue \
			"$repo_slug" "$runner_user" "$runner_role" "$runner_prefix" \
			"$role_label" "$role_label_color" "$role_label_desc" "$role_display")
	fi

	echo "$health_issue_number"
	return 0
}

#######################################
# Periodic label-based dedup scan (t2687, GH#20301).
#
# Even when the cached health issue is valid and returns quickly via
# _find_health_issue, the label-based dedup block inside that function
# is bypassed because the cache-hit path short-circuits before the
# label scan runs. That means duplicates that slipped in during past
# GraphQL rate-limit windows never get closed automatically — they
# require either a cache invalidation or manual intervention.
#
# This helper runs the same label-based dedup at most once per hour
# per repo-runner-role tuple, keyed by a timestamp state file. On
# query failure (rc != 0), the state file is NOT updated so the next
# pulse cycle retries — avoids starving the scan during an extended
# rate-limit window.
#
# Arguments:
#   $1 - repo slug
#   $2 - runner user
#   $3 - runner role (supervisor|contributor)
#   $4 - role label (supervisor|contributor)
#   $5 - role display (Supervisor|Contributor)
#   $6 - current (kept) health issue number
# Env:
#   HEALTH_DEDUP_INTERVAL - seconds between scans per (repo, runner, role).
#                           Default 3600 (1 hour).
# Returns: 0 always (best-effort, never breaks the pulse).
#######################################
_periodic_health_issue_dedup() {
	local repo_slug="$1"
	local runner_user="$2"
	local runner_role="$3"
	local role_label="$4"
	local role_display="$5"
	local current_issue="$6"

	[[ -z "$repo_slug" || -z "$runner_user" || -z "$role_label" || -z "$current_issue" ]] && return 0

	local slug_safe="${repo_slug//\//-}"
	local cache_dir="${HOME}/.aidevops/logs"
	local state_file="${cache_dir}/health-dedup-last-scan-${runner_user}-${role_label}-${slug_safe}"
	local interval="${HEALTH_DEDUP_INTERVAL:-3600}"

	# Throttle: skip if last scan was recent
	if [[ -f "$state_file" ]]; then
		local last_scan_epoch now_epoch elapsed
		last_scan_epoch=$(_file_mtime_epoch "$state_file")
		now_epoch=$(date +%s)
		elapsed=$((now_epoch - last_scan_epoch))
		if [[ $elapsed -lt $interval ]]; then
			return 0
		fi
	fi

	mkdir -p "$cache_dir" 2>/dev/null || true

	local label_results rc=0
	label_results=$(_list_health_issues_by_role_label \
		"$repo_slug" "$role_label" "$runner_user" "$role_display" 2>/dev/null) || rc=$?

	if [[ $rc -ne 0 ]]; then
		# Leave state_file alone — retry next pulse cycle.
		echo "[stats] Health issue: periodic dedup scan failed for ${repo_slug} (rc=${rc}) — will retry next cycle" >>"${LOGFILE:-/dev/null}"
		return 0
	fi

	label_results="${label_results:-[]}"

	local total_count
	total_count=$(printf '%s' "$label_results" | jq 'length' 2>/dev/null || echo "0")

	if [[ "${total_count:-0}" -gt 1 ]]; then
		local dup_numbers
		# Close every issue in the label-match set except the one we're
		# currently using. The cached/resolved issue is the canonical one
		# because its body+title are up-to-date with this pulse.
		dup_numbers=$(printf '%s' "$label_results" | jq -r --arg keep "$current_issue" \
			'.[] | select((.number | tostring) != $keep) | .number' 2>/dev/null || echo "")
		while IFS= read -r dup_num; do
			[[ -z "$dup_num" ]] && continue
			# _unpin_health_issue is already best-effort and a no-op for
			# unpinned (contributor) issues, so call unconditionally.
			# Duplicate supervisor issues CAN be pinned in pathological
			# cases (stale pin from a pre-rate-limit canonical).
			_unpin_health_issue "$dup_num" "$repo_slug"
			_strip_persistent_label_before_close "$dup_num" "$repo_slug"
			gh issue close "$dup_num" --repo "$repo_slug" \
				--comment "Closing duplicate ${runner_role} health issue — superseded by #${current_issue} (t2687 periodic dedup). Root cause likely a past GraphQL rate-limit window; see GH#20301." 2>/dev/null || true
			echo "[stats] Health issue: periodic dedup closed #${dup_num} in ${repo_slug} (kept #${current_issue})" >>"${LOGFILE:-/dev/null}"
		done <<<"$dup_numbers"
	fi

	# Update state file timestamp (even when no duplicates found) so we
	# don't re-query every cycle.
	touch "$state_file" 2>/dev/null || true

	return 0
}

#######################################
# Scan active headless worker processes for a repo.
#
# Uses the shared list_active_worker_processes (worker-lifecycle-common.sh)
# as the single source of truth for worker discovery, then filters by
# repo path and formats as markdown for the health issue body.
#
# Arguments:
#   $1 - repo path (used to filter workers by --dir)
# Output: NUL-delimited "workers_md\0worker_count\0"
#######################################
_scan_active_workers() {
	local repo_path="$1"

	local workers_md=""
	local worker_count=0

	# Get deduplicated, zombie-filtered worker list from shared function
	local worker_lines
	worker_lines=$(list_active_worker_processes || true)

	if [[ -n "$worker_lines" ]]; then
		local worker_table=""
		while IFS= read -r line; do
			[[ -z "$line" ]] && continue
			local w_pid w_etime w_cmd
			read -r w_pid w_etime w_cmd <<<"$line"

			# Extract dir if present — filter to this repo only
			local w_dir=""
			if [[ "$w_cmd" =~ --dir[[:space:]]+([^[:space:]]+) ]]; then
				w_dir="${BASH_REMATCH[1]}"
			fi

			# Only include workers for this repo (or all if dir not detectable)
			if [[ -n "$w_dir" && -n "$repo_path" && "$w_dir" != "$repo_path"* ]]; then
				continue
			fi

			# Extract title if present (--title "...")
			local w_title="headless"
			if [[ "$w_cmd" =~ --title[[:space:]]+\"([^\"]+)\" ]] || [[ "$w_cmd" =~ --title[[:space:]]+([^[:space:]]+) ]]; then
				w_title="${BASH_REMATCH[1]}"
			fi

			local w_title_short="${w_title:0:60}"
			[[ ${#w_title} -gt 60 ]] && w_title_short="${w_title_short}..."
			worker_table="${worker_table}| ${w_pid} | ${w_etime} | ${w_title_short} |
"
			worker_count=$((worker_count + 1))
		done <<<"$worker_lines"

		if [[ "$worker_count" -gt 0 ]]; then
			workers_md="| PID | Uptime | Title |
| --- | --- | --- |
${worker_table}"
		fi
	fi

	if [[ "$worker_count" -eq 0 ]]; then
		workers_md="_No active workers_"
	fi

	# NUL-delimited output preserves multiline workers_md markdown
	printf '%s\0%s\0' "$workers_md" "$worker_count"
	return 0
}

#######################################
# Collect system resource metrics (CPU, memory, processes).
#
# Output: "sys_load_ratio|sys_cpu_cores|sys_load_1m|sys_load_5m|sys_memory|sys_procs"
#######################################
_gather_system_resources() {
	local sys_cpu_cores sys_load_1m sys_load_5m sys_memory sys_procs
	sys_cpu_cores=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo "?")
	sys_procs=$(ps aux 2>/dev/null | wc -l | tr -d ' ')

	if [[ "$(uname)" == "Darwin" ]]; then
		local load_str
		load_str=$(sysctl -n vm.loadavg 2>/dev/null || echo "{ 0 0 0 }")
		sys_load_1m=$(echo "$load_str" | awk '{print $2}')
		sys_load_5m=$(echo "$load_str" | awk '{print $3}')

		local page_size vm_free vm_inactive
		page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo "16384")
		vm_free=$(vm_stat 2>/dev/null | awk '/Pages free/ {gsub(/\./,"",$3); print $3}')
		vm_inactive=$(vm_stat 2>/dev/null | awk '/Pages inactive/ {gsub(/\./,"",$3); print $3}')
		[[ "$page_size" =~ ^[0-9]+$ ]] || page_size=16384
		[[ "$vm_free" =~ ^[0-9]+$ ]] || vm_free=0
		[[ "$vm_inactive" =~ ^[0-9]+$ ]] || vm_inactive=0
		if [[ -n "$vm_free" ]]; then
			local avail_mb=$(((${vm_free:-0} + ${vm_inactive:-0}) * page_size / 1048576))
			if [[ "$avail_mb" -lt 1024 ]]; then
				sys_memory="HIGH pressure (${avail_mb}MB free)"
			elif [[ "$avail_mb" -lt 4096 ]]; then
				sys_memory="medium (${avail_mb}MB free)"
			else
				sys_memory="low (${avail_mb}MB free)"
			fi
		else
			sys_memory="unknown"
		fi
	elif [[ -f /proc/loadavg ]]; then
		read -r sys_load_1m sys_load_5m _ </proc/loadavg
		local mem_avail
		mem_avail=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo "")
		if [[ -n "$mem_avail" ]]; then
			if [[ "$mem_avail" -lt 1024 ]]; then
				sys_memory="HIGH pressure (${mem_avail}MB free)"
			elif [[ "$mem_avail" -lt 4096 ]]; then
				sys_memory="medium (${mem_avail}MB free)"
			else
				sys_memory="low (${mem_avail}MB free)"
			fi
		else
			sys_memory="unknown"
		fi
	else
		sys_load_1m="?"
		sys_load_5m="?"
		sys_memory="unknown"
	fi

	local sys_load_ratio="?"
	if [[ -n "${sys_load_1m:-}" && "${sys_cpu_cores:-0}" -gt 0 && "${sys_cpu_cores}" != "?" ]]; then
		if [[ "$sys_load_1m" =~ ^[0-9]+\.?[0-9]*$ ]] && [[ "$sys_cpu_cores" =~ ^[0-9]+$ ]]; then
			sys_load_ratio=$(awk "BEGIN {printf \"%d\", (${sys_load_1m} / ${sys_cpu_cores}) * 100}" || echo "?")
		fi
	fi

	printf '%s|%s|%s|%s|%s|%s' \
		"$sys_load_ratio" "$sys_cpu_cores" "$sys_load_1m" "$sys_load_5m" "$sys_memory" "$sys_procs"
	return 0
}

#######################################
# Gather live stats for the health issue body.
#
# Collects PR counts, issue counts, active workers, system resources,
# worktree count, max workers, and session count for a single repo.
#
# Arguments:
#   $1 - repo slug
#   $2 - repo path
#   $3 - runner user
# Output: newline-delimited fields:
#   pr_count, prs_md, assigned_issue_count, total_issue_count,
#   workers_md, worker_count, sys_load_ratio, sys_cpu_cores,
#   sys_load_1m, sys_load_5m, sys_memory, sys_procs,
#   wt_count, max_workers, session_count, session_warning
#######################################
_gather_health_stats() {
	local repo_slug="$1"
	local repo_path="$2"
	local runner_user="$3"

	# Open PRs — limit 100 for accurate count + table display.
	# Previously --limit 20 capped the count at 20 for repos with more open PRs.
	local pr_json
	pr_json=$(gh pr list --repo "$repo_slug" --state open \
		--json number,title,headRefName,updatedAt,reviewDecision,statusCheckRollup \
		--limit 100 2>/dev/null) || pr_json="[]"
	local pr_count
	pr_count=$(echo "$pr_json" | jq 'length')

	# Open issues — assigned to this runner (actionable) vs total.
	# --limit 500: gh defaults to 30, which undercounts for active repos.
	local assigned_issue_count
	assigned_issue_count=$(gh_issue_list --repo "$repo_slug" --state open \
		--assignee "$runner_user" --limit 500 \
		--json number --jq 'length' 2>/dev/null || echo "0")
	local total_issue_count
	total_issue_count=$(gh_issue_list --repo "$repo_slug" --state open \
		--limit 500 \
		--json number,labels --jq '[.[] | select(.labels | map(.name) | (index("supervisor") or index("contributor") or index("persistent") or index("quality-review")) | not)] | length' 2>/dev/null || echo "0")

	# Active headless workers — parse NUL-delimited output from _scan_active_workers.
	# Previously used head -1 / tail -1 on newline-delimited output, which truncated
	# the multiline workers_md markdown table to just its header row.
	local workers_md="" worker_count=0
	{
		local _worker_fields=()
		while IFS= read -r -d '' _wf; do
			_worker_fields+=("$_wf")
		done < <(_scan_active_workers "$repo_path")
		workers_md="${_worker_fields[0]:-_No active workers_}"
		worker_count="${_worker_fields[1]:-0}"
	}

	# System resources
	local sys_raw sys_load_ratio sys_cpu_cores sys_load_1m sys_load_5m sys_memory sys_procs
	sys_raw=$(_gather_system_resources)
	IFS='|' read -r sys_load_ratio sys_cpu_cores sys_load_1m sys_load_5m sys_memory sys_procs <<<"$sys_raw"

	# Worktree count for this repo
	local wt_count=0
	if [[ -d "${repo_path}/.git" ]]; then
		wt_count=$(git -C "$repo_path" worktree list 2>/dev/null | wc -l | tr -d ' ')
	fi

	# Max workers — validate as integer (matches pulse-wrapper's get_max_workers_target).
	# Previously read raw file content without validation, risking garbage display.
	local max_workers="?"
	local max_workers_file="${HOME}/.aidevops/logs/pulse-max-workers"
	if [[ -f "$max_workers_file" ]]; then
		max_workers=$(cat "$max_workers_file" 2>/dev/null || echo "?")
		[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers="?"
	fi

	# Interactive session count (t1398) — uses shared check_session_count
	# from worker-lifecycle-common.sh
	local session_count
	session_count=$(check_session_count)
	local session_warning=""
	if [[ "$session_count" -gt "$SESSION_COUNT_WARN" ]]; then
		session_warning=" **WARNING: exceeds threshold of ${SESSION_COUNT_WARN}**"
		echo "[stats] Session warning: $session_count interactive sessions open (threshold: $SESSION_COUNT_WARN)" >>"$LOGFILE"
	fi

	# PRs table
	local prs_md=""
	if [[ "$pr_count" -gt 0 ]]; then
		prs_md="| # | Title | Branch | Checks | Review | Updated |
| --- | --- | --- | --- | --- | --- |
"
		prs_md="${prs_md}$(echo "$pr_json" | jq -r '.[] | "| #\(.number) | \(.title[:60]) | `\(.headRefName)` | \(if .statusCheckRollup == null or (.statusCheckRollup | length) == 0 then "none" elif (.statusCheckRollup | all((.conclusion // .state) == "SUCCESS")) then "PASS" elif (.statusCheckRollup | any((.conclusion // .state) == "FAILURE")) then "FAIL" else "PENDING" end) | \(if .reviewDecision == null or .reviewDecision == "" then "NONE" else .reviewDecision end) | \(.updatedAt[:16]) |"')"
	else
		prs_md="_No open PRs_"
	fi

	# Output all stats as NUL-delimited fields.
	# This preserves multiline markdown blobs (prs_md/workers_md)
	# when consumed by _assemble_health_issue_body.
	printf '%s\0' \
		"$pr_count" \
		"$prs_md" \
		"$assigned_issue_count" \
		"$total_issue_count" \
		"$workers_md" \
		"$worker_count" \
		"$sys_load_ratio" \
		"$sys_cpu_cores" \
		"$sys_load_1m" \
		"$sys_load_5m" \
		"$sys_memory" \
		"$sys_procs" \
		"$wt_count" \
		"$max_workers" \
		"$session_count" \
		"$session_warning"
	return 0
}

#######################################
# Format the Worker Success Rate section markdown.
#
# Produces a two-row table showing 24h and 7d rates plus a parseable
# HTML comment so fleet-health-helper.sh (t2408) can extract values
# without re-running stats queries.
#
# Arguments:
#   $1 - rate_24h   (display string: "X% (M/T)" or "—")
#   $2 - rate_7d    (display string: "X% (M/T)" or "—")
#   $3 - total_24h  (numeric total run count for 24h window)
#   $4 - total_7d   (numeric total run count for 7d window)
# Output: markdown block to stdout
#######################################
_format_worker_rate_section() {
	local rate_24h="$1"
	local rate_7d="$2"
	local total_24h="$3"
	local total_7d="$4"
	printf '| Window | Success Rate |\n| --- | --- |\n| 24h | %s |\n| 7d | %s |\n\n<!-- worker-success-rate: 24h_total=%s 7d_total=%s -->' \
		"$rate_24h" "$rate_7d" "$total_24h" "$total_7d"
	return 0
}

#######################################
# Compute worker success rates for a given time window.
#
# Queries merged and closed-unmerged worker PRs across all pulse repos
# and counts watchdog kills (exit_code=124) from the headless-runtime
# metrics file. Fails open: gh errors count as 0; missing metrics file
# skips kill counting.
#
# Minimum-sample floor: when total_count < 5 the rate is reported as
# "—" (sentinel) per the t2402 §4 specification.
#
# Arguments:
#   $1 - runner_login  (GitHub username of the runner)
#   $2 - window_hours  (look-back window in hours, e.g. 24 or 168)
# Output: "<merged_count>\t<total_count>\t<rate_display>" to stdout
#   where rate_display is "X% (M/T)" when total >= 5, else "—"
#######################################
_compute_worker_success_rates() {
	local runner_login="$1"
	local window_hours="$2"
	local _iso_fmt="%Y-%m-%dT%H:%M:%SZ"
	local window_epoch window_start
	if [[ "$(uname)" == "Darwin" ]]; then
		window_epoch=$(date -u -v-"${window_hours}"H +"%s")
		window_start=$(date -u -v-"${window_hours}"H +"$_iso_fmt")
	else
		window_epoch=$(date -u -d "${window_hours} hours ago" +"%s")
		window_start=$(date -u -d "${window_hours} hours ago" +"$_iso_fmt")
	fi
	local merged_count=0 closed_unmerged_count=0 killed_count=0
	local repos_file="${HOME}/.config/aidevops/repos.json"
	if [[ -f "$repos_file" ]]; then
		local slug
		while IFS= read -r slug; do
			[[ -z "$slug" ]] && continue
			local m cu
			m=$(gh pr list \
				--repo "$slug" \
				--author "$runner_login" \
				--label "origin:worker" \
				--state merged \
				--search "created:>${window_start}" \
				--json number \
				--jq 'length' \
				--limit 500 2>/dev/null || echo "0")
			merged_count=$(( merged_count + ${m:-0} ))
			cu=$(gh pr list \
				--repo "$slug" \
				--author "$runner_login" \
				--label "origin:worker" \
				--state closed \
				--search "created:>${window_start}" \
				--json mergedAt \
				--jq '[.[] | select(.mergedAt == null)] | length' \
				--limit 500 2>/dev/null || echo "0")
			closed_unmerged_count=$(( closed_unmerged_count + ${cu:-0} ))
		done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only != true)) | .slug' "$repos_file" 2>/dev/null)
	fi
	local metrics_file="${HOME}/.aidevops/logs/headless-runtime-metrics.jsonl"
	if [[ -f "$metrics_file" ]]; then
		killed_count=$(METRICS_PATH="$metrics_file" EPOCH="$window_epoch" \
			python3 - 2>/dev/null <<'PY'
import json, os
metrics_path = os.environ["METRICS_PATH"]
epoch = int(os.environ["EPOCH"])
count = 0
with open(metrics_path) as f:
    for line in f:
        try:
            d = json.loads(line)
            if d.get("ts", 0) >= epoch and d.get("exit_code") == 124:
                count += 1
        except Exception:
            pass
print(count)
PY
		)
		killed_count="${killed_count:-0}"
	fi
	local total_count=$(( merged_count + closed_unmerged_count + killed_count ))
	local rate_display
	if [[ "$total_count" -lt 5 ]]; then
		rate_display="—"
	else
		local rate_int=$(( 100 * merged_count / total_count ))
		rate_display="${rate_int}% (${merged_count}/${total_count})"
	fi
	printf '%d\t%d\t%s\n' "$merged_count" "$total_count" "$rate_display"
	return 0
}

#######################################
# Build the health issue body markdown.
#
# Arguments:
#   $1  - now_iso
#   $2  - role_display
#   $3  - runner_user
#   $4  - repo_slug
#   $5  - pr_count
#   $6  - assigned_issue_count
#   $7  - total_issue_count
#   $8  - worker_count
#   $9  - max_workers
#   $10 - wt_count
#   $11 - session_count
#   $12 - session_warning
#   $13 - prs_md
#   $14 - workers_md
#   $15 - person_stats_md
#   $16 - cross_repo_person_stats_md
#   $17 - session_time_md
#   $18 - cross_repo_session_time_md
#   $19 - activity_md
#   $20 - cross_repo_md
#   $21 - sys_load_ratio
#   $22 - sys_cpu_cores
#   $23 - sys_load_1m
#   $24 - sys_load_5m
#   $25 - sys_memory
#   $26 - sys_procs
#   $27 - runner_role
#   $28 - worker_success_rate_24h  (display string: "X% (M/T)" or "—")
#   $29 - worker_success_rate_7d   (display string: "X% (M/T)" or "—")
#   $30 - worker_total_runs_24h    (numeric total run count for 24h window)
#   $31 - worker_total_runs_7d     (numeric total run count for 7d window)
# Output: body markdown to stdout
#######################################
_build_health_issue_body() {
	local now_iso="$1"
	local role_display="$2"
	local runner_user="$3"
	local repo_slug="$4"
	local pr_count="$5"
	local assigned_issue_count="$6"
	local total_issue_count="$7"
	local worker_count="$8"
	local max_workers="$9"
	local wt_count="${10}"
	local session_count="${11}"
	local session_warning="${12}"
	local prs_md="${13}" workers_md="${14}"
	local person_stats_md="${15}" cross_repo_person_stats_md="${16}"
	local session_time_md="${17}" cross_repo_session_time_md="${18}"
	local activity_md="${19}" cross_repo_md="${20}"
	local sys_load_ratio="${21}"
	local sys_cpu_cores="${22}"
	local sys_load_1m="${23}"
	local sys_load_5m="${24}"
	local sys_memory="${25}"
	local sys_procs="${26}"
	local runner_role="${27}"
	local worker_success_rate_24h="${28}" worker_success_rate_7d="${29}"
	local worker_total_runs_24h="${30}" worker_total_runs_7d="${31}"
	local _worker_rate_section; _worker_rate_section=$(_format_worker_rate_section \
		"$worker_success_rate_24h" "$worker_success_rate_7d" \
		"$worker_total_runs_24h" "$worker_total_runs_7d")

	cat <<BODY
## Queue Health Dashboard

**Last pulse**: \`${now_iso}\`
**${role_display}**: \`${runner_user}\`
**Repo**: \`${repo_slug}\`

<!-- aidevops:dashboard-freshness -->
last_refresh: ${now_iso}

### Summary

| Metric | Count |
| --- | --- |
| Open PRs | ${pr_count} |
| Assigned Issues | ${assigned_issue_count} |
| Total Issues | ${total_issue_count} |
| Active Workers | ${worker_count} |
| Max Workers | ${max_workers} |
| Worktrees | ${wt_count} |
| Interactive Sessions | ${session_count}${session_warning} |

### Open PRs

${prs_md}

### Active Workers

${workers_md}

### Worker Success Rate

${_worker_rate_section}

### GitHub activity on this project (last 30 days)

${person_stats_md:-_Person stats unavailable._}

### GitHub activity on all projects (last 30 days)

${cross_repo_person_stats_md:-_Cross-repo person stats unavailable._}

### Work with AI sessions on this project (${runner_user})

${session_time_md}

### Work with AI sessions on all projects (${runner_user})

${cross_repo_session_time_md:-_Single repo or cross-repo session data unavailable._}

### Commits to this project (last 30 days)

${activity_md}

### Commits to all projects (last 30 days)

${cross_repo_md:-_Single repo or cross-repo data unavailable._}

### System Resources

| Metric | Value |
| --- | --- |
| CPU | ${sys_load_ratio}% used (${sys_cpu_cores} cores, load: ${sys_load_1m}/${sys_load_5m}) |
| Memory | ${sys_memory} |
| Processes | ${sys_procs} |

---
_Auto-updated by ${runner_role} stats process. Do not edit manually._
BODY
	return 0
}

#######################################
# Update the health issue title if the stats have changed.
#
# Avoids unnecessary API calls by comparing the stats portion of the
# title (stripping the timestamp) before issuing an edit.
#
# Arguments:
#   $1 - health_issue_number
#   $2 - repo_slug
#   $3 - runner_prefix
#   $4 - pr_count
#   $5 - pr_label
#   $6 - assigned_issue_count
#   $7 - worker_count
#   $8 - worker_label
#######################################
_update_health_issue_title() {
	local health_issue_number="$1"
	local repo_slug="$2"
	local runner_prefix="$3"
	local pr_count="$4"
	local pr_label="$5"
	local assigned_issue_count="$6"
	local worker_count="$7"
	local worker_label="$8"

	local title_parts="${pr_count} ${pr_label}, ${assigned_issue_count} assigned, ${worker_count} ${worker_label}"
	local title_time
	title_time=$(date -u +"%H:%M")
	local health_title="${runner_prefix} ${title_parts} at ${title_time} UTC"

	local current_title=""
	local view_output
	view_output=$(gh_issue_view "$health_issue_number" --repo "$repo_slug" --json title --jq '.title' 2>&1)
	local view_exit_code=$?
	if [[ $view_exit_code -eq 0 ]]; then
		current_title="$view_output"
	else
		echo "[stats] Health issue: failed to view title for #${health_issue_number}: ${view_output}" >>"$LOGFILE"
	fi

	local current_stats="${current_title% at [0-9][0-9]:[0-9][0-9] UTC}"
	local new_stats="${health_title% at [0-9][0-9]:[0-9][0-9] UTC}"
	if [[ "$current_stats" != "$new_stats" ]]; then
		local title_edit_stderr
		title_edit_stderr=$(gh_issue_edit_safe "$health_issue_number" --repo "$repo_slug" --title "$health_title" 2>&1 >/dev/null)
		local title_edit_exit_code=$?
		if [[ $title_edit_exit_code -ne 0 ]]; then
			echo "[stats] Health issue: failed to update title for #${health_issue_number}: ${title_edit_stderr}" >>"$LOGFILE"
		fi
	fi

	return 0
}

#######################################
# Gather commit activity and session-time markdown for a single repo.
#
# Arguments:
#   $1 - repo path
#   $2 - slug_safe (slug with / replaced by -)
# Output: activity_md to stdout
#######################################
_gather_activity_stats_for_repo() {
	local repo_path="$1"
	local activity_helper="${HOME}/.aidevops/agents/scripts/contributor-activity-helper.sh"
	if [[ -x "$activity_helper" ]]; then
		bash "$activity_helper" summary "$repo_path" --period month --format markdown || echo "_Activity data unavailable._"
	else
		echo "_Activity helper not installed._"
	fi
	return 0
}

#######################################
# Gather session-time markdown for a single repo.
#
# Arguments:
#   $1 - repo path
# Output: session_time_md to stdout
#######################################
_gather_session_time_for_repo() {
	local repo_path="$1"
	local activity_helper="${HOME}/.aidevops/agents/scripts/contributor-activity-helper.sh"
	if [[ -x "$activity_helper" ]]; then
		bash "$activity_helper" session-time "$repo_path" --period all --format markdown || echo "_Session data unavailable._"
	else
		echo "_Activity helper not installed._"
	fi
	return 0
}

#######################################
# Read person-stats from the hourly cache for a repo.
#
# Arguments:
#   $1 - slug_safe (slug with / replaced by -)
# Output: person_stats_md to stdout
#######################################
_read_person_stats_cache() {
	local slug_safe="$1"
	local ps_cache="${PERSON_STATS_CACHE_DIR}/person-stats-cache-${slug_safe}.md"
	if [[ -f "$ps_cache" ]]; then
		cat "$ps_cache"
	else
		echo "_Person stats not yet cached._"
	fi
	return 0
}

#######################################
# Gather all stats and assemble the health issue body markdown.
#
# Combines _gather_health_stats, activity helpers, and _build_health_issue_body
# into a single call to keep _update_health_issue_for_repo under 100 lines.
#
# Arguments:
#   $1  - repo_slug
#   $2  - repo_path
#   $3  - runner_user
#   $4  - slug_safe
#   $5  - now_iso
#   $6  - role_display
#   $7  - runner_role
#   $8  - cross_repo_md
#   $9  - cross_repo_session_time_md
#   $10 - cross_repo_person_stats_md
# Output: body markdown to stdout
#######################################
_assemble_health_issue_body() {
	local repo_slug="$1"
	local repo_path="$2"
	local runner_user="$3"
	local slug_safe="$4"
	local now_iso="$5"
	local role_display="$6"
	local runner_role="$7"
	local cross_repo_md="$8"
	local cross_repo_session_time_md="$9"
	local cross_repo_person_stats_md="${10}"

	# Gather live stats via temp file (avoids subshell variable loss)
	local stats_tmp
	stats_tmp=$(mktemp)
	_gather_health_stats "$repo_slug" "$repo_path" "$runner_user" >"$stats_tmp"

	local pr_count prs_md assigned_issue_count total_issue_count
	local workers_md worker_count sys_load_ratio sys_cpu_cores
	local sys_load_1m sys_load_5m sys_memory sys_procs
	local wt_count max_workers session_count session_warning
	local stats_field
	local -a stats_fields=()
	while IFS= read -r -d '' stats_field; do
		stats_fields+=("$stats_field")
	done <"$stats_tmp"

	pr_count="${stats_fields[0]:-0}"
	prs_md="${stats_fields[1]:-_No open PRs_}"
	assigned_issue_count="${stats_fields[2]:-0}"
	total_issue_count="${stats_fields[3]:-0}"
	workers_md="${stats_fields[4]:-_No active workers_}"
	worker_count="${stats_fields[5]:-0}"
	sys_load_ratio="${stats_fields[6]:-0}"
	sys_cpu_cores="${stats_fields[7]:-0}"
	sys_load_1m="${stats_fields[8]:-0.00}"
	sys_load_5m="${stats_fields[9]:-0.00}"
	sys_memory="${stats_fields[10]:-unknown}"
	sys_procs="${stats_fields[11]:-0}"
	wt_count="${stats_fields[12]:-0}"
	max_workers="${stats_fields[13]:-?}"
	session_count="${stats_fields[14]:-0}"
	session_warning="${stats_fields[15]:-}"
	rm -f "$stats_tmp"

	local activity_md session_time_md person_stats_md
	activity_md=$(_gather_activity_stats_for_repo "$repo_path" "$slug_safe")
	session_time_md=$(_gather_session_time_for_repo "$repo_path")
	person_stats_md=$(_read_person_stats_cache "$slug_safe")

	local sr24h_raw sr7d_raw
	sr24h_raw=$(_compute_worker_success_rates "$runner_user" "24")
	sr7d_raw=$(_compute_worker_success_rates "$runner_user" "168")
	local worker_success_rate_24h worker_total_runs_24h
	worker_success_rate_24h=$(printf '%s' "$sr24h_raw" | cut -f3)
	worker_total_runs_24h=$(printf '%s' "$sr24h_raw" | cut -f2)
	local worker_success_rate_7d worker_total_runs_7d
	worker_success_rate_7d=$(printf '%s' "$sr7d_raw" | cut -f3)
	worker_total_runs_7d=$(printf '%s' "$sr7d_raw" | cut -f2)

	_build_health_issue_body \
		"$now_iso" "$role_display" "$runner_user" "$repo_slug" \
		"$pr_count" "$assigned_issue_count" "$total_issue_count" \
		"$worker_count" "$max_workers" "$wt_count" \
		"$session_count" "$session_warning" \
		"$prs_md" "$workers_md" \
		"$person_stats_md" "$cross_repo_person_stats_md" \
		"$session_time_md" "$cross_repo_session_time_md" \
		"$activity_md" "$cross_repo_md" \
		"$sys_load_ratio" "$sys_cpu_cores" "$sys_load_1m" "$sys_load_5m" \
		"$sys_memory" "$sys_procs" "$runner_role" \
		"$worker_success_rate_24h" "$worker_success_rate_7d" \
		"$worker_total_runs_24h" "$worker_total_runs_7d"
	return 0
}

#######################################
# Resolve role-specific config variables for a runner.
#
# Outputs pipe-delimited fields:
#   runner_prefix|role_label|role_label_color|role_label_desc|role_display
#
# Arguments:
#   $1 - runner_user
#   $2 - runner_role (supervisor|contributor)
#######################################
_resolve_runner_role_config() {
	local runner_user="$1"
	local runner_role="$2"

	local runner_prefix role_label role_label_color role_label_desc role_display
	if [[ "$runner_role" == "supervisor" ]]; then
		runner_prefix="[Supervisor:${runner_user}]"
		role_label="supervisor"
		role_label_color="1D76DB"
		role_label_desc="Supervisor health dashboard"
		role_display="Supervisor"
	else
		runner_prefix="[Contributor:${runner_user}]"
		role_label="contributor"
		role_label_color="A2EEEF"
		role_label_desc="Contributor health dashboard"
		role_display="Contributor"
	fi

	printf '%s|%s|%s|%s|%s' \
		"$runner_prefix" "$role_label" "$role_label_color" \
		"$role_label_desc" "$role_display"
	return 0
}

#######################################
# Ensure the active health issue is pinned (supervisor-only).
#
# Unpins closed/stale issues to free pin slots (max 3 per repo),
# then pins the active issue idempotently.
#
# Arguments:
#   $1 - health_issue_number
#   $2 - repo_slug
#   $3 - runner_user (for _cleanup_stale_pinned_issues)
#######################################
_ensure_health_issue_pinned() {
	local health_issue_number="$1"
	local repo_slug="$2"
	local runner_user="$3"

	_cleanup_stale_pinned_issues "$repo_slug" "$runner_user"

	local active_node_id
	active_node_id=$(gh_issue_view "$health_issue_number" --repo "$repo_slug" \
		--json id --jq '.id' 2>/dev/null || echo "")
	if [[ -n "$active_node_id" ]]; then
		gh api graphql -f query="
			mutation {
				pinIssue(input: {issueId: \"${active_node_id}\"}) {
					issue { number }
				}
			}" >/dev/null 2>&1 || true
	fi
	return 0
}

#######################################
# Extract headline counts from a rendered health issue body.
#
# Parses the Summary table rows for Open PRs, Assigned Issues,
# and Active Workers to avoid re-running stats queries.
#
# Arguments:
#   $1 - body (multiline markdown string)
# Output: "pr_count|assigned_issue_count|worker_count"
#######################################
_extract_body_counts() {
	local body="$1"

	local pr_count=0
	local assigned_issue_count=0
	local worker_count=0
	local body_line
	while IFS= read -r body_line; do
		if [[ "$body_line" =~ ^\|\ Open\ PRs\ \|\ ([0-9]+)\ \|$ ]]; then
			pr_count="${BASH_REMATCH[1]}"
		elif [[ "$body_line" =~ ^\|\ Assigned\ Issues\ \|\ ([0-9]+)\ \|$ ]]; then
			assigned_issue_count="${BASH_REMATCH[1]}"
		elif [[ "$body_line" =~ ^\|\ Active\ Workers\ \|\ ([0-9]+)\ \|$ ]]; then
			worker_count="${BASH_REMATCH[1]}"
		fi
	done <<<"$body"

	printf '%s|%s|%s' "$pr_count" "$assigned_issue_count" "$worker_count"
	return 0
}

#######################################
# Update pinned health issue for a single repo
#
# Creates or updates a pinned GitHub issue with live status:
#   - Open PRs and issues counts
#   - Active headless workers (from ps)
#   - System resources (CPU, RAM)
#   - Last pulse timestamp
#
# One issue per runner (GitHub user) per repo. Uses labels
# "supervisor" or "contributor" + "$runner_user" for dedup.
# Issue number cached in ~/.aidevops/logs/ to avoid repeated lookups.
#
# Maintainers get [Supervisor:user] issues; non-maintainers get
# [Contributor:user] issues. Role determined by _get_runner_role().
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - repo path (local filesystem)
#   $3 - cross-repo activity markdown (pre-computed by update_health_issues)
#   $4 - cross-repo session time markdown (pre-computed by update_health_issues)
#   $5 - cross-repo person stats markdown (pre-computed by update_health_issues)
# Returns: 0 always (best-effort, never breaks the pulse)
#######################################
# t2687: extracted activity guard — returns 0 to proceed, 1 to skip.
# Only runs when the cached health-issue file is absent (would create a new one).
_check_health_issue_activity_guard() {
	local repo_slug="$1"
	local repo_path="$2"
	local runner_user="$3"
	local health_issue_file="$4"

	[[ -f "$health_issue_file" ]] && return 0

	local guard_pr_count guard_assigned_count guard_worker_count
	guard_pr_count=$(gh pr list --repo "$repo_slug" --state open \
		--json number --jq 'length' 2>/dev/null || echo "0")
	guard_assigned_count=$(gh_issue_list --repo "$repo_slug" \
		--assignee "$runner_user" --state open \
		--json number --jq 'length' 2>/dev/null || echo "0")

	local _guard_fields=()
	while IFS= read -r -d '' _gf; do
		_guard_fields+=("$_gf")
	done < <(_scan_active_workers "${repo_path:-}")
	guard_worker_count="${_guard_fields[1]:-0}"

	if [[ "${guard_pr_count:-0}" -eq 0 && "${guard_assigned_count:-0}" -eq 0 && "${guard_worker_count:-0}" -eq 0 ]]; then
		echo "[stats] Health issue: skipping creation for ${repo_slug} — no active PRs, issues, or workers" \
			>>"${LOGFILE:-/dev/null}"
		return 1
	fi
	return 0
}

_update_health_issue_for_repo() {
	local repo_slug="$1"
	local repo_path="$2"
	local cross_repo_md="${3:-}"
	local cross_repo_session_time_md="${4:-}"
	local cross_repo_person_stats_md="${5:-}"

	[[ -z "$repo_slug" ]] && return 0

	local runner_user
	runner_user=$(gh api user --jq '.login' || whoami)

	local runner_role
	runner_role=$(_get_runner_role "$runner_user" "$repo_slug")

	local role_config runner_prefix role_label role_label_color role_label_desc role_display
	role_config=$(_resolve_runner_role_config "$runner_user" "$runner_role")
	IFS='|' read -r runner_prefix role_label role_label_color role_label_desc role_display \
		<<<"$role_config"

	local slug_safe="${repo_slug//\//-}"
	local cache_dir="${HOME}/.aidevops/logs"
	local health_issue_file="${cache_dir}/health-issue-${runner_user}-${role_label}-${slug_safe}"
	mkdir -p "$cache_dir"

	_check_health_issue_activity_guard \
		"$repo_slug" "$repo_path" "$runner_user" "$health_issue_file" || return 0

	local health_issue_number
	health_issue_number=$(_resolve_health_issue_number \
		"$repo_slug" "$runner_user" "$runner_role" "$runner_prefix" \
		"$role_label" "$role_label_color" "$role_label_desc" \
		"$role_display" "$health_issue_file")
	[[ -z "$health_issue_number" ]] && return 0

	# t2687: periodic dedup scan (at most once per HEALTH_DEDUP_INTERVAL
	# seconds per repo+runner+role, default 1h). Closes duplicates that
	# slipped in during past GraphQL rate-limit windows when the cache
	# was valid so the label-scan inside _find_health_issue never ran.
	_periodic_health_issue_dedup \
		"$repo_slug" "$runner_user" "$runner_role" \
		"$role_label" "$role_display" "$health_issue_number"

	if [[ "$runner_role" == "supervisor" ]]; then
		_ensure_health_issue_pinned "$health_issue_number" "$repo_slug" "$runner_user"
	fi

	echo "$health_issue_number" >"$health_issue_file"

	local now_iso
	now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	local body
	body=$(_assemble_health_issue_body \
		"$repo_slug" "$repo_path" "$runner_user" "$slug_safe" \
		"$now_iso" "$role_display" "$runner_role" \
		"$cross_repo_md" "$cross_repo_session_time_md" "$cross_repo_person_stats_md")

	local body_edit_stderr
	body_edit_stderr=$(gh issue edit "$health_issue_number" --repo "$repo_slug" \
		--body "$body" 2>&1 >/dev/null) || {
		echo "[stats] Health issue: failed to update body for #${health_issue_number}: ${body_edit_stderr}" \
			>>"$LOGFILE"
		return 0
	}

	# Re-extract headline counts from the rendered body to build the title.
	# Avoids relying on function-local variables from _assemble_health_issue_body.
	local counts_raw pr_count assigned_issue_count worker_count
	counts_raw=$(_extract_body_counts "$body")
	IFS='|' read -r pr_count assigned_issue_count worker_count <<<"$counts_raw"

	local pr_label="PRs"
	[[ "$pr_count" -eq 1 ]] && pr_label="PR"
	local worker_label="workers"
	[[ "$worker_count" -eq 1 ]] && worker_label="worker"

	_update_health_issue_title \
		"$health_issue_number" "$repo_slug" "$runner_prefix" \
		"$pr_count" "$pr_label" "$assigned_issue_count" \
		"$worker_count" "$worker_label"

	return 0
}

#######################################
# Unpin closed/stale supervisor issues to free pin slots
#
# GitHub allows max 3 pinned issues per repo. Old supervisor issues
# that were closed (manually or by dedup) may still be pinned, blocking
# the active health issue from being pinned. This function finds all
# pinned issues in the repo and unpins any that are closed.
#
# Arguments:
#   $1 - repo slug
#   $2 - runner user (for logging)
#######################################
_cleanup_stale_pinned_issues() {
	local repo_slug="$1"
	local runner_user="$2"
	local owner="${repo_slug%%/*}"
	local name="${repo_slug##*/}"

	# Query all pinned issues via GraphQL (parameterized to prevent injection)
	local pinned_json
	pinned_json=$(gh api graphql -F owner="$owner" -F name="$name" -f query="
		query(\$owner: String!, \$name: String!) {
			repository(owner: \$owner, name: \$name) {
				pinnedIssues(first: 10) {
					nodes {
						issue {
							id
							number
							state
							title
						}
					}
				}
			}
		}
		" 2>>"$LOGFILE" || echo "")

	[[ -z "$pinned_json" ]] && return 0

	# Unpin any closed issues
	local closed_pinned
	closed_pinned=$(echo "$pinned_json" | jq -r '.data.repository.pinnedIssues.nodes[] | select(.issue.state == "CLOSED") | "\(.issue.id)|\(.issue.number)"' 2>/dev/null || echo "")

	[[ -z "$closed_pinned" ]] && return 0

	while IFS='|' read -r node_id issue_num; do
		[[ -z "$node_id" ]] && continue
		gh api graphql -f query="
			mutation {
				unpinIssue(input: {issueId: \"${node_id}\"}) {
					issue { number }
				}
			}" >/dev/null 2>&1 || true
		echo "[stats] Health issue: unpinned closed issue #${issue_num} in ${repo_slug}" >>"$LOGFILE"
	done <<<"$closed_pinned"

	return 0
}

#######################################
# Unpin a health issue (best-effort)
# Arguments:
#   $1 - issue number
#   $2 - repo slug
#######################################
_unpin_health_issue() {
	local issue_number="$1"
	local repo_slug="$2"

	[[ -z "$issue_number" || -z "$repo_slug" ]] && return 0

	local issue_node_id
	issue_node_id=$(gh_issue_view "$issue_number" --repo "$repo_slug" --json id --jq '.id' 2>/dev/null || echo "")
	[[ -z "$issue_node_id" ]] && return 0

	gh api graphql -f query="
		mutation {
			unpinIssue(input: {issueId: \"${issue_node_id}\"}) {
				issue { number }
			}
		}" >/dev/null 2>&1 || true

	return 0
}

#######################################
# Refresh person-stats cache (t1426)
#
# Runs at most once per PERSON_STATS_INTERVAL (default 1h).
# Computes per-repo and cross-repo person-stats, writes markdown
# to cache files. Health issue updates read from cache.
#######################################
_refresh_person_stats_cache() {
	if [[ -f "$PERSON_STATS_LAST_RUN" ]]; then
		local last_run
		last_run=$(cat "$PERSON_STATS_LAST_RUN" 2>/dev/null || echo "0")
		last_run="${last_run//[^0-9]/}"
		last_run="${last_run:-0}"
		local now
		now=$(date +%s)
		if [[ $((now - last_run)) -lt "$PERSON_STATS_INTERVAL" ]]; then
			return 0
		fi
	fi

	local activity_helper="${HOME}/.aidevops/agents/scripts/contributor-activity-helper.sh"
	[[ -x "$activity_helper" ]] || return 0

	local repos_json="$REPOS_JSON"
	[[ -f "$repos_json" ]] || return 0

	mkdir -p "$PERSON_STATS_CACHE_DIR"

	# t1426: Estimate Search API cost before calling person_stats().
	# person_stats() burns ~4 Search API requests per contributor per repo.
	# GitHub Search API limit is 30 req/min. Check remaining budget against
	# estimated cost to avoid blocking the pulse with rate-limit sleeps.
	local search_remaining
	search_remaining=$(gh api rate_limit --jq '.resources.search.remaining' 2>/dev/null) || search_remaining=0

	# Per-repo person-stats
	local repo_entries
	repo_entries=$(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | "\(.slug)|\(.path)"' "$repos_json" 2>/dev/null || echo "")

	# Count repos to estimate minimum cost (at least 1 contributor × 4 queries per repo)
	local repo_count=0
	local search_api_cost_per_contributor=4
	while IFS='|' read -r _slug _path; do
		[[ -z "$_slug" ]] && continue
		repo_count=$((repo_count + 1))
	done <<<"$repo_entries"

	# Minimum budget: repo_count × 1 contributor × 4 queries. In practice,
	# repos have 2-3 contributors, so this is a conservative lower bound.
	local min_budget_needed=$((repo_count * search_api_cost_per_contributor))
	if [[ "$search_remaining" -lt "$min_budget_needed" ]]; then
		echo "[stats] Person stats cache refresh skipped: Search API budget ${search_remaining} < estimated cost ${min_budget_needed} (${repo_count} repos × ${search_api_cost_per_contributor} queries/contributor)" >>"$LOGFILE"
		return 0
	fi

	while IFS='|' read -r slug path; do
		[[ -z "$slug" ]] && continue

		# Re-check budget before each repo — bail early if exhausted mid-refresh
		search_remaining=$(gh api rate_limit --jq '.resources.search.remaining' 2>/dev/null) || search_remaining=0
		if [[ "$search_remaining" -lt "$search_api_cost_per_contributor" ]]; then
			echo "[stats] Person stats cache refresh stopped mid-run: Search API budget exhausted (${search_remaining} remaining)" >>"$LOGFILE"
			break
		fi

		local slug_safe="${slug//\//-}"
		local cache_file="${PERSON_STATS_CACHE_DIR}/person-stats-cache-${slug_safe}.md"
		local md
		md=$(bash "$activity_helper" person-stats "$path" --period month --format markdown 2>/dev/null) || md=""
		if [[ -n "$md" ]]; then
			echo "$md" >"$cache_file"
		fi
	done <<<"$repo_entries"

	# Cross-repo person-stats — also gated on remaining budget
	search_remaining=$(gh api rate_limit --jq '.resources.search.remaining' 2>/dev/null) || search_remaining=0
	local all_repo_paths
	all_repo_paths=$(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false) | .path' "$repos_json" 2>/dev/null || echo "")
	if [[ -n "$all_repo_paths" && "$search_remaining" -ge "$search_api_cost_per_contributor" ]]; then
		local -a cross_args=()
		while IFS= read -r rp; do
			[[ -n "$rp" ]] && cross_args+=("$rp")
		done <<<"$all_repo_paths"
		if [[ ${#cross_args[@]} -gt 1 ]]; then
			local cross_md
			cross_md=$(bash "$activity_helper" cross-repo-person-stats "${cross_args[@]}" --period month --format markdown 2>/dev/null) || cross_md=""
			if [[ -n "$cross_md" ]]; then
				echo "$cross_md" >"${PERSON_STATS_CACHE_DIR}/person-stats-cache-cross-repo.md"
			fi
		fi
	fi

	date +%s >"$PERSON_STATS_LAST_RUN"
	echo "[stats] Person stats cache refreshed" >>"$LOGFILE"
	return 0
}

#######################################
# Update health issues for ALL pulse-enabled repos
#
# Iterates repos.json and calls _update_health_issue_for_repo for each
# non-local-only repo with a slug. Runs sequentially to avoid gh API
# rate limiting. Best-effort — failures in one repo don't block others.
#######################################
update_health_issues() {
	# t2044 Phase 0: dry-run sentinel. When STATS_DRY_RUN=1, return immediately
	# to exercise the call graph without making gh/git API calls. Temporary
	# scaffolding — removed after Phase 3 merges.
	if [[ "${STATS_DRY_RUN:-}" == "1" ]]; then
		echo "[stats] update_health_issues: dry-run, skipping" >>"$LOGFILE"
		return 0
	fi
	command -v gh &>/dev/null || return 0
	gh auth status &>/dev/null 2>&1 || return 0

	local repos_json="$REPOS_JSON"
	if [[ ! -f "$repos_json" ]]; then
		return 0
	fi

	local repo_entries
	repo_entries=$(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | "\(.slug)|\(.path)"' "$repos_json" 2>/dev/null || echo "")

	if [[ -z "$repo_entries" ]]; then
		return 0
	fi

	# Refresh person-stats cache if stale (t1426: hourly, not every pulse)
	_refresh_person_stats_cache || true

	# Pre-compute cross-repo summaries ONCE for all health issues.
	# This avoids N×N git log walks (one cross-repo scan per repo dashboard)
	# and redundant DB queries for session time.
	# Person stats read from cache (refreshed hourly by _refresh_person_stats_cache).
	local cross_repo_md=""
	local cross_repo_session_time_md=""
	local cross_repo_person_stats_md=""
	local activity_helper="${HOME}/.aidevops/agents/scripts/contributor-activity-helper.sh"
	if [[ -x "$activity_helper" ]]; then
		local all_repo_paths
		all_repo_paths=$(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false) | .path' "$repos_json" || echo "")
		if [[ -n "$all_repo_paths" ]]; then
			local -a cross_args=()
			while IFS= read -r rp; do
				[[ -n "$rp" ]] && cross_args+=("$rp")
			done <<<"$all_repo_paths"
			if [[ ${#cross_args[@]} -gt 1 ]]; then
				cross_repo_md=$(bash "$activity_helper" cross-repo-summary "${cross_args[@]}" --period month --format markdown || echo "_Cross-repo data unavailable._")
				cross_repo_session_time_md=$(bash "$activity_helper" cross-repo-session-time "${cross_args[@]}" --period all --format markdown || echo "_Cross-repo session data unavailable._")
			fi
		fi
	fi
	local cross_repo_cache="${PERSON_STATS_CACHE_DIR}/person-stats-cache-cross-repo.md"
	if [[ -f "$cross_repo_cache" ]]; then
		cross_repo_person_stats_md=$(cat "$cross_repo_cache")
	fi

	local updated=0
	while IFS='|' read -r slug path; do
		[[ -z "$slug" ]] && continue
		_update_health_issue_for_repo "$slug" "$path" "$cross_repo_md" "$cross_repo_session_time_md" "$cross_repo_person_stats_md" || true
		updated=$((updated + 1))
	done <<<"$repo_entries"

	if [[ "$updated" -gt 0 ]]; then
		echo "[stats] Health issues: updated $updated repo(s)" >>"$LOGFILE"
	fi
	return 0
}
