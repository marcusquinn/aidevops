---
description: React Doctor advisory quality checks for React, Next.js, and React Native
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

# React Doctor

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Use when**: reviewing React, Next.js, or React Native changes for correctness, state/effects, accessibility, security, performance, architecture, or dead code risks.
- **Default posture**: advisory-first. Treat findings as review signals until the project baseline, false positives, and suppressions are triaged.
- **Local scans**: prefer staged or diff-limited scans during implementation so feedback matches the change under review.
- **CI scans**: pin React Doctor versions and action refs; use annotations/comments before enforcing failures.

<!-- AI-CONTEXT-END -->

## When To Run

Run React Doctor on React-family projects when a change touches components, hooks, state/effect logic, shared UI packages, accessibility behaviour, rendering performance, or dead-code cleanup. It is especially useful before PR creation when normal lint/type checks pass but a React-specific quality review is still valuable.

Do not run it for non-React projects, docs-only changes, or framework code where installing project tooling would add risk or noise.

## Local Workflow

- Use staged or diff mode when available so the scan focuses on the current change instead of historical project debt.
- Keep the normal project gates first: typecheck, lint, tests, and browser verification still own correctness for the implemented fix.
- Review findings manually before editing. Do not apply automated suggestions verbatim.
- Capture unrelated baseline findings as follow-up tasks instead of expanding the PR scope.

## CI Workflow

- Pin the React Doctor CLI or GitHub Action version in CI. Avoid floating tags and malformed action refs such as missing owner/repo, missing `@version`, or shell commands embedded where an action ref is expected.
- Start CI usage as advisory annotations or PR comments so teams can evaluate signal quality without blocking unrelated work.
- Do not make React Doctor a hard required gate until baseline findings are triaged, intentional suppressions are documented, and the team has verified the check is stable on representative PRs.
- If enabling a blocking gate later, scope it to changed files or new findings where possible.

## Interpreting Findings

Prioritise findings that identify defects introduced by the current change: invalid hook usage, stale effects, unsafe rendering paths, inaccessible controls, security-sensitive data exposure, or performance regressions on hot paths.

Treat broad architecture, dead-code, or style findings as advisory unless they are directly caused by the PR. Convert valuable but out-of-scope items into worker-ready follow-up tasks with file paths, finding text, and the verification command used.

## Related

- `tools/ui/ui-skills.md` -- implementation constraints for accessible, performant UI.
- `tools/ui/frontend-debugging.md` -- browser verification and React hydration debugging.
- `workflows/full-loop.md` -- PR loop completion and verification gates.
