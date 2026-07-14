#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../worker-permission-helper.sh
source "${SCRIPT_DIR}/worker-permission-helper.sh"

test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT
capture_file="${test_root}/capture.json"

cat >"$capture_file" <<'JSON'
{
  "schema": "aidevops-permission-capture/v1",
  "issue": "123",
  "repo": "owner/repo",
  "worker_session": "issue-123",
  "requests": [{
    "request_id": "perm-source",
    "permission": "external_directory",
    "patterns": ["~/.cache/opencode/node_modules/@opencode-ai/sdk/**"],
    "tool": "read",
    "intent": "Inspect generated SDK declarations",
    "risk": {"level": "medium", "grantable": true, "reason": "external boundary"},
    "opencode": {"request_id": "oc-1", "session_id": "ses-1"}
  }]
}
JSON

permission_validate_capture "$capture_file" 123 owner/repo
envelope=$(permission_build_envelope "$capture_file" 123 owner/repo issue-123 "$PWD" '{"auto_dispatch":true}')
expected_worktree_digest=$(permission_sha256_text "$PWD")
jq -e '
  .schema == "aidevops-permission-request/v1"
  and (.request_id | test("^perm-[0-9a-f]{16}$"))
  and .target.repository == "owner/repo"
  and .capabilities[0].tool == "read"
' <<<"$envelope" >/dev/null
jq -e --arg digest "$expected_worktree_digest" '.worker.worktree_sha256 == $digest' <<<"$envelope" >/dev/null
jq -e '.context.resume_auto_dispatch == true' <<<"$envelope" >/dev/null
if [[ "$envelope" == *"$PWD"* ]]; then
	printf 'permission envelope exposed the local worktree path\n' >&2
	exit 1
fi

jq '.requests[0].patterns = ["/Users/private/.ssh/id_ed25519"]' "$capture_file" >"${capture_file}.unsafe"
if permission_validate_capture "${capture_file}.unsafe" 123 owner/repo; then
	printf 'unsafe private path unexpectedly passed validation\n' >&2
	exit 1
fi

printf 'worker permission helper tests passed\n'
