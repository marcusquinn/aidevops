---
description: Site hygiene sweep - published sample/duplicate pages, links through redirects, utility-page indexing, plugin settings that point at duplicates
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Site Hygiene Sweep

Run during every SEO audit, after migrations or page rebuilds, and before handing a site back. Generic audits catch broken links; this sweep catches content that works but should not be public: leftover sample pages, numbered duplicates, internal links that go through redirects, and indexed utility pages.

## Inventory (read-only)

Export every page, post, product and custom post type with: ID, type, status, slug, title, word count, last modified, and SEO title, description, focus keyword and robots values. On WordPress use WP-CLI `post list` and read the SEO plugin's metadata. Do not read orders, users, form entries or other customer data.

## Checks

| # | Check | How to detect | Typical fix |
|---|-------|---------------|-------------|
| 1 | Published sample/starter pages | Slugs or titles like `sample-page`, `hello-world`, `about-2`, `contact-us` next to a real `/contact/`, theme demo content, empty or near-empty bodies | A slug match can be a live landing page: confirm with the owner that it is unused (menus, links, analytics, campaigns), then set to draft and 301 to the real page |
| 2 | Numbered duplicates | Slugs ending `-2`, `-3`, `-copy`; identical or similar titles; WooCommerce `my-account-2` or `checkout-2` created by plugin re-setup | Confirm which copy the theme, plugins and menus use, then draft the other and 301 to the real one |
| 3 | Plugin settings pointing at duplicates | Plugin options storing a page ID (for example terms, login, account or affiliate portal pages). Compare each with the canonical page. **Check before drafting**: drafting a page a plugin still uses breaks that flow | Point the option at the real page, then draft the duplicate |
| 4 | Internal links through redirects | Crawl internal `href`s in post content, builder data (Elementor JSON), menus, headers and footers; flag any 3xx. Treat slash-only, legacy product base and moved-page redirects as link debt, not breakage | Rewrite a link to its final URL only when the redirect is permanent (301/308) and the same for every session state. Send temporary or conditional redirects to owner review: to an anonymous crawler, `/my-account/` and `/checkout/` redirect to login. In builder JSON, edit link values exactly, then clear the builder's CSS and asset caches |
| 5 | Links to drafts, 404s or other sites | Same crawl: 4xx targets, and absolute links to an old or sister domain | Fix the target; mark external sister-site links for owner review |
| 6 | Indexed utility pages | Login, account, password reset, affiliate portal, terms used only in sign-up, preferences and unsubscribe, cart, checkout, thank-you pages | `noindex, follow` (keep links followable); confirm they leave the sitemap |
| 7 | Missing or stale SEO metadata | No focus keyword, titles over 60 characters or keyword-stuffed, descriptions outside 120–160 characters, slug and title disagreeing, past promotions written as current offers | Rewrite from the page's real content; describe past promotions as past; never invent prices, guarantees or turnaround times |
| 8 | Schema defaults | Post type default schema and what actually renders. **Verify after changing**: in Rank Math 1.0.281, setting the page default to `off` removed the whole JSON-LD graph (Organization, WebSite, WebPage) from pages | Change only with a before/after check of rendered `application/ld+json` |
| 9 | Plugin modules for absent integrations | SEO plugin modules enabled for plugins that are not installed (BuddyPress, bbPress, Web Stories) | Disable after confirming the integration plugin is absent |
| 10 | Temporary or masking redirects | 302/307 redirects on long-lived paths; redirects that hide a real published page (for example `/samples/` → a product while a samples page exists) | Ask the owner whether it is temporary; if not, make it 301 or deactivate it so the real page serves |
| 11 | Raw shortcodes from removed themes/plugins | Fetch each published URL and flag any shortcode-shaped text (`[name …]`) in the rendered body, for example `[av_…]`, `[layerslider…]`, `[ulp…]`, `[pm_…]`. Check each match against installed and removed plugins and themes. Skip builder-library endpoints that 301 | Plugin page with a rebuilt successor: draft and 301. Content page or product: convert to clean HTML preserving all copy, with a hash guard |
| 12 | Published records that 404 | Publicly queryable post types listed in `post list` or the sitemap but returning 404. A 404 on a non-public custom post type is by design | Check plugin and theme consumers of the post type first, then draft or 301 to the archive; confirm sitemap removal |

## Safety

- Detection is read-only. Apply fixes only when the request includes remediation; otherwise report each fix as proposed.
- Draft pages, don't delete them. Back up exact pre-change state (status, content, meta, options, redirects) in a private location before changes, and apply each change with a hash guard and readback.
- Add a 301 for every drafted URL that was public, and check for redirect loops.
- Never change prices, contact details, legal text or customer-facing promises without owner approval.
- Purge page and object caches, then verify publicly: redirect status and location, `<meta name="robots">`, `<title>`, rendered JSON-LD, sitemap contents, and a repeat link crawl.

## Output

Report each finding as Issue, Evidence (URL and ID), Fix applied or proposed, and Owner decision needed. List owner decisions separately (temporary redirects, sister-domain links, content that might be intentional).
