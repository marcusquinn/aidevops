# Verification Queue

Post-merge verification for completed tasks. Entries are auto-appended by the supervisor
after PR merge. Verification workers run the `check:` directives and mark pass `[x]` or
fail `[!]`. Failed verifications reopen the original task in TODO.md.

## Format

```text
- [ ] vNNN tNNN Description | PR #NNN | merged:YYYY-MM-DD
  files: path/to/changed/file1, path/to/changed/file2
  check: shellcheck .agents/scripts/script-name.sh
  check: file-exists .agents/tools/category/subagent.md
  check: rg "pattern" .agents/subagent-index.toon
  check: bash tests/test-name.sh
```

## States

- `[ ]` — pending verification
- `[x]` — verified, deliverables confirmed working (verified:YYYY-MM-DD)
- `[!]` — verification failed, task reopened (failed:YYYY-MM-DD reason:description)

## Queue

<!-- VERIFY-QUEUE-START -->

- [x] v001 t168 /compare-models commands | PR #660 | merged:2026-02-08 verified:2026-02-08
  files: .agents/scripts/commands/compare-models.md
  check: file-exists .agents/scripts/commands/compare-models.md

- [x] v002 t120 Agent Device subagent | PR #665 | merged:2026-02-08 verified:2026-02-08
  files: .agents/tools/mobile/agent-device.md, .agents/AGENTS.md, .agents/subagent-index.toon
  check: file-exists .agents/tools/mobile/agent-device.md
  check: rg "agent-device" .agents/subagent-index.toon

- [x] v003 t133 Cloud GPU deployment guide | cherry-picked:301b86c1 | merged:2026-02-08 verified:2026-02-08
  files: .agents/tools/infrastructure/cloud-gpu.md
  check: file-exists .agents/tools/infrastructure/cloud-gpu.md

- [x] v004 t073 Document Extraction subagent + helper | PR #667 | merged:2026-02-08 verified:2026-02-08
  files: .agents/scripts/document-extraction-helper.sh, .agents/tools/document/extraction-workflow.md, .agents/tools/document/document-extraction.md
  check: file-exists .agents/scripts/document-extraction-helper.sh
  check: file-exists .agents/tools/document/extraction-workflow.md
  check: shellcheck .agents/scripts/document-extraction-helper.sh
  check: rg "document-extraction" .agents/subagent-index.toon

- [x] v005 t175 Git heuristic signals for evaluator | PR #655 | merged:2026-02-08 verified:2026-02-08
  files: .agents/scripts/supervisor-helper.sh
  check: rg "Tier 2.5: Git heuristic" .agents/scripts/supervisor-helper.sh

- [x] v006 t176 Uncertainty decision framework | PR #656 | merged:2026-02-08 verified:2026-02-08
  files: .agents/scripts/commands/full-loop.md, .agents/scripts/supervisor-helper.sh, .agents/tools/ai-assistants/headless-dispatch.md
  check: rg "Uncertainty decision framework" .agents/scripts/commands/full-loop.md
  check: rg "PROCEED autonomously" .agents/scripts/commands/full-loop.md

- [x] v007 t177 Integration tests for dispatch cycle | PR #658 | merged:2026-02-08 verified:2026-02-08
  files: tests/test-supervisor-state-machine.sh
  check: file-exists tests/test-supervisor-state-machine.sh

- [x] v008 t178 Fix cmd_reprompt missing worktrees | PR #659 | merged:2026-02-08 verified:2026-02-08
  files: .agents/scripts/supervisor-helper.sh
  check: rg "cmd_reprompt" .agents/scripts/supervisor-helper.sh

- [x] v009 t166 Daily CodeRabbit review pulse | PR #657 | merged:2026-02-08 verified:2026-02-08
  files: .agents/scripts/review-pulse-helper.sh, .github/workflows/review-pulse.yml, .agents/tools/code-review/coderabbit.md
  check: file-exists .github/workflows/review-pulse.yml
  check: file-exists .agents/scripts/review-pulse-helper.sh

<!-- VERIFY-QUEUE-END -->
