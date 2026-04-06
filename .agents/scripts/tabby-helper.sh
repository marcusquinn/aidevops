#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# tabby-helper.sh — Generate and sync Tabby terminal profiles from repos.json
#
# Creates a Tabby profile for each repo in repos.json with:
# - Unique bright tab colour (dark-mode friendly)
# - Matching built-in colour scheme (closest hue match)
# - TABBY_AUTORUN=opencode env var for TUI compatibility
# - Grouped under "Projects"
#
# Usage:
#   tabby-helper.sh sync          # Sync profiles from repos.json (default)
#   tabby-helper.sh status        # Show current profile status
#   tabby-helper.sh zshrc         # Install TABBY_AUTORUN hook in .zshrc
#   tabby-helper.sh fix-shell     # Ensure default local profile uses /bin/zsh (macOS)
#   tabby-helper.sh help          # Show usage
#
# Requires: python3 (ships with macOS), repos.json
# Tabby config: ~/Library/Application Support/tabby/config.yaml (macOS)
#               ~/.config/tabby-terminal/config.yaml (Linux)

set -euo pipefail

# --- Constants ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_JSON="${HOME}/.config/aidevops/repos.json"

# Tabby config path (platform-aware)
if [[ "$(uname -s)" == "Darwin" ]]; then
	TABBY_CONFIG="${HOME}/Library/Application Support/tabby/config.yaml"
else
	TABBY_CONFIG="${HOME}/.config/tabby-terminal/config.yaml"
fi

# --- Colours ---
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
_success() { echo -e "${GREEN}[OK]${NC} $1"; }
_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# --- Preflight checks ---
_check_prereqs() {
	if ! command -v python3 >/dev/null 2>&1; then
		_error "python3 is required but not found"
		return 1
	fi

	if [[ ! -f "$REPOS_JSON" ]]; then
		_error "repos.json not found at $REPOS_JSON"
		_info "Run 'aidevops init' in your projects first"
		return 1
	fi

	if [[ ! -f "$TABBY_CONFIG" ]]; then
		_warn "Tabby config not found at $TABBY_CONFIG"
		_info "Install Tabby from https://tabby.sh or skip this step"
		return 1
	fi

	return 0
}

# --- Commands ---

cmd_sync() {
	if ! _check_prereqs; then
		return 1
	fi

	_info "Syncing Tabby profiles from repos.json..."

	# Back up config before modifying
	local backup="${TABBY_CONFIG}.backup"
	cp "$TABBY_CONFIG" "$backup"

	local result
	if result=$(python3 "${SCRIPT_DIR}/tabby-profile-sync.py" \
		--repos-json "$REPOS_JSON" \
		--tabby-config "$TABBY_CONFIG" 2>&1); then
		echo "$result"
		_success "Tabby profiles synced. Restart Tabby or open new tabs to see changes."
	else
		_error "Profile sync failed:"
		echo "$result" >&2
		_info "Config backup at: $backup"
		return 1
	fi

	return 0
}

cmd_status() {
	if ! _check_prereqs; then
		return 1
	fi

	python3 "${SCRIPT_DIR}/tabby-profile-sync.py" \
		--repos-json "$REPOS_JSON" \
		--tabby-config "$TABBY_CONFIG" \
		--status-only

	return 0
}

cmd_zshrc() {
	local zshrc="${HOME}/.zshrc"
	local marker="# Tabby profile autorun"

	if [[ ! -f "$zshrc" ]]; then
		_warn "No .zshrc found — creating one"
		touch "$zshrc"
	fi

	if grep -qF "$marker" "$zshrc" 2>/dev/null; then
		_success "TABBY_AUTORUN hook already in .zshrc"
		return 0
	fi

	cat >>"$zshrc" <<'ZSHRC_BLOCK'

# Tabby profile autorun - launches command after shell is fully interactive
# This allows TUI apps (opencode) to work with Tabby's custom colour schemes
_tabby_autorun() {
  if [[ -n "${TABBY_AUTORUN:-}" ]]; then
    local cmd="$TABBY_AUTORUN"
    unset TABBY_AUTORUN
    eval "$cmd"
  fi
}
_tabby_autorun
ZSHRC_BLOCK

	_success "Added TABBY_AUTORUN hook to .zshrc"
	return 0
}

cmd_fix_shell() {
	# macOS only: after OS updates, Tabby may fall back to /bin/bash when
	# profileDefaults.local.options.command is unset. This ensures the default
	# local profile uses /bin/zsh (the macOS default shell since Catalina).
	# Uses targeted text insertion (not full YAML rewrite) to preserve formatting.
	if [[ "$(uname -s)" != "Darwin" ]]; then
		_info "fix-shell is macOS-only (zsh is the default shell since Catalina)"
		return 0
	fi

	if [[ ! -f "$TABBY_CONFIG" ]]; then
		return 0
	fi

	if ! command -v python3 >/dev/null 2>&1; then
		_warn "python3 required for fix-shell — skipping"
		return 1
	fi

	local result
	result=$(
		python3 - "$TABBY_CONFIG" <<'PYEOF'
import sys
import yaml

config_path = sys.argv[1]

with open(config_path) as f:
    raw = f.read()

data = yaml.safe_load(raw)

# Navigate to profileDefaults.local.options
pd = data.get("profileDefaults") or {}
local_conf = pd.get("local") or {}
options = local_conf.get("options") or {}
current_cmd = options.get("command", "")

if current_cmd == "/bin/zsh":
    print("OK")
    sys.exit(0)

if current_cmd and current_cmd != "/bin/zsh":
    # User has explicitly set a different shell — respect that
    print("SKIP:" + current_cmd)
    sys.exit(0)

# command is missing — insert via targeted text edit to preserve formatting
lines = raw.split("\n")
state = "seek_pd"
result_lines = []
fixed = False

for line in lines:
    stripped = line.lstrip()
    indent = len(line) - len(stripped)

    if state == "seek_pd" and stripped == "profileDefaults:":
        state = "seek_local"
        result_lines.append(line)
        continue

    if state == "seek_local" and stripped.startswith("local:"):
        state = "seek_options"
        result_lines.append(line)
        continue

    if state == "seek_options" and stripped.startswith("options:"):
        state = "done"
        child_indent = " " * (indent + 2)
        result_lines.append(line)
        result_lines.append(child_indent + "command: /bin/zsh")
        result_lines.append(child_indent + "args:")
        result_lines.append(child_indent + "  - '-l'")
        fixed = True
        continue

    result_lines.append(line)

if not fixed:
    print("WARN")
    sys.exit(1)

# Validate before writing
new_text = "\n".join(result_lines)
try:
    yaml.safe_load(new_text)
except yaml.YAMLError as e:
    print("INVALID:" + str(e))
    sys.exit(1)

with open(config_path, "w") as f:
    f.write(new_text)
print("FIXED")
sys.exit(0)
PYEOF
	) 2>&1

	case "$result" in
	OK)
		_success "Tabby default profile already uses /bin/zsh"
		;;
	FIXED)
		_success "Set Tabby default profile shell to /bin/zsh (restart Tabby to apply)"
		;;
	SKIP:*)
		local other_shell="${result#SKIP:}"
		_info "Tabby default profile uses $other_shell — not overriding"
		;;
	WARN)
		_warn "Could not find profileDefaults.local.options in Tabby config"
		;;
	INVALID:*)
		_error "Generated invalid YAML — config not modified"
		;;
	*)
		_warn "Unexpected result from fix-shell: $result"
		;;
	esac

	return 0
}

cmd_help() {
	echo "tabby-helper.sh — Generate Tabby profiles from repos.json"
	echo ""
	echo "Usage:"
	echo "  tabby-helper.sh sync       Sync profiles from repos.json (create new, skip existing)"
	echo "  tabby-helper.sh status     Show profile status (which repos have profiles)"
	echo "  tabby-helper.sh zshrc      Install TABBY_AUTORUN hook in .zshrc"
	echo "  tabby-helper.sh fix-shell  Ensure default local profile uses /bin/zsh (macOS)"
	echo "  tabby-helper.sh help       Show this help"
	echo ""
	echo "Profiles are created with:"
	echo "  - Random bright tab colour (dark-mode friendly, HSL L:50-70%, S:60-90%)"
	echo "  - Matching Tabby colour scheme (closest hue from built-in presets)"
	echo "  - TABBY_AUTORUN=opencode for OpenCode TUI compatibility"
	echo "  - Grouped under 'Projects'"
	echo ""
	echo "Existing profiles (matched by cwd path) are never overwritten."
	return 0
}

# --- Main ---
main() {
	local cmd="${1:-sync}"

	case "$cmd" in
	sync) cmd_sync ;;
	status) cmd_status ;;
	zshrc) cmd_zshrc ;;
	fix-shell) cmd_fix_shell ;;
	help | --help | -h) cmd_help ;;
	*)
		_error "Unknown command: $cmd"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
