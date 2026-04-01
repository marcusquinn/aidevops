#!/usr/bin/env bash

# AI DevOps Framework CLI
# Usage: aidevops <command> [options]
#
# Version: 3.5.569

set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Paths
INSTALL_DIR="$HOME/Git/aidevops"
AGENTS_DIR="$HOME/.aidevops/agents"
CONFIG_DIR="$HOME/.config/aidevops"
REPOS_FILE="$CONFIG_DIR/repos.json"
# shellcheck disable=SC2034  # Used in fresh install fallback
REPO_URL="https://github.com/marcusquinn/aidevops.git"
VERSION_FILE="$INSTALL_DIR/VERSION"

# Portable sed in-place edit (macOS BSD sed vs GNU sed)
sed_inplace() { if [[ "$(uname)" == "Darwin" ]]; then sed -i '' "$@"; else sed -i "$@"; fi; }

# Portable timeout (macOS has no coreutils timeout)
_timeout_cmd() {
	local secs="$1"
	shift
	if command -v timeout &>/dev/null; then
		timeout "$secs" "$@"
	elif command -v gtimeout &>/dev/null; then
		gtimeout "$secs" "$@"
	elif command -v perl &>/dev/null; then
		perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
	else
		echo "[WARN] No timeout command available - running without timeout" >&2
		"$@"
	fi
}

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[OK]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_header() { echo -e "${BOLD}${CYAN}$1${NC}"; }

# Get current version
get_version() {
	if [[ -f "$VERSION_FILE" ]]; then
		cat "$VERSION_FILE"
	else
		echo "unknown"
	fi
}

# Get remote version
get_remote_version() {
	# Use GitHub API (not cached) instead of raw.githubusercontent.com (cached 5 min)
	local version
	if command -v jq &>/dev/null; then
		version=$(curl -fsSL "https://api.github.com/repos/marcusquinn/aidevops/contents/VERSION" 2>/dev/null | jq -r '.content // empty' 2>/dev/null | base64 -d 2>/dev/null | tr -d '\n')
		if [[ -n "$version" ]]; then
			echo "$version"
			return 0
		fi
	fi
	# Fallback to raw (cached) if jq unavailable or API fails
	curl -fsSL "https://raw.githubusercontent.com/marcusquinn/aidevops/main/VERSION" 2>/dev/null || echo "unknown"
}

get_public_release_tag() {
	local repo="$1"
	local tag=""

	tag=$(_timeout_cmd 15 curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null |
		grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"v?[^"]+"' |
		head -1 |
		sed -E 's/.*"v?([^"]+)"/\1/' || true)

	printf '%s\n' "$tag"
	return 0
}

# Check if a command exists
check_cmd() {
	command -v "$1" >/dev/null 2>&1
}

# Check if a directory exists
check_dir() {
	[[ -d "$1" ]]
}

# Check if a file exists
check_file() {
	[[ -f "$1" ]]
}

# Ensure file ends with a trailing newline (prevents malformed appends)
ensure_trailing_newline() {
	local file="$1"
	local last
	last="$(
		tail -c 1 "$file"
		printf x
	)"
	[[ -s "$file" ]] && [[ "$last" != $'\n'x ]] && printf '\n' >>"$file"
}

# Initialize repos.json if it doesn't exist
init_repos_file() {
	if [[ ! -f "$REPOS_FILE" ]]; then
		mkdir -p "$CONFIG_DIR"
		echo '{"initialized_repos": [], "git_parent_dirs": ["~/Git"]}' >"$REPOS_FILE"
	elif command -v jq &>/dev/null; then
		# Migrate: add git_parent_dirs if missing from existing repos.json
		if ! jq -e '.git_parent_dirs' "$REPOS_FILE" &>/dev/null; then
			local temp_file="${REPOS_FILE}.tmp"
			if jq '. + {"git_parent_dirs": ["~/Git"]}' "$REPOS_FILE" >"$temp_file"; then
				mv "$temp_file" "$REPOS_FILE"
			else
				rm -f "$temp_file"
			fi
		fi
		# Migrate: backfill slug for entries missing it (detect from git remote)
		local needs_slug
		needs_slug=$(jq '[.initialized_repos[] | select(.slug == null or .slug == "")] | length' "$REPOS_FILE" 2>/dev/null) || needs_slug="0"
		if [[ "$needs_slug" -gt 0 ]]; then
			local temp_file="${REPOS_FILE}.tmp"
			local repo_path slug
			# Build a map of path->slug for repos missing slugs
			while IFS= read -r repo_path; do
				# Expand ~ to $HOME for git operations
				local expanded_path="${repo_path/#\~/$HOME}"
				slug=$(get_repo_slug "$expanded_path" 2>/dev/null) || slug=""
				if [[ -n "$slug" ]]; then
					jq --arg path "$repo_path" --arg slug "$slug" \
						'(.initialized_repos[] | select(.path == $path and (.slug == null or .slug == ""))) |= . + {slug: $slug}' \
						"$REPOS_FILE" >"$temp_file" && mv "$temp_file" "$REPOS_FILE"
				fi
			done < <(jq -r '.initialized_repos[] | select(.slug == null or .slug == "") | .path' "$REPOS_FILE" 2>/dev/null)
		fi
	fi
	return 0
}

# Detect GitHub slug (owner/repo) from git remote origin
# Usage: get_repo_slug <path>
get_repo_slug() {
	local repo_path="$1"
	local remote_url
	remote_url=$(git -C "$repo_path" remote get-url origin 2>/dev/null) || return 1
	# Strip protocol/host prefix and .git suffix to get owner/repo
	local slug
	slug=$(echo "$remote_url" | sed 's|.*github\.com[:/]||;s|\.git$||')
	if [[ -n "$slug" && "$slug" == *"/"* ]]; then
		echo "$slug"
		return 0
	fi
	return 1
}

# Check whether a repo name follows mission-control naming.
# Usage: _is_mission_control_repo_name <repo-name>
_is_mission_control_repo_name() {
	local repo_name="$1"
	case "$repo_name" in
	mission-control | *-mission-control | mission-control-*)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

# Resolve mission-control scope from slug and current actor.
# Usage: _resolve_mission_control_scope <owner/repo> <current-login>
# Prints: personal | org (or empty if not mission-control)
_resolve_mission_control_scope() {
	local slug="$1"
	local current_login="$2"

	if [[ -z "$slug" ]] || [[ "$slug" != */* ]]; then
		echo ""
		return 1
	fi

	local owner repo
	owner="${slug%%/*}"
	repo="${slug##*/}"

	if ! _is_mission_control_repo_name "$repo"; then
		echo ""
		return 1
	fi

	if [[ -n "$current_login" && "$owner" == "$current_login" ]]; then
		echo "personal"
		return 0
	fi

	echo "org"
	return 0
}

# Compute default repos.json registration values.
# Usage: _compute_repo_registration_defaults <path> <slug> <local_only> <maintainer>
# Prints eval-safe key=value lines: DEFAULT_PULSE, DEFAULT_PRIORITY
_compute_repo_registration_defaults() {
	local repo_path="$1"
	local slug="$2"
	local is_local_only="$3"
	local maintainer="$4"

	local default_pulse=false
	local default_priority=""

	if [[ "$is_local_only" == "true" ]]; then
		default_pulse=false
	else
		default_pulse=true
	fi

	if [[ "$slug" == */* ]]; then
		local owner repo
		owner="${slug%%/*}"
		repo="${slug##*/}"

		if [[ "$repo" == "$owner" ]] && [[ "$repo_path" == "$HOME/Git/$owner" ]]; then
			default_pulse=false
			default_priority="profile"
		elif _is_mission_control_repo_name "$repo"; then
			default_pulse=true
			if [[ "$owner" == "$maintainer" ]]; then
				default_priority="product"
			else
				default_priority="tooling"
			fi
		fi
	fi

	printf 'DEFAULT_PULSE=%q\n' "$default_pulse"
	printf 'DEFAULT_PRIORITY=%q\n' "$default_priority"
	return 0
}

# Register a repo in repos.json
# Usage: register_repo <path> <version> <features>
register_repo() {
	local repo_path="$1"
	local version="$2"
	local features="$3"

	init_repos_file

	# Normalize path (resolve symlinks, remove trailing slash)
	if ! repo_path=$(cd "$repo_path" 2>/dev/null && pwd -P); then
		print_warning "Cannot access path: $repo_path"
		return 1
	fi

	if ! command -v jq &>/dev/null; then
		print_warning "jq not installed - repo tracking disabled"
		return 0
	fi

	# Auto-detect GitHub slug from git remote
	local slug=""
	local is_local_only="false"
	if ! slug=$(get_repo_slug "$repo_path" 2>/dev/null); then
		slug=""
		# No remote origin — mark as local_only
		if ! git -C "$repo_path" remote get-url origin &>/dev/null; then
			is_local_only="true"
		fi
	fi

	# Auto-detect maintainer from gh API (current authenticated user)
	# Only runs once per registration — preserved on subsequent updates
	local maintainer=""
	if command -v gh &>/dev/null; then
		maintainer=$(gh api user --jq '.login' 2>/dev/null) || maintainer=""
	fi

	local DEFAULT_PULSE="false"
	local DEFAULT_PRIORITY=""
	eval "$(_compute_repo_registration_defaults "$repo_path" "$slug" "$is_local_only" "$maintainer")"

	# Check if repo already registered
	if jq -e --arg path "$repo_path" '.initialized_repos[] | select(.path == $path)' "$REPOS_FILE" &>/dev/null; then
		# Update existing entry, preserving pulse/priority/local_only/maintainer if already set
		local temp_file="${REPOS_FILE}.tmp"
		jq --arg path "$repo_path" --arg version "$version" --arg features "$features" \
			--arg slug "$slug" --argjson local_only "$is_local_only" --arg maintainer "$maintainer" \
			--argjson pulse_default "$DEFAULT_PULSE" --arg priority_default "$DEFAULT_PRIORITY" \
			'(.initialized_repos[] | select(.path == $path)) |= (
				. + {path: $path, version: $version, features: ($features | split(",")), updated: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))}
				| if $slug != "" then .slug = $slug else . end
				| if $local_only then .local_only = true else . end
				| if .pulse == null then .pulse = (if $local_only then false else $pulse_default end) else . end
				| if (.priority == null or .priority == "") and $priority_default != "" then .priority = $priority_default else . end
				| if (.maintainer == null or .maintainer == "") and $maintainer != "" then .maintainer = $maintainer else . end
			)' \
			"$REPOS_FILE" >"$temp_file" && mv "$temp_file" "$REPOS_FILE"
	else
		# Add new entry with slug, defaults, and maintainer
		local temp_file="${REPOS_FILE}.tmp"
		jq --arg path "$repo_path" --arg version "$version" --arg features "$features" \
			--arg slug "$slug" --arg maintainer "$maintainer" \
			--argjson local_only "$is_local_only" --argjson pulse_default "$DEFAULT_PULSE" \
			--arg priority_default "$DEFAULT_PRIORITY" \
			'.initialized_repos += [(
				{
					path: $path,
					maintainer: $maintainer,
					version: $version,
					features: ($features | split(",")),
					pulse: $pulse_default,
					initialized: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
				}
				| if $slug != "" then . + {slug: $slug} else . end
				| if $local_only then . + {local_only: true, pulse: false} else . end
				| if $priority_default != "" then . + {priority: $priority_default} else . end
			)]' \
			"$REPOS_FILE" >"$temp_file" && mv "$temp_file" "$REPOS_FILE"
	fi
	return 0
}

# Get list of registered repos
get_registered_repos() {
	init_repos_file

	if ! command -v jq &>/dev/null; then
		echo "[]"
		return 0
	fi

	jq -r '.initialized_repos[] | .path' "$REPOS_FILE" 2>/dev/null || echo ""
	return 0
}

# Get the maintainer GitHub username for a repo
# Fallback chain: maintainer field > slug owner > empty string
# Usage: get_repo_maintainer <slug>
get_repo_maintainer() {
	local slug="$1"

	if ! command -v jq &>/dev/null; then
		echo ""
		return 0
	fi

	local maintainer
	maintainer=$(jq -r --arg slug "$slug" \
		'.initialized_repos[] | select(.slug == $slug) | .maintainer // empty' \
		"$REPOS_FILE" 2>/dev/null) || maintainer=""

	if [[ -n "$maintainer" ]]; then
		echo "$maintainer"
		return 0
	fi

	# Fallback: extract owner from slug (owner/repo -> owner)
	if [[ -n "$slug" && "$slug" == *"/"* ]]; then
		echo "${slug%%/*}"
		return 0
	fi

	echo ""
	return 0
}

# Check if a repo needs upgrade (version behind current)
check_repo_needs_upgrade() {
	local repo_path="$1"
	local current_version
	current_version=$(get_version)

	if ! command -v jq &>/dev/null; then
		return 1
	fi

	local repo_version
	repo_version=$(jq -r --arg path "$repo_path" '.initialized_repos[] | select(.path == $path) | .version' "$REPOS_FILE" 2>/dev/null)

	if [[ -z "$repo_version" || "$repo_version" == "null" ]]; then
		return 1
	fi

	# Compare versions (simple string comparison works for semver)
	if [[ "$repo_version" != "$current_version" ]]; then
		return 0 # needs upgrade
	fi
	return 1 # up to date
}

# Check if a planning file needs upgrading (version mismatch or missing TOON markers)
# Usage: check_planning_file_version <file> <template>
# Returns 0 if upgrade needed, 1 if up to date
check_planning_file_version() {
	local file="$1" template="$2"
	if [[ -f "$file" ]]; then
		if ! grep -q "TOON:meta" "$file" 2>/dev/null; then
			return 0
		fi
		local current_ver template_ver
		current_ver=$(grep -A1 "TOON:meta" "$file" 2>/dev/null | tail -1 | cut -d',' -f1)
		template_ver=$(grep -A1 "TOON:meta" "$template" 2>/dev/null | tail -1 | cut -d',' -f1)
		if [[ -n "$template_ver" ]] && [[ "$current_ver" != "$template_ver" ]]; then
			return 0
		fi
		return 1
	else
		# No file = no upgrade needed (init would create it)
		return 1
	fi
}

# Check if a repo's planning templates need upgrading
# Returns 0 if any planning file needs upgrade
check_planning_needs_upgrade() {
	local repo_path="$1"
	local todo_file="$repo_path/TODO.md"
	local plans_file="$repo_path/todo/PLANS.md"
	local todo_template="$AGENTS_DIR/templates/todo-template.md"
	local plans_template="$AGENTS_DIR/templates/plans-template.md"

	[[ ! -f "$todo_template" ]] && return 1

	if check_planning_file_version "$todo_file" "$todo_template"; then
		return 0
	fi
	if [[ -f "$plans_template" ]] && check_planning_file_version "$plans_file" "$plans_template"; then
		return 0
	fi
	return 1
}

# Detect if current directory has aidevops but isn't registered
detect_unregistered_repo() {
	local project_root

	# Check if in a git repo
	if ! git rev-parse --is-inside-work-tree &>/dev/null; then
		return 1
	fi

	project_root=$(git rev-parse --show-toplevel 2>/dev/null)

	# Check for .aidevops.json
	if [[ ! -f "$project_root/.aidevops.json" ]]; then
		return 1
	fi

	init_repos_file

	if ! command -v jq &>/dev/null; then
		return 1
	fi

	# Check if already registered
	if jq -e --arg path "$project_root" '.initialized_repos[] | select(.path == $path)' "$REPOS_FILE" &>/dev/null; then
		return 1 # already registered
	fi

	# Not registered - return the path
	echo "$project_root"
	return 0
}

# Check if on protected branch and offer worktree creation
# Returns 0 if safe to proceed, 1 if user cancelled
# Sets WORKTREE_PATH if worktree was created
check_protected_branch() {
	local branch_type="${1:-chore}"
	local branch_suffix="${2:-aidevops-setup}"

	# Not in a git repo - skip check
	if ! git rev-parse --is-inside-work-tree &>/dev/null; then
		return 0
	fi

	local current_branch
	current_branch=$(git branch --show-current 2>/dev/null || echo "")

	# Not on a protected branch - safe to proceed
	if [[ ! "$current_branch" =~ ^(main|master)$ ]]; then
		return 0
	fi

	local project_root
	project_root=$(git rev-parse --show-toplevel)
	local repo_name
	repo_name=$(basename "$project_root")
	local suggested_branch="$branch_type/$branch_suffix"

	echo ""
	print_warning "On protected branch '$current_branch'"
	echo ""
	echo "Options:"
	echo "  1. Create worktree: $suggested_branch (recommended)"
	echo "  2. Continue on $current_branch (commits directly to main)"
	echo "  3. Cancel"
	echo ""
	local choice
	read -r -p "Choice [1]: " choice
	choice="${choice:-1}"

	case "$choice" in
	1)
		# Create worktree
		local worktree_dir
		worktree_dir="$(dirname "$project_root")/${repo_name}-${branch_type}-${branch_suffix}"

		print_info "Creating worktree at $worktree_dir..."

		if [[ -f "$AGENTS_DIR/scripts/worktree-helper.sh" ]]; then
			if bash "$AGENTS_DIR/scripts/worktree-helper.sh" add "$suggested_branch" 2>/dev/null; then
				export WORKTREE_PATH="$worktree_dir"
				echo ""
				print_success "Worktree created!"
				print_info "Switching to: $worktree_dir"
				echo ""
				# Change to worktree directory
				cd "$worktree_dir" || return 1
				return 0
			else
				print_error "Failed to create worktree"
				return 1
			fi
		else
			# Fallback without helper script
			if git worktree add -b "$suggested_branch" "$worktree_dir" 2>/dev/null; then
				export WORKTREE_PATH="$worktree_dir"
				echo ""
				print_success "Worktree created!"
				print_info "Switching to: $worktree_dir"
				echo ""
				cd "$worktree_dir" || return 1
				return 0
			else
				print_error "Failed to create worktree"
				return 1
			fi
		fi
		;;
	2)
		print_warning "Continuing on $current_branch - changes will commit directly"
		return 0
		;;
	3 | *)
		print_info "Cancelled"
		return 1
		;;
	esac
}

# Status helpers (extracted for complexity reduction)
_status_recommended_tools() {
	print_header "Recommended Tools"
	if [[ "$(uname)" == "Darwin" ]]; then
		check_dir "/Applications/Tabby.app" && print_success "Tabby terminal" || print_warning "Tabby terminal - not installed"
		if check_dir "/Applications/Zed.app"; then
			print_success "Zed editor"
			check_dir "$HOME/Library/Application Support/Zed/extensions/installed/opencode" && print_success "  └─ OpenCode extension" || print_warning "  └─ OpenCode extension - not installed"
		else print_warning "Zed editor - not installed"; fi
	else
		check_cmd tabby && print_success "Tabby terminal" || print_warning "Tabby terminal - not installed"
		if check_cmd zed; then
			print_success "Zed editor"
			check_dir "$HOME/.local/share/zed/extensions/installed/opencode" && print_success "  └─ OpenCode extension" || print_warning "  └─ OpenCode extension - not installed"
		else print_warning "Zed editor - not installed"; fi
	fi
	echo ""
	return 0
}

_status_ai_tools() {
	print_header "AI Tools & MCPs"
	check_cmd opencode && print_success "OpenCode CLI" || print_warning "OpenCode CLI - not installed"
	if check_cmd auggie; then
		check_file "$HOME/.augment/session.json" && print_success "Augment Context Engine (authenticated)" || print_warning "Augment Context Engine (not authenticated)"
	else print_warning "Augment Context Engine - not installed"; fi
	check_cmd bd && print_success "Beads CLI (task graph)" || print_warning "Beads CLI (bd) - not installed"
	echo ""
	return 0
}

_status_dev_envs() {
	print_header "Development Environments"
	check_dir "$INSTALL_DIR/python-env/dspy-env" && print_success "DSPy Python environment" || print_warning "DSPy Python environment - not created"
	check_cmd dspyground && print_success "DSPyGround" || print_warning "DSPyGround - not installed"
	echo ""
	return 0
}

_status_ai_configs() {
	print_header "AI Assistant Configurations"
	local ai_configs=("$HOME/.config/opencode/opencode.json:OpenCode" "$HOME/.claude/commands:Claude Code CLI" "$HOME/CLAUDE.md:Claude Code memory")
	for config in "${ai_configs[@]}"; do
		local path="${config%%:*}" name="${config##*:}"
		[[ -e "$path" ]] && print_success "$name" || print_warning "$name - not configured"
	done
	echo ""
	return 0
}

# Status command
cmd_status() {
	print_header "AI DevOps Framework Status"
	echo "=========================="
	echo ""
	local current_version
	current_version=$(get_version)
	local remote_version
	remote_version=$(get_remote_version)
	print_header "Version"
	echo "  Installed: $current_version"
	echo "  Latest:    $remote_version"
	if [[ "$current_version" != "$remote_version" && "$remote_version" != "unknown" ]]; then
		print_warning "Update available! Run: aidevops update"
	elif [[ "$current_version" == "$remote_version" ]]; then print_success "Up to date"; fi
	echo ""
	print_header "Installation"
	check_dir "$INSTALL_DIR" && print_success "Repository: $INSTALL_DIR" || print_error "Repository: Not found at $INSTALL_DIR"
	if check_dir "$AGENTS_DIR"; then
		local agent_count
		agent_count=$(find "$AGENTS_DIR" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
		print_success "Agents: $AGENTS_DIR ($agent_count files)"
	else print_error "Agents: Not deployed"; fi
	echo ""
	print_header "Required Dependencies"
	for cmd in git curl jq ssh; do check_cmd "$cmd" && print_success "$cmd" || print_error "$cmd - not installed"; done
	echo ""
	print_header "Optional Dependencies"
	check_cmd sshpass && print_success "sshpass" || print_warning "sshpass - not installed (needed for password SSH)"
	echo ""
	_status_recommended_tools
	print_header "Git CLI Tools"
	check_cmd gh && print_success "GitHub CLI (gh)" || print_warning "GitHub CLI (gh) - not installed"
	check_cmd glab && print_success "GitLab CLI (glab)" || print_warning "GitLab CLI (glab) - not installed"
	check_cmd tea && print_success "Gitea CLI (tea)" || print_warning "Gitea CLI (tea) - not installed"
	echo ""
	_status_ai_tools
	_status_dev_envs
	_status_ai_configs
	print_header "SSH Configuration"
	check_file "$HOME/.ssh/id_ed25519" && print_success "Ed25519 SSH key" || print_warning "Ed25519 SSH key - not found"
	echo ""
}

# Update helpers (extracted for complexity reduction)

_update_fresh_install() {
	print_warning "Repository not found, performing fresh install..."
	local tmp_setup
	tmp_setup=$(mktemp "${TMPDIR:-/tmp}/aidevops-setup-XXXXXX.sh") || {
		print_error "Failed to create temp file for setup script"
		return 1
	}
	trap 'rm -f "${tmp_setup:-}"' RETURN
	if curl -fsSL "https://raw.githubusercontent.com/marcusquinn/aidevops/main/setup.sh" -o "$tmp_setup" 2>/dev/null && [[ -s "$tmp_setup" ]]; then
		chmod +x "$tmp_setup"
		bash "$tmp_setup"
		local setup_exit=$?
		rm -f "$tmp_setup"
		[[ $setup_exit -ne 0 ]] && return 1
	else
		rm -f "$tmp_setup"
		print_error "Failed to download setup script"
		print_info "Try: git clone https://github.com/marcusquinn/aidevops.git $INSTALL_DIR && bash $INSTALL_DIR/setup.sh"
		return 1
	fi
	return 0
}

_update_sync_projects() {
	local skip="$1" current_ver="$2"
	echo ""
	print_header "Syncing Initialized Projects"
	if [[ "$skip" == "true" ]]; then
		print_info "Project sync skipped (--skip-project-sync)"
		return 0
	fi
	local repos_needing_upgrade=()
	while IFS= read -r repo_path; do
		[[ -z "$repo_path" ]] && continue
		[[ -d "$repo_path" ]] && check_repo_needs_upgrade "$repo_path" && repos_needing_upgrade+=("$repo_path")
	done < <(get_registered_repos)
	if [[ ${#repos_needing_upgrade[@]} -eq 0 ]]; then
		print_success "All registered projects are up to date"
		return 0
	fi
	local synced=0 skipped=0 failed=0
	for repo in "${repos_needing_upgrade[@]}"; do
		[[ ! -f "$repo/.aidevops.json" ]] && {
			skipped=$((skipped + 1))
			continue
		}
		local did_sync=false
		if command -v jq &>/dev/null; then
			local temp_file="${repo}/.aidevops.json.tmp"
			if jq --arg version "$current_ver" '.version = $version' "$repo/.aidevops.json" >"$temp_file" 2>/dev/null && [[ -s "$temp_file" ]]; then
				mv "$temp_file" "$repo/.aidevops.json"
				local features
				features=$(jq -r '[.features | to_entries[] | select(.value == true) | .key] | join(",")' "$repo/.aidevops.json" 2>/dev/null || echo "")
				register_repo "$repo" "$current_ver" "$features"
				did_sync=true
			else rm -f "$temp_file"; fi
		fi
		if [[ "$did_sync" != "true" ]]; then
			sed -i '' "s/\"version\": *\"[^\"]*\"/\"version\": \"$current_ver\"/" "$repo/.aidevops.json" 2>/dev/null && did_sync=true
		fi
		[[ "$did_sync" == "true" ]] && synced=$((synced + 1)) || failed=$((failed + 1))
	done
	[[ $synced -gt 0 ]] && print_success "Synced $synced project(s) to v$current_ver"
	[[ $skipped -gt 0 ]] && print_info "Skipped $skipped uninitialized project(s) (run 'aidevops init' in each to enable)"
	[[ $failed -gt 0 ]] && print_warning "$failed project(s) failed to sync (jq missing or write error)"
	return 0
}

_update_check_planning() {
	echo ""
	print_header "Checking Planning Templates"
	local repos_needing_planning=()
	while IFS= read -r repo_path; do
		[[ -z "$repo_path" || ! -d "$repo_path" ]] && continue
		if [[ -f "$repo_path/.aidevops.json" ]]; then
			local has_planning
			has_planning=$(grep -o '"planning": *true' "$repo_path/.aidevops.json" 2>/dev/null || true)
			[[ -n "$has_planning" ]] && check_planning_needs_upgrade "$repo_path" && repos_needing_planning+=("$repo_path")
		fi
	done < <(get_registered_repos)
	if [[ ${#repos_needing_planning[@]} -eq 0 ]]; then
		print_success "All planning templates are up to date"
		return 0
	fi
	echo ""
	print_warning "${#repos_needing_planning[@]} project(s) have outdated planning templates:"
	for repo in "${repos_needing_planning[@]}"; do
		local repo_name
		repo_name=$(basename "$repo")
		local todo_ver
		todo_ver=$(grep -A1 "TOON:meta" "$repo/TODO.md" 2>/dev/null | tail -1 | cut -d',' -f1)
		echo "  - $repo_name (v${todo_ver:-none})"
	done
	local template_ver
	template_ver=$(grep -A1 "TOON:meta" "$AGENTS_DIR/templates/todo-template.md" 2>/dev/null | tail -1 | cut -d',' -f1)
	echo ""
	echo "  Latest template: v${template_ver} (adds risk field, active session time estimates)"
	echo ""
	read -r -p "Upgrade planning templates in these projects? [y/N] " response
	if [[ "$response" =~ ^[Yy]$ ]]; then
		for repo in "${repos_needing_planning[@]}"; do
			print_info "Upgrading $(basename "$repo")..."
			(cd "$repo" && cmd_upgrade_planning --force) || print_warning "Failed to upgrade $(basename "$repo")"
		done
	else print_info "Run 'aidevops upgrade-planning' in each project to upgrade manually"; fi
	return 0
}

_update_check_tools() {
	echo ""
	print_header "Checking Key Tools"
	local tool_check_script="$AGENTS_DIR/scripts/tool-version-check.sh"
	if [[ ! -f "$tool_check_script" ]]; then
		print_info "Tool version check not available (run setup first)"
		return 0
	fi
	local stale_count=0 stale_tools=""
	local key_tool_cmds="opencode gh"
	local key_tool_pkgs="opencode-ai brew:gh"
	local idx=0
	for cmd_name in $key_tool_cmds; do
		local pkg_ref
		pkg_ref=$(echo "$key_tool_pkgs" | cut -d' ' -f$((idx + 1)))
		idx=$((idx + 1))
		local installed="" latest=""
		command -v "$cmd_name" &>/dev/null || continue
		installed=$("$cmd_name" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
		[[ -z "$installed" ]] && continue
		if [[ "$pkg_ref" == brew:* ]]; then
			local brew_pkg="${pkg_ref#brew:}"
			local brew_bin=""
			brew_bin=$(command -v brew 2>/dev/null || true)
			if [[ -n "$brew_bin" && -x "$brew_bin" ]]; then
				latest=$(_timeout_cmd 30 "$brew_bin" info --json=v2 "$brew_pkg" | jq -r '.formulae[0].versions.stable // empty' || true)
			elif [[ "$brew_pkg" == "gh" ]] && command -v gh &>/dev/null; then latest=$(get_public_release_tag "cli/cli"); fi
		else latest=$(_timeout_cmd 30 npm view "$pkg_ref" version || true); fi
		[[ -z "$latest" ]] && continue
		[[ "$installed" != "$latest" ]] && {
			stale_tools="${stale_tools:+$stale_tools, }$cmd_name ($installed -> $latest)"
			((++stale_count))
		}
	done
	if [[ "$stale_count" -eq 0 ]]; then
		print_success "Key tools are up to date"
	else
		print_warning "$stale_count tool(s) have updates: $stale_tools"
		echo ""
		read -r -p "Run full tool update check? [y/N] " response
		[[ "$response" =~ ^[Yy]$ ]] && bash "$tool_check_script" --update || print_info "Run 'aidevops update-tools --update' to update later"
	fi
	return 0
}

# Check for stale Homebrew-installed copy after git update (GH#11470)
_update_check_homebrew() {
	command -v brew &>/dev/null || return 0
	brew list aidevops &>/dev/null 2>&1 || return 0
	local brew_version=""
	brew_version=$(brew info aidevops --json=v2 2>/dev/null | jq -r '.formulae[0].installed[0].version // empty' 2>/dev/null || true)
	[[ -z "$brew_version" ]] && return 0
	local current_version
	current_version=$(get_version)
	[[ -z "$current_version" ]] && return 0
	if [[ "$brew_version" != "$current_version" ]]; then
		echo ""
		print_warning "Homebrew-installed copy is outdated ($brew_version vs $current_version)"
		print_info "The Homebrew wrapper should prefer your git copy, but if your PATH"
		print_info "resolves the Homebrew libexec copy directly, you'll run the old version."
		echo ""
		read -r -p "Run 'brew upgrade aidevops' now? [y/N] " response
		if [[ "$response" =~ ^[Yy]$ ]]; then
			brew upgrade aidevops 2>&1 || print_warning "brew upgrade failed — run manually: brew upgrade aidevops"
		else
			print_info "Run 'brew upgrade aidevops' to sync the Homebrew copy"
		fi
	fi
	return 0
}

# Update/upgrade command
cmd_update() {
	local skip_project_sync=false
	local arg
	for arg in "$@"; do case "$arg" in --skip-project-sync) skip_project_sync=true ;; esac done
	print_header "Updating AI DevOps Framework"
	echo ""
	local current_version
	current_version=$(get_version)
	print_info "Current version: $current_version"
	print_info "Fetching latest version..."

	if check_dir "$INSTALL_DIR/.git"; then
		cd "$INSTALL_DIR" || exit 1
		local current_branch
		current_branch=$(git branch --show-current 2>/dev/null || echo "")
		[[ "$current_branch" != "main" ]] && {
			print_info "Switching to main branch..."
			git checkout main --quiet 2>/dev/null || git checkout -b main origin/main --quiet 2>/dev/null || true
		}
		if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
			print_info "Cleaning up stale working tree changes..."
			git reset HEAD -- . 2>/dev/null || true
			git checkout -- . 2>/dev/null || true
		fi
		git fetch origin main --tags --quiet
		local local_hash
		local_hash=$(git rev-parse HEAD)
		local remote_hash
		remote_hash=$(git rev-parse origin/main)
		if [[ "$local_hash" == "$remote_hash" ]]; then
			print_success "Framework already up to date!"
			local repo_version deployed_version
			repo_version=$(cat "$INSTALL_DIR/VERSION" 2>/dev/null || echo "unknown")
			deployed_version=$(cat "$HOME/.aidevops/agents/VERSION" 2>/dev/null || echo "none")
			if [[ "$repo_version" != "$deployed_version" ]]; then
				print_warning "Deployed agents ($deployed_version) don't match repo ($repo_version)"
				print_info "Re-running setup to sync agents..."
				bash "$INSTALL_DIR/setup.sh" --non-interactive
			fi
			git checkout -- . 2>/dev/null || true
		else
			print_info "Pulling latest changes..."
			local old_hash
			old_hash=$(git rev-parse HEAD)
			if git pull --ff-only origin main --quiet; then
				:
			else
				print_warning "Fast-forward pull failed — resetting to origin/main..."
				git reset --hard origin/main --quiet 2>/dev/null || {
					print_error "Failed to reset to origin/main"
					print_info "Try: cd $INSTALL_DIR && git fetch origin && git reset --hard origin/main"
					return 1
				}
			fi
			local new_version new_hash
			new_version=$(get_version)
			new_hash=$(git rev-parse HEAD)
			if [[ "$old_hash" != "$new_hash" ]]; then
				local total_commits
				total_commits=$(git rev-list --count "$old_hash..$new_hash" 2>/dev/null || echo "0")
				if [[ "$total_commits" -gt 0 ]]; then
					echo ""
					print_info "Changes since $current_version ($total_commits commits):"
					git log --oneline "$old_hash..$new_hash" | grep -E '^[a-f0-9]+ (feat|fix|refactor|perf|docs):' | head -20
					[[ "$total_commits" -gt 20 ]] && echo "  ... and more (run 'git log --oneline' in $INSTALL_DIR for full list)"
				fi
			fi
			echo ""
			print_info "Running setup to apply changes..."
			local setup_exit=0
			bash "$INSTALL_DIR/setup.sh" --non-interactive || setup_exit=$?
			git checkout -- . 2>/dev/null || true
			local repo_version deployed_version
			repo_version=$(cat "$INSTALL_DIR/VERSION" 2>/dev/null || echo "unknown")
			deployed_version=$(cat "$HOME/.aidevops/agents/VERSION" 2>/dev/null || echo "none")
			[[ "$setup_exit" -ne 0 ]] && print_warning "Setup exited with code $setup_exit"
			if [[ "$repo_version" != "$deployed_version" ]]; then
				print_warning "Agent deployment incomplete: repo=$repo_version, deployed=$deployed_version"
				print_info "Run 'bash $INSTALL_DIR/setup.sh' manually to deploy agents"
			else print_success "Updated to version $new_version (agents deployed)"; fi
		fi
	else
		_update_fresh_install || return 1
	fi

	_update_sync_projects "$skip_project_sync" "$(get_version)"
	_update_check_homebrew
	_update_check_planning
	_update_check_tools
	return 0
}
# Uninstall helpers (extracted for complexity reduction)
_uninstall_cleanup_refs() {
	print_info "Removing AI assistant configuration references..."
	local ai_agent_files=("$HOME/.config/opencode/agent/AGENTS.md" "$HOME/.claude/commands/AGENTS.md" "$HOME/.opencode/AGENTS.md")
	for file in "${ai_agent_files[@]}"; do
		if check_file "$file"; then
			grep -q "Add ~/.aidevops/agents/AGENTS.md" "$file" 2>/dev/null && {
				rm -f "$file"
				print_success "Removed $file"
			}
		fi
	done
	print_info "Removing shell aliases..."
	for rc_file in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
		if check_file "$rc_file" && grep -q "# AI Assistant Server Access Framework" "$rc_file" 2>/dev/null; then
			cp "$rc_file" "$rc_file.bak"
			sed_inplace '/# AI Assistant Server Access Framework/,/^$/d' "$rc_file"
			print_success "Removed aliases from $rc_file"
		fi
	done
	print_info "Removing AI memory files..."
	local mf="$HOME/CLAUDE.md"
	check_file "$mf" && {
		rm -f "$mf"
		print_success "Removed $mf"
	}
	return 0
}

# Uninstall command
cmd_uninstall() {
	print_header "Uninstall AI DevOps Framework"
	echo ""
	print_warning "This will remove:"
	echo "  - $AGENTS_DIR (deployed agents)"
	echo "  - $INSTALL_DIR (repository)"
	echo "  - AI assistant configuration references"
	echo "  - Shell aliases (if added)"
	echo ""
	print_warning "This will NOT remove:"
	echo "  - Installed tools (Tabby, Zed, gh, glab, etc.)"
	echo "  - SSH keys"
	echo "  - Python/Node environments"
	echo ""
	read -r -p "Are you sure you want to uninstall? (yes/no): " confirm
	[[ "$confirm" != "yes" ]] && {
		print_info "Uninstall cancelled"
		return 0
	}
	echo ""
	check_dir "$AGENTS_DIR" && {
		print_info "Removing $AGENTS_DIR..."
		rm -rf "$AGENTS_DIR"
		print_success "Removed agents directory"
	}
	check_dir "$HOME/.aidevops" && {
		print_info "Removing $HOME/.aidevops..."
		rm -rf "$HOME/.aidevops"
		print_success "Removed aidevops config directory"
	}
	_uninstall_cleanup_refs
	echo ""
	read -r -p "Also remove the repository at $INSTALL_DIR? (yes/no): " remove_repo
	if [[ "$remove_repo" == "yes" ]]; then
		check_dir "$INSTALL_DIR" && {
			print_info "Removing $INSTALL_DIR..."
			rm -rf "$INSTALL_DIR"
			print_success "Removed repository"
		}
	else print_info "Keeping repository at $INSTALL_DIR"; fi
	echo ""
	print_success "Uninstall complete!"
	print_info "To reinstall, run:"
	echo "  npm install -g aidevops && aidevops update"
	echo "  OR: brew install marcusquinn/tap/aidevops && aidevops update"
}

# Scaffold standard repo courtesy files if they don't exist
# Scaffold helpers (extracted for complexity reduction)
_scaffold_contributing() {
	local project_root="$1" repo_name="$2"
	[[ -f "$project_root/CONTRIBUTING.md" ]] && return 1
	local c="# Contributing to $repo_name"
	c="$c"$'\n\n'"Thanks for your interest in contributing!"
	c="$c"$'\n\n'"## Quick Start"$'\n\n'"1. Fork the repository"
	c="$c"$'\n'"2. Create a branch: \`git checkout -b feature/your-feature\`"
	c="$c"$'\n'"3. Make your changes"
	c="$c"$'\n'"4. Commit with conventional commits: \`git commit -m \"feat: add new feature\"\`"
	c="$c"$'\n'"5. Push and open a PR"
	c="$c"$'\n\n'"## Commit Messages"$'\n\n'"We use [Conventional Commits](https://www.conventionalcommits.org/):"
	c="$c"$'\n\n'"- \`feat:\` - New feature"$'\n'"- \`fix:\` - Bug fix"$'\n'"- \`docs:\` - Documentation only"
	c="$c"$'\n'"- \`refactor:\` - Code change that neither fixes a bug nor adds a feature"$'\n'"- \`chore:\` - Maintenance tasks"
	printf '%s\n' "$c" >"$project_root/CONTRIBUTING.md"
	return 0
}

_scaffold_security() {
	local project_root="$1"
	[[ -f "$project_root/SECURITY.md" ]] && return 1
	local se="" ge
	ge=$(git -C "$project_root" config user.email 2>/dev/null || echo "")
	[[ -n "$ge" ]] && se="$ge"
	cat >"$project_root/SECURITY.md" <<SECEOF
# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability, please report it privately.
SECEOF
	[[ -n "$se" ]] && cat >>"$project_root/SECURITY.md" <<SECEOF

**Email:** $se

Please do not open public issues for security vulnerabilities.
SECEOF
	return 0
}

_scaffold_coc() {
	local project_root="$1"
	[[ -f "$project_root/CODE_OF_CONDUCT.md" ]] && return 1
	cat >"$project_root/CODE_OF_CONDUCT.md" <<'COCEOF'
# Contributor Covenant Code of Conduct

## Our Pledge

We as members, contributors, and leaders pledge to make participation in our
community a harassment-free experience for everyone.

## Our Standards

Examples of behavior that contributes to a positive environment:

- Using welcoming and inclusive language
- Being respectful of differing viewpoints and experiences
- Gracefully accepting constructive criticism
- Focusing on what is best for the community

## Attribution

This Code of Conduct is adapted from the [Contributor Covenant](https://www.contributor-covenant.org),
version 2.1.
COCEOF
	return 0
}

# Scaffold standard repo courtesy files if they don't exist
# Creates: README.md, LICENCE, CHANGELOG.md, CONTRIBUTING.md, SECURITY.md, CODE_OF_CONDUCT.md
scaffold_repo_courtesy_files() {
	local project_root="$1"
	local created=0
	local repo_name
	repo_name=$(basename "$project_root")
	local author_name
	author_name=$(git -C "$project_root" config user.name 2>/dev/null || echo "")
	local current_year
	current_year=$(date +%Y)
	print_info "Checking repo courtesy files..."
	if [[ ! -f "$project_root/README.md" ]]; then
		local rc="# $repo_name"
		if [[ -f "$project_root/.aidevops.json" ]]; then
			local desc
			desc=$(jq -r '.description // empty' "$project_root/.aidevops.json" 2>/dev/null || echo "")
			[[ -n "$desc" ]] && rc="$rc"$'\n\n'"$desc"
		fi
		{ [[ -f "$project_root/LICENCE" ]] || [[ -f "$project_root/LICENSE" ]]; } && rc="$rc"$'\n\n'"## Licence"$'\n\n'"See [LICENCE](LICENCE) for details."
		printf '%s\n' "$rc" >"$project_root/README.md"
		((++created))
	fi
	if [[ ! -f "$project_root/LICENCE" ]] && [[ ! -f "$project_root/LICENSE" ]]; then
		local lh="${author_name:-$(whoami)}"
		cat >"$project_root/LICENCE" <<LICEOF
MIT License

Copyright (c) $current_year $lh

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
LICEOF
		((++created))
	fi
	if [[ ! -f "$project_root/CHANGELOG.md" ]]; then
		cat >"$project_root/CHANGELOG.md" <<'CHEOF'
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]
CHEOF
		((++created))
	fi
	_scaffold_contributing "$project_root" "$repo_name" && ((++created))
	_scaffold_security "$project_root" && ((++created))
	_scaffold_coc "$project_root" && ((++created))
	[[ $created -gt 0 ]] && print_success "Created $created repo courtesy file(s) (README, LICENCE, CHANGELOG, etc.)" || print_info "Repo courtesy files already exist"
	return 0
}

# Generate the Security section content based on project type (t1412.11)
# Returns the content via stdout so callers can use it for create or update.
_generate_security_section() {
	local project_root="$1"

	# Detect project type for security recommendations
	local is_js_ts=false
	if [[ -f "$project_root/package.json" ]]; then
		is_js_ts=true
	fi

	cat <<'SECHEADER'
## Security

SECHEADER

	if [[ "$is_js_ts" == "true" ]]; then
		cat <<'SECEOF'
### Prompt Injection Defense

Any feature that processes untrusted content (tool outputs, user input, webhook
payloads) and passes it to an LLM must defend against prompt injection. This is
a JS/TS project — use `@stackone/defender` to sanitize untrusted tool results
before they enter the LLM context:

```bash
npm install @stackone/defender
```

```typescript
import { createPromptDefense } from '@stackone/defender';

const defense = createPromptDefense({ enableTier2: true, blockHighRisk: true });

// Sanitize untrusted tool output before adding to LLM context
const result = await defense.defendToolResult(toolResponse, 'tool_name');
if (!result.allowed) {
  throw new Error('Blocked untrusted content');
}
const safeContent = result.sanitized;
```

For features that don't use LLMs but process untrusted text (webhooks, form
submissions, API endpoints), validate and sanitize inputs at the boundary.

### General Security Rules

- Never log or expose API keys, tokens, or credentials in output
- Store secrets via `aidevops secret set <NAME>` (gopass-encrypted) or
  environment variables — never hardcode them in source
- Use `<PLACEHOLDER>` values in code examples; note the secure storage location
- Validate all external input (user input, webhook payloads, API responses)
- Pin third-party GitHub Actions to SHA hashes, not branch tags
- Run `aidevops security audit` periodically to check security posture
- See `~/.aidevops/agents/tools/security/prompt-injection-defender.md` for
  the framework's prompt injection defense patterns
SECEOF
	else
		cat <<'SECEOF'
### Prompt Injection Defense

Any feature that passes untrusted content to an LLM — user input, tool outputs,
retrieved documents, emails, tickets, or webhook payloads — must defend against
prompt injection. Sanitize and validate that content before including it in
prompts:

- Strip or escape control characters and instruction-like patterns
- Use structured prompt templates with clear system/user boundaries
- Never concatenate raw external content directly into system prompts
- Validate all externally sourced content (tool results, API responses, database
  records) before inclusion in prompts
- Consider allowlist-based input validation where possible

### General Security Rules

- Never log or expose API keys, tokens, or credentials in output
- Store secrets via `aidevops secret set <NAME>` (gopass-encrypted) or
  environment variables — never hardcode them in source
- Use `<PLACEHOLDER>` values in code examples; note the secure storage location
- Validate all external input (user input, webhook payloads, API responses)
- Pin third-party GitHub Actions to SHA hashes, not branch tags
- Run `aidevops security audit` periodically to check security posture
- See `~/.aidevops/agents/tools/security/prompt-injection-defender.md` for
  the framework's prompt injection defense patterns
SECEOF
	fi

	return 0
}

# Scaffold .agents/AGENTS.md with context-aware Security section (t1412.11)
# Idempotent: creates the file if missing, or updates the Security section
# in an existing file (preserving all other custom content).
scaffold_agents_md() {
	local project_root="$1"
	local agents_md="$project_root/.agents/AGENTS.md"

	mkdir -p "$(dirname "$agents_md")"

	if [[ -f "$agents_md" ]]; then
		# File exists — update the Security section idempotently
		_update_agents_md_security "$project_root"
		return $?
	fi

	# File missing — create from scratch with base template + security
	local security_content
	security_content=$(_generate_security_section "$project_root")

	cat >"$agents_md" <<'AGENTSEOF'
# Agent Instructions

This directory contains project-specific agent context. The [aidevops](https://aidevops.sh)
framework is loaded separately via the global config (`~/.aidevops/agents/`).

## Purpose

Files in `.agents/` provide project-specific instructions that AI assistants
read when working in this repository. Use this for:

- Domain-specific conventions not covered by the framework
- Project architecture decisions and patterns
- API design rules, data models, naming conventions
- Integration details (third-party services, deployment targets)

## Adding Agents

Create `.md` files in this directory for domain-specific context:

```text
.agents/
  AGENTS.md              # This file - overview and index
  api-patterns.md        # API design conventions
  deployment.md          # Deployment procedures
  data-model.md          # Database schema and relationships
```

Each file is read on demand by AI assistants when relevant to the task.

AGENTSEOF

	# Append the generated security section
	printf '%s\n' "$security_content" >>"$agents_md"

	return 0
}

# Update the Security section in an existing .agents/AGENTS.md (t1412.11)
# Replaces everything from "## Security" to the next "## " heading (or EOF)
# with the latest security guidance. Preserves all other content.
_update_agents_md_security() {
	local project_root="$1"
	local agents_md="$project_root/.agents/AGENTS.md"
	local tmp_file="${agents_md}.tmp.$$"

	local security_content
	security_content=$(_generate_security_section "$project_root")

	local in_security=false
	local has_security_section=false

	# Process line by line: skip old Security section, insert new one
	while IFS= read -r line || [[ -n "$line" ]]; do
		# Match "## Security" exactly, with optional trailing whitespace
		if [[ "$line" =~ ^'## Security'[[:space:]]*$ ]]; then
			# Found the Security heading — replace it
			in_security=true
			has_security_section=true
			printf '%s\n' "$security_content" >>"$tmp_file"
			continue
		fi

		if [[ "$in_security" == "true" ]]; then
			# Check if we've hit the next ## heading (end of Security section)
			if [[ "$line" == "## "* ]]; then
				in_security=false
				printf '%s\n' "$line" >>"$tmp_file"
			fi
			# Skip lines within the old Security section
			continue
		fi

		printf '%s\n' "$line" >>"$tmp_file"
	done <"$agents_md"

	if [[ "$has_security_section" == "false" ]]; then
		# No existing Security section — append it
		printf '\n%s\n' "$security_content" >>"$tmp_file"
	fi

	mv "$tmp_file" "$agents_md"

	return 0
}

# Init helpers (extracted for complexity reduction)
_init_parse_features() {
	local features="$1"
	case "$features" in
	all) echo "planning git_workflow code_quality time_tracking database beads security" ;;
	planning) echo "planning" ;; git-workflow) echo "git_workflow" ;; code-quality) echo "code_quality" ;;
	time-tracking) echo "time_tracking planning" ;; database) echo "database" ;;
	beads) echo "beads planning" ;; sops) echo "sops" ;; security) echo "security" ;;
	*)
		local result=""
		IFS=',' read -ra FL <<<"$features"
		for f in "${FL[@]}"; do
			case "$f" in
			planning) result="$result planning" ;; git-workflow) result="$result git_workflow" ;;
			code-quality) result="$result code_quality" ;; time-tracking) result="$result time_tracking planning" ;;
			database) result="$result database" ;; beads) result="$result beads planning" ;;
			sops) result="$result sops" ;; security) result="$result security" ;;
			esac
		done
		echo "$result"
		;;
	esac
	return 0
}

# Seed mission-control onboarding template when initializing a mission-control repo.
# Usage: _seed_mission_control_template <project_root> <personal|org>
_seed_mission_control_template() {
	local project_root="$1"
	local scope="$2"
	local seed_file="$project_root/todo/mission-control-seed.md"

	if [[ -z "$scope" ]]; then
		return 0
	fi

	if [[ -f "$seed_file" ]]; then
		return 0
	fi

	mkdir -p "$project_root/todo"

	if [[ "$scope" == "personal" ]]; then
		cat >"$seed_file" <<'EOF'
# Mission Control Seed (Personal)

Starter checklist for a personal mission-control repo initialized with aidevops.

## First-Day Setup

- [ ] Confirm `~/.config/aidevops/repos.json` has all active repos registered with correct `slug` and `path`
- [ ] Set `pulse: true` only for repos you want actively supervised
- [ ] Add `pulse_hours` windows to avoid dispatch during daytime manual development
- [ ] Verify profile and archive repos are `pulse: false` and `priority: "profile"` where applicable

## Operating Rhythm

- [ ] Define weekly review cadence for `aidevops pulse` health and backlog aging
- [ ] Add hygiene tasks for stale branches, stale worktrees, and stale queued issues
- [ ] Track cross-repo blockers in TODO with clear `blocked-by:` links
EOF
	else
		cat >"$seed_file" <<'EOF'
# Mission Control Seed (Organization)

Starter checklist for an organization mission-control repo initialized with aidevops.

## First-Day Setup

- [ ] Register all managed org repos in `~/.config/aidevops/repos.json` with `slug`, `path`, `priority`, and `maintainer`
- [ ] Set `pulse: true` only for repos approved for autonomous dispatch
- [ ] Configure `pulse_hours` and optional `pulse_expires` windows for sprint-based focus
- [ ] Keep sensitive/internal-only repos `pulse: false` until policy checks are complete

## Governance

- [ ] Define maintainer response SLA for `needs-maintainer-review` triage
- [ ] Document worker guardrails (release, merge, and security boundaries)
- [ ] Add a weekly audit task for repo registration drift and label hygiene
EOF
	fi

	print_success "Seeded mission-control template: todo/mission-control-seed.md (${scope})"
	return 0
}

# Init command - initialize aidevops in a project
cmd_init() {
	local features="${1:-all}"

	print_header "Initialize AI DevOps in Project"
	echo ""

	# Check if we're in a git repo
	if ! git rev-parse --is-inside-work-tree &>/dev/null; then
		print_error "Not in a git repository"
		print_info "Run 'git init' first or navigate to a git repository"
		return 1
	fi

	# Check for protected branch and offer worktree
	if ! check_protected_branch "chore" "aidevops-init"; then
		return 1
	fi

	local project_root
	project_root=$(git rev-parse --show-toplevel)
	print_info "Project root: $project_root"
	echo ""

	# Parse features using helper
	local parsed
	parsed=$(_init_parse_features "$features")
	local enable_planning=false enable_git_workflow=false enable_code_quality=false
	local enable_time_tracking=false enable_database=false enable_beads=false
	local enable_sops=false enable_security=false
	local _f
	for _f in $parsed; do
		case "$_f" in
		planning) enable_planning=true ;; git_workflow) enable_git_workflow=true ;;
		code_quality) enable_code_quality=true ;; time_tracking) enable_time_tracking=true ;;
		database) enable_database=true ;; beads) enable_beads=true ;;
		sops) enable_sops=true ;; security) enable_security=true ;;
		esac
	done

	# Create .aidevops.json config
	local config_file="$project_root/.aidevops.json"
	local aidevops_version
	aidevops_version=$(get_version)

	print_info "Creating .aidevops.json..."
	cat >"$config_file" <<EOF
{
  "version": "$aidevops_version",
  "initialized": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "features": {
    "planning": $enable_planning,
    "git_workflow": $enable_git_workflow,
    "code_quality": $enable_code_quality,
    "time_tracking": $enable_time_tracking,
    "database": $enable_database,
    "beads": $enable_beads,
    "sops": $enable_sops,
    "security": $enable_security
  },
  "time_tracking": {
    "enabled": $enable_time_tracking,
    "prompt_on_commit": true,
    "auto_record_branch_start": true
  },
  "database": {
    "enabled": $enable_database,
    "schema_path": "schemas",
    "migrations_path": "migrations",
    "seeds_path": "seeds",
    "auto_generate_migration": true
  },
  "beads": {
    "enabled": $enable_beads,
    "sync_on_commit": false,
    "auto_ready_check": true
  },
  "sops": {
    "enabled": $enable_sops,
    "backend": "age",
    "patterns": ["*.secret.yaml", "*.secret.json", "configs/*.enc.json", "configs/*.enc.yaml"]
  },
  "plugins": []
}
EOF
	# Note: plugins array is always present but empty by default.
	# Users add plugins via: aidevops plugin add <repo-url> [--namespace <name>]
	# Schema per plugin entry:
	# {
	#   "name": "pro",
	#   "repo": "https://github.com/user/aidevops-pro.git",
	#   "branch": "main",
	#   "namespace": "pro",
	#   "enabled": true
	# }
	# Plugins deploy to ~/.aidevops/agents/<namespace>/ (namespaced, no collisions)
	print_success "Created .aidevops.json"

	# Derive repo name for scaffolding
	# In worktrees, basename gives the worktree dir name (e.g., "repo-chore-foo"),
	# not the actual repo name. Prefer: git remote URL > main worktree basename > cwd basename.
	local repo_name
	local remote_url
	remote_url=$(git -C "$project_root" remote get-url origin 2>/dev/null || true)
	local repo_slug=""
	if [[ -n "$remote_url" ]]; then
		repo_slug=$(echo "$remote_url" | sed 's|.*github\.com[:/]||;s|\.git$||')
	fi
	if [[ -n "$remote_url" ]]; then
		repo_name=$(basename "$remote_url" .git)
	else
		# No remote — try main worktree path (first line of `git worktree list`)
		local main_wt
		main_wt=$(git -C "$project_root" worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')
		if [[ -n "$main_wt" ]]; then
			repo_name=$(basename "$main_wt")
		else
			repo_name=$(basename "$project_root")
		fi
	fi

	# Create .agents/ directory for project-specific agent context
	# (The aidevops framework is loaded globally via ~/.aidevops/agents/ — this
	# directory is for project-specific agents, conventions, and architecture docs)
	if [[ -L "$project_root/.agents" ]]; then
		# Migrate legacy symlink to real directory
		rm -f "$project_root/.agents"
		print_info "Removed legacy .agents symlink (framework is loaded globally now)"
	fi
	# Also clean up legacy .agent symlink/directory
	if [[ -L "$project_root/.agent" ]]; then
		rm -f "$project_root/.agent"
		print_info "Removed legacy .agent symlink"
	elif [[ -d "$project_root/.agent" && ! -d "$project_root/.agents" ]]; then
		mv "$project_root/.agent" "$project_root/.agents"
		print_success "Migrated .agent/ -> .agents/ directory"
	fi

	if [[ ! -d "$project_root/.agents" ]]; then
		mkdir -p "$project_root/.agents"
		print_success "Created .agents/ directory"
	fi

	# Scaffold or update .agents/AGENTS.md (idempotent — creates if missing,
	# updates Security section if file already exists)
	local _agents_md_existed=false
	[[ -f "$project_root/.agents/AGENTS.md" ]] && _agents_md_existed=true
	scaffold_agents_md "$project_root"
	if [[ "$_agents_md_existed" == "true" ]]; then
		print_success "Updated Security section in .agents/AGENTS.md"
	else
		print_success "Created .agents/AGENTS.md"
	fi

	# Scaffold root AGENTS.md if missing
	if [[ ! -f "$project_root/AGENTS.md" ]]; then
		cat >"$project_root/AGENTS.md" <<ROOTAGENTSEOF
# $repo_name

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Build**: \`# TODO: add build command\`
- **Test**: \`# TODO: add test command\`
- **Deploy**: \`# TODO: add deploy command\`

## Project Overview

<!-- Brief description of what this project does and why it exists. -->

## Architecture

<!-- Key architectural decisions, tech stack, directory structure. -->

## Conventions

- Commits: [Conventional Commits](https://www.conventionalcommits.org/)
- Branches: \`feature/\`, \`bugfix/\`, \`hotfix/\`, \`refactor/\`, \`chore/\`

## Key Files

| File | Purpose |
|------|---------|
| \`.agents/AGENTS.md\` | Project-specific agent instructions |
| \`TODO.md\` | Task tracking |
| \`CHANGELOG.md\` | Version history |

<!-- AI-CONTEXT-END -->
ROOTAGENTSEOF
		print_success "Created AGENTS.md"
	fi

	# Create planning files if enabled
	if [[ "$enable_planning" == "true" ]]; then
		print_info "Setting up planning files..."

		# Create TODO.md from template
		if [[ ! -f "$project_root/TODO.md" ]]; then
			if [[ -f "$AGENTS_DIR/templates/todo-template.md" ]]; then
				cp "$AGENTS_DIR/templates/todo-template.md" "$project_root/TODO.md"
				print_success "Created TODO.md"
			else
				# Fallback minimal template
				cat >"$project_root/TODO.md" <<'EOF'
# TODO

## In Progress

<!-- Tasks currently being worked on -->

## Backlog

<!-- Prioritized list of upcoming tasks -->

---

*Format: `- [ ] Task description @owner #tag ~estimate`*
*Time tracking: `started:`, `completed:`, `actual:`*
EOF
				print_success "Created TODO.md (minimal template)"
			fi
		else
			print_warning "TODO.md already exists, skipping"
		fi

		# Create todo/ directory and PLANS.md
		mkdir -p "$project_root/todo/tasks"

		if [[ ! -f "$project_root/todo/PLANS.md" ]]; then
			if [[ -f "$AGENTS_DIR/templates/plans-template.md" ]]; then
				cp "$AGENTS_DIR/templates/plans-template.md" "$project_root/todo/PLANS.md"
				print_success "Created todo/PLANS.md"
			else
				# Fallback minimal template
				cat >"$project_root/todo/PLANS.md" <<'EOF'
# Execution Plans

Complex, multi-session work that requires detailed planning.

## Active Plans

<!-- Plans currently in progress -->

## Completed Plans

<!-- Archived completed plans -->

---

*See `.agents/workflows/plans.md` for planning workflow*
EOF
				print_success "Created todo/PLANS.md (minimal template)"
			fi
		else
			print_warning "todo/PLANS.md already exists, skipping"
		fi

		# Create .gitkeep in tasks
		touch "$project_root/todo/tasks/.gitkeep"

		# Seed mission-control starter template for personal/org control repos
		local init_actor=""
		if command -v gh &>/dev/null; then
			init_actor=$(gh api user --jq '.login' 2>/dev/null || echo "")
		fi
		local mission_scope=""
		mission_scope=$(_resolve_mission_control_scope "$repo_slug" "$init_actor" 2>/dev/null || echo "")
		_seed_mission_control_template "$project_root" "$mission_scope"
	fi

	# Create database directories if enabled
	if [[ "$enable_database" == "true" ]]; then
		print_info "Setting up database schema directories..."

		# Create schemas directory with AGENTS.md
		if [[ ! -d "$project_root/schemas" ]]; then
			mkdir -p "$project_root/schemas"
			cat >"$project_root/schemas/AGENTS.md" <<'EOF'
# Database Schemas

Declarative schema files - source of truth for database structure.

See: `@sql-migrations` or `.agents/workflows/sql-migrations.md`
EOF
			print_success "Created schemas/ directory"
		else
			print_warning "schemas/ already exists, skipping"
		fi

		# Create migrations directory with AGENTS.md
		if [[ ! -d "$project_root/migrations" ]]; then
			mkdir -p "$project_root/migrations"
			cat >"$project_root/migrations/AGENTS.md" <<'EOF'
# Database Migrations

Auto-generated versioned migration files. Do not edit manually.

See: `@sql-migrations` or `.agents/workflows/sql-migrations.md`
EOF
			print_success "Created migrations/ directory"
		else
			print_warning "migrations/ already exists, skipping"
		fi

		# Create seeds directory with AGENTS.md
		if [[ ! -d "$project_root/seeds" ]]; then
			mkdir -p "$project_root/seeds"
			cat >"$project_root/seeds/AGENTS.md" <<'EOF'
# Database Seeds

Initial and reference data (roles, statuses, test accounts).

See: `@sql-migrations` or `.agents/workflows/sql-migrations.md`
EOF
			print_success "Created seeds/ directory"
		else
			print_warning "seeds/ already exists, skipping"
		fi
	fi

	# Initialize Beads if enabled
	if [[ "$enable_beads" == "true" ]]; then
		print_info "Setting up Beads task graph..."

		# Check if Beads CLI is installed
		if ! command -v bd &>/dev/null; then
			print_warning "Beads CLI (bd) not installed"
			echo "  Install with: brew install steveyegge/beads/bd"
			echo "  Or download: https://github.com/steveyegge/beads/releases"
			echo "  Or via Go:   go install github.com/steveyegge/beads/cmd/bd@latest"
		else
			# Initialize Beads in the project
			if [[ ! -d "$project_root/.beads" ]]; then
				print_info "Initializing Beads database..."
				if (cd "$project_root" && bd init 2>/dev/null); then
					print_success "Beads initialized"
				else
					print_warning "Beads init failed - run manually: bd init"
				fi
			else
				print_info "Beads already initialized"
			fi

			# Run initial sync from TODO.md/PLANS.md
			if [[ -f "$AGENTS_DIR/scripts/beads-sync-helper.sh" ]]; then
				print_info "Syncing tasks to Beads..."
				if bash "$AGENTS_DIR/scripts/beads-sync-helper.sh" push "$project_root" 2>/dev/null; then
					print_success "Tasks synced to Beads"
				else
					print_warning "Beads sync failed - run manually: beads-sync-helper.sh push"
				fi
			fi
		fi
	fi

	# Initialize SOPS if enabled
	if [[ "$enable_sops" == "true" ]]; then
		print_info "Setting up SOPS encrypted config support..."

		# Check for sops and age
		local sops_ready=true
		if ! command -v sops &>/dev/null; then
			print_warning "SOPS not installed"
			echo "  Install with: brew install sops"
			sops_ready=false
		fi
		if ! command -v age-keygen &>/dev/null; then
			print_warning "age not installed (default SOPS backend)"
			echo "  Install with: brew install age"
			sops_ready=false
		fi

		# Generate age key if none exists
		local age_key_file="$HOME/.config/sops/age/keys.txt"
		if [[ "$sops_ready" == "true" ]] && [[ ! -f "$age_key_file" ]]; then
			print_info "Generating age key for SOPS..."
			mkdir -p "$(dirname "$age_key_file")"
			age-keygen -o "$age_key_file" 2>/dev/null
			chmod 600 "$age_key_file"
			print_success "Age key generated at $age_key_file"
		fi

		# Create .sops.yaml if it doesn't exist
		if [[ ! -f "$project_root/.sops.yaml" ]]; then
			local age_pubkey=""
			if [[ -f "$age_key_file" ]]; then
				age_pubkey=$(grep -o 'age1[a-z0-9]*' "$age_key_file" | head -1)
			fi

			if [[ -n "$age_pubkey" ]]; then
				cat >"$project_root/.sops.yaml" <<SOPSEOF
# SOPS configuration - encrypts values in config files while keeping keys visible
# See: .agents/tools/credentials/sops.md
creation_rules:
  - path_regex: '\.secret\.(yaml|yml|json)$'
    age: >-
      $age_pubkey
  - path_regex: 'configs/.*\.enc\.(yaml|yml|json)$'
    age: >-
      $age_pubkey
SOPSEOF
				print_success "Created .sops.yaml with age key"
			else
				cat >"$project_root/.sops.yaml" <<'SOPSEOF'
# SOPS configuration - encrypts values in config files while keeping keys visible
# See: .agents/tools/credentials/sops.md
#
# Generate an age key first:
#   age-keygen -o ~/.config/sops/age/keys.txt
#
# Then replace AGE_PUBLIC_KEY below with your public key:
creation_rules:
  - path_regex: '\.secret\.(yaml|yml|json)$'
    age: >-
      AGE_PUBLIC_KEY
  - path_regex: 'configs/.*\.enc\.(yaml|yml|json)$'
    age: >-
      AGE_PUBLIC_KEY
SOPSEOF
				print_warning "Created .sops.yaml template (replace AGE_PUBLIC_KEY with your key)"
			fi
		else
			print_info ".sops.yaml already exists"
		fi
	fi

	# Ensure .gitattributes has ai-training=false (opt out of AI model training)
	# GitHub and other platforms respect this attribute to exclude repo content
	# from AI/ML training datasets. Idempotent — only adds if not already present.
	local gitattributes="$project_root/.gitattributes"
	if [[ -f "$gitattributes" ]]; then
		if ! grep -qE '^\*[[:space:]]+ai-training=false' "$gitattributes" 2>/dev/null; then
			ensure_trailing_newline "$gitattributes"
			{
				echo ""
				echo "# Opt out of AI model training"
				echo "* ai-training=false"
			} >>"$gitattributes"
			print_success "Added ai-training=false to .gitattributes"
		else
			print_info ".gitattributes already has ai-training=false"
		fi
	else
		cat >"$gitattributes" <<'GITATTRSEOF'
# Opt out of AI model training
* ai-training=false
GITATTRSEOF
		print_success "Created .gitattributes with ai-training=false"
	fi

	# Add aidevops runtime artifacts to .gitignore
	# Note: .agents/ itself is NOT ignored — it contains committed project-specific agents.
	# Only runtime artifacts (loop state, tmp, memory) are ignored.
	local gitignore="$project_root/.gitignore"
	if [[ -f "$gitignore" ]]; then
		local gitignore_updated=false

		# Remove legacy bare ".agents" entry if present (was added by older versions)
		if grep -q "^\.agents$" "$gitignore" 2>/dev/null; then
			sed -i '' '/^\.agents$/d' "$gitignore" 2>/dev/null ||
				sed -i '/^\.agents$/d' "$gitignore" 2>/dev/null || true
			# Also remove the "# aidevops" comment if it's now orphaned
			sed -i '' '/^# aidevops$/{ N; /^# aidevops\n$/d; }' "$gitignore" 2>/dev/null || true
			print_info "Removed legacy bare .agents from .gitignore (now tracked)"
			gitignore_updated=true
		fi

		# Remove legacy bare ".agent" entry if present
		if grep -q "^\.agent$" "$gitignore" 2>/dev/null; then
			sed -i '' '/^\.agent$/d' "$gitignore" 2>/dev/null ||
				sed -i '/^\.agent$/d' "$gitignore" 2>/dev/null || true
			gitignore_updated=true
		fi

		# Add runtime artifact ignores
		if ! grep -q "^\.agents/loop-state/" "$gitignore" 2>/dev/null; then
			# Ensure trailing newline before appending (prevents malformed entries like *.zip.agents/loop-state/)
			ensure_trailing_newline "$gitignore"
			{
				echo ""
				echo "# aidevops runtime artifacts"
				echo ".agents/loop-state/"
				echo ".agents/tmp/"
				echo ".agents/memory/"
			} >>"$gitignore"
			print_success "Added .agents/ runtime artifact ignores to .gitignore"
			gitignore_updated=true
		fi

		# Add .aidevops.json to gitignore (local config, not committed).
		# If .aidevops.json is already tracked by git (committed by older framework
		# versions), untrack it first — adding a tracked file to .gitignore is a
		# no-op and the file keeps showing in git diff on every re-init (#2570 bug 3).
		if ! grep -q "^\.aidevops\.json$" "$gitignore" 2>/dev/null; then
			if git -C "$project_root" ls-files --error-unmatch .aidevops.json &>/dev/null; then
				git -C "$project_root" rm --cached .aidevops.json &>/dev/null || true
				print_info "Untracked .aidevops.json from git (was committed by older version)"
			fi
			# Ensure trailing newline before appending
			ensure_trailing_newline "$gitignore"
			echo ".aidevops.json" >>"$gitignore"
			gitignore_updated=true
		fi

		# Add .beads if beads is enabled
		if [[ "$enable_beads" == "true" ]]; then
			if ! grep -q "^\.beads$" "$gitignore" 2>/dev/null; then
				# Ensure trailing newline before appending
				ensure_trailing_newline "$gitignore"
				echo ".beads" >>"$gitignore"
				print_success "Added .beads to .gitignore"
				gitignore_updated=true
			fi
		fi

		if [[ "$gitignore_updated" == "true" ]]; then
			print_info "Updated .gitignore"
		fi
	fi

	# Generate collaborator pointer files (lightweight AGENTS.md references)
	local pointer_content="Read AGENTS.md for all project context and instructions."
	local pointer_files=(".cursorrules" ".windsurfrules" ".clinerules" ".github/copilot-instructions.md")
	local pointer_created=0
	for pf in "${pointer_files[@]}"; do
		local pf_path="$project_root/$pf"
		if [[ ! -f "$pf_path" ]]; then
			mkdir -p "$(dirname "$pf_path")"
			echo "$pointer_content" >"$pf_path"
			((++pointer_created))
		fi
	done
	if [[ $pointer_created -gt 0 ]]; then
		print_success "Created $pointer_created collaborator pointer file(s) (.cursorrules, etc.)"
	else
		print_info "Collaborator pointer files already exist"
	fi

	# Scaffold repo courtesy files (README, LICENCE, CHANGELOG, etc.)
	scaffold_repo_courtesy_files "$project_root"

	# Generate MODELS.md (per-repo model performance leaderboard, t1129)
	local generate_models_script="$AGENTS_DIR/scripts/generate-models-md.sh"
	if [[ -x "$generate_models_script" ]] && command -v sqlite3 &>/dev/null; then
		print_info "Generating MODELS.md (model performance leaderboard)..."
		if "$generate_models_script" --output "$project_root/MODELS.md" --repo-path "$project_root" --quiet 2>/dev/null; then
			print_success "Created MODELS.md (per-repo model leaderboard)"
		else
			print_warning "MODELS.md generation failed (will be populated as tasks run)"
		fi
	else
		print_info "MODELS.md skipped (sqlite3 or generate script not available)"
	fi

	# Run security posture assessment if enabled (t1412.11)
	if [[ "$enable_security" == "true" ]]; then
		local security_posture_script="$AGENTS_DIR/scripts/security-posture-helper.sh"
		if [[ -f "$security_posture_script" ]]; then
			print_info "Running security posture assessment..."
			if bash "$security_posture_script" store "$project_root"; then
				print_success "Security posture assessed and stored in .aidevops.json"
			else
				print_warning "Security posture assessment found issues (review with: aidevops security audit)"
			fi
		else
			print_info "Security posture check skipped (security-posture-helper.sh not available)"
		fi
	fi

	# Build features string for registration
	local features_list=""
	[[ "$enable_planning" == "true" ]] && features_list="${features_list}planning,"
	[[ "$enable_git_workflow" == "true" ]] && features_list="${features_list}git-workflow,"
	[[ "$enable_code_quality" == "true" ]] && features_list="${features_list}code-quality,"
	[[ "$enable_time_tracking" == "true" ]] && features_list="${features_list}time-tracking,"
	[[ "$enable_database" == "true" ]] && features_list="${features_list}database,"
	[[ "$enable_beads" == "true" ]] && features_list="${features_list}beads,"
	[[ "$enable_sops" == "true" ]] && features_list="${features_list}sops,"
	[[ "$enable_security" == "true" ]] && features_list="${features_list}security,"
	features_list="${features_list%,}" # Remove trailing comma

	# Register repo in repos.json
	register_repo "$project_root" "$aidevops_version" "$features_list"

	# Auto-commit initialized files so they don't linger as mystery unstaged
	# changes (#2570 bug 2). Collect all files that cmd_init creates/modifies.
	local init_files=()
	[[ -f "$project_root/.gitattributes" ]] && init_files+=(".gitattributes")
	[[ -f "$project_root/.gitignore" ]] && init_files+=(".gitignore")
	[[ -d "$project_root/.agents" ]] && init_files+=(".agents/")
	[[ -f "$project_root/AGENTS.md" ]] && init_files+=("AGENTS.md")
	[[ -f "$project_root/TODO.md" ]] && init_files+=("TODO.md")
	[[ -d "$project_root/todo" ]] && init_files+=("todo/")
	[[ -f "$project_root/MODELS.md" ]] && init_files+=("MODELS.md")
	[[ -f "$project_root/LICENCE" ]] && init_files+=("LICENCE")
	[[ -f "$project_root/CHANGELOG.md" ]] && init_files+=("CHANGELOG.md")
	[[ -f "$project_root/README.md" ]] && init_files+=("README.md")
	[[ -f "$project_root/.cursorrules" ]] && init_files+=(".cursorrules")
	[[ -f "$project_root/.windsurfrules" ]] && init_files+=(".windsurfrules")
	[[ -f "$project_root/.clinerules" ]] && init_files+=(".clinerules")
	[[ -d "$project_root/.github" ]] && init_files+=(".github/")
	[[ -f "$project_root/.sops.yaml" ]] && init_files+=(".sops.yaml")
	[[ -d "$project_root/schemas" ]] && init_files+=("schemas/")
	[[ -d "$project_root/migrations" ]] && init_files+=("migrations/")
	[[ -d "$project_root/seeds" ]] && init_files+=("seeds/")

	local committed=false
	if [[ ${#init_files[@]} -gt 0 ]]; then
		# Stage all init files (--force not needed; .aidevops.json is gitignored above)
		if git -C "$project_root" add -- "${init_files[@]}" 2>/dev/null; then
			# Only commit if there are staged changes
			if ! git -C "$project_root" diff --cached --quiet 2>/dev/null; then
				if git -C "$project_root" commit -m "chore: initialize aidevops v${aidevops_version}" 2>/dev/null; then
					committed=true
					print_success "Committed initialized files"
				else
					print_warning "Auto-commit failed (pre-commit hook rejected?)"
				fi
			fi
		fi
	fi

	echo ""
	print_success "AI DevOps initialized!"
	echo ""
	echo "Enabled features:"
	[[ "$enable_planning" == "true" ]] && echo "  ✓ Planning (TODO.md, PLANS.md)"
	[[ "$enable_git_workflow" == "true" ]] && echo "  ✓ Git workflow (branch management)"
	[[ "$enable_code_quality" == "true" ]] && echo "  ✓ Code quality (linting, auditing)"
	[[ "$enable_time_tracking" == "true" ]] && echo "  ✓ Time tracking (estimates, actuals)"
	[[ "$enable_database" == "true" ]] && echo "  ✓ Database (schemas/, migrations/, seeds/)"
	[[ "$enable_beads" == "true" ]] && echo "  ✓ Beads (task graph visualization)"
	[[ "$enable_sops" == "true" ]] && echo "  ✓ SOPS (encrypted config files with age backend)"
	[[ "$enable_security" == "true" ]] && echo "  ✓ Security (per-repo posture assessment)"
	[[ -f "$project_root/MODELS.md" ]] && echo "  ✓ MODELS.md (per-repo model performance leaderboard)"
	echo ""
	echo "Next steps:"
	local step=1
	if [[ "$committed" != "true" ]]; then
		echo "  ${step}. Commit the initialized files: git add -A && git commit -m 'chore: initialize aidevops'"
		((++step))
	fi
	if [[ "$enable_beads" == "true" ]]; then
		echo "  ${step}. Add tasks to TODO.md with dependencies (blocked-by:t001)"
		((++step))
		echo "  ${step}. Run /ready to see unblocked tasks"
		((++step))
		echo "  ${step}. Run /sync-beads to sync with Beads graph"
		((++step))
		echo "  ${step}. Use 'bd' CLI for graph visualization"
	elif [[ "$enable_database" == "true" ]]; then
		echo "  ${step}. Add schema files to schemas/"
		((++step))
		echo "  ${step}. Run diff to generate migrations"
		((++step))
		echo "  ${step}. See .agents/workflows/sql-migrations.md"
	else
		echo "  ${step}. Add tasks to TODO.md"
		((++step))
		echo "  ${step}. Use /create-prd for complex features"
		((++step))
		echo "  ${step}. Use /feature to start development"
	fi

	return 0
}

# Upgrade planning helpers (extracted for complexity reduction)

_upgrade_validate() {
	local project_root="$1"
	[[ ! -f "$project_root/.aidevops.json" ]] && {
		print_error "aidevops not initialized in this project"
		print_info "Run 'aidevops init' first"
		return 1
	}
	if command -v jq &>/dev/null; then
		jq -e '.features.planning == true' "$project_root/.aidevops.json" &>/dev/null || {
			print_error "Planning feature not enabled"
			print_info "Run 'aidevops init planning' to enable"
			return 1
		}
	else
		local pe
		pe=$(grep -o '"planning": *true' "$project_root/.aidevops.json" 2>/dev/null || echo "")
		[[ -z "$pe" ]] && {
			print_error "Planning feature not enabled"
			print_info "Run 'aidevops init planning' to enable"
			return 1
		}
	fi
	[[ ! -f "$AGENTS_DIR/templates/todo-template.md" ]] && {
		print_error "TODO template not found: $AGENTS_DIR/templates/todo-template.md"
		return 1
	}
	[[ ! -f "$AGENTS_DIR/templates/plans-template.md" ]] && {
		print_error "PLANS template not found: $AGENTS_DIR/templates/plans-template.md"
		return 1
	}
	return 0
}

_upgrade_check_version() {
	local file="$1" template="$2" label="$3"
	if check_planning_file_version "$file" "$template"; then
		if [[ -f "$file" ]]; then
			if ! grep -q "TOON:meta" "$file" 2>/dev/null; then
				print_warning "$label uses minimal template (missing TOON markers)"
			else
				local cv tv
				cv=$(grep -A1 "TOON:meta" "$file" 2>/dev/null | tail -1 | cut -d',' -f1)
				tv=$(grep -A1 "TOON:meta" "$template" 2>/dev/null | tail -1 | cut -d',' -f1)
				print_warning "$label format version $cv -> $tv"
			fi
		else print_info "$label not found - will create from template"; fi
		return 0
	else
		local cv
		cv=$(grep -A1 "TOON:meta" "$file" 2>/dev/null | tail -1 | cut -d',' -f1)
		print_success "$label already up to date (v${cv})"
		return 1
	fi
}

_upgrade_todo() {
	local todo_file="$1" todo_template="$2" backup="$3"
	print_info "Upgrading TODO.md..."
	local existing_tasks=""
	if [[ -f "$todo_file" ]]; then
		existing_tasks=$(grep -E "^[[:space:]]*- \[([ x-])\]" "$todo_file" 2>/dev/null || echo "")
		[[ "$backup" == "true" ]] && {
			cp "$todo_file" "${todo_file}.bak"
			print_success "Backup created: TODO.md.bak"
		}
	fi
	local temp_todo="${todo_file}.new"
	if awk '/^---$/ && !p {c++; if(c==2) p=1; next} p' "$todo_template" >"$temp_todo" 2>/dev/null && [[ -s "$temp_todo" ]]; then
		mv "$temp_todo" "$todo_file"
	else
		rm -f "$temp_todo"
		cp "$todo_template" "$todo_file"
	fi
	sed_inplace "s/{{DATE}}/$(date +%Y-%m-%d)/" "$todo_file" 2>/dev/null || true
	if [[ -n "$existing_tasks" ]] && grep -q "<!--TOON:backlog" "$todo_file"; then
		local temp_file="${todo_file}.merge" tasks_file
		tasks_file=$(mktemp)
		trap 'rm -f "${tasks_file:-}"' RETURN
		printf '%s\n' "$existing_tasks" >"$tasks_file"
		local in_backlog=false
		while IFS= read -r line || [[ -n "$line" ]]; do
			[[ "$line" == *"<!--TOON:backlog"* ]] && in_backlog=true
			if [[ "$in_backlog" == true && "$line" == "-->" ]]; then
				echo "$line"
				echo ""
				cat "$tasks_file"
				in_backlog=false
				continue
			fi
			echo "$line"
		done <"$todo_file" >"$temp_file"
		rm -f "$tasks_file"
		mv "$temp_file" "$todo_file"
		print_success "Merged existing tasks into Backlog"
	fi
	print_success "TODO.md upgraded to TOON-enhanced template"
	return 0
}

_upgrade_plans() {
	local plans_file="$1" plans_template="$2" backup="$3" project_root="$4"
	print_info "Upgrading todo/PLANS.md..."
	mkdir -p "$project_root/todo/tasks"
	local existing_plans=""
	if [[ -f "$plans_file" ]]; then
		existing_plans=$(awk '/^### /{found=1} found{print}' "$plans_file" 2>/dev/null || echo "")
		[[ "$backup" == "true" ]] && {
			cp "$plans_file" "${plans_file}.bak"
			print_success "Backup created: todo/PLANS.md.bak"
		}
	fi
	local temp_plans="${plans_file}.new"
	if awk '/^---$/ && !p {c++; if(c==2) p=1; next} p' "$plans_template" >"$temp_plans" 2>/dev/null && [[ -s "$temp_plans" ]]; then
		mv "$temp_plans" "$plans_file"
	else
		rm -f "$temp_plans"
		cp "$plans_template" "$plans_file"
	fi
	sed_inplace "s/{{DATE}}/$(date +%Y-%m-%d)/" "$plans_file" 2>/dev/null || true
	if [[ -n "$existing_plans" ]] && grep -q "<!--TOON:active_plans" "$plans_file"; then
		local temp_file="${plans_file}.merge" pcf
		pcf=$(mktemp)
		trap 'rm -f "${pcf:-}"' RETURN
		printf '%s\n' "$existing_plans" >"$pcf"
		local in_active=false
		while IFS= read -r line || [[ -n "$line" ]]; do
			[[ "$line" == *"<!--TOON:active_plans"* ]] && in_active=true
			if [[ "$in_active" == true && "$line" == "-->" ]]; then
				echo "$line"
				echo ""
				cat "$pcf"
				in_active=false
				continue
			fi
			echo "$line"
		done <"$plans_file" >"$temp_file"
		rm -f "$pcf"
		mv "$temp_file" "$plans_file"
		print_success "Merged existing plans into Active Plans"
	fi
	print_success "todo/PLANS.md upgraded to TOON-enhanced template"
	return 0
}

_upgrade_config_version() {
	local config_file="$1"
	local av
	av=$(get_version)
	if command -v jq &>/dev/null; then
		local tj="${config_file}.tmp"
		jq --arg version "$av" '.templates_version = $version' "$config_file" >"$tj" && mv "$tj" "$config_file"
	else
		if ! grep -q '"templates_version"' "$config_file" 2>/dev/null; then
			local tj="${config_file}.tmp"
			awk -v ver="$av" '/"version":/ { sub(/"version": "[^"]*"/, "\"version\": \"" ver "\",\n  \"templates_version\": \"" ver "\"") } { print }' "$config_file" >"$tj" && mv "$tj" "$config_file"
		else sed_inplace "s/\"templates_version\": \"[^\"]*\"/\"templates_version\": \"$av\"/" "$config_file" 2>/dev/null || true; fi
	fi
	return 0
}

# Upgrade planning files to latest templates
cmd_upgrade_planning() {
	local force=false backup=true dry_run=false
	while [[ $# -gt 0 ]]; do
		case "$1" in --force | -f)
			force=true
			shift
			;;
		--no-backup)
			backup=false
			shift
			;;
		--dry-run | -n)
			dry_run=true
			shift
			;;
		*) shift ;; esac
	done
	print_header "Upgrade Planning Files"
	echo ""
	git rev-parse --is-inside-work-tree &>/dev/null || {
		print_error "Not in a git repository"
		return 1
	}
	[[ "$dry_run" != "true" ]] && { check_protected_branch "chore" "upgrade-planning" || return 1; }
	local project_root
	project_root=$(git rev-parse --show-toplevel)
	_upgrade_validate "$project_root" || return 1
	local todo_file="$project_root/TODO.md" plans_file="$project_root/todo/PLANS.md"
	local todo_template="$AGENTS_DIR/templates/todo-template.md" plans_template="$AGENTS_DIR/templates/plans-template.md"
	local needs_upgrade=false todo_needs=false plans_needs=false
	_upgrade_check_version "$todo_file" "$todo_template" "TODO.md" && {
		todo_needs=true
		needs_upgrade=true
	}
	_upgrade_check_version "$plans_file" "$plans_template" "todo/PLANS.md" && {
		plans_needs=true
		needs_upgrade=true
	}
	[[ "$needs_upgrade" == "false" ]] && {
		echo ""
		print_success "Planning files are up to date!"
		return 0
	}
	echo ""
	if [[ "$dry_run" == "true" ]]; then
		print_info "Dry run - no changes will be made"
		echo ""
		[[ "$todo_needs" == "true" ]] && echo "  Would upgrade: TODO.md"
		[[ "$plans_needs" == "true" ]] && echo "  Would upgrade: todo/PLANS.md"
		return 0
	fi
	if [[ "$force" == "false" ]]; then
		echo "Files to upgrade:"
		[[ "$todo_needs" == "true" ]] && echo "  - TODO.md"
		[[ "$plans_needs" == "true" ]] && echo "  - todo/PLANS.md"
		echo ""
		echo "This will:"
		echo "  1. Extract existing tasks from current files"
		echo "  2. Create backups (.bak files)"
		echo "  3. Apply new TOON-enhanced templates"
		echo "  4. Merge existing tasks into new structure"
		echo ""
		read -r -p "Continue? [y/N] " response
		[[ ! "$response" =~ ^[Yy]$ ]] && {
			print_info "Upgrade cancelled"
			return 0
		}
	fi
	echo ""
	[[ "$todo_needs" == "true" ]] && _upgrade_todo "$todo_file" "$todo_template" "$backup"
	[[ "$plans_needs" == "true" ]] && _upgrade_plans "$plans_file" "$plans_template" "$backup" "$project_root"
	_upgrade_config_version "$project_root/.aidevops.json"
	echo ""
	print_success "Planning files upgraded!"
	echo ""
	echo "Next steps:"
	echo "  1. Review the upgraded files"
	echo "  2. Verify your tasks were preserved"
	if [[ "$backup" == "true" ]]; then
		echo "  3. Remove .bak files when satisfied"
		echo ""
		echo "If issues occurred, restore from backups:"
		[[ "$todo_needs" == "true" ]] && echo "  mv TODO.md.bak TODO.md"
		[[ "$plans_needs" == "true" ]] && echo "  mv todo/PLANS.md.bak todo/PLANS.md"
	fi
	return 0
}

# Features command - list available features
cmd_features() {
	print_header "AI DevOps Features"
	echo ""

	echo "Available features for 'aidevops init':"
	echo ""
	echo "  planning       TODO.md and PLANS.md task management"
	echo "                 - Quick task tracking in TODO.md"
	echo "                 - Complex execution plans in todo/PLANS.md"
	echo "                 - PRD and task file generation"
	echo ""
	echo "  git-workflow   Branch management and PR workflows"
	echo "                 - Automatic branch suggestions"
	echo "                 - Preflight quality checks"
	echo "                 - PR creation and review"
	echo ""
	echo "  code-quality   Linting and code auditing"
	echo "                 - ShellCheck, secretlint, pattern checks"
	echo "                 - Remote auditing (CodeRabbit, Codacy, SonarCloud)"
	echo "                 - Code standards compliance"
	echo ""
	echo "  time-tracking  Time estimation and tracking"
	echo "                 - Estimate format: ~4h (ai:2h test:1h)"
	echo "                 - Automatic started:/completed: timestamps"
	echo "                 - Release time summaries"
	echo ""
	echo "  database       Declarative database schema management"
	echo "                 - schemas/ for declarative SQL/TypeScript"
	echo "                 - migrations/ for versioned changes"
	echo "                 - seeds/ for initial/test data"
	echo "                 - Auto-generate migrations on schema diff"
	echo ""
	echo "  beads          Task graph visualization with Beads"
	echo "                 - Dependency tracking (blocked-by:, blocks:)"
	echo "                 - Graph visualization with bd CLI"
	echo "                 - Ready task detection (/ready)"
	echo "                 - Bi-directional sync with TODO.md/PLANS.md"
	echo ""
	echo "  sops           Encrypted config files with SOPS + age"
	echo "                 - Value-level encryption (keys visible, values encrypted)"
	echo "                 - .sops.yaml with age backend (simpler than GPG)"
	echo "                 - Patterns: *.secret.yaml, configs/*.enc.json"
	echo "                 - See: .agents/tools/credentials/sops.md"
	echo ""
	echo "  security       Per-repo security posture assessment"
	echo "                 - GitHub Actions workflow scanning (injection risks)"
	echo "                 - Branch protection verification (PR reviews)"
	echo "                 - Review-bot-gate status check"
	echo "                 - Dependency vulnerability scanning (npm/pip/cargo)"
	echo "                 - Collaborator access audit"
	echo "                 - Re-run anytime: aidevops security audit"
	echo ""
	echo "Extensibility:"
	echo ""
	echo "  plugins        Third-party agent plugins (configured in .aidevops.json)"
	echo "                 - Git repos deployed to ~/.aidevops/agents/<namespace>/"
	echo "                 - Namespaced to avoid collisions with core agents"
	echo "                 - Enable/disable per-plugin without removal"
	echo "                 - See: .agents/aidevops/plugins.md"
	echo ""
	echo "Usage:"
	echo "  aidevops init                    # Enable all features (except sops)"
	echo "  aidevops init planning           # Enable only planning"
	echo "  aidevops init sops               # Enable SOPS encryption"
	echo "  aidevops init security           # Enable security posture checks"
	echo "  aidevops init beads              # Enable beads (includes planning)"
	echo "  aidevops init database           # Enable only database"
	echo "  aidevops init planning,security  # Enable multiple"
	echo ""
}

# Update tools command - check and update installed tools
# Passes all arguments through to tool-version-check.sh
cmd_update_tools() {
	print_header "Tool Version Check"
	echo ""

	local tool_check_script="$AGENTS_DIR/scripts/tool-version-check.sh"

	if [[ ! -f "$tool_check_script" ]]; then
		print_error "Tool version check script not found"
		print_info "Run 'aidevops update' first to get the latest scripts"
		return 1
	fi

	# Pass all arguments through to the script
	bash "$tool_check_script" "$@"
}

# Repos helpers (extracted for complexity reduction)
_repos_list() {
	print_header "Registered AI DevOps Projects"
	echo ""
	init_repos_file
	command -v jq &>/dev/null || {
		print_error "jq required for repo management"
		return 1
	}
	local count
	count=$(jq '.initialized_repos | length' "$REPOS_FILE" 2>/dev/null || echo "0")
	if [[ "$count" == "0" ]]; then
		print_info "No projects registered yet"
		echo ""
		echo "Initialize a project with: aidevops init"
		return 0
	fi
	local current_ver
	current_ver=$(get_version)
	jq -r '.initialized_repos[] | "\(.path)|\(.version)|\(.features | join(","))"' "$REPOS_FILE" 2>/dev/null | while IFS='|' read -r path version features; do
		local name
		name=$(basename "$path")
		local status="✓" status_color="$GREEN"
		[[ "$version" != "$current_ver" ]] && {
			status="↑"
			status_color="$YELLOW"
		}
		[[ ! -d "$path" ]] && {
			status="✗"
			status_color="$RED"
		}
		echo -e "${status_color}${status}${NC} ${BOLD}$name${NC}"
		echo "    Path: $path"
		echo "    Version: $version"
		echo "    Features: $features"
		echo ""
	done
	echo "Legend: ✓ up-to-date  ↑ update available  ✗ not found"
	return 0
}

_repos_add() {
	git rev-parse --is-inside-work-tree &>/dev/null || {
		print_error "Not in a git repository"
		return 1
	}
	local project_root
	project_root=$(git rev-parse --show-toplevel)
	[[ ! -f "$project_root/.aidevops.json" ]] && {
		print_error "No .aidevops.json found - run 'aidevops init' first"
		return 1
	}
	local version features
	if command -v jq &>/dev/null; then
		version=$(jq -r '.version' "$project_root/.aidevops.json" 2>/dev/null || echo "unknown")
		features=$(jq -r '[.features | to_entries[] | select(.value == true) | .key] | join(",")' "$project_root/.aidevops.json" 2>/dev/null || echo "")
	else
		version="unknown"
		features=""
	fi
	register_repo "$project_root" "$version" "$features"
	print_success "Registered $(basename "$project_root")"
	return 0
}

_repos_remove() {
	local repo_path="${1:-}"
	local original_path="$repo_path"
	if [[ -z "$repo_path" ]]; then
		git rev-parse --is-inside-work-tree &>/dev/null && repo_path=$(git rev-parse --show-toplevel) && original_path="$repo_path" || {
			print_error "Specify a repo path or run from within a git repo"
			return 1
		}
	fi
	repo_path=$(cd "$repo_path" 2>/dev/null && pwd -P) || repo_path="$original_path"
	command -v jq &>/dev/null || {
		print_error "jq required for repo management"
		return 1
	}
	local temp_file="${REPOS_FILE}.tmp"
	jq --arg path "$repo_path" '.initialized_repos |= map(select(.path != $path))' "$REPOS_FILE" >"$temp_file" && mv "$temp_file" "$REPOS_FILE"
	print_success "Removed $repo_path from registry"
	return 0
}

_repos_clean() {
	print_info "Cleaning up stale repo entries..."
	command -v jq &>/dev/null || {
		print_error "jq required for repo management"
		return 1
	}
	local removed=0 temp_file="${REPOS_FILE}.tmp"
	while IFS= read -r repo_path; do
		[[ -z "$repo_path" ]] && continue
		if [[ ! -d "$repo_path" ]]; then
			jq --arg path "$repo_path" '.initialized_repos |= map(select(.path != $path))' "$REPOS_FILE" >"$temp_file" && mv "$temp_file" "$REPOS_FILE"
			print_info "Removed: $repo_path"
			removed=$((removed + 1))
		fi
	done < <(get_registered_repos)
	[[ $removed -eq 0 ]] && print_success "No stale entries found" || print_success "Removed $removed stale entries"
	return 0
}

# Repos management command
cmd_repos() {
	local action="${1:-list}"
	case "$action" in
	list | ls) _repos_list ;;
	add) _repos_add ;;
	remove | rm) _repos_remove "${2:-}" ;;
	clean) _repos_clean ;;
	*)
		echo "Usage: aidevops repos <command>"
		echo ""
		echo "Commands:"
		echo "  list     List all registered projects (default)"
		echo "  add      Register current project"
		echo "  remove   Remove project from registry"
		echo "  clean    Remove entries for non-existent projects"
		;;
	esac
}

# Detect command - check for unregistered aidevops repos
cmd_detect() {
	print_header "Detecting AI DevOps Projects"
	echo ""

	# Check current directory first
	local unregistered
	unregistered=$(detect_unregistered_repo)

	if [[ -n "$unregistered" ]]; then
		print_info "Found unregistered aidevops project:"
		echo "  $unregistered"
		echo ""
		read -r -p "Register this project? [Y/n] " response
		response="${response:-y}"
		if [[ "$response" =~ ^[Yy]$ ]]; then
			local version features
			if command -v jq &>/dev/null; then
				version=$(jq -r '.version' "$unregistered/.aidevops.json" 2>/dev/null || echo "unknown")
				features=$(jq -r '[.features | to_entries[] | select(.value == true) | .key] | join(",")' "$unregistered/.aidevops.json" 2>/dev/null || echo "")
			else
				version="unknown"
				features=""
			fi
			register_repo "$unregistered" "$version" "$features"
			print_success "Registered $(basename "$unregistered")"
		fi
		return 0
	fi

	# Scan common locations
	print_info "Scanning for aidevops projects in ~/Git/..."

	local found=0
	local to_register=()

	if [[ -d "$HOME/Git" ]]; then
		while IFS= read -r -d '' aidevops_json; do
			local repo_dir
			repo_dir=$(dirname "$aidevops_json")

			# Check if already registered
			init_repos_file
			if command -v jq &>/dev/null; then
				if ! jq -e --arg path "$repo_dir" '.initialized_repos[] | select(.path == $path)' "$REPOS_FILE" &>/dev/null; then
					to_register+=("$repo_dir")
					found=$((found + 1))
				fi
			fi
		done < <(find "$HOME/Git" -maxdepth 3 -name ".aidevops.json" -print0 2>/dev/null)
	fi

	if [[ $found -eq 0 ]]; then
		print_success "No unregistered aidevops projects found"
		return 0
	fi

	echo ""
	print_info "Found $found unregistered project(s):"
	for repo in "${to_register[@]}"; do
		echo "  - $(basename "$repo") ($repo)"
	done

	echo ""
	read -r -p "Register all? [Y/n] " response
	response="${response:-y}"
	if [[ "$response" =~ ^[Yy]$ ]]; then
		for repo in "${to_register[@]}"; do
			local version features
			if command -v jq &>/dev/null; then
				version=$(jq -r '.version' "$repo/.aidevops.json" 2>/dev/null || echo "unknown")
				features=$(jq -r '[.features | to_entries[] | select(.value == true) | .key] | join(",")' "$repo/.aidevops.json" 2>/dev/null || echo "")
			else
				version="unknown"
				features=""
			fi
			register_repo "$repo" "$version" "$features"
			print_success "Registered $(basename "$repo")"
		done
	fi
	return 0
}

# Skill help text (extracted for complexity reduction)
_skill_help() {
	print_header "Agent Skills Management"
	echo ""
	echo "Import and manage reusable AI agent skills from the community."
	echo "Skills are converted to aidevops format with upstream tracking."
	echo "Telemetry is disabled - no data sent to third parties."
	echo ""
	echo "Usage: aidevops skill <command> [options]"
	echo ""
	echo "Commands:"
	echo "  add <source>     Import a skill from GitHub (saved as *-skill.md)"
	echo "  list             List all imported skills"
	echo "  check            Check for upstream updates"
	echo "  update [name]    Update specific or all skills"
	echo "  remove <name>    Remove an imported skill"
	echo "  scan [name]      Security scan imported skills (Cisco Skill Scanner)"
	echo "  status           Show detailed skill status"
	echo "  generate         Generate SKILL.md stubs for cross-tool discovery"
	echo "  clean            Remove generated SKILL.md stubs"
	echo ""
	echo "Source formats:"
	echo "  owner/repo                    GitHub shorthand"
	echo "  owner/repo/path/to/skill      Specific skill in multi-skill repo"
	echo "  https://github.com/owner/repo Full URL"
	echo ""
	echo "Examples:"
	echo "  aidevops skill add vercel-labs/agent-skills"
	echo "  aidevops skill add anthropics/skills/pdf"
	echo "  aidevops skill add expo/skills --name expo-dev"
	echo "  aidevops skill check"
	echo "  aidevops skill update"
	echo "  aidevops skill scan"
	echo "  aidevops skill scan cloudflare-platform"
	echo "  aidevops skill generate --dry-run"
	echo ""
	echo "Imported skills are saved with a -skill suffix to distinguish"
	echo "from native aidevops subagents (e.g., playwright-skill.md vs playwright.md)."
	echo ""
	echo "Browse community skills: https://skills.sh"
	echo "Agent Skills specification: https://agentskills.io"
	return 0
}

_skill_add_usage() {
	print_error "Source required (owner/repo or URL)"
	echo ""
	echo "Usage: aidevops skill add <source> [options]"
	echo ""
	echo "Examples:"
	echo "  aidevops skill add vercel-labs/agent-skills"
	echo "  aidevops skill add anthropics/skills/pdf"
	echo "  aidevops skill add https://github.com/owner/repo"
	echo ""
	echo "Options:"
	echo "  --name <name>   Override the skill name"
	echo "  --force         Overwrite existing skill"
	echo "  --dry-run       Preview without making changes"
	echo ""
	echo "Browse skills: https://skills.sh"
	return 0
}

# Skill management command
cmd_skill() {
	local action="${1:-help}"
	shift || true
	export DISABLE_TELEMETRY=1 DO_NOT_TRACK=1 SKILLS_NO_TELEMETRY=1
	local add_skill_script="$AGENTS_DIR/scripts/add-skill-helper.sh"
	local update_skill_script="$AGENTS_DIR/scripts/skill-update-helper.sh"
	case "$action" in
	add | a)
		if [[ $# -lt 1 ]]; then
			_skill_add_usage
			return 1
		fi
		[[ ! -f "$add_skill_script" ]] && {
			print_error "add-skill-helper.sh not found"
			print_info "Run 'aidevops update' to get the latest scripts"
			return 1
		}
		bash "$add_skill_script" add "$@"
		;;
	list | ls | l)
		[[ ! -f "$add_skill_script" ]] && {
			print_error "add-skill-helper.sh not found"
			return 1
		}
		bash "$add_skill_script" list
		;;
	check | c)
		[[ ! -f "$update_skill_script" ]] && {
			print_error "skill-update-helper.sh not found"
			return 1
		}
		bash "$update_skill_script" check "$@"
		;;
	update | u)
		[[ ! -f "$update_skill_script" ]] && {
			print_error "skill-update-helper.sh not found"
			return 1
		}
		bash "$update_skill_script" update "$@"
		;;
	remove | rm)
		[[ $# -lt 1 ]] && {
			print_error "Skill name required"
			echo "Usage: aidevops skill remove <name>"
			return 1
		}
		[[ ! -f "$add_skill_script" ]] && {
			print_error "add-skill-helper.sh not found"
			return 1
		}
		bash "$add_skill_script" remove "$@"
		;;
	status | s)
		[[ ! -f "$update_skill_script" ]] && {
			print_error "skill-update-helper.sh not found"
			return 1
		}
		bash "$update_skill_script" status "$@"
		;;
	generate | gen | g)
		local gs="$AGENTS_DIR/scripts/generate-skills.sh"
		[[ ! -f "$gs" ]] && {
			print_error "generate-skills.sh not found"
			print_info "Run 'aidevops update' to get the latest scripts"
			return 1
		}
		print_info "Generating SKILL.md stubs for cross-tool discovery..."
		bash "$gs" "$@"
		;;
	scan)
		local ss="$AGENTS_DIR/scripts/security-helper.sh"
		[[ ! -f "$ss" ]] && {
			print_error "security-helper.sh not found"
			print_info "Run 'aidevops update' to get the latest scripts"
			return 1
		}
		bash "$ss" skill-scan "$@"
		;;
	clean)
		local gs="$AGENTS_DIR/scripts/generate-skills.sh"
		[[ ! -f "$gs" ]] && {
			print_error "generate-skills.sh not found"
			return 1
		}
		bash "$gs" --clean "$@"
		;;
	help | --help | -h) _skill_help ;;
	*)
		print_error "Unknown skill command: $action"
		echo "Run 'aidevops skill help' for usage information."
		return 1
		;;
	esac
}

# Plugin management helpers (extracted for complexity reduction)
_PLUGIN_RESERVED="custom draft scripts tools services workflows templates memory plugins seo wordpress aidevops"

_plugin_validate_ns() {
	local ns="$1"
	if [[ ! "$ns" =~ ^[a-z][a-z0-9-]*$ ]]; then
		print_error "Invalid namespace '$ns': must be lowercase alphanumeric with hyphens, starting with a letter"
		return 1
	fi
	local r
	for r in $_PLUGIN_RESERVED; do [[ "$ns" == "$r" ]] && {
		print_error "Namespace '$ns' is reserved."
		return 1
	}; done
	return 0
}

_plugin_field() {
	local pf="$1" n="$2" f="$3"
	jq -r --arg n "$n" --arg f "$f" '.plugins[] | select(.name == $n) | .[$f] // empty' "$pf" 2>/dev/null || echo ""
}

_plugin_add() {
	local pf="$1" ad="$2"
	shift 2
	if [[ $# -lt 1 ]]; then
		print_error "Repository URL required"
		echo ""
		echo "Usage: aidevops plugin add <repo-url> [options]"
		echo ""
		echo "Options:"
		echo "  --namespace <name>   Namespace directory (default: derived from repo name)"
		echo "  --branch <branch>    Branch to track (default: main)"
		echo "  --name <name>        Human-readable name (default: derived from repo)"
		echo ""
		echo "Examples:"
		echo "  aidevops plugin add https://github.com/marcusquinn/aidevops-pro.git --namespace pro"
		echo "  aidevops plugin add https://github.com/marcusquinn/aidevops-anon.git --namespace anon"
		return 1
	fi
	local repo_url="$1"
	shift
	local namespace="" branch="main" plugin_name=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--namespace | --ns)
			namespace="$2"
			shift 2
			;;
		--branch | -b)
			branch="$2"
			shift 2
			;;
		--name | -n)
			plugin_name="$2"
			shift 2
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done
	[[ -z "$namespace" ]] && {
		namespace=$(basename "$repo_url" .git | sed 's/^aidevops-//')
		namespace=$(echo "$namespace" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
	}
	[[ -z "$plugin_name" ]] && plugin_name="$namespace"
	_plugin_validate_ns "$namespace" || return 1
	local existing
	existing=$(jq -r --arg n "$plugin_name" '.plugins[] | select(.name == $n) | .name' "$pf" 2>/dev/null || echo "")
	[[ -n "$existing" ]] && {
		print_error "Plugin '$plugin_name' already exists. Use 'aidevops plugin update $plugin_name' to update."
		return 1
	}
	if [[ -d "$ad/$namespace" ]]; then
		local ns_owner
		ns_owner=$(jq -r --arg ns "$namespace" '.plugins[] | select(.namespace == $ns) | .name' "$pf" 2>/dev/null || echo "")
		[[ -n "$ns_owner" ]] && print_error "Namespace '$namespace' is already used by plugin '$ns_owner'" || {
			print_error "Directory '$ad/$namespace/' already exists"
			echo "  Choose a different namespace with --namespace <name>"
		}
		return 1
	fi
	print_info "Adding plugin '$plugin_name' from $repo_url..."
	print_info "  Namespace: $namespace"
	print_info "  Branch: $branch"
	local clone_dir="$ad/$namespace"
	if ! git clone --branch "$branch" --depth 1 "$repo_url" "$clone_dir" 2>&1; then
		print_error "Failed to clone repository"
		rm -rf "$clone_dir" 2>/dev/null || true
		return 1
	fi
	rm -rf "$clone_dir/.git"
	local tmp="${pf}.tmp"
	jq --arg name "$plugin_name" --arg repo "$repo_url" --arg branch "$branch" --arg ns "$namespace" \
		'.plugins += [{"name": $name, "repo": $repo, "branch": $branch, "namespace": $ns, "enabled": true}]' "$pf" >"$tmp" && mv "$tmp" "$pf"
	local loader="$ad/scripts/plugin-loader-helper.sh"
	[[ -f "$loader" ]] && bash "$loader" hooks "$namespace" init 2>/dev/null || true
	print_success "Plugin '$plugin_name' installed to $clone_dir"
	echo ""
	echo "  Agents available at: ~/.aidevops/agents/$namespace/"
	echo "  Update: aidevops plugin update $plugin_name"
	echo "  Remove: aidevops plugin remove $plugin_name"
	return 0
}

_plugin_list() {
	local pf="$1"
	local count
	count=$(jq '.plugins | length' "$pf" 2>/dev/null || echo "0")
	if [[ "$count" == "0" ]]; then
		echo "No plugins installed."
		echo ""
		echo "Add a plugin: aidevops plugin add <repo-url> --namespace <name>"
		return 0
	fi
	echo "Installed plugins ($count):"
	echo ""
	printf "  %-15s %-10s %-8s %s\n" "NAME" "NAMESPACE" "ENABLED" "REPO"
	printf "  %-15s %-10s %-8s %s\n" "----" "---------" "-------" "----"
	jq -r '.plugins[] | "  \(.name)\t\(.namespace)\t\(.enabled // true)\t\(.repo)"' "$pf" 2>/dev/null |
		while IFS=$'\t' read -r name ns enabled repo; do
			local si="yes"
			[[ "$enabled" == "false" ]] && si="no"
			printf "  %-15s %-10s %-8s %s\n" "$name" "$ns" "$si" "$repo"
		done
	return 0
}

_plugin_update() {
	local pf="$1" ad="$2" target="${3:-}"
	if [[ -n "$target" ]]; then
		local repo ns bn
		repo=$(_plugin_field "$pf" "$target" "repo")
		ns=$(_plugin_field "$pf" "$target" "namespace")
		bn=$(_plugin_field "$pf" "$target" "branch")
		bn="${bn:-main}"
		[[ -z "$repo" ]] && {
			print_error "Plugin '$target' not found"
			return 1
		}
		print_info "Updating plugin '$target'..."
		local cd2="$ad/$ns"
		rm -rf "$cd2"
		if git clone --branch "$bn" --depth 1 "$repo" "$cd2" 2>&1; then
			rm -rf "$cd2/.git"
			print_success "Plugin '$target' updated"
		else
			print_error "Failed to update plugin '$target'"
			return 1
		fi
	else
		local names
		names=$(jq -r '.plugins[] | select(.enabled != false) | .name' "$pf" 2>/dev/null || echo "")
		[[ -z "$names" ]] && {
			echo "No enabled plugins to update."
			return 0
		}
		local failed=0
		while IFS= read -r pn; do
			[[ -z "$pn" ]] && continue
			local pr pns pb
			pr=$(_plugin_field "$pf" "$pn" "repo")
			pns=$(_plugin_field "$pf" "$pn" "namespace")
			pb=$(_plugin_field "$pf" "$pn" "branch")
			pb="${pb:-main}"
			print_info "Updating '$pn'..."
			local pd="$ad/$pns"
			rm -rf "$pd"
			if git clone --branch "$pb" --depth 1 "$pr" "$pd" 2>/dev/null; then
				rm -rf "$pd/.git"
				print_success "  '$pn' updated"
			else
				print_error "  '$pn' failed to update"
				failed=$((failed + 1))
			fi
		done <<<"$names"
		[[ "$failed" -gt 0 ]] && {
			print_warning "$failed plugin(s) failed to update"
			return 1
		}
		print_success "All plugins updated"
	fi
	return 0
}

_plugin_toggle() {
	local pf="$1" ad="$2" tn="$3" action="$4"
	if [[ "$action" == "enable" ]]; then
		local tr
		tr=$(_plugin_field "$pf" "$tn" "repo")
		[[ -z "$tr" ]] && {
			print_error "Plugin '$tn' not found"
			return 1
		}
		local tns
		tns=$(_plugin_field "$pf" "$tn" "namespace")
		local tb
		tb=$(_plugin_field "$pf" "$tn" "branch")
		tb="${tb:-main}"
		local tmp="${pf}.tmp"
		jq --arg n "$tn" '(.plugins[] | select(.name == $n)).enabled = true' "$pf" >"$tmp" && mv "$tmp" "$pf"
		[[ ! -d "$ad/$tns" ]] && {
			print_info "Deploying plugin '$tn'..."
			git clone --branch "$tb" --depth 1 "$tr" "$ad/$tns" 2>/dev/null && rm -rf "$ad/$tns/.git"
		}
		local loader="$ad/scripts/plugin-loader-helper.sh"
		[[ -f "$loader" ]] && bash "$loader" hooks "$tns" init 2>/dev/null || true
		print_success "Plugin '$tn' enabled"
	else
		local tns
		tns=$(_plugin_field "$pf" "$tn" "namespace")
		[[ -z "$tns" ]] && {
			print_error "Plugin '$tn' not found"
			return 1
		}
		local loader="$ad/scripts/plugin-loader-helper.sh"
		[[ -f "$loader" && -d "$ad/$tns" ]] && bash "$loader" hooks "$tns" unload 2>/dev/null || true
		local tmp="${pf}.tmp"
		jq --arg n "$tn" '(.plugins[] | select(.name == $n)).enabled = false' "$pf" >"$tmp" && mv "$tmp" "$pf"
		[[ -d "$ad/${tns:?}" ]] && rm -rf "$ad/${tns:?}"
		print_success "Plugin '$tn' disabled (config preserved)"
	fi
	return 0
}

_plugin_remove() {
	local pf="$1" ad="$2" tn="$3"
	local tns
	tns=$(_plugin_field "$pf" "$tn" "namespace")
	[[ -z "$tns" ]] && {
		print_error "Plugin '$tn' not found"
		return 1
	}
	local loader="$ad/scripts/plugin-loader-helper.sh"
	[[ -f "$loader" && -d "$ad/$tns" ]] && bash "$loader" hooks "$tns" unload 2>/dev/null || true
	[[ -d "$ad/${tns:?}" ]] && {
		rm -rf "$ad/${tns:?}"
		print_info "Removed $ad/$tns/"
	}
	local tmp="${pf}.tmp"
	jq --arg n "$tn" '.plugins = [.plugins[] | select(.name != $n)]' "$pf" >"$tmp" && mv "$tmp" "$pf"
	print_success "Plugin '$tn' removed"
	return 0
}

_plugin_scaffold() {
	local ad="$1" td="${2:-.}" pn="${3:-my-plugin}"
	local ns="${4:-$pn}"
	if [[ "$td" != "." && -d "$td" ]]; then
		local ec
		ec=$(find "$td" -maxdepth 1 -type f | wc -l | tr -d ' ')
		[[ "$ec" -gt 0 ]] && {
			print_error "Directory '$td' already has files. Use an empty directory."
			return 1
		}
	fi
	mkdir -p "$td"
	local tpl="$ad/templates/plugin-template"
	[[ ! -d "$tpl" ]] && {
		print_error "Plugin template not found at $tpl"
		print_info "Run 'aidevops update' to get the latest templates."
		return 1
	}
	local pnu
	pnu=$(echo "$pn" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
	sed -e "s|{{PLUGIN_NAME}}|$pn|g" -e "s|{{PLUGIN_NAME_UPPER}}|$pnu|g" -e "s|{{NAMESPACE}}|$ns|g" -e "s|{{REPO_URL}}|https://github.com/user/aidevops-$ns.git|g" "$tpl/AGENTS.md" >"$td/AGENTS.md"
	sed -e "s|{{PLUGIN_NAME}}|$pn|g" -e "s|{{PLUGIN_DESCRIPTION}}|$pn plugin for aidevops|g" -e "s|{{NAMESPACE}}|$ns|g" "$tpl/main-agent.md" >"$td/$ns.md"
	mkdir -p "$td/$ns"
	sed -e "s|{{PLUGIN_NAME}}|$pn|g" -e "s|{{NAMESPACE}}|$ns|g" "$tpl/example-subagent.md" >"$td/$ns/example.md"
	mkdir -p "$td/scripts"
	if [[ -d "$tpl/scripts" ]]; then
		for hf in "$tpl/scripts"/on-*.sh; do
			[[ -f "$hf" ]] || continue
			local hb
			hb=$(basename "$hf")
			sed -e "s|{{PLUGIN_NAME}}|$pn|g" -e "s|{{NAMESPACE}}|$ns|g" "$hf" >"$td/scripts/$hb"
			chmod +x "$td/scripts/$hb"
		done
	fi
	[[ -f "$tpl/plugin.json" ]] && sed -e "s|{{PLUGIN_NAME}}|$pn|g" -e "s|{{PLUGIN_DESCRIPTION}}|$pn plugin for aidevops|g" -e "s|{{NAMESPACE}}|$ns|g" "$tpl/plugin.json" >"$td/plugin.json"
	print_success "Plugin scaffolded in $td/"
	echo ""
	echo "Structure:"
	echo "  $td/"
	echo "  ├── AGENTS.md              # Plugin documentation"
	echo "  ├── plugin.json            # Plugin manifest"
	echo "  ├── $ns.md           # Main agent"
	echo "  ├── $ns/"
	echo "  │   └── example.md          # Example subagent"
	echo "  └── scripts/"
	echo "      ├── on-init.sh          # Init lifecycle hook"
	echo "      ├── on-load.sh          # Load lifecycle hook"
	echo "      └── on-unload.sh        # Unload lifecycle hook"
	echo ""
	echo "Next steps:"
	echo "  1. Edit plugin.json with your plugin metadata"
	echo "  2. Edit $ns.md with your agent instructions"
	echo "  3. Add subagents to $ns/"
	echo "  4. Push to a git repo"
	echo "  5. Install: aidevops plugin add <repo-url> --namespace $ns"
	return 0
}

_plugin_help() {
	print_header "Plugin Management"
	echo ""
	echo "Manage third-party agent plugins that extend aidevops."
	echo "Plugins deploy to ~/.aidevops/agents/<namespace>/ (isolated from core)."
	echo ""
	echo "Usage: aidevops plugin <command> [options]"
	echo ""
	echo "Commands:"
	echo "  add <repo-url>     Install a plugin from a git repository"
	echo "  list               List installed plugins"
	echo "  update [name]      Update specific or all plugins"
	echo "  enable <name>      Enable a disabled plugin (redeploys files)"
	echo "  disable <name>     Disable a plugin (removes files, keeps config)"
	echo "  remove <name>      Remove a plugin entirely"
	echo "  init [dir] [name] [namespace]  Scaffold a new plugin from template"
	echo ""
	echo "Options for 'add':"
	echo "  --namespace <name>   Directory name under ~/.aidevops/agents/"
	echo "  --branch <branch>    Branch to track (default: main)"
	echo "  --name <name>        Human-readable plugin name"
	echo ""
	echo "Examples:"
	echo "  aidevops plugin add https://github.com/marcusquinn/aidevops-pro.git --namespace pro"
	echo "  aidevops plugin add https://github.com/marcusquinn/aidevops-anon.git --namespace anon"
	echo "  aidevops plugin list"
	echo "  aidevops plugin update"
	echo "  aidevops plugin update pro"
	echo "  aidevops plugin disable pro"
	echo "  aidevops plugin enable pro"
	echo "  aidevops plugin remove pro"
	echo "  aidevops plugin init ./my-plugin my-plugin my-plugin"
	echo ""
	echo "Plugin docs: ~/.aidevops/agents/aidevops/plugins.md"
	return 0
}

# Plugin management command
cmd_plugin() {
	local action="${1:-help}"
	shift || true
	local pf="$CONFIG_DIR/plugins.json" ad="$AGENTS_DIR"
	mkdir -p "$CONFIG_DIR"
	[[ ! -f "$pf" ]] && echo '{"plugins":[]}' >"$pf"
	case "$action" in
	add | a) _plugin_add "$pf" "$ad" "$@" ;;
	list | ls | l) _plugin_list "$pf" ;;
	update | u) _plugin_update "$pf" "$ad" "$@" ;;
	enable)
		[[ $# -lt 1 ]] && {
			print_error "Plugin name required"
			echo "Usage: aidevops plugin enable <name>"
			return 1
		}
		_plugin_toggle "$pf" "$ad" "$1" enable
		;;
	disable)
		[[ $# -lt 1 ]] && {
			print_error "Plugin name required"
			echo "Usage: aidevops plugin disable <name>"
			return 1
		}
		_plugin_toggle "$pf" "$ad" "$1" disable
		;;
	remove | rm)
		[[ $# -lt 1 ]] && {
			print_error "Plugin name required"
			echo "Usage: aidevops plugin remove <name>"
			return 1
		}
		_plugin_remove "$pf" "$ad" "$1"
		;;
	init) _plugin_scaffold "$ad" "$@" ;;
	help | --help | -h) _plugin_help ;;
	*)
		print_error "Unknown plugin command: $action"
		echo "Run 'aidevops plugin help' for usage information."
		return 1
		;;
	esac
	return 0
}

# Skills discovery command - search, browse, describe installed skills
cmd_skills() {
	local action="${1:-help}"
	shift || true

	local skills_helper="$AGENTS_DIR/scripts/skills-helper.sh"

	if [[ ! -f "$skills_helper" ]]; then
		print_error "skills-helper.sh not found"
		print_info "Run 'aidevops update' to get the latest scripts"
		return 1
	fi

	case "$action" in
	search | s | find | f)
		bash "$skills_helper" search "$@"
		;;
	browse | b)
		bash "$skills_helper" browse "$@"
		;;
	describe | desc | d | show)
		bash "$skills_helper" describe "$@"
		;;
	info | i | meta)
		bash "$skills_helper" info "$@"
		;;
	list | ls | l)
		bash "$skills_helper" list "$@"
		;;
	categories | cats | cat)
		bash "$skills_helper" categories "$@"
		;;
	recommend | rec | suggest)
		bash "$skills_helper" recommend "$@"
		;;
	install | add)
		bash "$skills_helper" install "$@"
		;;
	registry | online)
		bash "$skills_helper" registry "$@"
		;;
	help | --help | -h)
		print_header "Skill Discovery & Exploration"
		echo ""
		echo "Discover, explore, and get recommendations for installed skills."
		echo "For importing/managing skills, use: aidevops skill <cmd>"
		echo ""
		echo "Usage: aidevops skills <command> [options]"
		echo ""
		echo "Commands:"
		echo "  search <query>          Search installed skills by keyword"
		echo "  search --registry <q>   Search the public skills.sh registry (online)"
		echo "  browse [category]       Browse skills by category"
		echo "  describe <name>         Show detailed skill description"
		echo "  info <name>             Show skill metadata (path, source, model tier)"
		echo "  list [filter]           List skills (--imported, --native, --all)"
		echo "  categories              List all categories with skill counts"
		echo "  recommend <task>        Suggest skills for a task description"
		echo "  install <owner/repo@s>  Install a skill from the public registry"
		echo ""
		echo "Options:"
		echo "  --json                  Output in JSON format (for scripting)"
		echo "  --registry, --online    Search the public skills.sh registry"
		echo ""
		echo "Examples:"
		echo "  aidevops skills search \"browser automation\""
		echo "  aidevops skills search --registry \"seo\""
		echo "  aidevops skills browse tools"
		echo "  aidevops skills browse tools/browser"
		echo "  aidevops skills describe playwright"
		echo "  aidevops skills info seo-audit-skill"
		echo "  aidevops skills list --imported"
		echo "  aidevops skills categories"
		echo "  aidevops skills recommend \"deploy a Next.js app\""
		echo "  aidevops skills install vercel-labs/agent-browser@agent-browser"
		echo ""
		echo "See also: aidevops skill help  (import/manage skills)"
		;;
	*)
		# Treat unknown action as a search query
		bash "$skills_helper" search "$action $*"
		;;
	esac
}

# Help text helpers (extracted for complexity reduction)
_help_commands() {
	echo "Commands:"
	echo "  init [features]    Initialize aidevops in current project"
	echo "  upgrade-planning   Upgrade TODO.md/PLANS.md to latest templates"
	echo "  features           List available features for init"
	echo "  skill <cmd>        Manage agent skills (add/list/check/update/remove)"
	echo "  skills <cmd>       Discover skills (search/browse/describe/recommend)"
	echo "  plugin <cmd>       Manage plugins (add/list/update/enable/disable/remove)"
	echo "  status             Check installation status of all components"
	echo "  doctor             Detect duplicate installs and PATH conflicts (--fix to resolve)"
	echo "  update             Update aidevops to the latest version (alias: upgrade)"
	echo "  upgrade            Alias for update"
	echo "  pulse <cmd>        Session-based pulse control (start/stop/status)"
	echo "  auto-update <cmd>  Manage automatic update polling (enable/disable/status)"
	echo "  repo-sync <cmd>    Daily git pull for repos in parent dirs (enable/disable/status/dirs)"
	echo "  update-tools       Check for outdated tools (--update to auto-update)"
	echo "  repos [cmd]        Manage registered projects (list/add/remove/clean)"
	echo "  model-accounts-pool OAuth account pool (list/check/add/rotate/reset-cooldowns)"
	echo "  opencode-sandbox   Test OpenCode versions in isolation (install/run/check/clean)"
	echo "  security [cmd]     Full security assessment (posture + hygiene + supply chain)"
	echo "  ip-check <cmd>     IP reputation checks (check/batch/report/providers)"
	echo "  secret <cmd>       Manage secrets (set/list/run/init/import/status)"
	echo "  config <cmd>       Feature toggles (list/get/set/reset/path/help)"
	echo "  stats <cmd>        LLM usage analytics (summary/models/projects/costs/trend)"
	echo "  tabby <cmd>        Manage Tabby terminal profiles (sync/status/zshrc/help)"
	echo "  detect             Find and register aidevops projects"
	echo "  uninstall          Remove aidevops from your system"
	echo "  version            Show version information"
	echo "  help               Show this help message"
	return 0
}

_help_detailed_sections() {
	echo "Security:"
	echo "  aidevops security            # Run ALL checks (posture + hygiene + supply chain)"
	echo "  aidevops security posture    # Interactive security posture setup (gopass, gh, SSH)"
	echo "  aidevops security status     # Combined posture + hygiene summary"
	echo "  aidevops security scan       # Secret hygiene & supply chain scan"
	echo "  aidevops security scan-pth   # Python .pth file audit (supply chain IoC)"
	echo "  aidevops security scan-secrets # Plaintext credential locations"
	echo "  aidevops security scan-deps  # Unpinned dependency check"
	echo "  aidevops security check      # Per-repo security posture assessment"
	echo "  aidevops security dismiss <id> # Dismiss a security advisory"
	echo ""
	echo "IP Reputation:"
	echo "  aidevops ip-check check <ip> # Check IP reputation across providers"
	echo "  aidevops ip-check batch <f>  # Batch check IPs from file"
	echo "  aidevops ip-check report <ip># Generate markdown report"
	echo "  aidevops ip-check providers  # List available providers"
	echo "  aidevops ip-check cache-stats# Show cache statistics"
	echo ""
	echo "Model Accounts Pool (OAuth):"
	echo "  aidevops model-accounts-pool status            # Pool health at a glance"
	echo "  aidevops model-accounts-pool list              # Per-account detail"
	echo "  aidevops model-accounts-pool check             # Live token validity test"
	echo "  aidevops model-accounts-pool rotate [provider] # Switch to next available account NOW (use when rate-limited)"
	echo "  aidevops model-accounts-pool reset-cooldowns   # Clear rate-limit cooldowns"
	echo "  aidevops model-accounts-pool add anthropic     # Add Claude Pro/Max account"
	echo "  aidevops model-accounts-pool add openai        # Add ChatGPT Plus/Pro account"
	echo "  aidevops model-accounts-pool add cursor        # Add Cursor Pro account"
	echo "  aidevops model-accounts-pool add google        # Add Google AI Pro/Ultra/Workspace account"
	echo "  aidevops model-accounts-pool import claude-cli # Import from Claude CLI auth"
	echo "  aidevops model-accounts-pool assign-pending <provider># Assign stranded token"
	echo "  aidevops model-accounts-pool remove <provider> <email># Remove an account"
	echo ""
	echo "  Auth recovery (run these in order if model is broken):"
	echo "    aidevops model-accounts-pool status          # 1. Check pool health"
	echo "    aidevops model-accounts-pool check           # 2. Test token validity"
	echo "    aidevops model-accounts-pool rotate anthropic# 3. Switch account if rate-limited"
	echo "    aidevops model-accounts-pool reset-cooldowns # 4. Clear cooldowns if all stuck"
	echo "    aidevops model-accounts-pool add anthropic   # 5. Re-add if pool empty"
	echo ""
	echo "Secrets:"
	echo "  aidevops secret set NAME     # Store a secret (hidden input)"
	echo "  aidevops secret list         # List secret names (never values)"
	echo "  aidevops secret run CMD      # Run with secrets injected + redacted"
	echo "  aidevops secret init         # Initialize gopass encrypted store"
	echo "  aidevops secret import       # Import from credentials.sh to gopass"
	echo "  aidevops secret status       # Show backend status"
	echo ""
	echo "Feature Toggles:"
	echo "  aidevops config list         # List all toggles with current values"
	echo "  aidevops config get <key>    # Get a toggle value"
	echo "  aidevops config set <k> <v>  # Set a toggle (true/false)"
	echo "  aidevops config reset [key]  # Reset toggle(s) to defaults"
	echo "  aidevops config path         # Show config file path"
	echo ""
	echo "LLM Stats:"
	echo "  aidevops stats               # Show usage summary (last 30 days)"
	echo "  aidevops stats summary       # Overall usage summary"
	echo "  aidevops stats models        # Per-model breakdown"
	echo "  aidevops stats projects      # Per-project breakdown"
	echo "  aidevops stats costs         # Cost analysis with category breakdown"
	echo "  aidevops stats trend         # Usage trends over time"
	echo "  aidevops stats ingest        # Parse new Claude JSONL log entries"
	echo "  aidevops stats sync-budget   # Sync to budget tracker (t1100)"
	echo ""
	_help_management_sections
	return 0
}

_help_management_sections() {
	echo "Auto-Update:"
	echo "  aidevops auto-update enable  # Poll for updates every 10 min"
	echo "  aidevops auto-update disable # Stop auto-updating"
	echo "  aidevops auto-update status  # Show auto-update state"
	echo "  aidevops auto-update check   # One-shot check and update now"
	echo ""
	echo "Repo Sync:"
	echo "  aidevops repo-sync enable    # Enable daily git pull for repos"
	echo "  aidevops repo-sync disable   # Disable daily sync"
	echo "  aidevops repo-sync status    # Show sync state and last results"
	echo "  aidevops repo-sync check     # One-shot sync all repos now"
	echo "  aidevops repo-sync dirs list # List configured parent directories"
	echo "  aidevops repo-sync dirs add  # Add a parent directory"
	echo "  aidevops repo-sync dirs rm   # Remove a parent directory"
	echo "  aidevops repo-sync config    # Show/edit configuration"
	echo "  aidevops repo-sync logs      # View sync logs"
	echo ""
	echo "Agent Sources (private repos):"
	echo "  aidevops sources add <path>  # Add a local repo as agent source"
	echo "  aidevops sources add-remote <url> # Clone and add remote repo"
	echo "  aidevops sources remove <n>  # Remove a source (keeps agents)"
	echo "  aidevops sources list        # List configured sources"
	echo "  aidevops sources status      # Show sync status"
	echo "  aidevops sources sync        # Sync all sources to custom/"
	echo ""
	echo "Plugins:"
	echo "  aidevops plugin add <url>    # Install a plugin from git repo"
	echo "  aidevops plugin list         # List installed plugins"
	echo "  aidevops plugin update       # Update all plugins"
	echo "  aidevops plugin remove <n>   # Remove a plugin"
	echo ""
	echo "Skill Management:"
	echo "  aidevops skill add <source>  # Import a skill from GitHub"
	echo "  aidevops skill list          # List imported skills"
	echo "  aidevops skill check         # Check for upstream updates"
	echo "  aidevops skill update [name] # Update skills to latest"
	echo "  aidevops skill remove <name> # Remove an imported skill"
	echo ""
	echo "Skill Discovery:"
	echo "  aidevops skills search <q>   # Search skills by keyword"
	echo "  aidevops skills browse       # Browse skills by category"
	echo "  aidevops skills describe <n> # Show skill description"
	echo "  aidevops skills recommend <t># Suggest skills for a task"
	echo "  aidevops skills categories   # List all categories"
	echo ""
	echo "Installation:"
	echo "  npm install -g aidevops && aidevops update      # via npm (recommended)"
	echo "  brew install marcusquinn/tap/aidevops && aidevops update  # via Homebrew"
	echo "  bash <(curl -fsSL https://aidevops.sh/install)                     # manual"
	echo ""
	echo "Documentation: https://github.com/marcusquinn/aidevops"
	return 0
}

# Help command
cmd_help() {
	local version
	version=$(get_version)
	echo "AI DevOps Framework CLI v$version"
	echo ""
	echo "Usage: aidevops <command> [options]"
	echo ""
	_help_commands
	echo ""
	echo "Examples:"
	echo "  aidevops init                # Initialize with all features"
	echo "  aidevops init planning       # Initialize with planning only"
	echo "  aidevops upgrade-planning    # Upgrade planning files to latest"
	echo "  aidevops features            # List available features"
	echo "  aidevops status              # Check what's installed"
	echo "  aidevops doctor              # Find duplicate/conflicting installs"
	echo "  aidevops doctor --fix        # Interactively remove duplicates"
	echo "  aidevops update              # Update framework + check projects"
	echo "  aidevops repos               # List registered projects"
	echo "  aidevops repos add           # Register current project"
	echo "  aidevops detect              # Find unregistered projects"
	echo "  aidevops update-tools        # Check for outdated tools"
	echo "  aidevops update-tools -u     # Update all outdated tools"
	echo "  aidevops uninstall           # Remove aidevops"
	echo ""
	_help_detailed_sections
}

# Version command
cmd_version() {
	local current_version
	current_version=$(get_version)
	local remote_version
	remote_version=$(get_remote_version)

	echo "aidevops $current_version"

	if [[ "$remote_version" != "unknown" && "$current_version" != "$remote_version" ]]; then
		echo "Latest: $remote_version (run 'aidevops update' to upgrade)"
	fi
}

# Helper dispatch (extracted from main for complexity reduction)
_dispatch_helper() {
	local script_name="$1" error_name="$2"
	shift 2
	local hp="$AGENTS_DIR/scripts/$script_name"
	[[ ! -f "$hp" ]] && hp="$INSTALL_DIR/.agents/scripts/$script_name"
	if [[ -f "$hp" ]]; then
		bash "$hp" "$@"
	else
		print_error "$error_name not found. Run: aidevops update"
		exit 1
	fi
	return 0
}

_dispatch_config() {
	local ch="$AGENTS_DIR/scripts/config-helper.sh"
	[[ ! -f "$ch" ]] && ch="$INSTALL_DIR/.agents/scripts/config-helper.sh"
	[[ ! -f "$ch" ]] && ch="$AGENTS_DIR/scripts/feature-toggle-helper.sh"
	[[ ! -f "$ch" ]] && ch="$INSTALL_DIR/.agents/scripts/feature-toggle-helper.sh"
	if [[ -f "$ch" ]]; then
		bash "$ch" "$@"
	else
		print_error "config-helper.sh not found. Run: aidevops update"
		exit 1
	fi
	return 0
}

# Main entry point
main() {
	local command="${1:-help}"

	# Auto-detect unregistered repo on any command (silent check)
	local unregistered
	unregistered=$(detect_unregistered_repo 2>/dev/null) || true
	if [[ -n "$unregistered" && "$command" != "detect" && "$command" != "repos" ]]; then
		echo -e "${YELLOW}[TIP]${NC} This project uses aidevops but isn't registered. Run: aidevops repos add"
		echo ""
	fi

	# Check if agents need updating (skip for update command itself)
	if [[ "$command" != "update" && "$command" != "upgrade" && "$command" != "u" ]]; then
		local cli_version agents_version
		cli_version=$(get_version)
		[[ -f "$AGENTS_DIR/VERSION" ]] && agents_version=$(cat "$AGENTS_DIR/VERSION") || agents_version="not installed"
		if [[ "$agents_version" == "not installed" ]]; then
			echo -e "${YELLOW}[WARN]${NC} Agents not installed. Run: aidevops update"
			echo ""
		elif [[ "$cli_version" != "$agents_version" ]]; then
			echo -e "${YELLOW}[WARN]${NC} Version mismatch - CLI: $cli_version, Agents: $agents_version"
			echo -e "       Run: aidevops update"
			echo ""
		fi
	fi

	shift || true
	case "$command" in
	init | i) cmd_init "$@" ;;
	features | f) cmd_features ;;
	status | s) cmd_status ;;
	update | upgrade | u) cmd_update "$@" ;;
	auto-update | autoupdate) _dispatch_helper "auto-update-helper.sh" "auto-update-helper.sh" "$@" ;;
	repo-sync | reposync) _dispatch_helper "repo-sync-helper.sh" "repo-sync-helper.sh" "$@" ;;
	update-tools | tools) cmd_update_tools "$@" ;;
	upgrade-planning | up) cmd_upgrade_planning "$@" ;;
	repos | projects) cmd_repos "$@" ;;
	skill) cmd_skill "$@" ;;
	skills) cmd_skills "$@" ;;
	sources | agent-sources) _dispatch_helper "agent-sources-helper.sh" "agent-sources-helper.sh" "$@" ;;
	plugin | plugins) cmd_plugin "$@" ;;
	pulse) _dispatch_helper "pulse-session-helper.sh" "pulse-session-helper.sh" "$@" ;;
	security)
		case "${1:-}" in
		"")
			# No args: run ALL security checks (posture + hygiene + advisories)
			echo ""
			echo "Running full security assessment..."
			echo "==================================="
			echo ""
			_dispatch_helper "security-posture-helper.sh" "security-posture-helper.sh" status || true
			echo ""
			_dispatch_helper "secret-hygiene-helper.sh" "secret-hygiene-helper.sh" scan || true
			;;
		scan | scan-secrets | scan-pth | scan-deps | dismiss)
			_dispatch_helper "secret-hygiene-helper.sh" "secret-hygiene-helper.sh" "$@"
			;;
		hygiene)
			shift
			_dispatch_helper "secret-hygiene-helper.sh" "secret-hygiene-helper.sh" "${@:-scan}"
			;;
		posture | setup)
			shift || true
			_dispatch_helper "security-posture-helper.sh" "security-posture-helper.sh" "${@:-setup}"
			;;
		status)
			# Status shows both posture and hygiene summary
			_dispatch_helper "security-posture-helper.sh" "security-posture-helper.sh" status || true
			echo ""
			_dispatch_helper "secret-hygiene-helper.sh" "secret-hygiene-helper.sh" startup-check || true
			;;
		*)
			_dispatch_helper "security-posture-helper.sh" "security-posture-helper.sh" "$@"
			;;
		esac
		;;
	doctor | doc) _dispatch_helper "doctor-helper.sh" "doctor-helper.sh" "$@" ;;
	detect | scan) cmd_detect ;;
	ip-check | ip_check) _dispatch_helper "ip-reputation-helper.sh" "ip-reputation-helper.sh" "$@" ;;
	model-accounts-pool | map) _dispatch_helper "oauth-pool-helper.sh" "oauth-pool-helper.sh" "$@" ;;
	opencode-sandbox | oc-sandbox) _dispatch_helper "opencode-sandbox-helper.sh" "opencode-sandbox-helper.sh" "$@" ;;
	secret | secrets) _dispatch_helper "secret-helper.sh" "secret-helper.sh" "$@" ;;
	stats | observability) _dispatch_helper "observability-helper.sh" "observability-helper.sh" "$@" ;;
	tabby) _dispatch_helper "tabby-helper.sh" "tabby-helper.sh" "$@" ;;
	config | configure) _dispatch_config "$@" ;;
	uninstall | remove) cmd_uninstall ;;
	version | v | -v | --version) cmd_version ;;
	help | h | -h | --help) cmd_help ;;
	*)
		print_error "Unknown command: $command"
		echo ""
		cmd_help
		exit 1
		;;
	esac
}

main "$@"
