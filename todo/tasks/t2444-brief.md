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

- EDIT: `.agents/templates/brief-template.md` — add `## Files Scope` section after `## Files to Modify` (format: markdown list of paths **relative to the repository root**, one path or glob per list item); document the requirement in a `## Critical Rules` callout including: (1) the technical reasoning that the scope-guard parser (`scope-guard-pre-push.sh`) resolves all paths relative to the repository root — paths not anchored to the root will silently fail to match, allowing unintended files to pass the guard; (2) a warning that incorrect or overly-permissive paths create a path traversal risk where files outside the intended scope may be committed and pushed without review

## Acceptance

- Template contains `## Files Scope` section with documented format
- `markdownlint-cli2 .agents/templates/brief-template.md` passes

## Tier

Selected tier: `tier:standard`

Ref #19808
