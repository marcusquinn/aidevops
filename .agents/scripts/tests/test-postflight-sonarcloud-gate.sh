#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
POSTFLIGHT_SCRIPT="${REPO_ROOT}/.agents/scripts/postflight-check.sh"
STUB_DIR=$(mktemp -d)

cleanup() {
	rm -rf "$STUB_DIR"
	return 0
}
trap cleanup EXIT

cat >"${STUB_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
	exit 0
fi
if [[ "${1:-}" == "run" && "${2:-}" == "list" ]]; then
	if [[ "$*" == *"--limit=1"* || "$*" == *"--limit 1"* ]]; then
		printf '%s\n' '[{"databaseId":1,"status":"completed","conclusion":"success","name":"Stub CI"}]'
	else
		printf '%s\n' '[{"name":"Stub CI","status":"completed","conclusion":"success"}]'
	fi
	exit 0
fi
exit 1
EOF

cat >"${STUB_DIR}/curl" <<'EOF'
#!/usr/bin/env bash
url="${*: -1}"
case "$url" in
*qualitygates/project_status*)
	if [[ "${SONAR_STUB_STATUS:-}" == "UNAVAILABLE" ]]; then
		exit 1
	fi
	printf '{"projectStatus":{"status":"%s","conditions":[{"status":"%s","metricKey":"new_security_rating","actualValue":"4","errorThreshold":"1"}]}}\n' \
		"${SONAR_STUB_STATUS:-UNKNOWN}" "${SONAR_STUB_STATUS:-UNKNOWN}"
	;;
*measures/component*)
	printf '%s\n' '{"component":{"measures":[]}}'
	;;
*issues/search*)
	printf '%s\n' '{"total":0,"issues":[]}'
	;;
*) exit 1 ;;
esac
EOF

chmod +x "${STUB_DIR}/gh" "${STUB_DIR}/curl"

run_case() {
	local status="$1"
	local expected_exit="$2"
	local expected_text="$3"
	local forbidden_text="$4"
	local output
	local plain_output
	local actual_exit=0

	output=$(PATH="${STUB_DIR}:$PATH" SONAR_STUB_STATUS="$status" bash "$POSTFLIGHT_SCRIPT" --quick 2>&1) || actual_exit=$?
	plain_output=$(printf '%s' "$output" | sed $'s/\033\[[0-9;]*m//g')

	if [[ "$actual_exit" -ne "$expected_exit" ]]; then
		printf 'FAIL: status %s exited %s, expected %s\n%s\n' "$status" "$actual_exit" "$expected_exit" "$output" >&2
		return 1
	fi
	if [[ "$plain_output" != *"$expected_text"* ]]; then
		printf 'FAIL: status %s missing expected output %s\n%s\n' "$status" "$expected_text" "$output" >&2
		return 1
	fi
	if [[ -n "$forbidden_text" && "$plain_output" == *"$forbidden_text"* ]]; then
		printf 'FAIL: status %s contained forbidden output %s\n%s\n' "$status" "$forbidden_text" "$output" >&2
		return 1
	fi
	return 0
}

run_case "ERROR" 1 "Failed:   1" "POSTFLIGHT VERIFICATION PASSED"
run_case "OK" 0 "POSTFLIGHT VERIFICATION PASSED" "POSTFLIGHT VERIFICATION FAILED"
run_case "WARN" 0 "POSTFLIGHT VERIFICATION PASSED WITH WARNINGS" "POSTFLIGHT VERIFICATION FAILED"
run_case "UNKNOWN" 0 "SonarCloud quality gate status: UNKNOWN" "POSTFLIGHT VERIFICATION FAILED"
run_case "UNAVAILABLE" 0 "SKIPPED Could not reach SonarCloud API" "POSTFLIGHT VERIFICATION FAILED"

printf 'PASS: postflight propagates SonarCloud quality-gate results\n'
