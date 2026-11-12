## What

Add a "New package repository checklist" to the Cloudron packaging guide so new package repositories get initialized, enabled for dispatch, monitored for upstream releases, given managed labels and workflows, and published with correct listing metadata.

## Why

cloudron-orbit-app was registered without `aidevops init` (no `.aidevops.json`). It ended up with Pulse off, no aidevops labels, no `app_type`/`cloudron_package` entry, no upstream monitoring and missing managed workflows, so an `auto-dispatch` task there could never run and upstream Orbit v0.3.0 went unnoticed. Each gap was fixed by hand on 2026-11-11; the guide had no checklist naming these steps.

## How

### Files Scope

- `.agents/tools/deployment/cloudron-package-onboarding.md`
- `.agents/tools/deployment/cloudron-app-packaging.md`
- `.agents/tools/deployment/cloudron-app-publishing-skill.md`

## Acceptance Criteria

- [ ] `cloudron-package-onboarding.md` has a numbered checklist covering init, maintenance/Pulse, `cloudron_package` upstream config with a report-only monitor check, labels/workflows, and `packagerUrl`/`packageUrl`.
- [ ] The packaging guide and publishing skill both link to it, and the packaging guide stays under the 500-line Markdown limit.
- [ ] `markdownlint-cli2` passes on the three files.

## Follow-ups

Deterministic checks (registry setter, unconfigured-package audit, manifest URL validation) are filed as separate auto-dispatch tasks.
