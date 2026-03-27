#!/usr/bin/env bash
# gh-failure-miner-helper.sh - Mine GitHub ci_activity notifications for systemic failures

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/shared-constants.sh" 2>/dev/null || true

readonly DEFAULT_SINCE_HOURS=24
readonly DEFAULT_LIMIT=100
readonly DEFAULT_MAX_RUN_LOGS=8
readonly DEFAULT_SYSTEMIC_THRESHOLD=3
readonly DEFAULT_MAX_ISSUES=5
readonly DEFAULT_REPOS_JSON="${HOME}/.config/aidevops/repos.json"
readonly DEFAULT_ROUTINE_NAME="gh-failure-miner"
readonly DEFAULT_ROUTINE_SCHEDULE="15 * * * *"
readonly DEFAULT_ROUTINE_TITLE="GH failed notifications: systemic triage"
readonly JQ_COUNT='length'

print_usage() {
	cat <<'EOF'
gh-failure-miner-helper.sh - Mine GitHub failed CI notifications for root causes

Usage:
  gh-failure-miner-helper.sh collect [options]
  gh-failure-miner-helper.sh report [options]
  gh-failure-miner-helper.sh issue-body [options]
  gh-failure-miner-helper.sh create-issues [options]
  gh-failure-miner-helper.sh prefetch [options]
  gh-failure-miner-helper.sh install-launchd-routine [options]

Commands:
  collect     Emit JSON array of failed CI events from notification threads
  report      Print markdown summary with systemic-pattern candidates
  issue-body  Print markdown issue body for top systemic candidate
  create-issues  Create/update systemic root-cause issues for candidate clusters
  prefetch    Print compact pulse-ready summary section
  install-launchd-routine  One-shot launchd installer for systemic failure miner routine

Options:
  --since-hours N     Look back N hours (default: 24)
  --limit N           Notification API page size (default: 100, max: 100)
  --repos CSV         Optional repo allowlist (owner/repo,comma-separated)
  --pulse-repos       Auto-load repo allowlist from repos.json pulse=true entries
  --repos-json PATH   Custom repos.json path (default: ~/.config/aidevops/repos.json)
  --pr-only           Exclude push notifications; analyze PR notifications only
  --no-log-signatures Skip `gh run view --log-failed` signature extraction
  --max-run-logs N    Max workflow runs to inspect for signatures (default: 8)
  --systemic-threshold N  Minimum events per cluster to treat as systemic (default: 3)
  --max-issues N      Max issues to create in one run (default: 5)
  --label NAME        Extra label for created issues (repeatable)
  --dry-run           Show candidate issues without creating them
  --help, -h          Show help

Examples:
  gh-failure-miner-helper.sh collect --since-hours 12 --pulse-repos
  gh-failure-miner-helper.sh report --since-hours 24
  gh-failure-miner-helper.sh issue-body --since-hours 48 --max-run-logs 12
  gh-failure-miner-helper.sh create-issues --since-hours 24 --pulse-repos --label auto-dispatch
  gh-failure-miner-helper.sh install-launchd-routine --dry-run
EOF
	return 0
}

die() {
	local message="$1"
	printf '[ERROR] %s\n' "$message" >&2
	return 1
}

require_option_value() {
	local option_name="$1"
	local arg_count="$2"
	if [[ "$arg_count" -lt 2 ]]; then
		die "${option_name} requires a value"
		return 1
	fi
	return 0
}

require_positive_integer() {
	local option_name="$1"
	local value="$2"
	if [[ ! "$value" =~ ^[0-9]+$ ]]; then
		die "${option_name} must be a positive integer"
		return 1
	fi
	return 0
}

require_tools() {
	if ! command -v gh >/dev/null 2>&1; then
		die "gh CLI is required"
		return 1
	fi
	if ! command -v jq >/dev/null 2>&1; then
		die "jq is required"
		return 1
	fi
	if ! gh auth status >/dev/null 2>&1; then
		die "gh CLI is not authenticated"
		return 1
	fi
	return 0
}

iso_hours_ago() {
	local since_hours="$1"
	if [[ "$(uname -s)" == "Darwin" ]]; then
		date -u -v-"${since_hours}"H +%Y-%m-%dT%H:%M:%SZ
		return 0
	fi
	date -u -d "${since_hours} hours ago" +%Y-%m-%dT%H:%M:%SZ
	return 0
}

repo_in_allowlist() {
	local repo_slug="$1"
	local allowlist_csv="$2"
	if [[ -z "$allowlist_csv" ]]; then
		return 0
	fi
	local normalized
	normalized=",${allowlist_csv},"
	if [[ "$normalized" == *",${repo_slug},"* ]]; then
		return 0
	fi
	return 1
}

parse_run_id_from_details_url() {
	local details_url="$1"
	local run_id
	run_id=$(printf '%s' "$details_url" | sed -nE 's|.*/actions/runs/([0-9]+).*|\1|p')
	printf '%s' "$run_id"
	return 0
}

parse_commit_sha_from_subject_url() {
	local subject_url="$1"
	local commit_sha
	commit_sha=$(printf '%s' "$subject_url" | sed -nE 's|.*/commits/([0-9a-fA-F]{7,40}).*|\1|p')
	printf '%s' "$commit_sha"
	return 0
}

normalize_signature_line() {
	local raw_line="$1"
	local stripped
	stripped=$(printf '%s' "$raw_line" | sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g')
	stripped=$(printf '%s' "$stripped" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')
	if [[ -z "$stripped" ]]; then
		printf '%s' "no_error_signature_detected"
		return 0
	fi
	printf '%s' "$stripped" | cut -c1-220
	return 0
}

extract_failure_signature() {
	local repo_slug="$1"
	local run_id="$2"
	local logs
	logs=$(gh run view "$run_id" --repo "$repo_slug" --log-failed 2>/dev/null || true)
	if [[ -z "$logs" ]]; then
		printf '%s' "no_failed_log_output"
		return 0
	fi

	local candidate
	candidate=$(printf '%s\n' "$logs" | awk 'BEGIN{IGNORECASE=1} /error|exception|traceback|failed|denied|timeout|cannot|invalid|forbidden|unauthorized/ {print; exit}')
	if [[ -z "$candidate" ]]; then
		candidate=$(printf '%s\n' "$logs" | awk 'NF {print; exit}')
	fi

	normalize_signature_line "$candidate"
	return 0
}

fetch_notifications_json() {
	local since_iso="$1"
	local limit="$2"
	# NOSONAR - $limit is validated as [0-9]+ before call; $since_iso is output of date(1) in ISO format
	gh api "notifications?all=true&participating=false&per_page=${limit}&since=${since_iso}"
	return 0
}

load_pulse_repo_allowlist() {
	local repos_json_path="$1"
	if [[ ! -f "$repos_json_path" ]]; then
		printf '%s' ""
		return 0
	fi
	jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and (.slug // "") != "") | .slug' "$repos_json_path" 2>/dev/null | paste -sd ',' -
	return 0
}

resolve_repo_allowlist() {
	local explicit_allowlist="$1"
	local use_pulse_repos="$2"
	local repos_json_path="$3"

	if [[ -n "$explicit_allowlist" ]]; then
		printf '%s' "$explicit_allowlist"
		return 0
	fi

	if [[ "$use_pulse_repos" == "true" ]]; then
		load_pulse_repo_allowlist "$repos_json_path"
		return 0
	fi

	printf '%s' ""
	return 0
}

resolve_source_from_subject() {
	local subject_url="$1"
	local repo_slug="$2"
	local include_push_events="$3"

	local pr_number
	pr_number=$(printf '%s' "$subject_url" | sed -nE 's|.*/pulls/([0-9]+)$|\1|p')

	if [[ -n "$pr_number" ]]; then
		local pr_json
		pr_json=$(gh api "repos/${repo_slug}/pulls/${pr_number}" 2>/dev/null || printf '{}')
		local head_sha
		head_sha=$(printf '%s\n' "$pr_json" | jq -r '.head.sha // empty')
		printf '%s\n' "pr|#${pr_number}|https://github.com/${repo_slug}/pull/${pr_number}|${pr_number}||${head_sha}"
		return 0
	fi

	local commit_sha
	commit_sha=$(parse_commit_sha_from_subject_url "$subject_url")
	if [[ "$include_push_events" != "true" ]] || [[ -z "$commit_sha" ]]; then
		return 1
	fi
	printf '%s\n' "push|${commit_sha:0:12}|https://github.com/${repo_slug}/commit/${commit_sha}||${commit_sha}|${commit_sha}"
	return 0
}

resolve_check_signature() {
	local run_json="$1"
	local run_id="$2"
	local repo_slug="$3"
	local include_logs="$4"
	local run_logs_checked="$5"
	local max_run_logs="$6"

	# For non-GitHub-Actions check runs (e.g., Codacy, SonarCloud), the details_url
	# points to the external app, not a GH Actions run — so run_id is empty and logs
	# can't be extracted. Use the conclusion as the signature instead of "not_collected"
	# to produce meaningful cluster grouping (GH#4696).
	if [[ -z "$run_id" ]]; then
		local app_name conclusion
		app_name=$(printf '%s\n' "$run_json" | jq -r '.app.name // "external"')
		conclusion=$(printf '%s\n' "$run_json" | jq -r '.conclusion // "unknown"')
		printf '%s' "${conclusion}:${app_name}"
		return 0
	fi

	if [[ "$include_logs" == "true" ]] && [[ "$run_logs_checked" -lt "$max_run_logs" ]]; then
		extract_failure_signature "$repo_slug" "$run_id"
		return 0
	fi

	printf '%s' "not_collected"
	return 0
}

emit_event_json() {
	local repo_slug="$1" source_kind="$2" source_ref="$3" source_url="$4"
	local pr_number="$5" commit_sha="$6" check_name="$7" conclusion="$8"
	local run_id="$9" html_url="${10}" details_url="${11}" completed_at="${12}"
	local signature="${13}" notification_updated_at="${14}"

	local pr_url=""
	if [[ -n "$pr_number" ]]; then
		pr_url="https://github.com/${repo_slug}/pull/${pr_number}"
	fi

	jq -n \
		--arg repo "$repo_slug" \
		--arg source_kind "$source_kind" \
		--arg source_ref "$source_ref" \
		--arg source_url "$source_url" \
		--arg pr_number "$pr_number" \
		--arg pr_url "$pr_url" \
		--arg commit_sha "$commit_sha" \
		--arg check_name "$check_name" \
		--arg conclusion "$conclusion" \
		--arg run_id "$run_id" \
		--arg run_url "$html_url" \
		--arg details_url "$details_url" \
		--arg completed_at "$completed_at" \
		--arg signature "$signature" \
		--arg notification_updated_at "$notification_updated_at" \
		'{
			repo: $repo,
			source_kind: $source_kind,
			source_ref: $source_ref,
			source_url: (if $source_url == "" then null else $source_url end),
			pr_number: (if $pr_number == "" then null else ($pr_number | tonumber) end),
			pr_url: (if $pr_url == "" then null else $pr_url end),
			commit_sha: (if $commit_sha == "" then null else $commit_sha end),
			check_name: $check_name,
			conclusion: $conclusion,
			run_id: (if $run_id == "" then null else ($run_id | tonumber) end),
			run_url: (if $run_url == "" then null else $run_url end),
			details_url: (if $details_url == "" then null else $details_url end),
			completed_at: (if $completed_at == "" then null else $completed_at end),
			signature: $signature,
			notification_updated_at: (if $notification_updated_at == "" then null else $notification_updated_at end)
		}'
	return 0
}

# Filter check runs for failures. Two-pass approach:
# 1. Hard failures (failure, cancelled, timed_out, startup_failure) — always collected
# 2. action_required — only from GitHub Actions runs. External apps (Codacy, SonarCloud)
#    use action_required to mean "issues found for developer review", which is informational
#    not a CI failure. Including these creates false systemic clusters (GH#4696).
filter_failed_check_runs() {
	local checks_json="$1"
	printf '%s\n' "$checks_json" | jq '[.check_runs[] | select(
		((.conclusion // "" | ascii_downcase) as $c |
			["failure","cancelled","timed_out","startup_failure"] | index($c))
		or
		((.conclusion // "" | ascii_downcase) == "action_required"
			and (.app.slug // "" | ascii_downcase) == "github-actions")
	)]'
	return 0
}

process_failed_runs() {
	local failed_runs_json="$1"
	local repo_slug="$2" source_kind="$3" source_ref="$4" source_url="$5"
	local pr_number="$6" commit_sha="$7" notification_updated_at="$8"
	local include_logs="$9" run_logs_checked="${10}" max_run_logs="${11}"
	local event_file="${12}"

	local failed_count
	failed_count=$(printf '%s\n' "$failed_runs_json" | jq "$JQ_COUNT")
	local failed_index=0
	while [[ "$failed_index" -lt "$failed_count" ]]; do
		local run_json
		run_json=$(printf '%s\n' "$failed_runs_json" | jq ".[${failed_index}]")

		local check_name conclusion details_url html_url completed_at run_id
		check_name=$(printf '%s\n' "$run_json" | jq -r '.name // "unknown-check"')
		conclusion=$(printf '%s\n' "$run_json" | jq -r '.conclusion // "unknown"')
		details_url=$(printf '%s\n' "$run_json" | jq -r '.details_url // empty')
		html_url=$(printf '%s\n' "$run_json" | jq -r '.html_url // empty')
		completed_at=$(printf '%s\n' "$run_json" | jq -r '.completed_at // empty')
		run_id=$(parse_run_id_from_details_url "$details_url")

		local signature
		signature=$(resolve_check_signature "$run_json" "$run_id" "$repo_slug" "$include_logs" "$run_logs_checked" "$max_run_logs")
		if [[ "$include_logs" == "true" ]] && [[ -n "$run_id" ]] && [[ "$run_logs_checked" -lt "$max_run_logs" ]]; then
			run_logs_checked=$((run_logs_checked + 1))
		fi

		emit_event_json "$repo_slug" "$source_kind" "$source_ref" "$source_url" \
			"$pr_number" "$commit_sha" "$check_name" "$conclusion" \
			"$run_id" "$html_url" "$details_url" "$completed_at" \
			"$signature" "$notification_updated_at" >>"$event_file"

		failed_index=$((failed_index + 1))
	done

	printf '%s' "$run_logs_checked"
	return 0
}

extract_failed_events_json() {
	local since_hours="$1"
	local limit="$2"
	local allowlist_csv="$3"
	local include_logs="$4"
	local max_run_logs="$5"
	local include_push_events="$6"

	local since_iso
	since_iso=$(iso_hours_ago "$since_hours")

	local notifications_json
	notifications_json=$(fetch_notifications_json "$since_iso" "$limit" 2>/dev/null || printf '[]')

	local ci_threads_json
	ci_threads_json=$(printf '%s\n' "$notifications_json" | jq '[.[] | select((.subject.url // "") as $u | (($u | test("/pulls/")) or ($include_push and ($u | test("/commits/")))))]' --argjson include_push "$include_push_events")

	local thread_count
	thread_count=$(printf '%s\n' "$ci_threads_json" | jq "$JQ_COUNT")

	local event_file
	event_file=$(mktemp)
	local run_logs_checked=0

	local index=0
	while [[ "$index" -lt "$thread_count" ]]; do
		local thread_json
		thread_json=$(printf '%s\n' "$ci_threads_json" | jq ".[${index}]")

		local repo_slug
		repo_slug=$(printf '%s\n' "$thread_json" | jq -r '.repository.full_name // empty')
		if [[ -z "$repo_slug" ]] || ! repo_in_allowlist "$repo_slug" "$allowlist_csv"; then
			index=$((index + 1))
			continue
		fi

		local subject_url
		subject_url=$(printf '%s\n' "$thread_json" | jq -r '.subject.url // empty')
		if [[ -z "$subject_url" ]]; then
			index=$((index + 1))
			continue
		fi

		local source_info
		source_info=$(resolve_source_from_subject "$subject_url" "$repo_slug" "$include_push_events") || {
			index=$((index + 1))
			continue
		}

		local source_kind source_ref source_url pr_number commit_sha head_sha
		IFS='|' read -r source_kind source_ref source_url pr_number commit_sha head_sha <<<"$source_info"

		if [[ -z "$head_sha" ]]; then
			index=$((index + 1))
			continue
		fi

		local checks_json
		checks_json=$(gh api "repos/${repo_slug}/commits/${head_sha}/check-runs?per_page=100" 2>/dev/null || printf '{"check_runs":[]}')

		local failed_runs_json
		failed_runs_json=$(filter_failed_check_runs "$checks_json")

		local notification_updated_at
		notification_updated_at=$(printf '%s\n' "$thread_json" | jq -r '.updated_at // empty')

		run_logs_checked=$(process_failed_runs "$failed_runs_json" \
			"$repo_slug" "$source_kind" "$source_ref" "$source_url" \
			"$pr_number" "$commit_sha" "$notification_updated_at" \
			"$include_logs" "$run_logs_checked" "$max_run_logs" "$event_file")

		index=$((index + 1))
	done

	if [[ ! -s "$event_file" ]]; then
		printf '%s\n' '[]'
		rm -f "$event_file"
		return 0
	fi

	jq -s '.' "$event_file"
	rm -f "$event_file"
	return 0
}

render_report_markdown() {
	local events_json="$1"
	local systemic_threshold="$2"
	printf '%s\n' "$events_json" | jq -r '
		def systemic: .count >= $min_count;
		def key: (.check_name + " | " + .signature);
		"## GitHub Failed Notification Report",
		"",
		("- Total failed events: " + ((length) | tostring)),
		("- Unique repos: " + ((map(.repo) | unique | length) | tostring)),
		("- Unique sources: " + ((map(.repo + "|" + .source_kind + "|" + .source_ref) | unique | length) | tostring)),
		("- Push sources: " + ((map(select(.source_kind == "push")) | length) | tostring)),
		("- PR sources: " + ((map(select(.source_kind == "pr")) | length) | tostring)),
		"",
		"### Top Failure Clusters",
		(if length == 0 then
		  "- No failed CI events found in the selected notification window"
		 else
		  (sort_by(key)
		   | group_by(key)
		   | map({
			      check_name: .[0].check_name,
			      signature: .[0].signature,
			      count: length,
			      repos: (map(.repo) | unique),
			      sources: (map(.repo + "|" + .source_kind + "|" + .source_ref) | unique)
			    })
			   | sort_by(-.count)
			   | .[:12]
			   | map("- [" + (if systemic then "SYSTEMIC" else "local" end) + "] " + .check_name + " :: " + .signature + " (" + (.count|tostring) + " events, repos=" + ((.repos|length)|tostring) + ", sources=" + ((.sources|length)|tostring) + ")")
			   | .[])
		 end)
	' --argjson min_count "$systemic_threshold"
	return 0
}

render_issue_body_markdown() {
	local events_json="$1"
	local systemic_threshold="$2"
	printf '%s\n' "$events_json" | jq -r '
		def key: (.check_name + "|" + .signature);
		(sort_by(key)
		 | group_by(key)
		 | map({
			 check_name: .[0].check_name,
			 signature: .[0].signature,
			 count: length,
			 repos: (map(.repo) | unique),
			 sources: (map(.repo + "|" + .source_kind + "|" + .source_ref) | unique),
			 examples: (.[0:5] | map({repo, source_kind, source_ref, source_url, run_url, details_url, conclusion}))
		   })
		 | sort_by(-.count)
		 | .[0]) as $top
		| if ($top == null) then
			"No failed CI events found for the selected notification window."
		  else
			"## Summary\n" +
			"- Pattern: `" + $top.check_name + "`\n" +
			"- Error signature: `" + $top.signature + "`\n" +
			"- Events observed: " + ($top.count|tostring) + "\n" +
			"- Systemic threshold: " + ($min_count|tostring) + "\n" +
			"- Repos impacted: " + (($top.repos|length)|tostring) + "\n\n" +
			"## Why this looks systemic\n" +
			"- The same failing check/signature appears across multiple notifications in a short window.\n" +
			"- Notifications come from PR and/or push check failures, indicating a shared CI/tooling issue.\n\n" +
			"## Evidence\n" +
			($top.examples | map("- " + .repo + " [" + .source_kind + ":" + .source_ref + "] (" + .conclusion + ")" +
			  (if .source_url != null then " - " + .source_url else "" end) +
			  (if .run_url != null then " - " + .run_url else "" end) +
			  (if .details_url != null then " - " + .details_url else "" end)
			) | join("\n")) + "\n\n" +
			"## Root Cause Hypothesis\n" +
			"- Workflow/config regression or shared dependency/integration break in `" + $top.check_name + "`.\n\n" +
			"## Proposed Systemic Fix\n" +
			"- Patch the failing workflow/check once at the source (workflow file, shared action, or toolchain pin), then rerun failed checks on affected PRs.\n" +
			"- Add a regression guard to detect this signature early in future pulses.\n"
		  end
	' --argjson min_count "$systemic_threshold"
	return 0
}

build_repo_clusters_json() {
	local events_json="$1"
	printf '%s\n' "$events_json" | jq '[sort_by(.repo + "|" + .check_name + "|" + .signature) | group_by(.repo + "|" + .check_name + "|" + .signature)[] | {
		repo: .[0].repo,
		check_name: .[0].check_name,
		signature: .[0].signature,
		count: length,
		sources: (map(.source_kind + ":" + .source_ref) | unique),
		examples: (.[0:5] | map({source_kind, source_ref, source_url, run_url, details_url, conclusion}))
	}] | sort_by(-.count)'
	return 0
}

compute_pattern_id() {
	local input_value="$1"
	# SHA-256 for content fingerprinting (not cryptographic security).
	# Truncated to 12 hex chars for human-readable dedup IDs.
	if command -v shasum >/dev/null 2>&1; then
		printf '%s' "$input_value" | shasum -a 256 | awk '{print $1}' | cut -c1-12
		return 0
	fi
	printf '%s' "$input_value" | md5 | cut -c1-12
	return 0
}

build_issue_title() {
	local check_name="$1"
	local count="$2"
	printf 'Systemic CI failure: %s (%s events)' "$check_name" "$count"
	return 0
}

build_issue_body() {
	local cluster_json="$1"
	local pattern_id="$2"
	local threshold="$3"

	printf '%s\n' "$cluster_json" | jq -r '
		"## Summary\n" +
		"- Pattern: `" + .check_name + "`\n" +
		"- Error signature: `" + .signature + "`\n" +
		"- Scope: this repo\n" +
		"- Events observed: " + (.count|tostring) + "\n" +
		"- Systemic threshold: " + ($threshold|tostring) + "\n\n" +
		"## Why this looks systemic\n" +
		"- The same check/signature failed repeatedly within the notification window.\n" +
		"- This suggests a shared workflow/tooling defect rather than a PR-specific code problem.\n\n" +
		"## Evidence\n" +
		(.examples | map("- " + .source_kind + ":" + .source_ref + " (" + .conclusion + ")" +
		  (if .source_url != null then " - " + .source_url else "" end) +
		  (if .run_url != null then " - " + .run_url else "" end) +
		  (if .details_url != null then " - " + .details_url else "" end)
		) | join("\n")) + "\n\n" +
		"## Root Cause Hypothesis\n" +
		"- Regression or external dependency/toolchain break in the shared check path.\n\n" +
		"## Proposed Systemic Fix\n" +
		"- Fix the workflow/check at the source, then rerun failed checks on affected PRs.\n" +
		"- Add a regression guard for this signature in pulse routine outputs.\n\n" +
		"Signal tag: `gh-failure-miner:" + $pattern_id + "`\n"
	' --arg pattern_id "$pattern_id" --argjson threshold "$threshold"
	return 0
}

ensure_repo_labels() {
	local clusters_json="$1"
	printf '%s\n' "$clusters_json" | jq -r '.[].repo' | sort -u | while IFS= read -r repo_entry; do
		gh label create "source:ci-failure-miner" --repo "$repo_entry" \
			--description "Auto-created by gh-failure-miner-helper.sh" --color "C2E0C6" --force || true
	done
	return 0
}

issue_already_exists() {
	local repo_slug="$1"
	local signal_tag="$2"
	local existing_count
	existing_count=$(gh issue list --repo "$repo_slug" --state open --search "\"${signal_tag}\" in:body" --json number --limit 1 2>/dev/null | jq "$JQ_COUNT") || existing_count=0
	[[ "$existing_count" -gt 0 ]]
}

create_or_preview_issue() {
	local cluster_json="$1"
	local pattern_id="$2"
	local systemic_threshold="$3"
	local dry_run="$4"
	shift 4
	local extra_labels=("$@")

	local repo_slug check_name count
	repo_slug=$(printf '%s\n' "$cluster_json" | jq -r '.repo')
	check_name=$(printf '%s\n' "$cluster_json" | jq -r '.check_name')
	count=$(printf '%s\n' "$cluster_json" | jq -r '.count')

	local title
	title=$(build_issue_title "$check_name" "$count")
	local body
	body=$(build_issue_body "$cluster_json" "$pattern_id" "$systemic_threshold")

	if [[ "$dry_run" == "true" ]]; then
		echo "DRY RUN: would create issue: ${title}"
		return 0
	fi

	local create_cmd=(gh issue create --repo "$repo_slug" --title "$title" --body "$body" --label bug --label "source:ci-failure-miner")
	local label
	for label in "${extra_labels[@]}"; do
		if [[ -n "$label" ]]; then
			create_cmd+=(--label "$label")
		fi
	done
	"${create_cmd[@]}" >/dev/null
	echo "Created issue: ${title}"
	return 0
}

create_systemic_issues() {
	local events_json="$1"
	local systemic_threshold="$2"
	local max_issues="$3"
	local dry_run="$4"
	shift 4
	local extra_labels=("$@")

	local clusters_json
	clusters_json=$(build_repo_clusters_json "$events_json")

	local candidate_file
	candidate_file=$(mktemp)
	printf '%s\n' "$clusters_json" | jq --argjson min_count "$systemic_threshold" '[.[] | select(.count >= $min_count)]' >"$candidate_file"

	# Ensure source label exists on repos that will receive issues
	if [[ "$dry_run" != "true" ]]; then
		ensure_repo_labels "$clusters_json"
	fi

	local candidate_count
	candidate_count=$(jq "$JQ_COUNT" "$candidate_file")
	if [[ "$candidate_count" -eq 0 ]]; then
		echo "No systemic clusters met threshold (${systemic_threshold})."
		rm -f "$candidate_file"
		return 0
	fi

	local created=0
	local idx=0
	while [[ "$idx" -lt "$candidate_count" ]] && [[ "$created" -lt "$max_issues" ]]; do
		local cluster_json
		cluster_json=$(jq ".[${idx}]" "$candidate_file")

		local repo_slug check_name signature
		repo_slug=$(printf '%s\n' "$cluster_json" | jq -r '.repo')
		check_name=$(printf '%s\n' "$cluster_json" | jq -r '.check_name')
		signature=$(printf '%s\n' "$cluster_json" | jq -r '.signature')

		local pattern_id
		pattern_id=$(compute_pattern_id "${repo_slug}|${check_name}|${signature}")
		local signal_tag="gh-failure-miner:${pattern_id}"

		if issue_already_exists "$repo_slug" "$signal_tag"; then
			echo "Skipping cluster for ${check_name} - existing open issue with ${signal_tag}"
			idx=$((idx + 1))
			continue
		fi

		create_or_preview_issue "$cluster_json" "$pattern_id" "$systemic_threshold" "$dry_run" "${extra_labels[@]}"

		created=$((created + 1))
		idx=$((idx + 1))
	done

	echo "Processed ${created} systemic cluster(s) (max=${max_issues}, threshold=${systemic_threshold})."
	rm -f "$candidate_file"
	return 0
}

render_prefetch_summary() {
	local events_json="$1"
	local systemic_threshold="$2"
	printf '%s\n' "$events_json" | jq -r '
		def key: (.check_name + "|" + .signature);
		(sort_by(key)
		 | group_by(key)
		 | map({check_name: .[0].check_name, signature: .[0].signature, count: length, repos: (map(.repo) | unique)})
		 | sort_by(-.count)) as $clusters
		| ($clusters | map(select(.count >= $min_count))) as $systemic
		| [
			"## GH Failed Notifications",
			"- failed events: " + ((length) | tostring),
			"- systemic clusters (>= " + ($min_count|tostring) + "): " + (($systemic|length)|tostring),
			(if ($systemic|length) == 0 then
			  "- top cluster: none"
			 else
			  "- top cluster: " + $systemic[0].check_name + " :: " + $systemic[0].signature + " (" + ($systemic[0].count|tostring) + " events, repos=" + (($systemic[0].repos|length)|tostring) + ")"
			 end)
		  ] | .[]
	' --argjson min_count "$systemic_threshold"
	return 0
}

build_routine_prompt() {
	local since_hours="$1"
	local systemic_threshold="$2"
	local max_issues="$3"
	local labels_csv="$4"

	local labels_flags=""
	if [[ -n "$labels_csv" ]]; then
		local label
		IFS=',' read -r -a label_array <<<"$labels_csv"
		for label in "${label_array[@]}"; do
			if [[ -n "$label" ]]; then
				labels_flags+=" --label ${label}"
			fi
		done
	fi

	printf 'Run ~/.aidevops/agents/scripts/gh-failure-miner-helper.sh create-issues --since-hours %s --pulse-repos --systemic-threshold %s --max-issues %s%s and then run ~/.aidevops/agents/scripts/gh-failure-miner-helper.sh report --since-hours %s --pulse-repos.' \
		"$since_hours" "$systemic_threshold" "$max_issues" "$labels_flags" "$since_hours"
	return 0
}

parse_launchd_options() {
	ROUTINE_NAME="$DEFAULT_ROUTINE_NAME"
	ROUTINE_SCHEDULE="$DEFAULT_ROUTINE_SCHEDULE"
	# Resolve to canonical (main) worktree, not a linked worktree.
	# Worktree paths like ~/Git/repo.branch-name get cleaned up, so the plist
	# must point at the main worktree (~/Git/repo) to survive worktree removal.
	local raw_dir
	raw_dir=$(cd "${SCRIPT_DIR}/../.." && pwd)
	ROUTINE_DIR=$(git -C "$raw_dir" worktree list --porcelain 2>/dev/null |
		awk '/^worktree / {print substr($0, 10); exit}') || ROUTINE_DIR=""
	if [[ -z "$ROUTINE_DIR" || ! -d "$ROUTINE_DIR" ]]; then
		ROUTINE_DIR="$raw_dir"
	fi
	ROUTINE_TITLE="$DEFAULT_ROUTINE_TITLE"
	LAUNCHD_SINCE_HOURS="$DEFAULT_SINCE_HOURS"
	LAUNCHD_SYSTEMIC_THRESHOLD="$DEFAULT_SYSTEMIC_THRESHOLD"
	LAUNCHD_MAX_ISSUES="3"
	LAUNCHD_LABELS_CSV="auto-dispatch"
	LAUNCHD_DRY_RUN="false"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--name)
			require_option_value "$1" "$#" || return 1
			ROUTINE_NAME="$2"
			shift 2
			;;
		--schedule)
			require_option_value "$1" "$#" || return 1
			ROUTINE_SCHEDULE="$2"
			shift 2
			;;
		--dir)
			require_option_value "$1" "$#" || return 1
			ROUTINE_DIR="$2"
			shift 2
			;;
		--title)
			require_option_value "$1" "$#" || return 1
			ROUTINE_TITLE="$2"
			shift 2
			;;
		--since-hours)
			require_option_value "$1" "$#" || return 1
			LAUNCHD_SINCE_HOURS="$2"
			shift 2
			;;
		--systemic-threshold)
			require_option_value "$1" "$#" || return 1
			LAUNCHD_SYSTEMIC_THRESHOLD="$2"
			shift 2
			;;
		--max-issues)
			require_option_value "$1" "$#" || return 1
			LAUNCHD_MAX_ISSUES="$2"
			shift 2
			;;
		--labels)
			require_option_value "$1" "$#" || return 1
			LAUNCHD_LABELS_CSV="$2"
			shift 2
			;;
		--dry-run)
			LAUNCHD_DRY_RUN="true"
			shift
			;;
		--help | -h)
			print_usage
			return 2
			;;
		*)
			die "Unknown option for install-launchd-routine: $1"
			return 1
			;;
		esac
	done

	require_positive_integer "--since-hours" "$LAUNCHD_SINCE_HOURS" || return 1
	require_positive_integer "--systemic-threshold" "$LAUNCHD_SYSTEMIC_THRESHOLD" || return 1
	require_positive_integer "--max-issues" "$LAUNCHD_MAX_ISSUES" || return 1
	return 0
}

cmd_install_launchd_routine() {
	parse_launchd_options "$@" || {
		local rc=$?
		if [[ "$rc" -eq 2 ]]; then return 0; fi
		return 1
	}

	local routine_helper="${SCRIPT_DIR}/routine-helper.sh"
	if [[ ! -x "$routine_helper" ]]; then
		die "routine-helper.sh is missing or not executable at ${routine_helper}"
		return 1
	fi

	local prompt
	prompt=$(build_routine_prompt "$LAUNCHD_SINCE_HOURS" "$LAUNCHD_SYSTEMIC_THRESHOLD" "$LAUNCHD_MAX_ISSUES" "$LAUNCHD_LABELS_CSV")

	local action="install-launchd"
	if [[ "$LAUNCHD_DRY_RUN" == "true" ]]; then
		action="plan"
	fi

	bash "$routine_helper" "$action" \
		--name "$ROUTINE_NAME" \
		--schedule "$ROUTINE_SCHEDULE" \
		--dir "$ROUTINE_DIR" \
		--title "$ROUTINE_TITLE" \
		--prompt "$prompt"
	return $?
}

parse_common_options() {
	SINCE_HOURS="$DEFAULT_SINCE_HOURS"
	LIMIT="$DEFAULT_LIMIT"
	REPO_ALLOWLIST=""
	USE_PULSE_REPOS="false"
	REPOS_JSON_PATH="$DEFAULT_REPOS_JSON"
	INCLUDE_PUSH_EVENTS="true"
	INCLUDE_LOG_SIGNATURES="true"
	MAX_RUN_LOGS="$DEFAULT_MAX_RUN_LOGS"
	SYSTEMIC_THRESHOLD="$DEFAULT_SYSTEMIC_THRESHOLD"
	MAX_ISSUES="$DEFAULT_MAX_ISSUES"
	DRY_RUN="false"
	EXTRA_LABELS=()

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--since-hours)
			require_option_value "$1" "$#" || return 1
			SINCE_HOURS="$2"
			shift 2
			;;
		--limit)
			require_option_value "$1" "$#" || return 1
			LIMIT="$2"
			shift 2
			;;
		--repos)
			require_option_value "$1" "$#" || return 1
			REPO_ALLOWLIST="$2"
			shift 2
			;;
		--pulse-repos)
			USE_PULSE_REPOS="true"
			shift
			;;
		--repos-json)
			require_option_value "$1" "$#" || return 1
			REPOS_JSON_PATH="$2"
			shift 2
			;;
		--pr-only)
			INCLUDE_PUSH_EVENTS="false"
			shift
			;;
		--no-log-signatures)
			INCLUDE_LOG_SIGNATURES="false"
			shift
			;;
		--max-run-logs)
			require_option_value "$1" "$#" || return 1
			MAX_RUN_LOGS="$2"
			shift 2
			;;
		--systemic-threshold)
			require_option_value "$1" "$#" || return 1
			SYSTEMIC_THRESHOLD="$2"
			shift 2
			;;
		--max-issues)
			require_option_value "$1" "$#" || return 1
			MAX_ISSUES="$2"
			shift 2
			;;
		--label)
			require_option_value "$1" "$#" || return 1
			EXTRA_LABELS+=("$2")
			shift 2
			;;
		--dry-run)
			DRY_RUN="true"
			shift
			;;
		--help | -h)
			print_usage
			return 2
			;;
		*)
			die "Unknown option: $1"
			return 1
			;;
		esac
	done

	require_positive_integer "--since-hours" "$SINCE_HOURS" || return 1
	require_positive_integer "--limit" "$LIMIT" || return 1
	require_positive_integer "--max-run-logs" "$MAX_RUN_LOGS" || return 1
	require_positive_integer "--systemic-threshold" "$SYSTEMIC_THRESHOLD" || return 1
	require_positive_integer "--max-issues" "$MAX_ISSUES" || return 1

	if [[ "$LIMIT" -gt 100 ]]; then
		LIMIT=100
	fi

	REPO_ALLOWLIST=$(resolve_repo_allowlist "$REPO_ALLOWLIST" "$USE_PULSE_REPOS" "$REPOS_JSON_PATH")

	return 0
}

cmd_collect() {
	parse_common_options "$@" || {
		local rc=$?
		if [[ "$rc" -eq 2 ]]; then
			return 0
		fi
		return 1
	}
	require_tools || return 1

	extract_failed_events_json "$SINCE_HOURS" "$LIMIT" "$REPO_ALLOWLIST" "$INCLUDE_LOG_SIGNATURES" "$MAX_RUN_LOGS" "$INCLUDE_PUSH_EVENTS"
	return $?
}

cmd_report() {
	parse_common_options "$@" || {
		local rc=$?
		if [[ "$rc" -eq 2 ]]; then
			return 0
		fi
		return 1
	}
	require_tools || return 1

	local events_json
	events_json=$(extract_failed_events_json "$SINCE_HOURS" "$LIMIT" "$REPO_ALLOWLIST" "$INCLUDE_LOG_SIGNATURES" "$MAX_RUN_LOGS" "$INCLUDE_PUSH_EVENTS")
	render_report_markdown "$events_json" "$SYSTEMIC_THRESHOLD"
	return 0
}

cmd_issue_body() {
	parse_common_options "$@" || {
		local rc=$?
		if [[ "$rc" -eq 2 ]]; then
			return 0
		fi
		return 1
	}
	require_tools || return 1

	local events_json
	events_json=$(extract_failed_events_json "$SINCE_HOURS" "$LIMIT" "$REPO_ALLOWLIST" "$INCLUDE_LOG_SIGNATURES" "$MAX_RUN_LOGS" "$INCLUDE_PUSH_EVENTS")
	render_issue_body_markdown "$events_json" "$SYSTEMIC_THRESHOLD"
	return 0
}

cmd_create_issues() {
	parse_common_options "$@" || {
		local rc=$?
		if [[ "$rc" -eq 2 ]]; then
			return 0
		fi
		return 1
	}
	require_tools || return 1

	local events_json
	events_json=$(extract_failed_events_json "$SINCE_HOURS" "$LIMIT" "$REPO_ALLOWLIST" "$INCLUDE_LOG_SIGNATURES" "$MAX_RUN_LOGS" "$INCLUDE_PUSH_EVENTS")
	if [[ -n "${EXTRA_LABELS+x}" ]] && [[ "${#EXTRA_LABELS[@]}" -gt 0 ]]; then
		create_systemic_issues "$events_json" "$SYSTEMIC_THRESHOLD" "$MAX_ISSUES" "$DRY_RUN" "${EXTRA_LABELS[@]}"
		return 0
	fi
	create_systemic_issues "$events_json" "$SYSTEMIC_THRESHOLD" "$MAX_ISSUES" "$DRY_RUN"
	return 0
}

cmd_prefetch() {
	parse_common_options "$@" || {
		local rc=$?
		if [[ "$rc" -eq 2 ]]; then
			return 0
		fi
		return 1
	}
	require_tools || return 1

	local events_json
	events_json=$(extract_failed_events_json "$SINCE_HOURS" "$LIMIT" "$REPO_ALLOWLIST" "$INCLUDE_LOG_SIGNATURES" "$MAX_RUN_LOGS" "$INCLUDE_PUSH_EVENTS")
	render_prefetch_summary "$events_json" "$SYSTEMIC_THRESHOLD"
	return 0
}

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	collect)
		cmd_collect "$@"
		return $?
		;;
	report)
		cmd_report "$@"
		return $?
		;;
	issue-body)
		cmd_issue_body "$@"
		return $?
		;;
	create-issues)
		cmd_create_issues "$@"
		return $?
		;;
	prefetch)
		cmd_prefetch "$@"
		return $?
		;;
	install-launchd-routine)
		cmd_install_launchd_routine "$@"
		return $?
		;;
	help | --help | -h)
		print_usage
		return 0
		;;
	*)
		die "Unknown command: $command"
		print_usage
		return 1
		;;
	esac
}

main "$@"
