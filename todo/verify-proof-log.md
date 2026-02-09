# Verification Proof Log

Append-only evidence trail for verification runs. Each entry records the exact
check directives executed, their exit codes, and result summaries.

This is the proof that verification actually ran and what it found.
VERIFY.md has the check definitions and pass/fail status.

---

## v001 t168 | PASSED | 2026-02-09T02:53:28Z | by:marcusquinn | #660

  PASS | check 1: `file-exists .agents/scripts/commands/compare-models.md`
  exit: 0 | exists (1522 bytes)

## v002 t120 | PASSED | 2026-02-09T02:53:29Z | by:marcusquinn | #665

  PASS | check 1: `file-exists .agents/tools/mobile/agent-device.md`
  exit: 0 | exists (5899 bytes)
  PASS | check 2: `rg "agent-device" .agents/subagent-index.toon`
  exit: 0 | 1 matches

## v003 t133 | PASSED | 2026-02-09T02:53:29Z | by:marcusquinn | cherry:301b86c1

  PASS | check 1: `file-exists .agents/tools/infrastructure/cloud-gpu.md`
  exit: 0 | exists (17784 bytes)

## v004 t073 | PASSED | 2026-02-09T02:53:30Z | by:marcusquinn | #667

  PASS | check 1: `file-exists .agents/scripts/document-extraction-helper.sh`
  exit: 0 | exists (22354 bytes)
  PASS | check 2: `file-exists .agents/tools/document/extraction-workflow.md`
  exit: 0 | exists (6914 bytes)
  PASS | check 3: `shellcheck .agents/scripts/document-extraction-helper.sh`
  exit: 0 | 0 issues
  PASS | check 4: `rg "document-extraction" .agents/subagent-index.toon`
  exit: 0 | 2 matches

## v005 t175 | PASSED | 2026-02-09T02:53:30Z | by:marcusquinn | #655

  PASS | check 1: `rg "Tier 2.5: Git heuristic" .agents/scripts/supervisor-helper.sh`
  exit: 0 | 1 matches

## v006 t176 | PASSED | 2026-02-09T02:53:31Z | by:marcusquinn | #656

  PASS | check 1: `rg "Uncertainty decision framework" .agents/scripts/commands/full-loop.md`
  exit: 0 | 1 matches
  PASS | check 2: `rg "PROCEED autonomously" .agents/scripts/commands/full-loop.md`
  exit: 0 | 1 matches

## v007 t177 | PASSED | 2026-02-09T02:53:31Z | by:marcusquinn | #658

  PASS | check 1: `file-exists tests/test-supervisor-state-machine.sh`
  exit: 0 | exists (54795 bytes)

## v008 t178 | PASSED | 2026-02-09T02:53:31Z | by:marcusquinn | #659

  PASS | check 1: `rg "cmd_reprompt" .agents/scripts/supervisor-helper.sh`
  exit: 0 | 4 matches

## v009 t166 | PASSED | 2026-02-09T02:53:31Z | by:marcusquinn | #657

  PASS | check 1: `file-exists .github/workflows/review-pulse.yml`
  exit: 0 | exists (3809 bytes)
  PASS | check 2: `file-exists .agents/scripts/review-pulse-helper.sh`
  exit: 0 | exists (23461 bytes)

## v010 t179 | PASSED | 2026-02-09T02:53:31Z | by:marcusquinn | #677

  PASS | check 1: `file-exists .agents/scripts/issue-sync-helper.sh`
  exit: 0 | exists (55866 bytes)
  PASS | check 2: `rg "reconcile" .agents/scripts/issue-sync-helper.sh`
  exit: 0 | 7 matches
  PASS | check 3: `file-exists .github/workflows/issue-sync.yml`
  exit: 0 | exists (9030 bytes)

## v011 t180 | FAILED | 2026-02-09T02:54:21Z | by:marcusquinn | #679

  FAIL | check 1: `rg "post_merge_verify\|verification" .agents/scripts/supervisor-helper.sh`
  exit: 1 | no matches (exit:1)
  FAIL | check 2: `bash tests/test-supervisor-state-machine.sh`
  exit: 1 | 92 passed, 10 failed (exit:1)

## v012 t181 | FAILED | 2026-02-09T02:54:28Z | by:marcusquinn | #681

  FAIL | check 1: `rg "dedup\|auto_prune\|consolidate" .agents/scripts/memory-helper.sh`
  exit: 1 | no matches (exit:1)
  PASS | check 2: `bash tests/test-memory-mail.sh`
  exit: 0 | 54 passed, 0 failed (exit:0)

## v013 t182 | FAILED | 2026-02-09T02:54:28Z | by:marcusquinn | #684

  PASS | check 1: `file-exists .agents/scripts/monitor-code-review.sh`
  exit: 0 | exists (7230 bytes)
  FAIL | check 2: `rg "validate\|auto.fix" .agents/scripts/monitor-code-review.sh`
  exit: 1 | no matches (exit:1)

## v014 t183 | FAILED | 2026-02-09T02:54:28Z | by:marcusquinn | #685

  FAIL | check 1: `rg "no_log_file\|log_file" .agents/scripts/supervisor-helper.sh`
  exit: 1 | no matches (exit:1)

## v015 t184 | FAILED | 2026-02-09T02:54:28Z | by:marcusquinn | #689

  PASS | check 1: `file-exists .agents/scripts/memory-graduate-helper.sh`
  exit: 0 | exists (20596 bytes)
  PASS | check 2: `file-exists .agents/scripts/commands/graduate-memories.md`
  exit: 0 | exists (1129 bytes)
  FAIL | check 3: `shellcheck .agents/scripts/memory-graduate-helper.sh`
  exit: 1 | 2 issues (exit:1)

## v016 t185 | FAILED | 2026-02-09T02:54:29Z | by:marcusquinn | #691

  PASS | check 1: `file-exists .agents/scripts/memory-audit-pulse.sh`
  exit: 0 | exists (18759 bytes)
  PASS | check 2: `file-exists .agents/scripts/commands/memory-audit.md`
  exit: 0 | exists (1496 bytes)
  FAIL | check 3: `shellcheck .agents/scripts/memory-audit-pulse.sh`
  exit: 1 | 1 issues (exit:1)

## v017 t072 | PASSED | 2026-02-09T02:54:30Z | by:marcusquinn | #690

  PASS | check 1: `file-exists .agents/scripts/transcription-helper.sh`
  exit: 0 | exists (33859 bytes)
  PASS | check 2: `file-exists .agents/tools/voice/transcription.md`
  exit: 0 | exists (5619 bytes)
  PASS | check 3: `shellcheck .agents/scripts/transcription-helper.sh`
  exit: 0 | 0 issues
  PASS | check 4: `rg "transcription" .agents/subagent-index.toon`
  exit: 0 | 2 matches

## v018 t189 | FAILED | 2026-02-09T02:54:30Z | by:marcusquinn | #695

  FAIL | check 1: `rg "worktree_registry\|ownership" .agents/scripts/shared-constants.sh`
  exit: 1 | no matches (exit:1)
  FAIL | check 2: `rg "in_use\|registry" .agents/scripts/worktree-helper.sh`
  exit: 1 | no matches (exit:1)

## v019 t188 | FAILED | 2026-02-09T02:54:38Z | by:marcusquinn | #697

  FAIL | check 1: `rg "backup_sqlite_db\|verify_migration_rowcounts" .agents/scripts/shared-constants.sh`
  exit: 1 | no matches (exit:1)
  PASS | check 2: `file-exists tests/test-backup-safety.sh`
  exit: 0 | exists (11586 bytes)
  PASS | check 3: `bash tests/test-backup-safety.sh`
  exit: 0 | exit:0 | [0;32mALL TESTS PASSED[0m

## v020 t187 | FAILED | 2026-02-09T02:54:38Z | by:marcusquinn | #699

  FAIL | check 1: `rg "continuation\|auto.save" .agents/scripts/session-checkpoint-helper.sh`
  exit: 1 | no matches (exit:1)
  PASS | check 2: `rg "checkpoint" .agents/scripts/session-distill-helper.sh`
  exit: 0 | 17 matches
  PASS | check 3: `rg "Context Compaction Survival" .agents/prompts/build.txt`
  exit: 0 | 1 matches

## v021 t186 | PASSED | 2026-02-09T02:54:38Z | by:marcusquinn | #700

  PASS | check 1: `rg "MANDATORY: Development Lifecycle" .agents/AGENTS.md`
  exit: 0 | 1 matches

## v022 t190 | FAILED | 2026-02-09T02:54:38Z | by:marcusquinn | #703

  FAIL | check 1: `shellcheck .agents/scripts/memory-graduate-helper.sh`
  exit: 1 | 2 issues (exit:1)

## v023 t131 | PASSED | 2026-02-09T02:54:39Z | by:marcusquinn | #710

  PASS | check 1: `file-exists .agents/tools/vision/overview.md`
  exit: 0 | exists (3613 bytes)
  PASS | check 2: `file-exists .agents/tools/vision/image-generation.md`
  exit: 0 | exists (8094 bytes)
  PASS | check 3: `file-exists .agents/tools/vision/image-editing.md`
  exit: 0 | exists (7061 bytes)
  PASS | check 4: `file-exists .agents/tools/vision/image-understanding.md`
  exit: 0 | exists (8887 bytes)
  PASS | check 5: `rg "vision" .agents/subagent-index.toon`
  exit: 0 | 1 matches

## v024 t132 | PASSED | 2026-02-09T02:54:39Z | by:marcusquinn | #708

  PASS | check 1: `file-exists .agents/tools/multimodal-evaluation.md`
  exit: 0 | exists (5855 bytes)
  PASS | check 2: `rg "per-modality" .agents/tools/multimodal-evaluation.md`
  exit: 0 | 2 matches

## v025 t165 | FAILED | 2026-02-09T02:54:39Z | by:marcusquinn | #712

  FAIL | check 1: `rg "find_project_root\|detect_repo_slug" .agents/scripts/supervisor-helper.sh`
  exit: 1 | no matches (exit:1)
  PASS | check 2: `rg "with-issue" .agents/scripts/supervisor-helper.sh`
  exit: 0 | 7 matches
  PASS | check 3: `rg "Task claiming" .agents/AGENTS.md`
  exit: 0 | 2 matches
  PASS | check 4: `rg "Task Claiming via TODO.md" tests/test-supervisor-state-machine.sh`
  exit: 0 | 2 matches

## v026 t080 | PASSED | 2026-02-09T02:54:39Z | by:marcusquinn | #713

  PASS | check 1: `file-exists .agents/tools/voice/cloud-voice-agents.md`
  exit: 0 | exists (14871 bytes)
  PASS | check 2: `rg "GPT-4o Realtime" .agents/tools/voice/cloud-voice-agents.md`
  exit: 0 | 7 matches
  PASS | check 3: `rg "MiniCPM-o" .agents/tools/voice/cloud-voice-agents.md`
  exit: 0 | 13 matches
  PASS | check 4: `rg "Nemotron" .agents/tools/voice/cloud-voice-agents.md`
  exit: 0 | 7 matches

## v022 t190 | FAILED | 2026-02-09T03:06:10Z | by:marcusquinn | #703

  FAIL | check 1: `shellcheck .agents/scripts/memory-graduate-helper.sh`
  exit: 1 | 2 issues (exit:1)

## v025 t165 | FAILED | 2026-02-09T03:06:11Z | by:marcusquinn | #712

  FAIL | check 1: `rg "find_project_root\|detect_repo_slug" .agents/scripts/supervisor-helper.sh`
  exit: 1 | no matches (exit:1)
  PASS | check 2: `rg "with-issue" .agents/scripts/supervisor-helper.sh`
  exit: 0 | 7 matches
  PASS | check 3: `rg "Task claiming" .agents/AGENTS.md`
  exit: 0 | 2 matches
  PASS | check 4: `rg "Task Claiming via TODO.md" tests/test-supervisor-state-machine.sh`
  exit: 0 | 2 matches

## v022 t190 | PASSED | 2026-02-09T03:06:47Z | by:marcusquinn | #703

  PASS | check 1: `shellcheck .agents/scripts/memory-graduate-helper.sh`
  exit: 0 | 0 issues

## v025 t165 | PASSED | 2026-02-09T03:06:47Z | by:marcusquinn | #712

  PASS | check 1: `rg "find_project_root\|detect_repo_slug" .agents/scripts/supervisor-helper.sh`
  exit: 0 | 7 matches
  PASS | check 2: `rg "with-issue" .agents/scripts/supervisor-helper.sh`
  exit: 0 | 7 matches
  PASS | check 3: `rg "Task claiming" .agents/AGENTS.md`
  exit: 0 | 2 matches
  PASS | check 4: `rg "Task Claiming via TODO.md" tests/test-supervisor-state-machine.sh`
  exit: 0 | 2 matches

## v027 t191 | FAILED | 2026-02-09T03:06:52Z | by:marcusquinn | #717

  PASS | check 1: `rg "is_git_worktree\|get_repo_root" .agents/scripts/secretlint-helper.sh`
  exit: 0 | 10 matches
  FAIL | check 2: `rg "get_repo_root" .agents/scripts/linters-local.sh`
  exit: 1 | no matches (exit:1)
  PASS | check 3: `shellcheck .agents/scripts/secretlint-helper.sh`
  exit: 0 | 0 issues

## v027 t191 | PASSED | 2026-02-09T03:07:51Z | by:marcusquinn | #717

  PASS | check 1: `rg "is_git_worktree\|get_repo_root" .agents/scripts/secretlint-helper.sh`
  exit: 0 | 10 matches
  PASS | check 2: `rg "git-common-dir|git rev-parse --git-common" .agents/scripts/linters-local.sh`
  exit: 0 | 2 matches
  PASS | check 3: `shellcheck .agents/scripts/secretlint-helper.sh`
  exit: 0 | 0 issues

## v001 t168 | PASSED | 2026-02-09T03:08:32Z | by:marcusquinn | #660

  PASS | check 1: `file-exists .agents/scripts/commands/compare-models.md`
  exit: 0 | exists (1522 bytes)

## v002 t120 | PASSED | 2026-02-09T03:08:32Z | by:marcusquinn | #665

  PASS | check 1: `file-exists .agents/tools/mobile/agent-device.md`
  exit: 0 | exists (5899 bytes)
  PASS | check 2: `rg "agent-device" .agents/subagent-index.toon`
  exit: 0 | 1 matches

## v003 t133 | PASSED | 2026-02-09T03:08:32Z | by:marcusquinn | cherry:301b86c1

  PASS | check 1: `file-exists .agents/tools/infrastructure/cloud-gpu.md`
  exit: 0 | exists (17784 bytes)

## v004 t073 | PASSED | 2026-02-09T03:08:33Z | by:marcusquinn | #667

  PASS | check 1: `file-exists .agents/scripts/document-extraction-helper.sh`
  exit: 0 | exists (22354 bytes)
  PASS | check 2: `file-exists .agents/tools/document/extraction-workflow.md`
  exit: 0 | exists (6914 bytes)
  PASS | check 3: `shellcheck .agents/scripts/document-extraction-helper.sh`
  exit: 0 | 0 issues
  PASS | check 4: `rg "document-extraction" .agents/subagent-index.toon`
  exit: 0 | 2 matches

## v005 t175 | PASSED | 2026-02-09T03:08:33Z | by:marcusquinn | #655

  PASS | check 1: `rg "Tier 2.5: Git heuristic" .agents/scripts/supervisor-helper.sh`
  exit: 0 | 1 matches

## v006 t176 | PASSED | 2026-02-09T03:08:33Z | by:marcusquinn | #656

  PASS | check 1: `rg "Uncertainty decision framework" .agents/scripts/commands/full-loop.md`
  exit: 0 | 1 matches
  PASS | check 2: `rg "PROCEED autonomously" .agents/scripts/commands/full-loop.md`
  exit: 0 | 1 matches

## v007 t177 | PASSED | 2026-02-09T03:08:33Z | by:marcusquinn | #658

  PASS | check 1: `file-exists tests/test-supervisor-state-machine.sh`
  exit: 0 | exists (54795 bytes)

## v008 t178 | PASSED | 2026-02-09T03:08:33Z | by:marcusquinn | #659

  PASS | check 1: `rg "cmd_reprompt" .agents/scripts/supervisor-helper.sh`
  exit: 0 | 4 matches

## v009 t166 | PASSED | 2026-02-09T03:08:33Z | by:marcusquinn | #657

  PASS | check 1: `file-exists .github/workflows/review-pulse.yml`
  exit: 0 | exists (3809 bytes)
  PASS | check 2: `file-exists .agents/scripts/review-pulse-helper.sh`
  exit: 0 | exists (23461 bytes)

## v010 t179 | PASSED | 2026-02-09T03:08:34Z | by:marcusquinn | #677

  PASS | check 1: `file-exists .agents/scripts/issue-sync-helper.sh`
  exit: 0 | exists (55866 bytes)
  PASS | check 2: `rg "reconcile" .agents/scripts/issue-sync-helper.sh`
  exit: 0 | 7 matches
  PASS | check 3: `file-exists .github/workflows/issue-sync.yml`
  exit: 0 | exists (9030 bytes)

## v011 t180 | FAILED | 2026-02-09T03:09:41Z | by:marcusquinn | #679

  PASS | check 1: `rg "post_merge_verify\|verification" .agents/scripts/supervisor-helper.sh`
  exit: 0 | 27 matches
  FAIL | check 2: `bash tests/test-supervisor-state-machine.sh`
  exit: 1 | 92 passed, 10 failed (exit:1)

## v012 t181 | PASSED | 2026-02-09T03:09:46Z | by:marcusquinn | #681

  PASS | check 1: `rg "dedup\|auto_prune\|consolidate" .agents/scripts/memory-helper.sh`
  exit: 0 | 26 matches
  PASS | check 2: `bash tests/test-memory-mail.sh`
  exit: 0 | 54 passed, 0 failed (exit:0)

## v013 t182 | PASSED | 2026-02-09T03:09:46Z | by:marcusquinn | #684

  PASS | check 1: `file-exists .agents/scripts/monitor-code-review.sh`
  exit: 0 | exists (7230 bytes)
  PASS | check 2: `rg "validate\|auto.fix" .agents/scripts/monitor-code-review.sh`
  exit: 0 | 5 matches

## v014 t183 | PASSED | 2026-02-09T03:09:46Z | by:marcusquinn | #685

  PASS | check 1: `rg "no_log_file\|log_file" .agents/scripts/supervisor-helper.sh`
  exit: 0 | 76 matches

## v015 t184 | PASSED | 2026-02-09T03:09:46Z | by:marcusquinn | #689

  PASS | check 1: `file-exists .agents/scripts/memory-graduate-helper.sh`
  exit: 0 | exists (20596 bytes)
  PASS | check 2: `file-exists .agents/scripts/commands/graduate-memories.md`
  exit: 0 | exists (1129 bytes)
  PASS | check 3: `shellcheck .agents/scripts/memory-graduate-helper.sh`
  exit: 0 | 0 issues

## v016 t185 | PASSED | 2026-02-09T03:09:46Z | by:marcusquinn | #691

  PASS | check 1: `file-exists .agents/scripts/memory-audit-pulse.sh`
  exit: 0 | exists (18759 bytes)
  PASS | check 2: `file-exists .agents/scripts/commands/memory-audit.md`
  exit: 0 | exists (1496 bytes)
  PASS | check 3: `shellcheck .agents/scripts/memory-audit-pulse.sh`
  exit: 0 | 0 issues

## v017 t072 | PASSED | 2026-02-09T03:09:47Z | by:marcusquinn | #690

  PASS | check 1: `file-exists .agents/scripts/transcription-helper.sh`
  exit: 0 | exists (33859 bytes)
  PASS | check 2: `file-exists .agents/tools/voice/transcription.md`
  exit: 0 | exists (5619 bytes)
  PASS | check 3: `shellcheck .agents/scripts/transcription-helper.sh`
  exit: 0 | 0 issues
  PASS | check 4: `rg "transcription" .agents/subagent-index.toon`
  exit: 0 | 2 matches

## v018 t189 | PASSED | 2026-02-09T03:09:47Z | by:marcusquinn | #695

  PASS | check 1: `rg "worktree_registry\|ownership" .agents/scripts/shared-constants.sh`
  exit: 0 | 3 matches
  PASS | check 2: `rg "in_use\|registry" .agents/scripts/worktree-helper.sh`
  exit: 0 | 13 matches

## v019 t188 | PASSED | 2026-02-09T03:09:55Z | by:marcusquinn | #697

  PASS | check 1: `rg "backup_sqlite_db\|verify_migration_rowcounts" .agents/scripts/shared-constants.sh`
  exit: 0 | 4 matches
  PASS | check 2: `file-exists tests/test-backup-safety.sh`
  exit: 0 | exists (11586 bytes)
  PASS | check 3: `bash tests/test-backup-safety.sh`
  exit: 0 | exit:0 | [0;32mALL TESTS PASSED[0m

## v020 t187 | PASSED | 2026-02-09T03:09:55Z | by:marcusquinn | #699

  PASS | check 1: `rg "continuation\|auto.save" .agents/scripts/session-checkpoint-helper.sh`
  exit: 0 | 8 matches
  PASS | check 2: `rg "checkpoint" .agents/scripts/session-distill-helper.sh`
  exit: 0 | 17 matches
  PASS | check 3: `rg "Context Compaction Survival" .agents/prompts/build.txt`
  exit: 0 | 1 matches

## v021 t186 | PASSED | 2026-02-09T03:09:55Z | by:marcusquinn | #700

  PASS | check 1: `rg "MANDATORY: Development Lifecycle" .agents/AGENTS.md`
  exit: 0 | 1 matches

## v022 t190 | PASSED | 2026-02-09T03:09:56Z | by:marcusquinn | #703

  PASS | check 1: `shellcheck .agents/scripts/memory-graduate-helper.sh`
  exit: 0 | 0 issues

## v023 t131 | PASSED | 2026-02-09T03:09:56Z | by:marcusquinn | #710

  PASS | check 1: `file-exists .agents/tools/vision/overview.md`
  exit: 0 | exists (3613 bytes)
  PASS | check 2: `file-exists .agents/tools/vision/image-generation.md`
  exit: 0 | exists (8094 bytes)
  PASS | check 3: `file-exists .agents/tools/vision/image-editing.md`
  exit: 0 | exists (7061 bytes)
  PASS | check 4: `file-exists .agents/tools/vision/image-understanding.md`
  exit: 0 | exists (8887 bytes)
  PASS | check 5: `rg "vision" .agents/subagent-index.toon`
  exit: 0 | 1 matches

## v024 t132 | PASSED | 2026-02-09T03:09:56Z | by:marcusquinn | #708

  PASS | check 1: `file-exists .agents/tools/multimodal-evaluation.md`
  exit: 0 | exists (5855 bytes)
  PASS | check 2: `rg "per-modality" .agents/tools/multimodal-evaluation.md`
  exit: 0 | 2 matches

## v025 t165 | PASSED | 2026-02-09T03:09:56Z | by:marcusquinn | #712

  PASS | check 1: `rg "find_project_root\|detect_repo_slug" .agents/scripts/supervisor-helper.sh`
  exit: 0 | 7 matches
  PASS | check 2: `rg "with-issue" .agents/scripts/supervisor-helper.sh`
  exit: 0 | 7 matches
  PASS | check 3: `rg "Task claiming" .agents/AGENTS.md`
  exit: 0 | 2 matches
  PASS | check 4: `rg "Task Claiming via TODO.md" tests/test-supervisor-state-machine.sh`
  exit: 0 | 2 matches

## v026 t080 | PASSED | 2026-02-09T03:09:57Z | by:marcusquinn | #713

  PASS | check 1: `file-exists .agents/tools/voice/cloud-voice-agents.md`
  exit: 0 | exists (14871 bytes)
  PASS | check 2: `rg "GPT-4o Realtime" .agents/tools/voice/cloud-voice-agents.md`
  exit: 0 | 7 matches
  PASS | check 3: `rg "MiniCPM-o" .agents/tools/voice/cloud-voice-agents.md`
  exit: 0 | 13 matches
  PASS | check 4: `rg "Nemotron" .agents/tools/voice/cloud-voice-agents.md`
  exit: 0 | 7 matches

## v027 t191 | PASSED | 2026-02-09T03:09:58Z | by:marcusquinn | #717

  PASS | check 1: `rg "is_git_worktree\|get_repo_root" .agents/scripts/secretlint-helper.sh`
  exit: 0 | 10 matches
  PASS | check 2: `rg "git-common-dir|git rev-parse --git-common" .agents/scripts/linters-local.sh`
  exit: 0 | 2 matches
  PASS | check 3: `shellcheck .agents/scripts/secretlint-helper.sh`
  exit: 0 | 0 issues

## v028 t000 | PASSED | 2026-02-09T03:10:42Z | by:marcusquinn | #716

  PASS | check 1: `rg "Normalize grep BRE" .agents/scripts/verify-run-helper.sh`
  exit: 0 | 1 matches
  PASS | check 2: `rg "shellcheck -x -S warning" .agents/scripts/verify-run-helper.sh`
  exit: 0 | 1 matches

## v029 t134 | PASSED | 2026-02-09T03:13:45Z | by:marcusquinn | #718

  PASS | check 1: `file-exists .agents/scripts/sops-helper.sh`
  exit: 0 | exists (16207 bytes)
  PASS | check 2: `file-exists .agents/scripts/gocryptfs-helper.sh`
  exit: 0 | exists (14357 bytes)
  PASS | check 3: `file-exists .agents/tools/credentials/encryption-stack.md`
  exit: 0 | exists (3960 bytes)
  PASS | check 4: `rg "age|GPG" .agents/tools/credentials/sops.md`
  exit: 0 | 40 matches
  PASS | check 5: `rg "FUSE|AES-256" .agents/tools/credentials/gocryptfs.md`
  exit: 0 | 16 matches
  PASS | check 6: `shellcheck .agents/scripts/sops-helper.sh`
  exit: 0 | 0 issues
  PASS | check 7: `shellcheck .agents/scripts/gocryptfs-helper.sh`
  exit: 0 | 0 issues

## v030 t132.2 | FAILED | 2026-02-09T14:58:18Z | by:marcusquinn | #761

  PASS | check 1: `file-exists .agents/scripts/model-registry-helper.sh`
  exit: 0 | exists (39602 bytes)
  PASS | check 2: `shellcheck .agents/scripts/model-registry-helper.sh`
  exit: 0 | 0 issues
  FAIL | check 3: `bash -n .agents/scripts/model-registry-helper.sh`
  exit: 1 | exit:127 | bash: /Users/marcusquinn/Git/aidevops/-n .agents/scripts/model-registry-helper.s
  PASS | check 4: `rg "model-registry" .agents/subagent-index.toon`
  exit: 0 | 1 matches

## v031 t168.2 | PASSED | 2026-02-09T14:58:18Z | by:marcusquinn | #761

  PASS | check 1: `file-exists .agents/scripts/compare-models-helper.sh`
  exit: 0 | exists (32878 bytes)
  PASS | check 2: `rg "compare\|recommend" .agents/scripts/compare-models-helper.sh`
  exit: 0 | 34 matches

## v032 t166.2 | FAILED | 2026-02-09T14:58:19Z | by:marcusquinn | #765

  PASS | check 1: `file-exists .agents/scripts/coderabbit-collector-helper.sh`
  exit: 0 | exists (34080 bytes)
  PASS | check 2: `shellcheck .agents/scripts/coderabbit-collector-helper.sh`
  exit: 0 | 0 issues
  FAIL | check 3: `bash -n .agents/scripts/coderabbit-collector-helper.sh`
  exit: 1 | exit:127 | bash: /Users/marcusquinn/Git/aidevops/-n .agents/scripts/coderabbit-collector-he
  PASS | check 4: `rg "collect_pr_reviews|collect_comments" .agents/scripts/coderabbit-collector-helper.sh`
  exit: 0 | 2 matches

## v036 t102.2 | FAILED | 2026-02-09T14:58:19Z | by:marcusquinn | #768

  PASS | check 1: `file-exists .agents/scripts/memory-embeddings-helper.sh`
  exit: 0 | exists (38381 bytes)
  PASS | check 2: `shellcheck .agents/scripts/memory-embeddings-helper.sh`
  exit: 0 | 0 issues
  FAIL | check 3: `bash -n .agents/scripts/memory-embeddings-helper.sh`
  exit: 1 | exit:127 | bash: /Users/marcusquinn/Git/aidevops/-n .agents/scripts/memory-embeddings-helpe
  PASS | check 4: `rg "hybrid|semantic" .agents/memory/README.md`
  exit: 0 | 8 matches
  PASS | check 5: `rg "auto.index|--hybrid" .agents/scripts/memory-helper.sh`
  exit: 0 | 6 matches

## v030 t132.2 | PASSED | 2026-02-09T14:59:09Z | by:marcusquinn | #761

  PASS | check 1: `file-exists .agents/scripts/model-registry-helper.sh`
  exit: 0 | exists (39602 bytes)
  PASS | check 2: `shellcheck .agents/scripts/model-registry-helper.sh`
  exit: 0 | 0 issues
  PASS | check 3: `rg "model-registry" .agents/subagent-index.toon`
  exit: 0 | 1 matches

## v032 t166.2 | PASSED | 2026-02-09T14:59:10Z | by:marcusquinn | #765

  PASS | check 1: `file-exists .agents/scripts/coderabbit-collector-helper.sh`
  exit: 0 | exists (34080 bytes)
  PASS | check 2: `shellcheck .agents/scripts/coderabbit-collector-helper.sh`
  exit: 0 | 0 issues
  PASS | check 3: `rg "collect_pr_reviews|collect_comments" .agents/scripts/coderabbit-collector-helper.sh`
  exit: 0 | 2 matches

## v036 t102.2 | PASSED | 2026-02-09T14:59:11Z | by:marcusquinn | #768

  PASS | check 1: `file-exists .agents/scripts/memory-embeddings-helper.sh`
  exit: 0 | exists (38381 bytes)
  PASS | check 2: `shellcheck .agents/scripts/memory-embeddings-helper.sh`
  exit: 0 | 0 issues
  PASS | check 3: `rg "hybrid|semantic" .agents/memory/README.md`
  exit: 0 | 8 matches
  PASS | check 4: `rg "auto.index|--hybrid" .agents/scripts/memory-helper.sh`
  exit: 0 | 6 matches

