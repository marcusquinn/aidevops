#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression tests for managed README Star History and provenance sections.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1
HELPER="$REPO_ROOT/.agents/scripts/managed-readme-helper.sh"
TEST_ROOT=""
TESTS_RUN=0
TESTS_FAILED=0

cleanup() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

trap cleanup EXIT

pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s\n     %s\n' "$name" "$detail" >&2
	return 0
}

assert_file() {
	local name="$1"
	local file="$2"
	if [[ -f "$file" ]]; then
		pass "$name"
		return 0
	fi
	fail "$name" "missing file: $file"
	return 0
}

assert_contains() {
	local name="$1"
	local file="$2"
	local pattern="$3"
	if grep -Fq -- "$pattern" "$file"; then
		pass "$name"
		return 0
	fi
	fail "$name" "missing pattern: $pattern"
	return 0
}

assert_count() {
	local name="$1"
	local file="$2"
	local pattern="$3"
	local expected="$4"
	local actual=""
	actual=$(grep -Fc -- "$pattern" "$file" || true)
	if [[ "$actual" == "$expected" ]]; then
		pass "$name"
		return 0
	fi
	fail "$name" "expected $expected occurrences of $pattern, got $actual"
	return 0
}

write_gh_stub() {
	local bin_dir="$1"
	mkdir -p "$bin_dir"
	cat >"$bin_dir/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "repo" && "${2:-}" == "view" ]]; then
  slug="${3:-}"
  permission="${GH_STUB_PERMISSION:-ADMIN}"
  printf '{"nameWithOwner":"%s","viewerPermission":"%s"}\n' "$slug" "$permission"
  exit 0
fi
if [[ "${1:-}" == "api" ]]; then
  if [[ "${2:-}" == "--paginate" && "${GH_STUB_FETCH_FAIL:-0}" == "1" ]]; then
    exit 1
  fi
  printf '{"owner":{"html_url":"https://github.com/exampleorg"}}\n'
  exit 0
fi
exit 1
STUB
	chmod +x "$bin_dir/gh"
	return 0
}

test_created_repo_sync() {
	local root="$TEST_ROOT/created"
	local bin_dir="$TEST_ROOT/bin"
	mkdir -p "$root"
	write_gh_stub "$bin_dir"
	printf '{}\n' >"$root/.aidevops.json"
	cat >"$root/README.md" <<'README'
# Example

Custom project content.

## Star History

Old chart.

## Built with aidevops

Old attribution.

[custom-reference]: https://example.com/docs

<!-- generated: keep -->
README
	GH_STUB_FETCH_FAIL=1 PATH="$bin_dir:$PATH" \
		bash "$HELPER" sync --repo exampleorg/example --root "$root"
	assert_file "created repo receives static chart" "$root/docs/assets/star-history.svg"
	assert_contains "failed live fetch falls back to a valid placeholder" "$root/docs/assets/star-history.svg" "No star history available"
	assert_file "created repo receives refresh caller" "$root/.github/workflows/star-history.yml"
	assert_contains "custom README content is preserved" "$root/README.md" "Custom project content."
	assert_contains "verified owner root is rendered" "$root/README.md" "https://github.com/exampleorg"
	assert_contains "trailing link definitions are preserved" "$root/README.md" "[custom-reference]: https://example.com/docs"
	assert_contains "trailing generated comments are preserved" "$root/README.md" "<!-- generated: keep -->"
	assert_count "Star History is unique" "$root/README.md" "## Star History" 1
	assert_count "aidevops attribution is unique" "$root/README.md" "## Built with aidevops" 1
	local first=""
	first=$(cksum "$root/README.md" "$root/docs/assets/star-history.svg" "$root/.github/workflows/star-history.yml")
	PATH="$bin_dir:$PATH" bash "$HELPER" sync --repo exampleorg/example --root "$root"
	local second=""
	second=$(cksum "$root/README.md" "$root/docs/assets/star-history.svg" "$root/.github/workflows/star-history.yml")
	if [[ "$first" == "$second" ]]; then
		pass "managed README sync is idempotent"
	else
		fail "managed README sync is idempotent" "checksums changed on the second run"
	fi
	PATH="$bin_dir:$PATH" bash "$HELPER" check --repo exampleorg/example --root "$root"
	pass "managed README check accepts current files"
	return 0
}

test_registry_and_exclusions() {
	local managed="$TEST_ROOT/managed"
	local local_only="$TEST_ROOT/local"
	local contributed="$TEST_ROOT/contributed"
	local bin_dir="$TEST_ROOT/bin"
	mkdir -p "$managed" "$local_only" "$contributed"
	printf '# Managed\n' >"$managed/README.md"
	printf '# Local\n' >"$local_only/README.md"
	printf '# Contributed\n' >"$contributed/README.md"
	cat >"$TEST_ROOT/repos.json" <<JSON
{"initialized_repos":[
  {"slug":"exampleorg/managed","path":"$managed"},
  {"slug":"exampleorg/local","path":"$local_only","local_only":true},
  {"slug":"upstream/contributed","path":"$contributed","contributed":true}
]}
JSON
	AIDEVOPS_REPOS_FILE="$TEST_ROOT/repos.json" PATH="$bin_dir:$PATH" \
		bash "$HELPER" sync --repo exampleorg/managed --root "$managed"
	assert_file "repos.json managed repo is synchronized" "$managed/docs/assets/star-history.svg"
	AIDEVOPS_REPOS_FILE="$TEST_ROOT/repos.json" PATH="$bin_dir:$PATH" \
		bash "$HELPER" sync --repo exampleorg/local --root "$local_only"
	AIDEVOPS_REPOS_FILE="$TEST_ROOT/repos.json" PATH="$bin_dir:$PATH" \
		bash "$HELPER" sync --repo upstream/contributed --root "$contributed"
	if [[ ! -e "$local_only/docs/assets/star-history.svg" && ! -e "$contributed/docs/assets/star-history.svg" ]]; then
		pass "local-only and contributed repos remain unchanged"
	else
		fail "local-only and contributed repos remain unchanged" "an excluded chart was created"
	fi
	return 0
}

test_permission_failure() {
	local root="$TEST_ROOT/read-only"
	local bin_dir="$TEST_ROOT/bin"
	mkdir -p "$root"
	printf '{}\n' >"$root/.aidevops.json"
	printf '# Read only\n' >"$root/README.md"
	if GH_STUB_PERMISSION=READ PATH="$bin_dir:$PATH" \
		bash "$HELPER" sync --repo exampleorg/read-only --root "$root" >/dev/null 2>&1; then
		fail "read-only GitHub access fails closed" "sync unexpectedly succeeded"
	else
		pass "read-only GitHub access fails closed"
	fi
	if [[ ! -e "$root/docs/assets/star-history.svg" ]]; then
		pass "permission failure creates no public artifact"
	else
		fail "permission failure creates no public artifact" "chart was created"
	fi
	return 0
}

main() {
	TEST_ROOT=$(mktemp -d)
	test_created_repo_sync
	test_registry_and_exclusions
	test_permission_failure
	printf 'Tests run: %d, failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]] || return 1
	return 0
}

main "$@"
