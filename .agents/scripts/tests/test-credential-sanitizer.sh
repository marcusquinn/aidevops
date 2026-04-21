#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-credential-sanitizer.sh — t2458 unit tests.
#
# Asserts that `sanitize_url()` and `scrub_credentials()` from
# shared-constants.sh correctly strip:
#   - Credential authority components (scheme://user:pass@host, scheme://token@host)
#   - Known token prefixes (sk-, ghp_, gho_, ghs_, ghu_, github_pat_,
#     glpat-, xoxb-, xoxp-) anywhere in the text.
#
# Production origin: a session observed a gho_* token in tool output after a
# helper echoed `git remote get-url origin` verbatim. The sanitizer is the
# primary defence; this test locks its invariants.

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1

# shellcheck source=../shared-constants.sh
source "${SCRIPTS_DIR}/shared-constants.sh"

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

_assert_eq() {
	local label="$1"
	local expected="$2"
	local actual="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$actual" == "$expected" ]]; then
		printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$label"
		printf '       expected: %q\n' "$expected"
		printf '       got:      %q\n' "$actual"
	fi
	return 0
}

_assert_notcontains() {
	local label="$1"
	local needle="$2"
	local haystack="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$haystack" != *"$needle"* ]]; then
		printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$label"
		printf '       haystack still contains %q: %q\n' "$needle" "$haystack"
	fi
	return 0
}

echo "[test] sanitize_url — URL authority stripping"
_assert_eq "gho_ token in https URL authority is stripped" \
	"https://github.com/owner/repo.git" \
	"$(sanitize_url "https://gho_ABCDEFGHIJ1234567890@github.com/owner/repo.git")"

_assert_eq "user:pass@ form is stripped" \
	"https://example.com/path" \
	"$(sanitize_url "https://user:hunter2@example.com/path")"

_assert_eq "clean https URL passes through unchanged" \
	"https://github.com/owner/repo.git" \
	"$(sanitize_url "https://github.com/owner/repo.git")"

_assert_eq "ssh git@ form preserved (not a credential)" \
	"git@github.com:owner/repo.git" \
	"$(sanitize_url "git@github.com:owner/repo.git")"

_assert_eq "ssh:// scheme with token is stripped" \
	"ssh://example.com/path" \
	"$(sanitize_url "ssh://tokenvalue1234@example.com/path")"

_assert_eq "empty input produces empty output" \
	"" \
	"$(sanitize_url "")"

echo ""
echo "[test] sanitize_url — token embedded in query string"
_assert_notcontains "github_pat_ in query string scrubbed" \
	"github_pat_11ABCDEFG_abcdefghijklmnop" \
	"$(sanitize_url "https://example.com/callback?token=github_pat_11ABCDEFG_abcdefghijklmnop")"

_assert_notcontains "glpat- in query string scrubbed" \
	"glpat-abcdefghijklmnop1234" \
	"$(sanitize_url "https://example.com/?key=glpat-abcdefghijklmnop1234")"

echo ""
echo "[test] scrub_credentials — token prefix matrix"
for prefix in "sk-" "ghp_" "gho_" "ghs_" "ghu_" "github_pat_" "glpat-" "xoxb-" "xoxp-"; do
	fake_token="${prefix}abcdefghij1234567890"
	input="prefix: ${fake_token} suffix"
	result=$(scrub_credentials "$input")
	_assert_notcontains "${prefix} redacted from text" "$fake_token" "$result"
done

echo ""
echo "[test] scrub_credentials — short tokens preserved (boundary)"
_assert_eq "token with <10 chars after prefix is NOT redacted" \
	"not a token: sk-abc short" \
	"$(scrub_credentials "not a token: sk-abc short")"

echo ""
echo "[test] scrub_credentials — multiple tokens in one string"
multi=$(scrub_credentials "GH token ghp_abcdefghij1234567890 and slack xoxb-abcdefghij1234567890")
_assert_notcontains "both tokens replaced (ghp_)" "ghp_abcdefghij1234567890" "$multi"
_assert_notcontains "both tokens replaced (xoxb-)" "xoxb-abcdefghij1234567890" "$multi"

echo ""
echo "[test] scrub_credentials — clean input unchanged"
_assert_eq "no tokens → verbatim" \
	"the quick brown fox" \
	"$(scrub_credentials "the quick brown fox")"

echo ""
printf '%d test(s), %d failure(s)\n' "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
