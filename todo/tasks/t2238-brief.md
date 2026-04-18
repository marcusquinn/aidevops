<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2238: add curl retry-with-backoff to validate-version-consistency.sh

**Session origin:** interactive (maintainer, Marcus Quinn)
**GitHub:** GH#19753
**Parent:** t2228 / GH#19734
**Tier:** tier:simple (~15 lines of shell, mechanical retry pattern)

## What

Wrap `curl` calls in `.agents/scripts/validate-version-consistency.sh` in a retry-with-backoff helper — 3 attempts, 5s → 10s → 20s. Prevents a single transient HTTP 5xx from failing the Version Validation CI check.

## Why

During PR #19715 CI on 2026-04-18, the Version Consistency Check failed with:

```text
curl: (22) The requested URL returned error: 504
❌ Version Validation: FAILED
Version inconsistencies detected. Please fix before merging.
```

A single transient HTTP 504 caused the whole check to fail. `gh run rerun --failed` fixed it, but not before blocking merge until noticed. Transient 5xx on GitHub API / hub.docker.com is uncommon but not rare — any infra hiccup downstream of the script produces a false-fail that needs human intervention.

## How

### Files to modify

- EDIT: `.agents/scripts/validate-version-consistency.sh` — wrap external HTTP calls in a `fetch_with_retry` helper

### Helper to add (at top of script, after other helpers)

```bash
# fetch_with_retry <url>
# Retries up to 3 times with exponential backoff (5s, 10s, 20s).
# Prints response body on success; logs attempts on failure.
fetch_with_retry() {
    local url="$1"
    local attempt=0
    local max_attempts=3
    local delay=5
    local response=""

    while [[ $attempt -lt $max_attempts ]]; do
        if response=$(curl -fsSL --max-time 30 "$url" 2>&1); then
            printf '%s' "$response"
            return 0
        fi
        attempt=$((attempt + 1))
        if [[ $attempt -lt $max_attempts ]]; then
            print_warning "curl attempt $attempt/$max_attempts failed for $url — retrying in ${delay}s"
            sleep "$delay"
            delay=$((delay * 2))
        fi
    done

    print_error "Failed to fetch $url after $max_attempts attempts"
    return 1
}
```

### Call site changes

Find every `curl ...` invocation in the script (likely 1-3 sites). Replace with `fetch_with_retry <url>` and handle the return value. Example:

```bash
# Before
response=$(curl -fsSL "$url")

# After
response=$(fetch_with_retry "$url") || return 1
```

## Acceptance criteria

- [ ] `fetch_with_retry` helper defined in `validate-version-consistency.sh`
- [ ] All external `curl` calls in the script routed through the helper
- [ ] Success path unchanged (first-attempt success returns immediately)
- [ ] Failure path logs each attempt and returns 1
- [ ] No regression: script still passes on every normal run
- [ ] Retries capped at 3 (fails fast if endpoint is persistently down)

## Verification

```bash
# Happy path
./.agents/scripts/validate-version-consistency.sh

# Simulate failure (temporarily): point one URL at an invalid host
# sed -i '' 's|https://api.github.com|https://nonexistent.invalid|' validate-version-consistency.sh
# ./validate-version-consistency.sh  # should print 3 retry attempts then fail
# git checkout validate-version-consistency.sh  # revert
```

## Context

- Session: 2026-04-18, PR #19715 CI.
- Failure signature: `curl: (22) The requested URL returned error: 504` in GH Actions log for "Version Validation" workflow.
- Run ID that hit this: 24610114608 (run view log inspected).
- Auto-dispatchable — verbatim helper function + search-and-replace call sites, single file.

## Tier rationale

`tier:simple` — ~15-line helper function + small call-site edits in one file. Auto-dispatch.
