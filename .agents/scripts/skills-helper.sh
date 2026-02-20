#!/usr/bin/env bash
# =============================================================================
# Skills Discovery & Management Helper
# =============================================================================
# Interactive discovery, description, and management of installed skills,
# native subagents, and importable community skills.
#
# Usage:
#   skills-helper.sh search <query>       # Search installed skills by keyword
#   skills-helper.sh browse [category]    # Browse skills by category
#   skills-helper.sh describe <name>      # Show detailed description of a skill
#   skills-helper.sh info <name>          # Show metadata (path, source, model tier)
#   skills-helper.sh list [--imported|--native|--all]  # List skills
#   skills-helper.sh categories           # List all skill categories
#   skills-helper.sh recommend <task>     # Suggest skills for a task description
#   skills-helper.sh help                 # Show this help
#
# Examples:
#   skills-helper.sh search "browser automation"
#   skills-helper.sh browse tools/browser
#   skills-helper.sh describe playwright
#   skills-helper.sh info seo-audit-skill
#   skills-helper.sh recommend "scrape a website and extract product data"
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Configuration
AGENTS_DIR="${AIDEVOPS_AGENTS_DIR:-$HOME/.aidevops/agents}"
SUBAGENT_INDEX="${AGENTS_DIR}/subagent-index.toon"
SKILL_SOURCES="${AGENTS_DIR}/configs/skill-sources.json"

# =============================================================================
# Helper Functions
# =============================================================================

log_info() {
	echo -e "${BLUE}[skills]${NC} $1"
	return 0
}

log_success() {
	echo -e "${GREEN}[OK]${NC} $1"
	return 0
}

log_warning() {
	echo -e "${YELLOW}[WARN]${NC} $1"
	return 0
}

log_error() {
	echo -e "${RED}[ERROR]${NC} $1"
	return 0
}

show_help() {
	cat <<'EOF'
Skills Discovery & Management - Find, explore, and manage AI agent skills

USAGE:
    skills-helper.sh <command> [options]

COMMANDS:
    search <query>          Search installed skills by keyword
    browse [category]       Browse skills by category (interactive)
    describe <name>         Show detailed description of a skill/subagent
    info <name>             Show metadata (path, source, model tier, format)
    list [filter]           List skills (--imported, --native, --all)
    categories              List all skill categories with counts
    recommend <task>        Suggest relevant skills for a task description
    help                    Show this help message

OPTIONS:
    --json                  Output in JSON format (for scripting)
    --quiet                 Suppress decorative output

EXAMPLES:
    # Find skills related to browser automation
    skills-helper.sh search "browser automation"

    # Browse all tools
    skills-helper.sh browse tools

    # Get details about a specific skill
    skills-helper.sh describe playwright

    # See metadata for an imported skill
    skills-helper.sh info seo-audit-skill

    # Get skill recommendations for a task
    skills-helper.sh recommend "deploy a Next.js app to Vercel"

    # List only imported community skills
    skills-helper.sh list --imported

    # List all categories
    skills-helper.sh categories
EOF
	return 0
}

# Extract description from a markdown file's YAML frontmatter
extract_description() {
	local file="$1"

	if [[ ! -f "$file" ]]; then
		echo ""
		return 0
	fi

	awk '
		/^---$/ { in_fm = !in_fm; next }
		in_fm && /^description:/ {
			sub(/^description: */, "")
			gsub(/^["'"'"']|["'"'"']$/, "")
			print
			exit
		}
	' "$file"
	return 0
}

# Extract model tier from frontmatter
extract_model_tier() {
	local file="$1"

	if [[ ! -f "$file" ]]; then
		echo ""
		return 0
	fi

	awk '
		/^---$/ { in_fm = !in_fm; next }
		in_fm && /^model:/ {
			sub(/^model: */, "")
			gsub(/^["'"'"']|["'"'"']$/, "")
			print
			exit
		}
	' "$file"
	return 0
}

# Get the first heading from a markdown file
extract_title() {
	local file="$1"

	if [[ ! -f "$file" ]]; then
		echo ""
		return 0
	fi

	grep -m1 "^# " "$file" 2>/dev/null | sed 's/^# //' || echo ""
	return 0
}

# Derive a human-friendly category from a file path relative to AGENTS_DIR
path_to_category() {
	local rel_path="$1"
	local dir
	dir=$(dirname "$rel_path")

	# Strip leading ./ if present
	dir="${dir#./}"

	# Return the directory as category
	if [[ "$dir" == "." || -z "$dir" ]]; then
		echo "root"
	else
		echo "$dir"
	fi
	return 0
}

# =============================================================================
# Commands
# =============================================================================

cmd_search() {
	local query="$1"
	local json_output="${2:-false}"

	if [[ -z "$query" ]]; then
		log_error "Search query required"
		echo "Usage: skills-helper.sh search <query>"
		return 1
	fi

	# Convert query to lowercase for case-insensitive matching
	local query_lower
	query_lower=$(echo "$query" | tr '[:upper:]' '[:lower:]')

	local found=0
	local results=()

	# Search through all .md files in AGENTS_DIR (excluding scripts, templates, memory)
	while IFS= read -r md_file; do
		local rel_path="${md_file#"$AGENTS_DIR/"}"
		local filename
		filename=$(basename "$md_file" .md)
		local category
		category=$(path_to_category "$rel_path")

		# Skip non-skill files
		case "$rel_path" in
		scripts/* | templates/* | memory/* | configs/* | custom/* | draft/* | AGENTS.md | VERSION)
			continue
			;;
		esac

		# Search in filename, description, and first heading
		local desc
		desc=$(extract_description "$md_file")
		local title
		title=$(extract_title "$md_file")

		local match_text="${filename} ${desc} ${title} ${category}"
		local match_lower
		match_lower=$(echo "$match_text" | tr '[:upper:]' '[:lower:]')

		# Check if any query word matches
		local matched=false
		local word
		for word in $query_lower; do
			if [[ "$match_lower" == *"$word"* ]]; then
				matched=true
				break
			fi
		done

		if [[ "$matched" == true ]]; then
			((found++)) || true

			local is_imported="false"
			if [[ "$filename" == *-skill ]]; then
				is_imported="true"
			fi

			if [[ "$json_output" == true ]]; then
				results+=("{\"name\":\"$filename\",\"category\":\"$category\",\"description\":\"$(echo "$desc" | sed 's/"/\\"/g')\",\"imported\":$is_imported,\"path\":\"$rel_path\"}")
			else
				local type_label="native"
				if [[ "$is_imported" == "true" ]]; then
					type_label="imported"
				fi
				echo -e "  ${BOLD}${filename}${NC} ${CYAN}[$category]${NC} ${YELLOW}($type_label)${NC}"
				if [[ -n "$desc" ]]; then
					echo "    $desc"
				fi
			fi
		fi
	done < <(find "$AGENTS_DIR" -name "*.md" -type f 2>/dev/null | sort)

	if [[ "$json_output" == true ]]; then
		local results_json
		results_json=$(printf '%s,' "${results[@]}" 2>/dev/null || echo "")
		results_json="${results_json%,}"
		echo "{\"query\":\"$(echo "$query" | sed 's/"/\\"/g')\",\"count\":$found,\"results\":[$results_json]}"
	else
		echo ""
		if [[ $found -eq 0 ]]; then
			log_warning "No skills found matching '$query'"
			echo ""
			echo "Try:"
			echo "  skills-helper.sh browse          # Browse all categories"
			echo "  skills-helper.sh categories       # List categories"
		else
			log_info "Found $found skill(s) matching '$query'"
		fi
	fi

	return 0
}

cmd_browse() {
	local category="${1:-}"
	local json_output="${2:-false}"

	if [[ -z "$category" ]]; then
		# Show top-level categories
		echo ""
		echo -e "${BOLD}Skill Categories${NC}"
		echo "================"
		echo ""

		local -A cat_counts
		while IFS= read -r md_file; do
			local rel_path="${md_file#"$AGENTS_DIR/"}"

			# Skip non-skill files
			case "$rel_path" in
			scripts/* | templates/* | memory/* | configs/* | custom/* | draft/* | AGENTS.md | VERSION | subagent-index.toon)
				continue
				;;
			esac

			local cat
			cat=$(path_to_category "$rel_path")
			# Get top-level category
			local top_cat="${cat%%/*}"
			if [[ -n "$top_cat" && "$top_cat" != "root" ]]; then
				cat_counts["$top_cat"]=$((${cat_counts["$top_cat"]:-0} + 1))
			fi
		done < <(find "$AGENTS_DIR" -name "*.md" -type f 2>/dev/null)

		# Sort and display
		local cat_name
		for cat_name in $(echo "${!cat_counts[@]}" | tr ' ' '\n' | sort); do
			printf "  %-25s %s skill(s)\n" "$cat_name" "${cat_counts[$cat_name]}"
		done

		echo ""
		echo "Usage: skills-helper.sh browse <category>"
		echo "  e.g., skills-helper.sh browse tools"
		echo "        skills-helper.sh browse services"
		echo "        skills-helper.sh browse tools/browser"
		return 0
	fi

	# Browse specific category
	echo ""
	echo -e "${BOLD}Skills in: $category${NC}"
	echo "$(printf '=%.0s' $(seq 1 $((${#category} + 12))))"
	echo ""

	local found=0
	while IFS= read -r md_file; do
		local rel_path="${md_file#"$AGENTS_DIR/"}"

		# Skip non-skill files
		case "$rel_path" in
		scripts/* | templates/* | memory/* | configs/* | custom/* | draft/* | AGENTS.md | VERSION | subagent-index.toon)
			continue
			;;
		esac

		local cat
		cat=$(path_to_category "$rel_path")

		# Match category (prefix match)
		if [[ "$cat" == "$category" || "$cat" == "$category/"* ]]; then
			local filename
			filename=$(basename "$md_file" .md)
			local desc
			desc=$(extract_description "$md_file")

			local type_label="native"
			if [[ "$filename" == *-skill ]]; then
				type_label="imported"
			fi

			echo -e "  ${BOLD}${filename}${NC} ${YELLOW}($type_label)${NC}"
			if [[ -n "$desc" ]]; then
				echo "    $desc"
			fi
			((found++)) || true
		fi
	done < <(find "$AGENTS_DIR" -name "*.md" -type f 2>/dev/null | sort)

	echo ""
	if [[ $found -eq 0 ]]; then
		log_warning "No skills found in category '$category'"
		echo ""
		echo "Available categories:"
		cmd_categories "false"
	else
		log_info "Found $found skill(s) in '$category'"
	fi

	return 0
}

cmd_describe() {
	local name="$1"

	if [[ -z "$name" ]]; then
		log_error "Skill name required"
		echo "Usage: skills-helper.sh describe <name>"
		return 1
	fi

	# Find the skill file
	local skill_file=""
	local candidates=()

	# Search for exact match first, then partial
	while IFS= read -r md_file; do
		local filename
		filename=$(basename "$md_file" .md)
		local rel_path="${md_file#"$AGENTS_DIR/"}"

		# Skip non-skill files
		case "$rel_path" in
		scripts/* | templates/* | memory/* | configs/* | AGENTS.md | VERSION | subagent-index.toon)
			continue
			;;
		esac

		if [[ "$filename" == "$name" ]]; then
			skill_file="$md_file"
			break
		elif [[ "$filename" == *"$name"* ]]; then
			candidates+=("$md_file")
		fi
	done < <(find "$AGENTS_DIR" -name "*.md" -type f 2>/dev/null | sort)

	# Use first candidate if no exact match
	if [[ -z "$skill_file" && ${#candidates[@]} -gt 0 ]]; then
		skill_file="${candidates[0]}"
	fi

	if [[ -z "$skill_file" || ! -f "$skill_file" ]]; then
		log_error "Skill not found: $name"
		echo ""
		echo "Try: skills-helper.sh search '$name'"
		return 1
	fi

	local filename
	filename=$(basename "$skill_file" .md)
	local rel_path="${skill_file#"$AGENTS_DIR/"}"
	local category
	category=$(path_to_category "$rel_path")
	local desc
	desc=$(extract_description "$skill_file")
	local title
	title=$(extract_title "$skill_file")
	local model_tier
	model_tier=$(extract_model_tier "$skill_file")

	echo ""
	echo -e "${BOLD}${title:-$filename}${NC}"
	echo "$(printf '=%.0s' $(seq 1 ${#filename}))"
	echo ""

	if [[ -n "$desc" ]]; then
		echo -e "  ${CYAN}Description:${NC} $desc"
	fi
	echo -e "  ${CYAN}Category:${NC}    $category"
	echo -e "  ${CYAN}Path:${NC}        $rel_path"

	if [[ -n "$model_tier" ]]; then
		echo -e "  ${CYAN}Model tier:${NC}  $model_tier"
	fi

	local is_imported="false"
	if [[ "$filename" == *-skill ]]; then
		is_imported="true"
		echo -e "  ${CYAN}Type:${NC}        imported (community skill)"

		# Show upstream info if available
		if [[ -f "$SKILL_SOURCES" ]] && command -v jq &>/dev/null; then
			local base_name="${filename%-skill}"
			local upstream
			upstream=$(jq -r --arg n "$base_name" '.skills[] | select(.name == $n) | .upstream_url // empty' "$SKILL_SOURCES" 2>/dev/null || echo "")
			if [[ -n "$upstream" ]]; then
				echo -e "  ${CYAN}Upstream:${NC}    $upstream"
			fi
			local imported_at
			imported_at=$(jq -r --arg n "$base_name" '.skills[] | select(.name == $n) | .imported_at // empty' "$SKILL_SOURCES" 2>/dev/null || echo "")
			if [[ -n "$imported_at" ]]; then
				echo -e "  ${CYAN}Imported:${NC}    $imported_at"
			fi
		fi
	else
		echo -e "  ${CYAN}Type:${NC}        native (aidevops built-in)"
	fi

	# Check for companion directory (subagents)
	local companion_dir="${skill_file%.md}"
	if [[ -d "$companion_dir" ]]; then
		local sub_count
		sub_count=$(find "$companion_dir" -maxdepth 1 -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
		if [[ "$sub_count" -gt 0 ]]; then
			echo ""
			echo -e "  ${CYAN}Subagents ($sub_count):${NC}"
			while IFS= read -r sub_file; do
				local sub_name
				sub_name=$(basename "$sub_file" .md)
				local sub_desc
				sub_desc=$(extract_description "$sub_file")
				if [[ -n "$sub_desc" ]]; then
					echo "    - $sub_name: $sub_desc"
				else
					echo "    - $sub_name"
				fi
			done < <(find "$companion_dir" -maxdepth 1 -name "*.md" -type f 2>/dev/null | sort)
		fi
	fi

	# Show content preview (first non-frontmatter paragraph)
	echo ""
	echo -e "  ${CYAN}Preview:${NC}"
	awk '
		/^---$/ { in_fm = !in_fm; next }
		in_fm { next }
		/^#/ { next }
		/^$/ { if (found) exit; next }
		{ found = 1; print "    " $0 }
	' "$skill_file" | head -5

	echo ""
	echo "Full content: $skill_file"

	return 0
}

cmd_info() {
	local name="$1"
	local json_output="${2:-false}"

	if [[ -z "$name" ]]; then
		log_error "Skill name required"
		echo "Usage: skills-helper.sh info <name>"
		return 1
	fi

	# Find the skill file (same logic as describe)
	local skill_file=""
	while IFS= read -r md_file; do
		local filename
		filename=$(basename "$md_file" .md)
		local rel_path="${md_file#"$AGENTS_DIR/"}"

		case "$rel_path" in
		scripts/* | templates/* | memory/* | configs/* | AGENTS.md | VERSION | subagent-index.toon)
			continue
			;;
		esac

		if [[ "$filename" == "$name" ]]; then
			skill_file="$md_file"
			break
		fi
	done < <(find "$AGENTS_DIR" -name "*.md" -type f 2>/dev/null | sort)

	if [[ -z "$skill_file" || ! -f "$skill_file" ]]; then
		log_error "Skill not found: $name"
		return 1
	fi

	local filename
	filename=$(basename "$skill_file" .md)
	local rel_path="${skill_file#"$AGENTS_DIR/"}"
	local category
	category=$(path_to_category "$rel_path")
	local desc
	desc=$(extract_description "$skill_file")
	local model_tier
	model_tier=$(extract_model_tier "$skill_file")
	local file_size
	file_size=$(wc -c <"$skill_file" | tr -d ' ')
	local line_count
	line_count=$(wc -l <"$skill_file" | tr -d ' ')

	local is_imported="false"
	local upstream_url=""
	local imported_at=""
	local format_detected=""

	if [[ "$filename" == *-skill ]]; then
		is_imported="true"
		if [[ -f "$SKILL_SOURCES" ]] && command -v jq &>/dev/null; then
			local base_name="${filename%-skill}"
			upstream_url=$(jq -r --arg n "$base_name" '.skills[] | select(.name == $n) | .upstream_url // empty' "$SKILL_SOURCES" 2>/dev/null || echo "")
			imported_at=$(jq -r --arg n "$base_name" '.skills[] | select(.name == $n) | .imported_at // empty' "$SKILL_SOURCES" 2>/dev/null || echo "")
			format_detected=$(jq -r --arg n "$base_name" '.skills[] | select(.name == $n) | .format_detected // empty' "$SKILL_SOURCES" 2>/dev/null || echo "")
		fi
	fi

	if [[ "$json_output" == true ]]; then
		local json_desc
		json_desc=$(echo "$desc" | sed 's/"/\\"/g')
		echo "{"
		echo "  \"name\": \"$filename\","
		echo "  \"category\": \"$category\","
		echo "  \"description\": \"$json_desc\","
		echo "  \"path\": \"$rel_path\","
		echo "  \"full_path\": \"$skill_file\","
		echo "  \"model_tier\": \"${model_tier:-unspecified}\","
		echo "  \"imported\": $is_imported,"
		echo "  \"upstream_url\": \"$upstream_url\","
		echo "  \"imported_at\": \"$imported_at\","
		echo "  \"format\": \"$format_detected\","
		echo "  \"size_bytes\": $file_size,"
		echo "  \"lines\": $line_count"
		echo "}"
	else
		echo ""
		printf "  %-15s %s\n" "Name:" "$filename"
		printf "  %-15s %s\n" "Category:" "$category"
		printf "  %-15s %s\n" "Description:" "${desc:-<none>}"
		printf "  %-15s %s\n" "Path:" "$rel_path"
		printf "  %-15s %s\n" "Full path:" "$skill_file"
		printf "  %-15s %s\n" "Model tier:" "${model_tier:-unspecified}"
		printf "  %-15s %s\n" "Type:" "$(if [[ "$is_imported" == "true" ]]; then echo "imported"; else echo "native"; fi)"
		printf "  %-15s %s\n" "Size:" "${file_size} bytes (${line_count} lines)"
		if [[ -n "$upstream_url" ]]; then
			printf "  %-15s %s\n" "Upstream:" "$upstream_url"
		fi
		if [[ -n "$imported_at" ]]; then
			printf "  %-15s %s\n" "Imported:" "$imported_at"
		fi
		if [[ -n "$format_detected" ]]; then
			printf "  %-15s %s\n" "Format:" "$format_detected"
		fi
		echo ""
	fi

	return 0
}

cmd_list() {
	local filter="${1:-all}"
	local json_output="${2:-false}"

	echo ""
	local header="Installed Skills"
	case "$filter" in
	--imported | imported)
		header="Imported Skills"
		filter="imported"
		;;
	--native | native)
		header="Native Skills"
		filter="native"
		;;
	*)
		filter="all"
		;;
	esac

	if [[ "$json_output" != true ]]; then
		echo -e "${BOLD}${header}${NC}"
		echo "$(printf '=%.0s' $(seq 1 ${#header}))"
		echo ""
	fi

	local count=0
	local results=()

	while IFS= read -r md_file; do
		local rel_path="${md_file#"$AGENTS_DIR/"}"
		local filename
		filename=$(basename "$md_file" .md)

		# Skip non-skill files
		case "$rel_path" in
		scripts/* | templates/* | memory/* | configs/* | custom/* | draft/* | AGENTS.md | VERSION | subagent-index.toon)
			continue
			;;
		esac

		local is_imported="false"
		if [[ "$filename" == *-skill ]]; then
			is_imported="true"
		fi

		# Apply filter
		if [[ "$filter" == "imported" && "$is_imported" != "true" ]]; then
			continue
		fi
		if [[ "$filter" == "native" && "$is_imported" == "true" ]]; then
			continue
		fi

		local category
		category=$(path_to_category "$rel_path")
		local desc
		desc=$(extract_description "$md_file")

		if [[ "$json_output" == true ]]; then
			results+=("{\"name\":\"$filename\",\"category\":\"$category\",\"description\":\"$(echo "$desc" | sed 's/"/\\"/g')\",\"imported\":$is_imported}")
		else
			local type_label="native"
			if [[ "$is_imported" == "true" ]]; then
				type_label="imported"
			fi
			printf "  %-35s %-25s %s\n" "$filename" "[$category]" "($type_label)"
		fi
		((count++)) || true
	done < <(find "$AGENTS_DIR" -name "*.md" -type f 2>/dev/null | sort)

	if [[ "$json_output" == true ]]; then
		local results_json
		results_json=$(printf '%s,' "${results[@]}" 2>/dev/null || echo "")
		results_json="${results_json%,}"
		echo "{\"filter\":\"$filter\",\"count\":$count,\"skills\":[$results_json]}"
	else
		echo ""
		log_info "Total: $count skill(s)"
	fi

	return 0
}

cmd_categories() {
	local json_output="${1:-false}"

	local -A cat_counts

	while IFS= read -r md_file; do
		local rel_path="${md_file#"$AGENTS_DIR/"}"

		# Skip non-skill files
		case "$rel_path" in
		scripts/* | templates/* | memory/* | configs/* | custom/* | draft/* | AGENTS.md | VERSION | subagent-index.toon)
			continue
			;;
		esac

		local cat
		cat=$(path_to_category "$rel_path")
		if [[ -n "$cat" ]]; then
			cat_counts["$cat"]=$((${cat_counts["$cat"]:-0} + 1))
		fi
	done < <(find "$AGENTS_DIR" -name "*.md" -type f 2>/dev/null)

	if [[ "$json_output" == true ]]; then
		local entries=()
		local cat_name
		for cat_name in $(echo "${!cat_counts[@]}" | tr ' ' '\n' | sort); do
			entries+=("{\"category\":\"$cat_name\",\"count\":${cat_counts[$cat_name]}}")
		done
		local entries_json
		entries_json=$(printf '%s,' "${entries[@]}" 2>/dev/null || echo "")
		entries_json="${entries_json%,}"
		echo "{\"categories\":[$entries_json]}"
	else
		echo ""
		echo -e "${BOLD}Skill Categories${NC}"
		echo "================"
		echo ""
		printf "  %-40s %s\n" "CATEGORY" "COUNT"
		printf "  %-40s %s\n" "--------" "-----"

		local cat_name
		for cat_name in $(echo "${!cat_counts[@]}" | tr ' ' '\n' | sort); do
			printf "  %-40s %s\n" "$cat_name" "${cat_counts[$cat_name]}"
		done

		echo ""
		local total=0
		local c
		for c in "${cat_counts[@]}"; do
			total=$((total + c))
		done
		log_info "Total: $total skill(s) in ${#cat_counts[@]} categories"
	fi

	return 0
}

cmd_recommend() {
	local task_desc="$1"

	if [[ -z "$task_desc" ]]; then
		log_error "Task description required"
		echo "Usage: skills-helper.sh recommend <task description>"
		return 1
	fi

	echo ""
	echo -e "${BOLD}Skill Recommendations${NC}"
	echo "====================="
	echo ""
	echo -e "  ${CYAN}Task:${NC} $task_desc"
	echo ""

	# Extract keywords from the task description
	local task_lower
	task_lower=$(echo "$task_desc" | tr '[:upper:]' '[:lower:]')

	# Define keyword-to-category mappings for common tasks
	local -A keyword_map
	keyword_map["browser"]="tools/browser"
	keyword_map["scrape"]="tools/browser"
	keyword_map["crawl"]="tools/browser"
	keyword_map["playwright"]="tools/browser"
	keyword_map["seo"]="seo"
	keyword_map["search engine"]="seo"
	keyword_map["keyword"]="seo"
	keyword_map["ranking"]="seo"
	keyword_map["deploy"]="tools/deployment"
	keyword_map["vercel"]="tools/deployment"
	keyword_map["coolify"]="tools/deployment"
	keyword_map["docker"]="tools/containers"
	keyword_map["container"]="tools/containers"
	keyword_map["wordpress"]="tools/wordpress"
	keyword_map["wp"]="tools/wordpress"
	keyword_map["git"]="tools/git"
	keyword_map["github"]="tools/git"
	keyword_map["pr"]="tools/git"
	keyword_map["pull request"]="tools/git"
	keyword_map["email"]="services/email"
	keyword_map["video"]="tools/video"
	keyword_map["image"]="tools/vision"
	keyword_map["pdf"]="tools/pdf"
	keyword_map["database"]="services/database"
	keyword_map["postgres"]="services/database"
	keyword_map["security"]="tools/security"
	keyword_map["secret"]="tools/credentials"
	keyword_map["api key"]="tools/credentials"
	keyword_map["voice"]="tools/voice"
	keyword_map["speech"]="tools/voice"
	keyword_map["mobile"]="tools/mobile"
	keyword_map["ios"]="tools/mobile"
	keyword_map["accessibility"]="tools/accessibility"
	keyword_map["wcag"]="tools/accessibility"
	keyword_map["content"]="content"
	keyword_map["blog"]="content"
	keyword_map["article"]="content"
	keyword_map["youtube"]="content"
	keyword_map["code review"]="tools/code-review"
	keyword_map["lint"]="tools/code-review"
	keyword_map["quality"]="tools/code-review"
	keyword_map["hosting"]="services/hosting"
	keyword_map["cloudflare"]="services/hosting"
	keyword_map["dns"]="services/hosting"
	keyword_map["monitor"]="services/monitoring"
	keyword_map["sentry"]="services/monitoring"
	keyword_map["document"]="tools/document"
	keyword_map["extract"]="tools/document"
	keyword_map["ocr"]="tools/ocr"
	keyword_map["receipt"]="tools/accounts"

	local matched_categories=()
	local keyword
	for keyword in "${!keyword_map[@]}"; do
		if [[ "$task_lower" == *"$keyword"* ]]; then
			local cat="${keyword_map[$keyword]}"
			# Avoid duplicates
			local already=false
			local existing
			for existing in "${matched_categories[@]+"${matched_categories[@]}"}"; do
				if [[ "$existing" == "$cat" ]]; then
					already=true
					break
				fi
			done
			if [[ "$already" == false ]]; then
				matched_categories+=("$cat")
			fi
		fi
	done

	if [[ ${#matched_categories[@]} -eq 0 ]]; then
		# Fallback: do a general search with the task words
		log_info "No specific category match. Running general search..."
		echo ""
		cmd_search "$task_desc" "false"
		return 0
	fi

	echo -e "  ${CYAN}Matched categories:${NC} ${matched_categories[*]}"
	echo ""

	local total_found=0
	local cat
	for cat in "${matched_categories[@]}"; do
		echo -e "  ${BOLD}$cat:${NC}"

		local found_in_cat=0
		while IFS= read -r md_file; do
			local rel_path="${md_file#"$AGENTS_DIR/"}"
			local filename
			filename=$(basename "$md_file" .md)

			# Skip non-skill files
			case "$rel_path" in
			scripts/* | templates/* | memory/* | configs/* | custom/* | draft/* | AGENTS.md | VERSION | subagent-index.toon)
				continue
				;;
			esac

			local file_cat
			file_cat=$(path_to_category "$rel_path")

			if [[ "$file_cat" == "$cat" || "$file_cat" == "$cat/"* ]]; then
				local desc
				desc=$(extract_description "$md_file")
				echo -e "    ${GREEN}-${NC} $filename: ${desc:-<no description>}"
				((found_in_cat++)) || true
				((total_found++)) || true
			fi
		done < <(find "$AGENTS_DIR" -name "*.md" -type f 2>/dev/null | sort)

		if [[ $found_in_cat -eq 0 ]]; then
			echo "    (no skills in this category)"
		fi
		echo ""
	done

	echo -e "  ${CYAN}Tip:${NC} Use 'skills-helper.sh describe <name>' for details on any skill."
	echo ""

	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	local json_output=false

	# Extract global options
	local args=()
	local arg
	while [[ $# -gt 0 ]]; do
		arg="$1"
		case "$arg" in
		--json)
			json_output=true
			shift
			;;
		--quiet | -q)
			shift
			;;
		*)
			args+=("$arg")
			shift
			;;
		esac
	done

	case "$command" in
	search | s | find | f)
		cmd_search "${args[*]:-}" "$json_output"
		;;
	browse | b)
		cmd_browse "${args[0]:-}" "$json_output"
		;;
	describe | desc | d | show)
		cmd_describe "${args[0]:-}"
		;;
	info | i | meta)
		cmd_info "${args[0]:-}" "$json_output"
		;;
	list | ls | l)
		cmd_list "${args[0]:-all}" "$json_output"
		;;
	categories | cats | cat)
		cmd_categories "$json_output"
		;;
	recommend | rec | suggest)
		cmd_recommend "${args[*]:-}"
		;;
	help | --help | -h)
		show_help
		;;
	*)
		log_error "Unknown command: $command"
		echo ""
		show_help
		return 1
		;;
	esac
}

main "$@"
