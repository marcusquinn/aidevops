
- [x] v001 t267 Higgsfield image count detection fails after generation -... | PR #1068 | merged:2026-02-11 | verified:2026-02-11
  files: .agents/scripts/higgsfield/playwright-automator.mjs
  check: file-exists .agents/scripts/higgsfield/playwright-automator.mjs

- [x] v002 t269 Higgsfield video download fails silently - downloadLatest... | PR #1067 | merged:2026-02-11 | verified:2026-02-11
  files: .agents/scripts/higgsfield/playwright-automator.mjs
  check: file-exists .agents/scripts/higgsfield/playwright-automator.mjs

- [x] v003 t008 aidevops-opencode Plugin #plan → [todo/PLANS.md#aidevop... | PR #1073 | merged:2026-02-11 | verified:2026-02-11 (subagent-index gap fixed in PR #1133)
  files: .agents/plugins/opencode-aidevops/index.mjs, .agents/plugins/opencode-aidevops/package.json, .agents/tools/build-mcp/aidevops-plugin.md
  check: file-exists .agents/plugins/opencode-aidevops/index.mjs
  check: file-exists .agents/plugins/opencode-aidevops/package.json
  check: file-exists .agents/tools/build-mcp/aidevops-plugin.md
  check: rg "aidevops-plugin" .agents/subagent-index.toon

- [x] v004 t012 OCR Invoice/Receipt Extraction Pipeline #plan → [todo/P... | PR #1074 | merged:2026-02-11 | verified:2026-02-11
  files: .agents/accounts.md, .agents/scripts/ocr-receipt-helper.sh, .agents/subagent-index.toon, .agents/tools/accounts/receipt-ocr.md, .agents/tools/document/extraction-workflow.md
  check: file-exists .agents/accounts.md
  check: shellcheck .agents/scripts/ocr-receipt-helper.sh
  check: file-exists .agents/scripts/ocr-receipt-helper.sh
  check: file-exists .agents/subagent-index.toon
  check: file-exists .agents/tools/accounts/receipt-ocr.md
  check: file-exists .agents/tools/document/extraction-workflow.md
  check: rg "receipt-ocr" .agents/subagent-index.toon
  check: rg "extraction-workflow" .agents/subagent-index.toon

- [x] v005 t012.2 Design extraction schema (vendor, amount, date, VAT, item... | PR #1080 | merged:2026-02-11 | verified:2026-02-11
  files: .agents/scripts/document-extraction-helper.sh, .agents/subagent-index.toon, .agents/tools/document/document-extraction.md, .agents/tools/document/extraction-schemas.md
  check: shellcheck .agents/scripts/document-extraction-helper.sh
  check: file-exists .agents/scripts/document-extraction-helper.sh
  check: file-exists .agents/subagent-index.toon
  check: file-exists .agents/tools/document/document-extraction.md
  check: file-exists .agents/tools/document/extraction-schemas.md
  check: rg "document-extraction" .agents/subagent-index.toon
  check: rg "extraction-schemas" .agents/subagent-index.toon

- [x] v006 t283 issue-sync cmd_close iterates all 533 completed tasks mak... | PR #1084 | merged:2026-02-11 | verified:2026-02-11
  files: .agents/scripts/issue-sync-helper.sh, .github/workflows/issue-sync.yml
  check: shellcheck .agents/scripts/issue-sync-helper.sh
  check: file-exists .agents/scripts/issue-sync-helper.sh
  check: file-exists .github/workflows/issue-sync.yml

- [x] v007 t279 cmd_add() should log unknown options instead of silent su... | PR #1109 | merged:2026-02-11 | verified:2026-02-11
  files: .agents/scripts/supervisor-helper.sh
  check: shellcheck .agents/scripts/supervisor-helper.sh
  check: file-exists .agents/scripts/supervisor-helper.sh

- [x] v008 t289 Auto-recall memories at session start and before tasks | PR #1121 | merged:2026-02-11 | verified:2026-02-11 (shellcheck + subagent-index gaps fixed in PR #1133)
  files: .agents/AGENTS.md, .agents/memory/README.md, .agents/scripts/objective-runner-helper.sh, .agents/scripts/runner-helper.sh, .agents/scripts/session-checkpoint-helper.sh, .agents/workflows/conversation-starter.md
  check: file-exists .agents/AGENTS.md
  check: file-exists .agents/memory/README.md
  check: shellcheck .agents/scripts/objective-runner-helper.sh
  check: file-exists .agents/scripts/objective-runner-helper.sh
  check: shellcheck .agents/scripts/runner-helper.sh
  check: file-exists .agents/scripts/runner-helper.sh
  check: shellcheck .agents/scripts/session-checkpoint-helper.sh
  check: file-exists .agents/scripts/session-checkpoint-helper.sh
  check: file-exists .agents/workflows/conversation-starter.md
  check: rg "conversation-starter" .agents/subagent-index.toon

- [x] v009 t277 Fix Phase 3 blocking on non-required CI checks | PR #1120 | merged:2026-02-11 | verified:2026-02-11
  files: .agents/scripts/supervisor-helper.sh
  check: shellcheck .agents/scripts/supervisor-helper.sh
  check: file-exists .agents/scripts/supervisor-helper.sh

- [ ] v010 t012.1 Research OCR approaches | PR #1136 | merged:2026-02-11
  files: .agents/tools/ocr/ocr-research.md
  check: file-exists .agents/tools/ocr/ocr-research.md
  check: rg "ocr-research" .agents/subagent-index.toon

- [ ] v011 t008.1 Core plugin structure + agent loader ~4h #auto-dispatch | PR #1138 | merged:2026-02-11
  files: .agents/aidevops/plugins.md, .agents/scripts/plugin-loader-helper.sh, .agents/subagent-index.toon, .agents/templates/plugin-template/plugin.json, .agents/templates/plugin-template/scripts/on-init.sh, .agents/templates/plugin-template/scripts/on-load.sh, .agents/templates/plugin-template/scripts/on-unload.sh, aidevops.sh
  check: file-exists .agents/aidevops/plugins.md
  check: shellcheck .agents/scripts/plugin-loader-helper.sh
  check: file-exists .agents/scripts/plugin-loader-helper.sh
  check: file-exists .agents/subagent-index.toon
  check: file-exists .agents/templates/plugin-template/plugin.json
  check: shellcheck .agents/templates/plugin-template/scripts/on-init.sh
  check: file-exists .agents/templates/plugin-template/scripts/on-init.sh
  check: shellcheck .agents/templates/plugin-template/scripts/on-load.sh
  check: file-exists .agents/templates/plugin-template/scripts/on-load.sh
  check: shellcheck .agents/templates/plugin-template/scripts/on-unload.sh
  check: file-exists .agents/templates/plugin-template/scripts/on-unload.sh
  check: shellcheck aidevops.sh
  check: file-exists aidevops.sh

- [ ] v012 t008.3 Quality hooks (pre-commit) ~3h #auto-dispatch blocked-by:... | PR #1150 | merged:2026-02-11
  files: .agents/plugins/opencode-aidevops/index.mjs, .agents/tools/build-mcp/aidevops-plugin.md
  check: file-exists .agents/plugins/opencode-aidevops/index.mjs
  check: file-exists .agents/tools/build-mcp/aidevops-plugin.md
  check: rg "aidevops-plugin" .agents/subagent-index.toon

- [ ] v013 t293 Graduate high-confidence memories into docs — run `memo... | PR #1152 | merged:2026-02-11
  files: .agents/aidevops/graduated-learnings.md
  check: file-exists .agents/aidevops/graduated-learnings.md

- [ ] v014 t012.3 Implement OCR extraction pipeline ~8h #auto-dispatch bloc... | PR #1148 | merged:2026-02-11
  files: .agents/scripts/document-extraction-helper.sh, .agents/scripts/extraction_pipeline.py, .agents/scripts/ocr-receipt-helper.sh, .agents/tools/accounts/receipt-ocr.md, .agents/tools/document/extraction-workflow.md
  check: shellcheck .agents/scripts/document-extraction-helper.sh
  check: file-exists .agents/scripts/document-extraction-helper.sh
  check: file-exists .agents/scripts/extraction_pipeline.py
  check: shellcheck .agents/scripts/ocr-receipt-helper.sh
  check: file-exists .agents/scripts/ocr-receipt-helper.sh
  check: file-exists .agents/tools/accounts/receipt-ocr.md
  check: file-exists .agents/tools/document/extraction-workflow.md
  check: rg "receipt-ocr" .agents/subagent-index.toon
  check: rg "extraction-workflow" .agents/subagent-index.toon

- [ ] v015 t008.2 MCP registration ~2h #auto-dispatch blocked-by:t008.1 | PR #1149 | merged:2026-02-11
  files: .agents/plugins/opencode-aidevops/index.mjs, .agents/tools/build-mcp/aidevops-plugin.md
  check: file-exists .agents/plugins/opencode-aidevops/index.mjs
  check: file-exists .agents/tools/build-mcp/aidevops-plugin.md
  check: rg "aidevops-plugin" .agents/subagent-index.toon

- [ ] v016 t292 SonarCloud code smell sweep — SonarCloud reports 36 code ... | PR #1151 | merged:2026-02-11
  files: .agents/scripts/add-skill-helper.sh, .agents/scripts/agent-test-helper.sh, .agents/scripts/coderabbit-pulse-helper.sh, .agents/scripts/coderabbit-task-creator-helper.sh, .agents/scripts/compare-models-helper.sh, .agents/scripts/content-calendar-helper.sh, .agents/scripts/cron-dispatch.sh, .agents/scripts/cron-helper.sh, .agents/scripts/deploy-agents-on-merge.sh, .agents/scripts/document-extraction-helper.sh, .agents/scripts/email-health-check-helper.sh, .agents/scripts/email-test-suite-helper.sh, .agents/scripts/finding-to-task-helper.sh, .agents/scripts/gocryptfs-helper.sh, .agents/scripts/hetzner-helper.sh, .agents/scripts/issue-sync-helper.sh, .agents/scripts/list-todo-helper.sh, .agents/scripts/mail-helper.sh, .agents/scripts/matrix-dispatch-helper.sh, .agents/scripts/memory-helper.sh, .agents/scripts/model-availability-helper.sh, .agents/scripts/model-registry-helper.sh, .agents/scripts/objective-runner-helper.sh, .agents/scripts/pattern-tracker-helper.sh, .agents/scripts/quality-sweep-helper.sh, .agents/scripts/ralph-loop-helper.sh, .agents/scripts/review-pulse-helper.sh, .agents/scripts/self-improve-helper.sh, .agents/scripts/speech-to-speech-helper.sh, .agents/scripts/transcription-helper.sh, .agents/scripts/virustotal-helper.sh
  check: shellcheck .agents/scripts/add-skill-helper.sh
  check: file-exists .agents/scripts/add-skill-helper.sh
  check: shellcheck .agents/scripts/agent-test-helper.sh
  check: file-exists .agents/scripts/agent-test-helper.sh
  check: shellcheck .agents/scripts/coderabbit-pulse-helper.sh
  check: file-exists .agents/scripts/coderabbit-pulse-helper.sh
  check: shellcheck .agents/scripts/coderabbit-task-creator-helper.sh
  check: file-exists .agents/scripts/coderabbit-task-creator-helper.sh
  check: shellcheck .agents/scripts/compare-models-helper.sh
  check: file-exists .agents/scripts/compare-models-helper.sh
  check: shellcheck .agents/scripts/content-calendar-helper.sh
  check: file-exists .agents/scripts/content-calendar-helper.sh
  check: shellcheck .agents/scripts/cron-dispatch.sh
  check: file-exists .agents/scripts/cron-dispatch.sh
  check: shellcheck .agents/scripts/cron-helper.sh
  check: file-exists .agents/scripts/cron-helper.sh
  check: shellcheck .agents/scripts/deploy-agents-on-merge.sh
  check: file-exists .agents/scripts/deploy-agents-on-merge.sh
  check: shellcheck .agents/scripts/document-extraction-helper.sh
  check: file-exists .agents/scripts/document-extraction-helper.sh
  check: shellcheck .agents/scripts/email-health-check-helper.sh
  check: file-exists .agents/scripts/email-health-check-helper.sh
  check: shellcheck .agents/scripts/email-test-suite-helper.sh
  check: file-exists .agents/scripts/email-test-suite-helper.sh
  check: shellcheck .agents/scripts/finding-to-task-helper.sh
  check: file-exists .agents/scripts/finding-to-task-helper.sh
  check: shellcheck .agents/scripts/gocryptfs-helper.sh
  check: file-exists .agents/scripts/gocryptfs-helper.sh
  check: shellcheck .agents/scripts/hetzner-helper.sh
  check: file-exists .agents/scripts/hetzner-helper.sh
  check: shellcheck .agents/scripts/issue-sync-helper.sh
  check: file-exists .agents/scripts/issue-sync-helper.sh
  check: shellcheck .agents/scripts/list-todo-helper.sh
  check: file-exists .agents/scripts/list-todo-helper.sh
  check: shellcheck .agents/scripts/mail-helper.sh
  check: file-exists .agents/scripts/mail-helper.sh
  check: shellcheck .agents/scripts/matrix-dispatch-helper.sh
  check: file-exists .agents/scripts/matrix-dispatch-helper.sh
  check: shellcheck .agents/scripts/memory-helper.sh
  check: file-exists .agents/scripts/memory-helper.sh
  check: shellcheck .agents/scripts/model-availability-helper.sh
  check: file-exists .agents/scripts/model-availability-helper.sh
  check: shellcheck .agents/scripts/model-registry-helper.sh
  check: file-exists .agents/scripts/model-registry-helper.sh
  check: shellcheck .agents/scripts/objective-runner-helper.sh
  check: file-exists .agents/scripts/objective-runner-helper.sh
  check: shellcheck .agents/scripts/pattern-tracker-helper.sh
  check: file-exists .agents/scripts/pattern-tracker-helper.sh
  check: shellcheck .agents/scripts/quality-sweep-helper.sh
  check: file-exists .agents/scripts/quality-sweep-helper.sh
  check: shellcheck .agents/scripts/ralph-loop-helper.sh
  check: file-exists .agents/scripts/ralph-loop-helper.sh
  check: shellcheck .agents/scripts/review-pulse-helper.sh
  check: file-exists .agents/scripts/review-pulse-helper.sh
  check: shellcheck .agents/scripts/self-improve-helper.sh
  check: file-exists .agents/scripts/self-improve-helper.sh
  check: shellcheck .agents/scripts/speech-to-speech-helper.sh
  check: file-exists .agents/scripts/speech-to-speech-helper.sh
  check: shellcheck .agents/scripts/transcription-helper.sh
  check: file-exists .agents/scripts/transcription-helper.sh
  check: shellcheck .agents/scripts/virustotal-helper.sh
  check: file-exists .agents/scripts/virustotal-helper.sh

- [ ] v017 t008.4 oh-my-opencode compatibility ~2h #auto-dispatch blocked-b... | PR #1157 | merged:2026-02-11
  files: .agents/plugins/opencode-aidevops/index.mjs, .agents/tools/build-mcp/aidevops-plugin.md
  check: file-exists .agents/plugins/opencode-aidevops/index.mjs
  check: file-exists .agents/tools/build-mcp/aidevops-plugin.md
  check: rg "aidevops-plugin" .agents/subagent-index.toon

- [ ] v018 t012.4 QuickFile integration (purchases/expenses) ~4h #auto-disp... | PR #1156 | merged:2026-02-11
  files: .agents/accounts.md, .agents/scripts/ocr-receipt-helper.sh, .agents/scripts/quickfile-helper.sh, .agents/services/accounting/quickfile.md, .agents/subagent-index.toon, .agents/tools/accounts/receipt-ocr.md, .agents/tools/document/extraction-schemas.md, .agents/tools/document/extraction-workflow.md
  check: file-exists .agents/accounts.md
  check: shellcheck .agents/scripts/ocr-receipt-helper.sh
  check: file-exists .agents/scripts/ocr-receipt-helper.sh
  check: shellcheck .agents/scripts/quickfile-helper.sh
  check: file-exists .agents/scripts/quickfile-helper.sh
  check: file-exists .agents/services/accounting/quickfile.md
  check: file-exists .agents/subagent-index.toon
  check: file-exists .agents/tools/accounts/receipt-ocr.md
  check: file-exists .agents/tools/document/extraction-schemas.md
  check: file-exists .agents/tools/document/extraction-workflow.md
  check: rg "quickfile" .agents/subagent-index.toon
  check: rg "receipt-ocr" .agents/subagent-index.toon
  check: rg "extraction-schemas" .agents/subagent-index.toon
  check: rg "extraction-workflow" .agents/subagent-index.toon

- [ ] v019 t284 Fix opencode plugin createTools() Zod v4 crash — hotfix | PR #1103 | merged:2026-02-11
  files: .agents/plugins/opencode-aidevops/index.mjs
  check: file-exists .agents/plugins/opencode-aidevops/index.mjs

- [ ] v020 t294 ShellCheck warning sweep — run `shellcheck -S warning` ... | PR #1158 | merged:2026-02-11
  files: .agents/scripts/compare-models-helper.sh, setup.sh
  check: shellcheck .agents/scripts/compare-models-helper.sh
  check: file-exists .agents/scripts/compare-models-helper.sh
  check: shellcheck setup.sh
  check: file-exists setup.sh

- [ ] v021 t081 Set up Pipecat local voice agent with Soniox STT + Cartes... | PR #1161 | merged:2026-02-11
  files: .agents/scripts/pipecat-helper.sh, .agents/subagent-index.toon, .agents/tools/voice/pipecat-opencode.md
  check: shellcheck .agents/scripts/pipecat-helper.sh
  check: file-exists .agents/scripts/pipecat-helper.sh
  check: file-exists .agents/subagent-index.toon
  check: file-exists .agents/tools/voice/pipecat-opencode.md
  check: rg "pipecat-opencode" .agents/subagent-index.toon

- [ ] v022 t298 Auto-rebase BEHIND/DIRTY PRs in supervisor pulse — when... | PR #1166 | merged:2026-02-11
  files: .agents/scripts/supervisor-helper.sh
  check: shellcheck .agents/scripts/supervisor-helper.sh
  check: file-exists .agents/scripts/supervisor-helper.sh

- [ ] v023 t296 Workers comment on GH issues when blocked | PR #1167 | merged:2026-02-11
  files: .agents/scripts/supervisor-helper.sh
  check: shellcheck .agents/scripts/supervisor-helper.sh
  check: file-exists .agents/scripts/supervisor-helper.sh

- [x] v024 Homebrew install offer + Beads binary download fallback for Linux | PR #1168 | merged:2026-02-11 | verified:2026-02-11
  files: setup.sh, .agents/scripts/beads-sync-helper.sh, aidevops.sh
  check: shellcheck setup.sh
  check: file-exists setup.sh
  check: rg "ensure_homebrew" setup.sh
  check: rg "install_beads_binary" setup.sh
  proof: OrbStack Ubuntu 24.04 (x86_64) container test
    - Fresh container: no brew, no go, no bd installed
    - install_beads_binary(): downloaded bd v0.49.6 to /usr/local/bin/bd, exit 0
    - bd --version: "bd version 0.49.6 (c064f2aa)" -- functional
    - bd init + bd list: created .beads/beads.db, listed issues -- fully working
    - setup_beads() full chain: no brew/go -> binary download -> success
    - ensure_homebrew() decline path: prompted, user said "n", returned 1 cleanly
    - All 11 CI checks passed on PR #1168
