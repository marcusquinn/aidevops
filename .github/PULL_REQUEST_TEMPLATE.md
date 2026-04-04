<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

## Summary

Brief description of changes.

## Type of change

- [ ] Bug fix
- [ ] New feature
- [ ] Documentation
- [ ] Refactor

## Runtime Testing

**Testing level** (select one):

- [ ] `runtime-verified` — dev environment started, smoke/stability checks passed
- [ ] `self-assessed` — logic reviewed, no runtime available (docs, config, shell scripts)
- [ ] `untested` — not tested (explain why below)

**Test results** (fill in for runtime-verified; N/A for others):

| Check | Result | Notes |
|-------|--------|-------|
| Dev environment started | pass / fail / N/A | |
| Smoke pages loaded | pass / fail / N/A | |
| Stability check (no reload loops) | pass / fail / N/A | |
| Key user flow | pass / fail / N/A | |

**Escalation warnings** (check all that apply — these require runtime-verified level):

- [ ] Contains polling or reload logic
- [ ] Touches payment, auth, or session handling
- [ ] Modifies database schema or migrations
- [ ] Changes environment variables or secrets handling
- [ ] Affects production deploy or release pipeline

**Justification if untested or escalation warnings present:**

<!-- Explain why runtime verification was not possible, or describe manual verification steps taken for escalation-flagged patterns. -->

## Checklist

- [ ] I have followed the commit message conventions
- [ ] I have updated documentation if needed
- [ ] For architectural changes or new integrations, I have obtained maintainer approval (see [CONTRIBUTING.md](../CONTRIBUTING.md#scope-of-contributions))
