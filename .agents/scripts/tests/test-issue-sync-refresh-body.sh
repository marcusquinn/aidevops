#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(cd "$test_dir/.." && pwd)"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
export AIDEVOPS_TEMP_DIR="$root"
REPO_SLUG=example/repo
DRY_RUN=false
print_error() { printf '%s\n' "$*" >&2; return 0; }
_gh_current_user_allows_repo_write() {
	AIDEVOPS_GH_WRITE_PERMISSION_USER=maintainer
	AIDEVOPS_GH_WRITE_PERMISSION_LEVEL=maintain
	return 0
}
# shellcheck source=../issue-sync-helper-body-common.sh
source "$SCRIPT_DIR/issue-sync-helper-body-common.sh"
# shellcheck source=../issue-sync-helper-refresh.sh
source "$SCRIPT_DIR/issue-sync-helper-refresh.sh"
_body_sync_scan_file() { return 0; }
_refresh_audit() { return 0; }
body=$'Old content\n\n<!-- aidevops:origin:interactive -->\n<!-- aidevops:sig -->\n---\nSigned by framework\n\n<!-- feedback-route:start:one -->\nConflict recovery\n<!-- feedback-route:complete:one -->'
printf '%s\n' 'New content' >"$root/brief"
_body_sync_fetch_state() {
	jq -n --arg body "$body" --arg state "${state:-OPEN}" --arg label "${label:-}" \
		'{number:123,title:"Example",body:$body,state:$state,updatedAt:"now",labels:(if $label == "" then [] else [{name:$label}] end),assignees:[]}'
	return 0
}
gh_issue_edit_safe() {
	local issue="$1" flag="$2" repo="$3" option="$4" file="$5"
	[[ "$issue" == 123 && "$flag" == --repo && "$repo" == example/repo && "$option" == --body-file ]] || return 1
	body=$(<"$file")
	return 0
}
cmd_refresh_body 123 "$root/brief"
[[ "$body" == 'New content'* && "$body" == *'Signed by framework'* && "$body" == *'Conflict recovery'* ]]
[[ $(printf '%s\n' "$body" | rg -c '^<!-- aidevops:sig -->') == 1 ]]
printf '%s\n' '<!-- aidevops:sig -->' '---' 'Replacement signature' >>"$root/brief"
cmd_refresh_body 123 "$root/brief"
[[ $(printf '%s\n' "$body" | rg -c '^<!-- aidevops:sig -->') == 1 ]]
[[ "$body" == *'Conflict recovery'* ]]
body_before="$body"
cmd_refresh_body 123 "$root/brief"
[[ "$body" == "$body_before" ]]
state=CLOSED
if cmd_refresh_body 123 "$root/brief"; then exit 1; fi
state=OPEN label=status:queued
if cmd_refresh_body 123 "$root/brief"; then exit 1; fi
label=""
printf '%s\n' 'Different content' >"$root/brief"
DRY_RUN=true
if cmd_refresh_body 123 "$root/brief"; then exit 1; else [[ $? -eq 2 ]]; fi
[[ "$body" == "$body_before" ]]
printf '%s\n' 'PASS: refresh preserves appendages, avoids duplicate signature, blocks unsafe states and dry-run writes'
