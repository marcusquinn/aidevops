#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034

# =============================================================================
# Inbox Helper (t2866 + t2867)
# =============================================================================
# Manages the _inbox/ transit zone: provisioning, capture, find, and status.
#
# Usage:
#   inbox-helper.sh <command> [options]
#
# Commands:
#   provision [<repo-path>]   Create _inbox/ structure (default: current dir)
#   provision-workspace       Create workspace-level inbox at ~/.aidevops/.agent-workspace/inbox/
#   add <file|--url <url>>    Capture a file or URL into _inbox/
#   find <query>              Search triage.log for matching entries
#   status [<repo-path>]      Show item counts per sub-folder
#   help                      Show this help
#
# Examples:
#   inbox-helper.sh provision
#   inbox-helper.sh provision /path/to/repo
#   inbox-helper.sh add /tmp/meeting.eml
#   inbox-helper.sh add --url https://example.com/article
#   inbox-helper.sh find "meeting notes"
#   inbox-helper.sh status
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# =============================================================================
# Constants
# =============================================================================

readonly INBOX_DIR_NAME="_inbox"
readonly INBOX_SUB_DIRS=("_drop" "email" "web" "scan" "voice" "import" "_needs-review")
readonly TRIAGE_LOG="triage.log"
readonly INBOX_GITIGNORE_CONTENT='# _inbox/ is a transit zone.
# Binary captures are excluded; only README.md, .gitignore, and triage.log are tracked.
*
!README.md
!.gitignore
!triage.log
'
readonly DEBOUNCE_SECS=5

# Workspace-level inbox
readonly WORKSPACE_INBOX_DIR="${HOME}/.aidevops/.agent-workspace/inbox"

# Path to the README template
readonly README_TEMPLATE="${SCRIPT_DIR}/../templates/inbox-readme.md"

# =============================================================================
# Helpers
# =============================================================================

# _resolve_inbox_dir <repo-path>
# Returns the absolute path to the _inbox/ dir for the given repo root.
_resolve_inbox_dir() {
	local repo_path="${1:-$(pwd)}"
	echo "${repo_path}/${INBOX_DIR_NAME}"
	return 0
}

# _iso_ts
# Returns current UTC timestamp in ISO 8601 compact form: 20260425T190000
_iso_ts() {
	date -u '+%Y%m%dT%H%M%S'
	return 0
}

# _iso_ts_full
# Returns current UTC timestamp in ISO 8601 full form: 2026-04-25T19:00:00Z
_iso_ts_full() {
	date -u '+%Y-%m-%dT%H:%M:%SZ'
	return 0
}

# _detect_sub_folder <path_or_url>
# Maps extension / MIME / URL pattern to the appropriate sub-folder name.
_detect_sub_folder() {
	local input="$1"
	# URL → web
	if [[ "$input" =~ ^https?:// ]]; then
		echo "web"
		return 0
	fi
	# Extension-based mapping
	local ext
	ext="${input##*.}"
	ext="${ext,,}"  # lowercase
	case "$ext" in
	eml | msg) echo "email" ;;
	png | jpg | jpeg | heic | heif | tiff | tif | gif | bmp | webp | pdf)
		echo "scan"
		;;
	mp3 | m4a | wav | ogg | flac | aac | opus) echo "voice" ;;
	*) echo "_drop" ;;
	esac
	return 0
}

# _conflict_safe_name <inbox-sub-dir-path> <orig-filename>
# Returns a conflict-safe filename: <stem>_<ts>.<ext>
_conflict_safe_name() {
	local dir="$1"
	local orig="$2"
	local base stem ext ts
	base="$(basename "$orig")"
	ts="$(_iso_ts)"
	# Split into stem and extension
	if [[ "$base" == *.* ]]; then
		stem="${base%.*}"
		ext="${base##*.}"
		echo "${stem}_${ts}.${ext}"
	else
		echo "${base}_${ts}"
	fi
	return 0
}

# _append_triage_log <inbox-dir> <source> <sub> <orig> <dest-path> <status>
_append_triage_log() {
	local inbox_dir="$1"
	local source="$2"
	local sub="$3"
	local orig="$4"
	local dest_path="$5"
	local status="${6:-pending}"
	local log_path="${inbox_dir}/${TRIAGE_LOG}"
	local ts
	ts="$(_iso_ts_full)"
	printf '{"ts":"%s","source":"%s","sub":"%s","orig":"%s","path":"%s","status":"%s","sensitivity":"unverified"}\n' \
		"$ts" "$source" "$sub" "$orig" "$dest_path" "$status" >> "$log_path"
	return 0
}

# =============================================================================
# cmd_provision — create _inbox/ structure (t2866)
# =============================================================================
cmd_provision() {
	local repo_path="${1:-$(pwd)}"
	repo_path="$(cd "$repo_path" && pwd)"
	local inbox_dir
	inbox_dir="$(_resolve_inbox_dir "$repo_path")"

	print_info "Provisioning ${inbox_dir} ..."

	# Create sub-directories (idempotent)
	local sub
	for sub in "${INBOX_SUB_DIRS[@]}"; do
		local sub_dir="${inbox_dir}/${sub}"
		if [[ ! -d "$sub_dir" ]]; then
			mkdir -p "$sub_dir"
			print_success "Created ${sub_dir}"
		fi
	done

	# Write README.md from template (only if missing)
	local readme="${inbox_dir}/README.md"
	if [[ ! -f "$readme" ]]; then
		if [[ -f "$README_TEMPLATE" ]]; then
			cp "$README_TEMPLATE" "$readme"
		else
			printf '# _inbox/ — Transit Zone\n\nSee: aidevops inbox help\n' > "$readme"
		fi
		print_success "Created ${readme}"
	fi

	# Write .gitignore (only if missing)
	local gitignore="${inbox_dir}/.gitignore"
	if [[ ! -f "$gitignore" ]]; then
		printf '%s' "$INBOX_GITIGNORE_CONTENT" > "$gitignore"
		print_success "Created ${gitignore}"
	fi

	# Create empty triage.log (only if missing)
	local log_path="${inbox_dir}/${TRIAGE_LOG}"
	if [[ ! -f "$log_path" ]]; then
		touch "$log_path"
		print_success "Created ${log_path}"
	fi

	print_success "_inbox/ provisioned at ${inbox_dir}"
	return 0
}

# =============================================================================
# cmd_provision_workspace — create workspace-level inbox (t2866)
# =============================================================================
cmd_provision_workspace() {
	print_info "Provisioning workspace inbox at ${WORKSPACE_INBOX_DIR} ..."
	# Reuse provision logic using the workspace path as the "repo root"
	local workspace_parent
	workspace_parent="$(dirname "$WORKSPACE_INBOX_DIR")"
	mkdir -p "$workspace_parent"
	# provision expects a repo root, so create a temp symlink alias
	# Simplest: just provision directly
	local inbox_dir="$WORKSPACE_INBOX_DIR"
	local sub
	for sub in "${INBOX_SUB_DIRS[@]}"; do
		local sub_dir="${inbox_dir}/${sub}"
		if [[ ! -d "$sub_dir" ]]; then
			mkdir -p "$sub_dir"
			print_success "Created ${sub_dir}"
		fi
	done
	local readme="${inbox_dir}/README.md"
	if [[ ! -f "$readme" ]]; then
		if [[ -f "$README_TEMPLATE" ]]; then
			cp "$README_TEMPLATE" "$readme"
		else
			printf '# _inbox/ — Transit Zone\n\nSee: aidevops inbox help\n' > "$readme"
		fi
		print_success "Created ${readme}"
	fi
	local log_path="${inbox_dir}/${TRIAGE_LOG}"
	if [[ ! -f "$log_path" ]]; then
		touch "$log_path"
		print_success "Created ${log_path}"
	fi
	print_success "Workspace inbox provisioned at ${WORKSPACE_INBOX_DIR}"
	return 0
}

# =============================================================================
# cmd_add — capture a file or URL into _inbox/ (t2867)
# =============================================================================
cmd_add() {
	local is_url=0
	local url=""
	local file_path=""

	# Parse flags
	while [[ $# -gt 0 ]]; do
		local cur_arg="$1"
		case "$cur_arg" in
		--url | -u)
			is_url=1
			url="${2:-}"
			shift 2
			;;
		--url=*)
			is_url=1
			url="${cur_arg#--url=}"
			shift
			;;
		-*)
			print_error "Unknown flag: $cur_arg"
			return 1
			;;
		*)
			file_path="$cur_arg"
			shift
			;;
		esac
	done

	# Determine repo root / inbox dir
	local repo_root
	repo_root="$(pwd)"
	local inbox_dir
	inbox_dir="${repo_root}/${INBOX_DIR_NAME}"

	# Auto-provision if inbox doesn't exist yet
	if [[ ! -d "$inbox_dir" ]]; then
		print_info "_inbox/ not found — provisioning..."
		cmd_provision "$repo_root"
	fi

	if [[ "$is_url" -eq 1 ]]; then
		_add_url "$inbox_dir" "$url"
	else
		if [[ -z "$file_path" ]]; then
			print_error "Usage: inbox-helper.sh add <file> | --url <url>"
			return 1
		fi
		_add_file "$inbox_dir" "$file_path"
	fi
	return 0
}

# _add_file <inbox-dir> <file-path>
_add_file() {
	local inbox_dir="$1"
	local src="$2"

	# Validate source
	if [[ ! -f "$src" && ! -d "$src" ]]; then
		print_error "File not found: $src"
		return 1
	fi

	local abs_src
	abs_src="$(cd "$(dirname "$src")" && pwd)/$(basename "$src")"

	# Detect sub-folder
	local sub
	sub="$(_detect_sub_folder "$src")"
	local sub_dir="${inbox_dir}/${sub}"

	# Ensure sub-dir exists
	mkdir -p "$sub_dir"

	# Build conflict-safe destination name
	local dest_name
	dest_name="$(_conflict_safe_name "$sub_dir" "$src")"
	local dest_path="${sub_dir}/${dest_name}"

	# Determine if source is inside _drop/ (move) or external (copy)
	local drop_dir="${inbox_dir}/_drop"
	if [[ "$abs_src" == "${drop_dir}/"* ]]; then
		mv "$abs_src" "$dest_path"
	else
		cp "$abs_src" "$dest_path"
	fi

	# Relative path for the log entry
	local rel_path="${INBOX_DIR_NAME}/${sub}/${dest_name}"

	_append_triage_log "$inbox_dir" "cli-add" "$sub" "$abs_src" "$rel_path" "pending"

	print_success "Captured: ${rel_path}"
	return 0
}

# _add_url <inbox-dir> <url>
_add_url() {
	local inbox_dir="$1"
	local url="$2"

	if [[ -z "$url" ]]; then
		print_error "URL is required"
		return 1
	fi

	# Validate URL format
	if [[ ! "$url" =~ ^https?:// ]]; then
		print_error "Invalid URL (must start with http:// or https://): $url"
		return 1
	fi

	local web_dir="${inbox_dir}/web"
	mkdir -p "$web_dir"

	local ts
	ts="$(_iso_ts)"

	# Generate a URL slug (replace non-alphanumeric with -)
	local slug
	slug="$(printf '%s' "$url" | sed 's|^https\?://||' | sed 's|[^a-zA-Z0-9._-]|-|g' | cut -c1-60)"
	local base_name="${slug}_${ts}"

	local html_file="${web_dir}/${base_name}.html"
	local md_file="${web_dir}/${base_name}.md"
	local meta_file="${web_dir}/${base_name}.meta.json"

	# Fetch with curl (fail gracefully)
	local curl_ok=0
	if command -v curl >/dev/null 2>&1; then
		if curl -fsSL --max-time 30 -A "aidevops-inbox/1.0" "$url" -o "$html_file" 2>/dev/null; then
			curl_ok=1
		fi
	fi

	if [[ "$curl_ok" -eq 0 ]]; then
		# Create placeholder
		printf '<html><body><!-- fetch failed for %s --></body></html>\n' "$url" > "$html_file"
		print_warning "Could not fetch URL (curl unavailable or timed out); saved placeholder"
	fi

	# Extract title from HTML (best-effort, no external deps)
	local title=""
	if command -v grep >/dev/null 2>&1 && [[ -f "$html_file" ]]; then
		title="$(grep -oi '<title>[^<]*</title>' "$html_file" 2>/dev/null | sed 's|<[^>]*>||g' | head -1 || true)"
	fi
	[[ -z "$title" ]] && title="$url"

	# Write extracted text (best-effort strip tags)
	if command -v sed >/dev/null 2>&1 && [[ -f "$html_file" ]]; then
		sed 's/<[^>]*>//g' "$html_file" | sed '/^[[:space:]]*$/d' > "$md_file" 2>/dev/null || true
	fi

	# Write metadata JSON
	local fetched_at
	fetched_at="$(_iso_ts_full)"
	printf '{"url":"%s","title":"%s","fetched_at":"%s","html":"%s","text":"%s"}\n' \
		"$url" \
		"$(printf '%s' "$title" | sed 's/"/\\"/g')" \
		"$fetched_at" \
		"${INBOX_DIR_NAME}/web/${base_name}.html" \
		"${INBOX_DIR_NAME}/web/${base_name}.md" \
		> "$meta_file"

	# Triage log entry
	local rel_path="${INBOX_DIR_NAME}/web/${base_name}.meta.json"
	_append_triage_log "$inbox_dir" "cli-url" "web" "$url" "$rel_path" "pending"

	print_success "Captured URL: ${rel_path}"
	return 0
}

# =============================================================================
# cmd_find — search triage.log (t2867)
# =============================================================================
cmd_find() {
	local query="${1:-}"

	if [[ -z "$query" ]]; then
		print_error "Usage: inbox-helper.sh find <query>"
		return 1
	fi

	# Find triage.log in current dir first, then workspace
	local log_paths=()
	local local_log="${PWD}/${INBOX_DIR_NAME}/${TRIAGE_LOG}"
	[[ -f "$local_log" ]] && log_paths+=("$local_log")

	local ws_log="${WORKSPACE_INBOX_DIR}/${TRIAGE_LOG}"
	[[ -f "$ws_log" ]] && log_paths+=("$ws_log")

	if [[ ${#log_paths[@]} -eq 0 ]]; then
		print_warning "No triage.log found. Run: aidevops inbox provision"
		return 0
	fi

	# Search last 30 days
	local cutoff_ts
	cutoff_ts="$(date -u -d '30 days ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
		|| date -u -v-30d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
		|| date -u '+2000-01-01T00:00:00Z')"

	local found=0
	local log_path
	for log_path in "${log_paths[@]}"; do
		while IFS= read -r line; do
			[[ -z "$line" ]] && continue
			# Filter by date (compare ts field string — ISO 8601 sorts lexicographically)
			local line_ts
			line_ts="$(printf '%s' "$line" | grep -o '"ts":"[^"]*"' | cut -d'"' -f4 || true)"
			[[ -n "$line_ts" && "$line_ts" < "$cutoff_ts" ]] && continue
			# Filter by query (case-insensitive substring match)
			if printf '%s' "$line" | grep -qi "$query" 2>/dev/null; then
				printf '%s\n' "$line"
				found=$((found + 1))
			fi
		done < "$log_path"
	done

	if [[ "$found" -eq 0 ]]; then
		print_info "No entries matching \"${query}\" in the last 30 days."
	fi
	return 0
}

# =============================================================================
# cmd_status — show item counts per sub-folder (t2866)
# =============================================================================
cmd_status() {
	local repo_path="${1:-$(pwd)}"
	repo_path="$(cd "$repo_path" && pwd)"
	local inbox_dir
	inbox_dir="${repo_path}/${INBOX_DIR_NAME}"

	if [[ ! -d "$inbox_dir" ]]; then
		print_warning "_inbox/ not found at ${inbox_dir}. Run: aidevops inbox provision"
		return 0
	fi

	echo ""
	echo "_inbox/ status: ${inbox_dir}"
	echo ""

	local sub count oldest_file oldest_age age_label
	for sub in "${INBOX_SUB_DIRS[@]}"; do
		local sub_dir="${inbox_dir}/${sub}"
		if [[ ! -d "$sub_dir" ]]; then
			printf '  %-20s  (missing)\n' "${sub}/"
			continue
		fi
		# Count files (non-recursive, exclude hidden)
		count=0
		while IFS= read -r -d '' _f; do
			count=$((count + 1))
		done < <(find "$sub_dir" -maxdepth 1 -type f ! -name '.*' -print0 2>/dev/null)

		oldest_age=""
		if [[ "$count" -gt 0 ]]; then
			oldest_file="$(find "$sub_dir" -maxdepth 1 -type f ! -name '.*' -print0 2>/dev/null \
				| xargs -0 ls -t1 2>/dev/null | tail -1 || true)"
			if [[ -n "$oldest_file" ]]; then
				local file_ts now_ts diff_secs
				file_ts="$(date -r "$oldest_file" +%s 2>/dev/null || stat -c '%Y' "$oldest_file" 2>/dev/null || echo 0)"
				now_ts="$(date +%s)"
				diff_secs=$(( now_ts - file_ts ))
				if [[ "$diff_secs" -lt 3600 ]]; then
					age_label="${diff_secs}s"
				elif [[ "$diff_secs" -lt 86400 ]]; then
					age_label="$(( diff_secs / 3600 ))h"
				else
					age_label="$(( diff_secs / 86400 ))d"
				fi
				oldest_age=" (oldest: ${age_label})"
			fi
		fi
		printf '  %-20s  %d items%s\n' "${sub}/" "$count" "$oldest_age"
	done

	# triage.log line count
	local log_path="${inbox_dir}/${TRIAGE_LOG}"
	local log_count=0
	if [[ -f "$log_path" ]]; then
		log_count="$(wc -l < "$log_path" 2>/dev/null || true)"
		log_count="${log_count// /}"
	fi
	echo ""
	echo "  triage.log: ${log_count} entries"
	echo ""
	return 0
}

# =============================================================================
# cmd_help
# =============================================================================
cmd_help() {
	cat <<'EOF'
inbox-helper.sh — _inbox/ transit zone manager (t2866 + t2867)

Commands:
  provision [<repo-path>]   Create _inbox/ structure (default: current dir)
  provision-workspace       Create workspace-level inbox at ~/.aidevops/.agent-workspace/inbox/
  add <file>                Capture a file (auto-detects sub-folder from extension)
  add --url <url>           Capture a web page (saves HTML + text + metadata)
  find <query>              Search triage.log for entries matching query (last 30 days)
  status [<repo-path>]      Show item counts per sub-folder
  help                      Show this help

Sub-folder routing:
  email/   .eml, .msg
  scan/    .pdf, .png, .jpg, .heic, .tiff, .gif, .bmp, .webp
  voice/   .mp3, .m4a, .wav, .ogg, .flac, .aac, .opus
  web/     URLs (--url flag)
  _drop/   Everything else (or drag-drop target for watch folder)

Audit log:
  _inbox/triage.log — append-only JSONL; one entry per capture
  Fields: ts, source, sub, orig, path, status, sensitivity

EOF
	return 0
}

# =============================================================================
# Dispatch
# =============================================================================
main() {
	local cmd="${1:-help}"
	shift || true
	case "$cmd" in
	provision) cmd_provision "$@" ;;
	provision-workspace) cmd_provision_workspace "$@" ;;
	add) cmd_add "$@" ;;
	find) cmd_find "$@" ;;
	status) cmd_status "$@" ;;
	help | -h | --help) cmd_help ;;
	*)
		print_error "Unknown inbox command: $cmd"
		echo ""
		cmd_help
		exit 1
		;;
	esac
}

main "$@"
