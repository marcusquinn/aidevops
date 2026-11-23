---
description: Deliver a paid directory listing upgrade (Featured listing) on a WordPress directory site - from the order to the published listing and the delivery charge
mode: subagent
tools:
  read: true
  bash: true
  edit: true
  write: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Delivery: Featured listing upgrade

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Use when**: a customer has paid for a Featured (promoted) upgrade of a directory listing and the work is to publish it and close the order.
- **Site-specific source**: the order's board card (listing, term, price, deliverables) and the directory plugin's docs (field and flag names). This doc is the cross-site method.
- **Inputs**: order ID, listing ID or URL, paid product and term, customer-supplied copy/images, payment reference.
- **Related**: `ultimate-multisite.md` (order-to-delivery loop, charges), `fluent-mcp.md` (support ticket, boards, CRM), `wp-cli-reference.md`, `rankmath-mcp.md`.

<!-- AI-CONTEXT-END -->

## Rules

- Verify payment before changing the listing: the order is paid/completed in the order system, not just created.
- Change only the ordered listing. Never alter other listings, prices or the customer's own copy beyond what they supplied; typo fixes only.
- Delivery charge or invoice step happens only where the card or product says it applies, once, after the listing is verified live. Check for an existing charge first (idempotent).
- Do not message the customer outside the site's support/CRM route.

## Steps

1. **Read the order and card.** Confirm the listing, the term (start/end), and what is included (badge, top placement, extra images, longer description, links).
2. **Verify the listing.** `wp post get <id> --fields=ID,post_title,post_status,post_type`. Confirm the owner matches the customer (`post_author` or the plugin's owner field). Mismatch: stop, note on the card.
3. **Back up the listing.** `wp post get <id> --format=json` and `wp post meta list <id> --format=json` saved to a private backup path (`wp-dev.md` "Pre-change server backups").
4. **Apply the upgrade.** Plugins differ; map by role. Typical: a featured flag meta (`wp post meta update <id> <featured_key> 1`), a featured term (`wp post term add <id> <taxonomy> featured`), and an expiry meta set from the paid term (`date -d "+<term>" +%F`). Read the key and term names from the plugin docs or from an existing featured listing (`wp post meta list <featured-id>`), never guess.
5. **Add customer content.** Apply supplied copy and images (`wp media import <file> --post_id=<id> --porcelain`), set the featured image, keep formatting consistent with other featured listings.
6. **Publish and verify.** Set `post_status=publish` if pending. Flush the page/object cache for this URL only. Check: the listing URL returns 200, shows the badge, appears in the featured position on the category/area page, and appears in search with correct title and meta.
7. **Delivery charge.** If the product defines one, create it via the order/billing plugin once (`ultimate-multisite.md`), after checking none exists for this order. Record the charge reference.
8. **Close the loop.** Reply on the support ticket through the helper in `fluent-mcp.md`, add the CRM tag or note if the setup uses one, and move the card to done with: listing URL, term end date, charge reference.
9. **Expiry.** Record the end date on the card. At expiry, reverse step 4 (flag, term, expiry meta) unless a renewal order exists.

## Rollback

Restore the listing's post fields and meta from the step 3 backup (`wp post update`, `wp post meta update`), remove the featured term, purge the URL cache. A charge already raised is reversed through the billing plugin (refund or credit), not by deleting records; escalate on the card.
