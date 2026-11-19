---
description: Ultimate Multisite (WaaS) operations and order delivery - products, checkout, memberships, payments, sites, and the order-to-delivery loop with Fluent Support, Fluent Boards, FluentCRM and Stripe
mode: subagent
temperature: 0.1
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Ultimate Multisite and order delivery

<!-- AI-CONTEXT-START -->

## Quick Reference

- **What**: Ultimate Multisite (formerly WP Ultimo) sells sites and services on a WordPress network: products (plans, packages, services), checkout forms, customers, memberships, payments, sites, domains, webhooks and emails.
- **WP-CLI**: `wp wu <object> list|get|create|update|delete`, where `<object>` is `product`, `checkout_form`, `customer`, `membership`, `payment`, `site`, `domain`, `discount_code`, `webhook`, `email`, `broadcast` or `event`. Run with `--url=<main site>`. Check `wp help wu <object> <command>` for fields; many options have no description.
- **REST**: `/wp-json/wu/v2/<object>` (same objects). Enabled under Ultimate Multisite → Settings → API & Webhooks (`enable_api`). Authenticate with HTTP Basic, using the API key as the user and the API secret as the password. The endpoint also accepts `api_key`/`api_secret` query parameters; never use those, because they end up in access logs.
- **Settings**: network option `wp-ultimo_v2_settings` (currency, gateways, invoices, API). Read it with `wp eval`, never print key or secret values.
- **Order delivery** (below) joins Ultimate Multisite with `fluent-mcp.md` (Fluent Support tickets, Fluent Boards cards), `../../services/crm/fluentcrm.md` (customer email), `../../services/payments/stripe.md` (charges, refunds, disputes) and `mainwp.md` (fleet upkeep).
- **Subdomain DNS on Cloudflare**: per-site records through the core integration, no wildcard; origin SSL on Hostinger stays an aidevops step (section "Subdomain networks behind Cloudflare").
- **Network add-ons**: networks often add delivery, billing or support behaviour. Read the network's own repo `AGENTS.md` or docs for its commands before acting, and list the network's WP-CLI commands with `wp help --url=<main site>`.

<!-- AI-CONTEXT-END -->

## Operating rules

1. **Read before write.** Start with `list`/`get` and quote current values. Memberships, payments and products drive real billing.
2. **Money and messages need explicit intent.** Creating or completing a payment, changing a membership's status, amount or products, refunding, cancelling or sending a broadcast can charge, refund, email, or block a customer's site. Present the exact command and its effect. Run it only when the operator asked for that action.
3. **Test mode first.** Check `stripe_sandbox_mode` / `stripe_checkout_sandbox_mode` in settings before any test order. Never take a live payment to "test".
4. **Templates and copies.** Site templates (`site_template`) are cloned into customer sites, so changing a template changes future sites, not existing ones. A copied network keeps the source's queued work: Ultimate Multisite sends delayed system emails from its scheduler (`wu_send_schedule_system_email`, group `wu_system_emails`), and gateways and integrations call out. Block outbound mail and HTTP and pause cron and queues **before** the copy first runs, not at launch; the procedure is in `../../workflows/wordpress-local-clone.md` section 4. A clone or review copy of a network also keeps the source's settings, including support addresses and API credentials: check them before launch.
5. **Personal data.** Customers, payments and tickets contain PII. Summarise them; keep exports out of repos and issues.
6. **Caches.** After changing products or checkout forms, purge the page cache for the checkout and pricing pages (see `../../services/hosting/hostinger.md` for LiteSpeed on Hostinger).

## Read the state

```bash
URL=https://example.com   # the network's main site
wp wu membership list --status=active --fields=id,customer_id,plan_id,status,amount,date_expiration --url="$URL"
wp wu payment list --status=pending --fields=id,membership_id,total,status,gateway,date_created --url="$URL"
wp wu product list --fields=id,slug,name,type,amount,setup_fee,active --url="$URL"
wp wu checkout_form list --fields=id,slug,name,active --url="$URL"
```

`wp wu <object> list` returns at most 100 records (the BerlinDB default `number`), and has no limit or offset option. Count first, and page through larger sets with the REST collection (`page` and `per_page`; default 10):

```bash
wp eval 'echo wu_get_payments(["status" => "pending", "count" => true]);' --url="$URL"   # count has no limit
curl -s --config "$WU_CURL_CONFIG" "$URL/wp-json/wu/v2/payment?status=pending&per_page=100&page=2" \
  | jq '[.[] | {id, status, total, gateway, date_created}]'
```

`$WU_CURL_CONFIG` is a private file (mode 600, outside the repository) holding one line, `user = "API_KEY:API_SECRET"`, so the credentials stay out of the command line and shell history. Full records carry customer IDs and line items: keep the `jq` filter to the fields the task needs (rule 5).

The status values you see (for example `pending`, `active`, `on-hold`, `expired` and `cancelled` for memberships; `pending`, `completed`, `refunded` and `failed` for payments) are the plugin's own. Confirm them on the site before filtering.

## Order to delivery

One loop for every paid order. Each step names its record, so anyone can see where an order is.

| Step | Record | Check |
|------|--------|-------|
| 1. Order | Ultimate Multisite payment and membership | Payment `completed` (or the deposit's), membership created, customer email arrived |
| 2. Intake | Fluent Support ticket per ordered product (or one per order) | The ticket holds what is included, what the team needs from the customer, and what is due |
| 3. Plan | Fluent Boards card, linked from the ticket | Owner, due date, checklist; requests and feedback stay on the card. SSH-only access: `wp-helper.sh --fluent-boards` (`fluent-mcp.md` "Work a setup board") |
| 4. Build | The customer's site or service | Work happens on a staging copy or the customer site, never on a template |
| 5. Review | Ticket reply to the customer | The customer confirms. The card moves to "Done (please check)", then to Closed |
| 6. Bill | Ultimate Multisite payment or membership change | Any balance or recurring price starts as the network's terms say; failed charges get a payment link |
| 7. Follow up | FluentCRM automation or tag | Review request, onboarding emails, renewal reminders; marketing only with consent |

Network add-ons may automate steps 2 and 6. Follow their documented commands, and never duplicate a ticket or charge they already made.

Before the first real order, run the whole loop once in test mode. Check that the ticket opens, the customer can see it, billing starts as the terms say, and a refund works.

## Setup checklist for a selling network

- Payment gateway connected in test mode, webhook URL added in the gateway, then live mode. With direct API keys, the active gateway's settings show **Webhook Listener URL** (`stripe_webhook_listener_explanation` for Stripe, `stripe_checkout_webhook_listener_explanation` for Stripe Checkout). Connected through Stripe Connect (OAuth), that field is hidden; read the same URL without changing modes, `wp eval 'echo wu_get_gateway("stripe")->get_webhook_listener_url();' --url="$URL"` (`stripe-checkout` for Checkout; the main site address plus `?wu-gateway=<id>`, or `WU_GATEWAY_LISTENER_URL` when defined), and compare it with the endpoint listed in Stripe → Developers → Webhooks for the same mode (test or live).
- Products: names, descriptions, prices, setup fees, currency, and what the customer must provide.
- Checkout forms: fields, consent checkbox for marketing, terms link.
- Invoices: company details and numbering (`invoice_*` settings), PDF attachment.
- Support: Fluent Support mailbox read over IMAP from the operator's own mailbox (`fluent-mcp.md` rule 7). Customer sites' "contact support" goes to the operator, not to a previous owner of a cloned network.
- Email: transactional mail through the site's SMTP plugin; test the order, payment and password emails.
- Upkeep: backups, one updater (host-managed or WordPress's), uptime alerts (`../../services/hosting/hostinger.md`, `mainwp.md`).
- Subdomain network behind Cloudflare: per-site DNS records instead of a wildcard (next section).

## Subdomain networks behind Cloudflare

Observed **2026-11-19** with Ultimate Multisite 2.18.0 on Hostinger. A proxied `*.<apex>` wildcard lets any invented hostname reach the origin. The core Cloudflare integration can instead add a proxied record for each new site and remove it when the site is deleted. No add-on is needed.

1. **Back up the zone's DNS** (`GET /zones/<id>/dns_records`, saved privately), then add a proxied `CNAME <name> → @` for every existing child site. List them with `wp site list --field=domain --url="$URL"`.
2. **Token**: create a Cloudflare API token limited to that one zone, with Zone Read and DNS Edit. Set `WU_CLOUDFLARE_API_KEY` and `WU_CLOUDFLARE_ZONE_ID` in `wp-config.php` after `define('SUNRISE', true);` (`WU_CLOUDFLARE_SAAS_ZONE_ID` is only for Cloudflare for SaaS custom hostnames). Edit a copy, run `php -l` on it, then replace the live file: an anchor of only `define('SUNRISE'` split that line and broke the site. Confirm the integration's connection test passes (`test_connection()`) and the zone can be read.
3. **No `www` per site**: set `auto_create_www_subdomain` to `main_only`. Universal SSL covers one level, so `www.<site>.<apex>` fails at the edge; mapped custom domains still get `www`.
4. **Networks whose domain starts with `www.`** (`DOMAIN_CURRENT_SITE` = `www.<apex>`): up to 2.18.0, `on_add_subdomain()` and `on_remove_subdomain()` compare the new site's host with `www.<apex>`, so `<site>.<apex>` never matches and nothing is created or logged. Fix proposed upstream in [Ultimate-Multisite/ultimate-multisite#2122](https://github.com/Ultimate-Multisite/ultimate-multisite/pull/2122). Until a release includes it, an mu-plugin can drop the leading `www.` from `$current_site->domain` only while the `wu_add_subdomain` and `wu_remove_subdomain` actions run (strip at priority 9, restore at 11; the integration hooks at 10). It does nothing on a network without `www.`. Remove it once the fix ships.
5. **Test with a throwaway site.** The record is added by the queued `wu_add_subdomain` action, which ran from site cron within 5 minutes. Read the `integration-cloudflare` log for `Added sub-domain "<name>" to Cloudflare.`, delete the site, and check for `Removed sub-domain`.
6. **Delete the wildcard last**, after a second DNS backup. Check every child site returns 200 and an invented name no longer resolves.
7. **Origin SSL for each new site** stays a Hostinger step the operator runs from aidevops, because Hostinger's API tokens cover the whole account and must not be stored in WordPress: `../../services/hosting/hostinger.md` "Subdomain multisite behind Cloudflare without a wildcard". Until it runs, the new site answers 525.

## Troubleshooting

| Symptom | Check |
|---------|-------|
| `wu/v2` returns 401 | `enable_api` off, wrong key/secret, or a WAF stripping `Authorization` |
| Checkout takes payment but no membership | Gateway webhook missing or blocked; check the gateway's webhook log and Ultimate Multisite → Events |
| Customer site missing plugins after an add-on | Product plugin limits sync only at checkout or upgrade; look for a network command that re-syncs |
| Prices show the wrong currency | `currency_symbol` setting, and each product's own currency fields |
