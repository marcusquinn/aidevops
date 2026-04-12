#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-canonical-guard.sh — Smoke tests for the canonical-on-main post-checkout hook.
#
# Model: mirrors test-privacy-guard.sh (t1969). No network, no gh dependency.
# Uses a throwaway git repo + stub repos.json to exercise each branch of the
# hook's decision tree.
#
# Tests:
#   1. Bypass env var → exit 0, no stderr banner
#   2. Headless env var → exit 0, no stderr banner
#   3. File-level checkout flag (flag=0) → exit 0, no stderr banner
#   4. Worktree (non-canonical) → exit 0, no stderr banner
#   5. Canonical on main → exit 0, no stderr banner
#   6. Canonical off main + repo NOT in repos.json → exit 0 (fail-open)
#   7. Canonical off main + repo IN repos.json, interactive → exit 0 with warning
#   8. Canonical off main + repo IN repos.json, strict → exit 1 with warning
#
# Exit 0 = all tests pass, 1 = at least one failure.

set -u

if [[ -t 1 ]]; then
	GREEN=$'\033[0;32m'
	RED=$'\033[0;31m'
	BLUE=$'\033[0;34m'
	NC=$'\033[0m'
else
	GREEN="" RED="" BLUE="" NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$GREEN" "$NC" "$1"
	return 0
}

fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$RED" "$NC" "$1"
	return 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${SCRIPT_DIR}/../hooks/canonical-on-main-guard.sh"

if [[ ! -f "$HOOK" ]]; then
	printf 'test harness cannot find hook at %s\n' "$HOOK" >&2
	exit 1
fi

# Scratch dir with fake HOME for stubbed repos.json
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP"
mkdir -p "$HOME/.config/aidevops"

# Create a fake canonical repo
REPO="${TMP}/fake-canonical"
mkdir -p "$REPO"
(
	cd "$REPO" || exit 1
	git init --quiet
	git config user.email test@example.com
	git config user.name Test
	git commit --allow-empty -m init --quiet
	git branch -M main
	git checkout -b feature-branch --quiet
) || {
	printf 'failed to create fake canonical repo\n' >&2
	exit 1
}

# Register it in the stub repos.json
REPO_ABS=$(cd "$REPO" && pwd)
cat >"$HOME/.config/aidevops/repos.json" <<EOF
{
  "initialized_repos": [
    {
      "slug": "testorg/fake-canonical",
      "path": "$REPO_ABS",
      "pulse": true
    }
  ],
  "git_parent_dirs": []
}
EOF

# Helper: run the hook and capture exit code + stderr
_run_hook() {
	local flag="${1:-1}"
	pushd "$REPO" >/dev/null || return 99
	# Unset all headless env vars first to get a clean interactive baseline
	local stderr_file
	stderr_file=$(mktemp)
	(
		unset FULL_LOOP_HEADLESS AIDEVOPS_HEADLESS OPENCODE_HEADLESS GITHUB_ACTIONS
		# Apply caller-provided env strings (format: KEY=value) — parse and set
		shift
		while [[ $# -gt 0 ]]; do
			local kv="$1"
			local key="${kv%%=*}"
			local val="${kv#*=}"
			# shellcheck disable=SC2086
			export "$key=$val"
			shift
		done
		bash "$HOOK" "previous" "$(git rev-parse HEAD)" "$flag" 2>"$stderr_file"
	)
	local rc=$?
	HOOK_STDERR=$(cat "$stderr_file")
	rm -f "$stderr_file"
	popd >/dev/null || return 99
	return "$rc"
}

printf '%sRunning canonical-on-main-guard tests%s\n' "$BLUE" "$NC"

# -----------------------------------------------------------------------------
# Test 1: bypass env var
# -----------------------------------------------------------------------------
_run_hook 1 "AIDEVOPS_CANONICAL_GUARD=bypass"
rc=$?
if [[ "$rc" -eq 0 && -z "$HOOK_STDERR" ]]; then
	pass "bypass: exit 0, no warning"
else
	fail "bypass: expected exit 0 + silent, got rc=$rc stderr=${HOOK_STDERR:0:60}"
fi

# -----------------------------------------------------------------------------
# Test 2: headless env var (FULL_LOOP_HEADLESS)
# -----------------------------------------------------------------------------
_run_hook 1 "FULL_LOOP_HEADLESS=true"
rc=$?
if [[ "$rc" -eq 0 && -z "$HOOK_STDERR" ]]; then
	pass "headless FULL_LOOP_HEADLESS: exit 0, no warning"
else
	fail "headless: expected exit 0 + silent, got rc=$rc stderr=${HOOK_STDERR:0:60}"
fi

# -----------------------------------------------------------------------------
# Test 3: file-level checkout (flag=0)
# -----------------------------------------------------------------------------
_run_hook 0
rc=$?
if [[ "$rc" -eq 0 && -z "$HOOK_STDERR" ]]; then
	pass "file-level checkout (flag=0): exit 0, no warning"
else
	fail "file-level checkout: expected exit 0 + silent, got rc=$rc stderr=${HOOK_STDERR:0:60}"
fi

# -----------------------------------------------------------------------------
# Test 4: canonical on main (no violation)
# -----------------------------------------------------------------------------
pushd "$REPO" >/dev/null || exit 1
git checkout main --quiet
popd >/dev/null || exit 1
_run_hook 1
rc=$?
if [[ "$rc" -eq 0 && -z "$HOOK_STDERR" ]]; then
	pass "canonical on main: exit 0, no warning"
else
	fail "canonical on main: expected exit 0 + silent, got rc=$rc stderr=${HOOK_STDERR:0:60}"
fi

# -----------------------------------------------------------------------------
# Test 5: canonical off main + NOT in repos.json (fail-open)
# -----------------------------------------------------------------------------
# Temporarily blank out repos.json
mv "$HOME/.config/aidevops/repos.json" "$HOME/.config/aidevops/repos.json.bak"
cat >"$HOME/.config/aidevops/repos.json" <<'EOF'
{"initialized_repos":[],"git_parent_dirs":[]}
EOF

pushd "$REPO" >/dev/null || exit 1
git checkout feature-branch --quiet
popd >/dev/null || exit 1
_run_hook 1
rc=$?
if [[ "$rc" -eq 0 && -z "$HOOK_STDERR" ]]; then
	pass "canonical off main + unknown repo: exit 0 (fail-open)"
else
	fail "fail-open: expected exit 0 + silent, got rc=$rc stderr=${HOOK_STDERR:0:60}"
fi

# Restore repos.json
mv "$HOME/.config/aidevops/repos.json.bak" "$HOME/.config/aidevops/repos.json"

# -----------------------------------------------------------------------------
# Test 6: canonical off main + IN repos.json, interactive → warn, exit 0
# -----------------------------------------------------------------------------
_run_hook 1
rc=$?
if [[ "$rc" -eq 0 ]] && [[ "$HOOK_STDERR" == *"canonical-on-main-guard"* ]]; then
	pass "canonical off main + known repo, interactive: exit 0 + warning"
else
	fail "interactive violation: expected exit 0 + warning, got rc=$rc stderr_present=$([[ -n $HOOK_STDERR ]] && echo yes || echo no)"
fi

# -----------------------------------------------------------------------------
# Test 7: canonical off main + IN repos.json, strict → warn, exit 1
# -----------------------------------------------------------------------------
_run_hook 1 "AIDEVOPS_CANONICAL_GUARD=strict"
rc=$?
if [[ "$rc" -eq 1 ]] && [[ "$HOOK_STDERR" == *"canonical-on-main-guard"* ]]; then
	pass "canonical off main + strict: exit 1 + warning"
else
	fail "strict violation: expected exit 1 + warning, got rc=$rc"
fi

# -----------------------------------------------------------------------------
# Test 8: worktree (non-canonical) → no warning
# -----------------------------------------------------------------------------
# Create a worktree of the fake repo
WORKTREE="${TMP}/fake-worktree"
pushd "$REPO" >/dev/null || exit 1
git checkout main --quiet
git worktree add "$WORKTREE" -b wt-test --quiet 2>/dev/null || true
popd >/dev/null || exit 1

pushd "$WORKTREE" >/dev/null || exit 1
# Switch to a non-main branch in the worktree
git checkout -b another-feature --quiet 2>/dev/null || git checkout another-feature --quiet 2>/dev/null
stderr_file=$(mktemp)
(
	unset FULL_LOOP_HEADLESS AIDEVOPS_HEADLESS OPENCODE_HEADLESS GITHUB_ACTIONS
	bash "$HOOK" "previous" "$(git rev-parse HEAD)" "1" 2>"$stderr_file"
)
rc=$?
worktree_stderr=$(cat "$stderr_file")
rm -f "$stderr_file"
popd >/dev/null || exit 1
if [[ "$rc" -eq 0 && -z "$worktree_stderr" ]]; then
	pass "worktree off main: exit 0, no warning (worktrees are expected off main)"
else
	fail "worktree: expected exit 0 + silent, got rc=$rc stderr_present=$([[ -n $worktree_stderr ]] && echo yes || echo no)"
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
printf '\n'
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d test(s) passed%s\n' "$GREEN" "$TESTS_RUN" "$NC"
	exit 0
fi
printf '%s%d of %d test(s) failed%s\n' "$RED" "$TESTS_FAILED" "$TESTS_RUN" "$NC"
exit 1
