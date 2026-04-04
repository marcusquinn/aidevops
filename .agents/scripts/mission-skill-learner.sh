#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# mission-skill-learner.sh — Auto-capture reusable patterns from completed missions
#
# Scans mission directories for agents, scripts, and patterns that proved useful.
# Scores them for reusability, suggests promotion to custom/ or shared/, and
# stores learnings in cross-session memory for future mission planning.
#
# Usage:
#   mission-skill-learner.sh scan <mission-dir>          # Scan a completed mission
#   mission-skill-learner.sh scan-all [--repo <path>]    # Scan all completed missions
#   mission-skill-learner.sh promote <artifact-path>     # Promote an artifact to draft/
#   mission-skill-learner.sh patterns [--mission <id>]   # Show recurring patterns
#   mission-skill-learner.sh suggest <mission-dir>       # Suggest promotions for a mission
#   mission-skill-learner.sh stats                       # Show learning statistics
#   mission-skill-learner.sh help
#
# Integration:
#   - Called by mission orchestrator at Phase 5 (completion)
#   - Called by pulse supervisor when missions complete
#   - Stores patterns in memory.db via memory-helper.sh
#   - Writes promotion suggestions to mission state file
#
# Dependencies: sqlite3, jq (optional), memory-helper.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
init_log_file

readonly MEMORY_HELPER="${SCRIPT_DIR}/memory-helper.sh"
readonly MEMORY_DIR="${AIDEVOPS_MEMORY_DIR:-$HOME/.aidevops/.agent-workspace/memory}"
readonly MEMORY_DB="${MEMORY_DIR}/memory.db"
readonly DRAFT_DIR="$HOME/.aidevops/agents/draft"
readonly CUSTOM_DIR="$HOME/.aidevops/agents/custom"

# Minimum score thresholds for promotion suggestions
readonly PROMOTE_THRESHOLD_DRAFT=40
readonly PROMOTE_THRESHOLD_CUSTOM=70
readonly PROMOTE_THRESHOLD_SHARED=85

# Memory type for mission learnings
readonly MEMORY_TYPE_MISSION_PATTERN="MISSION_PATTERN"
readonly MEMORY_TYPE_MISSION_AGENT="MISSION_AGENT"
readonly MEMORY_TYPE_MISSION_SCRIPT="MISSION_SCRIPT"

#######################################
# Logging helpers (use shared-constants colours)
#######################################
log_info() {
	echo -e "${BLUE:-}[INFO]${NC:-} $*"
	return 0
}
log_success() {
	echo -e "${GREEN:-}[OK]${NC:-} $*"
	return 0
}
log_warn() {
	echo -e "${YELLOW:-}[WARN]${NC:-} $*"
	return 0
}
log_error() {
	echo -e "${RED:-}[ERROR]${NC:-} $*" >&2
	return 0
}

#######################################
# Ensure memory database exists
#######################################
ensure_db() {
	if [[ ! -f "$MEMORY_DB" ]]; then
		log_warn "No memory database found at: $MEMORY_DB"
		log_info "Run 'memory-helper.sh store' to initialize."
		return 1
	fi
	return 0
}

#######################################
# Ensure the mission_learnings table exists in memory.db
#######################################
ensure_learnings_table() {
	ensure_db || return 1

	sqlite3 "$MEMORY_DB" "
		CREATE TABLE IF NOT EXISTS mission_learnings (
			id TEXT PRIMARY KEY,
			mission_id TEXT NOT NULL,
			artifact_type TEXT NOT NULL,  -- agent, script, pattern, decision
			artifact_path TEXT,
			artifact_name TEXT NOT NULL,
			description TEXT,
			reuse_score INTEGER DEFAULT 0,  -- 0-100
			times_seen INTEGER DEFAULT 1,
			first_seen TEXT NOT NULL,
			last_seen TEXT NOT NULL,
			promoted_to TEXT,  -- NULL, draft, custom, shared
			promoted_at TEXT,
			tags TEXT,
			UNIQUE(mission_id, artifact_name, artifact_type)
		);
	" 2>/dev/null || {
		log_warn "Failed to create mission_learnings table"
		return 1
	}
	return 0
}

#######################################
# Generate a unique learning ID
#######################################
generate_learning_id() {
	local timestamp
	timestamp=$(date -u +%Y%m%d%H%M%S)
	local random_hex
	random_hex=$(od -An -tx4 -N4 /dev/urandom 2>/dev/null | tr -d ' ' || printf '%04x' "$$")
	echo "msl_${timestamp}_${random_hex}"
}

#######################################
# Parse mission frontmatter to extract mission ID and status
# $1: mission state file path
#######################################
parse_mission_state() {
	local mission_file="$1"

	if [[ ! -f "$mission_file" ]]; then
		log_error "Mission file not found: $mission_file"
		return 1
	fi

	# Extract frontmatter fields using simple grep/sed
	local mission_id=""
	local mission_status=""
	local mission_title=""

	mission_id=$(sed -n '/^---$/,/^---$/{ s/^id: *"\{0,1\}\([^"]*\)"\{0,1\}/\1/p; }' "$mission_file" | head -1)
	mission_status=$(sed -n '/^---$/,/^---$/{ s/^status: *\([^ ]*\)/\1/p; }' "$mission_file" | head -1)
	mission_title=$(sed -n '/^# /{s/^# *//;p;q;}' "$mission_file")

	echo "MISSION_ID=${mission_id}"
	echo "MISSION_STATUS=${mission_status}"
	echo "MISSION_TITLE=${mission_title}"
	return 0
}

#######################################
# Score generality of an artifact (+30 max)
# Penalises project-specific paths/URLs; rewards generic variable patterns.
# $1: artifact content (string)
# Outputs: integer points earned
#######################################
_score_generality() {
	local content="$1"
	local points=0
	local specificity_hits=0

	if echo "$content" | grep -qiE '(localhost:[0-9]+|127\.0\.0\.1|/home/[a-z]+/Git/[a-z])'; then
		specificity_hits=$((specificity_hits + 1))
	fi
	if echo "$content" | grep -qiE '(my-project|my-app|myapp|todo/missions/m-)'; then
		specificity_hits=$((specificity_hits + 1))
	fi
	# Reward generic patterns: env vars, positional params, long-form flags
	# shellcheck disable=SC2016 # Intentional: checking for literal $ patterns in content
	if echo "$content" | grep -qiE '(\$\{?[A-Z_]+\}?|\$1|\$2|--[a-z]+-[a-z]+)'; then
		points=$((points + 15))
	fi
	if [[ "$specificity_hits" -eq 0 ]]; then
		points=$((points + 15))
	elif [[ "$specificity_hits" -eq 1 ]]; then
		points=$((points + 8))
	fi

	echo "$points"
	return 0
}

#######################################
# Score documentation quality of an artifact (+20 max)
# $1: artifact content (string)
# $2: artifact type (agent|script)
# Outputs: integer points earned
#######################################
_score_documentation() {
	local content="$1"
	local artifact_type="$2"
	local points=0

	if [[ "$artifact_type" == "agent" ]]; then
		if echo "$content" | grep -q '^---'; then
			points=$((points + 7))
		fi
		if echo "$content" | grep -qi 'description:'; then
			points=$((points + 7))
		fi
		if echo "$content" | grep -qE '^## '; then
			points=$((points + 6))
		fi
	elif [[ "$artifact_type" == "script" ]]; then
		if echo "$content" | grep -qi '# Usage:'; then
			points=$((points + 7))
		fi
		if echo "$content" | grep -qi 'set -euo pipefail'; then
			points=$((points + 7))
		fi
		if echo "$content" | grep -qE '^[a-z_]+\(\)'; then
			points=$((points + 6))
		fi
	fi

	echo "$points"
	return 0
}

#######################################
# Score artifact size appropriateness (+15 max)
# Sweet spot: 20-200 lines for agents, 30-500 for scripts.
# $1: line count (integer)
# $2: artifact type (agent|script)
# Outputs: integer points earned
#######################################
_score_size() {
	local line_count="$1"
	local artifact_type="$2"
	local points=0

	if [[ "$artifact_type" == "agent" ]]; then
		if [[ "$line_count" -ge 20 && "$line_count" -le 200 ]]; then
			points=15
		elif [[ "$line_count" -ge 10 && "$line_count" -le 300 ]]; then
			points=8
		elif [[ "$line_count" -lt 10 ]]; then
			points=2 # Too trivial
		fi
	elif [[ "$artifact_type" == "script" ]]; then
		if [[ "$line_count" -ge 30 && "$line_count" -le 500 ]]; then
			points=15
		elif [[ "$line_count" -ge 15 && "$line_count" -le 800 ]]; then
			points=8
		elif [[ "$line_count" -lt 15 ]]; then
			points=2
		fi
	fi

	echo "$points"
	return 0
}

#######################################
# Score adherence to aidevops standard format (+15 max)
# $1: artifact content (string)
# $2: artifact type (agent|script)
# Outputs: integer points earned
#######################################
_score_standard_format() {
	local content="$1"
	local artifact_type="$2"
	local points=0

	if [[ "$artifact_type" == "agent" ]]; then
		if echo "$content" | grep -q 'mode: subagent'; then
			points=$((points + 10))
		fi
		if echo "$content" | grep -q 'tools:'; then
			points=$((points + 5))
		fi
	elif [[ "$artifact_type" == "script" ]]; then
		if echo "$content" | grep -q '#!/usr/bin/env bash'; then
			points=$((points + 5))
		fi
		if echo "$content" | grep -q 'shared-constants.sh'; then
			points=$((points + 5))
		fi
		if echo "$content" | grep -q 'local '; then
			points=$((points + 5))
		fi
	fi

	echo "$points"
	return 0
}

#######################################
# Score multi-feature usage within the mission (+20 max)
# $1: artifact path
# $2: mission directory
# Outputs: integer points earned
#######################################
_score_multi_feature_usage() {
	local artifact_path="$1"
	local mission_dir="$2"
	local points=0
	local ref_count=0

	if [[ -d "$mission_dir" ]]; then
		local artifact_name
		artifact_name=$(basename "$artifact_path")
		ref_count=$(grep -rl "$artifact_name" "$mission_dir" 2>/dev/null | wc -l | tr -d ' ')
		# Subtract self-reference
		ref_count=$((ref_count > 0 ? ref_count - 1 : 0))
	fi

	if [[ "$ref_count" -ge 3 ]]; then
		points=20
	elif [[ "$ref_count" -ge 2 ]]; then
		points=15
	elif [[ "$ref_count" -ge 1 ]]; then
		points=8
	fi

	echo "$points"
	return 0
}

#######################################
# Score an artifact for reusability (0-100)
# Factors:
#   - Generality (not project-specific): +30
#   - Documentation quality (has description/comments): +20
#   - Size (not too large, not trivial): +15
#   - Standard format (follows aidevops conventions): +15
#   - Used by multiple features in the mission: +20
#
# $1: artifact path
# $2: artifact type (agent|script)
# $3: mission directory
#######################################
score_artifact() {
	local artifact_path="$1"
	local artifact_type="$2"
	local mission_dir="$3"

	if [[ ! -f "$artifact_path" ]]; then
		echo "0"
		return 0
	fi

	local content
	content=$(cat "$artifact_path")
	local line_count
	line_count=$(wc -l <"$artifact_path" | tr -d ' ')

	local score=0
	local pts

	pts=$(_score_generality "$content")
	score=$((score + pts))

	pts=$(_score_documentation "$content" "$artifact_type")
	score=$((score + pts))

	pts=$(_score_size "$line_count" "$artifact_type")
	score=$((score + pts))

	pts=$(_score_standard_format "$content" "$artifact_type")
	score=$((score + pts))

	pts=$(_score_multi_feature_usage "$artifact_path" "$mission_dir")
	score=$((score + pts))

	# Clamp to 0-100
	if [[ "$score" -gt 100 ]]; then
		score=100
	fi

	echo "$score"
	return 0
}

#######################################
# Extract a short description from an artifact
# $1: artifact path
# $2: artifact type
#######################################
extract_description() {
	local artifact_path="$1"
	local artifact_type="$2"

	if [[ ! -f "$artifact_path" ]]; then
		echo "(file not found)"
		return 0
	fi

	if [[ "$artifact_type" == "agent" ]]; then
		# Try frontmatter description first
		local desc
		desc=$(sed -n '/^---$/,/^---$/{ s/^description: *//p; }' "$artifact_path" | head -1)
		if [[ -n "$desc" ]]; then
			echo "$desc"
			return 0
		fi
		# Fall back to first heading
		desc=$(sed -n '/^# /{s/^# *//;p;q;}' "$artifact_path")
		if [[ -n "$desc" ]]; then
			echo "$desc"
			return 0
		fi
	elif [[ "$artifact_type" == "script" ]]; then
		# Try first comment line after shebang
		local desc
		desc=$(sed -n '2{s/^# *//;p;}' "$artifact_path")
		if [[ -n "$desc" && ${#desc} -gt 5 ]]; then
			echo "$desc"
			return 0
		fi
	fi

	echo "(no description)"
	return 0
}

#######################################
# Print score-coloured artifact row
# $1: score (integer)
# $2: name
# $3: description
#######################################
_print_artifact_row() {
	local score="$1"
	local name="$2"
	local desc="$3"
	local score_color="${RED:-}"

	if [[ "$score" -ge "$PROMOTE_THRESHOLD_SHARED" ]]; then
		score_color="${GREEN:-}"
	elif [[ "$score" -ge "$PROMOTE_THRESHOLD_CUSTOM" ]]; then
		score_color="${CYAN:-}"
	elif [[ "$score" -ge "$PROMOTE_THRESHOLD_DRAFT" ]]; then
		score_color="${YELLOW:-}"
	fi

	printf "  %s%-3d%s  %-30s %s\n" "$score_color" "$score" "${NC:-}" "$name" "$desc"
	return 0
}

#######################################
# Upsert a single artifact learning record into mission_learnings
# $1: mission_id
# $2: artifact_type (agent|script)
# $3: artifact_path
# $4: artifact_name
# $5: description
# $6: score
# $7: now (ISO timestamp)
# $8: tags
#######################################
_upsert_learning() {
	local mission_id="$1"
	local artifact_type="$2"
	local artifact_path="$3"
	local artifact_name="$4"
	local description="$5"
	local score="$6"
	local now="$7"
	local tags="$8"
	local learning_id
	learning_id=$(generate_learning_id)

	local safe_mid safe_path safe_name safe_desc
	safe_mid=$(echo "$mission_id" | sed "s/'/''/g")
	safe_path=$(echo "$artifact_path" | sed "s/'/''/g")
	safe_name=$(echo "$artifact_name" | sed "s/'/''/g")
	safe_desc=$(echo "$description" | sed "s/'/''/g")

	sqlite3 "$MEMORY_DB" "
		INSERT INTO mission_learnings (id, mission_id, artifact_type, artifact_path, artifact_name, description, reuse_score, times_seen, first_seen, last_seen, tags)
		VALUES ('$learning_id', '$safe_mid', '$artifact_type', '$safe_path', '$safe_name', '$safe_desc', $score, 1, '$now', '$now', '$tags')
		ON CONFLICT(mission_id, artifact_name, artifact_type) DO UPDATE SET
			reuse_score = MAX(reuse_score, $score),
			times_seen = times_seen + 1,
			last_seen = '$now',
			description = '$safe_desc';
	" 2>/dev/null || log_warn "Failed to store $artifact_type learning: $artifact_name"
	return 0
}

#######################################
# Scan mission agents subdirectory
# $1: mission_dir
# $2: mission_id
# $3: now (ISO timestamp)
# Outputs: count of agents found (via stdout of last echo)
# Sets found_count via nameref is not bash 3.2 safe; caller adds return value.
#######################################
_scan_agents() {
	local mission_dir="$1"
	local mission_id="$2"
	local now="$3"
	local count=0

	if [[ ! -d "${mission_dir}/agents" ]]; then
		echo "$count"
		return 0
	fi

	echo -e "${CYAN:-}Mission Agents:${NC:-}"
	local agent_file
	while IFS= read -r -d '' agent_file; do
		local agent_name agent_score agent_desc
		agent_name=$(basename "$agent_file" .md)
		agent_score=$(score_artifact "$agent_file" "agent" "$mission_dir")
		agent_desc=$(extract_description "$agent_file" "agent")

		_upsert_learning "$mission_id" "agent" "$agent_file" "$agent_name" "$agent_desc" "$agent_score" "$now" "mission,agent"
		_print_artifact_row "$agent_score" "$agent_name" "$agent_desc"
		count=$((count + 1))
	done < <(find "${mission_dir}/agents" -name "*.md" -type f -print0 2>/dev/null)

	if [[ "$count" -eq 0 ]]; then
		echo "  (none found)"
	fi
	echo ""
	echo "$count"
	return 0
}

#######################################
# Scan mission scripts subdirectory
# $1: mission_dir
# $2: mission_id
# $3: now (ISO timestamp)
# Outputs: count of scripts found (via stdout of last echo)
#######################################
_scan_scripts() {
	local mission_dir="$1"
	local mission_id="$2"
	local now="$3"
	local count=0

	if [[ ! -d "${mission_dir}/scripts" ]]; then
		echo "$count"
		return 0
	fi

	echo -e "${CYAN:-}Mission Scripts:${NC:-}"
	local script_file
	while IFS= read -r -d '' script_file; do
		local script_name script_score script_desc
		script_name=$(basename "$script_file")
		script_score=$(score_artifact "$script_file" "script" "$mission_dir")
		script_desc=$(extract_description "$script_file" "script")

		_upsert_learning "$mission_id" "script" "$script_file" "$script_name" "$script_desc" "$script_score" "$now" "mission,script"
		_print_artifact_row "$script_score" "$script_name" "$script_desc"
		count=$((count + 1))
	done < <(find "${mission_dir}/scripts" -name "*.sh" -type f -print0 2>/dev/null)

	if [[ "$count" -eq 0 ]]; then
		echo "  (none found)"
	fi
	echo ""
	echo "$count"
	return 0
}

#######################################
# Extract and store decision patterns from mission.md
# $1: mission_file path
# $2: mission_id
# Outputs: count of decisions found (via stdout of last echo)
#######################################
_scan_decisions() {
	local mission_file="$1"
	local mission_id="$2"
	local count=0

	echo -e "${CYAN:-}Decision Patterns:${NC:-}"

	if [[ -f "$mission_file" ]]; then
		local in_decisions=false
		while IFS= read -r line; do
			if echo "$line" | grep -q '## Decision Log'; then
				in_decisions=true
				continue
			fi
			if [[ "$in_decisions" == true ]] && echo "$line" | grep -q '^## '; then
				break
			fi
			if [[ "$in_decisions" == true ]] && echo "$line" | grep -qE '^\| [0-9]'; then
				local decision_text
				decision_text=$(echo "$line" | awk -F'|' '{gsub(/^ +| +$/, "", $4); print $4}')
				if [[ -n "$decision_text" && "$decision_text" != "Rationale" ]]; then
					"$MEMORY_HELPER" store \
						--content "[mission:${mission_id}] Decision: ${decision_text}" \
						--type "$MEMORY_TYPE_MISSION_PATTERN" \
						--tags "mission,decision,${mission_id}" \
						--confidence "medium" 2>/dev/null || true
					echo "  + $decision_text"
					count=$((count + 1))
				fi
			fi
		done <"$mission_file"
	fi

	if [[ "$count" -eq 0 ]]; then
		echo "  (none found)"
	fi
	echo ""
	echo "$count"
	return 0
}

#######################################
# Extract and store lessons learned from mission.md
# $1: mission_file path
# $2: mission_id
# Outputs: count of lessons found (via stdout of last echo)
#######################################
_scan_lessons() {
	local mission_file="$1"
	local mission_id="$2"
	local count=0

	echo -e "${CYAN:-}Lessons Learned:${NC:-}"

	if [[ -f "$mission_file" ]]; then
		local in_lessons=false
		while IFS= read -r line; do
			if echo "$line" | grep -q '### Lessons Learned'; then
				in_lessons=true
				continue
			fi
			if [[ "$in_lessons" == true ]] && echo "$line" | grep -q '^## \|^### '; then
				break
			fi
			if [[ "$in_lessons" == true ]] && echo "$line" | grep -qE '^- '; then
				local lesson
				lesson=$(echo "$line" | sed 's/^- *//')
				if [[ -n "$lesson" && "$lesson" != "{What"* ]]; then
					"$MEMORY_HELPER" store \
						--content "[mission:${mission_id}] Lesson: ${lesson}" \
						--type "$MEMORY_TYPE_MISSION_PATTERN" \
						--tags "mission,lesson,${mission_id}" \
						--confidence "high" 2>/dev/null || true
					echo "  + $lesson"
					count=$((count + 1))
				fi
			fi
		done <"$mission_file"
	fi

	if [[ "$count" -eq 0 ]]; then
		echo "  (none found)"
	fi
	echo ""
	echo "$count"
	return 0
}

#######################################
# Print scan summary and promotion suggestions
# $1: mission_id
# $2: found_count (total artifacts)
#######################################
_scan_summary() {
	local mission_id="$1"
	local found_count="$2"
	local safe_mid
	safe_mid=$(echo "$mission_id" | sed "s/'/''/g")

	echo -e "${CYAN:-}Summary:${NC:-}"
	echo "  Artifacts scanned: $found_count"

	local promote_count
	promote_count=$(sqlite3 "$MEMORY_DB" "
		SELECT COUNT(*) FROM mission_learnings
		WHERE mission_id = '$safe_mid'
		AND reuse_score >= $PROMOTE_THRESHOLD_DRAFT
		AND promoted_to IS NULL;
	" 2>/dev/null || echo "0")
	echo "  Promotion candidates (score >= $PROMOTE_THRESHOLD_DRAFT): $promote_count"

	if [[ "$promote_count" -gt 0 ]]; then
		echo ""
		echo -e "${CYAN:-}Promotion Suggestions:${NC:-}"
		sqlite3 -separator '|' "$MEMORY_DB" "
			SELECT artifact_name, artifact_type, reuse_score, description
			FROM mission_learnings
			WHERE mission_id = '$safe_mid'
			AND reuse_score >= $PROMOTE_THRESHOLD_DRAFT
			AND promoted_to IS NULL
			ORDER BY reuse_score DESC;
		" 2>/dev/null | while IFS='|' read -r name atype ascore adesc; do
			local target="draft/"
			if [[ "$ascore" -ge "$PROMOTE_THRESHOLD_SHARED" ]]; then
				target="shared/ (PR required)"
			elif [[ "$ascore" -ge "$PROMOTE_THRESHOLD_CUSTOM" ]]; then
				target="custom/"
			fi
			printf "  %-30s %-8s score:%-3d -> %s\n" "$name" "($atype)" "$ascore" "$target"
			echo "    $adesc"
		done
	fi

	echo ""
	return 0
}

#######################################
# Scan a mission directory for reusable artifacts
# $1: mission directory path
#######################################
cmd_scan() {
	local mission_dir="$1"

	if [[ -z "$mission_dir" ]]; then
		log_error "Mission directory required: mission-skill-learner.sh scan <mission-dir>"
		return 1
	fi

	mission_dir=$(cd "$mission_dir" 2>/dev/null && pwd) || {
		log_error "Cannot access mission directory: $mission_dir"
		return 1
	}

	local mission_file="${mission_dir}/mission.md"
	if [[ ! -f "$mission_file" ]]; then
		log_error "No mission.md found in: $mission_dir"
		return 1
	fi

	local mission_id="" mission_status="" mission_title=""
	eval "$(parse_mission_state "$mission_file")"
	if [[ -z "$mission_id" ]]; then
		mission_id=$(basename "$mission_dir")
	fi

	echo ""
	echo -e "${CYAN:-}=== Mission Skill Learning: $mission_id ===${NC:-}"
	echo -e "  Title: ${mission_title:-unknown}"
	echo -e "  Status: ${mission_status:-unknown}"
	echo ""

	ensure_learnings_table || return 1

	local now
	now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	# Scan each artifact category; capture counts from last line of each helper's output
	local agent_out script_out decision_out lesson_out
	agent_out=$(_scan_agents "$mission_dir" "$mission_id" "$now")
	script_out=$(_scan_scripts "$mission_dir" "$mission_id" "$now")
	decision_out=$(_scan_decisions "$mission_file" "$mission_id")
	lesson_out=$(_scan_lessons "$mission_file" "$mission_id")

	# Print buffered output (all display lines except the trailing count)
	echo "$agent_out" | sed '$d'
	echo "$script_out" | sed '$d'
	echo "$decision_out" | sed '$d'
	echo "$lesson_out" | sed '$d'

	# Sum counts (last line of each output block)
	local agent_count script_count decision_count lesson_count found_count
	agent_count=$(echo "$agent_out" | tail -1)
	script_count=$(echo "$script_out" | tail -1)
	decision_count=$(echo "$decision_out" | tail -1)
	lesson_count=$(echo "$lesson_out" | tail -1)
	found_count=$((agent_count + script_count + decision_count + lesson_count))

	_scan_summary "$mission_id" "$found_count"
	log_success "Scan complete for mission: $mission_id"
	return 0
}

#######################################
# Scan all completed missions
#######################################
cmd_scan_all() {
	local repo_path=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo)
			repo_path="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	local mission_dirs=()

	# Check repo-attached missions
	if [[ -n "$repo_path" ]]; then
		local missions_base="${repo_path}/todo/missions"
		if [[ -d "$missions_base" ]]; then
			while IFS= read -r -d '' mdir; do
				if [[ -f "${mdir}/mission.md" ]]; then
					mission_dirs+=("$mdir")
				fi
			done < <(find "$missions_base" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
		fi
	else
		# Check current repo
		local repo_root
		repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
		if [[ -n "$repo_root" && -d "${repo_root}/todo/missions" ]]; then
			while IFS= read -r -d '' mdir; do
				if [[ -f "${mdir}/mission.md" ]]; then
					mission_dirs+=("$mdir")
				fi
			done < <(find "${repo_root}/todo/missions" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
		fi
	fi

	# Check homeless missions
	local homeless_base="$HOME/.aidevops/missions"
	if [[ -d "$homeless_base" ]]; then
		while IFS= read -r -d '' mdir; do
			if [[ -f "${mdir}/mission.md" ]]; then
				mission_dirs+=("$mdir")
			fi
		done < <(find "$homeless_base" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
	fi

	if [[ ${#mission_dirs[@]} -eq 0 ]]; then
		log_info "No mission directories found."
		log_info "Missions are stored in:"
		log_info "  - {repo}/todo/missions/*/mission.md (repo-attached)"
		log_info "  - ~/.aidevops/missions/*/mission.md (homeless)"
		return 0
	fi

	echo ""
	echo -e "${CYAN:-}=== Scanning ${#mission_dirs[@]} mission(s) ===${NC:-}"
	echo ""

	local scanned=0
	for mdir in "${mission_dirs[@]}"; do
		cmd_scan "$mdir" || log_warn "Failed to scan: $mdir"
		scanned=$((scanned + 1))
		echo "---"
	done

	echo ""
	log_success "Scanned $scanned mission(s)"
	return 0
}

#######################################
# Promote an artifact from a mission to draft/
# $1: artifact path (in mission directory)
# $2: optional target (draft|custom) — default: draft
#######################################
cmd_promote() {
	local artifact_path="$1"
	local target="${2:-draft}"

	if [[ -z "$artifact_path" ]]; then
		log_error "Artifact path required: mission-skill-learner.sh promote <path> [draft|custom]"
		return 1
	fi

	if [[ ! -f "$artifact_path" ]]; then
		log_error "Artifact not found: $artifact_path"
		return 1
	fi

	local artifact_name
	artifact_name=$(basename "$artifact_path")
	local target_dir=""

	case "$target" in
	draft)
		target_dir="$DRAFT_DIR"
		;;
	custom)
		target_dir="$CUSTOM_DIR"
		;;
	shared)
		log_error "Shared promotion requires a PR. Copy to .agents/ and submit via git workflow."
		return 1
		;;
	*)
		log_error "Invalid target: $target (use draft or custom)"
		return 1
		;;
	esac

	# Create target directory if needed
	mkdir -p "$target_dir"

	# Check for conflicts
	if [[ -f "${target_dir}/${artifact_name}" ]]; then
		log_warn "File already exists: ${target_dir}/${artifact_name}"
		log_info "Use a different name or manually merge."
		return 1
	fi

	# Copy the artifact
	cp "$artifact_path" "${target_dir}/${artifact_name}"
	log_success "Promoted: $artifact_name -> ${target_dir}/"

	# Update the learning record
	if ensure_db 2>/dev/null; then
		local now
		now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
		sqlite3 "$MEMORY_DB" "
			UPDATE mission_learnings
			SET promoted_to = '$target', promoted_at = '$now'
			WHERE artifact_name = '$(echo "$artifact_name" | sed "s/'/''/g")'
			AND promoted_to IS NULL;
		" 2>/dev/null || true
	fi

	# Store the promotion event in memory
	"$MEMORY_HELPER" store \
		--content "Promoted mission artifact '$artifact_name' to $target/ tier" \
		--type "$MEMORY_TYPE_MISSION_AGENT" \
		--tags "mission,promotion,$target,$artifact_name" \
		--confidence "high" 2>/dev/null || true

	return 0
}

#######################################
# Show recurring patterns across missions
#######################################
cmd_patterns() {
	local mission_filter=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--mission)
			mission_filter="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	ensure_learnings_table || return 1

	echo ""
	echo -e "${CYAN:-}=== Recurring Mission Patterns ===${NC:-}"
	echo ""

	# Artifacts seen across multiple missions
	echo -e "${CYAN:-}Artifacts Seen in Multiple Missions:${NC:-}"
	local multi_mission
	multi_mission=$(sqlite3 -separator '|' "$MEMORY_DB" "
		SELECT artifact_name, artifact_type, COUNT(DISTINCT mission_id) as mission_count,
			   MAX(reuse_score) as best_score, GROUP_CONCAT(DISTINCT mission_id) as missions
		FROM mission_learnings
		GROUP BY artifact_name, artifact_type
		HAVING COUNT(DISTINCT mission_id) > 1
		ORDER BY mission_count DESC, best_score DESC
		LIMIT 20;
	" 2>/dev/null || echo "")

	if [[ -n "$multi_mission" ]]; then
		printf "  %-30s %-8s %-8s %-6s %s\n" "Name" "Type" "Missions" "Score" "Seen in"
		printf "  %-30s %-8s %-8s %-6s %s\n" "----" "----" "--------" "-----" "-------"
		while IFS='|' read -r name atype mcount score missions; do
			printf "  %-30s %-8s %-8s %-6s %s\n" "$name" "$atype" "$mcount" "$score" "$missions"
		done <<<"$multi_mission"
	else
		echo "  (no artifacts seen across multiple missions yet)"
	fi
	echo ""

	# Memory patterns from missions
	echo -e "${CYAN:-}Mission Learnings in Memory:${NC:-}"
	local mission_memories
	if [[ -n "$mission_filter" ]]; then
		mission_memories=$("$MEMORY_HELPER" recall --query "mission:${mission_filter}" --type "$MEMORY_TYPE_MISSION_PATTERN" --limit 20 2>/dev/null || echo "")
	else
		mission_memories=$("$MEMORY_HELPER" recall --query "mission" --type "$MEMORY_TYPE_MISSION_PATTERN" --limit 20 2>/dev/null || echo "")
	fi

	if [[ -n "$mission_memories" ]]; then
		echo "$mission_memories"
	else
		echo "  (no mission patterns in memory yet)"
	fi
	echo ""

	# Top promotion candidates across all missions
	echo -e "${CYAN:-}Top Promotion Candidates (not yet promoted):${NC:-}"
	local candidates
	candidates=$(sqlite3 -separator '|' "$MEMORY_DB" "
		SELECT artifact_name, artifact_type, reuse_score, description, mission_id
		FROM mission_learnings
		WHERE promoted_to IS NULL
		AND reuse_score >= $PROMOTE_THRESHOLD_DRAFT
		ORDER BY reuse_score DESC
		LIMIT 10;
	" 2>/dev/null || echo "")

	if [[ -n "$candidates" ]]; then
		while IFS='|' read -r name atype score desc mid; do
			local target="draft/"
			if [[ "$score" -ge "$PROMOTE_THRESHOLD_SHARED" ]]; then
				target="shared/"
			elif [[ "$score" -ge "$PROMOTE_THRESHOLD_CUSTOM" ]]; then
				target="custom/"
			fi
			printf "  %-30s %-8s score:%-3d -> %-10s (from %s)\n" "$name" "($atype)" "$score" "$target" "$mid"
			if [[ -n "$desc" && "$desc" != "(no description)" ]]; then
				echo "    $desc"
			fi
		done <<<"$candidates"
	else
		echo "  (no candidates above threshold)"
	fi
	echo ""

	return 0
}

#######################################
# Suggest promotions for a specific mission
# $1: mission directory
#######################################
cmd_suggest() {
	local mission_dir="$1"

	if [[ -z "$mission_dir" ]]; then
		log_error "Mission directory required: mission-skill-learner.sh suggest <mission-dir>"
		return 1
	fi

	# Run scan first to ensure data is fresh
	cmd_scan "$mission_dir" 2>/dev/null || true

	local mission_id
	mission_id=$(basename "$mission_dir")

	echo ""
	echo -e "${CYAN:-}=== Promotion Suggestions for $mission_id ===${NC:-}"
	echo ""

	ensure_learnings_table || return 1

	local suggestions
	suggestions=$(sqlite3 -separator '|' "$MEMORY_DB" "
		SELECT artifact_name, artifact_type, artifact_path, reuse_score, description
		FROM mission_learnings
		WHERE mission_id = '$(echo "$mission_id" | sed "s/'/''/g")'
		AND promoted_to IS NULL
		ORDER BY reuse_score DESC;
	" 2>/dev/null || echo "")

	if [[ -z "$suggestions" ]]; then
		echo "  No artifacts found for this mission."
		return 0
	fi

	local idx=0
	while IFS='|' read -r name atype apath score desc; do
		idx=$((idx + 1))
		local recommendation="skip"
		local target=""

		if [[ "$score" -ge "$PROMOTE_THRESHOLD_SHARED" ]]; then
			recommendation="PROMOTE to shared/ (submit PR)"
			target="shared"
		elif [[ "$score" -ge "$PROMOTE_THRESHOLD_CUSTOM" ]]; then
			recommendation="PROMOTE to custom/"
			target="custom"
		elif [[ "$score" -ge "$PROMOTE_THRESHOLD_DRAFT" ]]; then
			recommendation="PROMOTE to draft/"
			target="draft"
		else
			recommendation="Keep in mission (score too low)"
		fi

		local score_color="${RED:-}"
		if [[ "$score" -ge "$PROMOTE_THRESHOLD_SHARED" ]]; then
			score_color="${GREEN:-}"
		elif [[ "$score" -ge "$PROMOTE_THRESHOLD_CUSTOM" ]]; then
			score_color="${CYAN:-}"
		elif [[ "$score" -ge "$PROMOTE_THRESHOLD_DRAFT" ]]; then
			score_color="${YELLOW:-}"
		fi

		echo -e "  ${idx}. ${name} (${atype}) — score: ${score_color}${score}${NC:-}"
		echo "     ${desc}"
		echo "     Recommendation: ${recommendation}"
		if [[ -n "$target" && "$target" != "shared" ]]; then
			echo "     Run: mission-skill-learner.sh promote \"${apath}\" ${target}"
		fi
		echo ""
	done <<<"$suggestions"

	return 0
}

#######################################
# Show learning statistics
#######################################
cmd_stats() {
	echo ""
	echo -e "${CYAN:-}=== Mission Skill Learning Statistics ===${NC:-}"
	echo ""

	ensure_learnings_table || return 1

	# Total learnings
	local total
	total=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM mission_learnings;" 2>/dev/null || echo "0")
	echo "  Total artifacts tracked: $total"

	if [[ "$total" -eq 0 ]]; then
		echo ""
		echo "  No mission artifacts tracked yet."
		echo "  Run: mission-skill-learner.sh scan <mission-dir>"
		echo ""
		return 0
	fi

	# By type
	echo ""
	echo "  By type:"
	sqlite3 -separator '|' "$MEMORY_DB" "
		SELECT artifact_type, COUNT(*), ROUND(AVG(reuse_score), 1)
		FROM mission_learnings
		GROUP BY artifact_type
		ORDER BY COUNT(*) DESC;
	" 2>/dev/null | while IFS='|' read -r atype count avg_score; do
		printf "    %-10s %3d artifacts  avg score: %s\n" "$atype" "$count" "$avg_score"
	done

	# Promotion stats
	echo ""
	echo "  Promotions:"
	local promoted
	promoted=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM mission_learnings WHERE promoted_to IS NOT NULL;" 2>/dev/null || echo "0")
	local pending
	pending=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM mission_learnings WHERE promoted_to IS NULL AND reuse_score >= $PROMOTE_THRESHOLD_DRAFT;" 2>/dev/null || echo "0")
	echo "    Promoted: $promoted"
	echo "    Pending (score >= $PROMOTE_THRESHOLD_DRAFT): $pending"

	if [[ "$promoted" -gt 0 ]]; then
		echo ""
		echo "  Promoted to:"
		sqlite3 -separator '|' "$MEMORY_DB" "
			SELECT promoted_to, COUNT(*)
			FROM mission_learnings
			WHERE promoted_to IS NOT NULL
			GROUP BY promoted_to;
		" 2>/dev/null | while IFS='|' read -r target count; do
			printf "    %-10s %d\n" "$target" "$count"
		done
	fi

	# Missions scanned
	echo ""
	echo "  Missions scanned:"
	sqlite3 -separator '|' "$MEMORY_DB" "
		SELECT mission_id, COUNT(*), MAX(reuse_score), last_seen
		FROM mission_learnings
		GROUP BY mission_id
		ORDER BY last_seen DESC
		LIMIT 10;
	" 2>/dev/null | while IFS='|' read -r mid count max_score last; do
		printf "    %-25s %3d artifacts  best: %-3d  last: %s\n" "$mid" "$count" "$max_score" "$last"
	done

	# Memory patterns
	echo ""
	echo "  Mission patterns in memory:"
	local pattern_count
	pattern_count=$(sqlite3 "$MEMORY_DB" "
		SELECT COUNT(*) FROM learnings
		WHERE type IN ('$MEMORY_TYPE_MISSION_PATTERN', '$MEMORY_TYPE_MISSION_AGENT', '$MEMORY_TYPE_MISSION_SCRIPT');
	" 2>/dev/null || echo "0")
	echo "    Total: $pattern_count"

	echo ""
	return 0
}

#######################################
# Show help
#######################################
cmd_help() {
	echo "mission-skill-learner.sh — Auto-capture reusable patterns from missions"
	echo ""
	echo "Usage:"
	echo "  mission-skill-learner.sh scan <mission-dir>          Scan a mission for reusable artifacts"
	echo "  mission-skill-learner.sh scan-all [--repo <path>]    Scan all missions"
	echo "  mission-skill-learner.sh promote <path> [draft|custom]  Promote artifact to agent tier"
	echo "  mission-skill-learner.sh patterns [--mission <id>]   Show recurring patterns"
	echo "  mission-skill-learner.sh suggest <mission-dir>       Suggest promotions"
	echo "  mission-skill-learner.sh stats                       Show statistics"
	echo "  mission-skill-learner.sh help                        Show this help"
	echo ""
	echo "Score thresholds:"
	echo "  >= $PROMOTE_THRESHOLD_DRAFT   Suggest promotion to draft/"
	echo "  >= $PROMOTE_THRESHOLD_CUSTOM   Suggest promotion to custom/"
	echo "  >= $PROMOTE_THRESHOLD_SHARED   Suggest promotion to shared/ (PR required)"
	echo ""
	echo "Scoring factors (0-100):"
	echo "  Generality (not project-specific):     +30"
	echo "  Documentation quality:                 +20"
	echo "  Size (appropriate for type):           +15"
	echo "  Standard format (aidevops conventions): +15"
	echo "  Multi-feature usage within mission:    +20"
	echo ""
	echo "Integration:"
	echo "  Called by mission orchestrator at Phase 5 (completion)"
	echo "  Called by pulse supervisor when missions complete"
	echo "  Stores patterns in memory.db via memory-helper.sh"
	echo ""
	return 0
}

#######################################
# Main dispatch
#######################################
main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	scan)
		cmd_scan "$@"
		;;
	scan-all)
		cmd_scan_all "$@"
		;;
	promote)
		cmd_promote "$@"
		;;
	patterns)
		cmd_patterns "$@"
		;;
	suggest)
		cmd_suggest "$@"
		;;
	stats)
		cmd_stats
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		log_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
