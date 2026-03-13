#!/usr/bin/env bash
# contribution-watch-helper.sh — Monitor external issues/PRs for new activity (t1419)
#
# Auto-discovers and monitors external GitHub issues/PRs where the
# authenticated user has contributed (authored or commented). Uses
# GitHub Notifications API for low-cost polling, with managed-repo
# exclusion to suppress aidevops automation noise.
#
# Architecture principle: the automated system (pulse/launchd) NEVER
# processes untrusted comment bodies through an LLM. It only performs
# deterministic timestamp/authorship checks. Comment bodies are only
# shown in interactive sessions after prompt-guard-helper.sh scanning.
#
# Usage:
#   contribution-watch-helper.sh seed [--dry-run]     Discover all external contributions
#   contribution-watch-helper.sh scan                 Check notifications for new external activity
#   contribution-watch-helper.sh status               Show watched items and their state
#   contribution-watch-helper.sh install               Install launchd plist
#   contribution-watch-helper.sh uninstall             Remove launchd plist
#   contribution-watch-helper.sh help                  Show usage
#
# State file: ~/.aidevops/cache/contribution-watch.json
# Launchd label: sh.aidevops.contribution-watch

set -euo pipefail

# PATH normalisation for launchd/MCP environments
export PATH="/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin:${PATH}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh" 2>/dev/null || true

# Fallback colours if shared-constants.sh not loaded
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${BLUE+x}" ]] && BLUE='\033[0;34m'
[[ -z "${CYAN+x}" ]] && CYAN='\033[0;36m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

# =============================================================================
# Configuration
# =============================================================================

STATE_FILE="${HOME}/.aidevops/cache/contribution-watch.json"
REPOS_JSON="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
LOGFILE="${HOME}/.aidevops/logs/contribution-watch.log"
PLIST_LABEL="sh.aidevops.contribution-watch"
PLIST_PATH="${HOME}/Library/LaunchAgents/${PLIST_LABEL}.plist"

# Adaptive polling intervals (seconds)
POLL_HOT=900       # 15 minutes — activity within last 24h
POLL_DEFAULT=3600  # 1 hour — normal
POLL_DORMANT=21600 # 6 hours — no activity for 7+ days

# Thresholds (seconds)
HOT_THRESHOLD=86400      # 24 hours
DORMANT_THRESHOLD=604800 # 7 days

# GitHub API page size
API_PAGE_SIZE=100

# Notification reasons that are likely to need a human response.
# Excludes low-signal reasons such as ci_activity and state_change.
SIGNAL_REASONS="author|comment|mention|review_requested|subscribed"

# =============================================================================
# Logging
# =============================================================================

_log() {
	local level="$1"
	shift
	local msg="$*"
	local timestamp
	timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	echo "[${timestamp}] [${level}] ${msg}" >>"$LOGFILE"
	return 0
}

_log_info() {
	_log "INFO" "$@"
	return 0
}

_log_warn() {
	_log "WARN" "$@"
	return 0
}

_log_error() {
	_log "ERROR" "$@"
	return 0
}

# =============================================================================
# Prerequisites
# =============================================================================

_check_prerequisites() {
	if ! command -v gh &>/dev/null; then
		echo -e "${RED}Error: gh CLI not found. Install from https://cli.github.com/${NC}" >&2
		return 1
	fi
	if ! command -v jq &>/dev/null; then
		echo -e "${RED}Error: jq not found. Install with: brew install jq${NC}" >&2
		return 1
	fi
	if ! gh auth status &>/dev/null 2>&1; then
		echo -e "${RED}Error: gh not authenticated. Run: gh auth login${NC}" >&2
		return 1
	fi
	return 0
}

_get_username() {
	local username
	username=$(gh api user --jq '.login' 2>/dev/null) || username=""
	if [[ -z "$username" ]]; then
		_log_error "Failed to resolve GitHub username via gh api user"
		echo -e "${RED}Error: Could not resolve GitHub username${NC}" >&2
		return 1
	fi
	echo "$username"
	return 0
}

# =============================================================================
# State file management
# =============================================================================

_ensure_state_file() {
	local state_dir
	state_dir=$(dirname "$STATE_FILE")
	mkdir -p "$state_dir" 2>/dev/null || true

	if [[ ! -f "$STATE_FILE" ]]; then
		echo '{"last_scan":"","items":{}}' >"$STATE_FILE"
		_log_info "Created new state file: $STATE_FILE"
	fi
	return 0
}

_read_state() {
	_ensure_state_file
	cat "$STATE_FILE"
	return 0
}

_write_state() {
	local state="$1"
	_ensure_state_file
	echo "$state" | jq '.' >"$STATE_FILE" 2>/dev/null || {
		_log_error "Failed to write state file (invalid JSON)"
		return 1
	}
	return 0
}

# =============================================================================
# ISO 8601 date helpers
# =============================================================================

_now_iso() {
	date -u +%Y-%m-%dT%H:%M:%SZ
	return 0
}

_epoch_from_iso() {
	local iso_date="$1"
	# macOS date -j -f for parsing ISO 8601
	if [[ "$(uname)" == "Darwin" ]]; then
		# Handle both Z and +00:00 suffixes
		local clean_date
		clean_date="${iso_date%Z}"
		clean_date="${clean_date%+00:00}"
		# Try multiple formats
		date -j -f "%Y-%m-%dT%H:%M:%S" "$clean_date" "+%s" 2>/dev/null || echo "0"
	else
		date -d "$iso_date" "+%s" 2>/dev/null || echo "0"
	fi
	return 0
}

_seconds_since() {
	local iso_date="$1"
	local then_epoch
	then_epoch=$(_epoch_from_iso "$iso_date")
	local now_epoch
	now_epoch=$(date +%s)
	echo $((now_epoch - then_epoch))
	return 0
}

_get_managed_repo_slugs() {
	if [[ ! -f "$REPOS_JSON" ]]; then
		return 0
	fi

	jq -r '.initialized_repos[] | select(.pulse == true and .slug != null and .slug != "") | .slug' "$REPOS_JSON" 2>/dev/null || true
	return 0
}

_is_managed_repo() {
	local repo_slug="$1"
	local managed_slugs="$2"

	if [[ -z "$repo_slug" || -z "$managed_slugs" ]]; then
		return 1
	fi

	while IFS= read -r managed_slug; do
		if [[ -n "$managed_slug" && "$repo_slug" == "$managed_slug" ]]; then
			return 0
		fi
	done <<<"$managed_slugs"

	return 1
}

_is_signal_reason() {
	local reason="$1"
	if [[ -z "$reason" ]]; then
		return 1
	fi
	if [[ "$reason" =~ ^(${SIGNAL_REASONS})$ ]]; then
		return 0
	fi
	return 1
}

_extract_item_key() {
	local subject_url="$1"
	if [[ -z "$subject_url" ]]; then
		echo ""
		return 0
	fi

	# Expected formats:
	#   https://api.github.com/repos/owner/repo/issues/123
	#   https://api.github.com/repos/owner/repo/pulls/456
	local path
	path="${subject_url#https://api.github.com/repos/}"
	if [[ "$path" == "$subject_url" ]]; then
		echo ""
		return 0
	fi

	local owner repo kind number
	owner=$(echo "$path" | cut -d'/' -f1)
	repo=$(echo "$path" | cut -d'/' -f2)
	kind=$(echo "$path" | cut -d'/' -f3)
	number=$(echo "$path" | cut -d'/' -f4)

	if [[ -z "$owner" || -z "$repo" || -z "$number" ]]; then
		echo ""
		return 0
	fi

	if [[ "$kind" != "issues" && "$kind" != "pulls" ]]; then
		echo ""
		return 0
	fi

	echo "${owner}/${repo}#${number}"
	return 0
}

_notification_item_type() {
	local subject_type="$1"
	if [[ "$subject_type" == "PullRequest" ]]; then
		echo "pr"
		return 0
	fi
	echo "issue"
	return 0
}

# =============================================================================
# Seed: discover all external contributions
# =============================================================================

cmd_seed() {
	local dry_run=false
	local arg
	for arg in "$@"; do
		if [[ "$arg" == "--dry-run" ]]; then
			dry_run=true
		fi
	done

	_check_prerequisites || return 1

	local username
	username=$(_get_username) || return 1

	echo -e "${BLUE}Discovering external contributions for @${username}...${NC}"
	_log_info "Seed started for @${username} (dry_run=${dry_run})"

	# Get list of our own repos to exclude
	local own_repos=""
	if [[ -f "$REPOS_JSON" ]]; then
		own_repos=$(jq -r '.initialized_repos[] | select(.pulse == true) | .slug' "$REPOS_JSON" 2>/dev/null | tr '\n' '|')
	fi

	local state
	state=$(_read_state)
	local items_added=0

	# Search for issues/PRs authored by user
	echo -e "${CYAN}Searching for authored issues/PRs...${NC}"
	local authored_json
	authored_json=$(gh api "search/issues?q=author:${username}+is:open&per_page=${API_PAGE_SIZE}&sort=updated" \
		--jq '.items[] | {url: .html_url, repo: .repository_url, number: .number, title: .title, type: (if .pull_request then "pr" else "issue" end), updated: .updated_at, created: .created_at}' \
		2>/dev/null) || authored_json=""

	# Search for issues/PRs commented on by user
	echo -e "${CYAN}Searching for commented issues/PRs...${NC}"
	local commented_json
	commented_json=$(gh api "search/issues?q=commenter:${username}+is:open&per_page=${API_PAGE_SIZE}&sort=updated" \
		--jq '.items[] | {url: .html_url, repo: .repository_url, number: .number, title: .title, type: (if .pull_request then "pr" else "issue" end), updated: .updated_at, created: .created_at}' \
		2>/dev/null) || commented_json=""

	# Combine and deduplicate
	local all_items
	all_items=$(printf '%s\n%s' "$authored_json" "$commented_json" | jq -s 'unique_by(.url)' 2>/dev/null) || all_items="[]"

	local total_found
	total_found=$(echo "$all_items" | jq 'length')

	echo -e "${CYAN}Found ${total_found} total items. Filtering external repos...${NC}"

	# Process each item
	local item_count
	item_count=$(echo "$all_items" | jq 'length')
	local i=0
	while [[ "$i" -lt "$item_count" ]]; do
		local item
		item=$(echo "$all_items" | jq ".[$i]")

		# Extract repo slug from repository_url (format: https://api.github.com/repos/owner/repo)
		local repo_url
		repo_url=$(echo "$item" | jq -r '.repo')
		local repo_slug
		repo_slug=$(echo "$repo_url" | sed 's|https://api.github.com/repos/||')

		# Skip our own repos (pulse-enabled)
		local is_own=false
		if [[ -n "$own_repos" ]]; then
			# Check if repo_slug matches any own repo
			local own_slug
			while IFS='|' read -r own_slug _rest; do
				if [[ "$repo_slug" == "$own_slug" ]]; then
					is_own=true
					break
				fi
			done <<<"$(echo "$own_repos" | tr '|' '\n')"
		fi

		if [[ "$is_own" == "true" ]]; then
			i=$((i + 1))
			continue
		fi

		local number
		number=$(echo "$item" | jq -r '.number')
		local item_type
		item_type=$(echo "$item" | jq -r '.type')
		local title
		title=$(echo "$item" | jq -r '.title')
		local updated
		updated=$(echo "$item" | jq -r '.updated')
		local item_key="${repo_slug}#${number}"

		# Determine role (author or commenter)
		local role="commenter"
		local created_by
		# We already know from the search query — items from authored_json are "author"
		# For simplicity, check if item appears in authored results
		if echo "$authored_json" | jq -e "select(.number == ${number})" &>/dev/null 2>&1; then
			role="author"
		fi

		if [[ "$dry_run" == "true" ]]; then
			echo "  ${item_key} (${item_type}, ${role}): ${title}"
		else
			# Add to state if not already tracked
			local now_iso
			now_iso=$(_now_iso)
			state=$(echo "$state" | jq \
				--arg key "$item_key" \
				--arg type "$item_type" \
				--arg role "$role" \
				--arg title "$title" \
				--arg updated "$updated" \
				--arg now "$now_iso" \
				'
				if .items[$key] == null then
					.items[$key] = {
						type: $type,
						role: $role,
						title: $title,
						last_our_comment: "",
						last_any_comment: $updated,
						last_notified: "",
						hot_until: ""
					}
				else
					.items[$key].title = $title |
					.items[$key].last_any_comment = (if ($updated > .items[$key].last_any_comment) then $updated else .items[$key].last_any_comment end)
				end
			')
		fi

		items_added=$((items_added + 1))
		i=$((i + 1))
	done

	if [[ "$dry_run" == "true" ]]; then
		echo ""
		echo -e "${GREEN}Dry run complete: ${items_added} external items found${NC}"
	else
		# Update last_scan timestamp
		local now_iso
		now_iso=$(_now_iso)
		state=$(echo "$state" | jq --arg ts "$now_iso" '.last_scan = $ts')
		_write_state "$state"
		echo -e "${GREEN}Seed complete: ${items_added} external items tracked${NC}"
		_log_info "Seed complete: ${items_added} items added"
	fi

	return 0
}

# =============================================================================
# Scan: check for new comments since last scan
# =============================================================================

cmd_scan() {
	_check_prerequisites || return 1

	local username
	username=$(_get_username) || return 1

	_ensure_state_file

	local state
	state=$(_read_state)

	local last_scan
	last_scan=$(echo "$state" | jq -r '.last_scan // ""')

	if [[ -z "$last_scan" ]]; then
		echo -e "${YELLOW}No previous scan found. Run 'seed' first.${NC}"
		_log_warn "Scan attempted with no prior seed"
		return 1
	fi

	_log_info "Scan started (last_scan: ${last_scan})"

	local managed_slugs
	managed_slugs=$(_get_managed_repo_slugs)

	local since_arg=""
	if [[ -n "$last_scan" ]]; then
		since_arg="&since=${last_scan}"
	fi

	# Notifications API is the primary signal: one paginated API stream instead
	# of one API call per tracked issue/PR.
	local notifications
	notifications=$(gh api --paginate "notifications?participating=true&all=true&per_page=${API_PAGE_SIZE}${since_arg}" 2>/dev/null) || notifications=""

	if [[ -z "$notifications" ]]; then
		echo -e "${GREEN}All caught up — no external contributions need attention${NC}"
		echo "Checked 0 notifications."
		local now_iso_no_data
		now_iso_no_data=$(_now_iso)
		state=$(echo "$state" | jq --arg ts "$now_iso_no_data" '.last_scan = $ts')
		_write_state "$state"
		echo "CONTRIBUTION_WATCH_COUNT=0"
		return 0
	fi

	local needs_attention=0
	local items_checked=0
	local attention_items=""
	local notifications_checked=0

	while IFS= read -r row; do
		[[ -z "$row" ]] && continue

		notifications_checked=$((notifications_checked + 1))

		local repo_slug
		repo_slug=$(echo "$row" | jq -r '.repository.full_name // ""')
		if [[ -z "$repo_slug" ]]; then
			continue
		fi

		# Suppress managed repos (aidevops automation noise belongs to pulse stream).
		if _is_managed_repo "$repo_slug" "$managed_slugs"; then
			continue
		fi

		local reason
		reason=$(echo "$row" | jq -r '.reason // ""')
		if ! _is_signal_reason "$reason"; then
			continue
		fi

		local subject_url
		subject_url=$(echo "$row" | jq -r '.subject.url // ""')
		local item_key
		item_key=$(_extract_item_key "$subject_url")
		if [[ -z "$item_key" ]]; then
			continue
		fi

		local item_type
		item_type=$(_notification_item_type "$(echo "$row" | jq -r '.subject.type // "Issue"')")
		local title
		title=$(echo "$row" | jq -r '.subject.title // "unknown"')
		local updated
		updated=$(echo "$row" | jq -r '.updated_at // ""')
		if [[ -z "$updated" ]]; then
			continue
		fi

		# Create or update tracked item from notification metadata only.
		state=$(echo "$state" | jq \
			--arg key "$item_key" \
			--arg type "$item_type" \
			--arg title "$title" \
			--arg updated "$updated" \
			'.items[$key] = ((.items[$key] // {type: $type, role: "participant", title: $title, last_our_comment: "", last_any_comment: "", last_notified: "", hot_until: ""})
				| .type = $type
				| .title = $title
				| .last_any_comment = (if .last_any_comment == "" or $updated > .last_any_comment then $updated else .last_any_comment end)
			)')

		local last_notified
		last_notified=$(echo "$state" | jq -r --arg key "$item_key" '.items[$key].last_notified // ""')
		# ISO 8601 UTC timestamps sort lexicographically, so string compare is valid.
		if [[ -n "$last_notified" ]] && [[ ! "$updated" > "$last_notified" ]]; then
			continue
		fi

		needs_attention=$((needs_attention + 1))
		attention_items="${attention_items}  ${item_key} (${item_type}): ${title} — reason: ${reason}\n"

		# Mark as notified and hot.
		local hot_until
		hot_until=$(date -u -v+24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+24 hours' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
		state=$(echo "$state" | jq \
			--arg key "$item_key" \
			--arg updated "$updated" \
			--arg hot "$hot_until" \
			'.items[$key].last_notified = $updated | .items[$key].hot_until = $hot')

		items_checked=$((items_checked + 1))
	done < <(echo "$notifications" | jq -c '.[]?')

	# Update scan timestamp
	local now_iso
	now_iso=$(_now_iso)
	state=$(echo "$state" | jq --arg ts "$now_iso" '.last_scan = $ts')
	_write_state "$state"

	# Output results
	if [[ "$needs_attention" -gt 0 ]]; then
		echo -e "${YELLOW}${needs_attention} external contribution(s) need your reply:${NC}"
		echo -e "$attention_items"

		# macOS notification (for launchd runs)
		if [[ ! -t 0 ]] && command -v osascript &>/dev/null; then
			osascript -e "display notification \"${needs_attention} contribution(s) need reply\" with title \"aidevops\"" 2>/dev/null || true
		fi
	else
		echo -e "${GREEN}All caught up — no external contributions need attention${NC}"
	fi

	echo "Checked ${notifications_checked} notifications (${items_checked} actionable external threads)."
	_log_info "Scan complete: notifications=${notifications_checked}, actionable=${items_checked}, needs_attention=${needs_attention}"

	# Output machine-readable count for pulse integration
	echo "CONTRIBUTION_WATCH_COUNT=${needs_attention}"

	return 0
}

# =============================================================================
# Status: show watched items
# =============================================================================

cmd_status() {
	_ensure_state_file

	local state
	state=$(_read_state)

	local last_scan
	last_scan=$(echo "$state" | jq -r '.last_scan // "never"')
	local item_count
	item_count=$(echo "$state" | jq '.items | length')

	echo -e "${BLUE}Contribution Watch Status${NC}"
	echo "========================="
	echo "Last scan: ${last_scan}"
	echo "Tracked items: ${item_count}"
	echo ""

	if [[ "$item_count" -eq 0 ]]; then
		echo "No items tracked. Run 'seed' to discover contributions."
		return 0
	fi

	# Group by state
	local now_epoch
	now_epoch=$(date +%s)

	local hot_count=0
	local active_count=0
	local dormant_count=0
	local needs_reply_count=0

	echo -e "${CYAN}Items needing reply:${NC}"
	local found_needing=false

	local keys
	keys=$(echo "$state" | jq -r '.items | keys[]' 2>/dev/null) || keys=""

	while IFS= read -r key; do
		[[ -z "$key" ]] && continue

		local item
		item=$(echo "$state" | jq --arg k "$key" '.items[$k]')
		local title
		title=$(echo "$item" | jq -r '.title // "unknown"')
		local item_type
		item_type=$(echo "$item" | jq -r '.type // "issue"')
		local last_any
		last_any=$(echo "$item" | jq -r '.last_any_comment // ""')
		local last_our
		last_our=$(echo "$item" | jq -r '.last_our_comment // ""')
		local hot_until
		hot_until=$(echo "$item" | jq -r '.hot_until // ""')
		local role
		role=$(echo "$item" | jq -r '.role // "commenter"')

		# Determine activity tier
		if [[ -n "$last_any" ]]; then
			local age_seconds
			age_seconds=$(_seconds_since "$last_any")
			if [[ "$age_seconds" -lt "$HOT_THRESHOLD" ]]; then
				hot_count=$((hot_count + 1))
			elif [[ "$age_seconds" -gt "$DORMANT_THRESHOLD" ]]; then
				dormant_count=$((dormant_count + 1))
			else
				active_count=$((active_count + 1))
			fi
		fi

		# Check if needs reply (someone else has last word and we haven't been notified)
		if [[ -n "$last_any" && ("$last_our" < "$last_any" || -z "$last_our") ]]; then
			needs_reply_count=$((needs_reply_count + 1))
			found_needing=true
			echo "  ${key} (${item_type}, ${role}): ${title}"
			echo "    Last activity: ${last_any}"
		fi
	done <<<"$keys"

	if [[ "$found_needing" == "false" ]]; then
		echo "  None — all caught up!"
	fi

	echo ""
	echo -e "${CYAN}Activity tiers:${NC}"
	echo "  Hot (<24h):     ${hot_count}"
	echo "  Active:         ${active_count}"
	echo "  Dormant (>7d):  ${dormant_count}"
	echo "  Need reply:     ${needs_reply_count}"

	# Show adaptive polling recommendation
	echo ""
	echo -e "${CYAN}Polling schedule:${NC}"
	if [[ "$hot_count" -gt 0 ]]; then
		echo "  Current: every 15 minutes (hot items detected)"
	elif [[ "$active_count" -gt 0 ]]; then
		echo "  Current: every 1 hour (active items)"
	else
		echo "  Current: every 6 hours (all dormant)"
	fi

	return 0
}

# =============================================================================
# Install: create launchd plist
# =============================================================================

cmd_install() {
	local script_path
	script_path=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")

	# Determine polling interval based on current state
	local interval="$POLL_DEFAULT"
	if [[ -f "$STATE_FILE" ]]; then
		local state
		state=$(_read_state)
		local hot_count
		hot_count=$(echo "$state" | jq '[.items[] | select(.hot_until != "" and .hot_until != null)] | length' 2>/dev/null) || hot_count=0
		if [[ "$hot_count" -gt 0 ]]; then
			interval="$POLL_HOT"
		fi
	fi

	# Ensure log directory exists
	mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true

	# Create plist
	cat >"$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${PLIST_LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>${script_path}</string>
		<string>scan</string>
	</array>
	<key>StartInterval</key>
	<integer>${interval}</integer>
	<key>StandardOutPath</key>
	<string>${LOGFILE}</string>
	<key>StandardErrorPath</key>
	<string>${LOGFILE}</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
		<key>HOME</key>
		<string>${HOME}</string>
	</dict>
	<key>RunAtLoad</key>
	<false/>
	<key>KeepAlive</key>
	<false/>
</dict>
</plist>
PLIST

	# Load the plist
	launchctl unload "$PLIST_PATH" 2>/dev/null || true
	launchctl load "$PLIST_PATH" 2>/dev/null || true

	echo -e "${GREEN}Installed launchd plist: ${PLIST_LABEL}${NC}"
	echo "  Plist: ${PLIST_PATH}"
	echo "  Interval: every $((interval / 60)) minutes"
	echo "  Log: ${LOGFILE}"
	_log_info "Installed launchd plist (interval: ${interval}s)"

	return 0
}

# =============================================================================
# Uninstall: remove launchd plist
# =============================================================================

cmd_uninstall() {
	if [[ -f "$PLIST_PATH" ]]; then
		launchctl unload "$PLIST_PATH" 2>/dev/null || true
		rm -f "$PLIST_PATH"
		echo -e "${GREEN}Uninstalled launchd plist: ${PLIST_LABEL}${NC}"
		_log_info "Uninstalled launchd plist"
	else
		echo "No plist found at ${PLIST_PATH}"
	fi
	return 0
}

# =============================================================================
# Help
# =============================================================================

cmd_help() {
	echo "contribution-watch-helper.sh — Monitor external issues/PRs for new activity"
	echo ""
	echo "Usage:"
	echo "  contribution-watch-helper.sh seed [--dry-run]   Discover all external contributions"
	echo "  contribution-watch-helper.sh scan               Check notifications for new external activity"
	echo "  contribution-watch-helper.sh status             Show watched items and their state"
	echo "  contribution-watch-helper.sh install            Install launchd plist"
	echo "  contribution-watch-helper.sh uninstall          Remove launchd plist"
	echo "  contribution-watch-helper.sh help               Show this help"
	echo ""
	echo "State file: ${STATE_FILE}"
	echo "Log file:   ${LOGFILE}"
	echo ""
	echo "Architecture: Automated scans are deterministic (notification metadata only)."
	echo "Managed repos (pulse=true in repos.json) are excluded to suppress internal automation noise."
	echo "Comment bodies are NEVER processed by LLM in automated context."
	echo "Use prompt-guard-helper.sh scan before showing comment bodies interactively."
	return 0
}

# =============================================================================
# Main dispatch
# =============================================================================

main() {
	local cmd="${1:-help}"
	shift 2>/dev/null || true

	# Ensure log directory exists
	mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true

	case "$cmd" in
	seed) cmd_seed "$@" ;;
	scan) cmd_scan "$@" ;;
	status) cmd_status "$@" ;;
	install) cmd_install "$@" ;;
	uninstall) cmd_uninstall "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		echo -e "${RED}Unknown command: ${cmd}${NC}" >&2
		echo "Run 'contribution-watch-helper.sh help' for usage." >&2
		return 1
		;;
	esac
}

main "$@"
