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
		slug=$(jq -r '.initialized_repos[] | select(.is_framework_dir == true) | .slug' \
			"${HOME}/.config/aidevops/repos.json" 2>/dev/null | head -1) || slug=""
	fi
	[[ -z "$slug" ]] && slug="marcusquinn/aidevops"
	printf '%s' "$slug"
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
	# Use --paginate to ensure all results are retrieved (avoids missed dedup on busy repos).
	local existing_number=""
	existing_number=$(gh issue list --repo "$aidevops_slug" --state open \
		--label "$UPSTREAM_WATCH_LABEL" \
		--search "in:title \"upstream: ${slug_or_name}\"" \
		--paginate \
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
	# Use --paginate to ensure all results are retrieved.
	local issue_number=""
	issue_number=$(gh issue list --repo "$aidevops_slug" --state open \
		--label "$UPSTREAM_WATCH_LABEL" \
		--search "in:title \"upstream: ${slug_or_name}\"" \
		--paginate \
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
