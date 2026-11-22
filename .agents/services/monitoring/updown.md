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
- **Policy**: one updown.io account monitors every site. Each site gets its own status page on a subdomain of its live domain, `status.<domain>`. Do not create an updown account per site.
- **Custom domain = two DNS records, no updown.io screen**: `status.<domain>` `CNAME page.updown.io` and `_updown.status.<domain>` `TXT "updown-page=p/<page-token>"`. The TXT record attaches the domain to the page; the whole setup is automatable.
- **Helper**: `updown-helper.sh` — `list`, `json`, `add`, `update`, `delete`, `metrics`, `recipients`, `status-page list|add|update|delete|domain`. Full flags: `updown-helper.sh help`.
- **Credentials**: `aidevops secret set UPDOWN_API_KEY` (the read-write key from updown.io settings). The helper sends it as an `X-API-KEY` header on curl's stdin, never in arguments or URLs.
- **Defaults**: new checks are private and hourly. Public visibility comes from the site's status page, which lists private checks too.
- **Not in the API**: account settings, including domain-expiration reminders (off by default). Set them in the updown.io UI. When a step seems UI-only, read the screen first in the user's signed-in browser (`tools/browser/opencode-browse.md`): that is how the custom-domain screen turned out to list only DNS records.
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

1. At the site's DNS host (its API, for example Cloudflare's, or panel) add both records. The helper creates no DNS records.

   | Name | Type | Value |
   |------|------|-------|
   | `status.example.com` | `CNAME` | `page.updown.io` (DNS only; see [DNS](#dns)) |
   | `_updown.status.example.com` | `TXT` | `"updown-page=p/<page-token>"` |

   There is nothing to enter on updown.io. The page's **Setup a custom domain** link (`https://updown.io/public-status?page=p%2F<page-token>`) only shows these records. The page must be `public` or `protected`. A check's own page uses the check token instead (`updown-page=<check-token>`).
2. Verify: `updown-helper.sh status-page domain <page-token> status.example.com` prints both records and checks the CNAME, the TXT record and `https://status.example.com/` (200 with a valid certificate). updown issues the certificate (Let's Encrypt or ZeroSSL) on the first HTTPS request after the records resolve, so the first TLS handshake can fail; the command retries for a minute. After changing an existing record, wait out its TTL.
3. Link the status page from the site, for example in the footer.

Several checks for one site (homepage, login, API) belong on the same page: repeat `--check`, or pass a comma-separated list, in display order. `status-page update <token> --check ...` replaces the list.

The status page shows each check's alias; with an alias set, the check URL is not shown. Set `--alias` to a public-facing name. After `add`, the `list` and `json` output can lag by a few seconds.

## DNS

| Situation | Record |
|-----------|--------|
| Default | `status` `CNAME` `page.updown.io`, DNS only (Cloudflare grey cloud), plus `_updown.status` `TXT "updown-page=p/<page-token>"` |
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
| `status-page domain <page-token> <host>` | Read-only: print the page's two DNS records for `host`, then check them and `https://host/` |

Invalid flag values exit 1 before any API call.

## Handover

When a site changes hands, remove its monitoring from this account instead of creating an account for it: `updown-helper.sh status-page delete <page-token>`, then `updown-helper.sh delete <check-token>`. Delete the page first so the custom domain is no longer attached to this account. The new owner can keep the `status` `CNAME` to `page.updown.io` and change the `_updown.status` TXT record to their own page's token, or repoint both to another provider.

## Related

- `scripts/updown-helper.sh` · [updown.io API](https://updown.io/api)
- `aidevops/service-links.md` · `services/monitoring/sentry.md`
