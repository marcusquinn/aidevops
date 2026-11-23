---
description: Checklist for setting up a new Cloudron package repository for aidevops automation
mode: reference
tools:
  read: true
  bash: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Cloudron Package Repository Onboarding

Complete this when a package repository is created, and use it to audit existing
packages. A repository registered by `aidevops repos add` or auto-discovery,
without `aidevops init`, misses most of it silently. In November 2026 one package
had Pulse off, no aidevops labels, no `cloudron_package` entry and missing
managed workflows, so its `auto-dispatch` tasks never ran and a new upstream
release went unnoticed. This adds Cloudron steps to the general
`reference/repo-onboarding.md`; complete its secrets and event policy steps too.
Apply the baseline rulesets in `cloudron-app-publishing-skill.md`. If you also
require pull requests and checks, catalog publication needs an admin bypass
actor and `CLOUDRON_RELEASE_PAT` with this repository added to the token's
selected access. A dry-run push with the token proves that access.

1. **Initialize:** run `aidevops init` in a linked worktree of the package and
   merge the result. It writes `.aidevops.json`, the release and catalog callers
   and `app_type: cloudron-package`, and syncs the canonical GitHub labels.
2. **Automation:** run `aidevops repos maintenance on <slug>`, then
   `aidevops repos pulse on <slug>`. The `repos.json` entry must show
   `pulse: true`, `maintenance: true` and `app_type: "cloudron-package"`;
   otherwise `auto-dispatch` issues are never picked up, and the upstream and
   compatibility routines skip the package.
3. **Upstream monitoring:** set `cloudron_package.upstream_slug`,
   `upstream_source` (`releases`, `tags` or `commits`), `monitor_upstream: true`
   and, when needed, `upstream_tag_prefixes`
   (`reference/repos-json-fields.md`). Check with
   `cloudron-package-monitor-helper.sh upstream`, which only reports and scans
   every registered package. For this package, a newer upstream prints
   `FINDING <slug>` or, when its issue exists, `Already handled in <slug>`.
   Silence is not proof: an up-to-date package and a package skipped for
   missing `app_type`, `maintenance: false` or no `upstream_slug` both print
   nothing, so confirm steps 1–3 in `repos.json` first.
4. **Labels and workflows:** if init warned about labels, run
   `label-sync-helper.sh sync --repo <slug>`. Run `aidevops check-workflows`,
   then `sync-workflows-helper.sh --repo <slug> --workflow <name> --install-missing`
   (dry run first, then `--apply`) for missing managed callers such as
   `linked-issue-check` and `issue-triage-gate`.
5. **Listing metadata:** set `packagerUrl` to the maintainer profile and
   `packageUrl` to the package repository (Cloudron 10+ catalogs only), and
   assert both in the package test. ca.cloudron.io links "By" to `packagerUrl`
   and Package to `packageUrl`. For the Cloudron 9.x trade-off, see
    `cloudron-app-publishing-skill.md`.

## Automated audit

`cloudron-package-monitor-helper.sh setup` audits registration (`app_type`,
`.aidevops.json`, maintenance, pulse), `cloudron_package.upstream_slug` and
`monitor_upstream`, and the `auto-dispatch` label for every registered repository
whose configured manifest (default `CloudronManifest.json`) exists, including
those missing `app_type` or with maintenance off. It does not validate managed
workflows or listing metadata; check those separately, so empty output does not
mean onboarding is complete. It is report-only, prints
`SETUP <slug>: <gap>; fix: <command>` per gap, and never creates issues or edits
files. The weekly `compatibility` routine runs it first. The compatibility check
also reports `packagerUrl` equal to `packageUrl`, and registration warns when a
package has no `cloudron_package.upstream_slug`.
