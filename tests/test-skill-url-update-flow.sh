#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

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

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"
REAL_GIT="$(command -v git)"

cat >"$FAKE_BIN/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "clone" ]]; then
	target_dir=""
	for arg in "$@"; do
		target_dir="$arg"
	done
	mkdir -p "$target_dir"
	cp -R "${FAKE_GIT_SOURCE}/." "$target_dir/"
	exit 0
fi

if [[ "${1:-}" == "-C" && "${3:-}" == "rev-parse" ]]; then
	printf '%s\n' "1111111111111111111111111111111111111111"
	exit 0
fi

exec "$REAL_GIT" "$@"
EOF
chmod +x "$FAKE_BIN/git"

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
source_values_1=()
while IFS= read -r value; do
	source_values_1+=("$value")
done < <(jq -r '.skills[0] | .format_detected, .upstream_hash, .upstream_etag, .upstream_last_modified, .local_path' "$SOURCES_FILE_1")
format_detected_1="${source_values_1[0]:-}"
upstream_hash_1="${source_values_1[1]:-}"
upstream_etag_1="${source_values_1[2]:-}"
upstream_last_modified_1="${source_values_1[3]:-}"
local_path_1="${source_values_1[4]:-}"

assert_eq "url" "$format_detected_1" "URL import sets format_detected to url"
assert_eq "\"etag-import-1\"" "$upstream_etag_1" "URL import stores ETag header"
assert_eq "Sat, 08 Mar 2026 12:00:00 GMT" "$upstream_last_modified_1" "URL import stores Last-Modified header"
expected_hash_1="2b280fca6ee87ff065b23e81958dccf40476c9bfa3aefe62507fd52ba212b60f"
if [[ "$upstream_hash_1" == "$expected_hash_1" ]]; then
	pass "URL import stores SHA-256 upstream_hash"
else
	fail "URL import stores SHA-256 upstream_hash" "Expected '$expected_hash_1', got '$upstream_hash_1'"
fi
if [[ "$local_path_1" == /* ]]; then
	assert_file_exists "$local_path_1" "URL import creates local skill file"
else
	assert_file_exists "$PROJECT_DIR_1/$local_path_1" "URL import creates local skill file"
fi

# Test 1b: nested GitHub imports place companion resources under AGENTS_DIR, not caller cwd
FAKE_REPO_1B="$TMP_DIR/fake-repo-1b"
PROJECT_DIR_1B="$TMP_DIR/project-1b"
AGENTS_DIR_1B="$TMP_DIR/agents-1b"
mkdir -p \
	"$FAKE_REPO_1B/nested-skill/references" \
	"$FAKE_REPO_1B/nested-skill/scripts" \
	"$FAKE_REPO_1B/nested-skill/assets" \
	"$PROJECT_DIR_1B/.agents" \
	"$AGENTS_DIR_1B/configs"

cat >"$FAKE_REPO_1B/nested-skill/SKILL.md" <<'EOF'
---
name: Nested GitHub
description: GitHub automation nested skill
---
# Nested GitHub
EOF
cat >"$FAKE_REPO_1B/nested-skill/references/guide.md" <<'EOF'
# Guide
EOF
cat >"$FAKE_REPO_1B/nested-skill/scripts/update-check.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
cat >"$FAKE_REPO_1B/nested-skill/assets/example.txt" <<'EOF'
asset
EOF

(
	cd "$PROJECT_DIR_1B"
	PATH="$FAKE_BIN:$PATH" \
		REAL_GIT="$REAL_GIT" \
		FAKE_GIT_SOURCE="$FAKE_REPO_1B" \
		AIDEVOPS_AGENTS_DIR="$AGENTS_DIR_1B" \
		bash "$ADD_SCRIPT" add "example/nested-repo" --skip-security >/dev/null
)

assert_file_exists "$AGENTS_DIR_1B/tools/git/nested-github-skill/references/guide.md" "Nested GitHub import copies references under AGENTS_DIR"
assert_file_exists "$AGENTS_DIR_1B/tools/git/nested-github-skill/scripts/update-check.sh" "Nested GitHub import copies scripts under AGENTS_DIR"
assert_file_exists "$AGENTS_DIR_1B/tools/git/nested-github-skill/assets/example.txt" "Nested GitHub import copies assets under AGENTS_DIR"

if [[ ! -e "$PROJECT_DIR_1B/.agents/tools/git/nested-github-skill" ]]; then
	pass "Nested GitHub import does not write resources under caller .agents"
else
	fail "Nested GitHub import does not write resources under caller .agents" "Unexpected path: $PROJECT_DIR_1B/.agents/tools/git/nested-github-skill"
fi

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
json_values_2=()
while IFS= read -r value; do
	json_values_2+=("$value")
done < <(jq -r '.updates_available, .up_to_date, .results[0].status' <<<"$JSON_OUTPUT_2")
updates_available_2="${json_values_2[0]:-}"
up_to_date_2="${json_values_2[1]:-}"
status_2="${json_values_2[2]:-}"
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
json_values_3=()
while IFS= read -r value; do
	json_values_3+=("$value")
done < <(jq -r '.updates_available, .results[0].status, .results[0].latest' <<<"$JSON_OUTPUT_3")
updates_available_3="${json_values_3[0]:-}"
status_3="${json_values_3[1]:-}"
latest_hash_3="${json_values_3[2]:-}"

assert_eq "1" "$CHECK_EXIT_3" "URL check exits non-zero when update is available"
assert_eq "1" "$updates_available_3" "URL check reports one available update"
assert_eq "update_available" "$status_3" "URL check marks changed content as update_available"
expected_hash_3="291b09128f5aadaf623ad8a05e120cf659e84d274bab87648c9a5ef9f5926d07"
if [[ "$latest_hash_3" == "$expected_hash_3" ]]; then
	pass "URL check returns latest SHA-256 hash for changed content"
else
	fail "URL check returns latest SHA-256 hash for changed content" "Expected '$expected_hash_3', got '$latest_hash_3'"
fi

# Curated imports exercise the normal update/add path with the real registry
# policies and deterministic upstream/scanner fixtures (no network or paid calls).
CURATED_AGENTS="$TMP_DIR/curated-agents"
CURATED_SOURCE="$TMP_DIR/curated-source"
mkdir -p "$CURATED_AGENTS/configs" "$CURATED_SOURCE"
ln -s "$REPO_DIR/.agents/scripts" "$CURATED_AGENTS/scripts"
jq '.skills |= map(select(.name == "remotion" or .name == "cloudflare-platform-skill"))' \
	"$REPO_DIR/.agents/configs/skill-sources.json" >"$CURATED_AGENTS/configs/skill-sources.json"
python3 - "$CURATED_SOURCE" "$CURATED_AGENTS" "$REPO_DIR/.agents" <<'PY'
import shutil
import sys
from pathlib import Path
source, agents, repo = map(Path, sys.argv[1:])
fixtures = {
    "skills/remotion-best-practices/SKILL.md": "# Router\n\n[Markup](remotion-markup/REFERENCE.md)\n",
    "skills/remotion-markup/SKILL.md": "# Markup\n\n[3D](3d.md)\n",
    "skills/remotion-markup/3d.md": "# 3D\n",
    "skills/remotion-markup/assets/icon.svg": "excluded asset",
    "skills/cloudflare/SKILL.md": "# Decision tree\n\n[Containers](references/containers/README.md)\n",
    "skills/cloudflare/references/containers/README.md": "# Containers\n\n[API](api.md)\n",
    "skills/cloudflare/references/containers/api.md": "# Containers API\n",
    "skills/cloudflare/references/containers/patterns.md": "# Containers patterns\n",
    "skills/cloudflare/references/kv/README.md": "# KV\n",
    "skills/cloudflare/references/kv/gotchas.md": "# KV gotchas\n",
    "skills/cloudflare/references/kv/patterns.md": "excluded generic patterns",
    "skills/cloudflare/references/pulumi/gotchas.md": "excluded IaC",
    "skills/agents-sdk/SKILL.md": "# Agents\n",
}
for relative, content in fixtures.items():
    file = source / relative
    file.parent.mkdir(parents=True, exist_ok=True)
    file.write_text(content)
for relative in ("tools/video/remotion/remotion.md", "services/hosting/cloudflare-platform-skill.md"):
    target = agents / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(repo / relative, target)
(agents / "tools/video/remotion/custom.md").write_text("user knowledge\n")
(agents / "services/hosting/cloudflare-platform-skill").mkdir(parents=True, exist_ok=True)
(agents / "services/hosting/cloudflare-platform-skill/custom.md").write_text("user knowledge\n")
PY
cat >"$FAKE_BIN/skill-scanner" <<'EOF'
#!/usr/bin/env bash
if [[ "${CURATED_BLOCK_SCAN:-false}" == true ]]; then
	printf '%s\n' '{"total_findings":1,"max_severity":"HIGH","findings":[{"severity":"HIGH","rule_id":"fixture","description":"blocked fixture"}]}'
else
	printf '%s\n' '{"total_findings":0,"findings":[]}'
fi
EOF
cat >"$FAKE_BIN/openskills" <<'EOF'
#!/usr/bin/env bash
exit 99
EOF
chmod +x "$FAKE_BIN/skill-scanner" "$FAKE_BIN/openskills"
for skill in remotion cloudflare-platform-skill; do
	for sync in 1 2; do
		PATH="$FAKE_BIN:$PATH" REAL_GIT="$REAL_GIT" FAKE_GIT_SOURCE="$CURATED_SOURCE" \
			AIDEVOPS_AGENTS_DIR="$CURATED_AGENTS" bash "$UPDATE_SCRIPT" update "$skill" >/dev/null
		python3 - "$CURATED_AGENTS" "$TMP_DIR/$skill-$sync.json" <<'PY'
import hashlib
import json
import sys
from pathlib import Path
agents, output = map(Path, sys.argv[1:])
files = sorted(list((agents / "tools").rglob("*.md")) + list((agents / "services").rglob("*.md")))
output.write_text(json.dumps({str(p.relative_to(agents)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}, sort_keys=True))
PY
	done
	if cmp -s "$TMP_DIR/$skill-1.json" "$TMP_DIR/$skill-2.json"; then
		pass "$skill repeated sync is byte-identical"
	else
		fail "$skill repeated sync is byte-identical"
	fi
done
assert_file_exists "$CURATED_AGENTS/tools/video/remotion/remotion-3d.md" "Repeated Remotion sync uses registry target"
assert_file_exists "$CURATED_AGENTS/services/hosting/cloudflare-platform-skill/containers-api.md" "Repeated Cloudflare sync keeps full new-product docs"
assert_file_exists "$CURATED_AGENTS/services/hosting/cloudflare-platform-skill/kv-gotchas.md" "Repeated Cloudflare sync keeps gotchas"
assert_file_exists "$CURATED_AGENTS/services/hosting/cloudflare-platform-skill/containers-patterns.md" "New-product patterns survive policy selection"
assert_file_exists "$CURATED_AGENTS/tools/video/remotion/custom.md" "Repeated sync preserves custom Remotion files"
assert_file_exists "$CURATED_AGENTS/services/hosting/cloudflare-platform-skill/custom.md" "Repeated sync preserves custom Cloudflare files"
if [[ ! -e "$CURATED_AGENTS/tools/video/remotion.md" &&
	! -e "$CURATED_AGENTS/services/hosting/cloudflare-platform-skill/kv-patterns.md" &&
	! -e "$CURATED_AGENTS/services/hosting/cloudflare-platform-skill/pulumi-gotchas.md" &&
	! -e "$CURATED_AGENTS/tools/video/remotion/assets" ]]; then
	pass "Repeated sync never recreates retired targets or excluded documents"
else
	fail "Repeated sync never recreates retired targets or excluded documents"
fi
assert_eq "1" "$(jq '[.skills[] | select(.import_policy.version == 1)] | length / 2' "$CURATED_AGENTS/configs/skill-sources.json")" "Policy survives registration on both repeated updates"
if grep -q '(remotion-markup.md)' "$CURATED_AGENTS/tools/video/remotion/remotion.md" &&
	grep -q '(containers-api.md)' "$CURATED_AGENTS/services/hosting/cloudflare-platform-skill/containers.md"; then
	pass "Router aliases and flattened local links resolve"
else
	fail "Router aliases and flattened local links resolve"
fi
cp "$CURATED_AGENTS/configs/skill-sources.json" "$TMP_DIR/curated-registry-before.json"
if PATH="$FAKE_BIN:$PATH" REAL_GIT="$REAL_GIT" FAKE_GIT_SOURCE="$CURATED_SOURCE" \
	CURATED_BLOCK_SCAN=true AIDEVOPS_AGENTS_DIR="$CURATED_AGENTS" \
	bash "$UPDATE_SCRIPT" update remotion >/dev/null 2>&1; then
	fail "Scanner rejection propagates through update"
else
	pass "Scanner rejection propagates through update"
fi
if cmp -s "$TMP_DIR/curated-registry-before.json" "$CURATED_AGENTS/configs/skill-sources.json"; then
	pass "Blocked scan leaves provenance and policy unchanged"
else
	fail "Blocked scan leaves provenance and policy unchanged"
fi

# Run setup's actual cleanup entrypoint in an isolated HOME, retaining all current
# shipped files and user files even inside a retired example directory.
MIGRATION_HOME="$TMP_DIR/migration-home"
mkdir -p "$MIGRATION_HOME/.aidevops/agents"
cp -R "$REPO_DIR/.agents/tools" "$MIGRATION_HOME/.aidevops/agents/"
mkdir -p "$MIGRATION_HOME/.aidevops/agents/services/hosting"
cp -R "$REPO_DIR/.agents/services/hosting/cloudflare-platform-skill" "$MIGRATION_HOME/.aidevops/agents/services/hosting/"
mkdir -p "$MIGRATION_HOME/.aidevops/agents/services/hosting/cloudflare-platform-skill/r2-patterns"
touch "$MIGRATION_HOME/.aidevops/agents/tools/video/remotion.md" \
	"$MIGRATION_HOME/.aidevops/agents/services/hosting/cloudflare-platform-skill/kv-patterns.md" \
	"$MIGRATION_HOME/.aidevops/agents/services/hosting/cloudflare-platform-skill/r2-patterns/01-streaming-large-files.md" \
	"$MIGRATION_HOME/.aidevops/agents/services/hosting/cloudflare-platform-skill/r2-patterns/custom.md"
HOME="$MIGRATION_HOME" bash -c 'source "$1"; source "$2"; cleanup_deprecated_paths' bash \
	"$REPO_DIR/.agents/scripts/shared-constants.sh" \
	"$REPO_DIR/.agents/scripts/setup/modules/migrations.sh" >/dev/null
if [[ ! -e "$MIGRATION_HOME/.aidevops/agents/tools/video/remotion.md" &&
	! -e "$MIGRATION_HOME/.aidevops/agents/services/hosting/cloudflare-platform-skill/kv-patterns.md" &&
	! -e "$MIGRATION_HOME/.aidevops/agents/services/hosting/cloudflare-platform-skill/r2-patterns/01-streaming-large-files.md" ]]; then
	pass "Setup cleanup removes exact retired files at runtime"
else
	fail "Setup cleanup removes exact retired files at runtime"
fi
assert_file_exists "$MIGRATION_HOME/.aidevops/agents/services/hosting/cloudflare-platform-skill/r2-patterns/custom.md" "Setup preserves user files in retired resource directories"
if python3 - "$REPO_DIR/.agents" "$MIGRATION_HOME/.aidevops/agents" <<'PY'; then
import sys
from pathlib import Path
source, deployed = map(Path, sys.argv[1:])
for relative in ("tools/video/remotion", "services/hosting/cloudflare-platform-skill"):
    for file in (source / relative).rglob("*"):
        if file.is_file():
            assert file.read_bytes() == (deployed / file.relative_to(source)).read_bytes(), str(file.relative_to(source))
PY
	pass "Setup preserves every retained skill file"
else
	fail "Setup preserves every retained skill file"
fi

printf "\nRan %d tests, %d failed.\n" "$TOTAL_COUNT" "$FAIL_COUNT"

if [[ "$FAIL_COUNT" -ne 0 ]]; then
	exit 1
fi

exit 0
