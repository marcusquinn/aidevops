#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# attribution-detection-helper.sh — Monitor GitHub for aidevops framework copies (t1883)
#
# Uses GitHub Code Search to detect when distinctive aidevops patterns appear in
# public repositories. Manages a set of canary tokens (unique, trackable strings)
# that can be searched for to identify copies or derivatives.
#
# The detection methodology (which patterns to search for) is stored locally in
# ~/.aidevops/cache/ — not committed to the public repo — to avoid tipping off
# bad actors. See .agents/reference/attribution-monitoring.md for setup guidance.
#
# Usage:
#   attribution-detection-helper.sh scan [--dry-run]        Search GitHub for canary patterns
#   attribution-detection-helper.sh dashboard               Print detection summary
#   attribution-detection-helper.sh status                  Show last scan results
#   attribution-detection-helper.sh canary list             List registered canary patterns
#   attribution-detection-helper.sh canary add <name> <pattern>  Register a new canary
#   attribution-detection-helper.sh canary remove <name>    Remove a canary pattern
#   attribution-detection-helper.sh setup-private-repo      Guide for private detection repo
#   attribution-detection-helper.sh install                 Install weekly scheduled job
#   attribution-detection-helper.sh uninstall               Remove scheduled job
#   attribution-detection-helper.sh help                    Show this help
#
# State files:
#   ~/.aidevops/cache/attribution-canaries.json  — canary patterns (auto-created)
#   ~/.aidevops/cache/attribution-detections.json — scan results (auto-created)
#
# GitHub Code Search rate limits:
#   Authenticated:   30 requests/minute
#   Unauthenticated: 10 requests/minute
#
# Exit codes:
#   0 = success / no new detections
#   1 = new unattributed detections found
#   2 = infrastructure error (missing deps, auth failure)

set -Eeuo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh" 2>/dev/null || true

# Fallback colours if shared-constants.sh not loaded (guard against readonly re-assignment)
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${BLUE+x}" ]] && BLUE='\033[0;34m'
[[ -z "${CYAN+x}" ]] && CYAN='\033[0;36m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

CACHE_DIR="${HOME}/.aidevops/cache"
LOG_DIR="${HOME}/.aidevops/logs"
DETECTIONS_FILE="${CACHE_DIR}/attribution-detections.json"
CANARIES_FILE="${CACHE_DIR}/attribution-canaries.json"
LOGFILE="${LOG_DIR}/attribution-detection.log"

PLIST_LABEL="sh.aidevops.attribution-detection"
PLIST_FILE="${HOME}/Library/LaunchAgents/${PLIST_LABEL}.plist"

# GitHub Code Search rate limit: sleep between requests (seconds)
# 30 req/min authenticated = 2s between requests; use 3s for safety
RATE_LIMIT_SLEEP=3

# Default canary patterns — distinctive aidevops strings unlikely to appear elsewhere
# These are embedded in the public framework and can be searched on GitHub
DEFAULT_CANARIES='[
  {
    "name": "spdx-header",
    "pattern": "SPDX-FileCopyrightText: 2025-2026 Marcus Quinn",
    "description": "Standard SPDX copyright header used in all aidevops files",
    "attributed_repos": ["marcusquinn/aidevops"]
  },
  {
    "name": "aidevops-sh-domain",
    "pattern": "aidevops.sh",
    "description": "Primary domain reference in signature footers and docs",
    "attributed_repos": ["marcusquinn/aidevops"]
  },
  {
    "name": "shared-constants-guard",
    "pattern": "_SHARED_CONSTANTS_LOADED",
    "description": "Unique include guard string from shared-constants.sh",
    "attributed_repos": ["marcusquinn/aidevops"]
  },
  {
    "name": "pulse-wrapper-label",
    "pattern": "sh.aidevops.pulse",
    "description": "Unique launchd label prefix used in pulse-wrapper.sh",
    "attributed_repos": ["marcusquinn/aidevops"]
  },
  {
    "name": "full-loop-helper-state",
    "pattern": "FULL_LOOP_COMPLETE",
    "description": "Unique sentinel string from full-loop-helper.sh",
    "attributed_repos": ["marcusquinn/aidevops"]
  }
]'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

print_info() {
	printf "${BLUE}[INFO]${NC} %s\n" "$1" >&2
	return 0
}

print_success() {
	printf "${GREEN}[OK]${NC} %s\n" "$1" >&2
	return 0
}

print_error() {
	printf "${RED}[ERROR]${NC} %s\n" "$1" >&2
	return 0
}

print_warning() {
	printf "${YELLOW}[WARN]${NC} %s\n" "$1" >&2
	return 0
}

log_to_file() {
	local msg="$1"
	mkdir -p "$LOG_DIR"
	printf '%s %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$msg" >>"$LOGFILE"
	return 0
}

# Ensure cache directory and state files exist
ensure_state_files() {
	mkdir -p "$CACHE_DIR" "$LOG_DIR"

	if [[ ! -f "$CANARIES_FILE" ]]; then
		printf '%s\n' "$DEFAULT_CANARIES" >"$CANARIES_FILE"
		print_info "Initialized canary patterns at ${CANARIES_FILE}"
	fi

	if [[ ! -f "$DETECTIONS_FILE" ]]; then
		printf '{"last_scan": null, "total_detections": 0, "unattributed": 0, "results": []}\n' >"$DETECTIONS_FILE"
	fi

	return 0
}

# Check required dependencies
check_deps() {
	local missing=()

	if ! command -v gh &>/dev/null; then
		missing+=("gh (GitHub CLI)")
	fi
	if ! command -v jq &>/dev/null; then
		missing+=("jq")
	fi

	if [[ ${#missing[@]} -gt 0 ]]; then
		print_error "Missing required dependencies:"
		local dep
		for dep in "${missing[@]}"; do
			printf '  - %s\n' "$dep" >&2
		done
		return 2
	fi

	return 0
}

# Check GitHub authentication
check_gh_auth() {
	if ! gh auth status &>/dev/null; then
		print_error "GitHub CLI not authenticated. Run: gh auth login"
		return 2
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Canary management
# ---------------------------------------------------------------------------

cmd_canary_list() {
	ensure_state_files
	local count
	count=$(jq 'length' "$CANARIES_FILE")
	printf "${CYAN}Registered canary patterns (%s):${NC}\n" "$count"
	jq -r '.[] | "  \(.name)\n    Pattern: \(.pattern)\n    Description: \(.description)\n    Attributed repos: \(.attributed_repos | join(", "))\n"' "$CANARIES_FILE"
	return 0
}

cmd_canary_add() {
	local name="$1"
	local pattern="$2"
	local description="${3:-Custom canary pattern}"

	if [[ -z "$name" ]] || [[ -z "$pattern" ]]; then
		print_error "Usage: canary add <name> <pattern> [description]"
		return 1
	fi

	ensure_state_files

	# Check for duplicate name
	local existing
	existing=$(jq -r --arg name "$name" '.[] | select(.name == $name) | .name' "$CANARIES_FILE")
	if [[ -n "$existing" ]]; then
		print_error "Canary '${name}' already exists. Remove it first."
		return 1
	fi

	local new_entry
	new_entry=$(jq -n \
		--arg name "$name" \
		--arg pattern "$pattern" \
		--arg description "$description" \
		'{name: $name, pattern: $pattern, description: $description, attributed_repos: ["marcusquinn/aidevops"]}')

	local tmp_file
	tmp_file=$(mktemp)
	jq --argjson entry "$new_entry" '. + [$entry]' "$CANARIES_FILE" >"$tmp_file"
	mv "$tmp_file" "$CANARIES_FILE"

	print_success "Added canary '${name}': ${pattern}"
	log_to_file "canary_added name=${name} pattern=${pattern}"
	return 0
}

cmd_canary_remove() {
	local name="$1"

	if [[ -z "$name" ]]; then
		print_error "Usage: canary remove <name>"
		return 1
	fi

	ensure_state_files

	local count_before count_after
	count_before=$(jq 'length' "$CANARIES_FILE")

	local tmp_file
	tmp_file=$(mktemp)
	jq --arg name "$name" '[.[] | select(.name != $name)]' "$CANARIES_FILE" >"$tmp_file"
	mv "$tmp_file" "$CANARIES_FILE"

	count_after=$(jq 'length' "$CANARIES_FILE")

	if [[ "$count_before" -eq "$count_after" ]]; then
		print_warning "Canary '${name}' not found"
		return 1
	fi

	print_success "Removed canary '${name}'"
	log_to_file "canary_removed name=${name}"
	return 0
}

# ---------------------------------------------------------------------------
# GitHub Code Search
# ---------------------------------------------------------------------------

# Search GitHub for a single pattern. Returns JSON array of matches.
# Args: pattern, dry_run (true/false)
search_github_code() {
	local pattern="$1"
	local dry_run="${2:-false}"

	if [[ "$dry_run" == "true" ]]; then
		print_info "[DRY-RUN] Would search GitHub for: ${pattern}"
		printf '[]\n'
		return 0
	fi

	# GitHub code search API
	# Returns: items[] with repository.full_name, html_url, path
	local response
	if ! response=$(gh api "search/code" \
		--method GET \
		-f "q=${pattern}" \
		-f "per_page=30" \
		2>&1); then
		print_warning "Search failed for pattern '${pattern}': ${response}"
		printf '[]\n'
		return 0
	fi

	# Extract relevant fields
	printf '%s\n' "$response" | jq '[.items[] | {
		repo: .repository.full_name,
		file: .path,
		url: .html_url,
		score: .score
	}]'
	return 0
}

# ---------------------------------------------------------------------------
# Scan command
# ---------------------------------------------------------------------------

cmd_scan() {
	local dry_run="false"
	if [[ "${1:-}" == "--dry-run" ]]; then
		dry_run="true"
	fi

	check_deps || return 2
	if [[ "$dry_run" == "false" ]]; then
		check_gh_auth || return 2
	fi
	ensure_state_files

	local canary_count
	canary_count=$(jq 'length' "$CANARIES_FILE")
	print_info "Starting attribution scan (${canary_count} canary patterns)..."
	if [[ "$dry_run" == "true" ]]; then
		print_info "DRY-RUN mode — no actual API calls"
	fi

	local scan_time
	scan_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	local all_results='[]'
	local total_detections=0
	local unattributed_count=0

	# Read canaries and iterate
	local canary_names
	canary_names=$(jq -r '.[].name' "$CANARIES_FILE")

	local name
	while IFS= read -r name; do
		local canary_json
		canary_json=$(jq --arg name "$name" '.[] | select(.name == $name)' "$CANARIES_FILE")

		local pattern attributed_json
		pattern=$(printf '%s\n' "$canary_json" | jq -r '.pattern')
		attributed_json=$(printf '%s\n' "$canary_json" | jq -r '.attributed_repos')

		print_info "Scanning for canary '${name}': ${pattern}"

		local matches
		matches=$(search_github_code "$pattern" "$dry_run")

		local match_count
		match_count=$(printf '%s\n' "$matches" | jq 'length')

		if [[ "$match_count" -gt 0 ]]; then
			print_info "  Found ${match_count} match(es)"

			# Annotate each match with attribution status
			local annotated_matches
			annotated_matches=$(printf '%s\n' "$matches" | jq \
				--arg canary_name "$name" \
				--argjson attributed "$attributed_json" \
				'[.[] | . + {
					canary: $canary_name,
					attributed: ((.repo as $r | $attributed | map(select(. == $r)) | length > 0))
				}]')

			# Count unattributed
			local unattributed_in_batch
			unattributed_in_batch=$(printf '%s\n' "$annotated_matches" | jq '[.[] | select(.attributed == false)] | length')

			total_detections=$((total_detections + match_count))
			unattributed_count=$((unattributed_count + unattributed_in_batch))

			if [[ "$unattributed_in_batch" -gt 0 ]]; then
				print_warning "  ${unattributed_in_batch} unattributed match(es) found!"
				printf '%s\n' "$annotated_matches" | jq -r '.[] | select(.attributed == false) | "    UNATTRIBUTED: \(.repo) — \(.url)"' >&2
			fi

			# Merge into all_results
			all_results=$(printf '%s\n%s\n' "$all_results" "$annotated_matches" | jq -s 'add')
		else
			print_info "  No matches found"
		fi

		# Rate limit: sleep between API calls
		if [[ "$dry_run" == "false" ]]; then
			sleep "$RATE_LIMIT_SLEEP"
		fi
	done <<<"$canary_names"

	# Write updated detections file
	local tmp_file
	tmp_file=$(mktemp)
	jq -n \
		--arg scan_time "$scan_time" \
		--argjson total "$total_detections" \
		--argjson unattributed "$unattributed_count" \
		--argjson results "$all_results" \
		'{
			last_scan: $scan_time,
			total_detections: $total,
			unattributed: $unattributed,
			results: $results
		}' >"$tmp_file"
	mv "$tmp_file" "$DETECTIONS_FILE"

	log_to_file "scan_complete total=${total_detections} unattributed=${unattributed_count} dry_run=${dry_run}"

	print_success "Scan complete: ${total_detections} total detections, ${unattributed_count} unattributed"

	if [[ "$unattributed_count" -gt 0 ]]; then
		return 1
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Dashboard command
# ---------------------------------------------------------------------------

cmd_dashboard() {
	ensure_state_files

	local last_scan total_detections unattributed
	last_scan=$(jq -r '.last_scan // "never"' "$DETECTIONS_FILE")
	total_detections=$(jq -r '.total_detections // 0' "$DETECTIONS_FILE")
	unattributed=$(jq -r '.unattributed // 0' "$DETECTIONS_FILE")

	printf '\n'
	printf "${CYAN}╔══════════════════════════════════════════════════╗${NC}\n"
	printf "${CYAN}║     Attribution Detection Dashboard              ║${NC}\n"
	printf "${CYAN}╚══════════════════════════════════════════════════╝${NC}\n"
	printf '\n'
	printf "  Last scan:          %s\n" "$last_scan"
	printf "  Total detections:   %s\n" "$total_detections"

	if [[ "$unattributed" -gt 0 ]]; then
		printf "  Unattributed:       ${RED}%s${NC}\n" "$unattributed"
	else
		printf "  Unattributed:       ${GREEN}%s${NC}\n" "$unattributed"
	fi

	local canary_count
	canary_count=$(jq 'length' "$CANARIES_FILE")
	printf "  Canary patterns:    %s\n" "$canary_count"
	printf '\n'

	if [[ "$total_detections" -gt 0 ]]; then
		printf "${CYAN}Detections by canary:${NC}\n"
		jq -r '
			.results
			| group_by(.canary)[]
			| "\n  Canary: \(.[0].canary) (\(length) match(es))"
			+ (
				.[]
				| "\n    [\(if .attributed then "attributed" else "UNATTRIBUTED" end)] \(.repo) — \(.file)"
			)
		' "$DETECTIONS_FILE"
		printf '\n'
	fi

	if [[ "$unattributed" -gt 0 ]]; then
		printf "${RED}Action required: %s unattributed detection(s) found.${NC}\n" "$unattributed"
		printf "See .agents/reference/attribution-monitoring.md for response guidance.\n"
		printf '\n'
	fi

	return 0
}

# ---------------------------------------------------------------------------
# Status command
# ---------------------------------------------------------------------------

cmd_status() {
	ensure_state_files

	local last_scan total_detections unattributed
	last_scan=$(jq -r '.last_scan // "never"' "$DETECTIONS_FILE")
	total_detections=$(jq -r '.total_detections // 0' "$DETECTIONS_FILE")
	unattributed=$(jq -r '.unattributed // 0' "$DETECTIONS_FILE")

	printf "last_scan=%s total=%s unattributed=%s\n" "$last_scan" "$total_detections" "$unattributed"
	return 0
}

# ---------------------------------------------------------------------------
# Setup private repo guide
# ---------------------------------------------------------------------------

cmd_setup_private_repo() {
	printf '\n'
	printf "${CYAN}Private Detection Repo Setup Guide${NC}\n"
	printf '%.0s─' {1..50}
	printf '\n\n'
	printf 'A private GitHub repo lets you store detection results and\n'
	printf 'custom canary patterns without exposing your methodology.\n\n'
	printf "${YELLOW}Step 1: Create the private repo${NC}\n"
	printf '  gh repo create <your-org>/aidevops-provenance --private\n\n'
	printf "${YELLOW}Step 2: Clone it locally${NC}\n"
	printf '  git clone git@github.com:<your-org>/aidevops-provenance.git\n'
	printf '  cd aidevops-provenance\n\n'
	printf "${YELLOW}Step 3: Initialize structure${NC}\n"
	printf '  mkdir -p scripts config reports\n'
	printf '  cp ~/.aidevops/cache/attribution-canaries.json config/search-strings.json\n'
	printf '  echo "# Attribution Detection" > README.md\n'
	printf '  git add . && git commit -m "init: attribution detection repo"\n'
	printf '  git push\n\n'
	printf "${YELLOW}Step 4: Schedule weekly scans${NC}\n"
	printf '  attribution-detection-helper.sh install\n\n'
	printf 'See .agents/reference/attribution-monitoring.md for full guidance.\n\n'
	return 0
}

# ---------------------------------------------------------------------------
# Scheduler install/uninstall
# ---------------------------------------------------------------------------

cmd_install() {
	local script_path
	script_path="$(realpath "${BASH_SOURCE[0]}")"

	if [[ "$(uname -s)" == "Darwin" ]]; then
		_install_launchd "$script_path"
	else
		_install_cron "$script_path"
	fi
	return 0
}

_install_launchd() {
	local script_path="$1"
	local plist_dir
	plist_dir="$(dirname "$PLIST_FILE")"
	mkdir -p "$plist_dir"

	cat >"$PLIST_FILE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${script_path}</string>
        <string>scan</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Weekday</key>
        <integer>1</integer>
        <key>Hour</key>
        <integer>3</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/attribution-detection.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/attribution-detection.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin</string>
        <key>HOME</key>
        <string>${HOME}</string>
    </dict>
</dict>
</plist>
EOF

	launchctl load "$PLIST_FILE" 2>/dev/null || true
	print_success "Installed launchd job: ${PLIST_LABEL} (runs weekly Monday 03:00)"
	log_to_file "launchd_installed"
	return 0
}

_install_cron() {
	local script_path="$1"
	local cron_entry="0 3 * * 1 ${script_path} scan >> ${LOGFILE} 2>&1 # aidevops: attribution-detection"

	# Check if already installed
	if crontab -l 2>/dev/null | grep -q "attribution-detection"; then
		print_warning "Cron job already installed"
		return 0
	fi

	# Add to crontab
	local tmp_cron
	tmp_cron=$(mktemp)
	crontab -l 2>/dev/null >"$tmp_cron" || true
	printf '%s\n' "$cron_entry" >>"$tmp_cron"
	crontab "$tmp_cron"
	rm -f "$tmp_cron"

	print_success "Installed cron job (runs weekly Monday 03:00)"
	log_to_file "cron_installed"
	return 0
}

cmd_uninstall() {
	if [[ "$(uname -s)" == "Darwin" ]]; then
		if [[ -f "$PLIST_FILE" ]]; then
			launchctl unload "$PLIST_FILE" 2>/dev/null || true
			rm -f "$PLIST_FILE"
			print_success "Removed launchd job: ${PLIST_LABEL}"
		else
			print_warning "Launchd job not installed"
		fi
	else
		if crontab -l 2>/dev/null | grep -q "attribution-detection"; then
			local tmp_cron
			tmp_cron=$(mktemp)
			crontab -l 2>/dev/null | grep -v "attribution-detection" >"$tmp_cron" || true
			crontab "$tmp_cron"
			rm -f "$tmp_cron"
			print_success "Removed cron job"
		else
			print_warning "Cron job not installed"
		fi
	fi
	log_to_file "uninstalled"
	return 0
}

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------

cmd_help() {
	cat <<'EOF'
attribution-detection-helper.sh — Monitor GitHub for aidevops framework copies

Usage:
  attribution-detection-helper.sh scan [--dry-run]
      Search GitHub Code Search with all registered canary patterns.
      --dry-run: show what would be searched without making API calls.
      Exit 0 = no unattributed detections. Exit 1 = unattributed found.

  attribution-detection-helper.sh dashboard
      Print a formatted summary of all detections from the last scan.

  attribution-detection-helper.sh status
      Print last scan metadata (machine-readable: key=value format).

  attribution-detection-helper.sh canary list
      List all registered canary patterns.

  attribution-detection-helper.sh canary add <name> <pattern> [description]
      Register a new canary pattern. Searches GitHub Code Search.
      Example: canary add my-func "my_unique_function_name" "Custom function"

  attribution-detection-helper.sh canary remove <name>
      Remove a canary pattern by name.

  attribution-detection-helper.sh setup-private-repo
      Print setup guide: private detection repo creation steps.

  attribution-detection-helper.sh install
      Install as a weekly scheduled job (launchd on macOS, cron on Linux).

  attribution-detection-helper.sh uninstall
      Remove the scheduled job.

  attribution-detection-helper.sh help
      Show this help.

State files (local, not committed to public repo):
  ~/.aidevops/cache/attribution-canaries.json   — canary patterns
  ~/.aidevops/cache/attribution-detections.json — scan results
  ~/.aidevops/logs/attribution-detection.log    — operation log

See also: .agents/reference/attribution-monitoring.md
EOF
	return 0
}

# ---------------------------------------------------------------------------
# Canary dispatch (extracted to reduce nesting depth in main)
# ---------------------------------------------------------------------------

cmd_canary_dispatch() {
	local sub="${1:-list}"
	shift || true
	case "$sub" in
	list)
		cmd_canary_list
		;;
	add)
		cmd_canary_add "${@}"
		;;
	remove)
		cmd_canary_remove "${@}"
		;;
	*)
		print_error "Unknown canary subcommand: ${sub}"
		printf 'Valid subcommands: list, add, remove\n' >&2
		return 1
		;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
	scan)
		cmd_scan "${@}"
		;;
	dashboard)
		cmd_dashboard
		;;
	status)
		cmd_status
		;;
	canary)
		cmd_canary_dispatch "${@}"
		;;
	setup-private-repo)
		cmd_setup_private_repo
		;;
	install)
		cmd_install
		;;
	uninstall)
		cmd_uninstall
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		print_error "Unknown command: ${cmd}"
		cmd_help
		return 1
		;;
	esac
	return 0
}

main "${@}"
