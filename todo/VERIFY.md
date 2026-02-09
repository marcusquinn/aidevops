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

- [x] v010 t179 Issue-sync reconciliation | PR #677 | merged:2026-02-09 verified:2026-02-09
  files: .agents/scripts/issue-sync-helper.sh, .github/workflows/issue-sync.yml
  check: file-exists .agents/scripts/issue-sync-helper.sh
  check: rg "reconcile" .agents/scripts/issue-sync-helper.sh
  check: file-exists .github/workflows/issue-sync.yml

- [x] v011 t180 Post-merge verification worker phase | PR #679 | merged:2026-02-09 verified:2026-02-09
  files: .agents/scripts/supervisor-helper.sh, tests/test-supervisor-state-machine.sh
  check: rg "post_merge_verify\|verification" .agents/scripts/supervisor-helper.sh
  check: bash tests/test-supervisor-state-machine.sh

- [x] v012 t181 Memory deduplication and auto-pruning | PR #681 | merged:2026-02-09 verified:2026-02-09
  files: .agents/scripts/memory-helper.sh, tests/test-memory-mail.sh
  check: rg "dedup\|auto_prune\|consolidate" .agents/scripts/memory-helper.sh
  check: bash tests/test-memory-mail.sh

- [x] v013 t182 GHA auto-fix workflow safety | PR #684 | merged:2026-02-09 verified:2026-02-09
  files: .agents/scripts/monitor-code-review.sh, .github/workflows/code-review-monitoring.yml
  check: file-exists .agents/scripts/monitor-code-review.sh
  check: rg "validate\|auto.fix" .agents/scripts/monitor-code-review.sh

- [x] v014 t183 Fix supervisor no_log_file dispatch | PR #685 | merged:2026-02-09 verified:2026-02-09
  files: .agents/scripts/supervisor-helper.sh
  check: rg "no_log_file\|log_file" .agents/scripts/supervisor-helper.sh

- [x] v015 t184 Graduate memories to docs | PR #689 | merged:2026-02-09 verified:2026-02-09
  files: .agents/scripts/memory-graduate-helper.sh, .agents/scripts/commands/graduate-memories.md
  check: file-exists .agents/scripts/memory-graduate-helper.sh
  check: file-exists .agents/scripts/commands/graduate-memories.md
  check: shellcheck .agents/scripts/memory-graduate-helper.sh

- [x] v016 t185 Memory audit pulse | PR #691 | merged:2026-02-09 verified:2026-02-09
  files: .agents/scripts/memory-audit-pulse.sh, .agents/scripts/commands/memory-audit.md
  check: file-exists .agents/scripts/memory-audit-pulse.sh
  check: file-exists .agents/scripts/commands/memory-audit.md
  check: shellcheck .agents/scripts/memory-audit-pulse.sh

- [x] v017 t072 Audio/Video Transcription subagent | PR #690 | merged:2026-02-09 verified:2026-02-09
  files: .agents/scripts/transcription-helper.sh, .agents/tools/voice/transcription.md
  check: file-exists .agents/scripts/transcription-helper.sh
  check: file-exists .agents/tools/voice/transcription.md
  check: shellcheck .agents/scripts/transcription-helper.sh
  check: rg "transcription" .agents/subagent-index.toon

- [x] v018 t189 Worktree ownership safety | PR #695 | merged:2026-02-09 verified:2026-02-09
  files: .agents/scripts/shared-constants.sh, .agents/scripts/worktree-helper.sh
  check: rg "worktree_registry\|ownership" .agents/scripts/shared-constants.sh
  check: rg "in_use\|registry" .agents/scripts/worktree-helper.sh

- [x] v019 t188 Pre-migration safety backups | PR #697 | merged:2026-02-09 verified:2026-02-09
  files: .agents/scripts/shared-constants.sh, .agents/scripts/supervisor-helper.sh, .agents/scripts/memory-helper.sh, tests/test-backup-safety.sh
  check: rg "backup_sqlite_db\|verify_migration_rowcounts" .agents/scripts/shared-constants.sh
  check: file-exists tests/test-backup-safety.sh
  check: bash tests/test-backup-safety.sh

- [x] v020 t187 Compaction-resilient session state | PR #699 | merged:2026-02-09 verified:2026-02-09
  files: .agents/scripts/session-checkpoint-helper.sh, .agents/scripts/session-distill-helper.sh, .agents/prompts/build.txt
  check: rg "continuation\|auto.save" .agents/scripts/session-checkpoint-helper.sh
  check: rg "checkpoint" .agents/scripts/session-distill-helper.sh
  check: rg "Context Compaction Survival" .agents/prompts/build.txt

- [x] v021 t186 Development lifecycle enforcement | PR #700 | merged:2026-02-09 verified:2026-02-09
  files: .agents/AGENTS.md
  check: rg "MANDATORY: Development Lifecycle" .agents/AGENTS.md

- [x] v022 t190 Memory graduation markdown fix | PR #703 | merged:2026-02-09 verified:2026-02-09
  files: .agents/scripts/memory-graduate-helper.sh
  check: shellcheck .agents/scripts/memory-graduate-helper.sh

- [x] v023 t131 Create tools/vision/ category | PR #710 | merged:2026-02-09 verified:2026-02-09
  files: .agents/tools/vision/overview.md, .agents/tools/vision/image-generation.md, .agents/tools/vision/image-editing.md, .agents/tools/vision/image-understanding.md
  check: file-exists .agents/tools/vision/overview.md
  check: file-exists .agents/tools/vision/image-generation.md
  check: file-exists .agents/tools/vision/image-editing.md
  check: file-exists .agents/tools/vision/image-understanding.md
  check: rg "vision" .agents/subagent-index.toon

- [x] v024 t132 Evaluate multimodal vs per-modality structure | PR #708 | merged:2026-02-09 verified:2026-02-09
  files: .agents/tools/multimodal-evaluation.md
  check: file-exists .agents/tools/multimodal-evaluation.md
  check: rg "per-modality" .agents/tools/multimodal-evaluation.md

- [x] v025 t165 Provider-agnostic task claiming | PR #712 | merged:2026-02-09 verified:2026-02-09
  files: .agents/scripts/supervisor-helper.sh, .agents/AGENTS.md, tests/test-supervisor-state-machine.sh
  check: rg "find_project_root\|detect_repo_slug" .agents/scripts/supervisor-helper.sh
  check: rg "with-issue" .agents/scripts/supervisor-helper.sh
  check: rg "Task claiming" .agents/AGENTS.md
  check: rg "Task Claiming via TODO.md" tests/test-supervisor-state-machine.sh

- [x] v026 t080 Cloud voice agents and S2S models | PR #713 | merged:2026-02-09 verified:2026-02-09
  files: .agents/tools/voice/cloud-voice-agents.md, .agents/tools/voice/voice-ai-models.md
  check: file-exists .agents/tools/voice/cloud-voice-agents.md
  check: rg "GPT-4o Realtime" .agents/tools/voice/cloud-voice-agents.md
  check: rg "MiniCPM-o" .agents/tools/voice/cloud-voice-agents.md
  check: rg "Nemotron" .agents/tools/voice/cloud-voice-agents.md

<!-- VERIFY-QUEUE-END -->
