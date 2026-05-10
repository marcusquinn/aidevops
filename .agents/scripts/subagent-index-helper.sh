#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
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
#   - setup.sh (via .agents/scripts/setup/modules/config.sh)
#   - aidevops update
#   - build-agent workflow (after agent create/promote)
#
# Scans: shared agents, custom/, draft/ (all tiers), plus enabled plugins
#
# Source shared-constants.sh for portable stat functions
# Performance: pure find + awk pipeline, no per-file reads
# =============================================================================

set -euo pipefail

# shellcheck source=shared-constants.sh
_sih_dir="${BASH_SOURCE[0]%/*}"
[[ -f "${_sih_dir}/shared-constants.sh" ]] && source "${_sih_dir}/shared-constants.sh"

AGENTS_DIR="${AIDEVOPS_AGENTS_DIR:-${HOME}/.aidevops/agents}"
INDEX_FILE="${AGENTS_DIR}/subagent-index.toon"
CAPABILITY_INDEX_FILE="${AGENTS_DIR}/agent-source-capabilities.toon"

# Directories to scan for subagents (relative to AGENTS_DIR)
# Covers all tiers: shared, custom, draft; plugins are appended separately
SUBAGENT_DIRS="aidevops content seo tools services workflows memory custom draft"

generate_plugin_agents_block() {
	local agents_dir="$1"
	local plugin_loader="${agents_dir}/scripts/plugin-loader-helper.sh"

	if [[ ! -x "$plugin_loader" ]]; then
		return 0
	fi

	AIDEVOPS_AGENTS_DIR="$agents_dir" "$plugin_loader" index 2>/dev/null || true
	return 0
}

generate_agent_source_capabilities_block() {
	local agents_dir="$1"
	local capability_index="${agents_dir}/agent-source-capabilities.toon"

	if [[ -f "$capability_index" ]]; then
		cat "$capability_index"
	else
		echo "<!--TOON:agent_source_capabilities[0]{source,pack,version,domains,triggers,agents,subagents,commands,helpers,secrets,artifacts,sensitivity,upstream_candidate,status}:"
		echo "-->"
	fi
	return 0
}

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
        if (filename ~ /^(README|AGENTS|SKILL)$/) next
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

	local tmpfile new_block_file plugin_block_file capability_block_file result_file
	tmpfile=$(mktemp)
	new_block_file=$(mktemp)
	plugin_block_file=$(mktemp)
	capability_block_file=$(mktemp)
	result_file=$(mktemp)

	generate_subagents_block "$AGENTS_DIR" >"$new_block_file"
	generate_plugin_agents_block "$AGENTS_DIR" >"$plugin_block_file"
	generate_agent_source_capabilities_block "$AGENTS_DIR" >"$capability_block_file"

	if [[ -f "$INDEX_FILE" ]]; then
		# Preserve existing sections (agents, model_tiers, workflows, scripts),
		# replace the subagents block, and refresh plugin_agents at EOF.
		# Uses sed to delete old block, then inserts new block from file
		local in_block=0
		while IFS= read -r line; do
			if [[ "$line" == "<!--TOON:subagents["* ]]; then
				in_block=1
				cat "$new_block_file"
				continue
			fi
			if [[ "$line" == "<!--TOON:plugin_agents["* ]]; then
				in_block=1
				continue
			fi
			if [[ "$line" == "<!--TOON:agent_source_capabilities["* ]]; then
				in_block=1
				continue
			fi
			if [[ "$in_block" -eq 1 ]]; then
				[[ "$line" == "-->" ]] && in_block=0
				continue
			fi
			echo "$line"
		done <"$INDEX_FILE" >"$result_file"
		if [[ -s "$plugin_block_file" ]]; then
			echo "" >>"$result_file"
			cat "$plugin_block_file" >>"$result_file"
		fi
		echo "" >>"$result_file"
		cat "$capability_block_file" >>"$result_file"
		mv "$result_file" "$tmpfile"
	else
		# No existing file — generate minimal index with just subagents
		cat "$new_block_file" >"$tmpfile"
		if [[ -s "$plugin_block_file" ]]; then
			echo "" >>"$tmpfile"
			cat "$plugin_block_file" >>"$tmpfile"
		fi
		echo "" >>"$tmpfile"
		cat "$capability_block_file" >>"$tmpfile"
	fi

	mv "$tmpfile" "$INDEX_FILE"
	rm -f "$new_block_file" "$plugin_block_file" "$capability_block_file" "$result_file" 2>/dev/null

	# Count entries for summary
	local entry_count
	entry_count=$(grep -c '|' "$INDEX_FILE" 2>/dev/null || true)
	[[ "$entry_count" =~ ^[0-9]+$ ]] || entry_count=0
	echo "Generated ${INDEX_FILE} (${entry_count} entries with key_files)"
	return 0
}

cmd_check() {
	local regenerate_hint="Regenerate with subagent-index-helper.sh generate"
	if [[ ! -f "$INDEX_FILE" ]]; then
		echo "Index not found: ${INDEX_FILE}"
		echo "$regenerate_hint"
		return 1
	fi

	local declared_agent_rows
	declared_agent_rows=$(sed -n 's/^<!--TOON:agents\[\([0-9][0-9]*\)\]{name,file,purpose,model_tier,triggers}:$/\1/p' "$INDEX_FILE")
	if [[ -n "$declared_agent_rows" ]]; then
		local actual_agent_rows
		actual_agent_rows=$(sed -n '/^<!--TOON:agents\[/,/^-->/p' "$INDEX_FILE" |
			awk 'BEGIN { in_block = 0; count = 0 }
				/^<!--TOON:agents\[/ { in_block = 1; next }
				/^-->/ { if (in_block) { in_block = 0 }; next }
				{ if (in_block && NF > 0) { count++ } }
				END { print count }')
		echo "Declared primary agent rows: ${declared_agent_rows}"
		echo "Actual primary agent rows: ${actual_agent_rows}"
		if [[ "$declared_agent_rows" != "$actual_agent_rows" ]]; then
			echo ""
			echo "Error: agents TOON header cardinality mismatch (declared ${declared_agent_rows}, actual ${actual_agent_rows})."
			echo "$regenerate_hint"
			return 1
		fi
	fi

	local declared_rows
	declared_rows=$(sed -n 's/^<!--TOON:subagents\[\([0-9][0-9]*\)\]{folder,purpose,key_files}:$/\1/p' "$INDEX_FILE")
	if [[ -z "$declared_rows" ]]; then
		echo "Error: Could not parse declared subagent row count from ${INDEX_FILE}" >&2
		return 1
	fi

	local actual_block_rows
	actual_block_rows=$(sed -n '/^<!--TOON:subagents\[/,/^-->/p' "$INDEX_FILE" |
		awk 'BEGIN { in_block = 0; count = 0 }
			/^<!--TOON:subagents\[/ { in_block = 1; next }
			/^-->/ { if (in_block) { in_block = 0 }; next }
			{ if (in_block && NF > 0) { count++ } }
			END { print count }')

	local index_mtime
	index_mtime=$(_file_mtime_epoch "$INDEX_FILE")
	local index_age=$(($(date +%s) - index_mtime))

	echo "Index: ${INDEX_FILE}"
	echo "Age: $((index_age / 3600))h $((index_age % 3600 / 60))m"
	echo "Declared subagent rows: ${declared_rows}"
	echo "Actual TOON rows: ${actual_block_rows}"

	local declared_plugin_rows
	declared_plugin_rows=$(sed -n 's/^<!--TOON:plugin_agents\[\([0-9][0-9]*\)\]{folder,purpose,key_files}:$/\1/p' "$INDEX_FILE")
	if [[ -n "$declared_plugin_rows" ]]; then
		local actual_plugin_rows
		actual_plugin_rows=$(sed -n '/^<!--TOON:plugin_agents\[/,/^-->/p' "$INDEX_FILE" |
			awk 'BEGIN { in_block = 0; count = 0 }
				/^<!--TOON:plugin_agents\[/ { in_block = 1; next }
				/^-->/ { if (in_block) { in_block = 0 }; next }
				{ if (in_block && NF > 0) { count++ } }
				END { print count }')
		echo "Declared plugin rows: ${declared_plugin_rows}"
		echo "Actual plugin rows: ${actual_plugin_rows}"
		if [[ "$declared_plugin_rows" != "$actual_plugin_rows" ]]; then
			echo ""
			echo "Error: plugin_agents TOON header cardinality mismatch (declared ${declared_plugin_rows}, actual ${actual_plugin_rows})."
			echo "$regenerate_hint"
			return 1
		fi
	fi

	local declared_capability_rows
	declared_capability_rows=$(sed -n 's/^<!--TOON:agent_source_capabilities\[\([0-9][0-9]*\)\]{source,pack,version,domains,triggers,agents,subagents,commands,helpers,secrets,artifacts,sensitivity,upstream_candidate,status}:$/\1/p' "$INDEX_FILE")
	if [[ -n "$declared_capability_rows" ]]; then
		local actual_capability_rows
		actual_capability_rows=$(sed -n '/^<!--TOON:agent_source_capabilities\[/,/^-->/p' "$INDEX_FILE" |
			awk 'BEGIN { in_block = 0; count = 0 }
				/^<!--TOON:agent_source_capabilities\[/ { in_block = 1; next }
				/^-->/ { if (in_block) { in_block = 0 }; next }
				{ if (in_block && NF > 0) { count++ } }
				END { print count }')
		echo "Declared agent source capability rows: ${declared_capability_rows}"
		echo "Actual agent source capability rows: ${actual_capability_rows}"
		if [[ "$declared_capability_rows" != "$actual_capability_rows" ]]; then
			echo ""
			echo "Error: agent_source_capabilities TOON header cardinality mismatch (declared ${declared_capability_rows}, actual ${actual_capability_rows})."
			echo "$regenerate_hint"
			return 1
		fi
	fi

	if [[ "$declared_rows" != "$actual_block_rows" ]]; then
		echo ""
		echo "Error: TOON header cardinality mismatch (declared ${declared_rows}, actual ${actual_block_rows})."
		echo "$regenerate_hint"
		return 1
	fi

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
	index_leaves=$(awk '
		BEGIN { in_block = 0; count = 0 }
		/^<!--TOON:(subagents|plugin_agents)\[/ { in_block = 1; next }
		/^-->/ { if (in_block) { in_block = 0 }; next }
		{
			if (in_block && NF > 0) {
				split($0, cols, ",")
				if (cols[3] != "") {
					count += split(cols[3], files, "|")
				}
			}
		}
		END { print count }' "$INDEX_FILE")

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
  subagent-index-helper.sh generate    Regenerate the subagents and capability index
  subagent-index-helper.sh check       Show index freshness and coverage
  subagent-index-helper.sh help        Show this help

The index is read by the OpenCode plugin at startup (1 file read vs 500+).
	It covers shared, custom, draft, enabled plugin tiers, and compact private
	agent-source manifest capabilities.

Called automatically by:
  - setup.sh / aidevops update
  - build-agent workflow (after agent create/promote)
EOF
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

command_arg="${1:-help}"

case "$command_arg" in
generate) cmd_generate ;;
check) cmd_check ;;
help | --help | -h) cmd_help ;;
*)
	echo "Unknown command: ${command_arg}" >&2
	cmd_help >&2
	exit 1
	;;
esac
