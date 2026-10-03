## Summary

Resolves #32622

Trim only known illustrative examples from built-in Bash, Task and TodoWrite
descriptions through the existing public definition adapter. Preserve all
surrounding workflow/safety rules, tool names, schemas and permission enforcement.
Revised upstream text falls through unchanged; repeated trims are idempotent.

## Scope and keep/cut decisions

- `.agents/plugins/opencode-aidevops/tool-definition.mjs:23-73`: literal-only
  replacements, following the existing directory-guidance adapter.
- `.agents/plugins/opencode-aidevops/tests/test-tool-definition.mjs`: exact trim,
  specificity, unknown-text, schema and repeated-block regression coverage.
- OC1 retains both adapter registrations. Existing OC2 Bash adaptation receives
  applicable trims; no speculative Task/TodoWrite exposure is introduced.

| Tool | Removed example-only material | Rules retained |
|---|---|---|
| Bash | Four mkdir/python quoting examples | Full quoting rule and remaining inline rm example |
| Bash | Parenthetical mkdir/cp, Write/Bash and git sequencing examples | Dependency/sequential-execution rule and its full surrounding sentence |
| Bash | good/bad workdir demonstrations | Full prohibition on cd-and-command and the workdir instruction |
| Task | Parenthetical research/verification examples | Explicit code-versus-research intent and verification directions |
| TodoWrite | Six examples | Every use/skip condition, state, update rule and “When in doubt” instruction |

No safety, permission or Git-safety sentence is removed. Other tools and the
dynamic agent catalogue are unchanged.

## Live measurements

Parent ran the existing isolated context-budget capture path on OpenCode
**1.18.34**, **claude-sonnet-5-5**, Build+, identical project, prompt and two-turn
flow; framework version **3.38.0**. No real configuration/deployment changes or
credential/header capture. Candidate dependencies were linked temporarily by the
existing helper and removed on exit.

| Measurement | Control | Candidate | Reduction |
|---|---:|---:|---:|
| Bash description characters | 5,234 | 4,716 | 518 |
| Task description characters | 4,018 | 3,947 | 71 |
| TodoWrite description characters | 2,012 | 1,531 | 481 |
| Total serialized tool characters | 33,083 | 31,972 | 1,111 |
| API first-prompt tokens: input + cache read + cache write | 34,356 | 33,889 | **467** |
| Turn-1 cached prefix | 34,352 | 33,885 | — |
| Turn-2 cache read | **34,352** | **33,885** | — |

This is a measured paired API reduction, not character/4 estimation or a per-tool
token attribution. The skill catalogue varied by six characters between live
captures; every other context section was identical in size. The three tool
schemas are unchanged. Wire comparison reports **no changes**: two system blocks,
billing header and Claude Code identity, 20 tools, correct non-built-in prefixes,
intent on all 20 tools and unchanged cache-control layout. Both turn-2 reads
cover their entire turn-1 cached prefixes.

An initial Haiku probe stopped after the mandatory greeting and produced only
one request. It is excluded from cache acceptance evidence; the matched Sonnet
control/candidate flow above performed the required tool call.

## Runtime Testing

- **Risk level:** Low — stateless description-only transformation.
- **Verification:** runtime-verified through the live provider-bound capture;
  parent independently reran the seven focused tests, syntax and changed-file
  lint. All passed; historical secret-policy marker warnings are not regressions.
- Parent reviewed both commits and all removal/replacement literals. No text
  supporting permissions or Git safety is deleted.
- Exact verified head: `6194242cf8d77d4ac91893aff237508bbe7b7a58`.

<!-- aidevops:origin:worker -->
