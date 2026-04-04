<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Attribution Monitoring

> t1883 — GitHub Code Search + canary dashboard for detecting framework copies

## Overview

The aidevops framework is MIT-licensed. Copying is legal, but attribution is expected. This system detects when distinctive framework patterns appear in public GitHub repositories, enabling:

- Adoption visibility (how widely is the framework being used?)
- Fork discovery (are there derivatives that could benefit from upstream contributions?)
- Attribution awareness (who is using the framework without credit?)

**Tool:** `attribution-detection-helper.sh` — see `scripts/attribution-detection-helper.sh`

## Quick Start

```bash
# List registered canary patterns
attribution-detection-helper.sh canary list

# Run a scan (dry-run first to verify)
attribution-detection-helper.sh scan --dry-run
attribution-detection-helper.sh scan

# View results
attribution-detection-helper.sh dashboard

# Schedule weekly scans
attribution-detection-helper.sh install
```

## Canary Token Strategy

Canary tokens are distinctive strings embedded in framework files that are unlikely to appear in unrelated code. When these strings appear in other public repos, it indicates the framework (or a copy of it) is present.

### Default canaries

| Name | Pattern | Source |
|------|---------|--------|
| `spdx-header` | `SPDX-FileCopyrightText: 2025-2026 Marcus Quinn` | All framework files |
| `aidevops-sh-domain` | `aidevops.sh` | Signature footers, docs |
| `shared-constants-guard` | `_SHARED_CONSTANTS_LOADED` | `shared-constants.sh` |
| `pulse-wrapper-label` | `sh.aidevops.pulse` | `pulse-wrapper.sh` |
| `full-loop-helper-state` | `FULL_LOOP_COMPLETE` | `full-loop-helper.sh` |

### Adding custom canaries

```bash
# Add a canary for a distinctive function name
attribution-detection-helper.sh canary add my-func "my_unique_function_name" "Custom function"

# Add a canary for a unique comment string
attribution-detection-helper.sh canary add my-comment "# aidevops: my-unique-comment" "Custom comment"
```

### Canary design principles

1. **Distinctive** — unlikely to appear in unrelated code
2. **Stable** — won't change frequently (avoid version numbers)
3. **Searchable** — short enough for GitHub code search (< 256 chars)
4. **Non-sensitive** — safe to search for publicly

## Private Detection Repo

For more comprehensive monitoring (including Cloudflare KV canary pings and
a full attribution manifest), set up a private detection repo. The private
repo stores detection methodology that should not be public.

```bash
# Get setup instructions
attribution-detection-helper.sh setup-private-repo
```

### Why private?

- Custom canary patterns reveal what you consider distinctive
- Detection results may contain sensitive repo names
- Methodology exposure lets bad actors avoid detection

## Interpreting Results

### Attribution status

| Status | Meaning | Action |
|--------|---------|--------|
| `attributed` | Repo is in the known/expected list | None required |
| `unattributed` | Repo not in known list | Review and decide |

### When you find an unattributed detection

1. **Check the repo** — is it a legitimate fork/derivative? A tutorial? A copy?
2. **Assess intent** — accidental omission vs deliberate copying
3. **Decide action:**
   - **Fork/derivative**: Open a friendly issue suggesting attribution
   - **Tutorial/example**: Usually fine, consider reaching out positively
   - **Commercial copy**: May warrant a DMCA notice (consult legal advice)
   - **False positive**: Add to `attributed_repos` in the canary config

### Adding a repo to the attributed list

```bash
# Edit the canaries file directly
jq '(.[] | select(.name == "spdx-header") | .attributed_repos) += ["owner/repo"]' \
  ~/.aidevops/cache/attribution-canaries.json > /tmp/canaries.json
mv /tmp/canaries.json ~/.aidevops/cache/attribution-canaries.json
```

## GitHub Code Search Limits

| Tier | Rate limit | Notes |
|------|-----------|-------|
| Authenticated | 30 req/min | Requires `gh auth login` |
| Unauthenticated | 10 req/min | Not recommended |

The script sleeps 3 seconds between requests (20 req/min) to stay within limits.

GitHub code search only indexes **public** repositories. Private repos are not searchable.

## Scheduling

Weekly scans are recommended. The script installs a launchd job (macOS) or cron job (Linux):

```bash
attribution-detection-helper.sh install    # Install weekly Monday 03:00
attribution-detection-helper.sh uninstall  # Remove
```

## State Files

All state is stored locally in `~/.aidevops/cache/` — not committed to the public repo.

| File | Purpose |
|------|---------|
| `~/.aidevops/cache/attribution-canaries.json` | Registered canary patterns |
| `~/.aidevops/cache/attribution-detections.json` | Latest scan results |
| `~/.aidevops/logs/attribution-detection.log` | Operation log |

## Privacy Considerations

- **Search queries are visible to GitHub** — avoid canaries that reveal sensitive internal details
- **Results may contain private repo names** — store in private detection repo, not public commits
- **Rate limit headers** — GitHub can see your search patterns; this is normal and expected
- **False positives** — common strings will match many repos; tune canaries to be distinctive

## Related

- `scripts/attribution-detection-helper.sh` — main tool
- `scripts/contribution-watch-helper.sh` — monitor external contributions
- `scripts/cch-canary.sh` — Claude CLI signing canary
- `reference/contribution-watch.md` — contribution monitoring guide
