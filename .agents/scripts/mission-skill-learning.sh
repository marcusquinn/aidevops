#!/usr/bin/env bash
# =============================================================================
# Mission Skill Learning Helper
# =============================================================================
# Scans completed mission directories for reusable artifacts (agents, scripts,
# research docs), scores them for promotion potential, and stores patterns in
# cross-session memory.
#
# This is the deterministic half of mission skill learning. It handles file
# discovery, recurrence counting, and artifact copying. The judgment calls
# (is this artifact worth promoting? how to adapt it?) belong to the
# orchestrator agent guided by workflows/mission-skill-learning.md.
#
# Usage:
#   mission-skill-learning.sh scan <mission-dir>
#   mission-skill-learning.sh score <mission-dir>
#   mission-skill-learning.sh promote <artifact-path> [--target draft|custom]
#   mission-skill-learning.sh remember <mission-dir>
#   mission-skill-learning.sh recurrence [--all-missions <missions-root>]
#   mission-skill-learning.sh help
#
# Integration:
#   - Called by mission orchestrator at Phase 5 (completion)
#   - Called manually via /mission-learn command
#   - Stores patterns via memory-helper.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

LOG_PREFIX="SKILL"

readonly MEMORY_HELPER="${SCRIPT_DIR}/memory-helper.sh"
readonly AGENTS_DIR="${HOME}/.aidevops/agents"
readonly DRAFT_DIR="${AGENTS_DIR}/draft"
readonly CUSTOM_DIR="${AGENTS_DIR}/custom"

# Artifact types we look for in mission directories
readonly AGENT_PATTERN="*.md"
readonly SCRIPT_PATTERN="*.sh"

# Minimum content length (bytes) to consider an artifact non-trivial
readonly MIN_ARTIFACT_SIZE=200

# =============================================================================
# Scan: discover artifacts in a mission directory
# =============================================================================

cmd_scan() {
	local mission_dir="${1:-}"

	if [[ -z "$mission_dir" ]]; then
		log_error "Usage: mission-skill-learning.sh scan <mission-dir>"
		return 1
	fi

	if [[ ! -d "$mission_dir" ]]; then
		log_error "Mission directory not found: $mission_dir"
		return 1
	fi

	log_info "Scanning mission directory: $mission_dir"
	echo ""

	local found=0

	# Scan for agent files
	if [[ -d "$mission_dir/agents" ]]; then
		echo "=== Mission Agents ==="
		while IFS= read -r -d '' agent_file; do
			local size name desc
			size=$(wc -c <"$agent_file" | tr -d ' ')
			name=$(basename "$agent_file")
			desc=$(extract_description "$agent_file")

			if [[ "$size" -ge "$MIN_ARTIFACT_SIZE" ]]; then
				echo "  [AGENT] $name (${size}B)"
				echo "    Path: $agent_file"
				[[ -n "$desc" ]] && echo "    Desc: $desc"
				echo ""
				found=$((found + 1))
			fi
		done < <(find "$mission_dir/agents" -name "$AGENT_PATTERN" -type f -print0 2>/dev/null)
	fi

	# Scan for script files
	if [[ -d "$mission_dir/scripts" ]]; then
		echo "=== Mission Scripts ==="
		while IFS= read -r -d '' script_file; do
			local size name
			size=$(wc -c <"$script_file" | tr -d ' ')
			name=$(basename "$script_file")

			if [[ "$size" -ge "$MIN_ARTIFACT_SIZE" ]]; then
				echo "  [SCRIPT] $name (${size}B)"
				echo "    Path: $script_file"
				echo ""
				found=$((found + 1))
			fi
		done < <(find "$mission_dir/scripts" -name "$SCRIPT_PATTERN" -type f -print0 2>/dev/null)
	fi

	# Scan for research docs (informational, not promotable)
	if [[ -d "$mission_dir/research" ]]; then
		echo "=== Research Artifacts ==="
		while IFS= read -r -d '' research_file; do
			local size name
			size=$(wc -c <"$research_file" | tr -d ' ')
			name=$(basename "$research_file")

			if [[ "$size" -ge "$MIN_ARTIFACT_SIZE" ]]; then
				echo "  [RESEARCH] $name (${size}B)"
				echo "    Path: $research_file"
				echo ""
				found=$((found + 1))
			fi
		done < <(find "$mission_dir/research" -name "$AGENT_PATTERN" -type f -print0 2>/dev/null)
	fi

	echo "---"
	echo "Total artifacts found: $found"

	return 0
}

# =============================================================================
# Score: evaluate artifacts for promotion potential
# =============================================================================

cmd_score() {
	local mission_dir="${1:-}"

	if [[ -z "$mission_dir" ]]; then
		log_error "Usage: mission-skill-learning.sh score <mission-dir>"
		return 1
	fi

	if [[ ! -d "$mission_dir" ]]; then
		log_error "Mission directory not found: $mission_dir"
		return 1
	fi

	log_info "Scoring artifacts in: $mission_dir"
	echo ""

	local scored=0

	# Score agents
	if [[ -d "$mission_dir/agents" ]]; then
		while IFS= read -r -d '' agent_file; do
			local size
			size=$(wc -c <"$agent_file" | tr -d ' ')
			[[ "$size" -lt "$MIN_ARTIFACT_SIZE" ]] && continue

			local score
			score=$(score_artifact "$agent_file" "agent")
			local name
			name=$(basename "$agent_file")
			local recommendation
			recommendation=$(recommend_action "$score")

			echo "  $name: score=$score -> $recommendation"
			scored=$((scored + 1))
		done < <(find "$mission_dir/agents" -name "$AGENT_PATTERN" -type f -print0 2>/dev/null)
	fi

	# Score scripts
	if [[ -d "$mission_dir/scripts" ]]; then
		while IFS= read -r -d '' script_file; do
			local size
			size=$(wc -c <"$script_file" | tr -d ' ')
			[[ "$size" -lt "$MIN_ARTIFACT_SIZE" ]] && continue

			local score
			score=$(score_artifact "$script_file" "script")
			local name
			name=$(basename "$script_file")
			local recommendation
			recommendation=$(recommend_action "$score")

			echo "  $name: score=$score -> $recommendation"
			scored=$((scored + 1))
		done < <(find "$mission_dir/scripts" -name "$SCRIPT_PATTERN" -type f -print0 2>/dev/null)
	fi

	if [[ "$scored" -eq 0 ]]; then
		log_info "No scorable artifacts found."
	fi

	echo ""
	echo "Score legend: 0-3=delete, 4-6=keep in mission, 7-8=promote to draft/, 9-10=promote to custom/"

	return 0
}

# =============================================================================
# Promote: copy an artifact to draft/ or custom/ with metadata
# =============================================================================

cmd_promote() {
	local artifact_path="${1:-}"
	local target="draft"

	shift || true
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--target)
			target="${2:-draft}"
			shift 2
			;;
		--dry-run)
			local dry_run=true
			shift
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$artifact_path" ]]; then
		log_error "Usage: mission-skill-learning.sh promote <artifact-path> [--target draft|custom]"
		return 1
	fi

	if [[ ! -f "$artifact_path" ]]; then
		log_error "Artifact not found: $artifact_path"
		return 1
	fi

	local target_dir
	case "$target" in
	draft) target_dir="$DRAFT_DIR" ;;
	custom) target_dir="$CUSTOM_DIR" ;;
	*)
		log_error "Invalid target: $target (must be draft or custom)"
		return 1
		;;
	esac

	local artifact_name
	artifact_name=$(basename "$artifact_path")

	# Check if already exists in target
	if [[ -f "$target_dir/$artifact_name" ]]; then
		log_warn "Artifact already exists in $target/: $artifact_name"
		log_warn "Review and merge manually if needed."
		return 1
	fi

	if [[ "${dry_run:-false}" == "true" ]]; then
		log_info "[DRY RUN] Would promote: $artifact_path -> $target_dir/$artifact_name"
		return 0
	fi

	# Ensure target directory exists
	mkdir -p "$target_dir"

	# Copy artifact
	cp "$artifact_path" "$target_dir/$artifact_name"

	# Add promotion metadata to the file if it's a markdown agent
	if [[ "$artifact_name" == *.md ]]; then
		add_promotion_metadata "$target_dir/$artifact_name" "$artifact_path"
	fi

	log_success "Promoted: $artifact_name -> $target_dir/"
	log_info "Review the promoted artifact and adjust for general use."

	# Store promotion event in memory
	if [[ -x "$MEMORY_HELPER" ]]; then
		"$MEMORY_HELPER" store --auto \
			--type "SUCCESS_PATTERN" \
			--content "Mission artifact promoted to $target/: $artifact_name (from $artifact_path)" \
			--tags "mission,skill-learning,promotion,$target" \
			2>/dev/null || true
	fi

	return 0
}

# =============================================================================
# Remember: store mission patterns in cross-session memory
# =============================================================================

cmd_remember() {
	local mission_dir="${1:-}"

	if [[ -z "$mission_dir" ]]; then
		log_error "Usage: mission-skill-learning.sh remember <mission-dir>"
		return 1
	fi

	if [[ ! -d "$mission_dir" ]]; then
		log_error "Mission directory not found: $mission_dir"
		return 1
	fi

	if [[ ! -x "$MEMORY_HELPER" ]]; then
		log_error "memory-helper.sh not found or not executable: $MEMORY_HELPER"
		return 1
	fi

	local mission_id
	mission_id=$(basename "$mission_dir")

	log_info "Storing mission patterns for: $mission_id"

	local stored=0

	# Extract and store mission goal/outcome from mission.md
	local mission_file="$mission_dir/mission.md"
	if [[ -f "$mission_file" ]]; then
		local goal
		goal=$(extract_mission_goal "$mission_file")
		if [[ -n "$goal" ]]; then
			"$MEMORY_HELPER" store --auto \
				--type "SUCCESS_PATTERN" \
				--content "Mission $mission_id completed: $goal" \
				--tags "mission,completed,$mission_id" \
				2>/dev/null || true
			stored=$((stored + 1))
		fi
	fi

	# Store decision log entries as DECISION memories
	if [[ -f "$mission_file" ]]; then
		store_decisions_from_mission "$mission_file" "$mission_id"
		stored=$((stored + 1))
	fi

	# Store info about promoted artifacts
	if [[ -d "$mission_dir/agents" ]]; then
		while IFS= read -r -d '' agent_file; do
			local name desc
			name=$(basename "$agent_file")
			desc=$(extract_description "$agent_file")
			if [[ -n "$desc" ]]; then
				"$MEMORY_HELPER" store --auto \
					--type "CODEBASE_PATTERN" \
					--content "Mission $mission_id created agent: $name — $desc" \
					--tags "mission,agent,$mission_id" \
					2>/dev/null || true
				stored=$((stored + 1))
			fi
		done < <(find "$mission_dir/agents" -name "$AGENT_PATTERN" -type f -print0 2>/dev/null)
	fi

	# Store info about mission scripts
	if [[ -d "$mission_dir/scripts" ]]; then
		while IFS= read -r -d '' script_file; do
			local name
			name=$(basename "$script_file")
			"$MEMORY_HELPER" store --auto \
				--type "CODEBASE_PATTERN" \
				--content "Mission $mission_id created script: $name" \
				--tags "mission,script,$mission_id" \
				2>/dev/null || true
			stored=$((stored + 1))
		done < <(find "$mission_dir/scripts" -name "$SCRIPT_PATTERN" -type f -print0 2>/dev/null)
	fi

	log_success "Stored $stored patterns from mission $mission_id"

	return 0
}

# =============================================================================
# Recurrence: check how often similar artifacts appear across missions
# =============================================================================

cmd_recurrence() {
	local missions_root="${1:-}"

	# Parse flags
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--all-missions)
			missions_root="${2:-}"
			shift 2
			;;
		*) shift ;;
		esac
	done

	# Auto-detect missions root
	if [[ -z "$missions_root" ]]; then
		local repo_root
		repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
		if [[ -n "$repo_root" && -d "$repo_root/todo/missions" ]]; then
			missions_root="$repo_root/todo/missions"
		elif [[ -d "$HOME/.aidevops/missions" ]]; then
			missions_root="$HOME/.aidevops/missions"
		else
			log_error "No missions directory found. Specify with --all-missions <path>"
			return 1
		fi
	fi

	if [[ ! -d "$missions_root" ]]; then
		log_error "Missions root not found: $missions_root"
		return 1
	fi

	log_info "Checking artifact recurrence across missions in: $missions_root"
	echo ""

	# Collect all artifact names across missions
	local tmp_names
	tmp_names=$(mktemp)
	trap 'rm -f "${tmp_names:-}"' RETURN

	local mission_count=0
	while IFS= read -r -d '' mission_dir; do
		[[ ! -d "$mission_dir" ]] && continue
		# Only count directories that contain a mission.md
		[[ ! -f "$mission_dir/mission.md" ]] && continue
		mission_count=$((mission_count + 1))

		# Collect agent names
		if [[ -d "$mission_dir/agents" ]]; then
			find "$mission_dir/agents" -name "$AGENT_PATTERN" -type f -exec basename {} \; \
				2>/dev/null >>"$tmp_names"
		fi

		# Collect script names
		if [[ -d "$mission_dir/scripts" ]]; then
			find "$mission_dir/scripts" -name "$SCRIPT_PATTERN" -type f -exec basename {} \; \
				2>/dev/null >>"$tmp_names"
		fi
	done < <(find "$missions_root" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)

	if [[ "$mission_count" -eq 0 ]]; then
		log_info "No completed missions found."
		return 0
	fi

	echo "Missions scanned: $mission_count"
	echo ""

	# Count occurrences of each artifact name
	if [[ -s "$tmp_names" ]]; then
		echo "=== Recurring Artifacts ==="
		sort "$tmp_names" | uniq -c | sort -rn | while read -r count name; do
			if [[ "$count" -gt 1 ]]; then
				echo "  ${count}x  $name"
			fi
		done

		echo ""
		echo "=== All Artifacts ==="
		sort "$tmp_names" | uniq -c | sort -rn | while read -r count name; do
			echo "  ${count}x  $name"
		done
	else
		log_info "No artifacts found across missions."
	fi

	return 0
}

# =============================================================================
# Helper functions
# =============================================================================

# Extract description from YAML frontmatter of a markdown file
extract_description() {
	local file="$1"

	# Look for description: in YAML frontmatter (between --- markers)
	local in_frontmatter=false
	while IFS= read -r line; do
		if [[ "$line" == "---" ]]; then
			if [[ "$in_frontmatter" == true ]]; then
				break
			fi
			in_frontmatter=true
			continue
		fi
		if [[ "$in_frontmatter" == true ]]; then
			if [[ "$line" =~ ^description:\ (.+) ]]; then
				echo "${BASH_REMATCH[1]}"
				return 0
			fi
		fi
	done <"$file"

	return 0
}

# Extract mission goal from mission.md
extract_mission_goal() {
	local file="$1"

	# Look for the blockquote goal line (> One-line goal statement)
	while IFS= read -r line; do
		if [[ "$line" =~ ^\>\ (.+) ]]; then
			local goal="${BASH_REMATCH[1]}"
			# Skip template placeholders
			if [[ "$goal" != *"{One-line"* ]]; then
				echo "$goal"
				return 0
			fi
		fi
	done <"$file"

	# Fallback: look for ## Goal section
	local in_goal=false
	while IFS= read -r line; do
		if [[ "$line" == "## Goal" || "$line" == "### Goal" ]]; then
			in_goal=true
			continue
		fi
		if [[ "$in_goal" == true ]]; then
			# Skip empty lines
			[[ -z "$line" ]] && continue
			# Stop at next heading
			[[ "$line" == "#"* ]] && break
			# Return first non-empty line
			echo "$line"
			return 0
		fi
	done <"$file"

	return 0
}

# Store decision log entries from mission.md as memories
store_decisions_from_mission() {
	local file="$1"
	local mission_id="$2"

	local in_decisions=false
	local in_table=false
	while IFS= read -r line; do
		if [[ "$line" == "## Decision Log"* ]]; then
			in_decisions=true
			continue
		fi
		if [[ "$in_decisions" == true ]]; then
			# Stop at next section
			[[ "$line" == "## "* && "$line" != "## Decision"* ]] && break

			# Skip table header and separator
			if [[ "$line" == "|"*"Date"*"|"* || "$line" == "|"*"---"*"|"* ]]; then
				in_table=true
				continue
			fi

			# Parse table rows
			if [[ "$in_table" == true && "$line" == "|"* ]]; then
				# Extract decision and rationale columns
				local decision rationale
				decision=$(echo "$line" | awk -F'|' '{print $4}' | xargs)
				rationale=$(echo "$line" | awk -F'|' '{print $5}' | xargs)

				# Skip empty or template rows
				if [[ -n "$decision" && "$decision" != "" && "$decision" != *"{"* ]]; then
					"$MEMORY_HELPER" store --auto \
						--type "DECISION" \
						--content "Mission $mission_id decision: $decision. Rationale: $rationale" \
						--tags "mission,decision,$mission_id" \
						2>/dev/null || true
				fi
			fi
		fi
	done <"$file"

	return 0
}

# Score an artifact for promotion potential (0-10)
# Scoring factors:
#   - Size (larger = more substantial): 0-2 points
#   - Has YAML frontmatter (structured): 0-2 points
#   - Has description (documented): 0-2 points
#   - Not project-specific (generalizable): 0-2 points
#   - Recurrence (appears in multiple missions): 0-2 points
score_artifact() {
	local file="$1"
	local type="$2"
	local score=0

	local size
	size=$(wc -c <"$file" | tr -d ' ')

	# Size scoring
	if [[ "$size" -gt 2000 ]]; then
		score=$((score + 2))
	elif [[ "$size" -gt 500 ]]; then
		score=$((score + 1))
	fi

	if [[ "$type" == "agent" ]]; then
		# Has YAML frontmatter
		local first_line
		first_line=$(head -1 "$file")
		if [[ "$first_line" == "---" ]]; then
			score=$((score + 2))
		fi

		# Has description
		local desc
		desc=$(extract_description "$file")
		if [[ -n "$desc" ]]; then
			score=$((score + 2))
		fi
	elif [[ "$type" == "script" ]]; then
		# Has shebang
		local first_line
		first_line=$(head -1 "$file")
		if [[ "$first_line" == "#!/"* ]]; then
			score=$((score + 1))
		fi

		# Has help/usage function
		if grep -q 'cmd_help\|usage()' "$file" 2>/dev/null; then
			score=$((score + 2))
		fi

		# Uses set -euo pipefail (quality indicator)
		if grep -q 'set -euo pipefail' "$file" 2>/dev/null; then
			score=$((score + 1))
		fi
	fi

	# Not project-specific (heuristic: no hardcoded paths or project names)
	local project_specific=false
	if grep -qE '(localhost:[0-9]+|/home/[a-z]+/|/Users/[a-z]+/)' "$file" 2>/dev/null; then
		project_specific=true
	fi
	if [[ "$project_specific" == false ]]; then
		score=$((score + 2))
	fi

	echo "$score"
	return 0
}

# Map score to recommendation
recommend_action() {
	local score="$1"

	if [[ "$score" -le 3 ]]; then
		echo "DELETE (low value)"
	elif [[ "$score" -le 6 ]]; then
		echo "KEEP (mission-specific)"
	elif [[ "$score" -le 8 ]]; then
		echo "PROMOTE to draft/ (review needed)"
	else
		echo "PROMOTE to custom/ (high value)"
	fi

	return 0
}

# Add promotion metadata to a promoted markdown file
add_promotion_metadata() {
	local target_file="$1"
	local source_path="$2"
	local timestamp
	timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	# Check if file has YAML frontmatter
	local first_line
	first_line=$(head -1 "$target_file")

	if [[ "$first_line" == "---" ]]; then
		# Insert promotion metadata into existing frontmatter
		# Find the closing --- and insert before it
		local tmp_file
		tmp_file=$(mktemp)
		trap 'rm -f "${tmp_file:-}"' RETURN

		local inserted=false
		local in_frontmatter=false
		while IFS= read -r line; do
			if [[ "$line" == "---" && "$in_frontmatter" == false ]]; then
				in_frontmatter=true
				echo "$line" >>"$tmp_file"
				continue
			fi
			if [[ "$line" == "---" && "$in_frontmatter" == true && "$inserted" == false ]]; then
				echo "promoted_from: \"$source_path\"" >>"$tmp_file"
				echo "promoted_at: \"$timestamp\"" >>"$tmp_file"
				echo "status: draft" >>"$tmp_file"
				inserted=true
			fi
			echo "$line" >>"$tmp_file"
		done <"$target_file"

		mv "$tmp_file" "$target_file"
	fi

	return 0
}

# =============================================================================
# Help
# =============================================================================

cmd_help() {
	cat <<'EOF'
mission-skill-learning.sh - Auto-capture reusable patterns from missions

Scans completed mission directories for artifacts (agents, scripts, research),
scores them for promotion potential, and stores patterns in cross-session memory.

USAGE:
    mission-skill-learning.sh <command> [options]

COMMANDS:
    scan <mission-dir>          List all artifacts in a mission directory
    score <mission-dir>         Score artifacts for promotion potential (0-10)
    promote <path> [options]    Copy artifact to draft/ or custom/
    remember <mission-dir>      Store mission patterns in cross-session memory
    recurrence [options]        Check artifact recurrence across all missions
    help                        Show this help

PROMOTE OPTIONS:
    --target draft|custom       Promotion target (default: draft)
    --dry-run                   Preview without copying

RECURRENCE OPTIONS:
    --all-missions <path>       Root directory containing mission subdirectories

SCORING:
    0-3  DELETE      Low value, mission-specific noise
    4-6  KEEP        Useful within this mission only
    7-8  PROMOTE     Worth promoting to draft/ for review
    9-10 PROMOTE+    High value, promote to custom/

SCORING FACTORS:
    - Content size (substantial vs trivial)
    - Structure (YAML frontmatter, shebang, help function)
    - Documentation (description field, usage docs)
    - Generalizability (no hardcoded paths or project names)
    - Recurrence (appears in multiple missions)

WORKFLOW:
    1. Mission completes (orchestrator Phase 5)
    2. Run 'scan' to discover artifacts
    3. Run 'score' to evaluate promotion potential
    4. Orchestrator reviews scores and decides promotions
    5. Run 'promote' for selected artifacts
    6. Run 'remember' to store patterns in memory
    7. Future missions benefit from stored patterns

INTEGRATION:
    - Mission orchestrator: Phase 5 calls scan + score + remember
    - Memory system: patterns stored via memory-helper.sh --auto
    - Agent lifecycle: promoted artifacts follow draft -> custom -> shared path

EXAMPLES:
    # Scan a completed mission
    mission-skill-learning.sh scan ~/Git/myapp/todo/missions/m-20260227-abc123

    # Score artifacts for promotion
    mission-skill-learning.sh score ~/Git/myapp/todo/missions/m-20260227-abc123

    # Promote a useful agent to draft/
    mission-skill-learning.sh promote ~/Git/myapp/todo/missions/m-20260227-abc123/agents/api-patterns.md

    # Store mission patterns in memory
    mission-skill-learning.sh remember ~/Git/myapp/todo/missions/m-20260227-abc123

    # Check which artifacts recur across missions
    mission-skill-learning.sh recurrence --all-missions ~/Git/myapp/todo/missions
EOF
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	scan | list) cmd_scan "$@" ;;
	score | evaluate) cmd_score "$@" ;;
	promote | move) cmd_promote "$@" ;;
	remember | store) cmd_remember "$@" ;;
	recurrence | recurring) cmd_recurrence "$@" ;;
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
