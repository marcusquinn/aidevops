<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# GUI testing and CI/CD strategy

## Status

Accepted for scaffold planning. This strategy defines the verification contract
for the first read-only GUI/API scaffold and the path for later Cloudron and
desktop release gates.

## Goals

- Give implementation workers exact local commands for the scaffold phase.
- Keep unrelated shell/framework and docs-only PRs fast.
- Separate required, advisory, and release-only GUI checks.
- Prove secret redaction and trust-boundary rules before write actions land.
- Leave clear upgrade points for Cloudron packaging and future Tauri desktop
  artifacts.

## Scope

The first GUI implementation follows the accepted control-plane decisions:

- `packages/gui-web/` contains the Vite React UI.
- `packages/gui-api/` contains the Hono local API.
- `packages/gui-shared/` contains schemas, contracts, fixtures, and shared
  policy models.
- `cloudron/` is added only when the Cloudron package phase begins.
- `packages/gui-desktop/` is added only when the Tauri wrapper phase begins.

The initial scaffold is local-first and read-only. Browser code never receives
raw secret values, helper command strings, or direct shell authority.

## Local test layers

### Schema and unit tests

`packages/gui-shared` owns Zod schemas, JSON Schema/OpenAPI generation, API
client types, fixture types, and policy helpers. Required tests cover:

- resource and account models;
- secret-reference-only payloads;
- helper output normalization;
- action and route manifests;
- task-capsule and machine-pairing schemas once those models exist.

Scaffold command:

```bash
npm run gui:test:schema
```

### Adapter fixture tests

`packages/gui-api` must test aidevops helper adapters against checked-in
fixtures before any route calls real helpers. Fixtures model successful output,
expected warnings, missing tools, malformed output, timeout classes, and
redacted error paths.

Scaffold command:

```bash
npm run gui:test:adapters
```

Adapter tests must assert exact argument vectors. They must not execute browser
provided command strings, helper names, working directories, environment values,
or install commands.

### API route tests

Every route in `packages/gui-api` needs request/response tests. Required read
route coverage includes status, repos, capabilities, settings health, routine
summaries, secret backend status, and OpenCode/session summaries when present.

Scaffold command:

```bash
npm run gui:test:api
```

API tests must prove:

- unknown routes, unknown action IDs, and unknown parameters are rejected;
- raw shell syntax and arbitrary helper names are rejected;
- secrets are returned as names, references, health, and non-sensitive error
  classes only;
- high-risk or destructive actions fail closed until an action manifest,
  confirmation, audit, and dry-run pattern exists.

### Component tests

`packages/gui-web` owns component tests for setup/status, infrastructure graph,
provider catalog, routines, session summaries, capability browser, empty states,
and warning states.

Scaffold command:

```bash
npm run gui:test:components
```

Component tests should use API/client fixtures rather than live helpers. They
must check that secret values, private key material, raw credential files, and
untrusted HTML are not rendered.

### Browser smoke tests

Browser smoke tests verify that the local dashboard boots, shows read-only
status, navigates core routes, and handles degraded helper states.

Scaffold command:

```bash
npm run gui:test:smoke
```

Smoke tests are required only for GUI path PRs after the first runnable scaffold
exists. Broader visual and end-to-end suites remain advisory until they are fast
and stable enough to gate ordinary development.

### Security and redaction tests

Security regression coverage is required from the first scaffold. The shared,
API, and web packages should include fixtures containing sentinel values such as
`SECRET_SENTINEL_DO_NOT_RENDER`, fake private keys, fake bearer tokens, fake
cookie strings, and credential-file-like content.

Scaffold command:

```bash
npm run gui:test:security
```

The command must fail if a sentinel appears in:

- API responses;
- serialized UI state;
- rendered component output;
- adapter logs;
- audit records;
- downloadable or exported artifacts.

It also verifies the trust-boundary bans from ADR 0002: no arbitrary shell
route, no browser-selected helper executable, no browser-provided environment,
no raw issue/PR body execution, and no Cloudron-to-local direct command bridge.

### Cloudron package checks

Cloudron checks start once `cloudron/` exists. Before that path exists, CI must
skip Cloudron jobs rather than failing unrelated GUI scaffold PRs.

Local command after `cloudron/` lands:

```bash
npm run gui:cloudron:check
```

Required coverage once active:

- `CloudronManifest.json` validation;
- Dockerfile lint/build smoke where runner capacity allows;
- start script shell lint;
- no bundled secret values or local machine execution credentials;
- health endpoint and backup/restore path documentation checks.

### Desktop package checks

Desktop checks start once `packages/gui-desktop/` exists. They are release-only
until signing, notarization, and auto-update channels are introduced.

Local command after the desktop wrapper lands:

```bash
npm run gui:desktop:check
```

Release verification must cover:

- Tauri config validation;
- sidecar/API launch policy;
- signed update metadata;
- checksums and provenance for produced artifacts;
- platform-specific signing/notarization evidence where applicable;
- no secret values in logs, crash reports, or artifacts.

## Scaffold command contract

The first implementation PR that creates GUI packages must add these root-level
npm scripts and document their package-manager equivalent if the workspace uses
something other than npm:

```bash
npm run gui:lint
npm run gui:typecheck
npm run gui:test:schema
npm run gui:test:adapters
npm run gui:test:api
npm run gui:test:components
npm run gui:test:security
npm run gui:test:smoke
npm run gui:build
npm run gui:ci
```

`npm run gui:ci` is the required local pre-PR contract for GUI code changes. For
the scaffold phase it expands to lint, typecheck, schema/unit, adapter fixture,
API route, component, security/redaction, smoke, and production build checks.
Cloudron and desktop commands are added to `gui:ci` only after their paths exist
and their jobs are stable enough to gate GUI changes.

Documentation-only changes under `docs/gui/` use the repository markdown checks
and do not require TypeScript jobs unless they modify runnable examples or test
fixtures.

## CI path filters

GUI CI should run separately from existing framework shell and documentation
jobs. The path filters below define when GUI-specific jobs start:

| Path | Required GUI jobs |
|------|-------------------|
| `packages/gui-shared/**` | lint, typecheck, schema/unit, security, build |
| `packages/gui-api/**` | lint, typecheck, adapter, API, security, build |
| `packages/gui-web/**` | lint, typecheck, component, security, smoke, build |
| `packages/gui-desktop/**` | desktop check, build, release checks when tagged |
| `cloudron/**` | Cloudron package check and security checks |
| `docs/gui/**` | markdown only unless examples or fixtures are executable |
| `.github/workflows/*gui*` | full GUI CI matrix |
| `package.json`, lockfiles, workspace config | full GUI CI matrix |

Unrelated `.agents/scripts/**`, workflow docs outside `docs/gui/**`, shell-only
helpers, and planning-only changes should keep using the existing framework CI
without running GUI package jobs unless shared workspace metadata changes.

## Required, advisory, and release-only checks

### Required for GUI code PRs

- Formatting/lint for touched GUI packages.
- TypeScript typecheck.
- Schema/unit tests for shared contracts.
- Adapter fixture tests for helper boundaries.
- API route tests for touched routes.
- Component tests for touched UI surfaces.
- Security/redaction sentinel tests.
- Browser smoke tests after the first runnable dashboard exists.
- Production build for touched GUI packages.

### Advisory for ordinary development

- Full browser E2E across every product area.
- Visual regression screenshots.
- Accessibility audits beyond smoke-level assertions.
- Docker image builds before `cloudron/` is active.
- Cross-platform desktop builds before a release lane exists.

Advisory failures create follow-up issues unless they identify a defect in the
PR's changed code or a release gate regression.

### Release-only checks

- Full E2E and visual regression suites for release/staging branches.
- Cloudron image build, health smoke, backup/restore proof, and manifest checks.
- Desktop signing/notarization, update metadata, checksums, and provenance.
- Artifact redaction scans for packaged web, Cloudron, and desktop outputs.

Release workflows publish artifacts only after required tests pass and artifact
checksums/provenance are produced. Auto-update artifacts must be signed before
publication.

## Artifact policy

Ordinary PRs may upload short-lived test artifacts such as coverage summaries,
Playwright traces, and build logs. They must not upload app bundles, Cloudron
images, desktop installers, secret-bearing fixture outputs, raw helper logs, or
machine-local config snapshots.

Release workflows may publish web bundles, Cloudron images/catalog metadata, and
desktop installers only when the release lane has:

- passed the required and release-only checks for the artifact type;
- scanned produced files for redaction sentinels and credential patterns;
- produced checksums and provenance;
- attached signing/notarization evidence when the artifact type requires it.

## Acceptance contract for scaffold workers

The first scaffold PR is acceptable when it provides:

- package paths matching ADR 0001 and the repo-layout policy update that permits
  those paths;
- the root scripts listed in the scaffold command contract;
- path-scoped CI that avoids GUI jobs for unrelated shell/framework PRs;
- at least one fixture-backed adapter test;
- at least one API route test proving secret-reference-only responses;
- at least one component test proving sentinel secret values are not rendered;
- a security/redaction test that scans API, UI, log, and artifact-like outputs;
- documentation stating which jobs are required, advisory, and release-only.

Cloudron package checks are accepted when `cloudron/` exists and validates the
manifest, image build path, start script, health endpoint, backup/restore notes,
and absence of bundled secret values. Desktop package checks are accepted when
`packages/gui-desktop/` exists and verifies Tauri config, sidecar/API policy,
signing/update metadata, checksums, and artifact redaction.
