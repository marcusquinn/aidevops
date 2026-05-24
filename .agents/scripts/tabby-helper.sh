#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# tabby-helper.sh — Generate and sync Tabby terminal profiles from repos.json
#
# Creates a Tabby profile for each repo in repos.json with:
# - Unique bright tab colour (dark-mode friendly)
# - Matching built-in colour scheme (closest hue match)
# - Direct OpenCode launch that leaves a shell open after exit
# - Grouped under "Projects"
#
# Usage:
#   tabby-helper.sh sync          # Sync profiles from repos.json (default)
#   tabby-helper.sh status        # Show current profile status
#   tabby-helper.sh zshrc         # Deprecated no-op (TABBY_AUTORUN is unused)
#   tabby-helper.sh fix-shell     # Ensure default local profile uses /bin/zsh (macOS)
#   tabby-helper.sh fix-appearance # Apply aidevops Tabby UI defaults when unchanged
#   tabby-helper.sh help          # Show usage
#
# Requires: python3 (ships with macOS), repos.json
# Tabby config: ~/Library/Application Support/tabby/config.yaml (macOS)
#               ~/.config/tabby-terminal/config.yaml (Linux)

set -euo pipefail

# --- Constants ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"
REPOS_JSON="${HOME}/.config/aidevops/repos.json"

# Tabby config path (platform-aware)
if [[ -z "${TABBY_CONFIG:-}" ]]; then
	if [[ "$(uname -s)" == "Darwin" ]]; then
		TABBY_CONFIG="${HOME}/Library/Application Support/tabby/config.yaml"
	else
		TABBY_CONFIG="${HOME}/.config/tabby-terminal/config.yaml"
	fi
fi

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
	_info "TABBY_AUTORUN is deprecated; Tabby profiles use direct split args"
	return 0
}

_fix_shell_check_prereqs() {
	# macOS only: after OS updates, Tabby may fall back to /bin/bash when
	# profileDefaults.local.options.command is unset. This ensures the default
	# local profile uses /bin/zsh (the macOS default shell since Catalina).
	if [[ "$(uname -s)" != "Darwin" ]]; then
		_info "fix-shell is macOS-only (zsh is the default shell since Catalina)"
		return 1
	fi

	if [[ ! -f "$TABBY_CONFIG" ]]; then
		return 1
	fi

	return 0
}

_fix_shell_patch_config() {
	# Parses the Tabby YAML with a targeted state machine and inserts
	# /bin/zsh as the default shell while preserving the existing file shape.
	# Prints a single status token: OK, FIXED, SKIP:<shell>, WARN, or INVALID.
	local config_path="$1"
	local current_cmd=""
	current_cmd=$(awk '
		function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
		function key_is(str, key) { return str ~ ("^" key ":[[:space:]]*($|#)") }
		BEGIN { state="seek_pd"; found_options=0; found_command=0 }
		{
			line=$0
			stripped=line
			sub(/^[[:space:]]+/, "", stripped)
			indent=length(line)-length(stripped)

			if (state=="seek_pd" && key_is(stripped, "profileDefaults")) { state="seek_local"; next }
			if (state=="seek_local" && key_is(stripped, "local")) { state="seek_options"; next }
			if (state=="seek_options" && key_is(stripped, "options")) {
				state="in_options"
				found_options=1
				options_indent=indent
				next
			}

			if (state=="in_options") {
				if (stripped !~ /^($|#)/ && indent <= options_indent) {
					state="done"
				}
				if (state=="in_options" && indent == options_indent + 2 && stripped ~ /^command:[[:space:]]*/) {
					value = stripped
					sub(/^command:[[:space:]]*/, "", value)
					sub(/[[:space:]]+#.*$/, "", value)
					value = trim(value)
					if ((value ~ /^\047.*\047$/) || (value ~ /^\".*\"$/)) {
						value = substr(value, 2, length(value)-2)
					}
					print value
					found_command=1
					exit
				}
			}
		}
		END {
			if (found_command==1) {
				exit 0
			}
			if (found_options==1) {
				print "__MISSING__"
			} else {
				print "__WARN__"
			}
		}
	' "$config_path" 2>/dev/null || printf '%s\n' "__WARN__")

	case "$current_cmd" in
	"__WARN__")
		echo "WARN"
		return 0
		;;
	"/bin/zsh")
		echo "OK"
		return 0
		;;
	"" | "__MISSING__" | "null" | "~" | "''" | '""') ;;
	*)
		echo "SKIP:$current_cmd"
		return 0
		;;
	esac

	local tmp_file="${config_path}.tmp.$$"
	if ! awk '
		function key_is(str, key) { return str ~ ("^" key ":[[:space:]]*($|#)") }
		BEGIN {
			state="seek_pd"
			inserted=0
			skip_args=0
		}
		{
			line=$0
			stripped=line
			sub(/^[[:space:]]+/, "", stripped)
			indent=length(line)-length(stripped)

			if (skip_args==1) {
				if (stripped ~ /^($|#)/ || indent > args_indent) {
					next
				}
				skip_args=0
			}

			if (state=="seek_pd" && key_is(stripped, "profileDefaults")) {
				state="seek_local"
				print line
				next
			}

			if (state=="seek_local" && key_is(stripped, "local")) {
				state="seek_options"
				print line
				next
			}

			if (state=="seek_options" && key_is(stripped, "options")) {
				state="in_options"
				options_indent=indent
				child_indent=sprintf("%*s", indent + 2, "")
				print line
				print child_indent "command: /bin/zsh"
				print child_indent "args:"
				print child_indent "  - '\''-l'\''"
				inserted=1
				next
			}

			if (state=="in_options") {
				if (stripped !~ /^($|#)/ && indent <= options_indent) {
					state="done"
					print line
					next
				}
				if (indent == options_indent + 2 && stripped ~ /^command:[[:space:]]*/) {
					next
				}
				if (indent == options_indent + 2 && key_is(stripped, "args")) {
					skip_args=1
					args_indent=indent
					next
				}
			}

			print line
		}
		END {
			if (inserted != 1) {
				exit 2
			}
		}
	' "$config_path" >"$tmp_file"; then
		rm -f "$tmp_file"
		echo "WARN"
		return 0
	fi

	if ! mv "$tmp_file" "$config_path"; then
		rm -f "$tmp_file"
		echo "INVALID:write-failed"
		return 0
	fi

	echo "FIXED"
	return 0
}

_fix_shell_report_result() {
	# Interprets the status token from _fix_shell_patch_config and prints
	# a user-friendly message.
	local result="$1"

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

cmd_fix_shell() {
	# Orchestrator: check prereqs, patch config, report result.
	# Uses targeted text insertion (not full YAML rewrite) to preserve formatting.
	if ! _fix_shell_check_prereqs; then
		return 0
	fi

	local result
	result=$(_fix_shell_patch_config "$TABBY_CONFIG")
	_fix_shell_report_result "$result"

	return 0
}

_fix_appearance_check_prereqs() {
	if [[ ! -f "$TABBY_CONFIG" ]]; then
		return 1
	fi

	if ! command -v python3 >/dev/null 2>&1; then
		_warn "python3 is required to update Tabby appearance defaults"
		return 1
	fi

	return 0
}

_fix_appearance_patch_config() {
	# Adds the aidevops left-tab width CSS only when Tabby's appearance.css is
	# absent or still the upstream placeholder. Existing user CSS is preserved.
	local config_path="$1"

	python3 - "$config_path" <<'PY'
from __future__ import annotations

import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
lines = text.splitlines(keepends=True)
newline = "\n" if text.endswith("\n") else ""

desired_block = [
    "  css: |\n",
    "    /* Widen left-side tab sidebar by 50% (default is 200px). */\n",
    "    .content.tabs-on-left {\n",
    "      --side-tab-width: calc(300px * var(--spaciness));\n",
    "    }\n",
]
desired_marker = "--side-tab-width: calc(300px * var(--spaciness))"
placeholder = "/* * { color: blue !important; } */"


def top_level(line: str) -> bool:
    return bool(line.strip()) and not line.startswith((" ", "\t")) and ":" in line


appearance_start = None
for index, line in enumerate(lines):
    if line.startswith("appearance:"):
        appearance_start = index
        break

if appearance_start is None:
    print("WARN")
    sys.exit(0)

appearance_end = len(lines)
for index in range(appearance_start + 1, len(lines)):
    if top_level(lines[index]):
        appearance_end = index
        break

css_start = None
for index in range(appearance_start + 1, appearance_end):
    stripped = lines[index].lstrip(" ")
    indent = len(lines[index]) - len(stripped)
    if indent == 2 and stripped.startswith("css:"):
        css_start = index
        break

if css_start is None:
    insert_at = appearance_end
    for index in range(appearance_start + 1, appearance_end):
        stripped = lines[index].lstrip(" ")
        indent = len(lines[index]) - len(stripped)
        if indent == 2 and stripped.startswith("tabsLocation:"):
            insert_at = index
            break
    new_lines = lines[:insert_at] + desired_block + lines[insert_at:]
    path.write_text("".join(new_lines) + ("" if new_lines and new_lines[-1].endswith("\n") else newline))
    print("FIXED")
    sys.exit(0)

css_end = css_start + 1
for index in range(css_start + 1, appearance_end):
    stripped = lines[index].lstrip(" ")
    indent = len(lines[index]) - len(stripped)
    if stripped.strip() and indent <= 2:
        break
    css_end = index + 1

css_text = "".join(lines[css_start:css_end])
css_value = lines[css_start].split(":", 1)[1].strip()
inline_value = css_value.strip('"\'')

if desired_marker in css_text:
    print("OK")
elif inline_value in ("", "|", "|-", ">", ">-"):
    body = "".join(lines[css_start + 1:css_end])
    if body.strip() == placeholder:
        path.write_text("".join(lines[:css_start] + desired_block + lines[css_end:]))
        print("FIXED")
    else:
        print("SKIP:custom-css")
elif inline_value == placeholder:
    path.write_text("".join(lines[:css_start] + desired_block + lines[css_end:]))
    print("FIXED")
else:
    print("SKIP:custom-css")
PY

	return 0
}

_fix_appearance_report_result() {
	local result="$1"

	case "$result" in
	OK)
		_success "Tabby left tab width default already applied"
		;;
	FIXED)
		_success "Applied Tabby left tab width default (restart Tabby to apply)"
		;;
	SKIP:custom-css)
		_info "Tabby custom CSS exists — not overriding"
		;;
	WARN)
		_warn "Could not find appearance section in Tabby config"
		;;
	*)
		_warn "Unexpected result from fix-appearance: $result"
		;;
	esac

	return 0
}

cmd_fix_appearance() {
	if ! _fix_appearance_check_prereqs; then
		return 0
	fi

	local result
	result=$(_fix_appearance_patch_config "$TABBY_CONFIG")
	_fix_appearance_report_result "$result"

	return 0
}

cmd_help() {
	echo "tabby-helper.sh — Generate Tabby profiles from repos.json"
	echo ""
	echo "Usage:"
	echo "  tabby-helper.sh sync       Sync profiles from repos.json (create new, skip existing)"
	echo "  tabby-helper.sh status     Show profile status (which repos have profiles)"
	echo "  tabby-helper.sh zshrc      Deprecated no-op (TABBY_AUTORUN is unused)"
	echo "  tabby-helper.sh fix-shell  Ensure default local profile uses /bin/zsh (macOS)"
	echo "  tabby-helper.sh fix-appearance  Apply aidevops Tabby UI defaults when unchanged"
	echo "  tabby-helper.sh help       Show this help"
	echo ""
	echo "Profiles are created with:"
	echo "  - Random bright tab colour (dark-mode friendly, HSL L:50-70%, S:60-90%)"
	echo "  - Matching Tabby colour scheme (closest hue from built-in presets)"
	echo "  - Direct OpenCode launch that leaves a shell open after exit"
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
	fix-appearance) cmd_fix_appearance ;;
	help | --help | -h) cmd_help ;;
	*)
		_error "Unknown command: $cmd"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
