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
      "slug": "testorg/public-repo",
      "path": "/tmp/public-repo",
      "pulse": true
    },
    {
      "slug": "testorg/private-mirror",
      "path": "/tmp/private-mirror",
      "pulse": false,
      "mirror_upstream": "upstream/source-repo"
    },
    {
      "slug": "testorg/local-only",
      "path": "/tmp/local-only",
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
if printf '%s\n' "$slugs" | grep -q '^testorg/private-mirror$' &&
	printf '%s\n' "$slugs" | grep -q '^testorg/local-only$'; then
	pass "enumerate picks up mirror_upstream and local_only entries"
else
	fail "enumerate missed expected slugs. Output:"
	printf '%s\n' "$slugs" | sed 's/^/     /'
fi

if printf '%s\n' "$slugs" | grep -q '^testorg/public-repo$'; then
	fail "enumerate incorrectly included public testorg slug"
else
	pass "enumerate excludes non-private testorg/public-repo slug"
fi

# -----------------------------------------------------------------------------
# Test 4: extra slug file
# -----------------------------------------------------------------------------
EXTRA_DIR="${TMP}/configs"
mkdir -p "$EXTRA_DIR"
EXTRA_FILE="${EXTRA_DIR}/privacy-guard-extra-slugs.txt"
cat >"$EXTRA_FILE" <<'EOF'
# extra private slugs
testorg/extra-secret-repo
EOF

# Override HOME temporarily so the helper reads our test extra-slugs file
ORIG_HOME="$HOME"
export HOME="$TMP"
mkdir -p "$HOME/.aidevops/configs"
cp "$EXTRA_FILE" "$HOME/.aidevops/configs/privacy-guard-extra-slugs.txt"
slugs_with_extra=$(privacy_enumerate_private_slugs 2>/dev/null)
export HOME="$ORIG_HOME"

if printf '%s\n' "$slugs_with_extra" | grep -q '^testorg/extra-secret-repo$'; then
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
testorg/private-mirror
testorg/local-only
EOF

# -----------------------------------------------------------------------------
# Test 1: TODO.md diff with private slug → blocks
# -----------------------------------------------------------------------------
(
	cd "$REPO" || exit 1
	cat >TODO.md <<'EOF'
- [x] r005 Sync mirror testorg/private-mirror run:custom/scripts/mirror-sync.sh
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
if [[ "$rc" -eq 1 ]] && printf '%s' "$hits" | grep -q 'testorg/private-mirror'; then
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
// reference to testorg/private-mirror in source code (private handling)
const MIRROR = "testorg/private-mirror";
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

# =============================================================================
# t1969: privacy_is_target_public stub-based tests (via cache pre-seeding)
# =============================================================================

#######################################
# Pre-seed the privacy cache with a given slug/privacy pair. Optionally
# back-date the entry by age_seconds to exercise TTL expiry.
#######################################
_seed_cache() {
	local slug="$1"
	local private_bool="$2"
	local age_seconds="${3:-0}"
	local now
	now=$(date +%s)
	local checked_at=$((now - age_seconds))
	if [[ ! -f "$PRIVACY_CACHE_FILE" ]]; then
		printf '{}\n' >"$PRIVACY_CACHE_FILE"
	fi
	local tmp
	tmp=$(mktemp "${TMP}/cache.XXXXXX")
	jq --arg slug "$slug" \
		--argjson private "$private_bool" \
		--argjson ca "$checked_at" \
		'.[$slug] = {private: $private, checked_at: $ca}' \
		"$PRIVACY_CACHE_FILE" >"$tmp" || {
		rm -f "$tmp"
		printf 'Error: failed to update cache file at %s\n' "$PRIVACY_CACHE_FILE" >&2
		return 1
	}
	mv "$tmp" "$PRIVACY_CACHE_FILE"
	return 0
}

# Reset cache so each test starts clean
printf '{}\n' >"$PRIVACY_CACHE_FILE"

# Test: cached public (SSH URL) → exit 0
_seed_cache "owner/public-ssh" false 0
if privacy_is_target_public "git@github.com:owner/public-ssh.git"; then
	pass "is_target_public: cached public (SSH URL) returns 0"
else
	fail "is_target_public: cached public (SSH URL) should return 0"
fi

# Test: cached public (HTTPS URL without .git) → exit 0
_seed_cache "owner/public-https" false 0
if privacy_is_target_public "https://github.com/owner/public-https"; then
	pass "is_target_public: cached public (HTTPS URL no .git) returns 0"
else
	fail "is_target_public: cached public (HTTPS URL no .git) should return 0"
fi

# Test: cached private → non-zero (exit 1)
_seed_cache "owner/private-repo" true 0
privacy_is_target_public "git@github.com:owner/private-repo.git"
rc=$?
if [[ "$rc" -eq 1 ]]; then
	pass "is_target_public: cached private returns exit 1"
else
	fail "is_target_public: cached private should return 1 (got $rc)"
fi

# Test: non-github URL → exit 2 (fail-open / unknown)
privacy_is_target_public "git@gitlab.com:owner/repo.git"
rc=$?
if [[ "$rc" -eq 2 ]]; then
	pass "is_target_public: non-github URL returns 2 (fail-open)"
else
	fail "is_target_public: non-github URL should return 2 (got $rc)"
fi

# Test: completely unparseable URL → exit 2
privacy_is_target_public "not-a-url"
rc=$?
if [[ "$rc" -eq 2 ]]; then
	pass "is_target_public: unparseable URL returns 2 (fail-open)"
else
	fail "is_target_public: unparseable URL should return 2 (got $rc)"
fi

# Test: stale cache entry (older than TTL) is NOT used — the function should
# fall through to a fresh probe. We can't stub gh, so we seed a stale private
# entry for a slug we KNOW is public (our own aidevops repo), set TTL=1, and
# verify the result matches the live state rather than the stale cache.
# If gh is unavailable, this test is skipped (fail-open returns 2, not a bug).
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
	_seed_cache "marcusquinn/aidevops" true 9999
	PRIVACY_CACHE_TTL=1 privacy_is_target_public "git@github.com:marcusquinn/aidevops.git"
	rc=$?
	# Live aidevops repo is public → fresh probe should return 0, overriding the stale private entry
	if [[ "$rc" -eq 0 ]]; then
		pass "is_target_public: stale cache entry is refreshed via fresh probe"
	else
		fail "is_target_public: stale cache should have been refreshed (got $rc)"
	fi
else
	pass "is_target_public: stale cache refresh test skipped (gh unavailable)"
fi

# Reset cache for hook-dispatch tests
printf '{}\n' >"$PRIVACY_CACHE_FILE"

# =============================================================================
# t1969: full-hook dispatch tests
# =============================================================================

HOOK="${SCRIPT_DIR}/../hooks/privacy-guard-pre-push.sh"

if [[ ! -x "$HOOK" ]]; then
	fail "hook dispatch: hook script not found at $HOOK"
else
	# Prepare a small git repo with a clean commit and a polluted commit
	HOOK_REPO="${TMP}/hook-test-repo"
	mkdir -p "$HOOK_REPO"
	(
		cd "$HOOK_REPO" || exit 1
		git init --quiet
		git config user.email 'test@example.com'
		git config user.name 'Test'
		git commit --allow-empty -m 'init' --quiet
		printf 'clean content no private slugs\n' >TODO.md
		git add TODO.md
		git commit -m 'clean' --quiet
		# Use a slug from our test repos.json (testorg/private-mirror —
		# registered with mirror_upstream in the test fixture above).
		# `printf --` ends option parsing so the leading "- [x]" doesn't
		# get interpreted as a printf flag.
		printf -- '- [x] rNNN testorg/private-mirror leak test\n' >TODO.md
		git add TODO.md
		git commit -m 'leak' --quiet
	) || fail "hook dispatch: could not seed hook-test repo"

	CLEAN_HEAD=$(git -C "$HOOK_REPO" rev-parse HEAD~1)
	LEAK_HEAD=$(git -C "$HOOK_REPO" rev-parse HEAD)
	INIT_HEAD=$(git -C "$HOOK_REPO" rev-parse HEAD~2)

	# Helper: run the hook in the hook-test repo with given args and ref list
	_run_hook() {
		local remote_name="$1"
		local remote_url="$2"
		local ref_line="$3"
		pushd "$HOOK_REPO" >/dev/null || return 99
		PRIVACY_REPOS_CONFIG="$PRIVACY_REPOS_CONFIG" \
			PRIVACY_CACHE_FILE="$PRIVACY_CACHE_FILE" \
			printf '%s\n' "$ref_line" |
			bash "$HOOK" "$remote_name" "$remote_url" >/dev/null 2>&1
		local rc=$?
		popd >/dev/null || return 99
		return "$rc"
	}

	# Test: public target + clean diff → exit 0
	_seed_cache "test/public" false 0
	_run_hook "origin" "git@github.com:test/public.git" \
		"refs/heads/main ${CLEAN_HEAD} refs/heads/main ${INIT_HEAD}"
	rc=$?
	if [[ "$rc" -eq 0 ]]; then
		pass "hook dispatch: public target + clean diff → exit 0"
	else
		fail "hook dispatch: public target + clean diff should exit 0 (got $rc)"
	fi

	# Test: public target + leak diff → exit 1 (BLOCKED)
	_seed_cache "test/public" false 0
	_run_hook "origin" "git@github.com:test/public.git" \
		"refs/heads/main ${LEAK_HEAD} refs/heads/main ${CLEAN_HEAD}"
	rc=$?
	if [[ "$rc" -eq 1 ]]; then
		pass "hook dispatch: public target + leak diff → exit 1 (blocked)"
	else
		fail "hook dispatch: public target + leak diff should exit 1 (got $rc)"
	fi

	# Test: private target + leak diff → exit 0 (fast path, no scan)
	_seed_cache "test/private" true 0
	_run_hook "origin" "git@github.com:test/private.git" \
		"refs/heads/main ${LEAK_HEAD} refs/heads/main ${CLEAN_HEAD}"
	rc=$?
	if [[ "$rc" -eq 0 ]]; then
		pass "hook dispatch: private target + leak diff → exit 0 (fast path)"
	else
		fail "hook dispatch: private target should exit 0 without scanning (got $rc)"
	fi

	# Test: PRIVACY_GUARD_DISABLE=1 bypass → exit 0 regardless of leak
	# NOTE: env vars must be applied to `bash "$HOOK"` (right side of pipe),
	# NOT to `printf` (left side). A pipeline's processes inherit separately.
	_seed_cache "test/public" false 0
	pushd "$HOOK_REPO" >/dev/null || exit 1
	printf 'refs/heads/main %s refs/heads/main %s\n' "$LEAK_HEAD" "$CLEAN_HEAD" |
		PRIVACY_GUARD_DISABLE=1 \
			PRIVACY_REPOS_CONFIG="$PRIVACY_REPOS_CONFIG" \
			PRIVACY_CACHE_FILE="$PRIVACY_CACHE_FILE" \
			bash "$HOOK" origin "git@github.com:test/public.git" >/dev/null 2>&1
	rc=$?
	popd >/dev/null || exit 1
	if [[ "$rc" -eq 0 ]]; then
		pass "hook dispatch: PRIVACY_GUARD_DISABLE=1 bypasses scan → exit 0"
	else
		fail "hook dispatch: PRIVACY_GUARD_DISABLE=1 should bypass scan (got $rc)"
	fi

	# Test: branch deletion (local SHA all zeros) → exit 0, no scan
	_seed_cache "test/public" false 0
	_run_hook "origin" "git@github.com:test/public.git" \
		"refs/heads/main 0000000000000000000000000000000000000000 refs/heads/main ${CLEAN_HEAD}"
	rc=$?
	if [[ "$rc" -eq 0 ]]; then
		pass "hook dispatch: branch deletion (zeros local SHA) → exit 0"
	else
		fail "hook dispatch: branch deletion should exit 0 without scanning (got $rc)"
	fi
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
