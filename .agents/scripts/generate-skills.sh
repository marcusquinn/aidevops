#!/usr/bin/env bash
# shellcheck disable=SC2329
# =============================================================================
# Generate Agent Skills SKILL.md Files
# =============================================================================
# Creates SKILL.md index files for Agent Skills compatibility while maintaining
# the aidevops pattern of {name}.md + {name}/ folder structure.
#
# This script generates lightweight SKILL.md stubs that reference the actual
# content in existing .md files, enabling cross-tool compatibility with:
# - Any tool supporting the Agent Skills standard (agentskills.io)
#
# Pattern:
#   wordpress.md + wordpress/ → wordpress/SKILL.md (generated)
#   wordpress/wp-dev.md → wordpress/wp-dev/SKILL.md (generated)
#
# Usage:
#   ./generate-skills.sh [--dry-run] [--clean]
#
# Options:
#   --dry-run  Show what would be generated without writing files
#   --clean    Remove all generated SKILL.md files
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Configuration
AGENTS_DIR="${AIDEVOPS_AGENTS_DIR:-$HOME/.aidevops/agents}"
DRY_RUN=false
CLEAN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
	case $1 in
	--dry-run)
		DRY_RUN=true
		shift
		;;
	--clean)
		CLEAN=true
		shift
		;;
	*)
		echo -e "${RED}Unknown option: $1${NC}"
		exit 1
		;;
	esac
done

# =============================================================================
# Helper Functions
# =============================================================================

log_info() {
	echo -e "${BLUE}$1${NC}"
	return 0
}

log_success() {
	echo -e "${GREEN}✓${NC} $1"
	return 0
}

log_warning() {
	echo -e "${YELLOW}⚠${NC} $1"
	return 0
}

log_error() {
	echo -e "${RED}✗${NC} $1"
	return 0
}

# Extract frontmatter field from markdown file
extract_frontmatter_field() {
	local file="$1"
	local field="$2"

	if [[ ! -f "$file" ]]; then
		return 1
	fi

	# Extract value between --- markers
	awk -v field="$field" '
        /^---$/ { in_frontmatter = !in_frontmatter; next }
        in_frontmatter && $0 ~ "^" field ":" {
            sub("^" field ": *", "")
            gsub(/^["'"'"']|["'"'"']$/, "")  # Remove quotes
            print
            exit
        }
    ' "$file"
	return 0
}

# Extract description from file - tries frontmatter first, then first heading
extract_description() {
	local file="$1"
	local desc

	# Try frontmatter first
	desc=$(extract_frontmatter_field "$file" "description")
	if [[ -n "$desc" ]]; then
		echo "$desc"
		return
	fi

	# Try first heading (# Title - Description pattern or just # Title)
	local heading
	heading=$(grep -m1 "^# " "$file" 2>/dev/null | sed 's/^# //')
	if [[ -n "$heading" ]]; then
		# If heading has " - ", take the part after
		if [[ "$heading" == *" - "* ]]; then
			echo "${heading#* - }"
		else
			echo "$heading"
		fi
		return
	fi

	# Fallback to filename
	echo "$(basename "$file" .md) skill"
}

# Convert name to valid skill name (lowercase, hyphens only)
to_skill_name() {
	local name="$1"
	echo "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-\|-$//g'
	return 0
}

# Capitalize first letter (portable)
capitalize() {
	local str="$1"
	local first
	local rest
	first=$(echo "$str" | cut -c1 | tr '[:lower:]' '[:upper:]')
	rest=$(echo "$str" | cut -c2-)
	echo "${first}${rest}"
	return 0
}

# Generate SKILL.md content for a folder with parent .md (pure pointer)
generate_folder_skill() {
	local folder_path="$1"
	local parent_md="$2"
	local folder_name
	folder_name=$(basename "$folder_path")
	local skill_name
	skill_name=$(to_skill_name "$folder_name")

	# Extract description from parent .md
	local description
	description=$(extract_description "$parent_md")

	# Generate pure pointer SKILL.md — no inlined subskill lists
	local title
	title=$(capitalize "$folder_name")

	echo "---"
	echo "name: ${skill_name}"
	echo "description: ${description}"
	echo "---"
	echo ""
	echo "# ${title}"
	echo ""
	echo "See [${folder_name}.md](../${folder_name}.md) for full instructions."
	return 0
}

# Generate SKILL.md content for a leaf .md file
generate_leaf_skill() {
	local md_file="$1"
	local filename
	filename=$(basename "$md_file" .md)
	local skill_name
	skill_name=$(to_skill_name "$filename")

	# Extract description
	local description
	description=$(extract_description "$md_file")

	# Get relative path to the .md file from the new folder
	local relative_path="../${filename}.md"

	local title
	title=$(capitalize "$filename")

	echo "---"
	echo "name: ${skill_name}"
	echo "description: ${description}"
	echo "---"
	echo ""
	echo "# ${title}"
	echo ""
	echo "See [${filename}.md](${relative_path}) for full instructions."
	return 0
}

# =============================================================================
# Clean Mode
# =============================================================================

if [[ "$CLEAN" == true ]]; then
	log_info "Cleaning generated SKILL.md files..."

	count=0
	while IFS= read -r skill_file; do
		if [[ "$DRY_RUN" == true ]]; then
			log_warning "Would remove: $skill_file"
		else
			rm -f "$skill_file"
			log_success "Removed: $skill_file"
		fi
		((count++)) || true
	done < <(find "$AGENTS_DIR" -name "SKILL.md" -type f 2>/dev/null)

	if [[ $count -eq 0 ]]; then
		log_info "No SKILL.md files found to clean"
	else
		log_info "Cleaned $count SKILL.md files"
	fi
	exit 0
fi

# =============================================================================
# Generate Mode
# =============================================================================

log_info "Generating Agent Skills SKILL.md files..."
log_info "Source: $AGENTS_DIR"

if [[ "$DRY_RUN" == true ]]; then
	log_warning "DRY RUN - no files will be written"
fi

generated=0
skipped=0

# Pattern 1: Folders with matching parent .md files
# e.g., wordpress.md + wordpress/ → wordpress/SKILL.md
log_info ""
log_info "Pattern 1: Folders with parent .md files"

while IFS= read -r folder; do
	folder_name=$(basename "$folder")
	parent_md="$AGENTS_DIR/${folder_name}.md"
	skill_file="$folder/SKILL.md"

	# Skip special folders
	if [[ "$folder_name" == "scripts" || "$folder_name" == "memory" || "$folder_name" == "templates" ]]; then
		continue
	fi

	if [[ -f "$parent_md" ]]; then
		if [[ "$DRY_RUN" == true ]]; then
			log_success "Would generate: $skill_file (from $parent_md)"
		else
			mkdir -p "$folder"
			generate_folder_skill "$folder" "$parent_md" >"$skill_file"
			log_success "Generated: $skill_file"
		fi
		((generated++)) || true
	fi
done < <(find "$AGENTS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

# Pattern 2: Nested folders without parent .md but with children
# e.g., tools/browser/ with playwright.md, etc.
log_info ""
log_info "Pattern 2: Nested folders with child .md files"

while IFS= read -r folder; do
	folder_name=$(basename "$folder")
	skill_file="$folder/SKILL.md"

	# Skip if already handled or special
	if [[ -f "$skill_file" ]]; then
		continue
	fi

	# Check if folder has .md files
	md_count=$(find "$folder" -maxdepth 1 -name "*.md" -type f 2>/dev/null | wc -l)
	if [[ $md_count -gt 0 ]]; then
		local_name=$(to_skill_name "$folder_name")

		if [[ "$DRY_RUN" == true ]]; then
			log_success "Would generate: $skill_file (folder index)"
		else
			# Pure pointer — no inlined subskill lists
			title=$(capitalize "$folder_name")
			{
				echo "---"
				echo "name: ${local_name}"
				echo "description: ${title} tools and utilities"
				echo "---"
				echo ""
				echo "# ${title}"
				echo ""
				echo "Browse the .md files in this directory for full instructions."
			} >"$skill_file"
			log_success "Generated: $skill_file"
		fi
		((generated++)) || true
	fi
done < <(find "$AGENTS_DIR" -mindepth 2 -type d 2>/dev/null | sort)

# Pattern 3: Standalone .md files in nested dirs without matching folders
# e.g., services/hosting/local-hosting.md with no local-hosting/ folder
# These were previously missed, causing discovery gaps.
log_info ""
log_info "Pattern 3: Standalone .md files without matching folders"

while IFS= read -r md_file; do
	filename=$(basename "$md_file" .md)
	parent_dir=$(dirname "$md_file")
	target_dir="${parent_dir}/${filename}"
	skill_file="${target_dir}/SKILL.md"

	# Skip if a matching folder already exists (handled by Pattern 1 or 2)
	if [[ -d "$target_dir" ]]; then
		continue
	fi

	# Skip SKILL.md files, AGENTS.md, README.md, and other non-skill files
	if [[ "$filename" == "SKILL" || "$filename" == "AGENTS" || "$filename" == "README" ]]; then
		continue
	fi

	# Skip files in special top-level directories
	rel_path="${md_file#"$AGENTS_DIR"/}"
	top_dir="${rel_path%%/*}"
	if [[ "$top_dir" == "scripts" || "$top_dir" == "memory" || "$top_dir" == "templates" || "$top_dir" == "configs" || "$top_dir" == "prompts" || "$top_dir" == "plugins" ]]; then
		continue
	fi

	# Skip top-level .md files (Pattern 1 handles those via folders)
	if [[ "$parent_dir" == "$AGENTS_DIR" ]]; then
		continue
	fi

	if [[ "$DRY_RUN" == true ]]; then
		log_success "Would generate: $skill_file (standalone)"
	else
		mkdir -p "$target_dir"
		generate_leaf_skill "$md_file" >"$skill_file"
		log_success "Generated: $skill_file"
	fi
	((generated++)) || true
done < <(find "$AGENTS_DIR" -mindepth 2 -name "*.md" -not -name "SKILL.md" -not -name "AGENTS.md" -not -name "README.md" -type f 2>/dev/null | sort)

# =============================================================================
# Summary
# =============================================================================

log_info ""
log_info "Generation complete:"
log_info "  Generated: $generated SKILL.md files"
log_info "  Skipped: $skipped (already exist or excluded)"

if [[ "$DRY_RUN" == true ]]; then
	log_warning ""
	log_warning "This was a dry run. Run without --dry-run to generate files."
fi

exit 0
