<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2233: push retry loop in `version-manager.sh release`

**Session origin:** interactive (maintainer, Marcus Quinn)
**GitHub:** GH#19737
**Parent:** t2228 / GH#19734
**Tier:** tier:simple (pattern exists, mechanical copy)

## What

Wrap `version-manager.sh`'s `push_changes` in a CAS-style retry loop so concurrent commits to `main` during a release don't fail the push step. On non-fast-forward, fetch → rebase → recreate tag → retry, up to 10 attempts with exponential backoff.

## Why

During v3.8.71 release (2026-04-18), `git push --atomic origin main --tags` failed with non-fast-forward because the pulse landed `chore: claim t2223` between my fetch and push. Single-shot push + no retry → required manual `git fetch && git rebase origin/main && git tag -d v3.8.71 && git tag -a v3.8.71 && git push --atomic` recovery. Pulse and interactive sessions commit to main frequently (`chore: claim tNNN`, `chore: update simplification state registry`); this race is common.

`claim-task-id.sh` already has exactly this retry pattern (CAS loop). Copy it.

## How

### Files to modify

- EDIT: `.agents/scripts/version-manager.sh` — function `push_changes` (around line 1319)

### Current code (single-shot)

```bash
push_changes() {
    cd "$REPO_ROOT" || exit 1
    print_info "Pushing changes to remote..."
    if git push --atomic origin main --tags; then
        print_success "Pushed changes and tags to remote"
        return 0
    else
        print_error "Failed to push to remote"
        return 1
    fi
}
```

### Replacement (retry loop)

```bash
push_changes() {
    local version="$1"  # version string, e.g. "3.8.71"
    local tag_name="v$version"
    cd "$REPO_ROOT" || exit 1

    local attempt=0 max_attempts=10 delay=2
    while [[ $attempt -lt $max_attempts ]]; do
        attempt=$((attempt + 1))
        print_info "Pushing changes to remote (attempt $attempt/$max_attempts)..."

        if git push --atomic origin main --tags 2>/dev/null; then
            print_success "Pushed changes and tags to remote"
            return 0
        fi

        # Non-fast-forward: rebase and retry
        print_info "Push failed (conflict). Fetching and rebasing..."
        if ! git fetch origin main --quiet; then
            print_error "Fetch failed, cannot retry"
            return 1
        fi

        if ! git rebase origin/main; then
            print_error "Rebase conflict, manual intervention needed"
            git rebase --abort 2>/dev/null || true
            return 1
        fi

        # Tag must be recreated on the new HEAD
        if git show-ref --tags "$tag_name" &>/dev/null; then
            print_info "Recreating tag $tag_name on rebased HEAD..."
            git tag -d "$tag_name"
            git tag -a "$tag_name" -m "$tag_name"
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            sleep "$delay"
            delay=$((delay * 2))
            [[ $delay -gt 60 ]] && delay=60
        fi
    done

    print_error "Failed to push after $max_attempts attempts. Manual recovery needed."
    print_info "Current SHA: $(git rev-parse HEAD), remote SHA: $(git rev-parse origin/main)"
    return 1
}
```

Caller (`perform_release` or equivalent) already passes the version string to `create_git_tag`; update the `push_changes` call to pass the same version.

### Reference implementation to model

`.agents/scripts/claim-task-id.sh` — search for `_cas_claim` or the retry loop structure around counter allocation. Same pattern: fetch → rebase-equivalent → retry → exponential backoff with cap.

## Acceptance criteria

- [ ] `push_changes` retries up to 10 times on non-fast-forward
- [ ] Each retry fetches and rebases onto `origin/main`
- [ ] Tag is deleted and recreated on the rebased HEAD
- [ ] Exponential backoff capped at 60s
- [ ] Exhaustion error includes local and remote SHAs for diagnosis
- [ ] Rebase conflict is surfaced (not silently retried)

## Verification

```bash
# Simulate: open two terminals
# Terminal 1: touch some file in canonical, commit, run version-manager.sh release patch
# Terminal 2: (while Terminal 1 is running) touch a different file, commit, push to main
# Expected: Terminal 1's push_changes detects conflict, rebases, retries successfully.
```

Unit test (optional): add to `.agents/scripts/tests/` a bash test that mocks `git push` to fail once then succeed, verifies the retry path.

## Context

- Session: 2026-04-18, release v3.8.71.
- `claim-task-id.sh` has solved the identical pattern (concurrent git-based CAS). Reusing its structure means proven correctness and bounded review burden.
- Auto-dispatchable — mechanical copy from a reference implementation, clear file + function boundary.

## Tier rationale

`tier:simple` — one function, one file, verbatim reference pattern. Single acceptance test available. Auto-dispatch.
