#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../approval-helper.sh
source "${SCRIPT_DIR}/approval-helper.sh"

request_file=$(mktemp)
edit_log=$(mktemp)
trap 'rm -f "$request_file" "${request_file}.unsafe" "$edit_log"' EXIT

jq -cnS '{
  schema: "aidevops-permission-request/v1",
  target: {kind: "issue", repository: "owner/repo", number: 123},
  worker: {session: "issue-123", branch: "feature/auto-gh123", worktree_sha256: ("a" * 64)},
  context: {stage: "worker tool execution", changed_files: [], alternatives: "none"},
  capabilities: [{
    permission: "external_directory",
    patterns: ["~/.cache/opencode/node_modules/@opencode-ai/sdk/**"],
    tool: "read",
    intent: "Inspect generated SDK declarations",
    risk: {level: "medium", grantable: true, reason: "external boundary"},
    opencode: {request_id: "oc-1", session_id: "ses-1"}
  }],
  created_at: "2026-07-14T00:00:00Z"
}' >"$request_file"

digest=$(_permission_request_digest "$(<"$request_file")")
request_id="perm-${digest:0:16}"
jq -cS --arg id "$request_id" --arg digest "$digest" \
  '. + {request_id: $id, request_sha256: $digest}' "$request_file" >"${request_file}.bound"
mv "${request_file}.bound" "$request_file"
request_json=$(<"$request_file")

_validate_permission_request_json "$request_json" issue 123 owner/repo "$request_id"

tampered=$(jq -cS '.capabilities[0].patterns = ["~/.config/opencode/**"]' "$request_file")
if _validate_permission_request_json "$tampered" issue 123 owner/repo "$request_id"; then
	printf 'tampered request unexpectedly retained a valid digest\n' >&2
	exit 1
fi

substituted_base=$(jq -cS 'del(.request_id, .request_sha256) | .worker.session = "different-session"' "$request_file")
substituted_digest=$(_permission_request_digest "$substituted_base")
substituted=$(jq -cS --arg id "$request_id" --arg digest "$substituted_digest" \
  '. + {request_id: $id, request_sha256: $digest}' <<<"$substituted_base")
if _validate_permission_request_json "$substituted" issue 123 owner/repo "$request_id"; then
	printf 'substituted request unexpectedly retained the original request ID\n' >&2
	exit 1
fi

unsafe_base=$(jq -cS '
  del(.request_id, .request_sha256)
  | .capabilities[0].patterns = ["~/.ssh/**"]
  | .capabilities[0].risk.grantable = true
' "$request_file")
unsafe_digest=$(_permission_request_digest "$unsafe_base")
unsafe_id="perm-${unsafe_digest:0:16}"
unsafe=$(jq -cS --arg id "$unsafe_id" --arg digest "$unsafe_digest" \
  '. + {request_id: $id, request_sha256: $digest}' <<<"$unsafe_base")
if _validate_permission_request_json "$unsafe" issue 123 owner/repo "$unsafe_id"; then
	printf 'sensitive path unexpectedly passed approval validation\n' >&2
	exit 1
fi

unbounded_base=$(jq -cS '
  del(.request_id, .request_sha256)
  | .capabilities[0].patterns = ["**"]
' "$request_file")
unbounded_digest=$(_permission_request_digest "$unbounded_base")
unbounded_id="perm-${unbounded_digest:0:16}"
unbounded=$(jq -cS --arg id "$unbounded_id" --arg digest "$unbounded_digest" \
  '. + {request_id: $id, request_sha256: $digest}' <<<"$unbounded_base")
if _validate_permission_request_json "$unbounded" issue 123 owner/repo "$unbounded_id"; then
	printf 'unbounded path unexpectedly passed approval validation\n' >&2
	exit 1
fi

gh_issue_view() {
	local issue_number="$1"
	: "$issue_number"
	printf '%s\n' '{"labels":[{"name":"status:blocked"},{"name":"needs-maintainer-permissions"}]}'
	return 0
}

gh_issue_edit_safe() {
	local issue_number="$1"
	shift
	printf '%s %s\n' "$issue_number" "$*" >"$edit_log"
	return 0
}

_apply_permission_approval_state issue 123 owner/repo "$request_json"
edit_args=$(<"$edit_log")
[[ "$edit_args" == *"--remove-label needs-maintainer-permissions"* ]]
[[ "$edit_args" != *"--remove-label status:blocked"* ]]
[[ "$edit_args" != *"--add-label status:available"* ]]
[[ "$edit_args" != *"--add-label auto-dispatch"* ]]

printf 'permission approval content-binding tests passed\n'
