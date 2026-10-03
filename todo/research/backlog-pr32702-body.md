<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

Resolves #32644

## Outcome

The brief explicitly permits reporting usage without changing code when no eligible
registered tool meets the threshold. Keep the existing dispatcher list. The earlier
attempt to add native session-title names did not defer them and is removed; no
API-token saving is claimed for that ineffective change.

## Measured selection

Read-only 30-day session-use measurement on 2026-10-03: 2,010 active sessions.

| Tool | Sessions | Percent | Disposition |
|---|---:|---:|---|
| ai-research | 119 | 5.920 | Above 2% |
| aidevops | 175 | 8.706 | Above 2% |
| aidevops_bounded_operation | 734 | 36.517 | Above 2% |
| aidevops_hook_status | 289 | 14.378 | Above 2% |
| aidevops_mcp | 104 | 5.174 | Above 2%; agent-gated |
| aidevops_memory | 1,169 | 58.159 | Mandatory recall |
| aidevops_pre_edit_check | 486 | 24.179 | Mandatory safety step |
| session-rename | 245 | 12.189 | Above 2%; native registration |
| session-rename_sync_branch | 33 | 1.642 | Native registration, not in baseTools |

`moveToolsOnDemand` operates on the plugin's `baseTools`; `.opencode/tool/`
exports are registered separately. Names absent from that map are ignored.
Changing their list membership would therefore not remove their tool definitions.
The documentation adds the reproducible distinct-session query, correctly comparing
ISO UTC timestamps rather than SQLite's space-separated datetime format.

## Provider-native deferral

Do not enable provider-native deferral here. OpenCode 1.18.34's reviewed
`packages/opencode/src/session/llm/native-request.ts` normalizes the tool record
to its native `ToolDefinition[]` and selects the Anthropic/OpenAI transports;
the exported plugin/SDK 1.18.33 interfaces do not supply a provider-native
deferred-tool registration capability. The existing plugin dispatcher remains
the verified route. This establishes the host integration boundary, not a claim
that either provider API can never support deferred tools.

## Verification

- `node --test .agents/plugins/opencode-aidevops/tests/test-on-demand-tools.mjs`: 9/9 pass.
- Existing checks on exact head `9e0698c2b5e37f277dd1db569eed8342ab56ef2e`: terminal success.
- Production tool registry and test enumeration are unchanged from current main.
- No candidate tool-registration change remains, so no new paired capture or
  zero-token measurement is fabricated. The separately merged #33439 capture
  measured 467 fewer API tokens and is not credited to this PR.

## Files and reference pattern

Only `.agents/reference/context-budget.md` differs from main. Reference:
`moveToolsOnDemand` in `.agents/plugins/opencode-aidevops/on-demand-tools.mjs`
and native exports under `.opencode/tool/`. Re-run the documented read-only query
and existing on-demand test for future selection decisions.

## Runtime Testing

Documentation-only; existing dispatcher runtime tests pass. No transport,
OAuth identity, billing header, tool prefix, intent field, or cache prefix changes.
