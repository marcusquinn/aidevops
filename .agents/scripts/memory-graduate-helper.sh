#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Memory Graduate Helper - Promote validated memories into shared docs
# =============================================================================
# Identifies high-value memories from the local SQLite DB and graduates them
# into the shared codebase (.agents/) so all users benefit from learnings.
#
# Graduation criteria (configurable):
#   - At least one independently verified positive outcome
#   - Live, unsuperseded, and not a personal USER_PREFERENCE
#   - Not already graduated
#   - Content is actionable (not just session metadata)
#
# Usage:
#   memory-graduate-helper.sh candidates [--limit N] [--min-access N]
#   memory-graduate-helper.sh graduate [--dry-run] [--limit N] [--min-access N]
#   memory-graduate-helper.sh outcome <memory-id> <kind> --verifier ID --source-id ID --provenance TEXT
#   memory-graduate-helper.sh revoke <memory-id> [--corrected-by ID] --reason TEXT
#   memory-graduate-helper.sh status
#   memory-graduate-helper.sh help
#
# Integration:
#   - Called by supervisor pulse (memory audit phase)
#   - Called manually via /graduate-memories command
#   - Writes to .agents/aidevops/graduated-learnings.md
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

readonly MEMORY_DIR="${AIDEVOPS_MEMORY_DIR:-$HOME/.aidevops/.agent-workspace/memory}"
readonly MEMORY_DB="$MEMORY_DIR/memory.db"

# Default graduation thresholds
readonly DEFAULT_MIN_ACCESS=3
readonly DEFAULT_LIMIT=20

# Target file for graduated learnings (relative to repo root)
readonly GRADUATED_FILE_NAME="graduated-learnings.md"
readonly GRADUATED_DESTINATION=".agents/aidevops/graduated-learnings.md"

# Logging: uses shared log_* from shared-constants.sh

#######################################
# SQLite wrapper with busy_timeout
#######################################
db() {
	sqlite3 -cmd ".timeout 5000" "$@"
}

#######################################
# Find the repo root (for writing graduated-learnings.md)
#######################################
find_repo_root() {
	git rev-parse --show-toplevel 2>/dev/null || echo ""
}

#######################################
# Resolve the graduated learnings file path
#######################################
graduated_file_path() {
	if [[ -n "${AIDEVOPS_GRADUATED_FILE:-}" ]]; then
		printf '%s\n' "$AIDEVOPS_GRADUATED_FILE"
		return 0
	fi
	local repo_root
	repo_root=$(find_repo_root)
	if [[ -z "$repo_root" ]]; then
		log_error "Not in a git repository. Cannot locate graduated-learnings.md"
		return 1
	fi
	echo "$repo_root/.agents/aidevops/$GRADUATED_FILE_NAME"
}

#######################################
# Ensure the graduated_at column exists in learning_access
#######################################
ensure_schema() {
	if [[ ! -f "$MEMORY_DB" ]]; then
		log_error "Memory database not found: $MEMORY_DB"
		log_error "Run memory-helper.sh store to initialize."
		return 1
	fi

	local has_truth_tables
	has_truth_tables=$(db "$MEMORY_DB" \
		"SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('learning_truth_events', 'learning_relations');" \
		2>/dev/null || echo "0")
	if [[ "$has_truth_tables" != "2" ]]; then
		local memory_helper="$SCRIPT_DIR/memory-helper.sh"
		if [[ ! -x "$memory_helper" ]]; then
			log_error "Memory migration helper not found: $memory_helper"
			return 1
		fi
		log_info "Migrating memory truth-maintenance schema before graduation..."
		if ! AIDEVOPS_MEMORY_DIR="$MEMORY_DIR" "$memory_helper" validate >/dev/null 2>&1; then
			log_error "Memory schema migration failed; graduation stopped"
			return 1
		fi
	fi

	local has_graduated
	has_graduated=$(db "$MEMORY_DB" \
		"SELECT COUNT(*) FROM pragma_table_info('learning_access') WHERE name='graduated_at';" \
		2>/dev/null || echo "0")

	if [[ "$has_graduated" == "0" ]]; then
		log_info "Migrating schema: adding graduated_at column..."
		db "$MEMORY_DB" \
			"ALTER TABLE learning_access ADD COLUMN graduated_at TEXT DEFAULT NULL;" \
			2>/dev/null || true
		log_success "Schema updated"
	fi

	return 0
}

#######################################
# Return 0 only when content is safe to expose in shared candidate output.
#######################################
is_shareable() {
	local content="$1"
	local scrubbed_content=""

	if [[ "$content" == *"GPG key"* || "$content" == *"pinentry-mac"* ]]; then
		return 1
	fi
	if [[ "$content" =~ [[:alnum:]._+%-]+@[[:alnum:].-]+\.[[:alpha:]]{2,} ]]; then
		return 1
	fi
	scrubbed_content=$(scrub_credentials "$content")
	if [[ "$scrubbed_content" != "$content" ]]; then
		return 1
	fi
	if [[ "$content" == *"/Users/"* || "$content" == *"/home/"* ||
		"$content" == *"~/"* || "$content" == *":\\Users\\"* ||
		"$content" == *"<private>"* || "$content" == *"</private>"* ]]; then
		return 1
	fi
	return 0
}

#######################################
# Filter out session metadata and low-value content.
# Returns 0 if content is actionable, 1 if it should be skipped.
#######################################
is_actionable() {
	local content="$1"

	if ! is_shareable "$content"; then
		return 1
	fi

	# Skip batch retrospectives (session metadata)
	if [[ "$content" == *"Batch retrospective:"* ]]; then
		return 1
	fi

	# Skip session review entries
	if [[ "$content" == *"Session review for batch"* ]]; then
		return 1
	fi

	# Skip "Implemented feature:" one-liners (too vague)
	if [[ "$content" =~ ^Implemented\ feature:\ [a-zA-Z0-9_-]+$ ]]; then
		return 1
	fi

	# Skip pure commit message references (no actionable content)
	if [[ "$content" =~ ^(Merge\ pull\ request|docs:\ (add|mark|update)) ]]; then
		return 1
	fi

	# Skip entries shorter than 20 chars (too terse to be useful)
	if [[ ${#content} -lt 20 ]]; then
		return 1
	fi

	# Skip supervisor task status entries (operational, not learnings)
	if [[ "$content" =~ ^Supervisor\ task\ t[0-9]+ ]]; then
		return 1
	fi

	return 0
}

#######################################
# Categorize a memory into a section for the graduated doc
#######################################
categorize_memory() {
	local type="$1"

	case "$type" in
	WORKING_SOLUTION | ERROR_FIX)
		echo "Solutions & Fixes"
		;;
	FAILED_APPROACH | FAILURE_PATTERN)
		echo "Anti-Patterns (What NOT to Do)"
		;;
	CODEBASE_PATTERN | SUCCESS_PATTERN)
		echo "Patterns & Best Practices"
		;;
	DECISION | ARCHITECTURAL_DECISION)
		echo "Architecture Decisions"
		;;
	TOOL_CONFIG)
		echo "Configuration & Preferences"
		;;
	CONTEXT)
		echo "Context & Background"
		;;
	*)
		echo "General Learnings"
		;;
	esac
}

#######################################
# Run the candidate SQL query and return JSON results
# Args: min_access limit
#######################################
_query_candidates_json() {
	local min_access="$1"
	local limit="$2"
	local raw_results=""

	raw_results=$(
		db -json "$MEMORY_DB" <<EOF
SELECT
    l.id,
    l.type,
    l.content,
    l.tags,
    l.confidence,
    l.created_at,
    COALESCE(a.access_count, 0) as access_count,
    COALESCE(a.last_accessed_at, '') as last_accessed_at,
    s.source_id,
    verified.outcome_id,
    verified.outcome_kind
FROM learnings l
JOIN observations o ON o.observation_id = 'obs_learning_' || l.id
LEFT JOIN learning_access a ON l.id = a.id
JOIN observation_sources s ON s.source_id = (
    SELECT source_id FROM observation_sources source_pick
    WHERE source_pick.observation_id = o.observation_id
      AND NULLIF(TRIM(source_pick.evidence), '') IS NOT NULL
    ORDER BY captured_at DESC, source_id DESC LIMIT 1
)
JOIN observation_outcomes verified ON verified.outcome_id = (
    SELECT outcome_id FROM observation_outcomes outcome_pick
    WHERE outcome_pick.observation_id = o.observation_id
      AND outcome_pick.outcome_kind IN ('test_passed', 'pr_merged', 'operational_verified', 'verified_reuse')
      AND COALESCE(outcome_pick.outcome_value, 1) > 0
    ORDER BY recorded_at DESC, outcome_id DESC LIMIT 1
)
JOIN outcome_verifications verification ON verification.outcome_id = verified.outcome_id
WHERE 1=1
AND l.type != 'USER_PREFERENCE'
AND o.status = 'active'
AND (o.expires_at IS NULL OR o.expires_at > datetime('now'))
AND o.sensitivity IN ('public', 'internal')
AND o.consent != 'denied'
AND (a.graduated_at IS NULL OR a.graduated_at = '')
AND NOT EXISTS (
    SELECT 1 FROM observation_outcomes negative
    WHERE negative.observation_id = o.observation_id
      AND negative.outcome_kind IN ('correction', 'reverted', 'pr_closed', 'rejected', 'stale_escape', 'privacy_escape')
      AND negative.recorded_at >= verified.recorded_at
)
AND NOT EXISTS (
    SELECT 1 FROM observation_promotions p
    WHERE p.observation_id = o.observation_id AND p.destination = '$GRADUATED_DESTINATION'
)
ORDER BY
    COALESCE(a.access_count, 0) DESC,
    l.created_at ASC;
EOF
	)

	while IFS= read -r entry; do
		local content=""
		local tags=""
		content=$(printf '%s' "$entry" | jq -r '.content')
		tags=$(printf '%s' "$entry" | jq -r '.tags // ""')
		if is_shareable "$content" && is_shareable "$tags"; then
			printf '%s\n' "$entry"
		fi
	done < <(printf '%s' "${raw_results:-[]}" | jq -c '.[]') | jq -s ".[:$limit]"
	return 0
}

#######################################
# Print candidates in human-readable text format
# Args: results_json min_access
#######################################
_print_candidates_text() {
	local results="$1"
	local min_access="$2"

	echo "=== Graduation Candidates ==="
	echo ""

	local count=0
	local actionable=0

	while IFS= read -r entry; do
		local id type content confidence access_count
		id=$(echo "$entry" | jq -r '.id')
		type=$(echo "$entry" | jq -r '.type')
		content=$(echo "$entry" | jq -r '.content')
		confidence=$(echo "$entry" | jq -r '.confidence')
		access_count=$(echo "$entry" | jq -r '.access_count')

		count=$((count + 1))

		if is_actionable "$content"; then
			actionable=$((actionable + 1))
			local category
			category=$(categorize_memory "$type")
			echo "  [$type] (confidence: $confidence, accessed: ${access_count}x)"
			echo "  Category: $category"
			echo "  ID: $id"
			echo "  $content"
			echo ""
		else
			echo "  [SKIP] $id - session metadata / low-value"
		fi
	done < <(echo "$results" | jq -c '.[]')

	echo "---"
	echo "Total candidates: $count (actionable: $actionable)"
	echo ""
	echo "Run 'memory-graduate-helper.sh graduate' to promote these to shared docs."

	return 0
}

#######################################
# Parse arguments for cmd_candidates
# Usage: _candidates_parse_args "$@"
# Outputs: newline-separated KEY=VALUE pairs
#######################################
_candidates_parse_args() {
	local limit=$DEFAULT_LIMIT
	local min_access=$DEFAULT_MIN_ACCESS
	local format="text"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--limit | -l)
			limit="$2"
			shift 2
			;;
		--min-access)
			min_access="$2"
			shift 2
			;;
		--json)
			format="json"
			shift
			;;
		*) shift ;;
		esac
	done

	printf '%s\n' \
		"limit=${limit}" \
		"min_access=${min_access}" \
		"format=${format}"
	return 0
}

#######################################
# Find graduation candidates
# Criteria: high confidence OR frequently accessed, live, unsuperseded,
# non-personal, and not yet graduated
#######################################
cmd_candidates() {
	local parsed
	parsed=$(_candidates_parse_args "$@")

	local limit min_access format
	while IFS='=' read -r key val; do
		case "$key" in
		limit) limit="$val" ;;
		min_access) min_access="$val" ;;
		format) format="$val" ;;
		esac
	done <<<"$parsed"

	ensure_schema || return 1

	log_info "Finding graduation candidates (min access: $min_access, limit: $limit)..."
	echo ""

	local results
	results=$(_query_candidates_json "$min_access" "$limit")

	if [[ -z "$results" || "$results" == "[]" ]]; then
		log_info "No graduation candidates found."
		log_info "Memories qualify when live, scoped, shareable, and backed by a verified outcome; access count only ranks candidates"
		return 0
	fi

	if [[ "$format" == "json" ]]; then
		echo "$results"
		return 0
	fi

	_print_candidates_text "$results" "$min_access"
	return 0
}

#######################################
# Collect actionable entries into tmp_dir, grouped by category
# Populates graduated_ids array (by reference via temp file)
# Args: results_json tmp_dir
# Outputs: writes count files to tmp_dir/counts (graduated, skipped)
#          writes id list to tmp_dir/ids
#######################################
_collect_entries() {
	local results="$1"
	local tmp_dir="$2"

	local graduated_count=0
	local skipped_count=0

	while IFS= read -r entry; do
		local id type content confidence access_count outcome_kind
		id=$(echo "$entry" | jq -r '.id')
		type=$(echo "$entry" | jq -r '.type')
		content=$(echo "$entry" | jq -r '.content')
		confidence=$(echo "$entry" | jq -r '.confidence')
		access_count=$(echo "$entry" | jq -r '.access_count')
		outcome_kind=$(echo "$entry" | jq -r '.outcome_kind')

		# Always record the id (actionable or not — both get marked graduated)
		echo "$id" >>"$tmp_dir/ids"

		if ! is_actionable "$content"; then
			skipped_count=$((skipped_count + 1))
			continue
		fi

		local category safe_category
		category=$(categorize_memory "$type")
		safe_category=$(echo "$category" | sed 's/[^a-zA-Z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')

		# Store the real category name in a mapping file
		echo "$category" >"$tmp_dir/${safe_category}.name"

		# Append to category file
		{
			echo "<!-- aidevops:promotion:$id:begin -->"
			echo "- **[$type]** $content"
			echo "  *(confidence: $confidence, verified outcome: $outcome_kind, recalled: ${access_count}x)*"
			echo "<!-- aidevops:promotion:$id:end -->"
			echo ""
		} >>"$tmp_dir/${safe_category}.entries"

		graduated_count=$((graduated_count + 1))
	done < <(echo "$results" | jq -c '.[]')

	# Write counts for caller to read
	echo "$graduated_count" >"$tmp_dir/count_graduated"
	echo "$skipped_count" >"$tmp_dir/count_skipped"

	return 0
}

#######################################
# Print dry-run preview of entries in tmp_dir
# Args: tmp_dir graduated_count skipped_count
#######################################
_preview_entries() {
	local tmp_dir="$1"
	local graduated_count="$2"
	local skipped_count="$3"

	log_info "[DRY RUN] Would graduate $graduated_count memories ($skipped_count skipped)"
	echo ""
	echo "=== Preview of graduated content ==="
	echo ""

	for entries_file in "$tmp_dir"/*.entries; do
		[[ -f "$entries_file" ]] || continue
		local base_name cat_name
		base_name=$(basename "$entries_file" .entries)
		cat_name=$(cat "$tmp_dir/${base_name}.name" 2>/dev/null || echo "$base_name")
		echo "### $cat_name"
		echo ""
		cat "$entries_file"
	done

	return 0
}

#######################################
# Build the markdown content to append from tmp_dir entries
# Args: tmp_dir
# Outputs: prints the markdown block to stdout
#######################################
_build_graduation_content() {
	local tmp_dir="$1"
	local timestamp
	timestamp=$(date -u +"%Y-%m-%d")

	printf '\n## Graduated: %s\n\n' "$timestamp"

	local first_category=true
	for entries_file in "$tmp_dir"/*.entries; do
		[[ -f "$entries_file" ]] || continue
		local base_name cat_name
		base_name=$(basename "$entries_file" .entries)
		cat_name=$(cat "$tmp_dir/${base_name}.name" 2>/dev/null || echo "$base_name")

		# Add blank line before heading (MD022) — skip for first category
		# (already has blank line from ## Graduated header above)
		if [[ "$first_category" == true ]]; then
			first_category=false
		else
			printf '\n'
		fi

		printf '### %s\n\n' "$cat_name"
		cat "$entries_file"
		printf '\n'
	done

	return 0
}

#######################################
# Ensure the graduated learnings file exists with its header
# Args: target_file
#######################################
_ensure_graduated_file() {
	local target_file="$1"

	[[ -f "$target_file" ]] && return 0

	local target_dir
	target_dir=$(dirname "$target_file")
	mkdir -p "$target_dir"

	cat >"$target_file" <<'HEADER'
---
description: Shared learnings graduated from local memory across all users
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: false
  grep: false
  webfetch: false
---

# Graduated Learnings

Validated, shareable learnings promoted from local memory databases into shared documentation.
Personal preferences remain scoped to their user/project profiles and never graduate automatically.

**How memories graduate**: Live, unsuperseded, non-personal memories qualify only
after an independently attributable verified outcome. Recall count affects rank,
not eligibility. Each generated block is marked for precise correction or revocation.

**Categories**:

- **Solutions & Fixes**: Working solutions to real problems
- **Anti-Patterns**: Approaches that failed (avoid repeating)
- **Patterns & Best Practices**: Proven approaches
- **Architecture Decisions**: Key design choices and rationale
- **Configuration & Preferences**: Tool and workflow settings
- **Context & Background**: Important background information

HEADER

	log_info "Created $target_file"
	return 0
}

#######################################
# Parse arguments for cmd_graduate
# Usage: _graduate_parse_args "$@"
# Outputs: newline-separated KEY=VALUE pairs
#######################################
_graduate_parse_args() {
	local dry_run=false
	local limit=$DEFAULT_LIMIT
	local min_access=$DEFAULT_MIN_ACCESS

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--dry-run)
			dry_run=true
			shift
			;;
		--limit | -l)
			limit="$2"
			shift 2
			;;
		--min-access)
			min_access="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	printf '%s\n' \
		"dry_run=${dry_run}" \
		"limit=${limit}" \
		"min_access=${min_access}"
	return 0
}

#######################################
# Collect entries from results into tmp_dir and read back counts/ids
# Args: results tmp_dir
# Outputs: sets graduated_count, skipped_count, graduated_ids[] in caller scope
# (caller must declare these variables before calling)
#######################################
_graduate_collect_and_read() {
	local results="$1"
	local tmp_dir="$2"

	_collect_entries "$results" "$tmp_dir"

	graduated_count=$(cat "$tmp_dir/count_graduated" 2>/dev/null || echo "0")
	skipped_count=$(cat "$tmp_dir/count_skipped" 2>/dev/null || echo "0")

	graduated_ids=()
	if [[ -f "$tmp_dir/ids" ]]; then
		while IFS= read -r id; do
			graduated_ids+=("$id")
		done <"$tmp_dir/ids"
	fi
	return 0
}

#######################################
# Write graduated content to file and mark memories in DB
# Args: tmp_dir target_file graduated_count skipped_count graduated_ids...
#######################################
_graduate_write_and_mark() {
	local tmp_dir="$1"
	local target_file="$2"
	local graduated_count="$3"
	local skipped_count="$4"
	shift 4
	local graduated_ids=("$@")

	local new_content
	new_content=$(_build_graduation_content "$tmp_dir")

	_ensure_graduated_file "$target_file"

	# Append graduated content
	echo "$new_content" >>"$target_file"

	# Mark memories as graduated in the DB
	if [[ ${#graduated_ids[@]} -gt 0 ]]; then
		mark_graduated "${graduated_ids[@]}"
	fi

	log_success "Graduated $graduated_count memories ($skipped_count skipped as metadata)"
	log_info "Updated: $target_file"
	log_info "Remember to commit and push the changes."
	return 0
}

#######################################
# Graduate memories into shared docs
#######################################
cmd_graduate() {
	local parsed
	parsed=$(_graduate_parse_args "$@")

	local dry_run limit min_access
	while IFS='=' read -r key val; do
		case "$key" in
		dry_run) dry_run="$val" ;;
		limit) limit="$val" ;;
		min_access) min_access="$val" ;;
		esac
	done <<<"$parsed"

	ensure_schema || return 1

	local target_file
	target_file=$(graduated_file_path) || return 1

	log_info "Graduating memories to $target_file..."

	local results
	results=$(_query_candidates_json "$min_access" "$limit")

	if [[ -z "$results" || "$results" == "[]" ]]; then
		log_info "No memories to graduate."
		return 0
	fi

	# Collect actionable entries grouped by category into tmp files
	local tmp_dir
	tmp_dir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmp_dir'" EXIT

	local graduated_count skipped_count
	local graduated_ids=()
	_graduate_collect_and_read "$results" "$tmp_dir"

	if [[ "$graduated_count" -eq 0 ]]; then
		log_info "No actionable memories to graduate ($skipped_count skipped as metadata)."
		# Still mark skipped entries so they don't reappear
		if [[ "$dry_run" == false && ${#graduated_ids[@]} -gt 0 ]]; then
			mark_graduated "${graduated_ids[@]}"
		fi
		return 0
	fi

	if [[ "$dry_run" == true ]]; then
		_preview_entries "$tmp_dir" "$graduated_count" "$skipped_count"
		return 0
	fi

	_graduate_write_and_mark "$tmp_dir" "$target_file" \
		"$graduated_count" "$skipped_count" "${graduated_ids[@]+"${graduated_ids[@]}"}"
	return 0
}

#######################################
# Mark memories as graduated in the DB
#######################################
mark_graduated() {
	local timestamp
	timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	for id in "$@"; do
		local escaped_id="${id//"'"/"''"}"
		db "$MEMORY_DB" <<EOF
INSERT INTO learning_access (id, last_accessed_at, access_count, graduated_at)
VALUES ('$escaped_id', datetime('now'), 0, '$timestamp')
ON CONFLICT(id) DO UPDATE SET graduated_at = '$timestamp';
INSERT OR IGNORE INTO observation_promotions (
    promotion_id, observation_id, source_id, outcome_id, destination, status, promoted_at
)
SELECT 'promotion_' || l.id, 'obs_learning_' || l.id, s.source_id, verified.outcome_id,
       '$GRADUATED_DESTINATION', 'active', '$timestamp'
FROM learnings l
JOIN observation_sources s ON s.source_id = (
    SELECT source_id FROM observation_sources WHERE observation_id = 'obs_learning_' || l.id
    AND NULLIF(TRIM(evidence), '') IS NOT NULL ORDER BY captured_at DESC, source_id DESC LIMIT 1
)
JOIN observation_outcomes verified ON verified.outcome_id = (
    SELECT outcome_id FROM observation_outcomes WHERE observation_id = 'obs_learning_' || l.id
    AND outcome_kind IN ('test_passed', 'pr_merged', 'operational_verified', 'verified_reuse')
    AND COALESCE(outcome_value, 1) > 0 ORDER BY recorded_at DESC, outcome_id DESC LIMIT 1
)
JOIN outcome_verifications verification ON verification.outcome_id = verified.outcome_id
WHERE l.id = '$escaped_id';
EOF
	done

	return 0
}

record_outcome() {
	local memory_id="$1"
	local outcome_kind="$2"
	local outcome_value="$3"
	local details="$4"
	local verifier_id="${5:-}"
	local evidence_source_id="${6:-}"
	local verification_provenance="${7:-}"
	local escaped_id="${memory_id//"'"/"''"}"
	local escaped_kind="${outcome_kind//"'"/"''"}"
	local escaped_details="${details//"'"/"''"}"
	local exists=""
	exists=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM observations WHERE observation_id = 'obs_learning_$escaped_id';")
	if [[ "$exists" != "1" ]]; then
		log_error "Memory observation not found: $memory_id"
		return 1
	fi
	db "$MEMORY_DB" "INSERT OR IGNORE INTO observation_outcomes (outcome_id, observation_id, outcome_kind, outcome_value, details, recorded_at) VALUES ('out_${escaped_kind}_${escaped_id}_' || strftime('%Y%m%d%H%M%f','now'), 'obs_learning_$escaped_id', '$escaped_kind', $outcome_value, '$escaped_details', strftime('%Y-%m-%dT%H:%M:%fZ','now'));"
	if [[ -n "$verifier_id" ]]; then
		local escaped_verifier="${verifier_id//"'"/"''"}"
		local escaped_source="${evidence_source_id//"'"/"''"}"
		local escaped_provenance="${verification_provenance//"'"/"''"}"
		db "$MEMORY_DB" "INSERT OR IGNORE INTO outcome_verifications SELECT outcome_id, '$escaped_verifier', '$escaped_source', '$escaped_provenance', recorded_at FROM observation_outcomes WHERE observation_id='obs_learning_$escaped_id' AND outcome_kind='$escaped_kind' ORDER BY recorded_at DESC, outcome_id DESC LIMIT 1;"
	fi
	return 0
}

cmd_outcome() {
	local memory_id="${1:-}"
	local outcome_kind="${2:-}"
	local outcome_value="1"
	local details=""
	local verifier_id=""
	local evidence_source_id=""
	local verification_provenance=""
	[[ -n "$memory_id" && -n "$outcome_kind" ]] || {
		log_error "Usage: outcome <memory-id> <kind> [--value N] [--details TEXT]"
		return 1
	}
	shift 2
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--value)
			[[ $# -ge 2 ]] || { log_error "Option --value requires an argument"; return 1; }
			outcome_value="$2"
			shift 2
			;;
		--details)
			[[ $# -ge 2 ]] || { log_error "Option --details requires an argument"; return 1; }
			details="$2"
			shift 2
			;;
		--verifier)
			[[ $# -ge 2 ]] || { log_error "Option --verifier requires an argument"; return 1; }
			verifier_id="$2"
			shift 2
			;;
		--source-id)
			[[ $# -ge 2 ]] || { log_error "Option --source-id requires an argument"; return 1; }
			evidence_source_id="$2"
			shift 2
			;;
		--provenance)
			[[ $# -ge 2 ]] || { log_error "Option --provenance requires an argument"; return 1; }
			verification_provenance="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done
	[[ "$outcome_value" =~ ^-?[0-9]+([.][0-9]+)?$ ]] || {
		log_error "--value must be numeric"
		return 1
	}
	ensure_schema || return 1
	case "$outcome_kind" in
	test_passed | pr_merged | operational_verified | verified_reuse)
		if [[ -z "$verifier_id" || -z "$evidence_source_id" || -z "$verification_provenance" ]]; then
			log_error "Qualifying outcomes require --verifier, --source-id, and --provenance"
			return 1
		fi
		if [[ "$verifier_id" == "self" ]]; then
			log_error "Qualifying outcomes reject self-asserted verifier identity"
			return 1
		fi
		local escaped_id="${memory_id//"'"/"''"}"
		local escaped_source="${evidence_source_id//"'"/"''"}"
		local escaped_verifier="${verifier_id//"'"/"''"}"
		local attributable=""
		attributable=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM observation_sources s JOIN observations o ON o.observation_id=s.observation_id WHERE s.source_id='$escaped_source' AND s.observation_id='obs_learning_$escaped_id' AND s.source_kind IN ('test_result','pull_request','operation','review') AND NULLIF(TRIM(s.evidence),'') IS NOT NULL AND '$escaped_verifier' NOT IN (COALESCE(o.owner_id,''), COALESCE(o.session_id,''));")
		if [[ "$attributable" != "1" ]]; then
			log_error "Qualifying outcome evidence must be an independent test_result, pull_request, operation, or review source for this observation"
			return 1
		fi
		;;
	esac
	record_outcome "$memory_id" "$outcome_kind" "$outcome_value" "$details" "$verifier_id" "$evidence_source_id" "$verification_provenance"
	log_success "Outcome recorded: $memory_id $outcome_kind"
	return 0
}

remove_promoted_block() {
	local target_file="$1"
	local memory_id="$2"
	local begin_marker="<!-- aidevops:promotion:$memory_id:begin -->"
	local end_marker="<!-- aidevops:promotion:$memory_id:end -->"
	local tmp_file=""
	local skipping=false
	tmp_file=$(mktemp)
	while IFS= read -r line || [[ -n "$line" ]]; do
		if [[ "$line" == "$begin_marker" ]]; then
			skipping=true
			continue
		fi
		if [[ "$skipping" == true ]]; then
			if [[ "$line" == "$end_marker" ]]; then
				skipping=false
			fi
			continue
		fi
		printf '%s\n' "$line" >>"$tmp_file"
	done <"$target_file"
	if [[ "$skipping" == true ]]; then
		rm -f "$tmp_file"
		log_error "Promotion block is missing its end marker: $memory_id"
		return 1
	fi
	mv "$tmp_file" "$target_file"
	return 0
}

cmd_revoke() {
	local memory_id="${1:-}"
	local reason=""
	local corrected_by=""
	[[ -n "$memory_id" ]] || {
		log_error "Usage: revoke <memory-id> [--corrected-by ID] --reason TEXT"
		return 1
	}
	shift
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--reason)
			[[ $# -ge 2 ]] || { log_error "Option --reason requires an argument"; return 1; }
			reason="$2"
			shift 2
			;;
		--corrected-by)
			[[ $# -ge 2 ]] || { log_error "Option --corrected-by requires an argument"; return 1; }
			corrected_by="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done
	[[ -n "$reason" ]] || {
		log_error "Revocation requires --reason"
		return 1
	}
	ensure_schema || return 1
	local escaped_id="${memory_id//"'"/"''"}"
	local escaped_reason="${reason//"'"/"''"}"
	local new_status="revoked"
	local outcome_kind="reverted"
	if [[ -n "$corrected_by" ]]; then
		new_status="corrected"
		outcome_kind="correction"
		local escaped_corrected_by="${corrected_by//"'"/"''"}"
		local correction_exists=""
		correction_exists=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM observations WHERE observation_id='obs_learning_$escaped_corrected_by' AND status='active';")
		if [[ "$correction_exists" != "1" ]]; then
			log_error "Correction observation not found or inactive: $corrected_by"
			return 1
		fi
	fi
	local current_status=""
	current_status=$(db "$MEMORY_DB" "SELECT status FROM observation_promotions WHERE observation_id='obs_learning_$escaped_id' AND destination='$GRADUATED_DESTINATION';")
	if [[ "$current_status" != "active" ]]; then
		log_error "Active promotion not found: $memory_id"
		return 1
	fi
	local target_file=""
	target_file=$(graduated_file_path) || return 1
	if [[ -f "$target_file" ]]; then
		remove_promoted_block "$target_file" "$memory_id" || return 1
	fi
	db "$MEMORY_DB" "UPDATE observation_promotions SET status='$new_status', changed_at=strftime('%Y-%m-%dT%H:%M:%fZ','now'), change_reason='$escaped_reason' WHERE observation_id='obs_learning_$escaped_id' AND status='active'; UPDATE observations SET status='$new_status' WHERE observation_id='obs_learning_$escaped_id';"
	record_outcome "$memory_id" "$outcome_kind" "-1" "$reason"
	if [[ -n "$corrected_by" ]]; then
		db "$MEMORY_DB" "INSERT OR IGNORE INTO observation_relations VALUES ('rel_correction_${escaped_corrected_by}_${escaped_id}', 'obs_learning_$escaped_corrected_by', 'obs_learning_$escaped_id', 'corrects', 'src_learning_$escaped_corrected_by', strftime('%Y-%m-%dT%H:%M:%fZ','now'));"
	fi
	log_success "Promotion $new_status: $memory_id"
	return 0
}

#######################################
# Show graduation status
#######################################
cmd_status() {
	ensure_schema || return 1

	echo ""
	echo "=== Memory Graduation Status ==="
	echo ""

	# Total memories
	local total
	total=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM learnings;" 2>/dev/null || echo "0")
	echo "Total memories: $total"

	# Already graduated
	local graduated
	graduated=$(db "$MEMORY_DB" \
		"SELECT COUNT(*) FROM learning_access WHERE graduated_at IS NOT NULL AND graduated_at != '';" \
		2>/dev/null || echo "0")
	echo "Already graduated: $graduated"

	local total_candidates
	total_candidates=$(_query_candidates_json "$DEFAULT_MIN_ACCESS" 100000 | jq 'length')
	echo "Verified outcome candidates: ${total_candidates:-0}"

	# Check if graduated-learnings.md exists
	local target_file
	target_file=$(graduated_file_path 2>/dev/null || echo "")
	if [[ -n "$target_file" && -f "$target_file" ]]; then
		local line_count
		line_count=$(wc -l <"$target_file" | tr -d ' ')
		echo ""
		echo "Shared doc: $target_file ($line_count lines)"
	else
		echo ""
		echo "Shared doc: not yet created (will be created on first graduation)"
	fi

	echo ""
	return 0
}

#######################################
# Show help
#######################################
cmd_help() {
	cat <<'EOF'
memory-graduate-helper.sh - Promote validated memories into shared docs

Moves high-value learnings from the local SQLite memory database into
version-controlled documentation (.agents/aidevops/graduated-learnings.md)
so all framework users benefit from validated patterns.

USAGE:
    memory-graduate-helper.sh <command> [options]

COMMANDS:
    candidates  List memories eligible for graduation
    graduate    Promote eligible memories to shared docs
    outcome     Record an attributable operational or review outcome
    revoke      Revoke or correct generated shared guidance
    status      Show graduation statistics
    help        Show this help

CANDIDATE OPTIONS:
    --limit N       Max candidates to show (default: 20)
    --json          Output as JSON

GRADUATE OPTIONS:
    --dry-run       Preview without writing changes
    --limit N       Max memories to graduate (default: 20)

GRADUATION CRITERIA:
    A memory qualifies when:
    - A test_passed, pr_merged, operational_verified, or verified_reuse outcome exists
    - The evidence source is live, scoped, non-empty, and privacy-classified
    - No correction, revert, rejection, stale escape, or privacy escape follows it
    - Not already graduated (tracked via graduated_at timestamp)
    - Content is actionable (not session metadata or batch logs)
    Access count only ranks eligible candidates; it never proves usefulness.

CATEGORIES:
    Memories are auto-categorized by type:
    - Solutions & Fixes:        WORKING_SOLUTION, ERROR_FIX
    - Anti-Patterns:            FAILED_APPROACH, FAILURE_PATTERN
    - Patterns & Best Practices: CODEBASE_PATTERN, SUCCESS_PATTERN
    - Architecture Decisions:    DECISION, ARCHITECTURAL_DECISION
    - Configuration:            USER_PREFERENCE, TOOL_CONFIG
    - Context:                  CONTEXT

WORKFLOW:
    1. Memories accumulate in local DB via /remember and auto-capture
    2. Frequently used memories gain access_count
    3. Run 'candidates' to review what qualifies
    4. Run 'graduate --dry-run' to preview
    5. Run 'graduate' to append to shared docs
    6. Commit and push the updated graduated-learnings.md

INTEGRATION:
    - Supervisor pulse: memory audit phase calls this automatically
    - Manual: /graduate-memories slash command
    - CI: Can be run in pre-release checks

EXAMPLES:
    # See what's ready to graduate
    memory-graduate-helper.sh candidates

    # Preview graduation output
    memory-graduate-helper.sh graduate --dry-run

    # Check status
    memory-graduate-helper.sh status
EOF
	return 0
}

#######################################
# Main
#######################################
main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	candidates | list) cmd_candidates "$@" ;;
	graduate | promote) cmd_graduate "$@" ;;
	outcome) cmd_outcome "$@" ;;
	revoke | correct) cmd_revoke "$@" ;;
	status | stats) cmd_status ;;
	help | --help | -h) cmd_help ;;
	*)
		log_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
exit $?
