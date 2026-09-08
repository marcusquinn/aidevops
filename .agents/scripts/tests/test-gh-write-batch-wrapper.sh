#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${TEST_DIR}/.." && pwd)"
TEST_TMP="$(mktemp -d -t gh-write-batch-wrapper.XXXXXX)"
trap 'rm -rf "$TEST_TMP"' EXIT
export AIDEVOPS_TEMP_DIR="${TEST_TMP}/private"
mkdir -m 700 "$AIDEVOPS_TEMP_DIR"

# shellcheck source=../shared-gh-wrappers.sh
source "${SCRIPTS_DIR}/shared-gh-wrappers.sh"

GUARD_CALLS=0
EXECUTE_CALLS=0
_gh_guard_public_write_args() {
	GUARD_CALLS=$((GUARD_CALLS + 1))
	return 0
}
_gh_with_timeout() {
	EXECUTE_CALLS=$((EXECUTE_CALLS + 1))
	return 0
}
_gh_secondary_cooldown_preflight() { return 75; }

set +e
gh_write_batch "${AIDEVOPS_TEMP_DIR}/does-not-need-to-exist.json" >/dev/null 2>&1
cooldown_rc=$?
set -e
if [[ "$cooldown_rc" -ne 75 || "$GUARD_CALLS" -ne 0 || "$EXECUTE_CALLS" -ne 0 ]]; then
	printf 'FAIL: active cooldown must make zero privacy/backend calls\n' >&2
	exit 1
fi

printf 'PASS: active cooldown makes zero backend calls\n'

BODY_FILE="${AIDEVOPS_TEMP_DIR}/body.md"
MANIFEST_FILE="${AIDEVOPS_TEMP_DIR}/manifest.json"
printf 'Public comment body\n' >"$BODY_FILE"
printf '%s\n' "{\"schema\":\"aidevops.github-write-batch/v1\",\"repository\":\"test/repo\",\"operations\":[{\"id\":\"comment\",\"kind\":\"issue_comment\",\"number\":1,\"body_file\":\"${BODY_FILE}\"}]}" >"$MANIFEST_FILE"
chmod 600 "$BODY_FILE" "$MANIFEST_FILE"
_gh_secondary_cooldown_preflight() { return 0; }
_gh_guard_public_write_args() {
	GUARD_CALLS=$((GUARD_CALLS + 1))
	return 1
}
set +e
gh_write_batch "$MANIFEST_FILE" >/dev/null 2>&1
privacy_rc=$?
set -e
if [[ "$privacy_rc" -eq 0 || "$GUARD_CALLS" -ne 1 || "$EXECUTE_CALLS" -ne 0 ]]; then
	printf 'FAIL: privacy rejection must stop before the GraphQL backend\n' >&2
	exit 1
fi

printf 'PASS: privacy rejection stops before the GraphQL backend\n'

STUB_BIN="${TEST_TMP}/bin"
GH_CALLS="${TEST_TMP}/gh-calls"
BATCH_OUTPUT="${TEST_TMP}/batch-output.json"
mkdir "$STUB_BIN"
export GH_CALLS
cat >"${STUB_BIN}/gh" <<'STUB'
#!/usr/bin/env bash
calls=0
[[ ! -f "$GH_CALLS" ]] || calls=$(<"$GH_CALLS")
calls=$((calls + 1))
printf '%s\n' "$calls" >"$GH_CALLS"
if [[ "$calls" -eq 1 ]]; then
	printf '%s\n' '{"data":{"repository":{"viewerPermission":"WRITE","t0":{"__typename":"Issue","id":"I1","number":1,"title":"Old","body":"Old","labels":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}}}'
else
	printf '%s\n' '{"data":{"o0":{"clientMutationId":"comment","commentEdge":{"node":{"id":"C1"}}}}}'
fi
STUB
chmod +x "${STUB_BIN}/gh"
_gh_guard_public_write_args() { return 0; }
_gh_with_timeout() {
	shift
	"$@"
}
PATH="${STUB_BIN}:$PATH" gh_write_batch "$MANIFEST_FILE" >"$BATCH_OUTPUT" 2>/dev/null
if [[ "$(<"$GH_CALLS")" -ne 2 ]] || ! grep -q '"overall": "succeeded"' "$BATCH_OUTPUT"; then
	printf 'FAIL: admitted batch must use one preflight and one successful mutation\n' >&2
	exit 1
fi

printf 'PASS: admitted batch uses one preflight and one mutation\n'
