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
		return 0
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

        # Skip paths containing filtered directories
        if ($0 ~ /\/references\//) next
        if ($0 ~ /\/node_modules\//) next
        if ($0 ~ /\/loop-state\//) next

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
	return 0
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_generate() {
	if [[ ! -d "$AGENTS_DIR" ]]; then
		echo "Error: ${AGENTS_DIR} not found. Run setup.sh first." >&2
		return 1
	fi

	local tmpfile new_block_file result_file
	tmpfile=$(mktemp)
	new_block_file=$(mktemp)
	result_file=$(mktemp)

	generate_subagents_block "$AGENTS_DIR" >"$new_block_file"

	if [[ -f "$INDEX_FILE" ]]; then
		# Preserve existing sections (agents, model_tiers, workflows, scripts)
		# and replace only the subagents block
		# Uses sed to delete old block, then inserts new block from file
		local in_block=0
		while IFS= read -r line; do
			if [[ "$line" == "<!--TOON:subagents["* ]]; then
				in_block=1
				cat "$new_block_file"
				continue
			fi
			if [[ "$in_block" -eq 1 ]]; then
				[[ "$line" == "-->" ]] && in_block=0
				continue
			fi
			echo "$line"
		done <"$INDEX_FILE" >"$result_file"
		mv "$result_file" "$tmpfile"
	else
		# No existing file — generate minimal index with just subagents
		mv "$new_block_file" "$tmpfile"
	fi

	mv "$tmpfile" "$INDEX_FILE"
	rm -f "$new_block_file" "$result_file" 2>/dev/null

	# Count entries for summary
	local entry_count
	entry_count=$(grep -c '|' "$INDEX_FILE" 2>/dev/null || echo "0")
	echo "Generated ${INDEX_FILE} (${entry_count} entries with key_files)"
	return 0
}

cmd_check() {
	if [[ ! -f "$INDEX_FILE" ]]; then
		echo "Index not found: ${INDEX_FILE}"
		echo "Run: subagent-index-helper.sh generate"
		return 1
	fi

	# Cross-platform file mtime: Linux (stat -c) first, macOS (stat -f) fallback
	local index_mtime
	index_mtime=$(stat -c %Y "$INDEX_FILE" 2>/dev/null || stat -f %m "$INDEX_FILE" 2>/dev/null || echo "0")
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
	return 0
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
	return 0
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
