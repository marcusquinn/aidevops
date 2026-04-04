<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Bot Management Gotchas

## False Positives

1. Check Bot Analytics for affected IPs and paths.
2. Identify detection source (ML, heuristics, etc.).
3. Add exception rule for isolated issues:

```txt
(cf.bot_management.score lt 30 and http.request.uri.path eq "/problematic-path")
Action: Skip (Bot Management)
```

4. Allowlist by IP, ASN, or country if necessary.

## False Negatives

1. Increase enforcement threshold (e.g., 30 → 50).
2. Enable JavaScript Detections (JSD).
3. Add JA3/JA4 fingerprinting rules.
4. Use rate limiting as fallback.

## Bot Score = 0

- Indicates Bot Management did not execute (not a score of 100).
- Causes: internal Cloudflare requests, Worker-routed Orange-to-Orange traffic, or request completion before execution.
- Fix: Trace request path; ensure Bot Management runs in the lifecycle.

## JavaScript Detections (JSD) Not Working

If `js_detection.passed` is `false` or `undefined`:

- **CSP:** Ensure `/cdn-cgi/challenge-platform/` is allowed.
- **First Visit:** JSD requires an initial HTML page visit.
- **Client:** Check for disabled JS or ad blockers.
- **Dashboard:** Verify JSD is enabled.
- **Action:** Rule must be `Managed Challenge` (not `Block`).

**CSP fix:**

```txt
Content-Security-Policy: script-src 'self' /cdn-cgi/challenge-platform/;
```

## Verified Bot Blocked

- Usually WAF Managed Rules, not Bot Management.
- Yandex bot verification may fail for 48h during Cloudflare IP updates.
- Fix: Create WAF exception for the rule ID; verify bot via reverse DNS.

## JA3/JA4 Missing

- Requires HTTPS/TLS traffic.
- Missing on Worker-routed or Orange-to-Orange traffic.
- Only exists if Bot Management executed.

## Detection Limits

### Bot score

- `0` = not computed.
- Initial requests may lack JSD data.
- Scores are probabilistic; false positives/negatives occur.

### JavaScript Detections

- Fails on first HTML page visit.
- Requires JS-enabled browser.
- Strips ETags from HTML.
- Breaks with restrictive CSP (no `<meta>` CSP support).
- No WebSocket or native mobile app support.

### JA3/JA4 fingerprints

- HTTPS/TLS only.
- Missing on Worker-routed traffic.
- Not unique per user; fingerprints can change on browser/library updates.

## Plan Restrictions

| Feature | Free | Pro/Business | Enterprise |
|---------|------|--------------|------------|
| Granular scores (1-99) | No | No | Yes |
| JA3/JA4 | No | No | Yes |
| Anomaly Detection | No | No | Yes |
| Corporate Proxy detection | No | No | Yes |
| Verified bot categories | Limited | Limited | Full |
| Custom WAF rules | 5 | 20/100 | 1,000+ |

## Technical Constraints

- Max 25 WAF custom rules on Free (varies by plan).
- Workers CPU limits apply to bot logic.
- Bot Analytics sampled at 1-10%; 30-day history max.
- JSD requires CSP allowing `/cdn-cgi/challenge-platform/`.
