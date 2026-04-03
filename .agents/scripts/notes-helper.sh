#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail

# Notes Helper — cross-platform CLI for agent use
#
# Backends:
#   macOS:  osascript via Notes.app
#   Linux:  nb (CLI notebook, brew install nb)
#
# Usage: ./notes-helper.sh [command] [args] [options]
# Commands:
#   setup                - Check/install backend, verify access
#   folders              - List note folders/notebooks
#   show [filter]        - Show recent notes (today|week|all)
#   add <title> [opts]   - Create a note
#   view <title|id>      - View a specific note
#   search <query>       - Search notes
#   delete <title|id>    - Delete a note (with confirmation)
#   sync                 - Sync (nb only; macOS syncs automatically)
#   help                 - Show this help
#
# Author: AI DevOps Framework
# Version: 1.0.0
# License: MIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

init_log_file

# =============================================================================
# Platform Detection
# =============================================================================

detect_platform() {
	local os
	os="$(uname -s)"
	case "$os" in
	Darwin) echo "macos" ;;
	Linux) echo "linux" ;;
	MINGW* | MSYS* | CYGWIN*)
		echo "windows"
		;;
	*)
		print_error "Unsupported platform: ${os}"
		return 1
		;;
	esac
	return 0
}

PLATFORM="$(detect_platform)" || exit 1

# =============================================================================
# macOS Backend (osascript / Notes.app)
# =============================================================================

macos_check_ready() {
	# Notes.app is always available on macOS
	return 0
}

macos_setup() {
	print_info "Checking Notes access (macOS)..."
	local count
	count="$(osascript -e 'tell application "Notes" to count of notes' 2>&1)" || true
	if [[ "$count" =~ ^[0-9]+$ ]]; then
		print_success "Notes access: authorized (${count} notes)"
		print_info "Available folders:"
		osascript -e 'tell application "Notes" to get name of every folder' 2>&1 || true
	else
		print_warning "Notes access may need authorization."
		print_info "System Settings > Privacy & Security > Automation > enable Notes for your terminal app"
		return 1
	fi
	print_success "macOS Notes setup complete."
	return 0
}

macos_folders() {
	osascript -e 'tell application "Notes" to get name of every folder' 2>&1
	return 0
}

_macos_show_recent() {
	local folder_filter="$1"
	local days_back="$2"
	local empty_msg="$3"

	osascript -e "
tell application \"Notes\"
set startDate to current date
set time of startDate to 0
set startDate to startDate - ${days_back} * days
set output to {}
repeat with n in (every note ${folder_filter})
try
if modification date of n >= startDate then
set end of output to (modification date of n as text) & \" | \" & name of n
end if
end try
end repeat
if (count of output) = 0 then return \"${empty_msg}\"
return output as text
end tell" 2>&1
	return 0
}

_macos_show_all() {
	local folder_filter="$1"

	osascript -e "
tell application \"Notes\"
set output to {}
set noteList to every note ${folder_filter}
set noteCount to count of noteList
set maxNotes to 50
if noteCount < maxNotes then set maxNotes to noteCount
repeat with i from 1 to maxNotes
set n to item i of noteList
try
set end of output to (modification date of n as text) & \" | \" & name of n
end try
end repeat
if (count of output) = 0 then return \"No notes found.\"
return output as text
end tell" 2>&1
	return 0
}

macos_show() {
	local filter="$1"
	local folder="$2"

	local folder_filter=""
	[[ -n "$folder" ]] && folder_filter="of folder \"${folder}\""

	case "$filter" in
	today) _macos_show_recent "$folder_filter" 0 "No notes modified today." ;;
	week) _macos_show_recent "$folder_filter" 7 "No notes modified this week." ;;
	*) _macos_show_all "$folder_filter" ;;
	esac
	return 0
}

macos_add() {
	local title="$1" body="$2" folder="$3"

	local folder_clause="folder \"Notes\""
	[[ -n "$folder" ]] && folder_clause="folder \"${folder}\""

	# Notes.app body is HTML — wrap plain text in basic HTML
	local html_body=""
	if [[ -n "$body" ]]; then
		html_body="$(printf '%s' "$body" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' | sed 's/$/<br>/' | tr -d '\n')"
	fi

	osascript -e "
tell application \"Notes\"
make new note at ${folder_clause} with properties {name:\"${title}\", body:\"<h1>${title}</h1>${html_body}\"}
end tell" 2>&1
	return $?
}

macos_view() {
	local name="$1"
	osascript -e "
tell application \"Notes\"
set matchList to every note whose name is \"${name}\"
if (count of matchList) = 0 then
set matchList to every note whose name contains \"${name}\"
end if
if (count of matchList) = 0 then return \"No note found matching: ${name}\"
set n to item 1 of matchList
set output to {\"Title: \" & name of n}
set end of output to \"Modified: \" & (modification date of n as text)
set end of output to \"Created: \" & (creation date of n as text)
try
set end of output to \"Folder: \" & (name of container of n)
end try
set end of output to \"---\"
set end of output to plaintext of n
return output as text
end tell" 2>&1
	return 0
}

macos_search() {
	local query="$1"
	local folder="$2"

	local folder_filter=""
	[[ -n "$folder" ]] && folder_filter="of folder \"${folder}\""

	osascript -e "
tell application \"Notes\"
set output to {}
repeat with n in (every note ${folder_filter})
try
if name of n contains \"${query}\" or plaintext of n contains \"${query}\" then
set end of output to (modification date of n as text) & \" | \" & name of n
end if
end try
end repeat
if (count of output) = 0 then return \"No notes found matching: ${query}\"
return output as text
end tell" 2>&1
	return 0
}

macos_delete() {
	local name="$1"
	osascript -e "
tell application \"Notes\"
set matchList to every note whose name is \"${name}\"
if (count of matchList) = 0 then
set matchList to every note whose name contains \"${name}\"
end if
if (count of matchList) = 0 then return \"No note found matching: ${name}\"
delete item 1 of matchList
end tell" 2>&1
	return $?
}

macos_sync() {
	print_info "macOS syncs Notes automatically via iCloud."
	return 0
}

# =============================================================================
# Linux/Windows Backend (nb)
# =============================================================================

NB_BIN="nb"

linux_check_ready() {
	if ! command -v "$NB_BIN" >/dev/null 2>&1; then
		print_error "nb not found. Install: brew install nb (or see https://xwmx.github.io/nb/)"
		return 1
	fi
	return 0
}

linux_setup() {
	print_info "Checking nb (notes backend)..."

	if command -v "$NB_BIN" >/dev/null 2>&1; then
		local ver
		ver="$("$NB_BIN" version 2>&1 | head -1)"
		print_success "nb installed: ${ver}"
	else
		print_warning "nb not installed"
		if command -v brew >/dev/null 2>&1; then
			read -r -p "Install nb now? [y/N] " answer
			if [[ "$answer" =~ ^[Yy] ]]; then
				brew install nb
				print_success "nb installed"
			else
				print_info "Install manually: brew install nb"
				print_info "Or: pip install nb-cli"
				return 1
			fi
		else
			print_info "Install with: brew install nb"
			print_info "Or see: https://xwmx.github.io/nb/"
			return 1
		fi
	fi

	print_info "Available notebooks:"
	"$NB_BIN" notebooks 2>&1 || true

	print_success "Notes setup complete."
	return 0
}

linux_folders() {
	"$NB_BIN" notebooks 2>&1
	return 0
}

linux_show() {
	local filter="$1"
	local folder="$2"

	local args=()
	if [[ -n "$folder" ]]; then
		args+=("${folder}:")
	fi

	case "$filter" in
	today)
		# nb doesn't have date filters — list recent and let user scan
		"$NB_BIN" list "${args[@]}" --limit 20 --no-id 2>&1 || "$NB_BIN" ls "${args[@]}" 2>&1
		;;
	week)
		"$NB_BIN" list "${args[@]}" --limit 50 --no-id 2>&1 || "$NB_BIN" ls "${args[@]}" 2>&1
		;;
	all | *)
		"$NB_BIN" list "${args[@]}" --no-id 2>&1 || "$NB_BIN" ls "${args[@]}" 2>&1
		;;
	esac
	return 0
}

linux_add() {
	local title="$1" body="$2" folder="$3"

	local args=()

	if [[ -n "$folder" ]]; then
		# Ensure notebook exists, create if not
		"$NB_BIN" notebooks add "$folder" 2>/dev/null || true
		args+=("${folder}:")
	fi

	args+=(--title "$title")

	if [[ -n "$body" ]]; then
		args+=(--content "$body")
	fi

	"$NB_BIN" add "${args[@]}" 2>&1
	return $?
}

linux_view() {
	local name="$1"

	# Try exact match first, then search
	"$NB_BIN" show "$name" --print 2>&1 || {
		local results
		results="$("$NB_BIN" search "$name" --limit 1 2>&1)" || true
		if [[ -n "$results" ]]; then
			echo "$results"
		else
			echo "No note found matching: ${name}"
		fi
	}
	return 0
}

linux_search() {
	local query="$1"
	local folder="$2"

	local args=("$query")
	if [[ -n "$folder" ]]; then
		args+=("${folder}:")
	fi

	"$NB_BIN" search "${args[@]}" 2>&1 || echo "No notes found matching: ${query}"
	return 0
}

linux_delete() {
	local name="$1"
	"$NB_BIN" delete "$name" --force 2>&1
	return $?
}

linux_sync() {
	print_info "Syncing nb notebooks..."
	"$NB_BIN" sync 2>&1
	local rc=$?
	if [[ $rc -eq 0 ]]; then
		print_success "Notebook sync complete"
	else
		print_warning "Notebook sync had issues (exit ${rc}). Check nb remote config."
	fi
	return $rc
}

# =============================================================================
# Platform-Dispatching Commands
# =============================================================================

cmd_setup() {
	print_info "Platform: ${PLATFORM}"
	case "$PLATFORM" in
	macos) macos_setup ;;
	linux | windows) linux_setup ;;
	esac
}

cmd_folders() {
	case "$PLATFORM" in
	macos)
		macos_check_ready || return 1
		macos_folders
		;;
	linux | windows)
		linux_check_ready || return 1
		linux_folders
		;;
	esac
}

cmd_show() {
	case "$PLATFORM" in
	macos) macos_check_ready || return 1 ;;
	linux | windows) linux_check_ready || return 1 ;;
	esac

	local filter="${1:-all}"
	shift || true

	local folder=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--folder | -f)
			folder="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	case "$PLATFORM" in
	macos) macos_show "$filter" "$folder" ;;
	linux | windows) linux_show "$filter" "$folder" ;;
	esac
}

cmd_add() {
	case "$PLATFORM" in
	macos) macos_check_ready || return 1 ;;
	linux | windows) linux_check_ready || return 1 ;;
	esac

	local title="" body="" folder=""

	# First positional arg is title if not a flag
	if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
		title="$1"
		shift
	fi

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--title | -t)
			title="$2"
			shift 2
			;;
		--body | -b)
			body="$2"
			shift 2
			;;
		--folder | -f)
			folder="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$title" ]]; then
		print_error "Title required. Usage: notes-helper.sh add \"Meeting notes\" --body \"Discussion points...\""
		return 1
	fi

	local rc=0
	case "$PLATFORM" in
	macos)
		macos_add "$title" "$body" "$folder"
		rc=$?
		;;
	linux | windows)
		linux_add "$title" "$body" "$folder"
		rc=$?
		;;
	esac

	if [[ $rc -eq 0 ]]; then
		print_success "Note created: ${title}"
	else
		print_error "Failed to create note: ${title}"
	fi
	return $rc
}

cmd_view() {
	case "$PLATFORM" in
	macos) macos_check_ready || return 1 ;;
	linux | windows) linux_check_ready || return 1 ;;
	esac

	local name="${1:-}"
	if [[ -z "$name" ]]; then
		print_error "Note title or ID required."
		return 1
	fi

	case "$PLATFORM" in
	macos) macos_view "$name" ;;
	linux | windows) linux_view "$name" ;;
	esac
}

cmd_search() {
	case "$PLATFORM" in
	macos) macos_check_ready || return 1 ;;
	linux | windows) linux_check_ready || return 1 ;;
	esac

	local query="${1:-}"
	if [[ -z "$query" ]]; then
		print_error "Search query required."
		return 1
	fi
	shift || true

	local folder=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--folder | -f)
			folder="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	case "$PLATFORM" in
	macos) macos_search "$query" "$folder" ;;
	linux | windows) linux_search "$query" "$folder" ;;
	esac
}

cmd_delete() {
	case "$PLATFORM" in
	macos) macos_check_ready || return 1 ;;
	linux | windows) linux_check_ready || return 1 ;;
	esac

	local name="${1:-}"
	if [[ -z "$name" ]]; then
		print_error "Note title or ID required."
		return 1
	fi

	local rc=0
	case "$PLATFORM" in
	macos)
		macos_delete "$name"
		rc=$?
		;;
	linux | windows)
		linux_delete "$name"
		rc=$?
		;;
	esac

	if [[ $rc -eq 0 ]]; then
		print_success "Note deleted: ${name}"
	else
		print_error "Failed to delete note: ${name}"
	fi
	return $rc
}

cmd_sync() {
	case "$PLATFORM" in
	macos) macos_sync ;;
	linux | windows)
		linux_check_ready || return 1
		linux_sync
		;;
	esac
}

cmd_help() {
	cat <<'HELP'
Notes Helper — cross-platform CLI for agent use

Backends: osascript/Notes.app (macOS) | nb (Linux/Windows)

Usage: notes-helper.sh <command> [args] [options]

Commands:
  setup                    Check/install backend, verify access
  folders                  List note folders/notebooks
  show [filter] [options]  Show recent notes
  add <title> [options]    Create a note
  view <title|id>          View a specific note
  search <query> [options] Search notes
  delete <title|id>        Delete a note
  sync                     Sync notebooks (nb; macOS syncs automatically)
  help                     Show this help

Show filters: today, week, all (default: all)

Add options:
  --title, -t <text>       Note title
  --body, -b <text>        Note body/content
  --folder, -f <name>      Target folder/notebook

Search/Show options:
  --folder, -f <name>      Filter by folder/notebook

Examples:
  notes-helper.sh setup
  notes-helper.sh folders
  notes-helper.sh show today
  notes-helper.sh show week --folder Work
  notes-helper.sh add "Meeting notes" --body "Discussed roadmap priorities" --folder Work
  notes-helper.sh add "Shopping list" --body "Milk, eggs, bread"
  notes-helper.sh view "Meeting notes"
  notes-helper.sh search "roadmap" --folder Work
  notes-helper.sh delete "Old draft"
  notes-helper.sh sync

Setup — macOS: No install needed (uses Notes.app). May need Automation authorization.
Setup — Linux/Windows: brew install nb (or see https://xwmx.github.io/nb/)
HELP
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	setup) cmd_setup "$@" ;;
	folders | notebooks) cmd_folders "$@" ;;
	show | list | ls) cmd_show "$@" ;;
	add | new | create) cmd_add "$@" ;;
	view | read | open) cmd_view "$@" ;;
	search | find) cmd_search "$@" ;;
	delete | rm | remove) cmd_delete "$@" ;;
	sync) cmd_sync "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "${ERROR_UNKNOWN_COMMAND}: ${command}"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
