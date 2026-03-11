#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI_SCRIPT="$REPO_DIR/aidevops.sh"
TOOL_CHECK_SCRIPT="$REPO_DIR/.agents/scripts/tool-version-check.sh"

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

assert_grep() {
	local pattern="$1"
	local file="$2"
	local name="$3"
	if grep -qE "$pattern" "$file"; then
		pass "$name"
	else
		fail "$name" "Pattern not found: $pattern"
	fi
	return 0
}

assert_not_grep() {
	local pattern="$1"
	local file="$2"
	local name="$3"
	if grep -qE "$pattern" "$file"; then
		fail "$name" "Unexpected pattern found: $pattern"
	else
		pass "$name"
	fi
	return 0
}

assert_contains() {
	local haystack="$1"
	local needle="$2"
	local name="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		pass "$name"
	else
		fail "$name" "Missing substring: $needle"
	fi
	return 0
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"

cat >"$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "--version" ]]; then
	printf 'gh version 2.0.0\n'
	exit 0
fi
printf 'Error: Token refresh failed: 500\n' >&2
exit 1
EOF
chmod +x "$FAKE_BIN/gh"

cat >"$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"tag_name":"v2.1.0"}\n'
EOF
chmod +x "$FAKE_BIN/curl"

cat >"$FAKE_BIN/timeout" <<'EOF'
#!/usr/bin/env bash
shift
exec "$@"
EOF
chmod +x "$FAKE_BIN/timeout"

PATH="$FAKE_BIN:/usr/bin:/bin" TOOL_OUTPUT="$(bash "$TOOL_CHECK_SCRIPT" --category brew --json 2>&1 || true)"

# shellcheck disable=SC2016
BREW_BIN_PATTERN='\[\[ -n "\$brew_bin" && -x "\$brew_bin" \]\]'
GH_LATEST_PATTERN='"latest": "2.1.0"'
GH_INSTALLED_PATTERN='"installed": "2.0.0"'

assert_grep 'brew_bin=.*command -v brew' "$CLI_SCRIPT" 'CLI resolves brew path before timeout use'
assert_grep "$BREW_BIN_PATTERN" "$CLI_SCRIPT" 'CLI requires brew to be executable before invoking timeout'
assert_grep 'get_public_release_tag "cli/cli"' "$CLI_SCRIPT" 'CLI uses public GitHub API fallback for gh latest version'
assert_not_grep 'gh api repos/cli/cli/releases/latest' "$CLI_SCRIPT" 'CLI no longer depends on gh auth for gh latest version checks'

assert_grep 'brew_bin=.*command -v brew' "$TOOL_CHECK_SCRIPT" 'Tool checker resolves brew path before timeout use'
assert_grep "$BREW_BIN_PATTERN" "$TOOL_CHECK_SCRIPT" 'Tool checker requires brew to be executable before invoking timeout'
assert_grep 'get_public_release_tag "cli/cli"' "$TOOL_CHECK_SCRIPT" 'Tool checker uses public GitHub API fallback for gh latest version'

assert_contains "$TOOL_OUTPUT" "$GH_LATEST_PATTERN" 'Tool checker reports gh latest version from public API fallback'
assert_contains "$TOOL_OUTPUT" "$GH_INSTALLED_PATTERN" 'Tool checker keeps the installed gh version when brew is unavailable'

if [[ "$TOOL_OUTPUT" == *'timeout: failed to run command'* ]]; then
	fail 'Tool checker avoids timeout/brew ENOENT when brew is unavailable' "$TOOL_OUTPUT"
else
	pass 'Tool checker avoids timeout/brew ENOENT when brew is unavailable'
fi

if [[ "$TOOL_OUTPUT" == *'Token refresh failed: 500'* ]]; then
	fail 'Tool checker avoids gh auth refresh failures for public latest checks' "$TOOL_OUTPUT"
else
	pass 'Tool checker avoids gh auth refresh failures for public latest checks'
fi

printf "\nRan %d tests, %d failed.\n" "$TOTAL_COUNT" "$FAIL_COUNT"

if [[ "$FAIL_COUNT" -ne 0 ]]; then
	exit 1
fi

exit 0
