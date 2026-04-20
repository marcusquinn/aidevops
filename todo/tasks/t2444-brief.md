# t2444: Add files_scope field to brief template for PR scope enforcement

## Origin

- **Created:** 2026-04-20
- **Session:** headless worker for GH#20148
- **Parent task:** t2264 (GH#19808)

## What

Add a `## Files Scope` section to `.agents/templates/brief-template.md`.

## Why

Prerequisite for the scope-guard pre-push hook (t2445). Workers declare intended file scope; the guard enforces it.

## How

- EDIT: `.agents/templates/brief-template.md` — add `## Files Scope` section after `## Files to Modify` (format: markdown list of relative paths, one path or glob per list item); document the format requirement in a `## Critical Rules` callout within the section so the scope-guard parser has a stable, explicit contract

## Acceptance

- Template contains `## Files Scope` section with documented format
- `markdownlint-cli2 .agents/templates/brief-template.md` passes

## Tier

Selected tier: `tier:standard`

Ref #19808
