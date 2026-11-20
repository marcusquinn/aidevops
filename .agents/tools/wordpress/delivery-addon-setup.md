---
description: Set up a website add-on plugin for a client (CRM, support desk, project boards, courses) working from the site's setup tasks
mode: subagent
tools:
  read: true
  bash: true
  edit: true
  write: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Delivery: add-on plugin setup

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Use when**: a client bought or requested an add-on (CRM, support desk, project boards, courses/LMS, bookings) and a setup board or task list exists for it.
- **Site-specific source**: the site's setup cards (task list and decisions) and the plugin's docs (settings, commands). This doc is the cross-plugin method.
- **Inputs**: site URL/blog ID, add-on role, setup board/cards, client details (business name, sender address, branding, staff users).
- **Related**: `fluent-mcp.md` (CRM, boards, forms, support, bookings; setup-board workflow), `wp-preferred.md` (plugin choices), `premium-plugin-updates.md`, `wp-cli-reference.md`, `ultimate-multisite.md`.

<!-- AI-CONTEXT-END -->

## Rules

- Setup cards define scope. Do each card in order, update it as you go, and stop at any card that needs a client decision or a credential: mark it blocked with the exact question. Never guess credentials, sender domains or payment settings; ask via secure provisioning (`aidevops secret`).
- Back up before activating (`wp-dev.md` "Pre-change server backups"). Test on a clone first when the site is live (`workflows/wordpress-local-clone.md`).
- Use licensed or free-repo plugins only; premium licence keys come from the secret store, never the card or chat.

## Steps

1. **Read the board.** Fetch the setup cards (`fluent-mcp.md` "Work a setup board"). List cards, dependencies, blockers.
2. **Pre-checks.** `wp core version`, `wp plugin list --status=active`, PHP version against the plugin's minimum, no conflicting plugin of the same role, disk and memory headroom. Record in the card.
3. **Install and activate.** `wp plugin install <slug> --activate --url=<site>` (or network-activate only if the card says so). For premium: upload from the licensed source, then activate the licence from the secret store. Confirm `wp plugin status <slug>`.
4. **Base configuration.** Business name, sender name/address, timezone (`wp option get timezone_string`), currency/locale, branding colours and logo, roles and capabilities for staff users (`wp user create`/`wp user add-role`). Use plugin WP-CLI or MCP where available, otherwise REST, otherwise wp-admin via browser automation.
5. **Role-specific setup** (the card gives specifics; typical shape):
   - **CRM**: lists, tags, a contact form wired to a list, double opt-in, unsubscribe page, one welcome automation.
   - **Support desk**: mailbox or form intake, ticket categories, canned replies, staff assignments, an auto-acknowledgement.
   - **Project boards**: board per project type, stages, default tasks, client/staff access.
   - **Courses/LMS**: course shell, lesson structure, enrolment rule, completion/certificate settings, access tied to the order or membership.
6. **Email deliverability.** Send a test message from the configured sender; confirm it arrives and that SPF/DKIM exist for the sending domain (`dig +short TXT <domain>`). If DNS is missing, add a card for the DNS owner.
7. **Verify end to end.** Run the primary user journey once as a test user (form to CRM contact, ticket to reply, course enrolment), then delete test data. Check front-end pages render, with no PHP notices in `wp-content/debug.log` if debug is on.
8. **Document and close.** Update each card with what changed and where; list open decisions; leave client-facing instructions on the card, not in the repo.

## Rollback

`wp plugin deactivate <slug>` returns the site to prior behaviour; keep data tables. Remove data only with `wp plugin uninstall <slug>` after user confirmation and a verified database backup. Restore changed options from the pre-change export.
