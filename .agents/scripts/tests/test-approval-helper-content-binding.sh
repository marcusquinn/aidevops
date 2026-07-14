#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for immutable V2 approval snapshots (GH#27560).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
APPROVAL_HELPER="${SCRIPT_DIR}/../approval-helper.sh"
# shellcheck source=../approval-snapshot-v2.sh
source "${SCRIPT_DIR}/../approval-snapshot-v2.sh"

TEST_ROOT="$(mktemp -d -t approval-content-binding.XXXXXX)"
FIXTURES="${TEST_ROOT}/fixtures"
TEST_HOME="${TEST_ROOT}/home"
TESTS_RUN=0
TESTS_FAILED=0
PR_HEAD="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

print_result() {
	local description="$1"
	local passed="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$description"
		return 0
	fi
	printf 'FAIL %s%s\n' "$description" "${detail:+ — $detail}"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

install_gh_stub() {
	mkdir -p "${TEST_ROOT}/bin" "$FIXTURES" "$TEST_HOME"
	cat >"${TEST_ROOT}/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "api" ]] || exit 1
endpoint="${2:-}"
if [[ -n "${GH_FAIL_ENDPOINT:-}" && "$endpoint" == *"${GH_FAIL_ENDPOINT}"* ]]; then
	exit 1
fi
case "$endpoint" in
repos/owner/repo/issues/41) cat "${FIXTURES}/issue-41.json" ;;
repos/owner/repo/issues/41/comments*) cat "${FIXTURES}/comments-41.json" ;;
repos/owner/repo/issues/41/timeline*) cat "${FIXTURES}/timeline-41.json" ;;
repos/owner/repo/issues/42) cat "${FIXTURES}/issue-42.json" ;;
repos/owner/repo/issues/42/comments*) cat "${FIXTURES}/comments-42.json" ;;
repos/owner/repo/issues/42/timeline*) cat "${FIXTURES}/timeline-42.json" ;;
repos/owner/repo/pulls/42) cat "${FIXTURES}/pr-42.json" ;;
repos/owner/repo/pulls/42/comments*) cat "${FIXTURES}/review-comments-42.json" ;;
repos/owner/repo/pulls/42/reviews*) cat "${FIXTURES}/reviews-42.json" ;;
*) printf 'Unhandled endpoint: %s\n' "$endpoint" >&2; exit 1 ;;
esac
exit 0
EOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

write_baseline_fixtures() {
	cat >"${FIXTURES}/issue-41.json" <<'EOF'
{"id":4100,"node_id":"I_41","number":41,"user":{"id":101,"node_id":"U_101","login":"external-author","type":"User"},"author_association":"CONTRIBUTOR","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","title":"Reviewed issue","body":"Issue body with https://example.invalid/opaque"}
EOF
	cat >"${FIXTURES}/issue-42.json" <<'EOF'
{"id":4200,"node_id":"I_42","number":42,"user":{"id":102,"node_id":"U_102","login":"external-author","type":"User"},"author_association":"CONTRIBUTOR","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","title":"Reviewed PR","body":"PR body with opaque external link","pull_request":{"url":"opaque"}}
EOF
	cat >"${FIXTURES}/pr-42.json" <<EOF
{"id":4201,"node_id":"PR_42","number":42,"user":{"id":102,"node_id":"U_102","login":"external-author","type":"User"},"author_association":"CONTRIBUTOR","created_at":"2026-01-01T00:00:00Z","title":"Reviewed PR","body":"PR body with opaque external link","head":{"sha":"${PR_HEAD}","ref":"feature/external","repo":{"id":5001,"full_name":"external/fork"}},"base":{"ref":"main","repo":{"id":5000,"full_name":"owner/repo"}}}
EOF
	cat >"${FIXTURES}/comments-41.json" <<'EOF'
[[{"id":411,"node_id":"IC_411","user":{"id":103,"node_id":"U_103","login":"reviewer","type":"User"},"author_association":"MEMBER","created_at":"2026-01-01T00:01:00Z","updated_at":"2026-01-01T00:01:00Z","body":"Reviewed issue comment"}]]
EOF
	cat >"${FIXTURES}/comments-42.json" <<'EOF'
[[{"id":421,"node_id":"IC_421","user":{"id":103,"node_id":"U_103","login":"reviewer","type":"User"},"author_association":"MEMBER","created_at":"2026-01-01T00:01:00Z","updated_at":"2026-01-01T00:01:00Z","body":"Reviewed PR comment"}]]
EOF
	cat >"${FIXTURES}/timeline-41.json" <<'EOF'
[[{"id":419,"node_id":"EV_419","event":"cross-referenced","created_at":"2026-01-01T00:02:00Z","actor":{"id":103,"node_id":"U_103","login":"reviewer","type":"User"},"source":{"issue":{"id":9001,"node_id":"I_9001","number":9,"title":"Linked scope","body":"Linked body","state":"open","updated_at":"2026-01-01T00:02:00Z","repository":{"full_name":"owner/repo"},"user":{"id":104,"node_id":"U_104","login":"link-author","type":"User"}}}}]]
EOF
	cp "${FIXTURES}/timeline-41.json" "${FIXTURES}/timeline-42.json"
	cat >"${FIXTURES}/review-comments-42.json" <<'EOF'
[[{"id":422,"node_id":"RC_422","user":{"id":103,"node_id":"U_103","login":"reviewer","type":"User"},"author_association":"MEMBER","created_at":"2026-01-01T00:03:00Z","updated_at":"2026-01-01T00:03:00Z","body":"Inline review","path":"file.sh","line":7,"side":"RIGHT","commit_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","original_commit_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]]
EOF
	cat >"${FIXTURES}/reviews-42.json" <<'EOF'
[[{"id":423,"node_id":"RV_423","user":{"id":103,"node_id":"U_103","login":"reviewer","type":"User"},"author_association":"MEMBER","state":"APPROVED","commit_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","submitted_at":"2026-01-01T00:04:00Z","body":"Reviewed"}]]
EOF
	return 0
}

sign_payload() {
	local payload="$1"
	local signature_file="$2"
	printf '%s' "$payload" | ssh-keygen -Y sign -f "${TEST_ROOT}/approval.key" -n aidevops-approve -q - >"$signature_file" 2>/dev/null
	return $?
}

append_signed_comment() {
	local kind="$1"
	local number="$2"
	local issued_at="$3"
	local comment_id="${4:-$((number * 100 + 99))}"
	local comments_file="${FIXTURES}/comments-${number}.json"
	local payload="" signature_file="" signature="" body="" updated=""
	payload=$(PATH="${TEST_ROOT}/bin:$PATH" FIXTURES="$FIXTURES" approval_snapshot_v2_payload "$kind" "$number" owner/repo "$issued_at") || return 1
	signature_file="${TEST_ROOT}/signature-${number}.txt"
	sign_payload "$payload" "$signature_file" || return 1
	signature=$(<"$signature_file")
	body="<!-- aidevops-signed-approval -->
\`\`\`
${payload}
\`\`\`
\`\`\`
${signature}
\`\`\`"
	updated=$(jq -c --arg body "$body" --argjson id "$comment_id" '
		.[0] += [{id:$id,node_id:("APPROVAL_" + ($id|tostring)),user:{id:1,node_id:"U_1",login:"maintainer",type:"User"},author_association:"OWNER",created_at:"2026-01-01T00:05:00Z",updated_at:"2026-01-01T00:05:00Z",body:$body}]
	' "$comments_file") || return 1
	printf '%s\n' "$updated" >"$comments_file"
	printf '%s\n' "$payload" >"${TEST_ROOT}/payload-${number}.json"
	return 0
}

replace_with_legacy_comment() {
	local number="$1"
	local payload="APPROVE:issue:owner/repo:${number}:2026-01-01T00:05:00Z"
	local signature_file="${TEST_ROOT}/legacy-signature.txt" signature="" body=""
	sign_payload "$payload" "$signature_file" || return 1
	signature=$(<"$signature_file")
	body="<!-- aidevops-signed-approval -->
\`\`\`
${payload}
\`\`\`
\`\`\`
${signature}
\`\`\`"
	jq -nc --arg body "$body" '[[{id:4199,user:{type:"User"},body:$body}]]' >"${FIXTURES}/comments-${number}.json"
	return 0
}

run_verify() {
	local kind="$1"
	local number="$2"
	local expected_head="${3:-}"
	if [[ -n "$expected_head" ]]; then
		HOME="$TEST_HOME" PATH="${TEST_ROOT}/bin:$PATH" FIXTURES="$FIXTURES" \
			AIDEVOPS_APPROVAL_PUB="${TEST_ROOT}/approval.pub" \
			"$APPROVAL_HELPER" verify "$kind" "$number" owner/repo --expect-head "$expected_head" 2>/dev/null
		return $?
	fi
	HOME="$TEST_HOME" PATH="${TEST_ROOT}/bin:$PATH" FIXTURES="$FIXTURES" \
		AIDEVOPS_APPROVAL_PUB="${TEST_ROOT}/approval.pub" \
		"$APPROVAL_HELPER" verify "$kind" "$number" owner/repo 2>/dev/null
	return $?
}

assert_verify() {
	local description="$1"
	local kind="$2"
	local number="$3"
	local expected_output="$4"
	local expected_rc="$5"
	local expected_head="${6:-}"
	local output="" rc=0
	output=$(run_verify "$kind" "$number" "$expected_head") || rc=$?
	if [[ "$output" == "$expected_output" && "$rc" -eq "$expected_rc" ]]; then
		print_result "$description" 0
		return 0
	fi
	print_result "$description" 1 "expected=${expected_output}/${expected_rc}, actual=${output}/${rc}"
	return 0
}

reset_and_sign() {
	local kind="$1"
	local number="$2"
	write_baseline_fixtures
	append_signed_comment "$kind" "$number" "2026-01-01T00:05:00Z"
	return $?
}

main() {
	install_gh_stub
	write_baseline_fixtures
	ssh-keygen -t ed25519 -N '' -f "${TEST_ROOT}/approval.key" -q
	cp "${TEST_ROOT}/approval.key.pub" "${TEST_ROOT}/approval.pub"

	reset_and_sign issue 41
	assert_verify "unchanged issue V2 snapshot verifies" issue 41 VERIFIED 0
	jq '.body = "changed issue body"' "${FIXTURES}/issue-41.json" >"${FIXTURES}/issue.tmp"
	mv "${FIXTURES}/issue.tmp" "${FIXTURES}/issue-41.json"
	assert_verify "issue body drift is stale" issue 41 STALE_APPROVAL 4

	reset_and_sign pr 42
	assert_verify "unchanged PR V2 snapshot verifies exact head" pr 42 VERIFIED 0 "$PR_HEAD"
	local original_digest="" repeated_payload="" repeated_digest=""
	original_digest=$(jq -r '.snapshot_sha256' "${TEST_ROOT}/payload-42.json")
	repeated_payload=$(PATH="${TEST_ROOT}/bin:$PATH" FIXTURES="$FIXTURES" approval_snapshot_v2_payload pr 42 owner/repo "2026-01-01T00:06:00Z")
	repeated_digest=$(jq -r '.snapshot_sha256' <<<"$repeated_payload")
	if [[ "$original_digest" != "$repeated_digest" ]]; then
		print_result "existing human approval comments remain content-bound" 0
	else
		print_result "existing human approval comments remain content-bound" 1
	fi
	append_signed_comment pr 42 "2026-01-01T00:06:00Z" 4300
	assert_verify "repeat approval verifies against the newest exact snapshot" pr 42 VERIFIED 0 "$PR_HEAD"

	reset_and_sign pr 42
	local audit_marker="<!-- aidevops-signed-approval -->
<!-- stale-recovery-tick:0 (reset: auto-approved by maintainer — cryptographic approval verified) -->
Auto-approved: cryptographic approval verified. Stale recovery tick reset."
	local audit_comments=""
	audit_comments=$(jq -c --arg body "$audit_marker" '.[0] += [{id:4301,node_id:"IC_4301",user:{id:1,node_id:"U_1",login:"maintainer",type:"User"},author_association:"OWNER",created_at:"2026-01-01T00:06:00Z",updated_at:"2026-01-01T00:06:00Z",body:$body}]' "${FIXTURES}/comments-42.json")
	printf '%s\n' "$audit_comments" >"${FIXTURES}/comments-42.json"
	assert_verify "trusted deterministic lifecycle audit comment is excluded" pr 42 VERIFIED 0 "$PR_HEAD"

	reset_and_sign pr 42
	local marker_drift="<!-- aidevops-signed-approval --> unsigned external drift"
	local marker_comments=""
	marker_comments=$(jq -c --arg body "$marker_drift" '.[0] += [{id:4302,node_id:"IC_4302",user:{id:105,node_id:"U_105",login:"external-author",type:"User"},author_association:"CONTRIBUTOR",created_at:"2026-01-01T00:06:00Z",updated_at:"2026-01-01T00:06:00Z",body:$body}]' "${FIXTURES}/comments-42.json")
	printf '%s\n' "$marker_comments" >"${FIXTURES}/comments-42.json"
	assert_verify "unsigned marker-bearing comment drift is not excluded" pr 42 STALE_APPROVAL 4 "$PR_HEAD"

	jq '.body = "changed PR body"' "${FIXTURES}/pr-42.json" >"${FIXTURES}/pr.tmp" && mv "${FIXTURES}/pr.tmp" "${FIXTURES}/pr-42.json"
	assert_verify "PR body drift is stale" pr 42 STALE_APPROVAL 4 "$PR_HEAD"

	reset_and_sign pr 42
	jq '.[0][0].body = "edited external comment" | .[0][0].updated_at = "2026-01-01T00:07:00Z"' "${FIXTURES}/comments-42.json" >"${FIXTURES}/comments.tmp" && mv "${FIXTURES}/comments.tmp" "${FIXTURES}/comments-42.json"
	assert_verify "conversation comment drift is stale" pr 42 STALE_APPROVAL 4 "$PR_HEAD"

	reset_and_sign pr 42
	jq '.[0][0].body = "edited inline review"' "${FIXTURES}/review-comments-42.json" >"${FIXTURES}/review.tmp" && mv "${FIXTURES}/review.tmp" "${FIXTURES}/review-comments-42.json"
	assert_verify "inline review drift is stale" pr 42 STALE_APPROVAL 4 "$PR_HEAD"

	reset_and_sign pr 42
	jq '.[0][0].source.issue.title = "changed linked scope"' "${FIXTURES}/timeline-42.json" >"${FIXTURES}/timeline.tmp" && mv "${FIXTURES}/timeline.tmp" "${FIXTURES}/timeline-42.json"
	assert_verify "linked-reference drift is stale" pr 42 STALE_APPROVAL 4 "$PR_HEAD"

	reset_and_sign pr 42
	jq '.base.ref = "release"' "${FIXTURES}/pr-42.json" >"${FIXTURES}/pr.tmp" && mv "${FIXTURES}/pr.tmp" "${FIXTURES}/pr-42.json"
	assert_verify "base-target drift is stale" pr 42 STALE_APPROVAL 4 "$PR_HEAD"

	reset_and_sign pr 42
	local changed_head="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	jq --arg head "$changed_head" '.head.sha = $head' "${FIXTURES}/pr-42.json" >"${FIXTURES}/pr.tmp" && mv "${FIXTURES}/pr.tmp" "${FIXTURES}/pr-42.json"
	assert_verify "head drift is stale" pr 42 STALE_APPROVAL 4 "$PR_HEAD"

	write_baseline_fixtures
	replace_with_legacy_comment 41
	assert_verify "V1 signature is legacy and cannot become V2 authority" issue 41 LEGACY_APPROVAL 3

	reset_and_sign issue 41
	jq '.[0][-1].body |= sub("aidevops-approval/v2"; "aidevops-approval/v3")' "${FIXTURES}/comments-41.json" >"${FIXTURES}/comments.tmp" && mv "${FIXTURES}/comments.tmp" "${FIXTURES}/comments-41.json"
	assert_verify "tampered signed payload is malformed" issue 41 MALFORMED_APPROVAL 5

	reset_and_sign issue 41
	local output="" rc=0
	output=$(GH_FAIL_ENDPOINT="timeline" run_verify issue 41) || rc=$?
	if [[ "$output" == "API_ERROR" && "$rc" -eq 6 ]]; then
		print_result "snapshot API uncertainty fails closed" 0
	else
		print_result "snapshot API uncertainty fails closed" 1 "output=${output}, rc=${rc}"
	fi

	printf '\nTests run: %d\nTests failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
	return $?
}

main "$@"
