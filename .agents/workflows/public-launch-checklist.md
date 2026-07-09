---
description: Public launch checklist for websites, apps, plugins, dashboards, widgets, and tools
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Public Launch Checklist

Use before publishing, deploying, merging to the live branch, removing noindex,
submitting sitemaps, enabling real customer automation, or telling the user a new
public website/app/plugin/widget/dashboard/tool is launch-ready.

## 1. Scope and approval

- Confirm the launch target, domain/app URL, repo/branch/worktree, and user-visible version.
- Confirm what will become public now versus later.
- Get explicit approval for publishing, DNS/live changes, noindex removal, SMS/email automation, paid services, data deletion, or production CRM changes.
- Record a rollback point: git commit/tag, deployment ID, WordPress DB/export/revision, or backup name.

## 2. Public exposure review

- Assume any visitor can inspect HTML, JavaScript bundles, static files, source maps, widgets, forms, iframes, and public API endpoints.
- Search the actual public build inputs and generated output for secrets, private URLs, tokens, API keys, CRM lead-capture URLs, webhook URLs, admin paths, internal hostnames, account IDs, payment/customer identifiers, and private callback URLs.
- Verify internal docs are excluded from public output: `README.md`, `TODO.md`, `SESSION-STATE.md`, `docs/`, `prompts/`, `todo/`, `inbox/`, scripts, scrapers, reports, backups, fixtures, agent metadata, and local notes.
- Search for exposed research/ops terms: scraping/source names, competitor/source URLs, crawler notes, lead lists, prompt libraries, source prioritisation, and internal SOPs.
- Public static pages must not write directly to privileged backends. Use a server-side proxy/Worker/API with rate limits and signature/origin checks.

## 3. Public endpoint and form security

- List every public webhook/API/form endpoint and what it can do.
- Require the narrowest possible permissions and inputs.
- Add sanitization, payload size limits, rate limiting/spam protection, replay protection where possible, and provider signature verification where available.
- Treat long private URLs as a second lock, not the only lock.
- Verify honeypot/CAPTCHA/Turnstile/Formspree/domain allowlisting where applicable.
- Do not enable SMS/MMS or customer messaging until consent wording, opt-out handling, A2P/registration, and explicit user approval are complete.

## 4. Front-end safety and performance

- Replace untrusted `innerHTML`, template-string rendering, and HTML concatenation with DOM APIs/text nodes.
- Validate external URL protocols before rendering links.
- Add `rel="noopener noreferrer"` to all `target="_blank"` links.
- Sandbox generated iframes unless broader privileges are required and documented; avoid combining `allow-scripts` with `allow-same-origin` to prevent sandbox bypass.
- Avoid shipping large internal datasets to the browser; lazy-load or split data where practical.
- Keep third-party analytics/chat/widgets consent-gated where consent applies.
- Run build/lint/typecheck and page-load checks available for the repo.

## 5. Content, legal, and trust

- Confirm no private names, personal addresses, unapproved entity names, or sensitive internal details appear publicly.
- Confirm required public pages from `tools/app-stack/public-site-surfaces.md` exist, are linked from the footer/sitemap, and match the launch scope: `/about`, `/contact`, `/privacy`, and `/terms` or documented equivalents.
- Confirm applicable trust/compliance pages exist and are accurate: cookie/tracking notice, accessibility statement, data-protection/security overview, confidentiality/conflict-handling statement, commerce policies, refunds/cancellation/shipping, SMS/email consent and opt-out, and sector-specific compliance pages.
- Check Terms, Privacy, disclaimers, contact details, cookie consent, tracking disclosures, and SMS/email consent wording against the actual product, routes, jurisdiction, processors, support channels, and implemented controls.
- Search public copy, metadata, legal pages, schema/JSON-LD, OG tags, favicons/logos, analytics/tag IDs, contact details, support links, package/app names, screenshots, sample testimonials, and footer/header text for copied content from another brand, prior client, template starter, or cloned stack.
- Verify certification, permit, partner, guarantee, pricing, and compliance claims are accurate and permissioned.
- Do not imply compliance, certification, encryption, AI isolation, human conflict separation, accessibility conformance, or data-protection controls without evidence.
- Ensure WordPress/public CMS content remains draft until the user explicitly approves publishing.

## 6. SEO and launch gates

- Confirm title/meta/OG, canonical URLs, sitemap, robots/noindex, redirects, 404, favicon/logo, mobile layout, accessibility basics, and schema validity.
- Submit sitemap/Search Console only after launch approval and noindex removal.
- Do not create or change Google Business Profile, local listings, outreach, ads, or DNS without explicit approval.

## 7. Data, integrations, and observability

- Verify backups before production changes.
- Confirm CRM/form/test submissions use fake data until production is approved.
- Verify analytics, logging, alerts, email notifications, uptime checks, and error monitoring are working without exposing secrets or customer PII.
- Document service costs, accounts, credentials storage location, and dashboard/inbox updates without including passwords/tokens.

## 8. Evidence and handoff

- Record version number, commit hash, deployment/build result, checks run, URLs tested, and rollback point.
- Record remaining risks and blocked items plainly.
- Update project `SESSION-STATE.md`, changelog/version log, and TODO/dashboard follow-ups.
- Before completion, scan the conversation for unfulfilled launch promises and displaced requests.

## Suggested exposure search terms

Use project-specific terms plus:

```text
LeadCapture|webhook|token|secret|api_key|apikey|auth|password|private|callback|admin|crm|formspree|zapier|make\.com|n8n|scrap|crawl|source_url|sourceUrl|competitor|_scripts|_scrapers|docs/|SESSION-STATE|TODO|README|inbox|innerHTML|target="_blank"|iframe|lorem|ipsum|example|placeholder|template|starter|ACME|old domain|old brand|support@|privacy@|terms|cookie|accessibility|data protection|confidentiality|refund|shipping|cancellation|GTM-|GA-|UA-|localhost|127\.0\.0\.1|0\.0\.0\.0|::1|[a-zA-Z0-9-]*(dev|staging)(\.|-[a-zA-Z0-9-]+\.)(?=[a-zA-Z0-9-]+\.)
```

## Related workflows

- `workflows/preflight.md` — includes the public launch exposure review gate.
- `workflows/ui-verification.md` — UI/browser checks.
- `tools/app-stack/public-site-surfaces.md` — standard public pages, trust pages, schema, and launch verification.
- `reference/pre-push-guards.md` — privacy and push guards.
- `reference/secret-handling.md` — credential handling.
