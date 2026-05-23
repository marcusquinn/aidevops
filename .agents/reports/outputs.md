---
description: Repo-local _reports artifact layout and privacy contract
agent: Reports
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Report Output Contract

`_reports/` is the repo-local data plane for generated report outputs. It keeps
report drafts, published artifacts, indexes, local configuration, and templates
out of the repository root while giving automation a stable path contract.

## Directory Contract

| Path | Purpose | Default git policy |
|------|---------|--------------------|
| `_reports/drafts/` | Work-in-progress report runs and review copies. | Gitignored |
| `_reports/published/` | Final report bundles ready for sharing or archival. | Gitignored |
| `_reports/index/` | Generated search, catalogue, and lookup indexes. | Gitignored |
| `_reports/_config/` | Repo-local report configuration and private options. | Gitignored |
| `_reports/examples/` | Reviewed reusable report examples generated from canonical Markdown and DESIGN.md styles. | Versioned |
| `_reports/sample/` | Full sample reports that demonstrate end-to-end report anatomy and supplementary appendix links. | Versioned |

## Artifact Contract

- `report.md` is the canonical source for each report.
- HTML, PDF, screenshots, archives, and other exports are derived artifacts.
- Regenerate derived artifacts from `report.md` rather than editing them by hand.
- Keep generated drafts, published bundles, and indexes out of git unless a
  maintainer explicitly promotes a small fixture or template for review.
- Do not call versioned report examples “templates”; templates are produced from
  the DESIGN.md standard and related design agents, while `_reports/examples/`
  shows generated examples using those templates.

## Privacy Rules

Public reports must not expose private local paths, private repository names, or
machine-specific filesystem details. Use placeholders when a path, repo name, or
environment detail would identify private infrastructure.
