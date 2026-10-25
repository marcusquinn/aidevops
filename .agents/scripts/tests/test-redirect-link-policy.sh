#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-redirect-link-policy.sh — redirect/shortener link detection (GH#35655).
# Lexical only: no test performs network I/O.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
SCANNER="${SCRIPT_DIR}/redirect_link_policy.py"
POLICY_HELPER="${SCRIPT_DIR}/command-policy-helper.py"
TESTS=0
FAILURES=0

pass() {
	local name="$1"
	TESTS=$((TESTS + 1))
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	TESTS=$((TESTS + 1))
	FAILURES=$((FAILURES + 1))
	printf 'FAIL %s: %s\n' "$name" "$detail"
	return 0
}

# assert_scan NAME EXPECTED_EXIT TEXT [extra args...]
assert_scan() {
	local name="$1"
	local expected="$2"
	local text="$3"
	shift 3
	local output=""
	local status=0
	output="$(printf '%s' "$text" | python3 "$SCANNER" scan "$@")" || status=$?
	if [[ "$status" -eq "$expected" ]]; then
		pass "$name"
	else
		fail "$name" "expected exit ${expected}, got ${status}: ${output}"
	fi
	return 0
}

# Positive: redirect links in every supported form.
assert_scan "scheme url" 1 "see https://is.gd/ywaF51 now"
assert_scan "markdown anchor" 1 "[Join the community](https://bit.ly/abc123)"
assert_scan "html anchor" 1 '<a href="https://tinyurl.com/y2abc">here</a>'
assert_scan "html entity encoded" 1 '<a href="https&#58;//tinyurl&#46;com/y2abc">x</a>'
assert_scan "bare host slug" 1 "visit is.gd/ywaF51 for stars"
assert_scan "www prefix" 1 "www.bit.ly/abc"
assert_scan "uppercase" 1 "HTTPS://BIT.LY/ABC"
assert_scan "defanged dot" 1 "is[.]gd/ywaF51"
assert_scan "defanged scheme" 1 "hxxps[:]//bit[.]ly/abc"
assert_scan "zero-width split" 1 $'https://bit\u200b.ly/abc'
assert_scan "fullwidth dot" 1 $'https://is\uff0egd/abc'
assert_scan "ideographic dot" 1 $'https://t\u3002co/abc'
assert_scan "percent-encoded host" 1 "https://%62it.ly/abc"
assert_scan "userinfo masking" 1 "https://github.com@bit.ly/abc"
assert_scan "suffix rule" 1 "https://eur01.safelinks.protection.outlook.com/?url=x"
assert_scan "path rule" 1 "https://www.google.com/url?q=https://example.com"
assert_scan "protocol relative" 1 "//rb.gy/abc"
assert_scan "strict bare host" 1 "short link host is.gd here" --strict-bare

# Negative: ordinary links, lookalikes, code identifiers, prose mentions.
assert_scan "github link clean" 0 "https://github.com/marcusquinn/aidevops/issues/35640"
assert_scan "docs link clean" 0 "See https://docs.github.com/en/rest for details."
assert_scan "lookalike prefix" 0 "https://this.gd/abc"
assert_scan "lookalike word" 0 "https://notbit.ly/abc"
assert_scan "lookalike suffix" 0 "https://bit.ly.example.com/abc"
assert_scan "identifier no slug" 0 "config s.id and x.co fields"
assert_scan "prose host mention" 0 "We never open is.gd links."
assert_scan "google search path" 0 "https://www.google.com/search?q=aidevops"
assert_scan "google urlx path" 0 "https://www.google.com/urlshortener"
assert_scan "empty text" 0 ""

# Output must never echo the matched URL slug (public CI logs).
leak_output="$(printf '%s' "https://is.gd/ywaF51" | python3 "$SCANNER" scan)"
if [[ "$leak_output" == *"ywaF51"* || "$leak_output" == *"ywaf51"* ]]; then
	fail "no url echo" "$leak_output"
else
	pass "no url echo"
fi

# check-url mode.
if python3 "$SCANNER" check-url "https://github.com/x" >/dev/null; then
	pass "check-url clean"
else
	fail "check-url clean" "non-zero exit"
fi
check_status=0
python3 "$SCANNER" check-url "https://cutt.ly/abc" >/dev/null || check_status=$?
if [[ "$check_status" -eq 1 ]]; then
	pass "check-url redirect"
else
	fail "check-url redirect" "exit ${check_status}"
fi

# Missing config fails closed with exit 2.
missing_status=0
printf 'x' | python3 "$SCANNER" scan --config /nonexistent/redirect-hosts.conf >/dev/null 2>&1 || missing_status=$?
if [[ "$missing_status" -eq 2 ]]; then
	pass "missing config fails closed"
else
	fail "missing config fails closed" "exit ${missing_status}"
fi

# Shared command policy: interactive (non-worker) sessions must not open
# redirect links; ordinary hosts remain allowed.
assert_policy() {
	local name="$1"
	local command_text="$2"
	local expected="$3"
	local output=""
	local decision=""
	output="$(env -u AIDEVOPS_WORKER_ID -u FULL_LOOP_HEADLESS -u AIDEVOPS_HEADLESS -u OPENCODE_HEADLESS -u CLAUDE_HEADLESS -u HEADLESS -u GITHUB_ACTIONS \
		python3 "$POLICY_HELPER" check-command --cwd "$SCRIPT_DIR" --command "$command_text" 2>/dev/null)"
	decision="$(printf '%s' "$output" | python3 -c 'import json,sys
try:
    data = json.load(sys.stdin)
except json.JSONDecodeError:
    print("invalid")
else:
    print(data.get("decision", "") + "/" + data.get("rule_id", ""))')"
	if [[ "$decision" == "$expected"* ]]; then
		pass "$name"
	else
		fail "$name" "expected ${expected}, got ${decision}"
	fi
	return 0
}

assert_policy "policy curl redirect" "curl -sL https://is.gd/ywaF51" "forbid/network.redirect-link"
assert_policy "policy wget redirect" "wget https://bit.ly/abc" "forbid/network.redirect-link"
assert_policy "policy open redirect" "open https://tinyurl.com/abc" "forbid/network.redirect-link"
assert_policy "policy defanged redirect" "curl 'hxxps://bit[.]ly/abc'" "forbid/network.redirect-link"
assert_policy "policy helper url arg" "browser-qa-helper.sh screenshot https://rb.gy/abc" "forbid/network.redirect-link"
assert_policy "policy echo mention allowed" "rg -n 'is.gd' .agents/configs" "allow"
assert_policy "policy curl github allowed" "curl -s https://api.github.com/zen" "allow"

# Claude Code adapter: URL-bearing tools (WebFetch/MCP) are denied for
# redirect links; file tools and ordinary URLs are allowed.
CLAUDE_HOOK="${SCRIPT_DIR}/../hooks/git_safety_guard.py"
assert_hook() {
	local name="$1"
	local payload="$2"
	local expected="$3"
	local output=""
	local actual="allow"
	output="$(printf '%s' "$payload" | python3 "$CLAUDE_HOOK" 2>/dev/null)"
	[[ "$output" == *'"deny"'* ]] && actual="deny"
	if [[ "$actual" == "$expected" ]]; then
		pass "$name"
	else
		fail "$name" "expected ${expected}, got ${actual}"
	fi
	return 0
}

assert_hook "hook webfetch redirect" '{"tool_name":"WebFetch","tool_input":{"url":"https://is.gd/x1","prompt":"x"}}' "deny"
assert_hook "hook mcp navigate redirect" '{"tool_name":"mcp__playwright__browser_navigate","tool_input":{"url":"https://bit.ly/x1"}}' "deny"
assert_hook "hook webfetch github" '{"tool_name":"WebFetch","tool_input":{"url":"https://github.com/x","prompt":"x"}}' "allow"

printf '\n%d tests, %d failures\n' "$TESTS" "$FAILURES"
[[ "$FAILURES" -eq 0 ]] || exit 1
exit 0
