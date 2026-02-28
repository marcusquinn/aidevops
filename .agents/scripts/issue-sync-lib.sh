#!/usr/bin/env bash
# =============================================================================
# aidevops Issue Sync Library — Platform-Agnostic Functions (t1120.1)
# =============================================================================
# Shared functions extracted from issue-sync-helper.sh that have no dependency
# on any specific git platform (GitHub, Gitea, GitLab).
#
# Covers three functional areas:
#   1. Parse   — TODO.md / PLANS.md / PRD file parsing
#   2. Compose — Issue body composition from task context
#   3. Ref     — ref:GH# and pr:# management in TODO.md
#
# Usage: source "${SCRIPT_DIR}/issue-sync-lib.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, log_verbose, sed_inplace)
#   - bash 3.2+, awk, sed, grep
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced — would affect caller)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_ISSUE_SYNC_LIB_LOADED:-}" ]] && return 0
_ISSUE_SYNC_LIB_LOADED=1

# Source shared-constants.sh to make the library self-contained.
# Resolves SCRIPT_DIR from BASH_SOURCE so it works when sourced from any location.
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	# Pure-bash dirname replacement — avoids external binary dependency
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi
source "${SCRIPT_DIR}/shared-constants.sh"

# =============================================================================
# Parse — TODO.md Utilities
# =============================================================================

# Strip lines inside markdown code-fenced blocks (``` ... ```) from stdin.
# Prevents task-like lines in format examples from being parsed as real tasks.
# Usage: strip_code_fences < file  OR  grep ... | strip_code_fences
strip_code_fences() {
	awk '/^[[:space:]]*```/{in_fence=!in_fence; next} !in_fence{print}'
	return 0
}

# Escape a string for use in Extended Regular Expressions (ERE).
# Task IDs like t001.1 contain dots that are regex wildcards — this prevents
# t001.1 from matching t001x1 in grep -E or awk patterns.
# Usage: local escaped; escaped=$(_escape_ere "$task_id")
_escape_ere() {
	local input="$1"
	printf '%s' "$input" | sed -E 's/[][(){}.^$*+?|\\]/\\&/g'
}

# Find project root (contains TODO.md)
find_project_root() {
	local dir="$PWD"
	while [[ "$dir" != "/" ]]; do
		if [[ -f "$dir/TODO.md" ]]; then
			echo "$dir"
			return 0
		fi
		dir="${dir%/*}"
		[[ -z "$dir" ]] && dir="/"
	done
	print_error "No TODO.md found in directory tree"
	return 1
}

# Parse a single task line from TODO.md.
# Returns structured data as key=value pairs on stdout.
# Handles both top-level tasks and indented subtasks.
# Arguments:
#   $1 - raw task line from TODO.md
parse_task_line() {
	local line="$1"

	# Extract checkbox status
	local status="open"
	if echo "$line" | grep -qE '^\s*- \[x\]'; then
		status="completed"
	elif echo "$line" | grep -qE '^\s*- \[-\]'; then
		status="declined"
	fi

	# Extract task ID
	local task_id
	task_id=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || echo "")

	# Extract description (between task ID and first metadata field)
	local description
	description=$(echo "$line" | sed -E 's/^[[:space:]]*- \[.\] t[0-9]+(\.[0-9]+)* //' |
		sed -E 's/ (#[a-z]|~[0-9]|→ |logged:|started:|completed:|ref:|actual:|blocked-by:|blocks:|assignee:|verified:).*//' ||
		echo "")

	# Extract tags
	local tags
	tags=$(echo "$line" | grep -oE '#[a-z][a-z0-9-]*' | tr '\n' ',' | sed 's/,$//' || echo "")

	# Extract estimate (with optional breakdown)
	local estimate
	estimate=$(echo "$line" | grep -oE '~[0-9]+[hmd](\s*\(ai:[^)]+\))?' | head -1 || echo "")

	# Extract plan link
	local plan_link
	plan_link=$(echo "$line" | grep -oE '→ \[todo/PLANS\.md#[^]]+\]' | sed 's/→ \[//' | sed 's/\]//' || echo "")

	# Extract existing GH ref
	local gh_ref
	gh_ref=$(echo "$line" | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo "")

	# Extract logged date
	local logged
	logged=$(echo "$line" | sed -nE 's/.*logged:([0-9-]+).*/\1/p' || echo "")

	# Extract assignee
	local assignee
	assignee=$(echo "$line" | sed -nE 's/.*assignee:([A-Za-z0-9._@-]+).*/\1/p' | head -1 || echo "")

	# Extract started timestamp
	local started
	started=$(echo "$line" | sed -nE 's/.*started:([0-9T:Z-]+).*/\1/p' | head -1 || echo "")

	# Extract completed date
	local completed
	completed=$(echo "$line" | sed -nE 's/.*completed:([0-9-]+).*/\1/p' | head -1 || echo "")

	# Extract actual time
	local actual
	actual=$(echo "$line" | sed -nE 's/.*actual:([0-9.]+[hmd]).*/\1/p' | head -1 || echo "")

	# Extract blocked-by dependencies
	local blocked_by
	blocked_by=$(echo "$line" | sed -nE 's/.*blocked-by:([A-Za-z0-9.,]+).*/\1/p' | head -1 || echo "")

	# Extract blocks (downstream dependencies)
	local blocks
	blocks=$(echo "$line" | sed -nE 's/.*blocks:([A-Za-z0-9.,]+).*/\1/p' | head -1 || echo "")

	# Extract verified date
	local verified
	verified=$(echo "$line" | sed -nE 's/.*verified:([0-9-]+).*/\1/p' | head -1 || echo "")

	echo "task_id=$task_id"
	echo "status=$status"
	echo "description=$description"
	echo "tags=$tags"
	echo "estimate=$estimate"
	echo "plan_link=$plan_link"
	echo "gh_ref=$gh_ref"
	echo "logged=$logged"
	echo "assignee=$assignee"
	echo "started=$started"
	echo "completed=$completed"
	echo "actual=$actual"
	echo "blocked_by=$blocked_by"
	echo "blocks=$blocks"
	echo "verified=$verified"
	return 0
}

# Extract a task and all its subtasks + notes from TODO.md.
# Returns the full block of text for a given task ID.
# Arguments:
#   $1 - task_id (e.g. t1120)
#   $2 - path to TODO.md
extract_task_block() {
	local task_id="$1"
	local todo_file="$2"

	local in_block=false
	local block=""
	local task_indent=-1

	while IFS= read -r line; do
		# Check if this is the target task line
		if [[ "$in_block" == "false" ]] && echo "$line" | grep -qE "^\s*- \[.\] ${task_id} "; then
			in_block=true
			block="$line"
			# Calculate indent level using pure bash (avoids subshells in loop)
			local prefix="${line%%[! ]*}"
			task_indent=${#prefix}
			continue
		fi

		if [[ "$in_block" == "true" ]]; then
			# Check if we've hit the next task at same or lower indent
			local current_indent
			local cur_prefix="${line%%[! ]*}"
			current_indent=${#cur_prefix}

			# Empty lines within block end the block
			if [[ -z "${line// /}" ]]; then
				break
			fi

			# If indent is <= task indent and it's a new task, we're done
			if [[ $current_indent -le $task_indent ]] && echo "$line" | grep -qE '^\s*- \[.\] t[0-9]'; then
				break
			fi

			# If indent is <= task indent and it's not a subtask/notes line, we're done
			if [[ $current_indent -le $task_indent ]] && ! echo "$line" | grep -qE '^\s*- '; then
				break
			fi

			block="$block"$'\n'"$line"
		fi
	done <"$todo_file"

	echo "$block"
	return 0
}

# Extract subtasks from a task block.
# Skips the first line (parent task), returns indented subtask lines.
# Arguments:
#   $1 - task block text (multi-line)
extract_subtasks() {
	local block="$1"
	echo "$block" | tail -n +2 | grep -E '^\s+- \[.\] t[0-9]' || true
	return 0
}

# Extract Notes from a task block.
# Arguments:
#   $1 - task block text (multi-line)
extract_notes() {
	local block="$1"
	echo "$block" | grep -E '^\s+- Notes:' | sed 's/^[[:space:]]*- Notes: //' || true
	return 0
}

# =============================================================================
# Parse — PLANS.md Utilities
# =============================================================================

# Extract a plan section from PLANS.md given an anchor.
# Uses awk for performance — avoids spawning subprocesses per line on large files.
# Arguments:
#   $1 - plan_link (e.g. "todo/PLANS.md#2026-02-08-git-issues-bi-directional-sync")
#   $2 - project_root
extract_plan_section() {
	local plan_link="$1"
	local project_root="$2"

	if [[ -z "$plan_link" ]]; then
		return 0
	fi

	local plans_file="$project_root/todo/PLANS.md"
	if [[ ! -f "$plans_file" ]]; then
		log_verbose "PLANS.md not found at $plans_file"
		return 0
	fi

	# Convert anchor to heading text for matching
	local anchor
	anchor="${plan_link#todo/PLANS.md#}"

	# Use awk to extract the section efficiently (single pass, no per-line subprocesses)
	# Matching strategy: exact > substring > date-prefix + word overlap (handles TODO.md/PLANS.md drift)
	awk -v anchor="$anchor" '
    BEGIN {
        in_section = 0; heading_level = 0

        # Extract date prefix from anchor for fuzzy matching (e.g., "2026-02-08")
        if (match(anchor, /^[0-9]{4}-[0-9]{2}-[0-9]{2}/)) {
            anchor_date = substr(anchor, RSTART, RLENGTH)
            anchor_rest = substr(anchor, RLENGTH + 2)  # skip date + hyphen
        } else {
            anchor_date = ""
            anchor_rest = anchor
        }
        # Split anchor remainder into words for overlap scoring
        n_anchor_words = split(anchor_rest, anchor_words, "-")
    }

    function check_match(line_anchor) {
        # 1. Exact match
        if (line_anchor == anchor) return 1
        # 2. Substring containment (either direction)
        if (index(line_anchor, anchor) > 0 || index(anchor, line_anchor) > 0) return 1
        # 3. Date-prefix + word overlap (handles renamed/abbreviated headings)
        if (anchor_date != "" && index(line_anchor, anchor_date) > 0) {
            score = 0
            for (i = 1; i <= n_anchor_words; i++) {
                if (length(anchor_words[i]) >= 3 && index(line_anchor, anchor_words[i]) > 0) {
                    score++
                }
            }
            # Require >50% word overlap for fuzzy match
            if (n_anchor_words > 0 && score > n_anchor_words / 2) return 1
        }
        return 0
    }

    /^#{1,6} / {
        if (in_section == 0) {
            # Generate anchor from heading: strip leading #s, lowercase, strip special chars, spaces to hyphens
            line_anchor = $0
            gsub(/^#+[[:space:]]+/, "", line_anchor)
            line_anchor = tolower(line_anchor)
            gsub(/[^a-z0-9 -]/, "", line_anchor)
            gsub(/ /, "-", line_anchor)

            if (check_match(line_anchor)) {
                in_section = 1
                match($0, /^#+/)
                heading_level = RLENGTH
                print
                next
            }
        } else {
            # Check if this heading is at same or higher level (ends section)
            match($0, /^#+/)
            if (RLENGTH <= heading_level) {
                exit
            }
        }
    }

    in_section == 1 { print }
    ' "$plans_file"

	return 0
}

# Extract a named subsection from a plan section.
# Uses awk for consistent, efficient extraction.
# Arguments:
#   $1 - plan_section (multi-line text)
#   $2 - heading_pattern (e.g. "Purpose")
#   $3 - max_lines (0=unlimited)
#   $4 - skip_toon (true|false, default true)
#   $5 - skip_placeholder (true|false, default false)
_extract_plan_subsection() {
	local plan_section="$1"
	local heading_pattern="$2"
	local max_lines="${3:-0}"
	local skip_toon="${4:-true}"
	local skip_placeholder="${5:-false}"

	local result
	result=$(echo "$plan_section" | awk -v pattern="$heading_pattern" -v skip_toon="$skip_toon" -v max_lines="$max_lines" -v skip_placeholder="$skip_placeholder" '
    BEGIN { in_section = 0; count = 0 }
    /^####[[:space:]]+/ {
        if (in_section == 1) { exit }
        if ($0 ~ "^####[[:space:]]+" pattern) { in_section = 1; next }
        next
    }
    /^###[[:space:]]+/ { if (in_section == 1) exit }
    in_section == 1 {
        if (skip_toon == "true" && $0 ~ /^<!--TOON:/) exit
        if (/^[[:space:]]*$/) next
        if (skip_placeholder == "true" && $0 ~ /To be populated/) next
        if (max_lines > 0 && count >= max_lines) exit
        print
        count++
    }
    ')

	echo "$result"
	return 0
}

# Extract just the Purpose section from a plan.
# Arguments:
#   $1 - plan_section (multi-line text)
extract_plan_purpose() {
	local plan_section="$1"
	_extract_plan_subsection "$plan_section" "Purpose" 20 "false"
	return 0
}

# Extract the Decision Log from a plan.
# Arguments:
#   $1 - plan_section (multi-line text)
extract_plan_decisions() {
	local plan_section="$1"
	_extract_plan_subsection "$plan_section" "Decision Log" 0 "true"
	return 0
}

# Extract Progress section from a plan.
# Arguments:
#   $1 - plan_section (multi-line text)
extract_plan_progress() {
	local plan_section="$1"
	_extract_plan_subsection "$plan_section" "Progress" 0 "true"
	return 0
}

# Extract Discoveries section from a plan.
# Arguments:
#   $1 - plan_section (multi-line text)
extract_plan_discoveries() {
	local plan_section="$1"
	_extract_plan_subsection "$plan_section" "Surprises" 0 "true" "true"
	return 0
}

# Find a plan section in PLANS.md by matching task ID in **TODO:** or **Task:** fields.
# Supports subtask walk-up: t004.2 → t004.
# Returns: "plan_id\n<plan_section_text>" or empty string if not found.
# Arguments:
#   $1 - task_id
#   $2 - project_root
find_plan_by_task_id() {
	local task_id="$1"
	local project_root="$2"

	local plans_file="$project_root/todo/PLANS.md"
	if [[ ! -f "$plans_file" ]]; then
		return 0
	fi

	# Resolve lookup IDs: try exact task_id first, then walk up to parent for subtasks
	local lookup_ids=("$task_id")
	if [[ "$task_id" == *"."* ]]; then
		local parent_id="${task_id%%.*}"
		lookup_ids+=("$parent_id")
	fi

	for lookup_id in "${lookup_ids[@]}"; do
		# Search for **TODO:** or **Task:** field containing this task ID
		local match_line match_line_num
		match_line=$(grep -n "^\*\*\(TODO\|Task\):\*\*.*\b${lookup_id}\b" "$plans_file" | head -1 || true)
		if [[ -z "$match_line" ]]; then
			continue
		fi
		match_line_num="${match_line%%:*}"

		# Walk backwards from match_line_num to find the enclosing ### heading
		local heading_line
		heading_line=$(awk -v target="$match_line_num" '
			NR <= target && /^### / { last_heading = NR; last_text = $0 }
			NR == target { print last_heading ":" last_text; exit }
		' "$plans_file")

		if [[ -z "$heading_line" ]]; then
			continue
		fi

		local heading_num heading_raw
		heading_num="${heading_line%%:*}"
		heading_raw="${heading_line#*:}"

		# Extract plan ID from TOON block between heading and next ### heading
		local plan_id=""
		plan_id=$(awk -v start="$heading_num" '
			NR < start { next }
			NR > start && /^### / { exit }
			/^<!--TOON:plan\{/ {
				# Extract first field (plan ID) from TOON data line
				getline data_line
				if (match(data_line, /^p[0-9]+,/)) {
					id = substr(data_line, RSTART, RLENGTH - 1)
					print id
					exit
				}
			}
		' "$plans_file" || true)

		# Generate anchor from heading text for extract_plan_section
		local anchor
		anchor=$(echo "$heading_raw" | sed 's/^### //' | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9 -]//g' | sed 's/ /-/g')

		local plan_section
		plan_section=$(extract_plan_section "todo/PLANS.md#${anchor}" "$project_root")

		if [[ -n "$plan_section" ]]; then
			echo "${plan_id}"
			echo "$plan_section"
			return 0
		fi
	done

	return 0
}

# Extract additional plan subsections not covered by the 4 standard extractors.
# Returns non-empty content for: Context, Research, Architecture, Tool Matrix, Linkage, etc.
# Arguments:
#   $1 - plan_section (multi-line text)
extract_plan_extra_sections() {
	local plan_section="$1"

	# Headings to include (beyond Purpose/Progress/Decision Log/Surprises)
	local extra_headings=(
		"Context"
		"Context from Discussion"
		"Context from Review"
		"Research"
		"Architecture"
		"Tool Matrix"
		"Linkage"
		"Proposed Structure"
		"Design"
		"Implementation"
		"Phases"
		"Risks"
		"Open Questions"
		"Related Tasks"
		"Dependencies"
	)

	local result=""
	for heading in "${extra_headings[@]}"; do
		local content
		content=$(_extract_plan_subsection "$plan_section" "$heading" 0 "true")
		if [[ -n "$content" ]]; then
			result="${result}"$'\n\n'"**${heading}**"$'\n\n'"${content}"
		fi
	done

	echo "$result"
	return 0
}

# =============================================================================
# Parse — PRD/Task File Utilities
# =============================================================================

# Find related PRD and task files in todo/tasks/.
# Checks both grep matches and explicit ref:todo/tasks/ from the task line.
# Arguments:
#   $1 - task_id
#   $2 - project_root
find_related_files() {
	local task_id="$1"
	local project_root="$2"
	local tasks_dir="$project_root/todo/tasks"
	local todo_file="$project_root/TODO.md"
	local all_files=""

	# 1. Follow explicit ref:todo/tasks/ from the task line
	if [[ -f "$todo_file" ]]; then
		local task_line
		task_line=$(grep -E "^- \[.\] ${task_id} " "$todo_file" | head -1 || echo "")
		local explicit_refs
		explicit_refs=$(echo "$task_line" | grep -oE 'ref:todo/tasks/[^ ]+' | sed 's/ref://' || true)
		while IFS= read -r ref; do
			if [[ -n "$ref" && -f "$project_root/$ref" ]]; then
				all_files="${all_files:+$all_files"$'\n'"}$project_root/$ref"
			fi
		done <<<"$explicit_refs"
	fi

	# 2. Search for files referencing this task ID in todo/tasks/
	if [[ -d "$tasks_dir" ]]; then
		local grep_files
		grep_files=$(grep -rl "$task_id" "$tasks_dir" || true)
		if [[ -n "$grep_files" ]]; then
			all_files="${all_files:+$all_files"$'\n'"}$grep_files"
		fi
	fi

	# Deduplicate and exclude brief files (handled separately by compose_issue_body)
	if [[ -n "$all_files" ]]; then
		echo "$all_files" | sort -u | grep -v -- '-brief\.md$'
	fi
	return 0
}

# Extract a summary from a PRD or task file (first meaningful section, max 30 lines).
# Arguments:
#   $1 - file_path
#   $2 - max_lines (default: 30)
extract_file_summary() {
	local file_path="$1"
	local max_lines="${2:-30}"

	if [[ ! -f "$file_path" ]]; then
		return 0
	fi

	local summary=""
	local line_count=0
	local in_frontmatter=false
	local past_frontmatter=false

	while IFS= read -r line; do
		# Skip YAML frontmatter
		if [[ "$line" == "---" ]] && [[ "$past_frontmatter" == "false" ]]; then
			if [[ "$in_frontmatter" == "true" ]]; then
				past_frontmatter=true
				in_frontmatter=false
				continue
			fi
			in_frontmatter=true
			continue
		fi
		if [[ "$in_frontmatter" == "true" ]]; then
			continue
		fi

		# Skip empty lines at the start
		if [[ -z "${line// /}" ]] && [[ $line_count -eq 0 ]]; then
			continue
		fi

		# Include the title heading (# Title) as first line
		if [[ $line_count -eq 0 ]] && [[ "$line" == "# "* ]]; then
			summary="$line"
			line_count=1
			continue
		fi

		summary="$summary"$'\n'"$line"
		line_count=$((line_count + 1))

		# Stop at max lines
		if [[ $line_count -ge $max_lines ]]; then
			summary="$summary"$'\n'"..."
			break
		fi
	done <"$file_path"

	echo "$summary"
	return 0
}

# =============================================================================
# Compose — Tag/Label Mapping
# =============================================================================

# Map TODO.md #tags to issue labels (passthrough with aliases).
# All tags are passed through as labels. A small alias map normalises
# common synonyms to their canonical label name.
# Arguments:
#   $1 - tags (comma-separated, with or without # prefix)
map_tags_to_labels() {
	local tags="$1"

	if [[ -z "$tags" ]]; then
		return 0
	fi

	local labels=""
	local tag
	local _saved_ifs="$IFS"
	IFS=','
	for tag in $tags; do
		tag="${tag#\#}"  # Remove # prefix if present
		tag="${tag// /}" # Strip whitespace

		[[ -z "$tag" ]] && continue

		# Alias common synonyms to canonical label names
		local label="$tag"
		case "$tag" in
		bugfix | bug) label="bug" ;;
		feat | feature) label="enhancement" ;;
		hardening) label="quality" ;;
		sync) label="git" ;;
		docs) label="documentation" ;;
		esac

		labels="${labels:+$labels,}$label"
	done
	IFS="$_saved_ifs"

	# Deduplicate
	echo "$labels" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//'
	return 0
}

# =============================================================================
# Compose — Issue Body
# =============================================================================

# Compose a rich issue body from all available task context.
# Arguments:
#   $1 - task_id
#   $2 - project_root
compose_issue_body() {
	local task_id="$1"
	local project_root="$2"

	local todo_file="$project_root/TODO.md"
	if [[ ! -f "$todo_file" ]]; then
		print_error "TODO.md not found at $todo_file"
		return 1
	fi

	# Extract the full task block
	local block
	block=$(extract_task_block "$task_id" "$todo_file")
	if [[ -z "$block" ]]; then
		print_error "Task $task_id not found in TODO.md"
		return 1
	fi

	# Parse the main task line
	local first_line
	first_line=$(echo "$block" | head -1)
	local parsed
	parsed=$(parse_task_line "$first_line")

	# Extract fields from parsed output using a single pass (avoids repeated grep|cut subshells)
	local description="" tags="" estimate="" plan_link="" status="" logged=""
	local assignee="" started="" completed="" actual="" blocked_by="" blocks="" verified=""
	while IFS='=' read -r key value; do
		case "$key" in
		description) description="$value" ;;
		tags) tags="$value" ;;
		estimate) estimate="$value" ;;
		plan_link) plan_link="$value" ;;
		status) status="$value" ;;
		logged) logged="$value" ;;
		assignee) assignee="$value" ;;
		started) started="$value" ;;
		completed) completed="$value" ;;
		actual) actual="$value" ;;
		blocked_by) blocked_by="$value" ;;
		blocks) blocks="$value" ;;
		verified) verified="$value" ;;
		esac
	done <<<"$parsed"

	# Resolve plan context early so plan ID can appear in metadata header.
	# Supports: explicit → [todo/PLANS.md#anchor] link OR auto-detect via **TODO:**/**Task:** field.
	local plan_section="" detected_plan_id=""
	if [[ -n "$plan_link" ]]; then
		plan_section=$(extract_plan_section "$plan_link" "$project_root")
		# Also extract plan ID from TOON block for explicit links
		if [[ -n "$plan_section" ]]; then
			detected_plan_id=$(echo "$plan_section" | awk '
				/^<!--TOON:plan\{/ { getline data; if (match(data, /^p[0-9]+,/)) { print substr(data, RSTART, RLENGTH-1); exit } }
			' || true)
		fi
	else
		# Auto-detect: scan PLANS.md for **TODO:** or **Task:** containing this task ID
		local auto_detected
		auto_detected=$(find_plan_by_task_id "$task_id" "$project_root")
		if [[ -n "$auto_detected" ]]; then
			detected_plan_id=$(echo "$auto_detected" | head -1)
			plan_section=$(echo "$auto_detected" | tail -n +2)
		fi
	fi

	# Start building the body
	local body=""

	# Task metadata header line
	body="**Task ID:** \`$task_id\`"
	if [[ -n "$status" ]]; then
		body="$body | **Status:** $status"
	fi
	if [[ -n "$estimate" ]]; then
		body="$body | **Estimate:** \`$estimate\`"
	fi
	if [[ -n "$actual" ]]; then
		body="$body | **Actual:** \`$actual\`"
	fi
	# Include plan ID in metadata header when auto-detected (no explicit link)
	if [[ -n "$detected_plan_id" ]]; then
		body="$body | **Plan:** \`$detected_plan_id\`"
	fi

	# Second metadata line: dates and assignment
	local meta_line2=""
	if [[ -n "$assignee" ]]; then
		meta_line2="**Assignee:** @$assignee"
	fi
	if [[ -n "$logged" ]]; then
		meta_line2="${meta_line2:+$meta_line2 | }**Logged:** $logged"
	fi
	if [[ -n "$started" ]]; then
		meta_line2="${meta_line2:+$meta_line2 | }**Started:** $started"
	fi
	if [[ -n "$completed" ]]; then
		meta_line2="${meta_line2:+$meta_line2 | }**Completed:** $completed"
	fi
	if [[ -n "$verified" ]]; then
		meta_line2="${meta_line2:+$meta_line2 | }**Verified:** $verified"
	fi
	if [[ -n "$meta_line2" ]]; then
		body="$body"$'\n'"$meta_line2"
	fi

	# Tags
	if [[ -n "$tags" ]]; then
		local formatted_tags
		# shellcheck disable=SC2016  # & in sed replacement is sed syntax, not a bash expression
		formatted_tags=$(echo "$tags" | sed 's/,/ /g' | sed 's/#//g' | sed 's/[^ ]*/`&`/g')
		body="$body"$'\n'"**Tags:** $formatted_tags"
	fi

	# Full description (the detailed spec after the em dash)
	if [[ -n "$description" ]]; then
		body="$body"$'\n\n'"## Description"$'\n\n'"$description"
	fi

	# Dependencies
	if [[ -n "$blocked_by" ]]; then
		body="$body"$'\n\n'"**Blocked by:** \`$blocked_by\`"
	fi
	if [[ -n "$blocks" ]]; then
		body="$body"$'\n'"**Blocks:** \`$blocks\`"
	fi

	# Subtasks
	local subtasks
	subtasks=$(extract_subtasks "$block")
	if [[ -n "$subtasks" ]]; then
		body="$body"$'\n\n'"## Subtasks"$'\n'
		while IFS= read -r subtask_line; do
			# Convert TODO.md checkbox format to issue checkbox
			local gh_line
			gh_line=$(echo "$subtask_line" | sed -E 's/^[[:space:]]+//' | sed -E 's/^- \[x\]/- [x]/' | sed -E 's/^- \[ \]/- [ ]/' | sed -E 's/^- \[-\] (.*)/- [x] ~~\1~~/')
			body="$body"$'\n'"$gh_line"
		done <<<"$subtasks"
	fi

	# Notes
	local notes
	notes=$(extract_notes "$block")
	if [[ -n "$notes" ]]; then
		body="$body"$'\n\n'"## Notes"$'\n\n'"$notes"
	fi

	# Plan context (plan_section resolved above before metadata header)
	if [[ -n "$plan_section" ]]; then
		# Purpose (always shown inline)
		local purpose
		purpose=$(extract_plan_purpose "$plan_section")
		if [[ -n "$purpose" ]]; then
			body="$body"$'\n\n'"## Plan: Purpose"$'\n\n'"$purpose"
		fi

		# Extra sections: Context, Research, Architecture, Tool Matrix, etc. (collapsed)
		local extra_sections
		extra_sections=$(extract_plan_extra_sections "$plan_section")
		if [[ -n "$extra_sections" ]]; then
			body="$body"$'\n\n'"<details><summary>Plan: Context &amp; Architecture</summary>"$'\n'"$extra_sections"$'\n\n'"</details>"
		fi

		# Progress (collapsed)
		local progress
		progress=$(extract_plan_progress "$plan_section")
		if [[ -n "$progress" ]]; then
			body="$body"$'\n\n'"<details><summary>Plan: Progress</summary>"$'\n\n'"$progress"$'\n\n'"</details>"
		fi

		# Decisions (collapsed)
		local decisions
		decisions=$(extract_plan_decisions "$plan_section")
		if [[ -n "$decisions" ]]; then
			body="$body"$'\n\n'"<details><summary>Plan: Decision Log</summary>"$'\n\n'"$decisions"$'\n\n'"</details>"
		fi

		# Discoveries (collapsed)
		local discoveries
		discoveries=$(extract_plan_discoveries "$plan_section")
		if [[ -n "$discoveries" ]]; then
			body="$body"$'\n\n'"<details><summary>Plan: Discoveries</summary>"$'\n\n'"$discoveries"$'\n\n'"</details>"
		fi
	fi

	# Related PRD/task files (with inline content)
	local related_files
	related_files=$(find_related_files "$task_id" "$project_root")
	if [[ -n "$related_files" ]]; then
		body="$body"$'\n\n'"## Related Files"
		while IFS= read -r file; do
			if [[ -n "$file" ]]; then
				local rel_path file_summary
				rel_path="${file#"$project_root"/}"
				file_summary=$(extract_file_summary "$file" 30)
				if [[ -n "$file_summary" ]]; then
					body="$body"$'\n\n'"<details><summary><code>$rel_path</code></summary>"$'\n\n'"$file_summary"$'\n\n'"</details>"
				else
					body="$body"$'\n\n'"- [\`$rel_path\`]($rel_path)"
				fi
			fi
		done <<<"$related_files"
	fi

	# Task brief file (todo/tasks/{task_id}-brief.md)
	local brief_file="$project_root/todo/tasks/${task_id}-brief.md"
	if [[ -f "$brief_file" ]]; then
		local brief_content
		# Strip YAML frontmatter (--- ... ---) if present
		brief_content=$(awk '
			BEGIN { in_front=0; front_done=0 }
			/^---$/ && !front_done { in_front=!in_front; if(!in_front) front_done=1; next }
			!in_front { print }
		' "$brief_file")
		if [[ -n "$brief_content" && ${#brief_content} -gt 10 ]]; then
			body="$body"$'\n\n'"## Task Brief"$'\n\n'"$brief_content"
		fi
	fi

	# Extract HTML comments (e.g., REBASE notes) from the task line
	local html_comments
	# Match HTML comments — use sed to extract content between <!-- and -->
	# Handles comments containing > characters (e.g., "use a -> b pattern")
	html_comments=$(echo "$first_line" | sed -n 's/.*\(<!--.*-->\).*/\1/p' | sed 's/<!--//;s/-->//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
	if [[ -n "$html_comments" ]]; then
		body="$body"$'\n\n'"## Implementation Notes"$'\n\n'"$html_comments"
	fi

	# Footer
	body="$body"$'\n\n'"---"$'\n'"*Synced from TODO.md by issue-sync-helper.sh*"

	echo "$body"
	return 0
}

# =============================================================================
# Ref Management — TODO.md ref:GH# and pr:# fields
# =============================================================================

# Fix a mismatched ref:GH# in TODO.md (t179.1).
# Replaces old_number with new_number for the given task.
# Arguments:
#   $1 - task_id
#   $2 - old_number
#   $3 - new_number
#   $4 - todo_file path
fix_gh_ref_in_todo() {
	local task_id="$1"
	local old_number="$2"
	local new_number="$3"
	local todo_file="$4"

	if [[ -z "$old_number" || -z "$new_number" || "$old_number" == "$new_number" ]]; then
		return 0
	fi

	# Find line number outside code fences, then replace only that line
	local task_id_ere
	task_id_ere=$(_escape_ere "$task_id")
	local line_num
	line_num=$(awk -v pat="^[[:space:]]*- \\[.\\] ${task_id_ere} .*ref:GH#${old_number}" \
		'/^[[:space:]]*```/{f=!f; next} !f && $0 ~ pat {print NR; exit}' "$todo_file")
	[[ -z "$line_num" ]] && {
		log_verbose "$task_id with ref:GH#$old_number not found outside code fences"
		return 0
	}
	sed_inplace "${line_num}s|ref:GH#${old_number}|ref:GH#${new_number}|" "$todo_file"
	log_verbose "Fixed ref:GH#$old_number -> ref:GH#$new_number for $task_id"
	return 0
}

# Add ref:GH#NNN to a task line in TODO.md.
# Idempotent — skips if ref already exists.
# Arguments:
#   $1 - task_id
#   $2 - issue_number
#   $3 - todo_file path
add_gh_ref_to_todo() {
	local task_id="$1"
	local issue_number="$2"
	local todo_file="$3"
	local task_id_ere
	task_id_ere=$(_escape_ere "$task_id")

	# Check if ref already exists outside code fences
	if strip_code_fences <"$todo_file" | grep -qE "^\s*- \[.\] ${task_id_ere} .*ref:GH#${issue_number}"; then
		return 0
	fi

	# Check if any GH ref exists outside code fences (might be different number)
	if strip_code_fences <"$todo_file" | grep -qE "^\s*- \[.\] ${task_id_ere} .*ref:GH#"; then
		log_verbose "$task_id already has a GH ref, skipping"
		return 0
	fi

	# Find the line number of the task OUTSIDE code fences, then apply sed to that specific line.
	# This prevents modifying format examples inside code-fenced blocks.
	local line_num
	line_num=$(awk -v pat="^[[:space:]]*- \\[.\\] ${task_id_ere} " \
		'/^[[:space:]]*```/{f=!f; next} !f && $0 ~ pat {print NR; exit}' "$todo_file")
	[[ -z "$line_num" ]] && {
		log_verbose "$task_id not found outside code fences"
		return 0
	}

	# Read the target line and insert ref
	local target_line
	target_line=$(sed -n "${line_num}p" "$todo_file")
	local new_line
	if echo "$target_line" | grep -qE 'logged:'; then
		new_line=$(echo "$target_line" | sed -E "s/( logged:)/ ref:GH#${issue_number}\1/")
	else
		new_line="${target_line} ref:GH#${issue_number}"
	fi

	# Replace only the specific line
	local new_line_escaped
	new_line_escaped=$(printf '%s' "$new_line" | sed 's/[|&\\]/\\&/g')
	sed_inplace "${line_num}s|.*|${new_line_escaped}|" "$todo_file"

	log_verbose "Added ref:GH#$issue_number to $task_id"
	return 0
}

# Add pr:#NNN to a task line in TODO.md (t280).
# Called when a closing PR is discovered that isn't already recorded.
# Ensures the proof-log is complete.
# Arguments:
#   $1 - task_id
#   $2 - pr_number
#   $3 - todo_file path
add_pr_ref_to_todo() {
	local task_id="$1"
	local pr_number="$2"
	local todo_file="$3"
	local task_id_ere
	task_id_ere=$(_escape_ere "$task_id")

	# Check if pr: ref already exists outside code fences
	if strip_code_fences <"$todo_file" | grep -qE "^\s*- \[.\] ${task_id_ere} .*pr:#${pr_number}"; then
		return 0
	fi

	# Check if any pr: ref already exists outside code fences (don't duplicate)
	if strip_code_fences <"$todo_file" | grep -qE "^\s*- \[.\] ${task_id_ere} .*pr:#"; then
		log_verbose "$task_id already has a pr: ref, skipping"
		return 0
	fi

	# Find line number outside code fences, then modify only that line
	local line_num
	line_num=$(awk -v pat="^[[:space:]]*- \\[.\\] ${task_id_ere} " \
		'/^[[:space:]]*```/{f=!f; next} !f && $0 ~ pat {print NR; exit}' "$todo_file")
	[[ -z "$line_num" ]] && {
		log_verbose "$task_id not found outside code fences for pr: ref"
		return 0
	}

	local target_line
	target_line=$(sed -n "${line_num}p" "$todo_file")
	local new_line
	if echo "$target_line" | grep -qE ' logged:'; then
		new_line=$(echo "$target_line" | sed -E "s/( logged:)/ pr:#${pr_number}\1/")
	elif echo "$target_line" | grep -qE ' completed:'; then
		new_line=$(echo "$target_line" | sed -E "s/( completed:)/ pr:#${pr_number}\1/")
	else
		new_line="${target_line} pr:#${pr_number}"
	fi

	local new_line_escaped
	new_line_escaped=$(printf '%s' "$new_line" | sed 's/[|&\\]/\\&/g')
	sed_inplace "${line_num}s|.*|${new_line_escaped}|" "$todo_file"

	log_verbose "Added pr:#$pr_number to $task_id (t280: backfill proof-log)"
	return 0
}
