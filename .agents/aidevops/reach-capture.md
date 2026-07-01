<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Reach and Capture

Use this registry when an agent needs to choose the lowest-agency way to reach,
capture, stage, or mine web content. The first implementation is intentionally
advisory: it reports available local primitives and emits a route decision; it
does not mutate browser profiles, cookies, proxies, inboxes, knowledge stores,
performance logs, or feedback artifacts.

## Capability Registry

| Capability | Backend key | Agency | Use first when | Local readiness signal | Artifact plane |
|------------|-------------|--------|----------------|------------------------|----------------|
| Fetch/static parse | `fetch` | 1 | Public/static pages, obvious JSON, no login | `curl` or `python3` present | caller-selected |
| Crawl4AI/WaterCrawl crawler | `crawler` | 2 | Many public pages, sitemaps, docs, structured extraction | `crawl4ai-helper.sh`, `watercrawl-helper.sh`, or `site-crawler-helper.sh` | caller-selected |
| Deterministic browser | `browser` | 3 | Known UI flow, forms, downloads, repeatable selectors | `agent-browser-helper.sh`, `browser-qa-helper.sh`, or Playwright tooling | traces/screenshots/downloads |
| Persistent profile | `persistent_profile` | 4 | Recurring logged-in workflows with approved stored state | `dev-browser-helper.sh` or browser profile storage | `browser-profiles` workspace |
| Cookie-session reuse | `cookie_session` | 4 | Authenticated API calls from an existing approved session | `sweet-cookie` tooling or `anti-detect-helper.sh` cookies support | storage state/cookie export |
| Anti-detect profile | `anti_detect_profile` | 6 | Authorized profile or fingerprint isolation need | `anti-detect-helper.sh` | profile workspace |
| Proxy/VPN | `proxy_vpn` | 6 | Authorized geo, isolation, or reputation separation need | `anti-detect-helper.sh proxy` support or VPN/proxy helper | proxy metadata |
| `_inbox` capture | `inbox_capture` | storage | Human-visible capture, triage, or later processing | `inbox-helper.sh` | `_inbox` |
| `_knowledge` staging | `knowledge_staging` | storage | Durable reusable knowledge or indexed research | `knowledge-helper.sh` | `_knowledge` |
| `_performance` logging | `performance_logging` | telemetry | Repeatable workflow measurement | `performance`/metrics helpers when present | `_performance` |
| `_feedback` mining | `feedback_mining` | telemetry | Mine prior failures, reviews, comments, or outcomes | feedback/quality helpers when present | `_feedback` |

## Route Decision Schema

`reach-helper.sh route --format json` returns one JSON object with this shape:

```json
{
  "backend": "fetch|crawler|browser|persistent_profile|cookie_session|anti_detect_profile|manual_review",
  "agency_level": 1,
  "mode": "static|crawl|deterministic_browser|profile|cookie_session|authorized_stealth|manual",
  "headed": false,
  "profile_policy": "none|avoid|use_existing_approved_profile|required|blocked",
  "cookie_policy": "none|avoid|reuse_approved_session|required|blocked",
  "proxy_policy": "none|avoid|authorized_only|required|blocked",
  "offload": "local|worker|manual",
  "capture_destination": "caller_selected|_inbox|_knowledge|_performance|_feedback",
  "safety_notes": ["sanitized notes only"],
  "expected_artifacts": ["sanitized artifact kinds only"],
  "blocked_reason": ""
}
```

Routing follows `.agents/workflows/auto-browse.md`: fetch/static parse first,
then crawler, deterministic browser, persistent profile or cookie reuse for
approved authenticated work, and anti-detect/proxy only for explicit authorized
isolation needs. Private/manual authentication without an approved reusable
session returns `manual_review` with `blocked_reason` set instead of attempting
capture.

## Safety Boundaries

- Do not contact arbitrary targets during `doctor` or `capabilities` checks.
- Do not print credentials, cookie values, proxy auth, local private paths, or
  raw private target strings in route output.
- Treat profile, cookie, proxy, inbox, knowledge, performance, and feedback
  mutation as follow-up work with separate task briefs and verification.
