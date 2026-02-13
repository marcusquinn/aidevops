#!/usr/bin/env bash
# =============================================================================
# Subagent Index Generator (t1040)
# =============================================================================
# Generates the subagents section of subagent-index.toon from actual files.
# This index is read by the OpenCode plugin at startup (1 file vs 500+ scans).
#
# Usage:
#   subagent-index-helper.sh generate    # Regenerate the index
#   subagent-index-helper.sh check       # Show stale/missing entries
#   subagent-index-helper.sh help        # Show this help
#
# Called by:
#   - setup.sh (via setup-modules/config.sh)
#   - aidevops update
#   - build-agent workflow (after agent create/promote)
#
# Scans: shared agents, custom/, draft/ (all tiers)
# Performance: pure find + awk pipeline, no per-file reads
# =============================================================================

set -euo pipefail

AGENTS_DIR="${HOME}/.aidevops/agents"
INDEX_FILE="${AGENTS_DIR}/subagent-index.toon"

# Directories to scan for subagents (relative to AGENTS_DIR)
# Covers all tiers: shared, custom, draft
SUBAGENT_DIRS="aidevops content seo tools services workflows memory custom draft"

# ---------------------------------------------------------------------------
# Generate subagents block: pure find + awk (no per-file reads)
# ---------------------------------------------------------------------------

generate_subagents_block() {
	local agents_dir="$1"
	local search_dirs=""

	# Build list of existing directories to scan
	for subdir in $SUBAGENT_DIRS; do
		local dir_path="${agents_dir}/${subdir}"
		if [[ -d "$dir_path" ]]; then
			search_dirs="${search_dirs} ${dir_path}"
		fi
	done

	if [[ -z "$search_dirs" ]]; then
		echo "<!--TOON:subagents[0]{folder,purpose,key_files}:"
		echo "-->"
		return
	fi

	# Single find + awk pipeline: no shell loops, no per-file reads
	# shellcheck disable=SC2086
	find $search_dirs -name "*.md" -type f 2>/dev/null | sort | awk -v agents_dir="$agents_dir" '
    BEGIN { count = 0 }
    {
        # Extract filename without .md
        n = split($0, path_parts, "/")
        filename = path_parts[n]
        sub(/\.md$/, "", filename)

        # Skip non-agent files
        if (filename ~ /^(README|AGENTS|SKILL|SKILL-SCAN-RESULTS)$/) next
        if (filename ~ /-skill$/) next

        # Get directory relative to agents_dir
        dir_rel = $0
        idx = index(dir_rel, agents_dir "/")
        if (idx == 1) dir_rel = substr(dir_rel, length(agents_dir) + 2)
        # Remove filename to get directory
        last_slash = 0
        for (i = 1; i <= length(dir_rel); i++) {
            if (substr(dir_rel, i, 1) == "/") last_slash = i
        }
        if (last_slash > 0) dir_rel = substr(dir_rel, 1, last_slash - 1)
        else dir_rel = ""

        if (dir_rel == "") next

        # Group by directory
        if (dir_rel != prev_dir) {
            if (prev_dir != "") {
                lines[count++] = prev_dir "/," prev_dir " subagents," files
            }
            prev_dir = dir_rel
            files = filename
        } else {
            files = files "|" filename
        }
    }
    END {
        if (prev_dir != "") {
            lines[count++] = prev_dir "/," prev_dir " subagents," files
        }
        print "<!--TOON:subagents[" count "]{folder,purpose,key_files}:"
        for (i = 0; i < count; i++) print lines[i]
        print "-->"
    }'
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_generate() {
	if [[ ! -d "$AGENTS_DIR" ]]; then
		echo "Error: ${AGENTS_DIR} not found. Run setup.sh first." >&2
		return 1
	fi

	local tmpfile
	tmpfile=$(mktemp)
	local new_subagents
	new_subagents=$(generate_subagents_block "$AGENTS_DIR")

	if [[ -f "$INDEX_FILE" ]]; then
		# Preserve existing sections (agents, model_tiers, workflows, scripts)
		# and replace only the subagents block
		awk -v new_block="$new_subagents" '
        /^<!--TOON:subagents\[/ { in_block = 1; print new_block; next }
        in_block && /^-->/ { in_block = 0; next }
        !in_block { print }
        ' "$INDEX_FILE" >"$tmpfile"
	else
		# No existing file — generate minimal index with just subagents
		echo "$new_subagents" >"$tmpfile"
	fi

	mv "$tmpfile" "$INDEX_FILE"

	# Count entries for summary
	local entry_count
	entry_count=$(grep -c '|' "$INDEX_FILE" 2>/dev/null || echo "0")
	echo "Generated ${INDEX_FILE} (${entry_count} entries with key_files)"
}

cmd_check() {
	if [[ ! -f "$INDEX_FILE" ]]; then
		echo "Index not found: ${INDEX_FILE}"
		echo "Run: subagent-index-helper.sh generate"
		return 1
	fi

	# macOS stat vs GNU stat
	local index_mtime
	if stat -f %m "$INDEX_FILE" >/dev/null 2>&1; then
		index_mtime=$(stat -f %m "$INDEX_FILE")
	else
		index_mtime=$(stat -c %Y "$INDEX_FILE")
	fi
	local index_age=$(($(date +%s) - index_mtime))

	echo "Index: ${INDEX_FILE}"
	echo "Age: $((index_age / 3600))h $((index_age % 3600 / 60))m"

	# Count actual .md files
	local actual_count=0
	for subdir in $SUBAGENT_DIRS; do
		local dir_path="${AGENTS_DIR}/${subdir}"
		[[ -d "$dir_path" ]] || continue
		local c
		c=$(find "$dir_path" -name "*.md" -type f \
			-not -name "README.md" -not -name "AGENTS.md" \
			-not -name "*-skill.md" 2>/dev/null | wc -l | tr -d ' ')
		actual_count=$((actual_count + c))
	done

	# Count index leaf entries (pipe-separated names)
	local index_leaves
	index_leaves=$(sed -n '/^<!--TOON:subagents/,/^-->/p' "$INDEX_FILE" |
		grep -v '^<!--' | grep -v '^-->' |
		tr ',' '\n' | grep '|' | tr '|' '\n' | wc -l | tr -d ' ')

	echo "Actual .md files: ${actual_count}"
	echo "Index leaf entries: ${index_leaves}"

	if [[ "$index_age" -gt 86400 ]]; then
		echo ""
		echo "Warning: Index is over 24h old. Run: subagent-index-helper.sh generate"
	fi
}

cmd_help() {
	cat <<'EOF'
subagent-index-helper.sh — Generate subagent-index.toon

Usage:
  subagent-index-helper.sh generate    Regenerate the subagents index
  subagent-index-helper.sh check       Show index freshness and coverage
  subagent-index-helper.sh help        Show this help

The index is read by the OpenCode plugin at startup (1 file read vs 500+).
It covers shared, custom, and draft agent tiers.

Called automatically by:
  - setup.sh / aidevops update
  - build-agent workflow (after agent create/promote)
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

case "${1:-help}" in
generate) cmd_generate ;;
check) cmd_check ;;
help | --help | -h) cmd_help ;;
*)
	echo "Unknown command: $1" >&2
	cmd_help >&2
	exit 1
	;;
esac
