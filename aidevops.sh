#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# AI DevOps Framework CLI
# Usage: aidevops <command> [options]
#
# Version: 3.13.0

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
# When running under sudo on Linux, env_reset rewrites HOME to /root/; SUDO_USER
# holds the original username. getent passwd is the canonical resolver on Linux.
# On macOS, sudo preserves HOME by default (env_keep+="HOME MAIL" in /etc/sudoers)
# and getent is not available, so the fallback to $HOME is correct.
# The command -v getent guard MUST be present — omitting it crashes aidevops.sh
# under `set -euo pipefail` on any BSD system and breaks sudo aidevops approve.
# Mirrors the pattern in .agents/scripts/approval-helper.sh:_resolve_real_home().
# Security: no escalation — root already has full filesystem access.
_AIDEVOPS_REAL_HOME="$HOME"
if [[ -n "${SUDO_USER:-}" && "$(id -u)" -eq 0 ]] && command -v getent &>/dev/null; then
	_tmp_real_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
	if [[ -n "$_tmp_real_home" ]]; then
		_AIDEVOPS_REAL_HOME="$_tmp_real_home"
	fi
fi
INSTALL_DIR="$_AIDEVOPS_REAL_HOME/Git/aidevops"
AGENTS_DIR="$_AIDEVOPS_REAL_HOME/.aidevops/agents"
CONFIG_DIR="$_AIDEVOPS_REAL_HOME/.config/aidevops"
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

print_info() {
	local msg="$1"
	echo -e "${BLUE}[INFO]${NC} $msg"
	return 0
}
print_success() {
	local msg="$1"
	echo -e "${GREEN}[OK]${NC} $msg"
	return 0
}
print_warning() {
	local msg="$1"
	echo -e "${YELLOW}[WARN]${NC} $msg"
	return 0
}
print_error() {
	local msg="$1"
	echo -e "${RED}[ERROR]${NC} $msg"
	return 0
}
print_header() {
	local msg="$1"
	echo -e "${BOLD}${CYAN}$msg${NC}"
	return 0
}

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
	local cmd="$1"
	command -v "$cmd" >/dev/null 2>&1
}

# Check if a directory exists
check_dir() {
	local dir="$1"
	[[ -d "$dir" ]]
}

# Check if a file exists
check_file() {
	local file="$1"
	[[ -f "$file" ]]
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

# Source sub-libraries (repo management, init/scaffold, skills/plugins).
# INSTALL_DIR is the canonical location of aidevops.sh (set above).
# Using INSTALL_DIR rather than BASH_SOURCE[0] because aidevops is installed
# as a symlink at /usr/local/bin/aidevops → $INSTALL_DIR/aidevops.sh;
# dirname(BASH_SOURCE[0]) resolves to /usr/local/bin, not $INSTALL_DIR.
# shellcheck source=./aidevops-repos-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $INSTALL_DIR
source "${INSTALL_DIR}/aidevops-repos-lib.sh"
# shellcheck source=./aidevops-init-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $INSTALL_DIR
source "${INSTALL_DIR}/aidevops-init-lib.sh"
# shellcheck source=./aidevops-skills-plugin-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $INSTALL_DIR
source "${INSTALL_DIR}/aidevops-skills-plugin-lib.sh"

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
	print_header "Commit Signing"
	local signing_format signing_key signing_enabled
	signing_format=$(git config --global gpg.format 2>/dev/null || echo "")
	signing_key=$(git config --global user.signingkey 2>/dev/null || echo "")
	signing_enabled=$(git config --global commit.gpgsign 2>/dev/null || echo "")
	if [[ "$signing_format" == "ssh" && -n "$signing_key" && "$signing_enabled" == "true" ]]; then
		print_success "SSH commit signing enabled"
		if check_file "$HOME/.ssh/allowed_signers"; then
			print_success "Allowed signers file configured"
		else
			print_warning "No allowed_signers file — run: aidevops signing setup"
		fi
	else
		print_warning "Commit signing not configured — run: aidevops signing setup"
	fi
	echo ""
	# t2424/GH#20030: Pulse operational counters (pre-dispatch aborts, etc.)
	local stats_helper="$AGENTS_DIR/scripts/pulse-stats-helper.sh"
	if [[ -x "$stats_helper" ]]; then
		print_header "Pulse Stats"
		"$stats_helper" status 2>/dev/null || print_info "  (no stats recorded yet)"
		echo ""
	fi
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
# Self-heal broken OpenCode runtime symlinks (t2172). A single dangling
# symlink in ~/.config/opencode/{command,agent,skills,tool}/ blocks new
# OpenCode sessions with "Failed to parse command ...". Running on every
# update is cheap (find+rm on 4 small dirs) and catches orphans left
# behind when users delete private agent source clones without going
# through `agent-sources-helper.sh remove`. Fail-open — must never
# break the update cron.
_update_sweep_opencode_symlinks() {
	local sym_helper="${HOME}/.aidevops/agents/scripts/agent-sources-helper.sh"
	[[ -x "$sym_helper" ]] || return 0
	"$sym_helper" cleanup-broken-symlinks >/dev/null 2>&1 || true
	return 0
}

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

# t2926 / GH#21102: Re-check setsid on every 'aidevops update' run.
# setsid (from util-linux) is required to detach pulse workers into their own
# process group — without it, every pulse restart sends SIGHUP to its PGID,
# killing in-flight workers. This check runs even when setup.sh is skipped
# (already up-to-date path), so Homebrew drift doesn't silently break workers.
_update_check_setsid() {
	command -v setsid >/dev/null 2>&1 && return 0

	# setsid is missing. On macOS with Homebrew, auto-install util-linux.
	# Use a boolean flag to avoid repeating the OS literal string.
	local _on_mac=false
	[[ "$(uname -s)" == Darwin* ]] && _on_mac=true
	if $_on_mac && command -v brew >/dev/null 2>&1; then
		print_info "setsid not found — installing util-linux for worker PGID isolation (GH#21102)"
		if brew install util-linux 2>&1 | tail -3; then
			local brew_prefix=""
			brew_prefix="$(brew --prefix 2>/dev/null || true)"
			local keg_setsid="${brew_prefix}/opt/util-linux/bin/setsid"
			local link_target="${brew_prefix}/bin/setsid"
			if [[ -x "$keg_setsid" && ! -e "$link_target" ]]; then
				ln -s "$keg_setsid" "$link_target" && \
					print_success "Symlinked setsid: $keg_setsid → $link_target"
			fi
			if command -v setsid >/dev/null 2>&1; then
				print_success "setsid installed at $(command -v setsid) (worker PGID isolation enabled)"
			else
				print_error "util-linux installed but setsid still not in PATH — check brew --prefix"
			fi
		else
			print_error "brew install util-linux failed — workers will share pulse PGID until resolved"
		fi
	elif $_on_mac; then
		print_error "setsid not found — worker isolation broken; install Homebrew then run: brew install util-linux"
	else
		print_error "setsid not found — worker isolation broken; install util-linux via your distro package manager"
	fi

	return 0
}

# Verify supply chain signature after pulling framework updates.
# Checks that the HEAD commit is signed by the trusted maintainer key.
# Non-blocking: warns on failure, does not abort the update.
_update_verify_signature() {
	local signing_helper="$AGENTS_DIR/scripts/signing-setup.sh"

	# Cannot verify if the helper script is not yet deployed
	if [[ ! -f "$signing_helper" ]]; then
		return 0
	fi

	local result
	result=$(bash "$signing_helper" verify-update "$INSTALL_DIR" 2>/dev/null || echo "UNKNOWN")

	case "$result" in
	VERIFIED)
		print_success "Supply chain verified: HEAD commit is signed by trusted maintainer"
		;;
	UNSIGNED)
		print_warning "HEAD commit is not signed — cannot verify supply chain integrity"
		print_info "This is expected for older releases. Signed commits start from v3.6.21+"
		;;
	UNTRUSTED)
		print_warning "HEAD commit is signed but by an untrusted key"
		print_info "Run 'aidevops signing setup' to configure signature verification"
		;;
	BAD_SIGNATURE)
		print_error "HEAD commit has a BAD signature — update may be compromised"
		print_info "Verify manually: cd $INSTALL_DIR && git log --show-signature -1"
		;;
	UNVERIFIABLE)
		# Signing not configured yet — silent, do not nag
		;;
	esac
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
			else
				# t2706: VERSION matches but .deployed-sha may lag HEAD when
				# fixes land between releases. Detect and redeploy on framework
				# code drift (inline so bootstrap doesn't depend on the deployed
				# aidevops-update-check.sh already carrying the same check).
				# Docs-only drift is intentionally skipped — no runtime impact.
				local stamp_file="$HOME/.aidevops/.deployed-sha"
				if [[ -f "$stamp_file" ]]; then
					local deployed_sha has_code_drift=0
					deployed_sha=$(tr -d '[:space:]' <"$stamp_file" 2>/dev/null) || deployed_sha=""
					if [[ -n "$deployed_sha" && "$deployed_sha" != "$local_hash" ]]; then
						# Per Gemini code-review on PR #20342: use git's path filter +
						# `grep -q .` to detect drift across the full set of deploy-affecting
						# paths (not just .agents/ subdirs — also setup.sh, setup-modules/,
						# and aidevops.sh itself, which are deployed/sourced by setup).
						if git -C "$INSTALL_DIR" diff --name-only "$deployed_sha" "$local_hash" -- \
							.agents/scripts/ .agents/agents/ .agents/workflows/ .agents/prompts/ .agents/hooks/ \
							setup.sh setup-modules/ aidevops.sh 2>/dev/null | grep -q .; then
							has_code_drift=1
						fi
						if [[ "$has_code_drift" -eq 1 ]]; then
							print_warning "Deployed scripts drifted (${deployed_sha:0:7}→${local_hash:0:7})"
							print_info "Re-running setup to deploy latest scripts..."
							bash "$INSTALL_DIR/setup.sh" --non-interactive
						fi
					fi
				fi
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
			# Verify supply chain integrity before applying changes
			_update_verify_signature
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
	_update_sweep_opencode_symlinks
	# t2926: Re-check setsid on every update (runs even when setup.sh is skipped).
	_update_check_setsid

	# t2898: When invoked interactively (terminal stdin AND not from the
	# auto-update daemon itself, which sets AIDEVOPS_AUTO_UPDATE=1 in its
	# environment), verify the daemon is healthy and warn if not. The
	# advisory file gets picked up by the next session greeting so the
	# user sees the warning even if they miss this output.
	#
	# Skip in headless / CI runs (no stdin, no TTY) to avoid spurious
	# warnings in setup.sh-driven flows that already do their own check.
	if [[ -t 0 ]] && [[ -z "${AIDEVOPS_AUTO_UPDATE:-}" ]] && [[ "${NON_INTERACTIVE:-false}" != "true" ]]; then
		_update_check_daemon_health
	fi

	# t2914: ensure pulse is running after every update. The existing
	# restart paths (setup.sh:1329, agent-deploy.sh:601) call
	# pulse-lifecycle-helper.sh restart-if-running which is a silent no-op
	# when pulse is dead — so a dead pulse stays dead through any number
	# of subsequent updates. The 'start' subcommand is idempotent
	# (pulse-lifecycle-helper.sh:127-131): no-op when running, starts when
	# dead. This belt-and-braces call after the daemon health check
	# guarantees the pulse is alive when 'aidevops update' returns,
	# regardless of whether scripts were redeployed.
	#
	# Honour AIDEVOPS_SKIP_PULSE_RESTART=1 at the call site (the helper's
	# 'start' subcommand does not check it directly — only 'restart' and
	# 'restart-if-running' do). Non-fatal: a pulse start failure should
	# not fail the update.
	if [[ "${AIDEVOPS_SKIP_PULSE_RESTART:-0}" != "1" ]]; then
		local _pulse_helper="${HOME}/.aidevops/agents/scripts/pulse-lifecycle-helper.sh"
		if [[ -x "$_pulse_helper" ]]; then
			"$_pulse_helper" start >/dev/null 2>&1 || print_warning "Pulse start failed (non-fatal)"
		fi
	fi

	return 0
}

# t2898: post-update daemon health verification (interactive only).
# Side effect: writes ~/.aidevops/advisories/daemon-disabled.advisory when
# the daemon is unhealthy so the session greeting surfaces the warning.
# Cleared (file removed) when the daemon recovers.
_update_check_daemon_health() {
	local helper="$HOME/.aidevops/agents/scripts/auto-update-helper.sh"
	[[ -x "$helper" ]] || return 0
	local advisory_dir="$HOME/.aidevops/advisories"
	local advisory_file="$advisory_dir/daemon-disabled.advisory"

	local hc_rc=0
	"$helper" health-check --quiet >/dev/null 2>&1 || hc_rc=$?

	if [[ "$hc_rc" -eq 0 ]]; then
		# Healthy — clear any stale advisory.
		[[ -f "$advisory_file" ]] && rm -f "$advisory_file"
		return 0
	fi

	# Unhealthy — warn on stderr and write advisory.
	mkdir -p "$advisory_dir" 2>/dev/null || return 0
	local fix_cmd="aidevops auto-update enable"
	[[ "$hc_rc" -eq 1 ]] && fix_cmd="aidevops auto-update check"
	cat >"$advisory_file" <<EOF
auto-update daemon is not running normally on this runner. Without it, this
runner falls behind the fleet and may dispatch workers that fail because of
bugs already fixed upstream. See cross-runner-coordination.md §4.4.

Diagnose: aidevops auto-update health-check
Fix:      ${fix_cmd}
EOF

	if [[ "$hc_rc" -eq 1 ]]; then
		print_warning "Auto-update daemon is stalled. Fix: ${fix_cmd}"
	else
		print_warning "Auto-update daemon is not running. Fix: ${fix_cmd}"
	fi
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

# t2434: Extract lines under "## <section>" until the next "## " header.
# Skips ## Format block entirely (its content is documentation, not tasks).
# Skips fenced code blocks.
# Exact-match on the section header — no regex escaping concerns.
_extract_todo_section() {
	local file="$1" section="$2"
	awk -v target="## $section" '
		/^## Format/ { in_format=1; next }
		in_format && /^## / { in_format=0 }
		in_format { next }
		/^```/ { in_codeblock = !in_codeblock; next }
		in_codeblock { next }
		$0 == target { found=1; next }
		found && /^## / { exit }
		found
	' "$file" 2>/dev/null || echo ""
}

# t2434: Filter stdin, removing only the literal Format-block placeholder IDs
# (tXXX, tYYY, tZZZ). Real-world repos have historic IDs that don't follow the
# strict t<digits> shape (e.g. "t059b", "t043-merge" from webapp) — we must
# preserve those. A blocklist is safer than an allowlist here: extraction
# already skips the Format section, so the filter is a secondary guard rather
# than primary validation.
_filter_todo_placeholders() {
	awk '
		!/^- \[[ x-]\] t/ { print; next }
		{
			id = $0
			sub(/^- \[[ x-]\] /, "", id)
			sub(/ .*/, "", id)
			if (id == "tXXX" || id == "tYYY" || id == "tZZZ") next
			print
		}
	'
}

# t2434: Insert content_file into target_file immediately after the closing
# "-->" of the named TOON marker block (<!--TOON:<tag>...-->).
# Idempotent only in the sense that each call inserts once per marker; repeated
# calls would stack insertions. Intended to be called once per tag per upgrade.
_insert_after_toon_marker() {
	local target_file="$1" toon_tag="$2" content_file="$3"
	local temp_file="${target_file}.insert"
	local marker_open="<!--TOON:${toon_tag}"
	local in_marker=false
	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ "$line" == *"$marker_open"* ]] && in_marker=true
		if [[ "$in_marker" == true && "$line" == "-->" ]]; then
			echo "$line"
			echo ""
			cat "$content_file"
			in_marker=false
			continue
		fi
		echo "$line"
	done <"$target_file" >"$temp_file"
	mv "$temp_file" "$target_file"
}

# t2434: Preserve each of the 6 task sections into $workdir/<tag>.txt for
# later re-insertion after the template is applied. Placeholder filter runs
# per section so Format-block tXXX-style examples never reach the new file.
_upgrade_todo_preserve_sections() {
	local todo_file="$1" workdir="$2"
	local sections=("Ready" "Backlog" "In Progress" "In Review" "Done" "Declined")
	local tags=("ready" "backlog" "in_progress" "in_review" "done" "declined")
	local i=0
	while [[ $i -lt ${#sections[@]} ]]; do
		local section="${sections[$i]}" tag="${tags[$i]}"
		local content
		content=$(_extract_todo_section "$todo_file" "$section")
		if [[ -n "$content" ]]; then
			content=$(printf '%s\n' "$content" | _filter_todo_placeholders)
			[[ -n "$content" ]] && printf '%s\n' "$content" >"$workdir/${tag}.txt"
		fi
		i=$((i + 1))
	done
	return 0
}

# t2434: Re-insert preserved section content after its matching TOON marker
# in the freshly-applied new template. Caller is responsible for counting
# merged tasks from the final file — keeping count out of the hot loop avoids
# subshell/arithmetic edge cases under `set -u` when content contains `GH#`-
# style IDs that don't match a naive `t[0-9]` count pattern.
_upgrade_todo_reinsert_sections() {
	local todo_file="$1" workdir="$2"
	local tags=("ready" "backlog" "in_progress" "in_review" "done" "declined")
	local tag content_file
	for tag in "${tags[@]}"; do
		content_file="$workdir/${tag}.txt"
		[[ -f "$content_file" && -s "$content_file" ]] || continue
		grep -q "<!--TOON:${tag}" "$todo_file" || continue
		_insert_after_toon_marker "$todo_file" "$tag" "$content_file"
	done
	return 0
}

# t2434: Upgrade TODO.md to the latest TOON-enhanced template, preserving
# tasks from all 6 sections (Ready, Backlog, In Progress, In Review, Done,
# Declined). Prior behaviour (GH#20077) only preserved Backlog and silently
# dropped the other 5 sections into TODO.md.bak, losing audit-trail data.
_upgrade_todo() {
	local todo_file="$1" todo_template="$2" backup="$3"
	print_info "Upgrading TODO.md..."
	local workdir=""
	workdir=$(mktemp -d)
	# shellcheck disable=SC2064  # intentional $workdir expansion at trap-set time
	trap "rm -rf \"${workdir}\"" RETURN
	if [[ -f "$todo_file" ]]; then
		_upgrade_todo_preserve_sections "$todo_file" "$workdir"
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
	_upgrade_todo_reinsert_sections "$todo_file" "$workdir"
	local merged=0
	merged=$(grep -cE '^- \[[ x-]\] (t[0-9]|GH#[0-9])' "$todo_file" 2>/dev/null || true)
	merged="${merged:-0}"
	[[ "$merged" -gt 0 ]] && print_success "Merged $merged existing task(s) across sections"
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


# Help text helpers (extracted for complexity reduction)
_help_commands() {
	echo "Commands:"
	echo "  init [features]    Initialize aidevops in current project"
	echo "  init-routines      Scaffold private routines repo (--org <name> | --local)"
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
	echo "  model-accounts-pool OAuth account pool (list/check/diagnose/add/rotate/reset-cooldowns)"
	echo "  client-format      Client request format alignment (extract/check/canary/monitor)"
	echo "  opencode-sandbox   Test OpenCode versions in isolation (install/run/check/clean)"
	echo "  approve <cmd>      Cryptographic issue/PR approval (setup/issue/pr/verify/status)"
	echo "  security [cmd]     Full security assessment (posture + hygiene + supply chain)"
	echo "  contributions      External contributions inbox (bare: status | seed/scan/stop/restart/install/uninstall)"
	echo "  inbox [cmd]        Capture transit zone (bare: status | provision/add/find/digest/help)"
	echo "  email [cmd]        Email mailbox management (mailbox add/list/test/remove)"
	echo "  ip-check <cmd>     IP reputation checks (check/batch/report/providers)"
	echo "  review-gate <cmd>  Configure review_gate.rate_limit_behavior (list/set/unset)"
	echo "  secret <cmd>       Manage secrets (set/list/run/init/import/status)"
	echo "  config <cmd>       Feature toggles (list/get/set/reset/path/help)"
	echo "  knowledge <cmd>    Knowledge plane management (init/status/provision)"
	echo "  stats <cmd>        LLM usage analytics (summary/models/projects/costs/trend)"
	echo "  tabby <cmd>        Manage Tabby terminal profiles (sync/status/zshrc/help)"
	echo "  parent-status <N>  Show decomposition state of parent-task issue #N (alias: ps)"
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
	echo "  aidevops model-accounts-pool diagnose          # Full pipeline diagnostics (pool, plugin, CCH, runtime)"
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
	echo "  Auth troubleshooting (run diagnose first, then recovery if needed):"
	echo "    aidevops model-accounts-pool diagnose        # 0. Full pipeline check (start here)"
	echo "    aidevops model-accounts-pool status          # 1. Check pool health"
	echo "    aidevops model-accounts-pool check           # 2. Test token validity"
	echo "    aidevops model-accounts-pool rotate anthropic# 3. Switch account if rate-limited"
	echo "    aidevops model-accounts-pool reset-cooldowns # 4. Clear cooldowns if all stuck"
	echo "    aidevops model-accounts-pool add anthropic   # 5. Re-add if pool empty"
	echo ""
	echo "Client Format:"
	echo "  aidevops client-format               # Show status + cached constants"
	echo "  aidevops client-format extract        # Re-extract constants from installed CLI"
	echo "  aidevops client-format check          # Verify cache matches installed CLI version"
	echo "  aidevops client-format canary         # Run drift check against real CLI (uses tokens)"
	echo "  aidevops client-format monitor [cmd]  # Traffic capture + diff (requires mitmproxy)"
	echo "  aidevops client-format install-canary # Install daily drift check (launchd)"
	echo ""
	echo "  If requests stop working after a CLI update:"
	echo "    aidevops client-format extract      # 1. Re-extract constants"
	echo "    aidevops client-format canary       # 2. Verify against real CLI"
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
	echo "Knowledge Plane:"
	echo "  aidevops knowledge init repo           # Provision _knowledge/ in current repo"
	echo "  aidevops knowledge init personal       # Provision at ~/.aidevops/.agent-workspace/knowledge/"
	echo "  aidevops knowledge init off            # Disable knowledge plane"
	echo "  aidevops knowledge status              # Show provisioning state"
	echo "  aidevops knowledge provision [path]    # Re-provision (idempotent)"
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

# Emit tip if the current directory has aidevops but isn't registered
_main_check_unregistered() {
	local command="$1"
	local unregistered
	unregistered=$(detect_unregistered_repo 2>/dev/null) || true
	if [[ -n "$unregistered" && "$command" != "detect" && "$command" != "repos" ]]; then
		echo -e "${YELLOW}[TIP]${NC} This project uses aidevops but isn't registered. Run: aidevops repos add"
		echo ""
	fi
	return 0
}

# Warn when CLI and agents versions differ
_main_check_version() {
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
	return 0
}

# Route 'aidevops security [subcommand]' to appropriate helpers
_cmd_security() {
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
	return 0
}

# Route 'aidevops email [subcommand]' to email helpers
_cmd_email() {
	local sub="${1:-help}"
	local _EPH="email-poll-helper.sh"
	shift || true
	case "$sub" in
	mailbox)
		local action="${1:-list}"
		shift || true
		local _EMR_HELPER="email-mailbox-register-helper.sh"
		case "$action" in
		add)      _dispatch_helper "$_EMR_HELPER" "$_EMR_HELPER" add "$@" ;;
		list)     _dispatch_helper "$_EPH" "$_EPH" list "$@" ;;
		test)     _dispatch_helper "$_EPH" "$_EPH" test "$@" ;;
		remove)   _dispatch_helper "$_EMR_HELPER" "$_EMR_HELPER" remove "$@" ;;
		*)
			echo "Usage: aidevops email mailbox <add|list|test|remove>"
			echo ""
			echo "Mailbox subcommands:"
			echo "  add           Interactive: prompt for provider, user, gopass path; test connection"
			echo "  list          Table of mailboxes with last-polled-at and last-error"
			echo "  test <id>     Dry-run fetch (1 message); does not commit state"
			echo "  remove <id>   Un-register a mailbox"
			;;
		esac
		;;
	poll)
		# Direct poll commands forwarded to email-poll-helper.sh
		local poll_action="${1:-tick}"
		shift || true
		_dispatch_helper "$_EPH" "$_EPH" "$poll_action" "$@" ;;
	thread)
		# Thread lookup: email thread <message-id> [knowledge-root]
		local _ETH="email-thread-helper.sh"
		_dispatch_helper "$_ETH" "$_ETH" thread "$@" ;;
	build)
		# Thread rebuild: email build [knowledge-root] [--force]
		local _ETH2="email-thread-helper.sh"
		_dispatch_helper "$_ETH2" "$_ETH2" build "$@" ;;
	filter)
		# Filter rules: email filter tick|add|test|list [knowledge-root]
		local _EFH="email-filter-helper.sh"
		[[ $# -eq 0 ]] && set -- list
		_dispatch_helper "$_EFH" "$_EFH" "$@" ;;
	*)
		echo "Usage: aidevops email <mailbox|poll|thread|build|filter> [subcommand]"
		echo ""
		echo "Email subcommands:"
		echo "  mailbox add              Register a new IMAP mailbox (interactive)"
		echo "  mailbox list             Show all mailboxes + polling status"
		echo "  mailbox test <id>        Dry-run connection test"
		echo "  mailbox remove <id>      Un-register a mailbox"
		echo "  poll tick                Poll all mailboxes now (same as routine r044)"
		echo "  poll backfill <id>       Backfill a mailbox from a given date"
		echo "  thread <message-id>      Look up thread by message-id"
		echo "  build [--force]          Rebuild thread index from email sources"
		echo "  filter list              List filter rules"
		echo "  filter add               Add a new filter rule (interactive)"
		echo "  filter test <rule>       Dry-run rule against last 50 sources"
		echo "  filter tick              Run filter pass (routine r045)"
		;;
	esac
	return 0
}

# Route 'aidevops client-format [subcommand]' to appropriate helpers
_cmd_client_format() {
	case "${1:-status}" in
	extract | refresh)
		_dispatch_helper "cch-extract.sh" "cch-extract.sh" --cache
		;;
	check | verify)
		_dispatch_helper "cch-extract.sh" "cch-extract.sh" --verify
		;;
	canary | test)
		shift || true
		_dispatch_helper "cch-canary.sh" "cch-canary.sh" --verbose "$@"
		;;
	monitor)
		shift || true
		_dispatch_helper "cch-traffic-monitor.sh" "cch-traffic-monitor.sh" "$@"
		;;
	install-canary)
		_dispatch_helper "cch-canary.sh" "cch-canary.sh" --install
		;;
	status | "")
		echo ""
		echo "Client request format alignment"
		echo "==============================="
		echo ""
		_dispatch_helper "cch-extract.sh" "cch-extract.sh" --verify 2>&1 || true
		echo ""
		if [[ -f "$HOME/.aidevops/cch-constants.json" ]]; then
			echo "Cached constants:"
			cat "$HOME/.aidevops/cch-constants.json"
		else
			echo "No cached constants. Run: aidevops client-format extract"
		fi
		;;
	*)
		print_error "Unknown subcommand: $1"
		echo "Usage: aidevops client-format [extract|check|canary|monitor|install-canary|status]"
		exit 1
		;;
	esac
	return 0
}

# Main entry point
main() {
	local command="${1:-help}"

	# Auto-detect unregistered repo on any command (silent check)
	_main_check_unregistered "$command"

	# Check if agents need updating (skip for update command itself)
	if [[ "$command" != "update" && "$command" != "upgrade" && "$command" != "u" ]]; then
		_main_check_version
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
	check-workflows | workflows) _dispatch_helper "check-workflows-helper.sh" "check-workflows-helper.sh" "$@" ;;
	sync-workflows) _dispatch_helper "sync-workflows-helper.sh" "sync-workflows-helper.sh" "$@" ;;
	security) _cmd_security "$@" ;;
	doctor | doc) _dispatch_helper "doctor-helper.sh" "doctor-helper.sh" "$@" ;;
	detect | scan) cmd_detect ;;
	ip-check | ip_check) _dispatch_helper "ip-reputation-helper.sh" "ip-reputation-helper.sh" "$@" ;;
	model-accounts-pool | map) _dispatch_helper "oauth-pool-helper.sh" "oauth-pool-helper.sh" "$@" ;;
	client-format) _cmd_client_format "$@" ;;
	opencode-sandbox | oc-sandbox) _dispatch_helper "opencode-sandbox-helper.sh" "opencode-sandbox-helper.sh" "$@" ;;
	review-gate | review_gate) _dispatch_helper "review-gate-config-helper.sh" "review-gate-config-helper.sh" "$@" ;;
	secret | secrets) _dispatch_helper "secret-helper.sh" "secret-helper.sh" "$@" ;;
	approve) _dispatch_helper "approval-helper.sh" "approval-helper.sh" "$@" ;;
	signing) _dispatch_helper "signing-setup.sh" "signing-setup.sh" "$@" ;;
	contributions | contrib)
		# Bare `aidevops contributions` defaults to status (most common use).
		# Other subcommands (seed, scan, stop, restart, install, uninstall) forward verbatim.
		[[ $# -eq 0 ]] && set -- status
		_dispatch_helper "contribution-watch-helper.sh" "contribution-watch-helper.sh" "$@"
		;;
	inbox)
		# Bare `aidevops inbox` defaults to status (most common use).
		[[ $# -eq 0 ]] && set -- status
		_dispatch_helper "inbox-helper.sh" "inbox-helper.sh" "$@"
		;;
	case | cases)
		# Bare `aidevops case` defaults to list (most common use).
		[[ $# -eq 0 ]] && set -- list
		_dispatch_helper "case-helper.sh" "case-helper.sh" "$@"
		;;
	email) _cmd_email "$@" ;;
	stats | observability) _dispatch_helper "observability-helper.sh" "observability-helper.sh" "$@" ;;
	tabby) _dispatch_helper "tabby-helper.sh" "tabby-helper.sh" "$@" ;;
	init-routines) _dispatch_helper "init-routines-helper.sh" "init-routines-helper.sh" "$@" ;;
	parent-status | ps) _dispatch_helper "parent-status-helper.sh" "parent-status-helper.sh" "$@" ;;
	knowledge) _dispatch_helper "knowledge-helper.sh" "knowledge-helper.sh" "$@" ;;
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
