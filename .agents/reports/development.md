---
description: Development, delivery, code quality, and incident report routing
agent: Reports
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Development Reports

Use this doc for engineering status, release readiness, quality audits, incident
reviews, CI reports, performance reviews, and delivery retrospectives. Route code
analysis and remediation to development workflows; this doc keeps reports
evidence-backed and handoff-ready.

## Domain Routing

- Use `/full-loop` or `workflows/feature-development.md` for implementation
  follow-up, not for report-only analysis.
- Use `workflows/pr.md`, `workflows/pr-loop.md`, and
  `reference/review-bot-gate.md` for PR review and merge-readiness reporting.
- Use `workflows/preflight.md`, `workflows/postflight.md`, and
  `reference/ci-gate-policy.md` for quality gate reporting.
- Use `tools/browser/pagespeed.md`, `workflows/ui-verification.md`, and
  `tools/git/conflict-resolution.md` when those evidence types apply.
- Use `reference/worker-diagnostics.md` for worker failure, stall, loop, or CI
  diagnosis reports.

## Report Sections

1. Scope: repo, branch, issue/PR, release, service, or incident window.
2. Summary: current state, risk, decision needed, and recommended next action.
3. Evidence: commits, diffs, checks, logs, screenshots, metrics, or traces.
4. Findings: defects, regressions, operational risks, and confirmed non-issues.
5. Remediation plan: worker-ready tasks with target files and verification.
6. Verification: commands run, terminal check status, and remaining gaps.
7. Appendix: raw command outputs, CI links from tool output, and source IDs.

## Evidence Rules

- Distinguish terminal failed checks from pending or expected CI.
- Avoid unverifiable performance claims; include metric, tool, date, and scope.
- Cite file paths and line numbers for code findings.
- Cite PR, issue, commit, check, or command output for delivery claims.
- Convert broad recommendations into follow-up tasks only when worker-ready.

## Export Notes

- Keep Markdown canonical for review and diffability.
- Use `reports/exporters.md` for HTML/PDF handoff only after the report passes
  citation and privacy checks.
- Use `tools/design/report-presentation.md` for risk tables, timelines,
  evidence badges, screenshots, and print-safe incident appendices.
