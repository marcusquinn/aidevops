<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18070: Design Secrets interface and repair Vault unlock readiness

## Pre-flight

- [x] Memory recall: `aidevops.app secrets interface vault passphrase unlock` → no relevant lessons
- [x] Discovery pass: 60+ recent GUI/Vault commits, no merged or open related PR reported by prework discovery
- [x] File refs verified: 14 target and reference files inspected at `193312e51`
- [x] Tier: `tier:thinking` — security boundary, native bridge, shell runtime, API state, and interface design span multiple packages
- [x] Seeded draft PR decision recorded: skipped — implementation remains in this claimed interactive full-loop worktree

## Origin

- **Created:** 2026-07-10
- **Session:** OpenCode interactive session
- **Created by:** ai-interactive
- **Conversation context:** The user supplied the current locked Secrets screenshot, requested a designed and implemented Secrets section, and reported that Unlock asks for a new passphrase after one was already saved.

## What

Deliver a security-first Secrets workspace for locked, unavailable, recovery, and unlocked Vault states. Correct Vault status probing so helper/dependency failures can never be interpreted as first-use setup, provide a functional native handoff to the existing hidden local terminal prompt, and provision the pinned crypto runtime required for real unlocks.

## Why

The current Secrets surface is a sparse generic gate. More critically, the local Vault helper fails because Python `cryptography` is absent; the API collapses that failure to `unknown`, the web classifier treats `!initialized` as setup, and an apparent Unlock action opens a create-passphrase prototype that never invokes an unlock operation. This erodes trust and leaves an existing Vault inaccessible from the product flow.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** This is a coordinated security/UX slice across React, API status parsing, a Bash/Python crypto runtime, setup, and the macOS wrapper. Explicit trust-boundary and fallback design is required.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** The active interactive session owns implementation and runtime verification; a separate seed would duplicate work.
- **Status:** `not-created`
- **Freshness evidence:** Discovery, local helper reproduction, and target-file reads were performed against current `origin/main`.
- **Verification run:** `aidevops vault status` and `setup-state` reproduced `ModuleNotFoundError: cryptography`; implementation checks pending.
- **Stale-assumption warning:** Recheck the live API and desktop process after setup because a stale GUI API process can preserve old contract behavior.

## How (Approach)

### Files to Modify

- NEW: `packages/gui-web/src/SecretsSurface.tsx` — state-specific, metadata-only Secrets workspace with safe aggregates and unlocked reference inventory.
- EDIT: `packages/gui-web/src/AppWorkspace.tsx`, `StatusSurfaces.tsx`, `VaultBadges.tsx`, `App.tsx`, `status-client.ts`, `styles.css` — route Secrets around the generic gate, use explicit Vault intents, refresh status after terminal handoff, and add responsive/a11y styling.
- RENAME/EDIT: `packages/gui-web/src/VaultPassphraseModal.tsx` — replace the non-functional browser passphrase collector with a secure terminal handoff and diagnostics/recovery dialog.
- NEW/EDIT: web/native bridge files and `packages/gui-desktop/scripts/install-macos-app.sh` — send only an allowlisted Vault action ID and map it natively to fixed `aidevops vault ...` commands.
- EDIT: `packages/gui-api/src/status-vault.ts`, `packages/gui-web/tests/component.test.ts`, `packages/gui-api/tests/status-adapter.test.ts` — preserve valid nonzero status output, fail closed on partial probes, and cover the state decision table.
- EDIT: `.agents/scripts/vault-helper.sh`, `.agents/scripts/vault_crypto_core.py`, `.agents/scripts/setup/modules/tool-install.sh`, `setup.sh`; NEW pinned Vault requirements file and focused tests — make reads side-effect free, surface missing runtime safely, and provision an isolated crypto environment.
- EDIT: `DESIGN.md` — record the Secrets information architecture and secret-value custody rules.

### Complexity Impact

- Existing large files (`StatusSurfaces.tsx` 489 lines, setup tool module 2663 lines) should not absorb the new interface/runtime logic. Extract new components/helpers and keep added shell functions below 80 lines with explicit returns.
- `vaultDialogIntentForStatus` and `readVaultCommand` remain small decision/probe functions; add decision-table tests rather than nested fallback branches.

### Implementation Steps

1. Model Vault action intent from authoritative enums: unlocked → lock, locked → unlock, authoritative uninitialized → setup, corrupted → recovery, all unknown/error/partial/loading paths → unavailable.
2. Normalize legacy/missing Vault payloads to unknown, disable automatic setup unless helper status and both state probes prove uninitialized, and parse allowlisted helper output for documented nonzero states.
3. Replace browser passphrase fields with an allowlisted native terminal handoff. Passphrases remain exclusively in the helper's local hidden TTY prompt; browser/API payloads remain metadata-only.
4. Add a compact Secrets hero, explicit value-custody boundary, safe aggregate cards, state-specific actions, unlock capabilities, and an accessible unlocked reference inventory without reveal/copy/value affordances.
5. Make Vault status/setup-state read-only and usable without crypto imports; add stable missing-runtime diagnostics for crypto operations. Provision an isolated exact-pinned runtime during setup and make the helper prefer it.
6. Add component, adapter, shell, setup, desktop bridge, security, responsive, and visual runtime checks. Verify real status transitions with synthetic temporary Vault data only.
7. Update `DESIGN.md`, commit through the full-loop wrapper, merge only after review/CI gates, patch-release, deploy with `setup.sh --non-interactive`, and recheck local Vault status.

### Verification

```bash
npm run gui:ci
shellcheck .agents/scripts/vault-helper.sh .agents/scripts/setup/modules/tool-install.sh setup.sh
bash -n .agents/scripts/vault-helper.sh .agents/scripts/setup/modules/tool-install.sh setup.sh
bash .agents/scripts/tests/test-vault-helper.sh
bash .agents/scripts/tests/test-vault-setup-flow.sh
git diff --check
```

Runtime verification must also cover desktop locked/unavailable/unlocked Secrets views, native terminal launch, return-focus status refresh, no passphrase fields or values in rendered HTML/API output, and a temporary synthetic Vault lock/unlock cycle.

## Acceptance Criteria

- [ ] An existing locked Vault always offers Unlock, never new-passphrase setup.
- [ ] Missing crypto/helper/legacy/timeout states show unavailable diagnostics with no passphrase fields and no setup action.
- [ ] The desktop Unlock action opens the fixed hidden-prompt terminal command; returning to the app refreshes status.
- [ ] Setup provisions an exact-pinned isolated crypto runtime and the Vault helper emits stable redacted errors if it is unavailable.
- [ ] Locked Secrets reveals no reference names; unlocked Secrets shows metadata and health only, with no value/reveal/copy path.
- [ ] The Secrets layout is responsive, keyboard accessible, and documented in `DESIGN.md`.
- [ ] GUI CI, focused Vault runtime/security tests, ShellCheck, syntax checks, and build pass.

## Context

- Preserve `docs/gui/adr-0002-trust-boundaries.md`: the browser is partially trusted and secret values remain in established secure storage/TTY flows.
- Preserve `docs/gui/threat-model.md`: native/API actions are typed and allowlisted; no browser-provided command string, path, environment, or shell fragment.
- Do not solve this by increasing a timeout alone, by adding `--force`, by accepting passphrases through HTTP/JavaScript, or by persisting any passphrase in browser/native state.
- The classifier called the request composite, but it remains one cohesive product slice because the misleading Secrets interface and helper-readiness state machine share the same lock/unlock acceptance path and release verification.
