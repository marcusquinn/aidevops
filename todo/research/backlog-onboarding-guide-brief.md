<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
<!-- aidevops:brief-schema=v2 -->

## What

Remove the unsupported `augment` setup guide from the two advertised guide lists.

## Why

Residual verification after framework audit #33139 found that
`.agents/scripts/onboarding-helper.sh` advertises `augment`, but `show_guide`
has no matching case or implementation. Users are sent back to the guide list.
Unrelated vendor URLs, migration history and MCP-audit patterns are not defects
and must remain unchanged.

## Reproducer

- Symptom command: `bash .agents/scripts/onboarding-helper.sh guide augment`.
- Actual: the fallback guide list advertises `augment` again instead of showing
  a guide; `show_guide` has no `augment` case. The `help` service list also
  advertises this unsupported guide.
- Expected: both advertised lists omit the retired guide and retain all
  implemented cases.

## How

Edit only the fallback guide list in `show_guide` and the service list in
`show_help`. Use their existing comma-separated format; remove only `augment,`
and its following space.
Do not restore a retired integration or refactor the helper.

## Acceptance Criteria

- Both CLI lists match the existing supported guide cases and omit Augment.
- `bash .agents/scripts/onboarding-helper.sh help` and `guide unknown` display
  supported services; `guide github` still displays its normal setup guide.
- `shellcheck .agents/scripts/onboarding-helper.sh` and `bash -n` pass.

## Files Scope

- EDIT: .agents/scripts/onboarding-helper.sh

## Verification

Use the normal CLI commands above. No new test infrastructure, configuration,
credential operations, integration removal, or unrelated references are needed.
