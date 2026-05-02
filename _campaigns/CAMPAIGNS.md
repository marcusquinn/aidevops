# _campaigns/ — Campaigns Plane

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

This plane stores marketing, advertising, outreach, and launch work with a
campaign-specific lifecycle: research, creative, review, distribution,
measurement, and learnings.

## Tracked seed surface

- `_config/campaigns.json` — sensitivity, LLM, blob, and cross-plane defaults.
- `lib/` — reusable public-safe brand, swipe, and asset-manifest placeholders.
- `launched/` — versioned post-launch campaigns, added when real campaigns go
  live.

## Git policy

Competitive intel and active campaign work stay local by default:

- `intel/` is ignored because competitive research is sensitive.
- `active/` is ignored because in-flight creative can contain confidential
  strategy.
- `index/` is ignored because it is generated.

Promote only reviewed, public-safe launched assets into git.

See `.agents/aidevops/campaigns-plane.md` for the full contract.
