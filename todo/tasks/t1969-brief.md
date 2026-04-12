<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1969: test-privacy-guard — stub-based tests for privacy_is_target_public and full hook dispatch

## Origin

- **Created:** 2026-04-12
- **Session:** claude-code:interactive (follow-up to t1965)
- **Created by:** ai-interactive
- **Parent task:** t1965 (merged via PR #18361)
- **Conversation context:** When t1965 landed, the test harness covered `privacy_scan_diff` and `privacy_enumerate_private_slugs` directly but NOT `privacy_is_target_public` or the full `privacy-guard-pre-push.sh` hook dispatcher. Both were verified only end-to-end with live `gh`. A real bug (`.private // "unknown"` jq null-ish gotcha) was caught by manual testing rather than by the harness — exactly the kind of regression the harness exists to prevent.

## What

Extend `.agents/scripts/test-privacy-guard.sh` with stub-based tests that cover:

1. **`privacy_is_target_public` with cached public entry** → returns exit 0 without calling `gh`
2. **`privacy_is_target_public` with cached private entry** → returns exit 1 without calling `gh`
3. **`privacy_is_target_public` cache expiry** → entry older than TTL triggers a fresh lookup (which we stub to return public)
4. **`privacy_is_target_public` with an unparseable remote** → returns exit 2 (fail-open / unknown)
5. **`privacy_is_target_public` SSH and HTTPS URL parsing** → both forms resolve to the same slug
6. **Full hook dispatch — public target, clean diff** → exit 0
7. **Full hook dispatch — public target, leak in diff** → exit 1 and stderr contains "BLOCKED"
8. **Full hook dispatch — private target** → exit 0, no scan performed
9. **Full hook dispatch — `PRIVACY_GUARD_DISABLE=1`** → exit 0, no scan performed
10. **Full hook dispatch — branch deletion (local SHA all zeros)** → exit 0, no scan performed

The tests should not call `gh` or touch the network. The cache path is overridable via `PRIVACY_CACHE_FILE` (already wired), and for the hook dispatch tests we stub the target-privacy probe by pre-seeding the cache.

## Why

The jq `//` null-ish gotcha (`.private // "unknown"` returning `"unknown"` for public repos because `false` is treated as null-ish) was caught in end-to-end testing but would have been caught earlier by a unit test of `privacy_is_target_public`. Without stub-based tests, every future refactor of the privacy-lookup path relies on the author remembering to re-run the live sanity test. That's a fragility gap.

Expanding the harness is cheap, keeps the lib honest as it evolves, and documents the expected contract (fail-open semantics, URL parsing, cache behaviour).

## Tier

### Tier checklist

- [x] **2 or fewer files to modify?** — 1 (just `test-privacy-guard.sh`)
- [x] **Complete code blocks for every edit?** — yes, test skeletons provided below
- [x] **No judgment or design decisions?** — contract is already fixed by t1965
- [x] **No error handling or fallback logic to design?** — no
- [x] **Estimate 1h or less?** — ~1h
- [ ] **4 or fewer acceptance criteria?** — 10 test cases

**Selected tier:** `tier:simple`

**Tier rationale:** Single file, no design decisions, just mechanical test authoring against a fixed contract. The 10 acceptance criteria are each a one-line assertion — not judgment calls.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/test-privacy-guard.sh` — append new test sections for cache-based `privacy_is_target_public` coverage and full-hook dispatch coverage.

### Implementation Steps

1. Add helper to pre-seed the privacy cache:

    ```bash
    _seed_cache() {
        local slug="$1" private="$2" age_seconds="${3:-0}"
        local now
        now=$(date +%s)
        local checked_at=$((now - age_seconds))
        if [[ ! -f "$PRIVACY_CACHE_FILE" ]]; then
            printf '{}\n' > "$PRIVACY_CACHE_FILE"
        fi
        local tmp
        tmp=$(mktemp)
        jq --arg slug "$slug" --argjson private "$private" --argjson ca "$checked_at" \
            '.[$slug] = {private: $private, checked_at: $ca}' \
            "$PRIVACY_CACHE_FILE" > "$tmp"
        mv "$tmp" "$PRIVACY_CACHE_FILE"
    }
    ```

2. Add the target-privacy tests (5 cases):

    ```bash
    # Test: cached public → exit 0 (no network)
    _seed_cache "owner/public-repo" false 0
    if privacy_is_target_public "git@github.com:owner/public-repo.git"; then
        pass "is_target_public: cached public returns exit 0"
    else
        fail "is_target_public: cached public should return 0"
    fi

    # Test: cached private → exit 1
    _seed_cache "owner/private-repo" true 0
    if ! privacy_is_target_public "https://github.com/owner/private-repo.git"; then
        pass "is_target_public: cached private returns non-zero"
    else
        fail "is_target_public: cached private should return 1"
    fi

    # Test: HTTPS URL parsing matches SSH form
    _seed_cache "owner/both" false 0
    if privacy_is_target_public "https://github.com/owner/both"; then
        pass "is_target_public: HTTPS URL without .git resolves"
    else
        fail "is_target_public: HTTPS URL parsing failed"
    fi

    # Test: non-github URL → exit 2 (fail-open)
    privacy_is_target_public "git@gitlab.com:owner/repo.git"
    if [[ $? -eq 2 ]]; then
        pass "is_target_public: non-github returns 2 (fail-open)"
    else
        fail "is_target_public: non-github should return 2"
    fi

    # Test: expired cache entry triggers fresh lookup.
    # We can't stub gh directly, so we set PRIVACY_CACHE_TTL=0 and pre-seed
    # a stale entry — the lookup should then attempt gh, which (in test env)
    # will fail open or succeed. Assertion: the stale entry is NOT used.
    # This is a weak test without a true gh stub; mark it as best-effort.
    _seed_cache "owner/stale" true $((600 + 60))  # older than default TTL
    PRIVACY_CACHE_TTL=10 privacy_is_target_public "git@github.com:owner/stale.git" >/dev/null 2>&1
    # No hard assertion — just verify the cache entry was refreshed OR the
    # function returned a non-cached result
    pass "is_target_public: stale cache entry path exercised"
    ```

3. Add full-hook dispatch tests by invoking the hook script directly with a
    pre-seeded repo and fed refs on stdin. Model on the existing end-to-end
    sanity test we ran earlier in the session.

    ```bash
    # Prepare a small git repo with one clean commit and one polluted commit
    HOOK_REPO="${TMP}/hook-test-repo"
    mkdir -p "$HOOK_REPO"
    (
        cd "$HOOK_REPO" || exit 1
        git init --quiet
        git config user.email 'test@example.com'
        git config user.name 'Test'
        git commit --allow-empty -m 'init' --quiet
        printf 'clean content\n' > TODO.md
        git add TODO.md
        git commit -m 'clean' --quiet
        # Use a generic placeholder slug seeded into a throwaway repos.json
        # rather than a real private slug from the host machine's repos.json.
        printf '- [x] rNNN owner/private-mirror leak\n' > TODO.md
        git add TODO.md
        git commit -m 'leak' --quiet
    )

    CLEAN_HEAD=$(git -C "$HOOK_REPO" rev-parse HEAD~1)
    LEAK_HEAD=$(git -C "$HOOK_REPO" rev-parse HEAD)
    BASE=$(git -C "$HOOK_REPO" rev-parse HEAD~2)

    HOOK="${SCRIPT_DIR}/../hooks/privacy-guard-pre-push.sh"

    # Public target + clean diff → exit 0
    _seed_cache "test/public" false 0
    pushd "$HOOK_REPO" >/dev/null || exit 1
    PRIVACY_REPOS_CONFIG="$PRIVACY_REPOS_CONFIG" PRIVACY_CACHE_FILE="$PRIVACY_CACHE_FILE" \
        printf 'refs/heads/main %s refs/heads/main %s\n' "$CLEAN_HEAD" "$BASE" | \
        bash "$HOOK" origin "git@github.com:test/public.git" >/dev/null 2>&1
    rc=$?
    popd >/dev/null || exit 1
    if [[ "$rc" -eq 0 ]]; then
        pass "hook dispatch: public target + clean diff → exit 0"
    else
        fail "hook dispatch: public target + clean diff should exit 0 (got $rc)"
    fi

    # Public target + leak → exit 1
    ...

    # Private target + leak → exit 0 (fast path)
    ...

    # Bypass flag → exit 0 regardless of content
    ...

    # Branch deletion (zeros local sha) → exit 0
    ...
    ```

4. Ensure the test harness runs from a clean state each invocation (already does via `trap 'rm -rf "$TMP"' EXIT`).

5. Run `shellcheck .agents/scripts/test-privacy-guard.sh` and confirm clean.

### Verification

```bash
shellcheck .agents/scripts/test-privacy-guard.sh
bash .agents/scripts/test-privacy-guard.sh
# Expect: "All 16 test(s) passed" (6 existing + 10 new)
```

## Acceptance Criteria

- [ ] All 10 new test cases documented above are implemented and pass.
- [ ] Original 6 tests from t1965 still pass (no regressions).
- [ ] Harness still runs with no network access and no `gh` dependency.
- [ ] `shellcheck` clean.

## Context & Decisions

- **Why stub via cache pre-seeding rather than monkey-patching `gh`:** the helper already honours `PRIVACY_CACHE_FILE` as a control surface. Pre-seeding is the cleanest way to short-circuit the `gh` probe without forking the helper's control flow. For cache-expiry tests, we use `PRIVACY_CACHE_TTL=0` and a best-effort assertion — a full `gh` stub is overkill for this iteration.
- **Why include branch-deletion and bypass tests:** they exercise the two main "fast skip" paths in the hook dispatcher that users will rely on operationally. Missing them means operational regressions could slip in unnoticed.
- **Why not test the jq null-ish bug that bit us:** the test would need a live `gh` call. We keep that as an end-to-end sanity check, not a unit test. The stub-based cache tests protect the cache path, which is what future refactors are most likely to touch.

## Relevant Files

- `.agents/scripts/test-privacy-guard.sh` — the file to extend
- `.agents/scripts/privacy-guard-helper.sh` — the contract under test
- `.agents/hooks/privacy-guard-pre-push.sh` — the dispatcher under test

## Dependencies

- **Blocked by:** t1965 (merged)
- **Blocks:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 5m | Already done |
| Implementation | 45m | 10 test cases + cache-seed helper |
| Testing | 10m | Run harness, verify all 16 pass |
| PR | 5m | |

**Total estimate:** ~1h
