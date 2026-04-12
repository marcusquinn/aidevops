#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-privacy-guard.sh — Smoke tests for the privacy guard pre-push hook.
#
# These tests DO NOT call gh or hit the network. They stub the privacy
# library's "is public" function by overriding PRIVACY_REPOS_CONFIG and
# sourcing the library directly, bypassing the gh probe.
#
# Tests:
#   1. Match blocks: TODO.md diff introducing a private slug → scanner returns 1
#   2. Sanitised passes: TODO.md diff without private slug → scanner returns 0
#   3. No scan paths: diff only in src/ → scanner returns 0
#   4. Extra-slug file: privacy-guard-extra-slugs.txt entries are picked up
#   5. Enumerate: repos.json with mirror_upstream / local_only → enumerated correctly
#
# Usage:
#   .agents/scripts/test-privacy-guard.sh
# Exit code 0 = all tests pass, 1 = at least one failure.

set -u

# Colours
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
HELPER="${SCRIPT_DIR}/privacy-guard-helper.sh"

if [[ ! -f "$HELPER" ]]; then
	printf 'test harness cannot find helper at %s\n' "$HELPER" >&2
	exit 1
fi

# Set up a temp scratch area with a fake repos.json and a fake git repo
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export PRIVACY_REPOS_CONFIG="${TMP}/repos.json"
export PRIVACY_CACHE_FILE="${TMP}/cache.json"

cat >"$PRIVACY_REPOS_CONFIG" <<'EOF'
{
  "initialized_repos": [
    {
      "slug": "marcusquinn/aidevops",
      "path": "/tmp/aidevops",
      "pulse": true
    },
    {
      "slug": "marcusquinn/turbostarter-ai",
      "path": "/tmp/turbostarter/ai",
      "pulse": false,
      "mirror_upstream": "turbostarter/ai"
    },
    {
      "slug": "marcusquinn/wpallstars.com",
      "path": "/tmp/wpallstars.com",
      "local_only": true
    }
  ]
}
EOF

# shellcheck source=privacy-guard-helper.sh
source "$HELPER"

printf '%sRunning privacy-guard tests%s\n' "$BLUE" "$NC"

# -----------------------------------------------------------------------------
# Test 5: enumerate
# -----------------------------------------------------------------------------
slugs=$(privacy_enumerate_private_slugs 2>/dev/null)
if printf '%s\n' "$slugs" | grep -q '^marcusquinn/turbostarter-ai$' &&
	printf '%s\n' "$slugs" | grep -q '^marcusquinn/wpallstars.com$'; then
	pass "enumerate picks up mirror_upstream and local_only entries"
else
	fail "enumerate missed expected slugs. Output:"
	printf '%s\n' "$slugs" | sed 's/^/     /'
fi

if printf '%s\n' "$slugs" | grep -q '^marcusquinn/aidevops$'; then
	fail "enumerate incorrectly included public aidevops slug"
else
	pass "enumerate excludes non-private aidevops slug"
fi

# -----------------------------------------------------------------------------
# Test 4: extra slug file
# -----------------------------------------------------------------------------
EXTRA_DIR="${TMP}/configs"
mkdir -p "$EXTRA_DIR"
EXTRA_FILE="${EXTRA_DIR}/privacy-guard-extra-slugs.txt"
cat >"$EXTRA_FILE" <<'EOF'
# extra private slugs
marcusquinn/extra-secret
EOF

# Override HOME temporarily so the helper reads our test extra-slugs file
ORIG_HOME="$HOME"
export HOME="$TMP"
mkdir -p "$HOME/.aidevops/configs"
cp "$EXTRA_FILE" "$HOME/.aidevops/configs/privacy-guard-extra-slugs.txt"
slugs_with_extra=$(privacy_enumerate_private_slugs 2>/dev/null)
export HOME="$ORIG_HOME"

if printf '%s\n' "$slugs_with_extra" | grep -q '^marcusquinn/extra-secret$'; then
	pass "enumerate includes entries from privacy-guard-extra-slugs.txt"
else
	fail "enumerate missed extra slug from config file. Output:"
	printf '%s\n' "$slugs_with_extra" | sed 's/^/     /'
fi

# -----------------------------------------------------------------------------
# Prepare a real git repo for diff scanning tests
# -----------------------------------------------------------------------------
REPO="${TMP}/fake-repo"
mkdir -p "$REPO"
(
	cd "$REPO" || exit 1
	git init --quiet
	git config user.email 'test@example.com'
	git config user.name 'Test'
	# Initial empty commit
	git commit --allow-empty -m 'init' --quiet
) || {
	printf 'failed to create fake repo\n' >&2
	exit 1
}

SLUGS_FILE="${TMP}/private-slugs.txt"
cat >"$SLUGS_FILE" <<'EOF'
marcusquinn/turbostarter-ai
marcusquinn/wpallstars.com
EOF

# -----------------------------------------------------------------------------
# Test 1: TODO.md diff with private slug → blocks
# -----------------------------------------------------------------------------
(
	cd "$REPO" || exit 1
	cat >TODO.md <<'EOF'
- [x] r005 Sync mirror marcusquinn/turbostarter-ai run:custom/scripts/mirror-sync.sh
EOF
	git add TODO.md
	git commit -m 'add TODO with private slug' --quiet
) || fail "could not seed test 1 repo state"

# Scan the newly added commit against the initial empty commit
base=$(git -C "$REPO" rev-list --max-parents=0 HEAD)
head=$(git -C "$REPO" rev-parse HEAD)

pushd "$REPO" >/dev/null || exit 1
hits=$(privacy_scan_diff "$base" "$head" "$SLUGS_FILE")
rc=$?
popd >/dev/null || exit 1
if [[ "$rc" -eq 1 ]] && printf '%s' "$hits" | grep -q 'marcusquinn/turbostarter-ai'; then
	pass "diff with private slug in TODO.md is flagged"
else
	fail "diff with private slug not flagged (rc=$rc hits=$hits)"
fi

# -----------------------------------------------------------------------------
# Test 2: sanitised TODO.md → does not block
# -----------------------------------------------------------------------------
(
	cd "$REPO" || exit 1
	cat >TODO.md <<'EOF'
- [x] r005 Sync private mirror repos (see local routine config) run:custom/scripts/mirror-sync.sh
EOF
	git add TODO.md
	git commit -m 'sanitise TODO' --quiet
) || fail "could not seed test 2 repo state"

base=$(git -C "$REPO" rev-parse HEAD~1)
head=$(git -C "$REPO" rev-parse HEAD)

pushd "$REPO" >/dev/null || exit 1
hits=$(privacy_scan_diff "$base" "$head" "$SLUGS_FILE")
rc=$?
popd >/dev/null || exit 1
if [[ "$rc" -eq 0 && -z "$hits" ]]; then
	pass "sanitised TODO.md diff is not flagged"
else
	fail "sanitised diff incorrectly flagged (rc=$rc hits=$hits)"
fi

# -----------------------------------------------------------------------------
# Test 3: diff only in src/ (outside scan globs) → does not block
# -----------------------------------------------------------------------------
(
	cd "$REPO" || exit 1
	mkdir -p src
	cat >src/code.ts <<'EOF'
// reference to marcusquinn/turbostarter-ai in source code (private handling)
const MIRROR = "marcusquinn/turbostarter-ai";
EOF
	git add src/code.ts
	git commit -m 'add source reference' --quiet
) || fail "could not seed test 3 repo state"

base=$(git -C "$REPO" rev-parse HEAD~1)
head=$(git -C "$REPO" rev-parse HEAD)

pushd "$REPO" >/dev/null || exit 1
hits=$(privacy_scan_diff "$base" "$head" "$SLUGS_FILE")
rc=$?
popd >/dev/null || exit 1
if [[ "$rc" -eq 0 && -z "$hits" ]]; then
	pass "src/ diff outside scan globs is not flagged"
else
	fail "src/ diff incorrectly flagged (rc=$rc hits=$hits)"
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
