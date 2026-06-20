<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# aidevops GUI control plane

This document is the canonical product memory for the aidevops GUI/control
plane. ADRs under `docs/gui/` record decisions that should not be re-litigated
by implementation workers without a new ADR.

## Product scope

The control plane is the primary visual surface for setting up, understanding,
managing, and scaling aidevops across local machines, Cloudron, git platforms,
infrastructure providers, routines, and AI-agent workflows.

The first usable product remains local-first:

- It must run without signing, VPN access, or a hosted aidevops service.
- It must not centralise secrets or make a remote control plane mandatory.
- It uses aidevops helper scripts and git platforms as sources of truth instead
  of duplicating orchestration state.
- It starts read-only for setup/status insight before adding write actions.

## Phase roadmap

1. Product, stack, and repo-layout ADR.
2. Security threat model and trust-boundary ADR.
3. Data model and infrastructure graph ADR.
4. Helper/API contract.
5. GUI testing and CI/CD strategy.
6. Local read-only API and dashboard scaffold.
7. Setup/status, repos/Git, infrastructure, provider bookmarks, routines,
   CalDAV/CardDAV, and capability browser surfaces.
8. Cloudron package.
9. Multi-machine pairing and scoped task capsules.
10. OpenCode session/chat UI and desktop wrapper.

## Current architecture decisions

- ADR 0001 chooses a Vite React web app, Hono local API, and SQLite-first local
  storage for the first scaffold.
- First code should land in this repository as staged package subtrees, not as a
  separate repository and not as new root-level ad hoc app files.
- Future phases that introduce new top-level directories must update
  `.agents/configs/repo-layout-policy.conf` before adding those paths.

## Implementation gates

- Coding may begin in Phase 6 after ADRs for product/stack, threat model, data
  model, helper/API contract, and testing/CI strategy are complete.
- Write actions remain gated on explicit trust-boundary documentation, helper
  contracts, and tests for destructive-operation safeguards.
- Cloudron packaging, machine pairing, and desktop packaging remain later-phase
  deliverables, not prerequisites for first local use.
