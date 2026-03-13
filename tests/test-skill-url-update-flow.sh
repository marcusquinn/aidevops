#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADD_SCRIPT="$REPO_DIR/.agents/scripts/add-skill-helper.sh"
UPDATE_SCRIPT="$REPO_DIR/.agents/scripts/skill-update-helper.sh"

PASS_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0

pass() {
	PASS_COUNT=$((PASS_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	printf "\033[0;32mPASS\033[0m %s\n" "$1"
	return 0
}

fail() {
	FAIL_COUNT=$((FAIL_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	printf "\033[0;31mFAIL\033[0m %s\n" "$1"
	if [[ -n "${2:-}" ]]; then
		printf "     %s\n" "$2"
	fi
	return 0
}

assert_eq() {
	local expected="$1"
	local actual="$2"
	local name="$3"
	if [[ "$expected" == "$actual" ]]; then
		pass "$name"
	else
		fail "$name" "Expected '$expected', got '$actual'"
	fi
	return 0
}

assert_file_exists() {
	local path="$1"
	local name="$2"
	if [[ -f "$path" ]]; then
		pass "$name"
	else
		fail "$name" "Missing file: $path"
	fi
	return 0
}

safe_jq_file() {
	local filter="$1"
	local file="$2"
	local name="$3"
	local value=""
	if value="$(jq -er "$filter" "$file" 2>/dev/null)"; then
		printf '%s\n' "$value"
		return 0
	fi

	fail "$name" "Could not read '$filter' from $file"
	printf '\n'
	return 1
}

safe_jq_json() {
	local filter="$1"
	local json="$2"
	local name="$3"
	local value=""
	if value="$(jq -er "$filter" <<<"$json" 2>/dev/null)"; then
		printf '%s\n' "$value"
		return 0
	fi

	fail "$name" "Could not read '$filter' from helper JSON output"
	printf '\n'
	return 1
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"

cat >"$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

output_file=""
header_file=""
write_http_code=false
log_file="${CURL_LOG:-}"
requested_url=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	-o)
		output_file="$2"
		shift 2
		;;
	-D)
		header_file="$2"
		shift 2
		;;
	-w)
		write_http_code=true
		shift 2
		;;
	-H)
		if [[ -n "$log_file" ]]; then
			printf '%s\n' "$2" >>"$log_file"
		fi
		shift 2
		;;
	*)
		if [[ -z "$requested_url" && ( "$1" == http://* || "$1" == https://* ) ]]; then
			requested_url="$1"
		fi
		shift
		;;
	esac
done

if [[ "$requested_url" != "https://convos.org/skill.md" ]]; then
	printf 'unexpected URL: %s\n' "$requested_url" >&2
	exit 1
fi

mode="${CURL_MODE:-add_import}"

if [[ "$mode" == "add_import" ]]; then
	cat >"$output_file" <<'BODY'
---
name: Convos
description: Convos URL skill
---
# Convos
BODY
	cat >"$header_file" <<'HEADERS'
HTTP/1.1 200 OK
ETag: "etag-import-1"
Last-Modified: Sat, 08 Mar 2026 12:00:00 GMT
HEADERS
	if [[ "$write_http_code" == true ]]; then
		printf '200'
	fi
	exit 0
fi

if [[ "$mode" == "check_304" ]]; then
	: >"$output_file"
	cat >"$header_file" <<'HEADERS'
HTTP/1.1 304 Not Modified
ETag: "etag-import-1"
Last-Modified: Sat, 08 Mar 2026 12:00:00 GMT
HEADERS
	if [[ "$write_http_code" == true ]]; then
		printf '304'
	fi
	exit 0
fi

if [[ "$mode" == "check_changed" ]]; then
	cat >"$output_file" <<'BODY'
# Updated skill content
BODY
	cat >"$header_file" <<'HEADERS'
HTTP/1.1 200 OK
ETag: "etag-import-2"
Last-Modified: Sun, 09 Mar 2026 12:00:00 GMT
HEADERS
	if [[ "$write_http_code" == true ]]; then
		printf '200'
	fi
	exit 0
fi

exit 1
EOF
chmod +x "$FAKE_BIN/curl"

# Test 1: URL import registers format/hash/cache headers in skill-sources.json
PROJECT_DIR_1="$TMP_DIR/project-1"
AGENTS_DIR_1="$TMP_DIR/agents-1"
mkdir -p "$PROJECT_DIR_1/.agents" "$AGENTS_DIR_1/configs"

(
	cd "$PROJECT_DIR_1"
	PATH="$FAKE_BIN:$PATH" \
		CURL_MODE="add_import" \
		AIDEVOPS_AGENTS_DIR="$AGENTS_DIR_1" \
		bash "$ADD_SCRIPT" add "https://convos.org/skill.md" --name convos --skip-security >/dev/null
)

SOURCES_FILE_1="$AGENTS_DIR_1/configs/skill-sources.json"
format_detected_1="$(safe_jq_file '.skills[0].format_detected' "$SOURCES_FILE_1" 'Imported format_detected is readable' || true)"
upstream_hash_1="$(safe_jq_file '.skills[0].upstream_hash' "$SOURCES_FILE_1" 'Imported upstream_hash is readable' || true)"
upstream_etag_1="$(safe_jq_file '.skills[0].upstream_etag' "$SOURCES_FILE_1" 'Imported upstream_etag is readable' || true)"
upstream_last_modified_1="$(safe_jq_file '.skills[0].upstream_last_modified' "$SOURCES_FILE_1" 'Imported upstream_last_modified is readable' || true)"
local_path_1="$(safe_jq_file '.skills[0].local_path' "$SOURCES_FILE_1" 'Imported local_path is readable' || true)"

assert_eq "url" "$format_detected_1" "URL import sets format_detected to url"
assert_eq "\"etag-import-1\"" "$upstream_etag_1" "URL import stores ETag header"
assert_eq "Sat, 08 Mar 2026 12:00:00 GMT" "$upstream_last_modified_1" "URL import stores Last-Modified header"
expected_hash_1="2b280fca6ee87ff065b23e81958dccf40476c9bfa3aefe62507fd52ba212b60f"
if [[ "$upstream_hash_1" == "$expected_hash_1" ]]; then
	pass "URL import stores SHA-256 upstream_hash"
else
	fail "URL import stores SHA-256 upstream_hash" "Expected '$expected_hash_1', got '$upstream_hash_1'"
fi
assert_file_exists "$PROJECT_DIR_1/$local_path_1" "URL import creates local skill file"

# Test 2: URL update check sends conditional headers and treats 304 as up to date
PROJECT_DIR_2="$TMP_DIR/project-2"
AGENTS_DIR_2="$TMP_DIR/agents-2"
CURL_LOG_2="$TMP_DIR/curl-headers.log"
mkdir -p "$PROJECT_DIR_2" "$AGENTS_DIR_2/configs"

cat >"$AGENTS_DIR_2/configs/skill-sources.json" <<'EOF'
{
  "version": "1.0.0",
  "skills": [
    {
      "name": "convos",
      "upstream_url": "https://convos.org/skill.md",
      "local_path": ".agents/tools/convos-skill.md",
      "format_detected": "url",
      "upstream_hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "upstream_etag": "\"etag-import-1\"",
      "upstream_last_modified": "Sat, 08 Mar 2026 12:00:00 GMT",
      "imported_at": "2026-03-08T12:00:00Z",
      "merge_strategy": "added"
    }
  ]
}
EOF

set +e
CHECK_OUTPUT_2="$(
	cd "$PROJECT_DIR_2"
	PATH="$FAKE_BIN:$PATH" \
		CURL_MODE="check_304" \
		CURL_LOG="$CURL_LOG_2" \
		AIDEVOPS_AGENTS_DIR="$AGENTS_DIR_2" \
		bash "$UPDATE_SCRIPT" check --quiet --json 2>&1
)"
CHECK_EXIT_2=$?
set -e

JSON_OUTPUT_2="$(printf '%s\n' "$CHECK_OUTPUT_2" | sed -n '/^{/,$p')"
updates_available_2="$(safe_jq_json '.updates_available' "$JSON_OUTPUT_2" '304 check updates_available is readable' || true)"
up_to_date_2="$(safe_jq_json '.up_to_date' "$JSON_OUTPUT_2" '304 check up_to_date is readable' || true)"
status_2="$(safe_jq_json '.results[0].status' "$JSON_OUTPUT_2" '304 check result status is readable' || true)"
last_checked_2="$(safe_jq_file '.skills[0].last_checked // ""' "$AGENTS_DIR_2/configs/skill-sources.json" '304 check last_checked is readable' || true)"

assert_eq "0" "$CHECK_EXIT_2" "URL check returns success when upstream is 304"
assert_eq "0" "$updates_available_2" "URL check reports no updates on 304"
assert_eq "1" "$up_to_date_2" "URL check counts 304 result as up_to_date"
assert_eq "up_to_date" "$status_2" "URL check JSON result marks 304 as up_to_date"

if grep -q '^If-None-Match: "etag-import-1"$' "$CURL_LOG_2"; then
	pass "URL check sends If-None-Match conditional header"
else
	fail "URL check sends If-None-Match conditional header"
fi

if grep -q '^If-Modified-Since: Sat, 08 Mar 2026 12:00:00 GMT$' "$CURL_LOG_2"; then
	pass "URL check sends If-Modified-Since conditional header"
else
	fail "URL check sends If-Modified-Since conditional header"
fi

if [[ -n "$last_checked_2" ]]; then
	pass "URL check updates last_checked timestamp on 304"
else
	fail "URL check updates last_checked timestamp on 304"
fi

# Test 3: URL update check reports update_available when content hash changes
PROJECT_DIR_3="$TMP_DIR/project-3"
AGENTS_DIR_3="$TMP_DIR/agents-3"
mkdir -p "$PROJECT_DIR_3" "$AGENTS_DIR_3/configs"

cat >"$AGENTS_DIR_3/configs/skill-sources.json" <<'EOF'
{
  "version": "1.0.0",
  "skills": [
    {
      "name": "convos",
      "upstream_url": "https://convos.org/skill.md",
      "local_path": ".agents/tools/convos-skill.md",
      "format_detected": "url",
      "upstream_hash": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "imported_at": "2026-03-08T12:00:00Z",
      "merge_strategy": "added"
    }
  ]
}
EOF

set +e
CHECK_OUTPUT_3="$(
	cd "$PROJECT_DIR_3"
	PATH="$FAKE_BIN:$PATH" \
		CURL_MODE="check_changed" \
		AIDEVOPS_AGENTS_DIR="$AGENTS_DIR_3" \
		bash "$UPDATE_SCRIPT" check --quiet --json 2>&1
)"
CHECK_EXIT_3=$?
set -e

JSON_OUTPUT_3="$(printf '%s\n' "$CHECK_OUTPUT_3" | sed -n '/^{/,$p')"
updates_available_3="$(safe_jq_json '.updates_available' "$JSON_OUTPUT_3" 'Changed-content check updates_available is readable' || true)"
status_3="$(safe_jq_json '.results[0].status' "$JSON_OUTPUT_3" 'Changed-content check result status is readable' || true)"
latest_hash_3="$(safe_jq_json '.results[0].latest' "$JSON_OUTPUT_3" 'Changed-content check latest hash is readable' || true)"

assert_eq "1" "$CHECK_EXIT_3" "URL check exits non-zero when update is available"
assert_eq "1" "$updates_available_3" "URL check reports one available update"
assert_eq "update_available" "$status_3" "URL check marks changed content as update_available"
expected_hash_3="291b09128f5aadaf623ad8a05e120cf659e84d274bab87648c9a5ef9f5926d07"
if [[ "$latest_hash_3" == "$expected_hash_3" ]]; then
	pass "URL check returns latest SHA-256 hash for changed content"
else
	fail "URL check returns latest SHA-256 hash for changed content" "Expected '$expected_hash_3', got '$latest_hash_3'"
fi

printf "\nRan %d tests, %d failed.\n" "$TOTAL_COUNT" "$FAIL_COUNT"

if [[ "$FAIL_COUNT" -ne 0 ]]; then
	exit 1
fi

exit 0
