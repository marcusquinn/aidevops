---
description: updown.io uptime monitoring - one account for every site, a status page per site on its status subdomain
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: false
  webfetch: false
  task: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# updown.io Monitoring

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: uptime and TLS-certificate monitoring for every site, with a public status page per site.
- **Policy**: one updown.io account monitors every site. Each site gets its own status page on a subdomain of its live domain, `status.<domain>`, a `CNAME` to `page.updown.io`. Do not create an updown account per site.
- **Helper**: `updown-helper.sh` — `list`, `json`, `add`, `update`, `delete`, `metrics`, `recipients`, `status-page list|add|update|delete`. Full flags: `updown-helper.sh help`.
- **Credentials**: `aidevops secret set UPDOWN_API_KEY` (the read-write key from updown.io settings). The helper sends it as an `X-API-KEY` header on curl's stdin, never in arguments or URLs.
- **Defaults**: new checks are private and hourly. Public visibility comes from the site's status page, which lists private checks too.
- **Not in the API**: a status page's custom domain and account settings, including domain-expiration reminders (off by default). Set them in the updown.io UI; the helper cannot.
- **Use instead**: error tracking → `services/monitoring/sentry.md`; LLM traces → `services/monitoring/langwatch.md`.

<!-- AI-CONTEXT-END -->

## Set up a site

Domain-expiration reminders are optional and off by default. Leave them off when the domains auto-renew. To use them, enable them once in the updown.io account settings; the API cannot change account settings.

```bash
# 1. Create the check: private, hourly. Prints the check token.
updown-helper.sh add https://example.com --alias "Example" --contains "Example Domain"

# 2. Optional: choose alert recipients (default: the account's selected recipients).
updown-helper.sh recipients
updown-helper.sh update <check-token> --recipient email:12345

# 3. Create the site's status page. Prints its token, updown URL and the next steps.
updown-helper.sh status-page add --name "Example status" --check <check-token>
```

Then:

1. On updown.io, open the status page's settings and enter `status.example.com` as its custom domain.
2. At the site's DNS host, add every record the custom-domain screen lists: `status` `CNAME` `page.updown.io` (DNS only; see [DNS](#dns)), plus any TXT record shown there. The helper creates no DNS records. updown issues the page's TLS certificate (Let's Encrypt or ZeroSSL) once the records resolve. After changing an existing record, wait out its TTL.
3. Verify: `dig +short CNAME status.example.com` returns `page.updown.io.`, and `curl -sSI https://status.example.com/` returns `200` with a valid certificate.
4. Link the status page from the site, for example in the footer.

Several checks for one site (homepage, login, API) belong on the same page: repeat `--check`, or pass a comma-separated list, in display order. `status-page update <token> --check ...` replaces the list.

The status page shows each check's alias; with an alias set, the check URL is not shown. Set `--alias` to a public-facing name. After `add`, the `list` and `json` output can lag by a few seconds.

## DNS

| Situation | Record |
|-----------|--------|
| Default | `status` `CNAME` `page.updown.io`, DNS only (Cloudflare grey cloud) |
| Cloudflare proxied (orange cloud) | Avoid. If required, add CAA records on `status.<domain>`: `0 issue "letsencrypt.org"` and `0 issue "sectigo.com"`, because proxying hides updown's own CAA and certificate issuance fails (Cloudflare error 525). Never use Flexible TLS: it loops redirects. |
| Site on a subdomain (`app.example.com`) | `status.app.example.com` must be DNS only: Cloudflare's free certificate covers one subdomain level. |
| Multisite network with wildcard subdomain sites | The explicit `status` record shadows the `*` wildcard, so no subsite may be named `status`. |

The proxied-mode problems are from updown's [Cloudflare DNS for custom status pages](https://updown.io/doc/known-issues-when-using-cloudflare-dns-for-custom-status-pages) notes.

## Cost

updown charges one credit per check request; SMS alerts cost 7,500 credits per message ([pricing](https://updown.io/#pricing)). Credits per check per 30 days:

| Period | 3600 s | 1800 s | 600 s | 300 s | 120 s | 60 s | 30 s | 15 s |
|--------|--------|--------|-------|-------|-------|------|------|------|
| Credits | 720 | 1,440 | 4,320 | 8,640 | 21,600 | 43,200 | 86,400 | 172,800 |

Hourly is the default. A shorter period detects outages sooner and costs proportionally more; choose it per site with `--period`.

## Visibility

| Setting | Controls | Default |
|---------|----------|---------|
| Check `published` (`--public` / `--private`) | The check's own updown page | private |
| Status page `--visibility public\|protected\|private` | The site's status page; `protected` requires an access key | public |

A status page lists its checks whether or not they are published, so keep checks private and publish through the status page.

## Helper reference

| Command | Effect |
|---------|--------|
| `add <url> [alias] [period] [flags]` | Create a check; prints its token. Flags: `--alias`, `--period`, `--contains`, `--apdex`, `--recipient ID` (repeatable), `--public` |
| `update <token> <flags>` | Send only the given fields (`PUT /api/checks/<token>`); adds `--private`. `--recipient` replaces the selection. The URL is never copied from a read, so basic-auth credentials in it are not erased |
| `list` / `json` | Token, URL, alias and status / raw JSON |
| `delete <token>` / `metrics <token>` | Delete a check / last month's metrics |
| `recipients` | Alert recipient ids for `--recipient` |
| `status-page list\|add\|update\|delete` | Manage status pages (`/api/status_pages`) |

Invalid flag values exit 1 before any API call.

## Handover

When a site changes hands, remove its monitoring from this account instead of creating an account for it: `updown-helper.sh status-page delete <page-token>`, then `updown-helper.sh delete <check-token>`. Delete the page first so the custom domain is no longer attached to this account. The new owner can keep the `status` `CNAME` to `page.updown.io` for their own updown page, or repoint it to another provider.

## Related

- `scripts/updown-helper.sh` · [updown.io API](https://updown.io/api)
- `aidevops/service-links.md` · `services/monitoring/sentry.md`
