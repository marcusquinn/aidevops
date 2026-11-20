---
description: Refresh WordPress directory listings from a data provider and add a new area or service to the directory
mode: subagent
tools:
  read: true
  bash: true
  edit: true
  write: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Delivery: directory refresh and new area/service

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Use when**: listings must be refreshed from a data provider (places/business data API or CSV export), or a new area (location) or service (category) must be added to a directory site.
- **Site-specific source**: the site's board cards (which areas/services, provider, limits) and the directory plugin's docs (post type, taxonomy and field names, importer). This doc is the cross-site method.
- **Inputs**: site URL, provider and credential name in the secret store, area/service list, import mapping, record limit/budget.
- **Related**: `wp-cli-reference.md`, `rankmath-mcp.md`, `../../seo/local-seo.md`, `fluent-mcp.md` (boards), `workflows/wordpress-local-clone.md`.

<!-- AI-CONTEXT-END -->

## Rules

- Never overwrite owner-edited or paid (Featured) listings from provider data; match on a stable provider ID stored in meta and update only fields marked provider-managed.
- Respect provider terms and rate limits; cache raw responses privately and record the provider call count against the card's budget.
- Dry run first on a clone or with the importer's preview mode; write to production only after the diff is reviewed.
- Credentials come from `aidevops secret`; never put API keys in commands that are logged or in cards.

## Steps

1. **Read the card.** Confirm scope: areas, services, fields to refresh, budget, schedule.
2. **Back up.** `wp db export` to a private path (`wp-dev.md` "Pre-change server backups"), plus a listing count: `wp post list --post_type=<type> --format=count`.
3. **Add the area or service (if asked).** Create the term: `wp term create <taxonomy> "<Name>" --slug=<slug> --parent=<id>`. Create its landing page or confirm the plugin generates one; add intro copy from the brief only. Add it to menus and the sitemap (`wp menu item add-term`), and set SEO title/description per `../../seo/local-seo.md`.
4. **Fetch provider data.** Query by area and service; save raw results privately; deduplicate on provider ID, then on normalised name plus address/phone.
5. **Diff.** Compare with existing listings: new, changed, closed/removed. Output counts and a sample. Flag low-quality records (no name, no address, wrong category, permanently closed).
6. **Apply.** Create new listings as `draft` first: `wp post create --post_type=<type> --post_status=draft --post_title=... --meta_input='{...}'`; set taxonomy terms with `wp post term set`. Update changed provider-managed fields only. Mark closed listings per card policy (draft or note), never delete.
7. **Publish in batches.** Review a sample batch (title, categories, map location, hours, duplicates), then publish: `wp post update <ids> --post_status=publish`. Rebuild plugin indexes/caches the plugin documents, then flush caches for affected pages only.
8. **Verify.** Counts match the diff; the area/service page lists its listings; search finds a sample; no duplicates (`wp db query` grouping on the provider ID meta); sitemap includes new pages; spot-check 5 listings on the front end.
9. **Close the card** with counts (created, updated, skipped, removed), provider calls used, and the next refresh date.

## Rollback

Restore from the step 2 export, or revert only this run: keep the list of created IDs and trash them (`wp post delete <ids>` without `--force`), and restore changed meta from the saved pre-change JSON. Remove a newly added term with `wp term delete <taxonomy> <id>` once empty.
