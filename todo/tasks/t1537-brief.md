<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1537: Refactor shared product concerns from mobile-app-dev to product/

## Session Origin

Identified during review of mobile-app-dev agent suite. The subagents `planning.md`, `ui-design.md`, `monetisation.md`, `onboarding.md`, and `analytics.md` contain universal product concerns that apply to any digital product (mobile apps, browser extensions, web apps, SaaS). They are currently housed under `mobile-app-dev/` which implies mobile-only scope, causing `browser-extension-dev.md` to cross-reference them with awkward "shared with mobile-app-dev" notes.

## What

Extract the five universal product subagents from `mobile-app-dev/` into a new `product/` directory. Add a new `product/growth.md` acquisition playbook. Create a `product.md` entry-point agent. Update `mobile-app-dev.md` and `browser-extension-dev.md` to reference `product/` for shared concerns. Update the AGENTS.md domain index.

## Why

- **Clarity**: `mobile-app-dev/planning.md` is not mobile-specific — it's product validation. Naming it under mobile-app-dev misleads agents and users.
- **Reuse**: `browser-extension-dev.md` already cross-references these files with "Shared with mobile-app-dev" notes — a code smell indicating they belong in a shared location.
- **Extensibility**: A `product/` directory can serve future product types (web apps, SaaS, CLI tools) without coupling to mobile.
- **Growth gap**: No acquisition/growth playbook exists anywhere in the framework. `product/growth.md` fills this gap.

## How

1. Create `product/` directory in `.agents/`
2. Copy (not move — mobile-app-dev keeps its own copies for mobile-specific context) the following to `product/`:
   - `planning.md` → `product/validation.md` (de-mobilified: remove mobile-specific app store search URLs, generalise to "product validation")
   - `ui-design.md` → `product/ui-design.md` (de-mobilified: remove mobile-only platform sections, keep universal design principles)
   - `monetisation.md` → `product/monetisation.md` (de-mobilified: remove RevenueCat-specific mobile SDK code, keep revenue model thinking)
   - `onboarding.md` → `product/onboarding.md` (de-mobilified: remove mobile-specific permission patterns, keep universal onboarding principles)
   - `analytics.md` → `product/analytics.md` (de-mobilified: remove mobile-specific platform tools, keep universal analytics principles)
3. Create `product/growth.md` — acquisition playbook (ASO, SEO, content, paid, referral, community)
4. Create `product.md` entry-point agent with subagent index
5. Update `mobile-app-dev.md`: replace inline shared subagent table entries with references to `product/` equivalents; keep mobile-specific subagents (`expo.md`, `swift.md`, `backend.md`, `notifications.md`, `assets.md`, `testing.md`, `publishing.md`)
6. Update `browser-extension-dev.md`: replace "Shared subagents (from mobile-app-dev/)" table with "Shared subagents (from product/)"
7. Update `.agents/AGENTS.md` domain index: add `product/` row under Browser/Mobile section

## Acceptance Criteria

- [ ] `product/` directory exists with 6 files: `validation.md`, `ui-design.md`, `monetisation.md`, `onboarding.md`, `analytics.md`, `growth.md`
- [ ] `product.md` entry-point agent exists with subagent index table
- [ ] All product/ files have de-mobilified language (no "mobile app" in titles/descriptions where the content is universal)
- [ ] `mobile-app-dev.md` references `product/` for shared concerns, not its own subagents
- [ ] `browser-extension-dev.md` references `product/` not `mobile-app-dev/` for shared subagents
- [ ] `mobile-app-dev/` retains its mobile-specific subagents unchanged
- [ ] AGENTS.md domain index includes `product/` entry
- [ ] `product/growth.md` covers: ASO/SEO, content marketing, paid acquisition, referral/viral, community, launch strategy

## Context

- Worktree: `~/Git/aidevops-refactor-t1537-product-concerns`
- Branch: `refactor/t1537-product-concerns`
- Issue: GH#5092
- Estimate: ~4h
