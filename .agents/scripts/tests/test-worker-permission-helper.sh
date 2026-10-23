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
export AIDEVOPS_WORKER_BLOCKER_LOG_FILE="${test_root}/blockers.jsonl"
gh_call_log="${test_root}/gh-calls.log"
posted_comment="${test_root}/permission-comment.md"

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
  }, {
    "request_id": "perm-tool-discovery",
    "permission": "external_directory",
    "patterns": ["~/.qlty/bin/*"],
    "tool": "read",
    "intent": "Locate the Qlty executable",
    "risk": {"level": "high", "grantable": false, "reason": "external boundary"},
    "opencode": {"request_id": "oc-2", "session_id": "ses-1"}
  }]
}
JSON

permission_validate_capture "$capture_file" 123 owner/repo
capability_summary=$(permission_blocker_capability_json "$capture_file")
jq -e 'select(
  .permission == "external_directory×2"
  and .tool == "read×2"
  and .risk_level == "high"
  and .grantable == false
)' <<<"$capability_summary" >/dev/null
single_capture="${test_root}/single-capture.json"
jq '.requests = [.requests[0]]' "$capture_file" >"$single_capture"
single_capability_summary=$(permission_blocker_capability_json "$single_capture")
jq -e 'select(
  .permission == "external_directory"
  and .tool == "read"
  and .risk_level == "medium"
  and .grantable == true
)' <<<"$single_capability_summary" >/dev/null
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
envelope_file="${test_root}/envelope.json"
printf '%s\n' "$envelope" >"$envelope_file"
rendered_capabilities=$(permission_render_capabilities "$envelope_file")
capability_marker="- **external_directory** via \`read\`"
target_marker="**Target:** \`owner/repo#123\`"
session_marker="**Worker session:** \`issue-123\`"
if [[ "$rendered_capabilities" != *"$capability_marker"* ]]; then
	printf 'permission capability summary was empty or incomplete\n' >&2
	exit 1
fi
# shellcheck disable=SC2016 # Markdown backticks are intentional literals.
if [[ "$rendered_capabilities" != *'Routine tool discovery should use `command -v TOOL`'* ]]; then
	printf 'known tool-bin read omitted command-based recovery guidance\n' >&2
	exit 1
fi
if [[ "$rendered_capabilities" != *'no unsigned supersession path'* ]]; then
	printf 'dependency read omitted owned recovery and signed-hold limitation\n' >&2
	exit 1
fi
executing_envelope="${test_root}/executing-envelope.json"
jq '.capabilities |= map(.tool = "bash" | .patterns = ["~/**"])' "$envelope_file" >"$executing_envelope"
if [[ "$(permission_render_capabilities "$executing_envelope")" == *'Owned recovery:'* ]]; then
	printf 'broad external bash was misclassified as a dependency read\n' >&2
	exit 1
fi
# Existing request IDs own unchanged recovery; do not create another comment.
(
	gh_issue_view() { printf '{"labels":[]}\n'; return 0; }
	permission_request_already_posted() { return 0; }
	gh_issue_comment() { printf 'duplicate request comment\n' >&2; return 1; }
	permission_post_request "$single_capture" 123 owner/repo issue-123 "$PWD" >/dev/null
)
printf '{invalid-json\n' >"${test_root}/invalid-envelope.json"
if permission_render_capabilities "${test_root}/invalid-envelope.json" >/dev/null 2>&1; then
	printf 'permission capability rendering hid a jq failure\n' >&2
	exit 1
fi

jq '.requests[0].patterns = ["/Users/private/.ssh/id_ed25519"]' "$capture_file" >"${capture_file}.unsafe"
if permission_validate_capture "${capture_file}.unsafe" 123 owner/repo; then
	printf 'unsafe private path unexpectedly passed validation\n' >&2
	exit 1
fi

repo_dir="${test_root}/repo"
git init -q "$repo_dir"
gh() {
	printf '%s\n' "$*" >>"$gh_call_log"
	printf '0\n'
	return 0
}
gh_issue_view() {
	printf '{"labels":[]}\n'
	return 0
}
gh_issue_comment() {
	local body_file="${5:-}"
	[[ -f "$body_file" ]] || return 1
	cp "$body_file" "$posted_comment"
	return $?
}
gh_issue_edit_safe() {
	printf '%s\n' "$*" >>"$gh_call_log"
	return 0
}
cmd_block --issue 123 --repo owner/repo
if ! grep -q -- '--add-label needs-maintainer-permissions --add-label status:blocked' "$gh_call_log"; then
	printf 'terminal permission block omitted maintainer labels\n' >&2
	exit 1
fi
if cmd_block --issue invalid --repo owner/repo >/dev/null 2>&1; then
	printf 'terminal permission block accepted an invalid issue number\n' >&2
	exit 1
fi
(
	cd "$test_root"
	cmd_request --file "$single_capture" --issue 123 --repo owner/repo --session issue-123 --work-dir "$repo_dir"
)
if grep -q -- '--slurp' "$gh_call_log"; then
	printf 'permission comment lookup combined unsupported --slurp with --jq\n' >&2
	exit 1
fi
if ! grep -q -- '--paginate' "$gh_call_log"; then
	printf 'permission comment lookup did not request all pages\n' >&2
	exit 1
fi
if ! grep -Fq -- '[.[] | select' "$gh_call_log"; then
	printf 'permission comment lookup did not use page-local jq input\n' >&2
	exit 1
fi
if ! grep -Fq -- "$capability_marker" "$posted_comment"; then
	printf 'permission comment omitted the human-readable capability summary\n' >&2
	exit 1
fi
if ! grep -Fq -- "$target_marker" "$posted_comment"; then
	printf 'permission comment omitted the correlated issue target\n' >&2
	exit 1
fi
if ! grep -Fq -- "$session_marker" "$posted_comment"; then
	printf 'permission comment omitted the correlated worker session\n' >&2
	exit 1
fi
git_dir=$(git -C "$repo_dir" rev-parse --absolute-git-dir)
if [[ ! -f "${git_dir}/aidevops-permission-pending" ]]; then
	printf 'permission pending marker was not written to the target repository git directory\n' >&2
	exit 1
fi
if ! jq -e 'select(.issue == 123 and .session == "issue-123" and (.request_id | test("^perm-[0-9a-f]{16}$")))' \
	"${git_dir}/aidevops-permission-pending" >/dev/null; then
	printf 'permission pending marker omitted its issue or worker session owner\n' >&2
	exit 1
fi
jq -e 'select(.event == "permission_awaiting_approval" and .reason == "needs_maintainer_permissions" and .blocking == true
  and .issue_number == 123 and .repo_slug == "owner/repo" and .session_key == "issue-123"
  and .permission == "external_directory" and .tool == "read"
  and .risk_level == "medium" and .grantable == true)' \
	"$AIDEVOPS_WORKER_BLOCKER_LOG_FILE" >/dev/null
# Unsupported permission kinds must never invite an unusable signature, even
# when the capture's risk classifier incorrectly claims they are grantable.
for unsupported_permission in task read unknown; do
	unsupported_capture="${test_root}/unsupported.json"
	jq --arg permission "$unsupported_permission" \
		'.requests = [.requests[0] | .permission = $permission | .tool = "task" | .patterns = ["playwright"] | .risk.grantable = true]' \
		"$capture_file" >"$unsupported_capture"
	: >"$gh_call_log"
	rm -f "$posted_comment" "${git_dir}/aidevops-permission-pending"
	unsupported_rc=0
	cmd_request --file "$unsupported_capture" --issue 123 --repo owner/repo --session issue-123 \
		--work-dir "$repo_dir" || unsupported_rc=$?
	[[ "$unsupported_rc" -eq 1 ]]
	grep -q 'permission_non_grantable' "$posted_comment"
	grep -q 'static subagent allowlist/routing' "$posted_comment"
	if grep -q 'sudo aidevops approve permissions' "$posted_comment" ||
		grep -q 'needs-maintainer-permissions' "$gh_call_log" ||
		[[ -f "${git_dir}/aidevops-permission-pending" ]]; then
		printf 'unsupported permission invited approval or persisted an approval hold\n' >&2
		exit 1
	fi
	jq -e --arg permission "$unsupported_permission" \
		'select(.reason == "permission_non_grantable" and .permission == $permission and .grantable == false)' \
		"$AIDEVOPS_WORKER_BLOCKER_LOG_FILE" >/dev/null
done
mixed_capture="${test_root}/mixed.json"
jq --slurpfile unsupported "$unsupported_capture" '.requests += $unsupported[0].requests' "$single_capture" >"$mixed_capture"
jq -e '.grantable == false' <<<"$(permission_blocker_capability_json "$mixed_capture")" >/dev/null
# GH#35128: temp/scratch writes are owned recovery; other external writes are not.
temp_capture="${test_root}/temp-capture.json"
jq '.requests = [.requests[0] | .permission = "external_directory" | .tool = "write" | .patterns = ["~/.aidevops-private/tmp/*"]]' \
	"$capture_file" >"$temp_capture"
permission_capture_is_temp_write_recovery "$temp_capture"
: >"$gh_call_log"
temp_rc=0
temp_out=$(cmd_request --file "$temp_capture" --issue 123 --repo owner/repo --session issue-123 --work-dir "$repo_dir") || temp_rc=$?
if [[ "$temp_rc" -ne "$PERMISSION_OWNED_RECOVERY_RC" || "$temp_out" != *'AIDEVOPS_TEMP_DIR'* ]]; then
	printf 'temp-path write was not classified as owned recovery\n' >&2
	exit 1
fi
if grep -q -- 'needs-maintainer-permissions' "$gh_call_log"; then
	printf 'temp-path write applied the maintainer permission hold\n' >&2
	exit 1
fi
# shellcheck disable=SC2088 # Literal tilde patterns mirror captured requests.
for unsafe_pattern in '~/projects/app/src/**' '~/.ssh/**' '~/.cache/../.ssh/id' '~/.aws/tmp/credentials'; do
	jq --arg p "$unsafe_pattern" '.requests[0].patterns = [$p]' "$temp_capture" >"${temp_capture}.n"
	if permission_capture_is_temp_write_recovery "${temp_capture}.n"; then
		printf 'non-temp external write misclassified as recovery: %s\n' "$unsafe_pattern" >&2
		exit 1
	fi
done
jq '.requests[0].tool = "read"' "$temp_capture" >"${temp_capture}.n"
if permission_capture_is_temp_write_recovery "${temp_capture}.n"; then
	printf 'temp read misclassified as write recovery\n' >&2
	exit 1
fi
permission_record_blocker "permission_capability_true_fixture" "blocked" "permission_required" "true" \
	123 "owner/repo" "issue-123" "perm-true" "Boolean transport fixture" \
	"external_directory" "read" "medium" "true"
jq -e 'select(.event == "permission_capability_true_fixture" and .grantable == true)' \
	"$AIDEVOPS_WORKER_BLOCKER_LOG_FILE" >/dev/null
activity_summary=$(WAH_BLOCKER_LOG_FILE="$AIDEVOPS_WORKER_BLOCKER_LOG_FILE" \
	WAH_METRICS_FILE="${test_root}/missing-metrics.jsonl" \
	WAH_PULSE_STATS_FILE="${test_root}/missing-pulse-stats.json" \
	WAH_DISPATCH_LEDGER_FILE="${test_root}/missing-dispatch-ledger.jsonl" \
	"${SCRIPT_DIR}/worker-activity-helper.sh" summary --since 24h --json --no-pr-check)
jq -e '.progress_blockers.active_blockers[] | select(
  .event == "permission_awaiting_approval"
  and .permission == "external_directory"
  and .tool == "read"
  and .risk_level == "medium"
  and .grantable == true
)' <<<"$activity_summary" >/dev/null

# Canonical-checkout requests get an owned redirect and no request record (GH#35139).
canonical_repos="${test_root}/canonical-repos.json"
printf '{"initialized_repos":[{"path":"%s/checkouts/example-repo","slug":"owner/repo"}]}\n' "$HOME" >"$canonical_repos"
canonical_capture="${test_root}/canonical-capture.json"
jq '.requests = [.requests[0] | .patterns = ["~/checkouts/example-repo/.agents/**"]]' "$capture_file" >"$canonical_capture"
: >"$gh_call_log"
rm -f "$posted_comment"
redirect_rc=0
redirect_out=$(AIDEVOPS_REPOS_FILE="$canonical_repos" cmd_request --file "$canonical_capture" --issue 123 \
	--repo owner/repo --session issue-123 --work-dir "$repo_dir") || redirect_rc=$?
if [[ "$redirect_rc" -ne "$PERMISSION_CANONICAL_REDIRECT_RC" || "$redirect_out" != *"own worktree"* ]]; then
	printf 'canonical-checkout request did not return the owned redirect\n' >&2
	exit 1
fi
if [[ -f "$posted_comment" ]] || grep -q -- 'needs-maintainer-permissions' "$gh_call_log"; then
	printf 'canonical-checkout request created a maintainer request record\n' >&2
	exit 1
fi
jq -e 'select(.event == "permission_request_redirected" and .blocking == false)' \
	"$AIDEVOPS_WORKER_BLOCKER_LOG_FILE" >/dev/null
# A sibling path that merely shares the canonical prefix is not canonical.
sibling_capture="${test_root}/sibling-capture.json"
jq '.requests[0].patterns = ["~/checkouts/example-repo-other/**"]' "$canonical_capture" >"$sibling_capture"
if AIDEVOPS_REPOS_FILE="$canonical_repos" permission_targets_canonical_checkout "$sibling_capture"; then
	printf 'prefix-sharing path was misclassified as a canonical checkout\n' >&2
	exit 1
fi

printf 'worker permission helper tests passed\n'
