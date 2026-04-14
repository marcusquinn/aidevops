#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# stats-quality-sweep.sh - Daily code quality sweep functions
#
# Extracted from stats-functions.sh via the phased decomposition plan:
#   todo/plans/stats-functions-decomposition.md  (Phase 2)
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
# The sweep creates simplification-debt issues directly (with
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
# Ensure persistent quality review issue exists for a repo
#
# Creates or finds the "Daily Code Quality Review" issue. Uses labels
# "quality-review" + "persistent" for dedup. Pins the issue.
#
# Arguments:
#   $1 - repo slug
# Output: issue number to stdout
# Returns: 0 on success, 1 if issue could not be created/found
#######################################
_ensure_quality_issue() {
	local repo_slug="$1"
	local slug_safe="${repo_slug//\//-}"
	local cache_file="${HOME}/.aidevops/logs/quality-issue-${slug_safe}"

	mkdir -p "${HOME}/.aidevops/logs"

	# Try cached issue number
	local issue_number=""
	if [[ -f "$cache_file" ]]; then
		issue_number=$(cat "$cache_file" 2>/dev/null || echo "")
	fi

	# Validate cached issue is still open
	if [[ -n "$issue_number" ]]; then
		local state
		state=$(gh issue view "$issue_number" --repo "$repo_slug" --json state --jq '.state' 2>/dev/null || echo "")
		if [[ "$state" != "OPEN" ]]; then
			issue_number=""
			rm -f "$cache_file" 2>/dev/null || true
		fi
	fi

	# Search by labels
	if [[ -z "$issue_number" ]]; then
		issue_number=$(gh issue list --repo "$repo_slug" \
			--label "quality-review" --label "persistent" \
			--state open --json number \
			--jq '.[0].number // empty' 2>/dev/null || echo "")
	fi

	# Create if missing
	if [[ -z "$issue_number" ]]; then
		# Ensure labels exist
		gh label create "quality-review" --repo "$repo_slug" --color "7057FF" \
			--description "Daily code quality review" --force 2>/dev/null || true
		gh label create "persistent" --repo "$repo_slug" --color "FBCA04" \
			--description "Persistent issue — do not close" --force 2>/dev/null || true
		gh label create "source:quality-sweep" --repo "$repo_slug" --color "C2E0C6" \
			--description "Auto-created by stats-functions.sh quality sweep" --force 2>/dev/null || true

		local qa_body="Persistent dashboard for automated code quality and simplification routines (ShellCheck, Qlty, SonarCloud, Codacy, CodeRabbit). The supervisor posts findings here and creates actionable issues from them. **Do not close this issue.**"
		local qa_sig=""
		qa_sig=$("${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" footer --body "$qa_body" 2>/dev/null || true)
		qa_body="${qa_body}${qa_sig}"

		issue_number=$(gh_create_issue --repo "$repo_slug" \
			--title "Code Audit Routines" \
			--body "$qa_body" \
			--label "quality-review" --label "persistent" --label "source:quality-sweep" 2>/dev/null | grep -oE '[0-9]+$' || echo "")

		if [[ -z "$issue_number" ]]; then
			echo "[stats] Quality sweep: could not create issue for ${repo_slug}" >>"$LOGFILE"
			return 1
		fi

		# Pin (best-effort)
		local node_id
		node_id=$(gh issue view "$issue_number" --repo "$repo_slug" --json id --jq '.id' 2>/dev/null || echo "")
		if [[ -n "$node_id" ]]; then
			gh api graphql -f query="
				mutation {
					pinIssue(input: {issueId: \"${node_id}\"}) {
						issue { number }
					}
				}" >/dev/null 2>&1 || true
		fi

		echo "[stats] Quality sweep: created and pinned issue #${issue_number} in ${repo_slug}" >>"$LOGFILE"
	fi

	# Cache
	echo "$issue_number" >"$cache_file"
	echo "$issue_number"
	return 0
}

#######################################
# Load previous quality sweep state for a repo
#
# Reads gate_status and total_issues from the per-repo state file.
# Returns defaults if no state file exists (first run).
#
# Arguments:
#   $1 - repo slug
# Output: "gate_status|total_issues|high_critical_count" to stdout
#######################################
_load_sweep_state() {
	local repo_slug="$1"
	local slug_safe="${repo_slug//\//-}"
	local state_file="${QUALITY_SWEEP_STATE_DIR}/${slug_safe}.json"

	if [[ -f "$state_file" ]]; then
		local prev_gate prev_issues prev_high_critical
		prev_gate=$(jq -r '.gate_status // "UNKNOWN"' "$state_file" 2>/dev/null || echo "UNKNOWN")
		prev_issues=$(jq -r '.total_issues // 0' "$state_file" 2>/dev/null || echo "0")
		prev_high_critical=$(jq -r '.high_critical_count // 0' "$state_file" 2>/dev/null || echo "0")
		echo "${prev_gate}|${prev_issues}|${prev_high_critical}"
	else
		echo "UNKNOWN|0|0"
	fi
	return 0
}

#######################################
# Save current quality sweep state for a repo
#
# Persists gate_status, total_issues, and high/critical severity
# count so the next sweep can compute deltas.
#
# Arguments:
#   $1 - repo slug
#   $2 - gate status (OK/ERROR/UNKNOWN)
#   $3 - total issue count
#   $4 - high+critical severity count
#######################################
_save_sweep_state() {
	local repo_slug="$1"
	local gate_status="$2"
	local total_issues="$3"
	local high_critical_count="$4"
	local qlty_smells="${5:-0}"
	local qlty_grade="${6:-UNKNOWN}"
	local slug_safe="${repo_slug//\//-}"

	mkdir -p "$QUALITY_SWEEP_STATE_DIR"

	local state_file="${QUALITY_SWEEP_STATE_DIR}/${slug_safe}.json"
	printf '{"gate_status":"%s","total_issues":%d,"high_critical_count":%d,"qlty_smells":%d,"qlty_grade":"%s","updated_at":"%s"}\n' \
		"$gate_status" "$total_issues" "$high_critical_count" "$qlty_smells" "$qlty_grade" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		>"$state_file"
	return 0
}

#######################################
# Discover tracked .sh files in a repo.
#
# Arguments:
#   $1 - repo path
# Output: newline-separated file paths to stdout (max 100)
#######################################
_sweep_shellcheck_get_files() {
	local repo_path="$1"

	# GH#5663: Use git ls-files to discover only tracked shell scripts.
	# find can return deleted files still on disk, stale worktree paths, or
	# build artifacts — causing false ShellCheck findings on non-existent files.
	if git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1; then
		git -C "$repo_path" ls-files '*.sh' 2>/dev/null | head -100
	else
		# Fallback for non-git directories (should not occur for pulse repos)
		find "$repo_path" -name "*.sh" -not -path "*/node_modules/*" \
			-not -path "*/.git/*" -type f 2>/dev/null | head -100
	fi
	return 0
}

#######################################
# Format ShellCheck results into a markdown section.
#
# Arguments:
#   $1 - file count scanned
#   $2 - error count
#   $3 - warning count
#   $4 - note count
#   $5 - top findings details (may be empty)
# Output: markdown section to stdout
#######################################
_sweep_shellcheck_format_section() {
	local file_count="$1"
	local sc_errors="$2"
	local sc_warnings="$3"
	local sc_notes="$4"
	local sc_details="$5"

	local shellcheck_section="### ShellCheck ($file_count files scanned)

- **Errors**: ${sc_errors}
- **Warnings**: ${sc_warnings}
- **Notes**: ${sc_notes}
"
	if [[ -n "$sc_details" ]]; then
		shellcheck_section="${shellcheck_section}
**Top findings:**
${sc_details}"
	fi
	if [[ "$sc_errors" -eq 0 && "$sc_warnings" -eq 0 && "$sc_notes" -eq 0 ]]; then
		shellcheck_section="${shellcheck_section}
_All clear — no issues found._
"
	fi

	printf '%s' "$shellcheck_section"
	return 0
}

#######################################
# Run ShellCheck on all tracked .sh files in a repo.
#
# Arguments:
#   $1 - repo slug
#   $2 - repo path
# Output: shellcheck_section markdown to stdout
#######################################
_sweep_shellcheck() {
	local repo_slug="$1"
	local repo_path="$2"

	command -v shellcheck &>/dev/null || return 0

	local sh_files
	sh_files=$(_sweep_shellcheck_get_files "$repo_path")

	[[ -z "$sh_files" ]] && return 0

	local sc_errors=0
	local sc_warnings=0
	local sc_notes=0
	local sc_details=""

	# timeout_sec (from shared-constants.sh) handles macOS + Linux portably,
	# providing a background + kill fallback on bare macOS so we no longer
	# need to skip ShellCheck when no timeout utility is installed.
	# GH#5663: git ls-files returns relative paths — resolve to absolute
	# before running ShellCheck, and guard against tracked-but-deleted files
	# (index vs working tree mismatch) by skipping missing paths with a log
	# entry rather than passing a non-existent path to ShellCheck.

	while IFS= read -r shfile; do
		[[ -z "$shfile" ]] && continue
		if [[ ! "$shfile" =~ ^/ ]]; then
			shfile="${repo_path}/${shfile}"
		fi
		if [[ ! -f "$shfile" ]]; then
			printf '%s [stats] ShellCheck: skipping missing file: %s\n' \
				"$(date '+%Y-%m-%d %H:%M:%S')" "${shfile}" >>"$LOGFILE"
			continue
		fi
		local result
		# t1398.2: hardened invocation — no -x, --norc, per-file timeout,
		# ulimit -v in subshell to cap RSS per shellcheck process.
		# t1402: stderr merged into stdout (2>&1) so diagnostic messages
		# (parse errors, timeouts, permission failures) are captured in
		# $result and appear in the sweep summary.
		result=$(
			ulimit -v 1048576 2>/dev/null || true
			timeout_sec 30 shellcheck --norc -f gcc "$shfile" 2>&1 || true
		)
		if [[ -n "$result" ]]; then
			# t1992: shellcheck -f gcc emits three severities: error, warning,
			# note. Pin the regex to the gcc location prefix `<file>:<line>:<col>:`
			# so we don't accidentally match content inside a finding message.
			local file_errors file_warnings file_notes
			file_errors=$(grep -cE ':[0-9]+:[0-9]+: error:' <<<"$result") || file_errors=0
			file_warnings=$(grep -cE ':[0-9]+:[0-9]+: warning:' <<<"$result") || file_warnings=0
			file_notes=$(grep -cE ':[0-9]+:[0-9]+: note:' <<<"$result") || file_notes=0
			sc_errors=$((sc_errors + file_errors))
			sc_warnings=$((sc_warnings + file_warnings))
			sc_notes=$((sc_notes + file_notes))

			# Capture first 3 findings per file for the summary
			local rel_path="${shfile#"$repo_path"/}"
			local top_findings
			top_findings=$(head -3 <<<"$result" | while IFS= read -r line; do
				echo "  - \`${rel_path}\`: ${line##*: }"
			done)
			if [[ -n "$top_findings" ]]; then
				sc_details="${sc_details}${top_findings}
"
			fi
		fi
	done <<<"$sh_files"

	local file_count
	file_count=$(echo "$sh_files" | wc -l | tr -d ' ')
	_sweep_shellcheck_format_section "$file_count" "$sc_errors" "$sc_warnings" "$sc_notes" "$sc_details"
	return 0
}

#######################################
# Run Qlty CLI analysis on a repo.
#
# Arguments:
#   $1 - repo slug
#   $2 - repo path
# Sets caller variables via stdout (pipe-delimited):
#   qlty_section|qlty_smell_count|qlty_grade
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

		qlty_section="### Qlty Maintainability

- **Total smells**: ${qlty_smell_count}
- **By rule (fix these for maximum grade improvement)**:
${qlty_rules_breakdown}
- **Top files (highest smell density)**:
${qlty_files_breakdown}
"
		if [[ "$qlty_smell_count" -eq 0 ]]; then
			qlty_section="### Qlty Maintainability

_No smells detected — clean codebase._
"
		fi
	else
		qlty_section="### Qlty Maintainability

_Qlty analysis returned empty or failed to parse._
"
	fi

	# Fetch the Qlty Cloud badge grade (A/B/C/D/F) from the badge SVG.
	# The grade is determined by Qlty Cloud's analysis (not local CLI),
	# so we parse the badge colour which maps to the grade letter.
	local badge_svg
	badge_svg=$(curl -sS --fail --connect-timeout 5 --max-time 10 \
		"https://qlty.sh/gh/${repo_slug}/maintainability.svg" 2>/dev/null) || badge_svg=""
	if [[ -n "$badge_svg" ]]; then
		# Grade colour mapping from Qlty's badge palette
		qlty_grade=$(python3 -c "
import sys, re
svg = sys.stdin.read()
colors = {'#22C55E':'A','#84CC16':'B','#EAB308':'C','#F97316':'D','#EF4444':'F'}
for c in re.findall(r'fill=\"(#[A-F0-9]+)\"', svg):
    if c in colors:
        print(colors[c])
        sys.exit(0)
print('UNKNOWN')
" <<<"$badge_svg" 2>/dev/null) || qlty_grade="UNKNOWN"
	fi

	qlty_section="${qlty_section}
- **Qlty Cloud grade**: ${qlty_grade}
"

	# --- 2b. Simplification-debt bridge (code-simplifier pipeline) ---
	# For files with high smell density, auto-create simplification-debt issues
	# with needs-maintainer-review label. This bridges the daily sweep to the
	# code-simplifier's human-gated dispatch pipeline (see code-simplifier.md).
	# Max 3 issues per sweep to avoid flooding. Deduplicates against existing issues.
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
# Output: pipe-delimited "sonar_section|sweep_gate_status|sweep_total_issues|sweep_high_critical"
#######################################
_sweep_sonarcloud() {
	local repo_path="$1"

	local sonar_section=""
	local sweep_gate_status="UNKNOWN"
	local sweep_total_issues=0
	local sweep_high_critical=0

	[[ -f "${repo_path}/sonar-project.properties" ]] || {
		printf '%s|%s|%s|%s' "$sonar_section" "$sweep_gate_status" "$sweep_total_issues" "$sweep_high_critical"
		return 0
	}

	local project_key
	project_key=$(grep '^sonar.projectKey=' "${repo_path}/sonar-project.properties" 2>/dev/null | cut -d= -f2)
	local org_key
	org_key=$(grep '^sonar.organization=' "${repo_path}/sonar-project.properties" 2>/dev/null | cut -d= -f2)

	if [[ -z "$project_key" || -z "$org_key" ]]; then
		printf '%s|%s|%s|%s' "$sonar_section" "$sweep_gate_status" "$sweep_total_issues" "$sweep_high_critical"
		return 0
	fi

	# URL-encode project_key to prevent injection via crafted sonar-project.properties
	local encoded_project_key
	encoded_project_key=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$project_key" 2>/dev/null) || encoded_project_key=""
	if [[ -z "$encoded_project_key" ]]; then
		echo "[stats] Failed to URL-encode project_key — skipping SonarCloud" >&2
		printf '%s|%s|%s|%s' "$sonar_section" "$sweep_gate_status" "$sweep_total_issues" "$sweep_high_critical"
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
	local issues_section total_issues high_critical_count
	issues_section=$(_sweep_sonarcloud_issues "$encoded_project_key")
	total_issues="${issues_section%%|*}"
	local issues_remainder="${issues_section#*|}"
	high_critical_count="${issues_remainder%%|*}"
	local issues_md="${issues_remainder#*|}"
	[[ "$total_issues" =~ ^[0-9]+$ ]] || total_issues=0
	[[ "$high_critical_count" =~ ^[0-9]+$ ]] || high_critical_count=0
	sweep_total_issues="$total_issues"
	sweep_high_critical="$high_critical_count"
	if [[ -n "$issues_md" ]]; then
		sonar_section="${sonar_section}${issues_md}"
	fi

	printf '%s|%s|%s|%s' "$sonar_section" "$sweep_gate_status" "$sweep_total_issues" "$sweep_high_critical"
	return 0
}

#######################################
# Fetch SonarCloud open issues summary with rule-level breakdown.
#
# Arguments:
#   $1 - encoded_project_key
# Output: "total_issues|high_critical_count|issues_md"
#######################################
_sweep_sonarcloud_issues() {
	local encoded_project_key="$1"

	local sonar_issues=""
	sonar_issues=$(curl -sS --fail --connect-timeout 5 --max-time 20 \
		"https://sonarcloud.io/api/issues/search?componentKeys=${encoded_project_key}&statuses=OPEN,CONFIRMED,REOPENED&ps=1&facets=severities,types,rules" || echo "")

	if [[ -z "$sonar_issues" ]] || ! echo "$sonar_issues" | jq -e '.total' &>/dev/null; then
		printf '%s|%s|%s' "0" "0" ""
		return 0
	fi

	# Single jq pass: extract total, high/critical count, severity breakdown, type breakdown, and top rules
	local issues_data
	issues_data=$(echo "$sonar_issues" | jq -r '
		(.total // 0) as $total |
		([.facets[]? | select(.property == "severities") | .values[]? | select(.val == "MAJOR" or .val == "CRITICAL" or .val == "BLOCKER") | .count] | add // 0) as $hc |
		([.facets[]? | select(.property == "severities") | .values[]? | "  - \(.val): \(.count)"] | join("\n")) as $sev |
		([.facets[]? | select(.property == "types") | .values[]? | "  - \(.val): \(.count)"] | join("\n")) as $typ |
		"\($total)|\($hc)|\($sev)|\($typ)"
	') || issues_data="0|0||"
	local total_issues="${issues_data%%|*}"
	local remainder="${issues_data#*|}"
	local high_critical_count="${remainder%%|*}"
	remainder="${remainder#*|}"
	local severity_breakdown="${remainder%%|*}"
	local type_breakdown="${remainder#*|}"
	[[ "$total_issues" =~ ^[0-9]+$ ]] || total_issues=0
	[[ "$high_critical_count" =~ ^[0-9]+$ ]] || high_critical_count=0
	severity_breakdown=$(_sanitize_markdown "$severity_breakdown")
	type_breakdown=$(_sanitize_markdown "$type_breakdown")

	local issues_md="
- **Open issues**: ${total_issues}
- **By severity**:
${severity_breakdown}
- **By type**:
${type_breakdown}
"
	# Rule-level breakdown: shows which rules produce the most issues,
	# enabling targeted batch fixes (e.g., S1192 string constants, S7688
	# bracket style). This is the key data the supervisor needs to create
	# actionable quality-debt issues grouped by rule rather than by file.
	local rules_breakdown
	rules_breakdown=$(echo "$sonar_issues" | jq -r '
		[.facets[]? | select(.property == "rules") | .values[:10][]? |
		"  - \(.val): \(.count) issues"] | join("\n")
	') || rules_breakdown=""
	if [[ -n "$rules_breakdown" ]]; then
		rules_breakdown=$(_sanitize_markdown "$rules_breakdown")
		issues_md="${issues_md}
- **Top rules (fix these for maximum badge improvement)**:
${rules_breakdown}
"
	fi

	printf '%s|%s|%s' "$total_issues" "$high_critical_count" "$issues_md"
	return 0
}

#######################################
# Build SonarCloud failing-condition diagnostics markdown.
#
# Called only when gate_status is ERROR or WARN.
#
# Arguments:
#   $1 - sonar_status JSON
#   $2 - encoded_project_key
# Output: diagnostics markdown to stdout
#######################################
_sweep_sonarcloud_diagnostics() {
	local sonar_status="$1"
	local encoded_project_key="$2"

	local failing_diagnostics
	failing_diagnostics=$(echo "$sonar_status" | jq -r '
		[.projectStatus.conditions[]? | select(.status == "ERROR" or .status == "WARN") |
		"- **\(.metricKey)**: actual=\(.actualValue), required \(.comparator) \(.errorThreshold) -- " +
		(if .metricKey == "new_security_hotspots_reviewed" then
			"Review unreviewed security hotspots in SonarCloud UI (mark Safe/Fixed) or fix the flagged code"
		elif .metricKey == "new_reliability_rating" then
			"Fix new bugs introduced in the analysis period"
		elif .metricKey == "new_security_rating" then
			"Fix new vulnerabilities introduced in the analysis period"
		elif .metricKey == "new_maintainability_rating" then
			"Reduce new code smells (extract constants, fix unused vars, simplify conditionals)"
		elif .metricKey == "new_duplicated_lines_density" then
			"Reduce code duplication in new code"
		else
			"Check SonarCloud dashboard for details"
		end)
		] | join("\n")
	') || failing_diagnostics=""

	if [[ -n "$failing_diagnostics" ]]; then
		failing_diagnostics=$(_sanitize_markdown "$failing_diagnostics")
		printf '\n**Failing conditions (badge blockers):**\n%s\n' "$failing_diagnostics"
	fi

	# Fetch unreviewed security hotspots count — this is the most
	# common quality gate blocker for DevOps repos (false positives
	# from shell patterns like curl, npm install, hash algorithms).
	local hotspots_response=""
	hotspots_response=$(curl -sS --fail --connect-timeout 5 --max-time 20 \
		"https://sonarcloud.io/api/hotspots/search?projectKey=${encoded_project_key}&status=TO_REVIEW&ps=5" || echo "")
	if [[ -n "$hotspots_response" ]] && echo "$hotspots_response" | jq -e '.paging' &>/dev/null; then
		local hotspot_total hotspot_details
		hotspot_total=$(echo "$hotspots_response" | jq -r '.paging.total // 0')
		[[ "$hotspot_total" =~ ^[0-9]+$ ]] || hotspot_total=0
		if [[ "$hotspot_total" -gt 0 ]]; then
			hotspot_details=$(echo "$hotspots_response" | jq -r '
				[.hotspots[:5][] |
				"  - `\(.component | split(":") | last):\(.line)` — \(.ruleKey): \(.message | .[0:100])"]
				| join("\n")
			') || hotspot_details=""
			hotspot_details=$(_sanitize_markdown "$hotspot_details")
			printf '\n**Unreviewed security hotspots (%s):**\n%s\n_Review these in SonarCloud UI or fix the underlying code to pass the quality gate._\n' \
				"$hotspot_total" "$hotspot_details"
		fi
	fi

	return 0
}

#######################################
# Run Codacy API check for a repo.
#
# Arguments:
#   $1 - repo slug
# Output: codacy_section markdown to stdout (empty if unavailable)
#######################################
_sweep_codacy() {
	local repo_slug="$1"

	local codacy_token=""
	if command -v gopass &>/dev/null; then
		codacy_token=$(gopass show -o "aidevops/CODACY_API_TOKEN" 2>/dev/null || echo "")
	fi
	[[ -z "$codacy_token" ]] && return 0

	local codacy_org="${repo_slug%%/*}"
	local codacy_repo="${repo_slug##*/}"
	local codacy_response
	codacy_response=$(curl -s -H "api-token: ${codacy_token}" \
		"https://app.codacy.com/api/v3/organizations/gh/${codacy_org}/repositories/${codacy_repo}/issues/search" \
		-X POST -H "Content-Type: application/json" -d '{"limit":1}' 2>/dev/null || echo "")

	if [[ -n "$codacy_response" ]] && echo "$codacy_response" | jq -e '.pagination' &>/dev/null; then
		local codacy_total
		codacy_total=$(echo "$codacy_response" | jq -r '.pagination.total // 0')
		[[ "$codacy_total" =~ ^[0-9]+$ ]] || codacy_total=0
		printf '### Codacy\n\n- **Open issues**: %s\n- **Dashboard**: https://app.codacy.com/gh/%s/%s/dashboard\n' \
			"$codacy_total" "$codacy_org" "$codacy_repo"
	fi

	return 0
}

#######################################
# Build the CodeRabbit trigger section for a quality sweep.
#
# Arguments:
#   $1 - repo slug
#   $2 - sweep_gate_status
#   $3 - sweep_total_issues
# Output: coderabbit_section markdown to stdout
#######################################
_sweep_coderabbit() {
	local repo_slug="$1"
	local sweep_gate_status="$2"
	local sweep_total_issues="$3"

	local prev_state
	prev_state=$(_load_sweep_state "$repo_slug")
	local prev_gate prev_issues prev_high_critical
	IFS='|' read -r prev_gate prev_issues prev_high_critical <<<"$prev_state"
	# Validate numeric fields from state file before arithmetic — corrupted or
	# missing values would cause $(( )) to fail or produce nonsense deltas.
	[[ "$prev_issues" =~ ^[0-9]+$ ]] || prev_issues=0
	[[ "$prev_high_critical" =~ ^[0-9]+$ ]] || prev_high_critical=0

	# First-run guard: if no previous state exists (prev_gate is UNKNOWN from
	# _load_sweep_state default), skip delta-based triggers. Without this, the
	# delta from 0 to current issue count always exceeds the spike threshold,
	# causing every first run (or run after state loss) to trigger a full review.
	if [[ "$prev_gate" == "UNKNOWN" ]]; then
		echo "[stats] CodeRabbit: first run for ${repo_slug} — saved baseline, skipping trigger" >>"$LOGFILE"
		printf '### CodeRabbit\n\n_First sweep run — baseline saved (%s issues, gate %s). Review trigger will activate on next sweep if quality degrades._\n' \
			"$sweep_total_issues" "$sweep_gate_status"
		return 0
	fi

	local issue_delta=$((sweep_total_issues - prev_issues))
	local reasons=()

	# Condition 1: Quality Gate is failing
	if [[ "$sweep_gate_status" == "ERROR" || "$sweep_gate_status" == "WARN" ]]; then
		reasons+=("quality gate ${sweep_gate_status}")
	fi

	# Condition 2: Issue count spiked by threshold or more
	if [[ "$issue_delta" -ge "$CODERABBIT_ISSUE_SPIKE" ]]; then
		reasons+=("issue spike +${issue_delta}")
	fi

	if [[ ${#reasons[@]} -gt 0 ]]; then
		local trigger_reasons=""
		# Use printf -v to avoid subshell overhead (Gemini review on PR #2886)
		printf -v trigger_reasons '%s, ' "${reasons[@]}"
		trigger_reasons="${trigger_reasons%, }"
		echo "[stats] CodeRabbit: active review triggered for ${repo_slug} (${trigger_reasons})" >>"$LOGFILE"
		printf '### CodeRabbit\n\n**Trigger**: %s\n\n@coderabbitai Please run a full codebase review of this repository. Focus on:\n- Security vulnerabilities and credential exposure\n- Shell script quality (error handling, quoting, race conditions)\n- Code duplication and maintainability\n- Documentation accuracy\n' \
			"$trigger_reasons"
	else
		printf '### CodeRabbit\n\n_Monitoring: %s issues (delta: %s), gate %s — no active review needed._\n' \
			"$sweep_total_issues" "$issue_delta" "$sweep_gate_status"
	fi

	return 0
}

#######################################
# Run merged PR review scanner for a repo.
#
# Arguments:
#   $1 - repo slug
# Output: review_scan_section markdown to stdout (empty if unavailable)
#######################################
_sweep_review_scanner() {
	local repo_slug="$1"

	local review_helper="${SCRIPT_DIR}/quality-feedback-helper.sh"
	[[ -x "$review_helper" ]] || return 0

	local scan_output
	scan_output=$("$review_helper" scan-merged \
		--repo "$repo_slug" \
		--batch 30 \
		--create-issues \
		--min-severity medium \
		--json) || scan_output=""

	[[ -z "$scan_output" ]] && return 0
	echo "$scan_output" | jq -e '.scanned' &>/dev/null || return 0

	# Single jq pass: extract all three fields at once
	local scan_data
	scan_data=$(echo "$scan_output" | jq -r '"\(.scanned // 0)|\(.findings // 0)|\(.issues_created // 0)"') || scan_data="0|0|0"
	local scanned="${scan_data%%|*}"
	local remainder="${scan_data#*|}"
	local scan_findings="${remainder%%|*}"
	local scan_issues="${remainder#*|}"
	# Validate integers before any arithmetic comparison
	[[ "$scanned" =~ ^[0-9]+$ ]] || scanned=0
	[[ "$scan_findings" =~ ^[0-9]+$ ]] || scan_findings=0
	[[ "$scan_issues" =~ ^[0-9]+$ ]] || scan_issues=0

	local review_scan_section="### Merged PR Review Scanner

- **PRs scanned**: ${scanned}
- **Findings**: ${scan_findings}
- **Issues created**: ${scan_issues}
"
	if [[ "$scan_findings" -gt 0 ]]; then
		review_scan_section="${review_scan_section}
_Issues labelled \`quality-debt\` — capped at 30% of dispatch concurrency._
"
	fi

	printf '%s' "$review_scan_section"
	return 0
}

#######################################
# Run quality sweep for a single repo
#
# Gathers findings from all available tools and posts a single
# summary comment on the persistent quality review issue.
#
# Arguments:
#   $1 - repo slug
#   $2 - repo path
#######################################

#######################################
# Build the daily quality sweep comment body.
#
# Arguments:
#   $1  - now_iso
#   $2  - repo_slug
#   $3  - tool_count
#   $4  - shellcheck_section
#   $5  - qlty_section
#   $6  - sonar_section
#   $7  - codacy_section
#   $8  - coderabbit_section
#   $9  - review_scan_section
# Output: comment markdown to stdout
#######################################
_build_sweep_comment() {
	local now_iso="$1"
	local repo_slug="$2"
	local tool_count="$3"
	local shellcheck_section="$4"
	local qlty_section="$5"
	local sonar_section="$6"
	local codacy_section="$7"
	local coderabbit_section="$8"
	local review_scan_section="$9"

	cat <<COMMENT
## Daily Code Quality Sweep

**Date**: ${now_iso}
**Repo**: \`${repo_slug}\`
**Tools run**: ${tool_count}

---

${shellcheck_section}
${qlty_section}
${sonar_section}
${codacy_section}
${coderabbit_section}
${review_scan_section}

---
_Auto-generated by stats-wrapper.sh daily quality sweep. The supervisor will review findings and create actionable issues._
COMMENT
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

	local sonar_section=""
	local sonar_raw
	sonar_raw=$(_sweep_sonarcloud "$repo_path")
	if [[ -n "$sonar_raw" ]]; then
		sonar_section="${sonar_raw%%|*}"
		local sonar_remainder="${sonar_raw#*|}"
		sweep_gate_status="${sonar_remainder%%|*}"
		sonar_remainder="${sonar_remainder#*|}"
		sweep_total_issues="${sonar_remainder%%|*}"
		sweep_high_critical="${sonar_remainder#*|}"
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
	printf '%s' "$sonar_section" >"${sections_dir}/sonar"
	printf '%s' "$sweep_gate_status" >"${sections_dir}/sweep_gate_status"
	printf '%s' "$sweep_total_issues" >"${sections_dir}/sweep_total_issues"
	printf '%s' "$sweep_high_critical" >"${sections_dir}/sweep_high_critical"
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
	local sonar_section sweep_gate_status sweep_total_issues sweep_high_critical
	local codacy_section coderabbit_section review_scan_section
	tool_count=$(cat "${sections_dir}/tool_count" 2>/dev/null || echo 0)
	shellcheck_section=$(cat "${sections_dir}/shellcheck" 2>/dev/null || echo "")
	qlty_section=$(cat "${sections_dir}/qlty" 2>/dev/null || echo "")
	qlty_smell_count=$(cat "${sections_dir}/qlty_smell_count" 2>/dev/null || echo 0)
	qlty_grade=$(cat "${sections_dir}/qlty_grade" 2>/dev/null || echo UNKNOWN)
	sonar_section=$(cat "${sections_dir}/sonar" 2>/dev/null || echo "")
	sweep_gate_status=$(cat "${sections_dir}/sweep_gate_status" 2>/dev/null || echo UNKNOWN)
	sweep_total_issues=$(cat "${sections_dir}/sweep_total_issues" 2>/dev/null || echo 0)
	sweep_high_critical=$(cat "${sections_dir}/sweep_high_critical" 2>/dev/null || echo 0)
	codacy_section=$(cat "${sections_dir}/codacy" 2>/dev/null || echo "")
	coderabbit_section=$(cat "${sections_dir}/coderabbit" 2>/dev/null || echo "")
	review_scan_section=$(cat "${sections_dir}/review_scan" 2>/dev/null || echo "")
	rm -rf "$sections_dir"

	if [[ "${tool_count:-0}" -eq 0 ]]; then
		echo "[stats] Quality sweep: no tools available for ${repo_slug}" >>"$LOGFILE"
		return 0
	fi

	# Update issue body dashboard first (best-effort — comment is secondary)
	_update_quality_issue_body "$repo_slug" "$issue_number" \
		"$sweep_gate_status" "$sweep_total_issues" "$sweep_high_critical" \
		"$now_iso" "$tool_count" "$qlty_smell_count" "$qlty_grade"

	# Post daily comment with full findings
	local comment_body
	comment_body=$(_build_sweep_comment \
		"$now_iso" "$repo_slug" "$tool_count" \
		"$shellcheck_section" "$qlty_section" "$sonar_section" \
		"$codacy_section" "$coderabbit_section" "$review_scan_section")

	local comment_stderr=""
	local comment_posted=false
	comment_stderr=$(gh issue comment "$issue_number" --repo "$repo_slug" --body "$comment_body" 2>&1 >/dev/null) && comment_posted=true || {
		echo "[stats] Quality sweep: failed to post comment on #${issue_number} in ${repo_slug}: ${comment_stderr}" >>"$LOGFILE"
	}

	if [[ "$comment_posted" == true ]]; then
		echo "[stats] Quality sweep: posted findings on #${issue_number} in ${repo_slug} (${tool_count} tools)" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Build the simplification-debt issue body for a single file.
#
# Arguments:
#   $1 - file_path
#   $2 - smell_count
#   $3 - rule_breakdown
# Output: issue body markdown to stdout
#######################################
_build_simplification_issue_body() {
	local file_path="$1"
	local smell_count="$2"
	local rule_breakdown="$3"

	cat <<BODY
## Qlty Maintainability — ${file_path}

**Smells detected**: ${smell_count}
**Rules**: ${rule_breakdown}

This file was flagged by the daily quality sweep for high smell density. The smells are primarily function complexity, nested control flow, and return statement count — all reducible via extract-function refactoring.

### Suggested approach

1. Read the file and identify the highest-complexity functions
2. Extract helper functions to reduce per-function complexity below the threshold (~17)
3. Verify with \`qlty smells ${file_path}\` after each change
4. No behavior changes — pure structural refactoring

### Verification

- Syntax check: \`python3 -c "import ast; ast.parse(open('${file_path}').read())"\` (Python) or \`node --check ${file_path}\` (JS/TS)
- Smell check: \`qlty smells ${file_path} --no-snippets --quiet\`
- No public API changes

---
**To approve or decline**, comment on this issue:
- \`approved\` — removes the review gate and queues for automated dispatch
- \`declined: <reason>\` — closes this issue (include your reason after the colon)
BODY
	return 0
}

#######################################
# Create simplification-debt issues for files with high Qlty smell density.
# Bridges the daily quality sweep to the code-simplifier's human-gated
# dispatch pipeline. Issues are created with simplification-debt +
# needs-maintainer-review labels and assigned to the repo maintainer.
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - SARIF JSON string from qlty smells
#
# Behaviour:
#   - Only creates issues for files with >5 smells
#   - Max 3 new issues per sweep (rate limiting)
#   - Deduplicates: skips files that already have an open simplification-debt issue
#   - Issues follow the code-simplifier.md format (needs-maintainer-review gate)
#######################################
_create_simplification_issues() {
	local repo_slug="$1"
	local sarif_json="$2"
	local max_issues_per_sweep=3
	local min_smells_threshold=5
	local issues_created=0

	# Ensure required labels exist (gh issue create fails if labels are missing)
	gh label create "simplification-debt" --repo "$repo_slug" \
		--description "Code simplification opportunity (human-gated via code-simplifier)" \
		--color "C5DEF5" 2>/dev/null || true
	gh label create "needs-maintainer-review" --repo "$repo_slug" \
		--description "Requires maintainer approval before automated dispatch" \
		--color "FBCA04" 2>/dev/null || true
	gh label create "source:quality-sweep" --repo "$repo_slug" \
		--description "Auto-created by stats-functions.sh quality sweep" \
		--color "C2E0C6" --force 2>/dev/null || true

	# Extract files with smell count > threshold, sorted by count descending
	local high_smell_files
	high_smell_files=$(echo "$sarif_json" | jq -r --argjson threshold "$min_smells_threshold" '
		[.runs[0].results[] | .locations[0].physicalLocation.artifactLocation.uri] |
		group_by(.) | map({file: .[0], count: length}) |
		[.[] | select(.count > $threshold)] | sort_by(-.count)[:10] |
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
	total_open=$(gh api graphql -f query="query { repository(owner:\"${repo_slug%%/*}\", name:\"${repo_slug##*/}\") { issues(labels:[\"simplification-debt\"], states:OPEN) { totalCount } } }" \
		--jq '.data.repository.issues.totalCount' 2>/dev/null) || total_open="0"
	if [[ "${total_open:-0}" -ge 200 ]]; then
		echo "[stats] Simplification issues: skipping — ${total_open} open (cap: 200)" >>"$LOGFILE"
		return 0
	fi

	while IFS=$'\t' read -r smell_count file_path; do
		[[ -z "$file_path" ]] && continue
		[[ "$issues_created" -ge "$max_issues_per_sweep" ]] && break

		# Deduplicate via server-side title search — accurate across all issues.
		# The file path is in the title, so searching by path is reliable.
		local existing_count
		existing_count=$(gh issue list --repo "$repo_slug" \
			--label "simplification-debt" --state open \
			--search "in:title \"$file_path\"" \
			--json number --jq 'length' 2>/dev/null) || existing_count="0"
		if [[ "${existing_count:-0}" -gt 0 ]]; then
			continue
		fi

		# Build per-rule breakdown for this file
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
			--label "simplification-debt" --label "needs-maintainer-review" --label "source:quality-sweep" \
			--assignee "$maintainer" \
			--body "$issue_body" >/dev/null 2>&1; then
			issues_created=$((issues_created + 1))
		fi
	done <<<"$high_smell_files"

	if [[ "$issues_created" -gt 0 ]]; then
		qlty_section="${qlty_section}
_Created ${issues_created} simplification-debt issue(s) for high-smell files (needs maintainer review)._
"
	fi

	return 0
}

#######################################
# Compute quality-debt backlog stats for the quality issue dashboard.
#
# Arguments:
#   $1 - repo slug
# Output: pipe-delimited "debt_open|debt_closed|debt_total|debt_resolution_pct"
#######################################
_compute_debt_stats() {
	local repo_slug="$1"

	# Use GraphQL issueCount for accurate totals without pagination limits
	# (CodeRabbit review feedback — gh issue list defaults to 30 results).
	local debt_open=0
	local debt_closed=0
	debt_open=$(gh api graphql \
		-F searchQuery="repo:${repo_slug} is:issue is:open label:quality-debt" \
		-f query="
		query(\$searchQuery: String!) {
			search(query: \$searchQuery, type: ISSUE, first: 1) {
				issueCount
			}
		}" --jq '.data.search.issueCount' 2>>"$LOGFILE" || echo "0")
	debt_closed=$(gh api graphql \
		-F searchQuery="repo:${repo_slug} is:issue is:closed label:quality-debt" \
		-f query="
		query(\$searchQuery: String!) {
			search(query: \$searchQuery, type: ISSUE, first: 1) {
				issueCount
			}
		}" --jq '.data.search.issueCount' 2>>"$LOGFILE" || echo "0")
	# Validate integers
	[[ "$debt_open" =~ ^[0-9]+$ ]] || debt_open=0
	[[ "$debt_closed" =~ ^[0-9]+$ ]] || debt_closed=0
	local debt_total=$((debt_open + debt_closed))
	local debt_resolution_pct=0
	if [[ "$debt_total" -gt 0 ]]; then
		debt_resolution_pct=$((debt_closed * 100 / debt_total))
	fi

	printf '%s|%s|%s|%s' "$debt_open" "$debt_closed" "$debt_total" "$debt_resolution_pct"
	return 0
}

#######################################
# Compute bot review coverage stats for open PRs.
#
# Arguments:
#   $1 - repo slug
# Output: bot_coverage_section markdown to stdout
#######################################
#######################################
# Check bot review status for each open PR and accumulate counts.
#
# Arguments:
#   $1 - pr_objects (newline-delimited compact JSON objects)
#   $2 - repo_slug
#   $3 - review_helper path
# Output: "prs_with_reviews|prs_waiting|prs_stale_waiting"
#######################################
_check_pr_bot_coverage() {
	local pr_objects="$1"
	local repo_slug="$2"
	local review_helper="$3"

	local prs_with_reviews=0
	local prs_waiting=0
	local prs_stale_waiting=""

	while IFS= read -r pr_obj; do
		[[ -z "$pr_obj" ]] && continue
		local pr_num
		pr_num=$(echo "$pr_obj" | jq -r '.number')
		[[ -z "$pr_num" || "$pr_num" == "null" ]] && continue
		local gate_result
		gate_result=$("$review_helper" check "$pr_num" "$repo_slug" 2>>"$LOGFILE" || echo "UNKNOWN")
		case "$gate_result" in
		PASS*)
			prs_with_reviews=$((prs_with_reviews + 1))
			;;
		WAITING* | UNKNOWN*)
			prs_waiting=$((prs_waiting + 1))
			# Check if PR is older than 2 hours (stale waiting).
			local pr_created
			pr_created=$(echo "$pr_obj" | jq -r '.createdAt // empty')
			if [[ -n "$pr_created" ]]; then
				local pr_epoch
				pr_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$pr_created" +%s 2>/dev/null || date -d "$pr_created" +%s 2>/dev/null || echo "0")
				[[ "$pr_epoch" =~ ^[0-9]+$ ]] || pr_epoch=0
				if [[ "$pr_epoch" -gt 0 ]]; then
					local now_epoch
					now_epoch=$(date +%s)
					local pr_age_hours=$(((now_epoch - pr_epoch) / 3600))
					if [[ "$pr_age_hours" -ge 2 ]]; then
						local pr_title
						pr_title=$(echo "$pr_obj" | jq -r '.title[:50] // empty')
						pr_title=$(_sanitize_markdown "$pr_title")
						prs_stale_waiting="${prs_stale_waiting}  - #${pr_num}: ${pr_title} (${pr_age_hours}h old)
"
					fi
				fi
			fi
			;;
		SKIP*)
			prs_with_reviews=$((prs_with_reviews + 1))
			;;
		esac
	done <<<"$pr_objects"

	printf '%s|%s|%s' "$prs_with_reviews" "$prs_waiting" "$prs_stale_waiting"
	return 0
}

_compute_bot_coverage() {
	local repo_slug="$1"

	local open_prs_json
	open_prs_json=$(gh pr list --repo "$repo_slug" --state open \
		--limit 1000 --json number,title,createdAt 2>>"$LOGFILE") || open_prs_json="[]"
	local open_pr_count
	open_pr_count=$(echo "$open_prs_json" | jq 'length' || echo "0")
	[[ "$open_pr_count" =~ ^[0-9]+$ ]] || open_pr_count=0

	local prs_with_reviews=0
	local prs_waiting=0
	local prs_stale_waiting=""
	local review_helper="${SCRIPT_DIR}/review-bot-gate-helper.sh"

	local helper_available=false
	if [[ "$open_pr_count" -gt 0 && -x "$review_helper" ]]; then
		helper_available=true
	fi

	if [[ "$helper_available" == true ]]; then
		# Parse open_prs_json once into per-PR objects to avoid re-parsing the
		# full JSON array on every iteration (Gemini review feedback — GH#3153).
		local pr_objects
		pr_objects=$(echo "$open_prs_json" | jq -c '.[]')
		local coverage_raw
		coverage_raw=$(_check_pr_bot_coverage "$pr_objects" "$repo_slug" "$review_helper")
		prs_with_reviews="${coverage_raw%%|*}"
		local cov_remainder="${coverage_raw#*|}"
		prs_waiting="${cov_remainder%%|*}"
		prs_stale_waiting="${cov_remainder#*|}"
	fi

	# Build bot coverage section — show N/A when helper is unavailable
	# to avoid misleading zero counts (CodeRabbit review feedback)
	local bot_coverage_section=""
	if [[ "$helper_available" == true ]]; then
		bot_coverage_section="### Bot Review Coverage

| Metric | Count |
| --- | --- |
| Open PRs | ${open_pr_count} |
| With bot reviews | ${prs_with_reviews} |
| Awaiting bot review | ${prs_waiting} |
"
	elif [[ "$open_pr_count" -gt 0 ]]; then
		bot_coverage_section="### Bot Review Coverage

| Metric | Count |
| --- | --- |
| Open PRs | ${open_pr_count} |
| With bot reviews | N/A |
| Awaiting bot review | N/A |

_review-bot-gate-helper.sh not available — install to enable bot coverage tracking._
"
	else
		bot_coverage_section="### Bot Review Coverage

_No open PRs._
"
	fi

	if [[ -n "$prs_stale_waiting" ]]; then
		bot_coverage_section="${bot_coverage_section}
**PRs waiting >2h for bot review (may need re-trigger):**
${prs_stale_waiting}"
	fi

	printf '%s' "$bot_coverage_section"
	return 0
}

#######################################
# Compute badge status indicator from gate status and Qlty grade.
#
# Arguments:
#   $1 - gate_status (OK/ERROR/WARN/UNKNOWN)
#   $2 - qlty_grade (A/B/C/D/F/UNKNOWN)
# Output: badge_indicator string to stdout
#######################################
_compute_badge_indicator() {
	local gate_status="$1"
	local qlty_grade="$2"

	local sonar_badge="UNKNOWN"
	case "$gate_status" in
	OK) sonar_badge="GREEN" ;;
	ERROR) sonar_badge="RED" ;;
	WARN) sonar_badge="YELLOW" ;;
	esac

	local qlty_badge="UNKNOWN"
	case "$qlty_grade" in
	A) qlty_badge="GREEN" ;;
	B) qlty_badge="GREEN" ;;
	C) qlty_badge="YELLOW" ;;
	D) qlty_badge="RED" ;;
	F) qlty_badge="RED" ;;
	esac

	local badge_indicator="UNKNOWN"
	if [[ "$sonar_badge" == "GREEN" && "$qlty_badge" == "GREEN" ]]; then
		badge_indicator="GREEN (all badges passing)"
	elif [[ "$sonar_badge" == "RED" || "$qlty_badge" == "RED" ]]; then
		local failing=""
		[[ "$sonar_badge" == "RED" ]] && failing="SonarCloud"
		[[ "$qlty_badge" == "RED" ]] && failing="${failing:+$failing + }Qlty"
		badge_indicator="RED (${failing} failing)"
	elif [[ "$sonar_badge" == "YELLOW" || "$qlty_badge" == "YELLOW" ]]; then
		local warning=""
		[[ "$sonar_badge" == "YELLOW" ]] && warning="SonarCloud"
		[[ "$qlty_badge" == "YELLOW" ]] && warning="${warning:+$warning + }Qlty"
		badge_indicator="YELLOW (${warning} needs improvement)"
	fi

	printf '%s' "$badge_indicator"
	return 0
}

#######################################
# Gather all stats needed for the quality issue dashboard body.
#
# Collects debt backlog, PR scan lifetime stats, bot coverage,
# badge indicator, and simplification progress for a single repo.
#
# Arguments:
#   $1 - repo slug
#   $2 - gate_status (OK/ERROR/WARN/UNKNOWN)
#   $3 - qlty_grade (A/B/C/D/F/UNKNOWN)
# Output: newline-delimited fields:
#   debt_open, debt_closed, debt_total, debt_resolution_pct,
#   prs_scanned_lifetime, issues_created_lifetime,
#   bot_coverage_section, badge_indicator, simplified_count
#######################################
_gather_quality_issue_stats() {
	local repo_slug="$1"
	local gate_status="$2"
	local qlty_grade="$3"

	# Quality-debt backlog stats
	local debt_raw
	debt_raw=$(_compute_debt_stats "$repo_slug")
	local debt_open="${debt_raw%%|*}"
	local debt_remainder="${debt_raw#*|}"
	local debt_closed="${debt_remainder%%|*}"
	debt_remainder="${debt_remainder#*|}"
	local debt_total="${debt_remainder%%|*}"
	local debt_resolution_pct="${debt_remainder#*|}"

	# PR scan lifetime stats from state file
	local slug_safe="${repo_slug//\//-}"
	local scan_state_file="${HOME}/.aidevops/logs/review-scan-state-${slug_safe}.json"
	local prs_scanned_lifetime=0
	local issues_created_lifetime=0
	if [[ -f "$scan_state_file" ]]; then
		prs_scanned_lifetime=$(jq -r '.scanned_prs | length // 0' "$scan_state_file" 2>>"$LOGFILE" || echo "0")
		issues_created_lifetime=$(jq -r '.issues_created // 0' "$scan_state_file" 2>>"$LOGFILE" || echo "0")
	fi
	[[ "$prs_scanned_lifetime" =~ ^[0-9]+$ ]] || prs_scanned_lifetime=0
	[[ "$issues_created_lifetime" =~ ^[0-9]+$ ]] || issues_created_lifetime=0

	# Bot review coverage on open PRs (t1411)
	local bot_coverage_section
	bot_coverage_section=$(_compute_bot_coverage "$repo_slug")

	# Badge status indicator
	local badge_indicator
	badge_indicator=$(_compute_badge_indicator "$gate_status" "$qlty_grade")

	# Simplification progress — count files tracked in simplification state
	local simplified_count=0
	local repo_path
	repo_path=$(jq -r --arg slug "$repo_slug" \
		'.initialized_repos[]? | select(.slug == $slug) | .path // empty' \
		"${HOME}/.config/aidevops/repos.json" 2>/dev/null) || repo_path=""
	local state_file=""
	if [[ -n "$repo_path" ]]; then
		state_file="${repo_path}/.agents/configs/simplification-state.json"
	fi
	if [[ -f "$state_file" ]]; then
		simplified_count=$(jq '.files | length' "$state_file" 2>/dev/null) || simplified_count=0
	fi

	printf '%s\n' \
		"$debt_open" "$debt_closed" "$debt_total" "$debt_resolution_pct" \
		"$prs_scanned_lifetime" "$issues_created_lifetime" \
		"$bot_coverage_section" "$badge_indicator" "$simplified_count"
	return 0
}

#######################################
# Build the quality issue dashboard body markdown.
#
# Pure formatting function — no API calls. All data pre-gathered by caller.
#
# Arguments:
#   $1  - sweep_time
#   $2  - repo_slug
#   $3  - tool_count
#   $4  - badge_indicator
#   $5  - gate_status
#   $6  - total_issues
#   $7  - high_critical
#   $8  - qlty_grade
#   $9  - qlty_smell_count
#   $10 - debt_open
#   $11 - debt_closed
#   $12 - simplified_count
#   $13 - debt_resolution_pct
#   $14 - prs_scanned_lifetime
#   $15 - issues_created_lifetime
#   $16 - bot_coverage_section
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
| SonarCloud issues | ${total_issues} (${high_critical} high/critical) |
| Qlty grade | ${qlty_grade} |
| Qlty smells | ${qlty_smell_count} |

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

#######################################
# Update the quality review issue title if stats have changed.
#
# Avoids unnecessary API calls by comparing the new title to the
# current one before issuing an edit.
#
# Arguments:
#   $1 - issue_number
#   $2 - repo_slug
#   $3 - debt_open
#   $4 - debt_closed
#   $5 - simplified_count
#######################################
_update_quality_issue_title() {
	local issue_number="$1"
	local repo_slug="$2"
	local debt_open="$3"
	local debt_closed="$4"
	local simplified_count="$5"

	local quality_title="Code Audit Routines — Open: ${debt_open} | Closed: ${debt_closed} | Simplified: ${simplified_count}"
	local current_title
	current_title=$(gh issue view "$issue_number" --repo "$repo_slug" --json title --jq '.title' 2>>"$LOGFILE" || echo "")
	if [[ "$current_title" != "$quality_title" ]]; then
		gh issue edit "$issue_number" --repo "$repo_slug" --title "$quality_title" 2>>"$LOGFILE" >/dev/null || true
	fi
	return 0
}

#######################################
# Update the quality review issue body with a stats dashboard
#
# Mirrors the supervisor health issue pattern: the body shows at-a-glance
# stats (gate status, backlog, bot coverage, scan history), while daily
# sweep comments preserve the full history.
#
# Delegates to:
#   _gather_quality_issue_stats  — collects all stats (API calls)
#   _build_quality_issue_body    — assembles markdown (pure formatting)
#   _update_quality_issue_title  — updates title if changed
#
# Arguments:
#   $1 - repo slug
#   $2 - issue number
#   $3 - gate status (OK/ERROR/WARN/UNKNOWN)
#   $4 - total SonarCloud issues
#   $5 - high/critical count
#   $6 - sweep timestamp (ISO)
#   $7 - tool count
#   $8 - qlty smell count (optional)
#   $9 - qlty grade (optional)
#######################################
_update_quality_issue_body() {
	local repo_slug="$1"
	local issue_number="$2"
	local gate_status="$3"
	local total_issues="$4"
	local high_critical="$5"
	local sweep_time="$6"
	local tool_count="$7"
	local qlty_smell_count="${8:-0}"
	local qlty_grade="${9:-UNKNOWN}"

	# Sanitize inputs to single-line values — prevents multi-line tool output
	# (e.g., ShellCheck findings) from leaking into the dashboard table.
	gate_status="${gate_status%%$'\n'*}"
	total_issues="${total_issues%%$'\n'*}"
	high_critical="${high_critical%%$'\n'*}"
	qlty_grade="${qlty_grade%%$'\n'*}"
	qlty_smell_count="${qlty_smell_count%%$'\n'*}"
	# Validate numeric fields — fall back to 0 if corrupted
	[[ "$total_issues" =~ ^[0-9]+$ ]] || total_issues=0
	[[ "$high_critical" =~ ^[0-9]+$ ]] || high_critical=0
	[[ "$qlty_smell_count" =~ ^[0-9]+$ ]] || qlty_smell_count=0

	# Gather all stats via temp file (avoids subshell variable loss)
	local stats_tmp
	stats_tmp=$(mktemp)
	_gather_quality_issue_stats "$repo_slug" "$gate_status" "$qlty_grade" >"$stats_tmp"

	local debt_open debt_closed debt_total debt_resolution_pct
	local prs_scanned_lifetime issues_created_lifetime
	local bot_coverage_section badge_indicator simplified_count
	{
		IFS= read -r debt_open
		IFS= read -r debt_closed
		IFS= read -r debt_total
		IFS= read -r debt_resolution_pct
		IFS= read -r prs_scanned_lifetime
		IFS= read -r issues_created_lifetime
		IFS= read -r bot_coverage_section
		IFS= read -r badge_indicator
		IFS= read -r simplified_count
	} <"$stats_tmp"
	rm -f "$stats_tmp"

	local body
	body=$(_build_quality_issue_body \
		"$sweep_time" "$repo_slug" "$tool_count" "$badge_indicator" \
		"$gate_status" "$total_issues" "$high_critical" \
		"$qlty_grade" "$qlty_smell_count" \
		"$debt_open" "$debt_closed" "$simplified_count" "$debt_resolution_pct" \
		"$prs_scanned_lifetime" "$issues_created_lifetime" "$bot_coverage_section")

	# Update issue body — redirect stderr to log for debugging on failure
	local edit_stderr
	edit_stderr=$(gh issue edit "$issue_number" --repo "$repo_slug" --body "$body" 2>&1 >/dev/null) || {
		echo "[stats] Quality sweep: failed to update body on #${issue_number} in ${repo_slug}: ${edit_stderr}" >>"$LOGFILE"
		return 0
	}

	_update_quality_issue_title "$issue_number" "$repo_slug" \
		"$debt_open" "$debt_closed" "$simplified_count"

	echo "[stats] Quality sweep: updated dashboard on #${issue_number} in ${repo_slug}" >>"$LOGFILE"
	return 0
}
