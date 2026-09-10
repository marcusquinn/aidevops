#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/../object-storage-helper.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/aidevops-object-storage.XXXXXX") || exit 1
trap 'rm -rf "$TEST_ROOT"' EXIT
CONFIG="$TEST_ROOT/object-storage-config.json"
RCLONE="$TEST_ROOT/rclone"
LOG="$TEST_ROOT/rclone.argv"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	return 1
}
assert_json() {
	jq -e "$2" <<<"$1" >/dev/null || fail "$3"
	return 0
}

cat >"$CONFIG" <<'JSON'
{"version":1,"accounts":{"fixture":{"provider":"s3-compatible","remote":"fixture_remote","endpoint":"https://s3.example.invalid","region":"test-1","buckets":["backup"]},"b2":{"provider":"backblaze-b2","remote":"b2_remote","endpoint":"https://s3.us-west-000.backblazeb2.com","region":"us-west-000","buckets":["b2-backup"]}}}
JSON
cat >"$RCLONE" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$AIDEVOPS_OBJECT_STORAGE_TEST_LOG"
if [[ "$1" == "version" ]]; then printf 'rclone v1.70.0\n'; exit 0; fi
if [[ "$1" == "lsd" ]]; then printf '{"Path":"backup"}\n'; exit 0; fi
printf '[{"Path":"backup-2026-01-01","Size":12,"ModTime":"2026-01-01T00:00:00Z"}]\n'
SH
chmod +x "$RCLONE"

run_helper() {
	if AIDEVOPS_OBJECT_STORAGE_CONFIG="$CONFIG" AIDEVOPS_RCLONE_BIN="$RCLONE" AIDEVOPS_OBJECT_STORAGE_TEST_LOG="$LOG" "$HELPER" "$@"; then
		return 0
	fi
	return 1
}

result=$(run_helper readiness fixture)
assert_json "$result" '.status == "ok" and .data.ready == true' "readiness did not return stable JSON"
result=$(run_helper readiness b2)
assert_json "$result" '.data.provider == "backblaze-b2"' "Backblaze B2 profile was not accepted"
result=$(run_helper list-buckets fixture)
assert_json "$result" '.data[0].bucket == "backup"' "bucket listing did not normalize JSON"
result=$(run_helper list-objects fixture backup --limit 1)
assert_json "$result" '.data | length == 1' "bounded object listing failed"
if run_helper list-objects fixture backup --limit 1001 >/dev/null 2>&1; then fail "unbounded listing was accepted"; fi
if run_helper list-objects fixture invalid --limit 1 >/dev/null 2>&1; then fail "unknown bucket was accepted"; fi
if run_helper readiness unknown >/dev/null 2>&1; then fail "unknown alias was accepted"; fi
if run_helper object-info fixture backup https://invalid >/dev/null 2>&1; then fail "raw URL was accepted"; fi
result=$(run_helper copy fixture backup source destination)
assert_json "$result" '.data.dry_run == true and .data.confirmation_required == "preview:fixture:backup"' "copy was not preview-only"
if [[ -s "$LOG" ]] && grep -q -- '--config\|config create\|delete\|purge' "$LOG"; then fail "unsafe rclone command was invoked"; fi
printf 'PASS: object storage helper rejects unsafe inputs and keeps transfers dry-run\n'
