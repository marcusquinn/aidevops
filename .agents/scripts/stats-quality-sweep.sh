#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Stats Quality Sweep -- Orchestrator
# =============================================================================
# Daily code quality sweep orchestrator. Sources sub-libraries for individual
# tool integrations and issue management, and retains the entry point plus
# functions >100 lines (to preserve function-complexity identity keys).
#
# Extracted from the original monolithic stats-quality-sweep.sh:
#   - stats-quality-sweep-tools.sh   -- per-tool sweep functions
#   - stats-quality-sweep-issues.sh  -- quality issue management functions
#   - stats-quality-sweep-coverage.sh -- bot coverage + badge functions
#
# This module is sourced by stats-functions.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all stats-* configuration constants in the bootstrap
# section of stats-functions.sh.
#
# Dependencies on other stats modules:
#   - none (zero inter-cluster edges from C to A or B)
#
# Globals read:
#   - LOGFILE, REPOS_JSON, QUALITY_SWEEP_INTERVAL, QUALITY_SWEEP_LAST_RUN
#   - QUALITY_SWEEP_STATE_DIR, CODERABBIT_ISSUE_SPIKE
#   - Environment overrides: QUALITY_SWEEP_OFFPEAK, QUALITY_SWEEP_PEAK_START,
#     QUALITY_SWEEP_PEAK_END, STATS_DRY_RUN
# Globals written:
#   - none (state written to disk under ~/.aidevops/logs/)

# Include guard — prevent double-sourcing
[[ -n "${_STATS_QUALITY_SWEEP_LOADED:-}" ]] && return 0
_STATS_QUALITY_SWEEP_LOADED=1

# Defensive SCRIPT_DIR fallback — avoids external binary dependency
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Source sub-libraries ---

# shellcheck source=./stats-quality-sweep-coverage.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/stats-quality-sweep-coverage.sh"

# shellcheck source=./stats-quality-sweep-tools.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/stats-quality-sweep-tools.sh"

# shellcheck source=./stats-quality-sweep-issues.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/stats-quality-sweep-issues.sh"

# --- Orchestrator functions ---

#######################################
# Daily Code Quality Sweep
#
# Runs once per 24h (guarded by timestamp file). For each pulse-enabled
# repo, ensures a persistent "Daily Code Quality Review" issue exists,
# then runs available quality tools and posts a summary comment.
#
# Tools checked (in order):
#   1. ShellCheck — local, always available for repos with .sh files
#   2. Qlty CLI — local, if installed (~/.qlty/bin/qlty)
#   3. CodeRabbit — via @coderabbitai mention on the persistent issue
#   4. Codacy — via API if CODACY_API_TOKEN available
#   5. SonarCloud — via API if sonar-project.properties exists
#
# The sweep creates function-complexity-debt issues directly (with
# source:quality-sweep label). The pulse LLM dispatches these as normal
# work — it should NOT independently create issues for the same findings.
# See GH#10308 for the sweep-pulse dedup contract.
#######################################
run_daily_quality_sweep() {
	# t2044 Phase 0: dry-run sentinel. When STATS_DRY_RUN=1, return immediately
	# to exercise the call graph without making gh/git API calls. Temporary
	# scaffolding — removed after Phase 3 merges.
	if [[ "${STATS_DRY_RUN:-}" == "1" ]]; then
		echo "[stats] run_daily_quality_sweep: dry-run, skipping" >>"$LOGFILE"
		return 0
	fi
	# Time-of-day gate — only run during Anthropic's 2x usage boost hours.
	# Claude doubles usage allowance outside peak: for UK/GMT that's 18:00-11:59
	# (standard 1x is only 12:00-17:59). Weekends are 2x all day, all timezones.
	# Reference: https://claude.ai — "Claude 2x usage boost" schedule.
	# Peak hours by timezone (standard 1x only):
	#   Pacific PT:  05:00-10:59    UK GMT:     12:00-17:59
	#   Eastern ET:  08:00-13:59    CET:        13:00-18:59
	# Quality sweep findings trigger LLM worker dispatch via the pulse, so
	# landing findings in the 2x window means workers also run at boosted rates.
	# Override: QUALITY_SWEEP_OFFPEAK=0
	local current_hour current_dow
	current_hour=$(date +%H)
	current_dow=$(date +%u) # 1=Monday, 7=Sunday
	# Weekends (Sat=6, Sun=7) are 2x all day — always run
	if [[ "${QUALITY_SWEEP_OFFPEAK:-1}" == "1" ]] && ((current_dow < 6)); then
		# Weekday: defer during peak hours only (12:00-17:59 UK/GMT).
		# Users in other timezones can override via QUALITY_SWEEP_PEAK_START
		# and QUALITY_SWEEP_PEAK_END environment variables.
		local peak_start peak_end
		peak_start="${QUALITY_SWEEP_PEAK_START:-12}"
		peak_end="${QUALITY_SWEEP_PEAK_END:-18}"
		if ((10#$current_hour >= 10#$peak_start && 10#$current_hour < 10#$peak_end)); then
			echo "[stats] Quality sweep deferred: hour ${current_hour} is peak (${peak_start}:00-$((peak_end - 1)):59), 2x boost inactive" >>"$LOGFILE"
			return 0
		fi
	fi

	# Timestamp guard — run at most once per QUALITY_SWEEP_INTERVAL
	if [[ -f "$QUALITY_SWEEP_LAST_RUN" ]]; then
		local last_run
		last_run=$(cat "$QUALITY_SWEEP_LAST_RUN" || echo "0")
		# Strip whitespace/newlines and validate integer (t1397)
		last_run="${last_run//[^0-9]/}"
		last_run="${last_run:-0}"
		local now
		now=$(date +%s)
		local elapsed=$((now - last_run))
		if [[ "$elapsed" -lt "$QUALITY_SWEEP_INTERVAL" ]]; then
			return 0
		fi
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

	echo "[stats] Starting daily code quality sweep..." >>"$LOGFILE"

	local swept=0
	while IFS='|' read -r slug path; do
		[[ -z "$slug" ]] && continue
		[[ ! -d "$path" ]] && continue
		_quality_sweep_for_repo "$slug" "$path" || true
		swept=$((swept + 1))
	done <<<"$repo_entries"

	# Update timestamp
	date +%s >"$QUALITY_SWEEP_LAST_RUN"

	echo "[stats] Quality sweep complete: $swept repo(s) swept" >>"$LOGFILE"
	return 0
}

#######################################
# Run Qlty CLI analysis on a repo.
#
# t2066: local SARIF smell count is the PRIMARY grade source. The Qlty Cloud
# badge is fetched best-effort as secondary telemetry and appended to the
# section only when it disagrees with the local grade (so the dashboard
# surfaces the divergence when it exists, but does not pollute the common
# case where they agree). The cloud badge is NEVER used as the primary grade
# — it has been observed 404'ing in production, leaving the dashboard
# reporting "Qlty grade UNKNOWN" while the local SARIF had the exact count
# in hand.
#
# Arguments:
#   $1 - repo slug
#   $2 - repo path
# Sets caller variables via stdout (pipe-delimited):
#   qlty_section|qlty_smell_count|qlty_grade
# where qlty_grade is the LOCAL-COMPUTED grade.
#######################################
_sweep_qlty() {
	local repo_slug="$1"
	local repo_path="$2"

	local qlty_bin="${HOME}/.qlty/bin/qlty"
	if [[ ! -x "$qlty_bin" ]] || [[ ! -f "${repo_path}/.qlty/qlty.toml" && ! -f "${repo_path}/.qlty.toml" ]]; then
		printf '%s|%s|%s' "" "0" "UNKNOWN"
		return 0
	fi

	# Use SARIF output for machine-parseable smell data (structured by rule, file, location)
	local qlty_sarif
	qlty_sarif=$("$qlty_bin" smells --all --sarif --no-snippets --quiet 2>/dev/null) || qlty_sarif=""

	local qlty_smell_count=0
	local qlty_grade="UNKNOWN"
	local qlty_section=""

	if [[ -n "$qlty_sarif" ]] && echo "$qlty_sarif" | jq -e '.runs' &>/dev/null; then
		# Single jq pass: extract total count, per-rule breakdown, and top files
		local qlty_data
		qlty_data=$(echo "$qlty_sarif" | jq -r '
			(.runs[0].results | length) as $total |
			([.runs[0].results[] | .ruleId] | group_by(.) | map({rule: .[0], count: length}) | sort_by(-.count)[:8] |
				map("  - \(.rule): \(.count)") | join("\n")) as $rules |
			([.runs[0].results[] | .locations[0].physicalLocation.artifactLocation.uri] |
				group_by(.) | map({file: .[0], count: length}) | sort_by(-.count)[:10] |
				map("  - `\(.file)`: \(.count) smells") | join("\n")) as $files |
			"\($total)|\($rules)|\($files)"
		') || qlty_data="0||"
		qlty_smell_count="${qlty_data%%|*}"
		local qlty_remainder="${qlty_data#*|}"
		local qlty_rules_breakdown="${qlty_remainder%%|*}"
		local qlty_files_breakdown="${qlty_remainder#*|}"
		[[ "$qlty_smell_count" =~ ^[0-9]+$ ]] || qlty_smell_count=0
		qlty_rules_breakdown=$(_sanitize_markdown "$qlty_rules_breakdown")
		qlty_files_breakdown=$(_sanitize_markdown "$qlty_files_breakdown")

		# t2066: compute grade from local count BEFORE building the section so
		# we can put the authoritative grade into the markdown.
		qlty_grade=$(_compute_qlty_grade_from_count "$qlty_smell_count")

		qlty_section="### Qlty Maintainability

- **Total smells**: ${qlty_smell_count}
- **Grade (local, from count)**: ${qlty_grade}
- **By rule (fix these for maximum grade improvement)**:
${qlty_rules_breakdown}
- **Top files (highest smell density)**:
${qlty_files_breakdown}
"
		if [[ "$qlty_smell_count" -eq 0 ]]; then
			qlty_section="### Qlty Maintainability

- **Total smells**: 0
- **Grade (local, from count)**: ${qlty_grade}

_No smells detected — clean codebase._
"
		fi
	else
		qlty_section="### Qlty Maintainability

_Qlty analysis returned empty or failed to parse._
"
	fi

	# Fetch the Qlty Cloud badge grade (best-effort secondary telemetry).
	# Short timeout so a slow/unreachable badge doesn't stall the sweep.
	# t2066: this is NO LONGER the primary grade source — it is only reported
	# below if the badge is reachable AND disagrees with the local grade.
	local cloud_grade="UNKNOWN"
	local badge_svg
	badge_svg=$(curl -sS --fail --connect-timeout 5 --max-time 10 \
		"https://qlty.sh/gh/${repo_slug}/maintainability.svg" 2>/dev/null) || badge_svg=""
	if [[ -n "$badge_svg" ]]; then
		# Grade colour mapping from Qlty's badge palette.
		cloud_grade=$(python3 -c "
import sys, re
svg = sys.stdin.read()
colors = {'#22C55E':'A','#84CC16':'B','#EAB308':'C','#F97316':'D','#EF4444':'F'}
for c in re.findall(r'fill=\"(#[A-F0-9]+)\"', svg):
    if c in colors:
        print(colors[c])
        sys.exit(0)
print('UNKNOWN')
" <<<"$badge_svg" 2>/dev/null) || cloud_grade="UNKNOWN"
	fi

	# Only surface the cloud grade when it disagrees with the local grade.
	# When they agree (the common case), omit the line to keep the section
	# short. When they diverge, the line flags it as telemetry — not used
	# as the primary grade.
	if [[ "$cloud_grade" != "UNKNOWN" && "$cloud_grade" != "$qlty_grade" ]]; then
		qlty_section="${qlty_section}
- **Qlty Cloud grade (telemetry, diverges from local)**: ${cloud_grade}
"
	fi

	# --- 2b. Function-complexity-debt bridge (code-simplifier pipeline) ---
	# For files with high smell density, auto-create function-complexity-debt issues
	# with needs-maintainer-review label. This bridges the daily sweep to the
	# code-simplifier's human-gated dispatch pipeline (see code-simplifier.md).
	# Deduplicates against existing issues. Caps are tuned for throughput:
	# see _create_simplification_issues for the numbers.
	if [[ -n "$qlty_sarif" && "$qlty_smell_count" -gt 0 ]]; then
		_create_simplification_issues "$repo_slug" "$qlty_sarif"
	fi

	printf '%s|%s|%s' "$qlty_section" "$qlty_smell_count" "$qlty_grade"
	return 0
}

#######################################
# Run SonarCloud quality gate check for a repo.
#
# Arguments:
#   $1 - repo path
# Output: pipe-delimited
#   "sonar_section|sweep_gate_status|sweep_total_issues|sweep_high_critical|sweep_sev_inline"
# t2717: sweep_sev_inline is a single-line per-severity summary for the
# dashboard (e.g., "0 BLOCKER · 0 CRITICAL · 98 MAJOR · 196 MINOR · 0 INFO").
# Empty on early-return paths where no SonarCloud data was fetched.
#######################################
_sweep_sonarcloud() {
	local repo_path="$1"

	local sonar_section=""
	local sweep_gate_status="UNKNOWN"
	local sweep_total_issues=0
	local sweep_high_critical=0
	local sweep_sev_inline=""

	[[ -f "${repo_path}/sonar-project.properties" ]] || {
		printf '%s|%s|%s|%s|%s' "$sonar_section" "$sweep_gate_status" "$sweep_total_issues" "$sweep_high_critical" "$sweep_sev_inline"
		return 0
	}

	local project_key
	project_key=$(grep '^sonar.projectKey=' "${repo_path}/sonar-project.properties" 2>/dev/null | cut -d= -f2)
	local org_key
	org_key=$(grep '^sonar.organization=' "${repo_path}/sonar-project.properties" 2>/dev/null | cut -d= -f2)

	if [[ -z "$project_key" || -z "$org_key" ]]; then
		printf '%s|%s|%s|%s|%s' "$sonar_section" "$sweep_gate_status" "$sweep_total_issues" "$sweep_high_critical" "$sweep_sev_inline"
		return 0
	fi

	# URL-encode project_key to prevent injection via crafted sonar-project.properties
	local encoded_project_key
	encoded_project_key=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$project_key" 2>/dev/null) || encoded_project_key=""
	if [[ -z "$encoded_project_key" ]]; then
		echo "[stats] Failed to URL-encode project_key — skipping SonarCloud" >&2
		printf '%s|%s|%s|%s|%s' "$sonar_section" "$sweep_gate_status" "$sweep_total_issues" "$sweep_high_critical" "$sweep_sev_inline"
		return 0
	fi

	# SonarCloud public API — quality gate status
	local sonar_status=""
	sonar_status=$(curl -sS --fail --connect-timeout 5 --max-time 20 \
		"https://sonarcloud.io/api/qualitygates/project_status?projectKey=${encoded_project_key}" || echo "")

	if [[ -n "$sonar_status" ]] && echo "$sonar_status" | jq -e '.projectStatus' &>/dev/null; then
		# Single jq pass: extract gate status, conditions, and failing conditions with remediation
		local gate_data
		gate_data=$(echo "$sonar_status" | jq -r '
			(.projectStatus.status // "UNKNOWN") as $status |
			[.projectStatus.conditions[]? | "- **\(.metricKey)**: \(.actualValue) (\(.status))"] | join("\n") as $conds |
			"\($status)|\($conds)"
		') || gate_data="UNKNOWN|"
		local gate_status="${gate_data%%|*}"
		local conditions="${gate_data#*|}"
		# Sanitise API data before embedding in markdown comment
		gate_status=$(_sanitize_markdown "$gate_status")
		conditions=$(_sanitize_markdown "$conditions")
		sweep_gate_status="$gate_status"

		sonar_section="### SonarCloud Quality Gate

- **Status**: ${gate_status}
${conditions}
"
		# Badge-aware diagnostics: when the gate fails, identify the
		# specific failing conditions and provide actionable remediation.
		if [[ "$gate_status" == "ERROR" || "$gate_status" == "WARN" ]]; then
			sonar_section="${sonar_section}$(_sweep_sonarcloud_diagnostics "$sonar_status" "$encoded_project_key")"
		fi
	fi

	# Fetch open issues summary with rule-level breakdown for targeted fixes
	# t2717: parse the 4-field return (total|hc|sev_inline|md).
	local issues_section total_issues high_critical_count sev_inline
	issues_section=$(_sweep_sonarcloud_issues "$encoded_project_key")
	total_issues="${issues_section%%|*}"
	local issues_remainder="${issues_section#*|}"
	high_critical_count="${issues_remainder%%|*}"
	issues_remainder="${issues_remainder#*|}"
	sev_inline="${issues_remainder%%|*}"
	local issues_md="${issues_remainder#*|}"
	[[ "$total_issues" =~ ^[0-9]+$ ]] || total_issues=0
	[[ "$high_critical_count" =~ ^[0-9]+$ ]] || high_critical_count=0
	sweep_total_issues="$total_issues"
	sweep_high_critical="$high_critical_count"
	sweep_sev_inline="$sev_inline"
	if [[ -n "$issues_md" ]]; then
		sonar_section="${sonar_section}${issues_md}"
	fi

	printf '%s|%s|%s|%s|%s' "$sonar_section" "$sweep_gate_status" "$sweep_total_issues" "$sweep_high_critical" "$sweep_sev_inline"
	return 0
}

#######################################
# Run all quality sweep tools for a repo and write results to a sections dir.
#
# t1992: Each section is written to its own temp file (one file per variable)
# so multi-line markdown sections survive the writer/reader round trip.
# The previous implementation used `printf '%s\n'` + `IFS= read -r` chains,
# which silently truncated every section after the first line — fragmenting
# the daily quality-sweep comment.
#
# Arguments:
#   $1 - repo slug
#   $2 - repo path
# Output (single line on stdout): the absolute path of the sections directory.
# Files written inside the sections directory (one file per variable):
#   - tool_count, shellcheck, qlty, qlty_smell_count, qlty_grade
#   - sonar, sweep_gate_status, sweep_total_issues, sweep_high_critical
#   - codacy, coderabbit, review_scan
# The caller is responsible for `rm -rf`ing the directory after consumption.
#######################################
_run_sweep_tools() {
	local repo_slug="$1"
	local repo_path="$2"

	local tool_count=0
	local sweep_gate_status="UNKNOWN"
	local sweep_total_issues=0
	local sweep_high_critical=0
	local sweep_sev_inline=""

	# t2066: capture previous smell count BEFORE running the sweep so we can
	# render a delta (trend indicator) in the dashboard. The state file is
	# written later by _save_sweep_state — we need to read it beforehand so
	# the delta reflects the change since the previous sweep, not the change
	# since a moment ago.
	local prev_state prev_qlty_smells
	prev_state=$(_load_sweep_state "$repo_slug")
	# 4th field is the previous qlty_smells (added in t2066). Missing / first
	# run returns "0" from _load_sweep_state's default.
	prev_qlty_smells=$(awk -F'|' '{print $4}' <<<"$prev_state")
	[[ "$prev_qlty_smells" =~ ^[0-9]+$ ]] || prev_qlty_smells=0

	local shellcheck_section=""
	shellcheck_section=$(_sweep_shellcheck "$repo_slug" "$repo_path")
	[[ -n "$shellcheck_section" ]] && tool_count=$((tool_count + 1))

	local qlty_section="" qlty_smell_count=0 qlty_grade="UNKNOWN"
	local qlty_raw
	qlty_raw=$(_sweep_qlty "$repo_slug" "$repo_path")
	if [[ -n "$qlty_raw" ]]; then
		qlty_section="${qlty_raw%%|*}"
		local qlty_remainder="${qlty_raw#*|}"
		qlty_smell_count="${qlty_remainder%%|*}"
		qlty_grade="${qlty_remainder#*|}"
		[[ -n "$qlty_section" ]] && tool_count=$((tool_count + 1))
	fi

	# t2066: compute smell delta vs previous sweep. Signed integer — positive
	# means regression (more smells), negative means improvement. The caller
	# renders the sign + trend arrow in the dashboard.
	local qlty_smell_delta=0
	if [[ "$qlty_smell_count" =~ ^[0-9]+$ ]]; then
		qlty_smell_delta=$((qlty_smell_count - prev_qlty_smells))
	fi

	# Parse _sweep_sonarcloud's 5-field pipe-separated return. sonar_section
	# is the only multi-line field, so strip it with ${..%%|*} (works on
	# newlines) and IFS-split the single-line remainder into the 4 scalars.
	# read(1) fills missing fields as empty, providing 4-field back-compat.
	local sonar_section=""
	local sonar_raw
	sonar_raw=$(_sweep_sonarcloud "$repo_path")
	if [[ -n "$sonar_raw" ]]; then
		sonar_section="${sonar_raw%%|*}"
		IFS='|' read -r sweep_gate_status sweep_total_issues sweep_high_critical sweep_sev_inline <<<"${sonar_raw#*|}"
		[[ -n "$sonar_section" ]] && tool_count=$((tool_count + 1))
	fi

	local codacy_section=""
	codacy_section=$(_sweep_codacy "$repo_slug")
	[[ -n "$codacy_section" ]] && tool_count=$((tool_count + 1))

	local coderabbit_section=""
	coderabbit_section=$(_sweep_coderabbit "$repo_slug" "$sweep_gate_status" "$sweep_total_issues")
	_save_sweep_state "$repo_slug" "$sweep_gate_status" "$sweep_total_issues" "$sweep_high_critical" "$qlty_smell_count" "$qlty_grade"
	tool_count=$((tool_count + 1))

	local review_scan_section=""
	review_scan_section=$(_sweep_review_scanner "$repo_slug")
	[[ -n "$review_scan_section" ]] && tool_count=$((tool_count + 1))

	# t1992: write each section to its own file. printf '%s' (no trailing
	# newline) preserves byte-for-byte content; multi-line strings round-trip
	# intact because each file owns exactly one variable.
	local sections_dir
	sections_dir=$(mktemp -d 2>/dev/null) || return 1
	printf '%s' "$tool_count" >"${sections_dir}/tool_count"
	printf '%s' "$shellcheck_section" >"${sections_dir}/shellcheck"
	printf '%s' "$qlty_section" >"${sections_dir}/qlty"
	printf '%s' "$qlty_smell_count" >"${sections_dir}/qlty_smell_count"
	printf '%s' "$qlty_grade" >"${sections_dir}/qlty_grade"
	# t2066: smell delta and previous count — the dashboard reads these to
	# render a trend indicator ("↓ -3", "↑ +7", "→ 0") next to the smell count.
	printf '%s' "$qlty_smell_delta" >"${sections_dir}/qlty_smell_delta"
	printf '%s' "$prev_qlty_smells" >"${sections_dir}/qlty_smell_count_prev"
	printf '%s' "$sonar_section" >"${sections_dir}/sonar"
	printf '%s' "$sweep_gate_status" >"${sections_dir}/sweep_gate_status"
	printf '%s' "$sweep_total_issues" >"${sections_dir}/sweep_total_issues"
	printf '%s' "$sweep_high_critical" >"${sections_dir}/sweep_high_critical"
	# t2717: per-severity inline summary for the dashboard (replaces the
	# misleading '(N high/critical)' aggregate on line rendering).
	printf '%s' "$sweep_sev_inline" >"${sections_dir}/sweep_sev_inline"
	printf '%s' "$codacy_section" >"${sections_dir}/codacy"
	printf '%s' "$coderabbit_section" >"${sections_dir}/coderabbit"
	printf '%s' "$review_scan_section" >"${sections_dir}/review_scan"

	# Single-line handshake: just the directory path. The caller reads each
	# section by `cat`ing one file at a time.
	printf '%s\n' "$sections_dir"
	return 0
}

_quality_sweep_for_repo() {
	local repo_slug="$1"
	local repo_path="$2"

	local issue_number
	issue_number=$(_ensure_quality_issue "$repo_slug") || return 0

	local now_iso
	now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	# t1992: read each section back from its own file. The previous code
	# used `IFS= read -r` chains which only handled single-line values and
	# silently truncated every multi-line markdown section.
	local sections_dir
	sections_dir=$(_run_sweep_tools "$repo_slug" "$repo_path")
	if [[ -z "$sections_dir" || ! -d "$sections_dir" ]]; then
		echo "[stats] Quality sweep: _run_sweep_tools produced no sections dir for ${repo_slug}" >>"$LOGFILE"
		[[ -n "$sections_dir" && -e "$sections_dir" ]] && rm -rf "$sections_dir"
		return 0
	fi

	local tool_count shellcheck_section qlty_section qlty_smell_count qlty_grade
	local qlty_smell_delta qlty_smell_count_prev
	local sonar_section sweep_gate_status sweep_total_issues sweep_high_critical
	local sweep_sev_inline
	local codacy_section coderabbit_section review_scan_section
	tool_count=$(cat "${sections_dir}/tool_count" 2>/dev/null || echo 0)
	shellcheck_section=$(cat "${sections_dir}/shellcheck" 2>/dev/null || echo "")
	qlty_section=$(cat "${sections_dir}/qlty" 2>/dev/null || echo "")
	qlty_smell_count=$(cat "${sections_dir}/qlty_smell_count" 2>/dev/null || echo 0)
	qlty_grade=$(cat "${sections_dir}/qlty_grade" 2>/dev/null || echo UNKNOWN)
	# t2066: smell delta + previous count for dashboard trend rendering
	qlty_smell_delta=$(cat "${sections_dir}/qlty_smell_delta" 2>/dev/null || echo 0)
	qlty_smell_count_prev=$(cat "${sections_dir}/qlty_smell_count_prev" 2>/dev/null || echo 0)
	sonar_section=$(cat "${sections_dir}/sonar" 2>/dev/null || echo "")
	sweep_gate_status=$(cat "${sections_dir}/sweep_gate_status" 2>/dev/null || echo UNKNOWN)
	sweep_total_issues=$(cat "${sections_dir}/sweep_total_issues" 2>/dev/null || echo 0)
	sweep_high_critical=$(cat "${sections_dir}/sweep_high_critical" 2>/dev/null || echo 0)
	# t2717: per-severity inline summary for the dashboard. Optional; empty
	# string on early-return paths or if the sections file is missing (e.g.,
	# when a stale sections_dir predates this field).
	sweep_sev_inline=$(cat "${sections_dir}/sweep_sev_inline" 2>/dev/null || echo "")
	codacy_section=$(cat "${sections_dir}/codacy" 2>/dev/null || echo "")
	coderabbit_section=$(cat "${sections_dir}/coderabbit" 2>/dev/null || echo "")
	review_scan_section=$(cat "${sections_dir}/review_scan" 2>/dev/null || echo "")
	rm -rf "$sections_dir"

	if [[ "${tool_count:-0}" -eq 0 ]]; then
		echo "[stats] Quality sweep: no tools available for ${repo_slug}" >>"$LOGFILE"
		return 0
	fi

	# Update issue body dashboard first (best-effort — comment is secondary)
	# t2717: pass sweep_sev_inline so the dashboard can render the per-
	# severity breakdown in place of the misleading 'high/critical' aggregate.
	_update_quality_issue_body "$repo_slug" "$issue_number" \
		"$sweep_gate_status" "$sweep_total_issues" "$sweep_high_critical" \
		"$now_iso" "$tool_count" "$qlty_smell_count" "$qlty_grade" \
		"$qlty_smell_delta" "$qlty_smell_count_prev" "$sweep_sev_inline"

	# Post daily comment with full findings
	local comment_body
	comment_body=$(_build_sweep_comment \
		"$now_iso" "$repo_slug" "$tool_count" \
		"$shellcheck_section" "$qlty_section" "$sonar_section" \
		"$codacy_section" "$coderabbit_section" "$review_scan_section")

	local comment_stderr=""
	local comment_posted=false
	comment_stderr=$(gh_issue_comment "$issue_number" --repo "$repo_slug" --body "$comment_body" 2>&1 >/dev/null) && comment_posted=true || {
		echo "[stats] Quality sweep: failed to post comment on #${issue_number} in ${repo_slug}: ${comment_stderr}" >>"$LOGFILE"
	}

	if [[ "$comment_posted" == true ]]; then
		echo "[stats] Quality sweep: posted findings on #${issue_number} in ${repo_slug} (${tool_count} tools)" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Create function-complexity-debt issues for files with high Qlty smell density.
# Bridges the daily quality sweep to the code-simplifier's human-gated
# dispatch pipeline. Issues are created with function-complexity-debt +
# needs-maintainer-review + tier:thinking labels and assigned to the
# repo maintainer.
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - SARIF JSON string from qlty smells
#
# Behaviour (t2066 retuned caps — throughput over trickle):
#   - min_smells_threshold=3 (was 5): catch more medium-density files
#   - max_issues_per_sweep=5 (was 3): the goal is throughput
#   - total_open_cap=30 (was 200): the goal isn't backlog, it's flow;
#     needs-maintainer-review already rate-limits human work
#   - Default tier label: tier:thinking (Haiku can't refactor 70+ complexity,
#     and per-user direction tier:thinking is the canonical opus label
#     going forward)
#   - Deduplicates: skips files that already have an open function-complexity-debt
#     issue for the same file
#   - Includes per-rule breakdown in the body (already computed per file —
#     the old code dropped it into the title only)
#######################################
_create_simplification_issues() {
	local repo_slug="$1"
	local sarif_json="$2"
	# t2066: retuned caps for throughput. The old values (5/3/200) were set for
	# a world where simplification issues were a trickle. With the current
	# ~109-smell baseline we need flow, not trickle — and the
	# needs-maintainer-review gate already ensures human approval rate-limits
	# actual dispatch. See GH#18774.
	local max_issues_per_sweep=5
	local min_smells_threshold=3
	local total_open_cap=30
	local issues_created=0

	# Ensure required labels exist (gh issue create fails if labels are missing)
	gh label create "function-complexity-debt" --repo "$repo_slug" \
		--description "Functions exceed complexity threshold — needs refactoring before implementation can proceed" \
		--color "E05D44" 2>/dev/null || true
	gh label create "needs-maintainer-review" --repo "$repo_slug" \
		--description "Requires maintainer approval before automated dispatch" \
		--color "FBCA04" 2>/dev/null || true
	gh label create "source:quality-sweep" --repo "$repo_slug" \
		--description "Auto-created by stats-functions.sh quality sweep" \
		--color "C2E0C6" --force 2>/dev/null || true
	# t2066: ensure the tier:thinking label exists. Simplification refactors
	# typically involve decomposing functions at cyclomatic 25+ — Sonnet handles
	# them poorly and Haiku cannot handle them at all. Default to the opus
	# tier so the first dispatch attempt succeeds.
	gh label create "tier:thinking" --repo "$repo_slug" \
		--description "Opus-tier: architecture, deep reasoning, high-complexity refactors" \
		--color "5319E7" 2>/dev/null || true

	# Extract files with smell count > threshold, sorted by count descending
	local high_smell_files
	high_smell_files=$(echo "$sarif_json" | jq -r --argjson threshold "$min_smells_threshold" '
		[.runs[0].results[] | .locations[0].physicalLocation.artifactLocation.uri] |
		group_by(.) | map({file: .[0], count: length}) |
		[.[] | select(.count >= $threshold)] | sort_by(-.count)[:15] |
		.[] | "\(.count)\t\(.file)"
	' 2>/dev/null) || high_smell_files=""

	if [[ -z "$high_smell_files" ]]; then
		return 0
	fi

	# Resolve maintainer for issue assignment
	local maintainer=""
	maintainer=$(jq -r --arg slug "$repo_slug" \
		'.initialized_repos[]? | select(.slug == $slug) | .maintainer // empty' \
		"${HOME}/.config/aidevops/repos.json" 2>/dev/null) || maintainer=""
	if [[ -z "$maintainer" ]]; then
		maintainer="${repo_slug%%/*}"
	fi

	# Total-open cap: stop creating when backlog is already large
	local total_open
	total_open=$(gh api graphql -f query="query { repository(owner:\"${repo_slug%%/*}\", name:\"${repo_slug##*/}\") { issues(labels:[\"function-complexity-debt\"], states:OPEN) { totalCount } } }" \
		--jq '.data.repository.issues.totalCount' 2>/dev/null) || total_open="0"
	if [[ "${total_open:-0}" -ge "$total_open_cap" ]]; then
		echo "[stats] Function-complexity-debt issues: skipping — ${total_open} open (cap: ${total_open_cap})" >>"$LOGFILE"
		return 0
	fi

	while IFS=$'\t' read -r smell_count file_path; do
		[[ -z "$file_path" ]] && continue
		[[ "$issues_created" -ge "$max_issues_per_sweep" ]] && break

		# Deduplicate via server-side title search — accurate across all issues.
		# The file path is in the title, so searching by path is reliable.
		local existing_count
		existing_count=$(gh issue list --repo "$repo_slug" \
			--label "function-complexity-debt" --state open \
			--search "in:title \"$file_path\"" \
			--json number --jq 'length' 2>/dev/null) || existing_count="0"
		if [[ "${existing_count:-0}" -gt 0 ]]; then
			continue
		fi

		# Build per-rule breakdown for this file. Already computed in the sweep
		# body above — we re-extract it here to feed it to the issue body
		# template (t2066: surface the per-rule counts in the body, not just
		# the aggregate smell count).
		local rule_breakdown
		rule_breakdown=$(echo "$sarif_json" | jq -r --arg fp "$file_path" '
			[.runs[0].results[] |
			 select(.locations[0].physicalLocation.artifactLocation.uri == $fp) |
			 .ruleId] | group_by(.) | map("\(.[0]): \(length)") | join(", ")
		' 2>/dev/null) || rule_breakdown="(could not parse)"

		# Create the issue with code-simplifier label convention
		local file_basename="${file_path##*/}"
		local issue_title="simplification: reduce ${smell_count} Qlty smells in ${file_basename}"
		local issue_body
		issue_body=$(_build_simplification_issue_body "$file_path" "$smell_count" "$rule_breakdown")

		# Append signature footer
		local qlty_sig=""
		qlty_sig=$("${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" footer --body "$issue_body" 2>/dev/null || true)
		issue_body="${issue_body}${qlty_sig}"

		if gh_create_issue --repo "$repo_slug" \
			--title "$issue_title" \
			--label "function-complexity-debt" --label "needs-maintainer-review" --label "source:quality-sweep" --label "tier:thinking" \
			--assignee "$maintainer" \
			--body "$issue_body" >/dev/null 2>&1; then
			issues_created=$((issues_created + 1))
		fi
	done <<<"$high_smell_files"

	if [[ "$issues_created" -gt 0 ]]; then
		qlty_section="${qlty_section}
_Created ${issues_created} function-complexity-debt issue(s) for high-smell files (needs maintainer review, tier:thinking)._
"
	fi

	return 0
}

#######################################
# Build the quality issue dashboard body markdown.
#
# Pure formatting function — no API calls. All data pre-gathered by caller.
#
# t2066: added qlty_smell_delta and qlty_smell_count_prev so the dashboard
# can render a trend indicator next to the smell count and the grade row
# shows the grade is derived from the local count (not the cloud badge).
#
# Arguments:
#   $1  - sweep_time
#   $2  - repo_slug
#   $3  - tool_count
#   $4  - badge_indicator
#   $5  - gate_status
#   $6  - total_issues
#   $7  - high_critical (retained for back-compat; not displayed per t2717)
#   $8  - qlty_grade
#   $9  - qlty_smell_count
#   $10 - debt_open
#   $11 - debt_closed
#   $12 - simplified_count
#   $13 - debt_resolution_pct
#   $14 - prs_scanned_lifetime
#   $15 - issues_created_lifetime
#   $16 - bot_coverage_section
#   $17 - qlty_smell_delta (signed int; positive = regression)
#   $18 - qlty_smell_count_prev (previous sweep's smell count; 0 = first run)
#   $19 - sev_inline (t2717; per-severity inline summary, e.g.,
#        "0 BLOCKER · 0 CRITICAL · 98 MAJOR · 196 MINOR · 0 INFO";
#        empty string falls back to legacy high_critical rendering)
# Output: body markdown to stdout
#######################################
_build_quality_issue_body() {
	local sweep_time="$1"
	local repo_slug="$2"
	local tool_count="$3"
	local badge_indicator="$4"
	local gate_status="$5"
	local total_issues="$6"
	local high_critical="$7"
	local qlty_grade="$8"
	local qlty_smell_count="$9"
	local debt_open="${10}"
	local debt_closed="${11}"
	local simplified_count="${12}"
	local debt_resolution_pct="${13}"
	local prs_scanned_lifetime="${14}"
	local issues_created_lifetime="${15}"
	local bot_coverage_section="${16}"
	local qlty_smell_delta="${17:-0}"
	local qlty_smell_count_prev="${18:-0}"
	local sev_inline="${19:-}"

	# t2066: render smell-count trend indicator. The arrow is a simple
	# visual cue; the signed value is authoritative. First-run case (prev=0,
	# no history) shows "baseline" instead of an arrow so the reader knows
	# the delta is meaningless until the second sweep lands.
	local smell_trend=""
	if [[ "$qlty_smell_count_prev" == "0" && "$qlty_smell_count" -gt 0 ]]; then
		smell_trend="(baseline — no prior sweep)"
	elif [[ "$qlty_smell_delta" == "0" ]]; then
		smell_trend="→ 0 (unchanged)"
	elif [[ "$qlty_smell_delta" =~ ^- ]]; then
		# Negative delta = improvement
		smell_trend="↓ ${qlty_smell_delta} (improved)"
	else
		smell_trend="↑ +${qlty_smell_delta} (regressed)"
	fi

	# t2717: prefer the per-severity inline summary (BLOCKER · CRITICAL ·
	# MAJOR · MINOR · INFO) over the legacy '(N high/critical)' aggregate.
	# The legacy label was misleading because it summed MAJOR (a
	# CODE_SMELL severity in SonarCloud's taxonomy) with the true high
	# severities (BLOCKER, CRITICAL). Fall back to the legacy label only
	# when sev_inline is empty (e.g., first sweep after upgrade, or an
	# early-return path where no SonarCloud data was fetched).
	local sonar_issues_detail
	if [[ -n "$sev_inline" ]]; then
		sonar_issues_detail="${total_issues} (${sev_inline})"
	else
		sonar_issues_detail="${total_issues} (${high_critical} high/critical)"
	fi

	cat <<BODY
## Code Audit Routines

**Last sweep**: \`${sweep_time}\`
**Repo**: \`${repo_slug}\`
**Tools run**: ${tool_count}
**Badge status**: ${badge_indicator}

### Quality

| Metric | Value |
| --- | --- |
| SonarCloud gate | ${gate_status} |
| SonarCloud issues | ${sonar_issues_detail} |
| Qlty grade (local, from smell count) | ${qlty_grade} |
| Qlty smells | ${qlty_smell_count} ${smell_trend} |

### Simplification

| Metric | Value |
| --- | --- |
| Open | ${debt_open} |
| Closed | ${debt_closed} |
| Simplified (state tracked) | ${simplified_count} |
| Resolution rate | ${debt_resolution_pct}% |

### PR Scanning

| Metric | Value |
| --- | --- |
| PRs scanned (lifetime) | ${prs_scanned_lifetime} |
| Issues created (lifetime) | ${issues_created_lifetime} |

${bot_coverage_section}

---
_Auto-updated by daily quality sweep. Findings as of \`${sweep_time}\` — may not reflect recent merges between sweeps._
_The codebase is the primary source of truth. This dashboard is a reporting snapshot that may lag behind reality._
_Do not edit manually._
BODY
	return 0
}
