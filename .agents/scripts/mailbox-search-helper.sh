#!/usr/bin/env bash
# mailbox-search-helper.sh - macOS Spotlight and notmuch/mu mailbox search integration
#
# Leverages OS-level email indexes for fast full-text search including attachment content.
# macOS: uses mdfind (Spotlight) for Mail.app and EML file search.
# Linux: uses notmuch or mu (maildir-based indexed search).
#
# Usage:
#   mailbox-search-helper.sh search <query> [--backend auto|spotlight|notmuch|mu] [--limit <n>] [--maildir <path>]
#   mailbox-search-helper.sh search-attachments <query> [--type <pdf|docx|txt|all>] [--limit <n>]
#   mailbox-search-helper.sh index-status [--backend auto|spotlight|notmuch|mu]
#   mailbox-search-helper.sh setup [--backend notmuch|mu] [--maildir <path>]
#   mailbox-search-helper.sh help
#
# Backends:
#   spotlight  - macOS Spotlight via mdfind (Mail.app + EML files, includes attachments)
#   notmuch    - notmuch indexed search (Linux/macOS, maildir format)
#   mu         - mu/mu4e indexed search (Linux/macOS, maildir format)
#   auto       - detect best available backend (default)
#
# Output format: JSON array of results with fields: id, subject, from, date, path, snippet
#
# Dependencies:
#   macOS: mdfind (built-in), mdls (built-in)
#   notmuch: brew install notmuch / apt install notmuch
#   mu: brew install mu / apt install maildir-utils
#
# Part of aidevops email system (t1522)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# ============================================================================
# Constants
# ============================================================================

readonly DEFAULT_LIMIT=50
readonly DEFAULT_MAILDIR="${HOME}/Maildir"
readonly WORKSPACE_DIR="${MAILBOX_SEARCH_WORKSPACE:-${HOME}/.aidevops/.agent-workspace/mailbox-search}"
readonly RESULTS_DB="${WORKSPACE_DIR}/search-cache.db"

# Spotlight MDItem attributes for email
readonly SPOTLIGHT_EMAIL_KIND="com.apple.mail.emlx"
readonly SPOTLIGHT_EML_KIND="public.email-message"

# ============================================================================
# Logging (uses shared-constants.sh print_* functions)
# ============================================================================

# shellcheck disable=SC2034
LOG_PREFIX="MAILBOX-SEARCH"

# ============================================================================
# Dependency detection
# ============================================================================

detect_backend() {
	local preferred="${1:-auto}"

	if [[ "$preferred" != "auto" ]]; then
		echo "$preferred"
		return 0
	fi

	# macOS: prefer Spotlight (no setup required, indexes Mail.app natively)
	if [[ "$(uname -s)" == "Darwin" ]] && command -v mdfind >/dev/null 2>&1; then
		echo "spotlight"
		return 0
	fi

	# notmuch: widely available, excellent query language
	if command -v notmuch >/dev/null 2>&1; then
		echo "notmuch"
		return 0
	fi

	# mu: alternative to notmuch
	if command -v mu >/dev/null 2>&1; then
		echo "mu"
		return 0
	fi

	echo "none"
	return 0
}

check_backend_available() {
	local backend="$1"

	case "$backend" in
	spotlight)
		if [[ "$(uname -s)" != "Darwin" ]]; then
			print_error "Spotlight is only available on macOS"
			return 1
		fi
		if ! command -v mdfind >/dev/null 2>&1; then
			print_error "mdfind not found (should be built-in on macOS)"
			return 1
		fi
		;;
	notmuch)
		if ! command -v notmuch >/dev/null 2>&1; then
			print_error "notmuch not found. Install: brew install notmuch (macOS) or apt install notmuch (Linux)"
			return 1
		fi
		;;
	mu)
		if ! command -v mu >/dev/null 2>&1; then
			print_error "mu not found. Install: brew install mu (macOS) or apt install maildir-utils (Linux)"
			return 1
		fi
		;;
	none)
		print_error "No search backend available. On macOS, Spotlight is built-in. On Linux, install notmuch or mu."
		return 1
		;;
	*)
		print_error "Unknown backend: $backend. Valid: auto, spotlight, notmuch, mu"
		return 1
		;;
	esac

	return 0
}

# ============================================================================
# Spotlight (macOS mdfind) backend
# ============================================================================

spotlight_search() {
	local query="$1"
	local limit="$2"
	local output_format="${3:-json}"

	# Build mdfind query: search email content and metadata
	# kMDItemContentType matches Mail.app emlx and generic .eml files
	# kMDItemTextContent searches body text (requires Spotlight indexing)
	local mdfind_query
	mdfind_query="(kMDItemContentType == '${SPOTLIGHT_EMAIL_KIND}' || kMDItemContentType == '${SPOTLIGHT_EML_KIND}') && kMDItemTextContent == '*${query}*'cdw"

	local results
	results=$(mdfind -count "$mdfind_query" 2>/dev/null || echo "0")

	if [[ "$results" -eq 0 ]]; then
		# Fallback: broader search without content type restriction
		mdfind_query="kMDItemTextContent == '*${query}*'cdw && (kMDItemContentType == '${SPOTLIGHT_EMAIL_KIND}' || kMDItemContentType == '${SPOTLIGHT_EML_KIND}' || kMDItemFSName == '*.eml')"
	fi

	# Fetch file paths
	local paths
	paths=$(mdfind -0 "$mdfind_query" 2>/dev/null | tr '\0' '\n' | head -n "$limit")

	if [[ -z "$paths" ]]; then
		echo "[]"
		return 0
	fi

	# Build JSON output from mdls metadata
	spotlight_paths_to_json "$paths" "$query"
	return 0
}

spotlight_paths_to_json() {
	local paths="$1"
	local query="$2"
	local first=1

	printf '['
	while IFS= read -r path; do
		[[ -z "$path" ]] && continue
		[[ ! -f "$path" ]] && continue

		# Extract metadata via mdls
		local subject from_addr date_str
		subject=$(mdls -name kMDItemSubject "$path" 2>/dev/null | awk -F '"' '{print $2}' | head -1)
		from_addr=$(mdls -name kMDItemAuthorEmailAddresses "$path" 2>/dev/null | grep -oE '[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}' | head -1)
		date_str=$(mdls -name kMDItemContentCreationDate "$path" 2>/dev/null | awk '{print $3, $4}' | head -1)

		# Sanitize for JSON
		subject="${subject:-}"
		from_addr="${from_addr:-}"
		date_str="${date_str:-}"

		# Escape JSON special characters
		subject=$(printf '%s' "$subject" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/ /g')
		from_addr=$(printf '%s' "$from_addr" | sed 's/\\/\\\\/g; s/"/\\"/g')
		path_escaped=$(printf '%s' "$path" | sed 's/\\/\\\\/g; s/"/\\"/g')

		if [[ "$first" -eq 0 ]]; then
			printf ','
		fi
		first=0

		printf '{"path":"%s","subject":"%s","from":"%s","date":"%s","backend":"spotlight"}' \
			"$path_escaped" "$subject" "$from_addr" "$date_str"
	done <<<"$paths"
	printf ']'
	return 0
}

spotlight_search_attachments() {
	local query="$1"
	local limit="$2"
	local file_type="${3:-all}"

	# Build type filter for Spotlight
	local type_filter=""
	case "$file_type" in
	pdf)
		type_filter="&& kMDItemContentType == 'com.adobe.pdf'"
		;;
	docx)
		type_filter="&& (kMDItemContentType == 'org.openxmlformats.wordprocessingml.document' || kMDItemContentType == 'com.microsoft.word.doc')"
		;;
	txt)
		type_filter="&& kMDItemContentType == 'public.plain-text'"
		;;
	all)
		# No type filter — search all indexable content
		type_filter=""
		;;
	esac

	# Search attachment content via Spotlight
	# Spotlight indexes PDF text, Office documents, and plain text natively
	local mdfind_query
	mdfind_query="kMDItemTextContent == '*${query}*'cdw ${type_filter}"

	local paths
	paths=$(mdfind -0 "$mdfind_query" 2>/dev/null | tr '\0' '\n' | head -n "$limit")

	if [[ -z "$paths" ]]; then
		echo "[]"
		return 0
	fi

	# Return as JSON with file metadata
	local first=1
	printf '['
	while IFS= read -r path; do
		[[ -z "$path" ]] && continue
		[[ ! -f "$path" ]] && continue

		local filename kind size
		filename=$(basename "$path")
		kind=$(mdls -name kMDItemContentType "$path" 2>/dev/null | awk -F '"' '{print $2}')
		size=$(mdls -name kMDItemFSSize "$path" 2>/dev/null | awk '{print $3}')

		filename=$(printf '%s' "$filename" | sed 's/\\/\\\\/g; s/"/\\"/g')
		path_escaped=$(printf '%s' "$path" | sed 's/\\/\\\\/g; s/"/\\"/g')
		kind="${kind:-unknown}"
		size="${size:-0}"

		if [[ "$first" -eq 0 ]]; then
			printf ','
		fi
		first=0

		printf '{"path":"%s","filename":"%s","content_type":"%s","size":%s,"backend":"spotlight"}' \
			"$path_escaped" "$filename" "$kind" "$size"
	done <<<"$paths"
	printf ']'
	return 0
}

spotlight_index_status() {
	local status
	# Check if Spotlight indexing is enabled
	if ! command -v mdutil >/dev/null 2>&1; then
		echo '{"backend":"spotlight","available":false,"reason":"mdutil not found"}'
		return 0
	fi

	status=$(mdutil -s / 2>/dev/null | head -2 | tr '\n' ' ')
	local enabled="false"
	if printf '%s' "$status" | grep -qi "enabled"; then
		enabled="true"
	fi

	# Count indexed email files
	local email_count
	email_count=$(mdfind "kMDItemContentType == '${SPOTLIGHT_EMAIL_KIND}'" 2>/dev/null | wc -l | tr -d ' ')

	printf '{"backend":"spotlight","available":true,"indexing_enabled":%s,"indexed_emails":%s,"status":"%s"}' \
		"$enabled" "$email_count" "$(printf '%s' "$status" | sed 's/"/\\"/g')"
	return 0
}

# ============================================================================
# notmuch backend
# ============================================================================

notmuch_search() {
	local query="$1"
	local limit="$2"
	local maildir="${3:-$DEFAULT_MAILDIR}"

	# Verify notmuch database exists
	if ! notmuch config get database.path >/dev/null 2>&1; then
		print_error "notmuch database not initialized. Run: mailbox-search-helper.sh setup --backend notmuch --maildir $maildir"
		return 1
	fi

	# notmuch search with JSON output
	# Format: id, subject, authors, date, tags, matched, total
	local results
	results=$(notmuch search --format=json --limit="$limit" --output=summary "$query" 2>/dev/null || echo "[]")

	# Enrich with file paths
	notmuch_enrich_results "$results" "$query"
	return 0
}

notmuch_enrich_results() {
	local results="$1"
	local query="$2"

	# Add backend field and file paths to each result
	printf '%s' "$results" | python3 -c "
import json, sys, subprocess

data = json.load(sys.stdin)
enriched = []
for item in data:
    thread_id = item.get('thread', '')
    # Get file paths for this thread
    try:
        files_out = subprocess.run(
            ['notmuch', 'search', '--format=json', '--output=files', 'thread:' + thread_id],
            capture_output=True, text=True, timeout=5
        )
        files = json.loads(files_out.stdout) if files_out.returncode == 0 else []
    except Exception:
        files = []

    enriched.append({
        'id': item.get('thread', ''),
        'subject': item.get('subject', ''),
        'from': item.get('authors', ''),
        'date': item.get('date_relative', ''),
        'tags': item.get('tags', []),
        'matched': item.get('matched', 0),
        'total': item.get('total', 0),
        'files': files[:3],  # First 3 file paths
        'backend': 'notmuch'
    })

print(json.dumps(enriched))
" 2>/dev/null || printf '%s' "$results"
	return 0
}

notmuch_search_attachments() {
	local query="$1"
	local limit="$2"
	local file_type="${3:-all}"

	# notmuch supports attachment filename search
	local notmuch_query="$query"
	case "$file_type" in
	pdf)
		notmuch_query="$query attachment:*.pdf"
		;;
	docx)
		notmuch_query="$query (attachment:*.docx OR attachment:*.doc)"
		;;
	txt)
		notmuch_query="$query attachment:*.txt"
		;;
	all)
		notmuch_query="$query"
		;;
	esac

	notmuch search --format=json --limit="$limit" --output=summary "$notmuch_query" 2>/dev/null || echo "[]"
	return 0
}

notmuch_index_status() {
	if ! command -v notmuch >/dev/null 2>&1; then
		echo '{"backend":"notmuch","available":false,"reason":"notmuch not installed"}'
		return 0
	fi

	local db_path
	db_path=$(notmuch config get database.path 2>/dev/null || echo "")

	if [[ -z "$db_path" ]]; then
		echo '{"backend":"notmuch","available":true,"initialized":false,"reason":"database not configured"}'
		return 0
	fi

	local count
	count=$(notmuch count 2>/dev/null || echo "0")

	local last_indexed
	last_indexed=$(notmuch config get index.last_mod 2>/dev/null || echo "unknown")

	printf '{"backend":"notmuch","available":true,"initialized":true,"database_path":"%s","message_count":%s,"last_indexed":"%s"}' \
		"$db_path" "$count" "$last_indexed"
	return 0
}

notmuch_setup() {
	local maildir="$1"

	if [[ ! -d "$maildir" ]]; then
		print_error "Maildir not found: $maildir"
		print_info "Create a maildir structure or sync email first with an IMAP sync tool (mbsync, offlineimap)"
		return 1
	fi

	# Initialize notmuch database
	print_info "Initializing notmuch database for: $maildir"
	notmuch config set database.path "$maildir"
	notmuch new --quiet

	local count
	count=$(notmuch count 2>/dev/null || echo "0")
	print_info "notmuch indexed $count messages"
	return 0
}

# ============================================================================
# mu backend
# ============================================================================

mu_search() {
	local query="$1"
	local limit="$2"
	local maildir="${3:-$DEFAULT_MAILDIR}"

	# Verify mu database exists
	if ! mu info 2>/dev/null | grep -q "database"; then
		print_error "mu database not initialized. Run: mailbox-search-helper.sh setup --backend mu --maildir $maildir"
		return 1
	fi

	# mu find with JSON output (mu 1.8+)
	# Older mu versions use --format=sexp; detect version
	local mu_version
	mu_version=$(mu --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
	local mu_major
	mu_major=$(printf '%s' "$mu_version" | cut -d. -f1)

	local results
	if [[ "${mu_major:-0}" -ge 1 ]]; then
		# mu 1.x: use --format=json
		results=$(mu find --format=json --maxnum="$limit" "$query" 2>/dev/null || echo "[]")
	else
		# Older mu: parse plain text output
		results=$(mu_parse_plain_output "$query" "$limit")
	fi

	# Add backend field
	printf '%s' "$results" | python3 -c "
import json, sys
data = json.load(sys.stdin)
if isinstance(data, list):
    for item in data:
        item['backend'] = 'mu'
    print(json.dumps(data))
else:
    print(json.dumps([]))
" 2>/dev/null || echo "[]"
	return 0
}

mu_parse_plain_output() {
	local query="$1"
	local limit="$2"

	# Fallback for older mu versions: parse plain text
	local output
	output=$(mu find --fields "i s f d p" --maxnum="$limit" "$query" 2>/dev/null || echo "")

	if [[ -z "$output" ]]; then
		echo "[]"
		return 0
	fi

	# Convert to minimal JSON
	local first=1
	printf '['
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		local path subject from date
		path=$(printf '%s' "$line" | awk '{print $NF}')
		subject=$(printf '%s' "$line" | awk '{$1=$2=$3=""; print $0}' | xargs)

		if [[ "$first" -eq 0 ]]; then
			printf ','
		fi
		first=0

		path=$(printf '%s' "$path" | sed 's/\\/\\\\/g; s/"/\\"/g')
		subject=$(printf '%s' "$subject" | sed 's/\\/\\\\/g; s/"/\\"/g')
		printf '{"path":"%s","subject":"%s","backend":"mu"}' "$path" "$subject"
	done <<<"$output"
	printf ']'
	return 0
}

mu_search_attachments() {
	local query="$1"
	local limit="$2"
	local file_type="${3:-all}"

	# mu supports mime: and file: search terms
	local mu_query="$query"
	case "$file_type" in
	pdf)
		mu_query="$query mime:application/pdf"
		;;
	docx)
		mu_query="$query (mime:application/vnd.openxmlformats-officedocument.wordprocessingml.document OR mime:application/msword)"
		;;
	txt)
		mu_query="$query mime:text/plain"
		;;
	all)
		mu_query="$query flag:attach"
		;;
	esac

	mu find --format=json --maxnum="$limit" "$mu_query" 2>/dev/null || echo "[]"
	return 0
}

mu_index_status() {
	if ! command -v mu >/dev/null 2>&1; then
		echo '{"backend":"mu","available":false,"reason":"mu not installed"}'
		return 0
	fi

	local info
	info=$(mu info 2>/dev/null || echo "")

	if [[ -z "$info" ]]; then
		echo '{"backend":"mu","available":true,"initialized":false,"reason":"database not initialized"}'
		return 0
	fi

	local count
	count=$(printf '%s' "$info" | grep -oE 'messages[^0-9]*[0-9]+' | grep -oE '[0-9]+' | head -1 || echo "0")

	local db_path
	db_path=$(printf '%s' "$info" | grep -oE 'database[^:]*:[^,}]*' | head -1 | awk -F: '{print $2}' | xargs || echo "unknown")

	printf '{"backend":"mu","available":true,"initialized":true,"database_path":"%s","message_count":%s}' \
		"$db_path" "${count:-0}"
	return 0
}

mu_setup() {
	local maildir="$1"

	if [[ ! -d "$maildir" ]]; then
		print_error "Maildir not found: $maildir"
		print_info "Create a maildir structure or sync email first with an IMAP sync tool (mbsync, offlineimap)"
		return 1
	fi

	print_info "Initializing mu database for: $maildir"
	mu init --maildir="$maildir" --quiet 2>/dev/null || mu init --maildir="$maildir"
	mu index --quiet 2>/dev/null || mu index

	local count
	count=$(mu info 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo "0")
	print_info "mu indexed $count messages"
	return 0
}

# ============================================================================
# Unified search dispatcher
# ============================================================================

cmd_search() {
	local query=""
	local backend="auto"
	local limit="$DEFAULT_LIMIT"
	local maildir="$DEFAULT_MAILDIR"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--backend)
			backend="$2"
			shift 2
			;;
		--limit)
			limit="$2"
			shift 2
			;;
		--maildir)
			maildir="$2"
			shift 2
			;;
		-*)
			print_error "Unknown option: $1"
			return 1
			;;
		*)
			query="$1"
			shift
			;;
		esac
	done

	if [[ -z "$query" ]]; then
		print_error "Query is required"
		print_usage
		return 1
	fi

	local resolved_backend
	resolved_backend=$(detect_backend "$backend")

	if ! check_backend_available "$resolved_backend"; then
		return 1
	fi

	case "$resolved_backend" in
	spotlight)
		spotlight_search "$query" "$limit"
		;;
	notmuch)
		notmuch_search "$query" "$limit" "$maildir"
		;;
	mu)
		mu_search "$query" "$limit" "$maildir"
		;;
	esac
	return 0
}

cmd_search_attachments() {
	local query=""
	local backend="auto"
	local limit="$DEFAULT_LIMIT"
	local file_type="all"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--backend)
			backend="$2"
			shift 2
			;;
		--limit)
			limit="$2"
			shift 2
			;;
		--type)
			file_type="$2"
			shift 2
			;;
		-*)
			print_error "Unknown option: $1"
			return 1
			;;
		*)
			query="$1"
			shift
			;;
		esac
	done

	if [[ -z "$query" ]]; then
		print_error "Query is required"
		print_usage
		return 1
	fi

	local resolved_backend
	resolved_backend=$(detect_backend "$backend")

	if ! check_backend_available "$resolved_backend"; then
		return 1
	fi

	case "$resolved_backend" in
	spotlight)
		spotlight_search_attachments "$query" "$limit" "$file_type"
		;;
	notmuch)
		notmuch_search_attachments "$query" "$limit" "$file_type"
		;;
	mu)
		mu_search_attachments "$query" "$limit" "$file_type"
		;;
	esac
	return 0
}

cmd_index_status() {
	local backend="auto"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--backend)
			backend="$2"
			shift 2
			;;
		-*)
			print_error "Unknown option: $1"
			return 1
			;;
		*)
			shift
			;;
		esac
	done

	local resolved_backend
	resolved_backend=$(detect_backend "$backend")

	case "$resolved_backend" in
	spotlight)
		spotlight_index_status
		;;
	notmuch)
		notmuch_index_status
		;;
	mu)
		mu_index_status
		;;
	none)
		echo '{"backend":"none","available":false,"reason":"No search backend found. Install notmuch or mu, or use macOS Spotlight."}'
		;;
	esac
	return 0
}

cmd_setup() {
	local backend=""
	local maildir="$DEFAULT_MAILDIR"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--backend)
			backend="$2"
			shift 2
			;;
		--maildir)
			maildir="$2"
			shift 2
			;;
		-*)
			print_error "Unknown option: $1"
			return 1
			;;
		*)
			shift
			;;
		esac
	done

	if [[ -z "$backend" ]]; then
		print_error "--backend is required for setup. Valid: notmuch, mu"
		print_info "Spotlight requires no setup on macOS — it indexes Mail.app automatically."
		return 1
	fi

	case "$backend" in
	notmuch)
		notmuch_setup "$maildir"
		;;
	mu)
		mu_setup "$maildir"
		;;
	spotlight)
		print_info "Spotlight requires no setup on macOS."
		print_info "Ensure Mail.app is configured and Spotlight indexing is enabled in System Settings > Siri & Spotlight."
		print_info "To verify: mdutil -s / (should show 'Indexing enabled')"
		;;
	*)
		print_error "Unknown backend: $backend. Valid: notmuch, mu, spotlight"
		return 1
		;;
	esac
	return 0
}

# ============================================================================
# Usage
# ============================================================================

print_usage() {
	cat <<'EOF'
mailbox-search-helper.sh - macOS Spotlight and notmuch/mu mailbox search

Usage:
  mailbox-search-helper.sh search <query> [--backend auto|spotlight|notmuch|mu] [--limit <n>] [--maildir <path>]
  mailbox-search-helper.sh search-attachments <query> [--type pdf|docx|txt|all] [--limit <n>] [--backend auto|spotlight|notmuch|mu]
  mailbox-search-helper.sh index-status [--backend auto|spotlight|notmuch|mu]
  mailbox-search-helper.sh setup --backend notmuch|mu [--maildir <path>]
  mailbox-search-helper.sh help

Commands:
  search              Full-text search across email body and headers
  search-attachments  Search attachment content (PDF, DOCX, TXT)
  index-status        Show index health and message count
  setup               Initialize notmuch or mu database for a maildir

Options:
  --backend           Search backend: auto (default), spotlight, notmuch, mu
  --limit             Max results (default: 50)
  --maildir           Path to maildir (default: ~/Maildir, for notmuch/mu)
  --type              Attachment type filter: pdf, docx, txt, all (default: all)

Backends:
  spotlight   macOS only. No setup required. Indexes Mail.app and .eml files.
              Attachment content (PDF, Office, text) indexed automatically.
  notmuch     Cross-platform. Requires maildir + notmuch new. Rich query language.
              Queries: from:alice@example.com subject:invoice date:2026..
  mu          Cross-platform. Requires maildir + mu init + mu index.
              Queries: from:alice subject:invoice date:20260101..20260401

Examples:
  # Search email body (auto-detect backend)
  mailbox-search-helper.sh search "project proposal"

  # Search with Spotlight on macOS
  mailbox-search-helper.sh search "invoice Q1 2026" --backend spotlight

  # Search with notmuch using query syntax
  mailbox-search-helper.sh search "from:alice@example.com subject:contract" --backend notmuch

  # Search attachment content for PDF files
  mailbox-search-helper.sh search-attachments "NDA agreement" --type pdf

  # Check index status
  mailbox-search-helper.sh index-status

  # Set up notmuch for ~/Maildir
  mailbox-search-helper.sh setup --backend notmuch --maildir ~/Maildir

  # Set up mu for a custom maildir
  mailbox-search-helper.sh setup --backend mu --maildir ~/Mail

Installation:
  macOS (Spotlight): built-in, no install needed
  macOS (notmuch):   brew install notmuch
  macOS (mu):        brew install mu
  Linux (notmuch):   apt install notmuch / dnf install notmuch
  Linux (mu):        apt install maildir-utils / dnf install maildir-utils

EOF
	return 0
}

# ============================================================================
# Main
# ============================================================================

main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
	search)
		cmd_search "$@"
		;;
	search-attachments)
		cmd_search_attachments "$@"
		;;
	index-status)
		cmd_index_status "$@"
		;;
	setup)
		cmd_setup "$@"
		;;
	help | --help | -h)
		print_usage
		;;
	*)
		print_error "Unknown command: $cmd"
		print_usage
		return 1
		;;
	esac
	return 0
}

main "$@"
