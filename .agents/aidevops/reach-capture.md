<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Reach and Capture

Use this registry when an agent needs to choose the lowest-agency way to reach,
capture, stage, or mine web content. Route and doctor commands are advisory:
they report available local primitives and emit a route decision without
contacting arbitrary targets. Profile and cookie broker commands mutate only
private reach metadata under the aidevops agent workspace.

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
  "failure_policy": "sanitized retry and stop policy",
  "failover_order": ["fetch", "crawler", "browser"],
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

`route --auth cookie|profile` consults the private broker metadata before it
sets `cookie_policy` or `profile_policy`. Missing or expired broker state keeps
the policy at `required`; an unexpired cookie registration or profile lease
allows `reuse_approved_session` or `use_existing_approved_profile`.

## Profile and Cookie Broker

`reach-helper.sh profile lease|release|status --format json` and
`reach-helper.sh cookie status|register|clear --format json` manage private
lease metadata only. The broker does not import cookies, launch browsers, or
touch the underlying profile directory.

Private state is stored under:

```text
~/.aidevops/.agent-workspace/reach/
├── leases/           # profile lease metadata, mode 600 JSON files
└── cookie-sessions/  # cookie source metadata, mode 600 JSON files
```

Profile lease files contain these fields: `schema_version`, `target_key`,
`profile_name`, `profile_type`, `auth_mode`, `cookie_source`, `owner`,
`created_at`, `expires_at`, `sensitivity`, and sanitized `notes`. Cookie session
metadata stores the private source path locally plus a safe label/hash for
output. `profile lease` refuses to overwrite an unexpired lease unless `--force`
is present, so parallel workers do not silently reuse or mutate the same approved
session state.

Safe logging rules:

- Command output may include target hashes, profile names, profile types, safe
  labels, expiry timestamps, and boolean status fields.
- Command output must not include cookie values, bearer tokens, proxy
  credentials, private paths, raw private target strings, or browser profile
  state paths.
- Cookie source paths may exist only inside private metadata files in the reach
  workspace; issue, PR, and transcript output uses the safe label/hash instead.

## Health Doctors

`reach-helper.sh network doctor --format json` reports sanitized proxy/VPN
readiness. It may expose provider class, check keys, boolean availability, and
generic status values. It must not print IP addresses, proxy credentials,
session IDs, cookies, private target strings, or local private paths.

`reach-helper.sh fingerprint doctor --format json` reports sanitized browser and
fingerprint/profile readiness. Profile types follow the anti-detect browser
decision tree: persistent, clean, warm, or disposable. Doctor output is local
readiness only and does not contact arbitrary targets.

## Failure Classes and Failover

`reach-helper.sh classify-failure --format json` emits:

- `failure_class`: one of `success`, `network_timeout`, `proxy_unhealthy`,
  `rate_limited`, `captcha_required`, `bot_block`, `auth_required`,
  `scope_forbidden`, `selector_drift`, `content_empty`, or `unknown`.
- `temporary`: whether backoff or a route change may plausibly succeed.
- `retry_after_seconds`: conservative minimum wait before retrying.
- `next_action`: sanitized action guidance.
- `safe_to_failover`: whether an authorized alternate route may be used.
- `requires_authorization`: whether new approval/session/scope is required.
- `notes`: sanitized operational constraints.

Failover is safe only for temporary classes such as `network_timeout`,
`proxy_unhealthy`, `rate_limited`, `captcha_required`, `bot_block`, and
`content_empty`, and only within the existing authorization boundary. Do not
retry the same blocked identity after `bot_block`; switch only to a healthy,
authorized profile/proxy or stop. `selector_drift` requires extraction repair,
not identity failover. `auth_required` and `scope_forbidden` are hard stops:
never recommend proxy, VPN, fingerprint, cookie, or profile failover without new
authorization for that scope.

## Safety Boundaries

- Do not contact arbitrary targets during `doctor` or `capabilities` checks.
- Do not print credentials, cookie values, proxy auth, local private paths, or
  raw private target strings in route output.
- Do not use proxy, VPN, fingerprint, profile, or cookie changes to bypass
  authentication, authorization, robots, rate-limit, or terms boundaries.
- Treat proxy, inbox, knowledge, performance, and feedback mutation as follow-up
  work with separate task briefs and verification. Profile and cookie broker
  mutation is limited to private metadata leases and registrations.
