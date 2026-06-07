#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Upstream Watch Issues -- GitHub issue filing and closing (t2810)
# =============================================================================
# Sub-library for upstream-watch-helper.sh. Handles filing and closing GitHub
# issues when upstream updates are detected or acknowledged.
#
# Usage: source "${SCRIPT_DIR}/upstream-watch-helper-issues.sh"
#
# Dependencies:
#   - shared-constants.sh (gh_create_issue, gh_issue_comment, gh_issue_edit_safe, etc.)
#   - upstream-watch-helper-state.sh (_log_info, _log_warn)
#   - Expects SCRIPT_DIR, UPSTREAM_WATCH_LABEL globals set by orchestrator
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_UPSTREAM_WATCH_ISSUES_LIB_LOADED:-}" ]] && return 0
_UPSTREAM_WATCH_ISSUES_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

if ! declare -F _gh_collaborator_permission_lookup >/dev/null 2>&1; then
	if [[ -f "${SCRIPT_DIR}/github-app-auth-helper.sh" ]]; then
		# shellcheck source=./github-app-auth-helper.sh
		source "${SCRIPT_DIR}/github-app-auth-helper.sh"
	fi
	if [[ -f "${SCRIPT_DIR}/shared-gh-wrappers-rest-fallback.sh" ]]; then
		# shellcheck source=./shared-gh-wrappers-rest-fallback.sh
		source "${SCRIPT_DIR}/shared-gh-wrappers-rest-fallback.sh"
	fi
	if [[ -f "${SCRIPT_DIR}/shared-gh-collaborator-permission.sh" ]]; then
		# shellcheck source=./shared-gh-collaborator-permission.sh
		source "${SCRIPT_DIR}/shared-gh-collaborator-permission.sh"
	fi
fi

# =============================================================================
# GitHub issue filing (t2810)
# =============================================================================

#######################################
# Look up the local aidevops repo slug for issue filing
# Outputs: owner/repo slug string
# Returns: 0 always
#######################################
_get_aidevops_slug() {
	local slug=""
	if [[ -f "${HOME}/.config/aidevops/repos.json" ]]; then
		slug=$(jq -r 'first(.initialized_repos[] | select(.is_framework_dir == true) | .slug) // ""' \
			"${HOME}/.config/aidevops/repos.json" 2>/dev/null) || slug=""
	fi
	[[ -z "$slug" ]] && slug="marcusquinn/aidevops"
	printf '%s' "$slug"
	return 0
}

#######################################
# Check whether authenticated gh may write public upstream-watch issues.
# Arguments:
#   $1 - aidevops repo slug receiving upstream-watch issues
# Returns: 0 when issue writes are authorized, 1 otherwise
#######################################
_upstream_watch_issue_creation_authorized() {
	local aidevops_slug="$1"

	if [[ "${AIDEVOPS_UPSTREAM_WATCH_ALLOW_PUBLIC_ISSUES:-}" == "1" ]]; then
		return 0
	fi

	local login=""
	login=$(gh api user --jq '.login // ""' 2>/dev/null) || login=""
	if [[ -z "$login" ]]; then
		_log_warn "Unable to resolve gh login -- upstream-watch public issue creation disabled for ${aidevops_slug}"
		return 1
	fi

	local permission=""
	# #aidevops:trust-boundary — public upstream-watch issue creation requires
	# confirmed write+ access; API lookup failures skip without claiming none.
	if ! _gh_collaborator_permission_lookup "$aidevops_slug" "$login" permission; then
		_log_warn "Skipping public upstream-watch issue creation in ${aidevops_slug}: permission check failed for gh user ${login} (HTTP ${AIDEVOPS_GH_COLLAB_PERMISSION_HTTP:-unknown})"
		return 1
	fi

	case "$permission" in
		admin | maintain | write)
			return 0
			;;
		*)
			_log_warn "Skipping public upstream-watch issue creation in ${aidevops_slug}: gh user ${login} has permission '${permission:-none}', not maintainer/collaborator write access"
			return 1
			;;
	esac
}

#######################################
# Persist a local upstream-watch report when public issue creation is not
# authorized. The report is local to the install and avoids public repo spam.
# Arguments:
#   $1 - title
#   $2 - body
# Outputs: local report path via stdout
#######################################
_write_upstream_watch_local_report() {
	local title="$1"
	local body="$2"
	local report_dir="${HOME}/.aidevops/reports/upstream-watch"
	local stamp
	stamp=$(date -u +%Y%m%dT%H%M%SZ)

	mkdir -p "$report_dir"
	local report_file
	report_file=$(mktemp "${report_dir}/${stamp}.XXXXXX.md")
	{
		printf '# %s\n\n' "$title"
		printf '%s\n' "$body"
	} >"$report_file"
	printf '%s' "$report_file"
	return 0
}

#######################################
# Queue a detected upstream update for end-of-run coalescing.
# Falls back to immediate filing when no queue file is configured.
# Arguments: same as _file_upstream_update_issue
#######################################
_queue_upstream_update_issue() {
	local slug_or_name="$1"
	local kind="$2"
	local old_value="$3"
	local new_value="$4"
	local entry_json="$5"

	if [[ -z "${_UPSTREAM_WATCH_ISSUE_QUEUE_FILE:-}" ]]; then
		_file_upstream_update_issue "$slug_or_name" "$kind" "$old_value" "$new_value" "$entry_json"
		return 0
	fi

	jq -nc \
		--arg slug_or_name "$slug_or_name" \
		--arg kind "$kind" \
		--arg old_value "$old_value" \
		--arg new_value "$new_value" \
		--argjson entry "$entry_json" \
		'{slug_or_name:$slug_or_name, kind:$kind, old_value:$old_value, new_value:$new_value, entry:$entry}' \
		>>"$_UPSTREAM_WATCH_ISSUE_QUEUE_FILE"
	return 0
}

#######################################
# Compose a single batch tracker issue for multiple upstream updates.
# Arguments:
#   $1 - queue file containing one JSON object per update
# Outputs: issue body text via stdout
#######################################
_compose_upstream_batch_issue_body() {
	local queue_file="$1"

	printf '## Summary\n\n'
	printf 'Multiple upstream-watch sources changed in the same scan run. Review this coalesced tracker instead of one issue per upstream.\n\n'
	printf '## Updates\n\n'
	printf '| Upstream | Kind | Previous | Current | Relevance |\n'
	printf '|----------|------|----------|---------|-----------|\n'
	while IFS= read -r update_json; do
		[[ -n "$update_json" ]] || continue
		local slug_or_name kind old_value new_value relevance
		slug_or_name=$(printf '%s' "$update_json" | jq -r '.slug_or_name')
		kind=$(printf '%s' "$update_json" | jq -r '.kind')
		old_value=$(printf '%s' "$update_json" | jq -r '.old_value // "none"')
		new_value=$(printf '%s' "$update_json" | jq -r '.new_value')
		relevance=$(printf '%s' "$update_json" | jq -r '.entry.relevance // .entry.description // "Review upstream changes"')
		printf "| \`%s\` | %s | \`%s\` | \`%s\` | %s |\n" \
			"$slug_or_name" "$kind" "${old_value:-none}" "${new_value:0:12}" "$relevance"
	done <"$queue_file"
	printf '\n## Action\n\n'
	printf '1. Review each upstream source above.\n'
	printf '2. Decide which changes warrant adoption.\n'
	printf "3. Acknowledge reviewed sources with \`upstream-watch-helper.sh ack <upstream>\`.\n\n"
	printf '<!-- aidevops:generator=upstream-watch batch=true -->\n'
	return 0
}

#######################################
# File or locally report a coalesced upstream-watch batch issue.
# Arguments:
#   $1 - queue file containing one JSON object per update
# Returns: 0 always for offline/unauthorized paths
#######################################
_file_upstream_batch_update_issue() {
	local queue_file="$1"
	local title="upstream: batch review adoption"
	local body
	body=$(_compose_upstream_batch_issue_body "$queue_file")

	if ! command -v gh &>/dev/null || ! gh auth status &>/dev/null; then
		_log_warn "gh unavailable -- writing local upstream-watch batch report"
		local offline_report
		offline_report=$(_write_upstream_watch_local_report "$title" "$body")
		echo -e "  ${YELLOW}Local upstream-watch report: ${offline_report}${NC}"
		return 0
	fi

	local aidevops_slug
	aidevops_slug=$(_get_aidevops_slug)
	if ! _upstream_watch_issue_creation_authorized "$aidevops_slug"; then
		local report_file
		report_file=$(_write_upstream_watch_local_report "$title" "$body")
		_log_info "Wrote local upstream-watch batch report: ${report_file}"
		echo -e "  ${YELLOW}Skipped public issue creation; local report: ${report_file}${NC}"
		return 0
	fi

	local existing_number=""
	existing_number=$(gh issue list --repo "$aidevops_slug" --state open \
		--label "$UPSTREAM_WATCH_LABEL" \
		--search 'in:title "upstream: batch"' \
		--limit 1000 \
		--json number --jq '.[0].number // empty') || existing_number=""

	local sig_footer=""
	if [[ -x "${SCRIPT_DIR}/gh-signature-helper.sh" ]]; then
		sig_footer=$("${SCRIPT_DIR}/gh-signature-helper.sh" footer 2>/dev/null || true)
	fi
	[[ -n "$sig_footer" ]] && body="${body}

${sig_footer}"

	if [[ -n "$existing_number" ]]; then
		_log_info "Updating existing upstream-watch batch issue #${existing_number}"
		gh_issue_edit_safe "$existing_number" --repo "$aidevops_slug" \
			--title "$title" --body "$body" >/dev/null 2>&1 || {
			_log_warn "Failed to update upstream-watch batch issue #${existing_number}"
			return 0
		}
		echo -e "  ${BLUE}Updated batch issue #${existing_number}${NC}"
	else
		local issue_url=""
		issue_url=$(gh_create_issue --repo "$aidevops_slug" \
			--title "$title" \
			--label "$UPSTREAM_WATCH_LABEL" \
			--label "auto-dispatch" \
			--label "tier:standard" \
			--label "origin:worker" \
			--body "$body" 2>/dev/null) || {
			_log_warn "Failed to file upstream-watch batch issue -- will retry next cycle"
			return 0
		}
		[[ -n "$issue_url" ]] && echo -e "  ${BLUE}Filed batch issue: ${issue_url}${NC}"
	fi
	return 0
}

#######################################
# Flush queued upstream update issue requests, coalescing large batches.
# Arguments:
#   $1 - queue file containing one JSON object per update
# Returns: 0 always for empty queues and handled issue paths
#######################################
_flush_upstream_update_issue_queue() {
	local queue_file="$1"

	if [[ ! -s "$queue_file" ]]; then
		return 0
	fi

	local threshold="${UPSTREAM_WATCH_BATCH_THRESHOLD:-5}"
	local queue_count
	queue_count=$(wc -l <"$queue_file" | tr -d '[:space:]')
	[[ "$queue_count" =~ ^[0-9]+$ ]] || queue_count=0

	if [[ "$queue_count" -ge "$threshold" ]]; then
		_file_upstream_batch_update_issue "$queue_file"
		return 0
	fi

	while IFS= read -r update_json; do
		[[ -n "$update_json" ]] || continue
		local slug_or_name kind old_value new_value entry_json
		slug_or_name=$(printf '%s' "$update_json" | jq -r '.slug_or_name')
		kind=$(printf '%s' "$update_json" | jq -r '.kind')
		old_value=$(printf '%s' "$update_json" | jq -r '.old_value')
		new_value=$(printf '%s' "$update_json" | jq -r '.new_value')
		entry_json=$(printf '%s' "$update_json" | jq -c '.entry')
		_file_upstream_update_issue "$slug_or_name" "$kind" "$old_value" "$new_value" "$entry_json"
	done <"$queue_file"
	return 0
}

#######################################
# Compose the issue body for an upstream update notification.
# Extracted from _file_upstream_update_issue() to reduce complexity.
# Arguments:
#   $1 - slug_or_name
#   $2 - kind
#   $3 - old_display   (previous version/commit or "none")
#   $4 - new_value_short
#   $5 - relevance     (may be empty)
#   $6 - affects       (newline-separated list, may be empty)
#   $7 - compare_url   (may be empty)
# Outputs: issue body text via stdout
#######################################
_compose_upstream_issue_body() {
	local slug_or_name="$1"
	local kind="$2"
	local old_display="$3"
	local new_value_short="$4"
	local relevance="$5"
	local affects="$6"
	local compare_url="$7"

	# Build affects section using real newlines to avoid printf %b backslash expansion
	# on user/config-provided data (e.g. Windows paths with \t would be misinterpreted).
	local affects_section="See relevance text above."
	if [[ -n "$affects" ]]; then
		affects_section=""
		while IFS= read -r af; do
			[[ -n "$af" ]] || continue
			if [[ -z "$affects_section" ]]; then
				affects_section="- \`${af}\`"
			else
				affects_section="${affects_section}"$'\n'"- \`${af}\`"
			fi
		done <<<"$affects"
		[[ -z "$affects_section" ]] && affects_section="See relevance text above."
	fi

	cat <<ISSUEEOF
## Summary

${relevance:-Upstream repo monitored for relevant changes.}

## What Changed

| Field | Value |
|-------|-------|
| Upstream | \`${slug_or_name}\` |
| Kind | ${kind} |
| Previous | \`${old_display}\` |
| Current | \`${new_value_short}\` |
$(if [[ -n "$compare_url" ]]; then echo "| Compare | [view diff](${compare_url}) |"; fi)

## Affects

${affects_section}

## Action

1. Review the upstream changes${compare_url:+ at the [compare link](${compare_url})}
2. Determine if adoption is needed (new feature, bug fix, security patch)
3. If adopting: create a PR with the relevant changes
4. Mark as reviewed: \`upstream-watch-helper.sh ack ${slug_or_name}\`

<!-- aidevops:generator=upstream-watch upstream_slug=${slug_or_name} -->
<!-- upstream-watch:slug=${slug_or_name} -->
ISSUEEOF
	return 0
}

#######################################
# File a GitHub issue when an upstream update is detected (0->1 transition).
# Deduplicates by searching for open issues with the same title prefix.
# If a matching open issue exists and the upstream has advanced further,
# the existing issue body is updated instead of creating a duplicate.
#
# Arguments:
#   $1 - slug_or_name  (upstream repo slug or non-GitHub entry name)
#   $2 - kind          (release|commit|update)
#   $3 - old_value     (previous version/commit, may be empty)
#   $4 - new_value     (new version/commit)
#   $5 - entry_json    (config entry JSON for relevance, affects, etc.)
# Returns: 0 on success or gh offline, 1 on unexpected error
#######################################
_file_upstream_update_issue() {
	local slug_or_name="$1"
	local kind="$2"
	local old_value="$3"
	local new_value="$4"
	local entry_json="$5"

	# Bail if gh is not available (offline mode -- don't break the check loop)
	if ! command -v gh &>/dev/null || ! gh auth status &>/dev/null; then
		_log_warn "gh unavailable -- skipping issue filing for ${slug_or_name}"
		return 0
	fi

	local aidevops_slug
	aidevops_slug=$(_get_aidevops_slug)

	local new_value_short="${new_value:0:12}"
	local title="upstream: ${slug_or_name} ${kind} -> ${new_value_short} (review adoption)"

	# --- Dedup: check for existing open issue ---
	# Quote the search term to handle slugs/names with special characters or spaces.
	# Use a high limit because `gh issue list` does not support `--paginate`.
	local existing_number=""
	existing_number=$(gh issue list --repo "$aidevops_slug" --state open \
		--label "$UPSTREAM_WATCH_LABEL" \
		--search "in:title \"upstream: ${slug_or_name}\"" \
		--limit 1000 \
		--json number --jq '.[0].number // empty') || existing_number=""

	# Extract relevance, affects, and upstream URL from config entry
	local relevance="" affects="" upstream_url=""
	if [[ -n "$entry_json" ]]; then
		relevance=$(printf '%s' "$entry_json" | jq -r '.relevance // ""' 2>/dev/null) || relevance=""
		affects=$(printf '%s' "$entry_json" | jq -r '.affects // [] | .[]' 2>/dev/null) || affects=""
		local entry_slug=""
		entry_slug=$(printf '%s' "$entry_json" | jq -r '.slug // ""' 2>/dev/null) || entry_slug=""
		if [[ -n "$entry_slug" ]]; then
			upstream_url="https://github.com/${entry_slug}"
		else
			upstream_url=$(printf '%s' "$entry_json" | jq -r '.url // ""' 2>/dev/null) || upstream_url=""
		fi
	fi

	# Build compare URL for GitHub repos
	local compare_url=""
	if [[ -n "$old_value" && -n "$upstream_url" && "$upstream_url" == *"github.com"* ]]; then
		compare_url="${upstream_url}/compare/${old_value}...${new_value_short}"
	fi

	# Compose body via helper and append signature footer
	local body
	body=$(_compose_upstream_issue_body "$slug_or_name" "$kind" "${old_value:-none}" \
		"$new_value_short" "$relevance" "$affects" "$compare_url")
	if ! _upstream_watch_issue_creation_authorized "$aidevops_slug"; then
		local report_file
		report_file=$(_write_upstream_watch_local_report "$title" "$body")
		_log_info "Wrote local upstream-watch report for ${slug_or_name}: ${report_file}"
		echo -e "  ${YELLOW}Skipped public issue creation; local report: ${report_file}${NC}"
		return 0
	fi

	local sig_footer=""
	if [[ -x "${SCRIPT_DIR}/gh-signature-helper.sh" ]]; then
		sig_footer=$("${SCRIPT_DIR}/gh-signature-helper.sh" footer 2>/dev/null || true)
	fi
	[[ -n "$sig_footer" ]] && body="${body}

${sig_footer}"

	if [[ -n "$existing_number" ]]; then
		# Update existing issue title and body if upstream advanced further
		_log_info "Updating existing issue #${existing_number} for ${slug_or_name}"
		gh_issue_edit_safe "$existing_number" --repo "$aidevops_slug" \
			--title "$title" --body "$body" >/dev/null 2>&1 || {
			_log_warn "Failed to update issue #${existing_number} for ${slug_or_name}"
			return 0
		}
		echo -e "  ${BLUE}Updated issue #${existing_number}${NC}"
	else
		# Create new issue
		_log_info "Filing issue for upstream update: ${slug_or_name} ${kind} -> ${new_value_short}"
		local issue_url=""
		issue_url=$(gh_create_issue --repo "$aidevops_slug" \
			--title "$title" \
			--label "$UPSTREAM_WATCH_LABEL" \
			--label "auto-dispatch" \
			--label "tier:standard" \
			--label "origin:worker" \
			--body "$body" 2>/dev/null) || {
			_log_warn "Failed to file issue for ${slug_or_name} -- will retry next cycle"
			return 0
		}
		if [[ -n "$issue_url" ]]; then
			_log_info "Filed issue: ${issue_url}"
			echo -e "  ${BLUE}Filed issue: ${issue_url}${NC}"
		fi
	fi
	return 0
}

#######################################
# Close the open upstream-watch issue for a given slug/name on ack.
# Searches for open issues with the source:upstream-watch label and
# matching title, then posts an ack comment and closes.
#
# Arguments:
#   $1 - slug_or_name  (upstream repo slug or non-GitHub entry name)
#   $2 - note          (optional user-supplied note for the close comment)
# Returns: 0 always (offline/failure is non-fatal)
#######################################
_close_upstream_update_issue() {
	local slug_or_name="$1"
	local note="${2:-}"

	# Bail if gh is not available
	if ! command -v gh &>/dev/null || ! gh auth status &>/dev/null; then
		_log_warn "gh unavailable -- skipping issue close for ${slug_or_name}"
		return 0
	fi

	local aidevops_slug
	aidevops_slug=$(_get_aidevops_slug)

	# Find matching open issue.
	# Quote the search term to handle slugs/names with special characters or spaces.
	# Use a high limit because `gh issue list` does not support `--paginate`.
	local issue_number=""
	issue_number=$(gh issue list --repo "$aidevops_slug" --state open \
		--label "$UPSTREAM_WATCH_LABEL" \
		--search "in:title \"upstream: ${slug_or_name}\"" \
		--limit 1000 \
		--json number --jq '.[0].number // empty') || issue_number=""

	if [[ -z "$issue_number" ]]; then
		_log_info "No open upstream-watch issue found for ${slug_or_name} -- nothing to close"
		return 0
	fi

	# Build ack comment
	local comment_body="> Acked by user."
	if [[ -n "$note" ]]; then
		comment_body="> Acked by user. Adoption: ${note}"
	fi

	# Append signature footer
	local sig_footer=""
	if [[ -x "${SCRIPT_DIR}/gh-signature-helper.sh" ]]; then
		sig_footer=$("${SCRIPT_DIR}/gh-signature-helper.sh" footer --issue "${aidevops_slug}#${issue_number}" --solved 2>/dev/null || true)
	fi
	[[ -n "$sig_footer" ]] && comment_body="${comment_body}

${sig_footer}"

	# Post comment and close
	gh_issue_comment "$issue_number" --repo "$aidevops_slug" --body "$comment_body" >/dev/null 2>&1 || {
		_log_warn "Failed to post ack comment on issue #${issue_number}"
	}
	gh issue close "$issue_number" --repo "$aidevops_slug" --reason "completed" >/dev/null 2>&1 || {
		_log_warn "Failed to close issue #${issue_number}"
	}

	_log_info "Closed upstream-watch issue #${issue_number} for ${slug_or_name}"
	echo -e "  ${GREEN}Closed issue #${issue_number}${NC}"
	return 0
}
