#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# contributor-insight-helper.sh — File privacy-sanitized upstream issues from
# session-miner output for contributor-role repos (t2147).
# Uses gh_create_issue wrapper (shared-constants.sh) for origin labelling.
#
# When a contributor runs aidevops with a repo they don't own in repos.json
# (role: contributor), the session-miner still runs locally and detects
# instruction candidates, steerage patterns, and error trends. This helper
# takes the compressed_signals.json output and:
#   1. Filters for framework-relevant signals (not project-specific)
#   2. Privacy-sanitizes: strips private repo slugs, file paths outside
#      ~/.aidevops/agents/, client/project names, credential patterns
#   3. Deduplicates against existing open issues on the target repo
#   4. Files upstream issues tagged origin:contributor-insight
#
# Usage:
#   contributor-insight-helper.sh file <compressed_signals.json> <target_slug>
#   contributor-insight-helper.sh file --dry-run <compressed_signals.json> <target_slug>
#   contributor-insight-helper.sh sanitize <text>    # test sanitization
#
# Env:
#   CONTRIBUTOR_INSIGHT_MAX_ISSUES (default 3) — cap per run
#   CONTRIBUTOR_INSIGHT_MIN_CONFIDENCE (default 0.65) — instruction candidate threshold
#
# Called by: session-miner-pulse.sh (for contributor-role repos)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

REPOS_JSON="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
MAX_ISSUES="${CONTRIBUTOR_INSIGHT_MAX_ISSUES:-3}"
MIN_CONFIDENCE="${CONTRIBUTOR_INSIGHT_MIN_CONFIDENCE:-0.65}"

# --- Logging ---

_ci_log() {
	local level="$1"
	local msg="$2"
	printf '[contributor-insight] %s: %s\n' "$level" "$msg" >&2
	return 0
}

# --- Privacy sanitization ---

# _load_private_slugs outputs one slug per line from repos.json entries
# that have mirror_upstream or local_only (same logic as privacy-guard).
_load_private_slugs() {
	if [[ ! -f "$REPOS_JSON" ]]; then
		return 0
	fi
	jq -r '.initialized_repos[]
		| select((.mirror_upstream // false) == true or (.local_only // false) == true)
		| .slug // empty' "$REPOS_JSON" 2>/dev/null || true
	# Also load extra slugs file if present
	local extras="${HOME}/.aidevops/configs/privacy-guard-extra-slugs.txt"
	if [[ -f "$extras" ]]; then
		grep -v '^#' "$extras" 2>/dev/null | grep -v '^$' || true
	fi
	return 0
}

# sanitize_text strips private slugs, non-framework file paths,
# credential patterns, and home directory references from text.
# Arguments: $1 — text to sanitize
# Outputs: sanitized text to stdout
sanitize_text() {
	local text="$1"

	# 1. Strip private repo slugs
	local slug
	while IFS= read -r slug; do
		[[ -z "$slug" ]] && continue
		# Escape for sed
		local escaped
		escaped=$(printf '%s' "$slug" | sed 's/[.[\/*^$]/\\&/g')
		text=$(printf '%s' "$text" | sed "s|${escaped}|[private-repo]|g")
	done < <(_load_private_slugs)

	# 2. Strip absolute file paths outside .agents/ (user project paths)
	text=$(printf '%s' "$text" | sed -E 's|/Users/[^ ]*|[local-path]|g')
	text=$(printf '%s' "$text" | sed -E 's|/home/[^ ]*|[local-path]|g')
	text=$(printf '%s' "$text" | sed -E 's|~/Git/[^ ]*|[local-path]|g')

	# 3. Strip credential patterns (API keys, tokens)
	text=$(printf '%s' "$text" | sed -E 's/(sk-|ghp_|gho_|ghs_|ghu_|glpat-|xoxb-|xoxp-)[A-Za-z0-9_-]{10,}/[redacted-credential]/g')

	# 4. Strip email addresses
	text=$(printf '%s' "$text" | sed -E 's/[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/[email]/g')

	printf '%s' "$text"
	return 0
}

# --- Issue body composition ---

# _compose_instruction_issue builds an issue body from instruction candidates.
# Arguments: $1 — JSON array of candidates (from jq), $2 — contributor gh user
_compose_instruction_issue() {
	local candidates_json="$1"
	local contributor_user="$2"

	local body=""
	body+="## Contributor Insight: Instruction Candidates"$'\n\n'
	body+="Detected from real usage sessions by contributor \`${contributor_user}\`."$'\n'
	body+="These patterns were flagged as persistent guidance that may benefit all users."$'\n\n'
	body+="<!-- aidevops:generator=contributor-insight-helper -->"$'\n\n'

	# Parse candidates and append
	local count
	count=$(printf '%s' "$candidates_json" | jq -r 'length' 2>/dev/null) || count=0
	local i=0
	while [[ "$i" -lt "$count" && "$i" -lt 10 ]]; do
		local conf cat text
		conf=$(printf '%s' "$candidates_json" | jq -r ".[$i].confidence // 0" 2>/dev/null) || conf="0"
		cat=$(printf '%s' "$candidates_json" | jq -r ".[$i].category // \"general\"" 2>/dev/null) || cat="general"
		text=$(printf '%s' "$candidates_json" | jq -r ".[$i].text // \"\"" 2>/dev/null) || text=""
		[[ -z "$text" ]] && {
			i=$((i + 1))
			continue
		}

		# Sanitize the candidate text
		text=$(sanitize_text "$text")
		# Truncate for readability
		[[ ${#text} -gt 300 ]] && text="${text:0:300}..."

		body+="### ${cat} (confidence: ${conf})"$'\n\n'
		body+="> ${text}"$'\n\n'
		i=$((i + 1))
	done

	body+="---"$'\n'
	body+="*Filed automatically by contributor-insight-helper.sh (t2147).*"$'\n'
	body+="*Review these for inclusion in AGENTS.md or build.txt.*"

	printf '%s' "$body"
	return 0
}

# _compose_error_pattern_issue builds an issue body from error patterns.
_compose_error_pattern_issue() {
	local patterns_json="$1"
	local contributor_user="$2"

	local body=""
	body+="## Contributor Insight: Error Patterns"$'\n\n'
	body+="Detected from real usage sessions by contributor \`${contributor_user}\`."$'\n'
	body+="These recurring tool failure patterns may indicate framework gaps."$'\n\n'
	body+="<!-- aidevops:generator=contributor-insight-helper -->"$'\n\n'

	local count
	count=$(printf '%s' "$patterns_json" | jq -r 'length' 2>/dev/null) || count=0
	local i=0
	while [[ "$i" -lt "$count" && "$i" -lt 10 ]]; do
		local tool category pcount models
		tool=$(printf '%s' "$patterns_json" | jq -r ".[$i].tool // \"unknown\"" 2>/dev/null) || tool="unknown"
		category=$(printf '%s' "$patterns_json" | jq -r ".[$i].error_category // \"other\"" 2>/dev/null) || category="other"
		pcount=$(printf '%s' "$patterns_json" | jq -r ".[$i].count // 0" 2>/dev/null) || pcount=0
		models=$(printf '%s' "$patterns_json" | jq -r ".[$i].model_count // 0" 2>/dev/null) || models=0

		body+="- \`${tool}:${category}\` — ${pcount}x across ${models} model(s)"$'\n'
		i=$((i + 1))
	done

	body+=$'\n'"---"$'\n'
	body+="*Filed automatically by contributor-insight-helper.sh (t2147).*"

	printf '%s' "$body"
	return 0
}

# --- Dedup ---

# _issue_exists checks if a similar contributor-insight issue already exists.
# Arguments: $1 — target slug, $2 — search query
_issue_exists() {
	local slug="$1"
	local query="$2"

	local existing
	existing=$(gh issue list --repo "$slug" --state open \
		--label "contributor-insight" \
		--search "$query" \
		--limit 1 --json number --jq 'length' 2>/dev/null) || existing="0"
	[[ "$existing" != "0" ]]
	return $?
}

# --- Main commands ---

# _CI_INSIGHT_CREATED: set to 1 by filing helpers when an issue is created or
# would be created (dry-run). Callers must reset to 0 before each call.
_CI_INSIGHT_CREATED=0

# _file_instruction_candidates — extract and file high-confidence instruction
# candidates. Writes to stdout (dry-run: body; live: log). Sets
# _CI_INSIGHT_CREATED=1 on success.
_file_instruction_candidates() {
	local compressed_file="$1" target_slug="$2"
	local contributor_user="$3" dry_run="$4"
	_CI_INSIGHT_CREATED=0

	local candidates
	candidates=$(jq -c '
		[
			.instruction_candidates
			| to_entries[]
			| .value[]
			| select(.confidence >= '"$MIN_CONFIDENCE"')
		]
		| sort_by(-.confidence)
		| .[:10]
	' "$compressed_file" 2>/dev/null) || candidates="[]"

	local candidate_count
	candidate_count=$(printf '%s' "$candidates" | jq -r 'length' 2>/dev/null) || candidate_count=0
	[[ "$candidate_count" -gt 0 ]] || return 0

	local title="Contributor insight: ${candidate_count} instruction candidate(s) from ${contributor_user}"
	if _issue_exists "$target_slug" "instruction candidate"; then
		_ci_log INFO "Instruction candidates issue already exists — skipping"
		return 0
	fi

	local body
	body=$(_compose_instruction_issue "$candidates" "$contributor_user")
	if [[ "$dry_run" == true ]]; then
		_ci_log INFO "DRY RUN: would create issue: ${title}"
		printf '%s\n' "$body"
		_CI_INSIGHT_CREATED=1
		return 0
	fi
	if gh_create_issue --repo "$target_slug" \
		--title "$title" --body "$body" \
		--label "contributor-insight" 2>/dev/null; then
		_ci_log INFO "Created issue: ${title}"
		_CI_INSIGHT_CREATED=1
	else
		_ci_log ERROR "Failed to create instruction candidates issue"
	fi
	return 0
}

# _file_error_patterns — extract and file high-frequency cross-model error
# patterns. Writes to stdout (dry-run: body; live: log). Sets
# _CI_INSIGHT_CREATED=1 on success.
_file_error_patterns() {
	local compressed_file="$1" target_slug="$2"
	local contributor_user="$3" dry_run="$4"
	_CI_INSIGHT_CREATED=0

	local error_patterns
	error_patterns=$(jq -c '
		[
			.errors.patterns[]
			| select(.count >= 20 and .model_count >= 2)
		]
		| sort_by(-.count)
		| .[:10]
	' "$compressed_file" 2>/dev/null) || error_patterns="[]"

	local error_count
	error_count=$(printf '%s' "$error_patterns" | jq -r 'length' 2>/dev/null) || error_count=0
	[[ "$error_count" -gt 0 ]] || return 0

	local error_title="Contributor insight: ${error_count} recurring error pattern(s) from ${contributor_user}"
	if _issue_exists "$target_slug" "error pattern"; then
		_ci_log INFO "Error patterns issue already exists — skipping"
		return 0
	fi

	local error_body
	error_body=$(_compose_error_pattern_issue "$error_patterns" "$contributor_user")
	if [[ "$dry_run" == true ]]; then
		_ci_log INFO "DRY RUN: would create issue: ${error_title}"
		printf '%s\n' "$error_body"
		_CI_INSIGHT_CREATED=1
		return 0
	fi
	if gh_create_issue --repo "$target_slug" \
		--title "$error_title" --body "$error_body" \
		--label "contributor-insight" 2>/dev/null; then
		_ci_log INFO "Created issue: ${error_title}"
		_CI_INSIGHT_CREATED=1
	else
		_ci_log ERROR "Failed to create error patterns issue"
	fi
	return 0
}

cmd_file() {
	local dry_run=false
	if [[ "${1:-}" == "--dry-run" ]]; then
		dry_run=true
		shift
	fi

	local compressed_file="${1:-}" target_slug="${2:-}"
	if [[ -z "$compressed_file" || -z "$target_slug" ]]; then
		_ci_log ERROR "Usage: contributor-insight-helper.sh file [--dry-run] <compressed_signals.json> <target_slug>"
		return 1
	fi
	if [[ ! -f "$compressed_file" ]]; then
		_ci_log ERROR "Compressed signals file not found: ${compressed_file}"
		return 1
	fi
	if ! command -v gh >/dev/null 2>&1; then
		_ci_log ERROR "gh CLI not found"
		return 1
	fi

	local contributor_user
	contributor_user=$(gh api user --jq '.login' 2>/dev/null) || contributor_user="unknown"

	local issues_created=0

	if [[ "$issues_created" -lt "$MAX_ISSUES" ]]; then
		_file_instruction_candidates "$compressed_file" "$target_slug" "$contributor_user" "$dry_run"
		issues_created=$((issues_created + _CI_INSIGHT_CREATED))
	fi
	if [[ "$issues_created" -lt "$MAX_ISSUES" ]]; then
		_file_error_patterns "$compressed_file" "$target_slug" "$contributor_user" "$dry_run"
		issues_created=$((issues_created + _CI_INSIGHT_CREATED))
	fi

	_ci_log INFO "Complete: ${issues_created} issue(s) created (cap=${MAX_ISSUES})"
	return 0
}

cmd_sanitize() {
	local text="${1:-}"
	if [[ -z "$text" ]]; then
		_ci_log ERROR "Usage: contributor-insight-helper.sh sanitize <text>"
		return 1
	fi
	sanitize_text "$text"
	printf '\n'
	return 0
}

# --- Entry point ---

main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
	file)
		cmd_file "$@"
		;;
	sanitize)
		cmd_sanitize "$@"
		;;
	help | --help | -h)
		printf 'Usage: contributor-insight-helper.sh {file|sanitize|help}\n'
		printf '  file [--dry-run] <compressed_signals.json> <target_slug>\n'
		printf '  sanitize <text>\n'
		return 0
		;;
	*)
		_ci_log ERROR "Unknown command: ${cmd}"
		return 1
		;;
	esac
}

main "$@"
