
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

- [!] v010 t012.1 Research OCR approaches | PR #1136 | merged:2026-02-11 failed:2026-02-12 reason:rg: "ocr-research" not found in .agents/subagent-index.toon
  files: .agents/tools/ocr/ocr-research.md
  check: file-exists .agents/tools/ocr/ocr-research.md
  check: rg "ocr-research" .agents/subagent-index.toon

- [!] v011 t008.1 Core plugin structure + agent loader ~4h #auto-dispatch | PR #1138 | merged:2026-02-11 failed:2026-02-12 reason:shellcheck: .agents/scripts/plugin-loader-helper.sh has violations
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

- [x] v012 t008.3 Quality hooks (pre-commit) ~3h #auto-dispatch blocked-by:... | PR #1150 | merged:2026-02-11 verified:2026-02-12
  files: .agents/plugins/opencode-aidevops/index.mjs, .agents/tools/build-mcp/aidevops-plugin.md
  check: file-exists .agents/plugins/opencode-aidevops/index.mjs
  check: file-exists .agents/tools/build-mcp/aidevops-plugin.md
  check: rg "aidevops-plugin" .agents/subagent-index.toon

- [x] v013 t293 Graduate high-confidence memories into docs — run `memo... | PR #1152 | merged:2026-02-11 verified:2026-02-12
  files: .agents/aidevops/graduated-learnings.md
  check: file-exists .agents/aidevops/graduated-learnings.md

- [x] v014 t012.3 Implement OCR extraction pipeline ~8h #auto-dispatch bloc... | PR #1148 | merged:2026-02-11 verified:2026-02-12
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

- [x] v015 t008.2 MCP registration ~2h #auto-dispatch blocked-by:t008.1 | PR #1149 | merged:2026-02-11 verified:2026-02-12
  files: .agents/plugins/opencode-aidevops/index.mjs, .agents/tools/build-mcp/aidevops-plugin.md
  check: file-exists .agents/plugins/opencode-aidevops/index.mjs
  check: file-exists .agents/tools/build-mcp/aidevops-plugin.md
  check: rg "aidevops-plugin" .agents/subagent-index.toon

- [!] v016 t292 SonarCloud code smell sweep — SonarCloud reports 36 code ... | PR #1151 | merged:2026-02-11 failed:2026-02-12 reason:shellcheck: .agents/scripts/add-skill-helper.sh has violations; shellcheck: .agents/scripts/agent-test-helper.sh has violations; shellcheck: .agents/scripts/compare-models-helper.sh has violatio
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

- [x] v017 t008.4 oh-my-opencode compatibility ~2h #auto-dispatch blocked-b... | PR #1157 | merged:2026-02-11 verified:2026-02-12
  files: .agents/plugins/opencode-aidevops/index.mjs, .agents/tools/build-mcp/aidevops-plugin.md
  check: file-exists .agents/plugins/opencode-aidevops/index.mjs
  check: file-exists .agents/tools/build-mcp/aidevops-plugin.md
  check: rg "aidevops-plugin" .agents/subagent-index.toon

- [x] v018 t012.4 QuickFile integration (purchases/expenses) ~4h #auto-disp... | PR #1156 | merged:2026-02-11 verified:2026-02-12
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

- [x] v019 t284 Fix opencode plugin createTools() Zod v4 crash — hotfix | PR #1103 | merged:2026-02-11 verified:2026-02-12
  files: .agents/plugins/opencode-aidevops/index.mjs
  check: file-exists .agents/plugins/opencode-aidevops/index.mjs

- [!] v020 t294 ShellCheck warning sweep — run `shellcheck -S warning` ... | PR #1158 | merged:2026-02-11 failed:2026-02-12 reason:shellcheck: .agents/scripts/compare-models-helper.sh has violations; shellcheck: setup.sh has violations
  files: .agents/scripts/compare-models-helper.sh, setup.sh
  check: shellcheck .agents/scripts/compare-models-helper.sh
  check: file-exists .agents/scripts/compare-models-helper.sh
  check: shellcheck setup.sh
  check: file-exists setup.sh

- [x] v021 t081 Set up Pipecat local voice agent with Soniox STT + Cartes... | PR #1161 | merged:2026-02-11 verified:2026-02-12
  files: .agents/scripts/pipecat-helper.sh, .agents/subagent-index.toon, .agents/tools/voice/pipecat-opencode.md
  check: shellcheck .agents/scripts/pipecat-helper.sh
  check: file-exists .agents/scripts/pipecat-helper.sh
  check: file-exists .agents/subagent-index.toon
  check: file-exists .agents/tools/voice/pipecat-opencode.md
  check: rg "pipecat-opencode" .agents/subagent-index.toon

- [!] v022 t298 Auto-rebase BEHIND/DIRTY PRs in supervisor pulse — when... | PR #1166 | merged:2026-02-11 failed:2026-02-12 reason:shellcheck: .agents/scripts/supervisor-helper.sh has violations
  files: .agents/scripts/supervisor-helper.sh
  check: shellcheck .agents/scripts/supervisor-helper.sh
  check: file-exists .agents/scripts/supervisor-helper.sh

- [!] v023 t296 Workers comment on GH issues when blocked | PR #1167 | merged:2026-02-11 failed:2026-02-12 reason:shellcheck: .agents/scripts/supervisor-helper.sh has violations
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

- [!] v025 t300 Verify Phase 10b self-improvement loop works end-to-end �... | PR #1174 | merged:2026-02-12 failed:2026-02-12 reason:shellcheck: .agents/scripts/supervisor-helper.sh has violations
  files: .agents/scripts/supervisor-helper.sh
  check: shellcheck .agents/scripts/supervisor-helper.sh
  check: file-exists .agents/scripts/supervisor-helper.sh

- [!] v026 t301 Rosetta audit + shell linter optimisation — detect x86 ... | PR #1185 | merged:2026-02-12 failed:2026-02-12 reason:shellcheck: setup.sh has violations
  files: .agents/scripts/linters-local.sh, .agents/scripts/rosetta-audit-helper.sh, setup.sh
  check: shellcheck .agents/scripts/linters-local.sh
  check: file-exists .agents/scripts/linters-local.sh
  check: shellcheck .agents/scripts/rosetta-audit-helper.sh
  check: file-exists .agents/scripts/rosetta-audit-helper.sh
  check: shellcheck setup.sh
  check: file-exists setup.sh

- [x] v027 t307 Fix missing validate_namespace call in aidevops.sh — re... | PR #1189 | merged:2026-02-12 verified:2026-02-12
  files: aidevops.sh
  check: shellcheck aidevops.sh
  check: file-exists aidevops.sh

- [!] v028 t310 Enhancor AI agent — create enhancor.md subagent under t... | PR #1194 | merged:2026-02-12 failed:2026-02-12 reason:rg: "enhancor" not found in .agents/subagent-index.toon
  files: .agents/content/production/image.md, .agents/scripts/enhancor-helper.sh, .agents/tools/video/enhancor.md
  check: file-exists .agents/content/production/image.md
  check: shellcheck .agents/scripts/enhancor-helper.sh
  check: file-exists .agents/scripts/enhancor-helper.sh
  check: file-exists .agents/tools/video/enhancor.md
  check: rg "enhancor" .agents/subagent-index.toon

- [x] v029 t309 REAL Video Enhancer agent — create a real-video-enhance... | PR #1193 | merged:2026-02-12 verified:2026-02-12
  files: .agents/AGENTS.md, .agents/content/production/video.md, .agents/scripts/real-video-enhancer-helper.sh, .agents/subagent-index.toon, .agents/tools/video/real-video-enhancer.md, .agents/tools/video/video-prompt-design.md
  check: file-exists .agents/AGENTS.md
  check: file-exists .agents/content/production/video.md
  check: shellcheck .agents/scripts/real-video-enhancer-helper.sh
  check: file-exists .agents/scripts/real-video-enhancer-helper.sh
  check: file-exists .agents/subagent-index.toon
  check: file-exists .agents/tools/video/real-video-enhancer.md
  check: file-exists .agents/tools/video/video-prompt-design.md
  check: rg "real-video-enhancer" .agents/subagent-index.toon
  check: rg "video-prompt-design" .agents/subagent-index.toon

- [!] v030 t306 Fix namespace validation in setup.sh — namespace collec... | PR #1190 | merged:2026-02-12 failed:2026-02-12 reason:shellcheck: setup.sh has violations
  files: setup.sh
  check: shellcheck setup.sh
  check: file-exists setup.sh

- [!] v031 t304 Fix rm -rf on potentially empty variable in setup.sh — ... | PR #1187 | merged:2026-02-12 failed:2026-02-12 reason:shellcheck: setup.sh has violations
  files: setup.sh
  check: shellcheck setup.sh
  check: file-exists setup.sh

- [x] v032 t308 Fix help text in aidevops.sh — help text omits the `[na... | PR #1191 | merged:2026-02-12 verified:2026-02-12
  files: aidevops.sh
  check: shellcheck aidevops.sh
  check: file-exists aidevops.sh

- [!] v033 t305 Fix path traversal risk in setup.sh plugin clone paths �... | PR #1188 | merged:2026-02-12 failed:2026-02-12 reason:shellcheck: setup.sh has violations
  files: setup.sh
  check: shellcheck setup.sh
  check: file-exists setup.sh

- [!] v034 t305 Fix path traversal risk in setup.sh plugin clone paths �... | PR #1188 | merged:2026-02-12 failed:2026-02-12 reason:shellcheck: setup.sh has violations
  files: setup.sh
  check: shellcheck setup.sh
  check: file-exists setup.sh

- [!] v035 t299 Close self-improvement feedback loop — add supervisor P... | PR #1206 | merged:2026-02-12 failed:2026-02-12 reason:shellcheck: .agents/scripts/supervisor-helper.sh has violations
  files: .agents/scripts/supervisor-helper.sh
  check: shellcheck .agents/scripts/supervisor-helper.sh
  check: file-exists .agents/scripts/supervisor-helper.sh

- [x] v036 t311.1 Audit and map supervisor-helper.sh functions by domain �... | PR #1207 | merged:2026-02-12 verified:2026-02-12
  files: .agents/aidevops/supervisor-module-map.md
  check: file-exists .agents/aidevops/supervisor-module-map.md

- [!] v037 t311.4 Repeat modularisation for memory-helper.sh — apply same... | PR #1208 | merged:2026-02-12 failed:2026-02-12 reason:shellcheck: .agents/scripts/memory-helper.sh has violations
  files: .agents/scripts/memory-helper.sh, .agents/scripts/memory/_common.sh, .agents/scripts/memory/maintenance.sh, .agents/scripts/memory/recall.sh, .agents/scripts/memory/store.sh
  check: shellcheck .agents/scripts/memory-helper.sh
  check: file-exists .agents/scripts/memory-helper.sh
  check: shellcheck .agents/scripts/memory/_common.sh
  check: file-exists .agents/scripts/memory/_common.sh
  check: shellcheck .agents/scripts/memory/maintenance.sh
  check: file-exists .agents/scripts/memory/maintenance.sh
  check: shellcheck .agents/scripts/memory/recall.sh
  check: file-exists .agents/scripts/memory/recall.sh
  check: shellcheck .agents/scripts/memory/store.sh
  check: file-exists .agents/scripts/memory/store.sh

- [!] v038 t311.5 Update tooling for module structure — update setup.sh t... | PR #1209 | merged:2026-02-12 failed:2026-02-12 reason:shellcheck: setup.sh has violations
  files: .agents/scripts/linters-local.sh, .agents/scripts/quality-fix.sh, setup.sh, tests/test-smoke-help.sh
  check: shellcheck .agents/scripts/linters-local.sh
  check: file-exists .agents/scripts/linters-local.sh
  check: shellcheck .agents/scripts/quality-fix.sh
  check: file-exists .agents/scripts/quality-fix.sh
  check: shellcheck setup.sh
  check: file-exists setup.sh
  check: shellcheck tests/test-smoke-help.sh
  check: file-exists tests/test-smoke-help.sh

- [!] v039 t303 Distributed task ID allocation via claim-task-id.sh — p... | PR #1216 | merged:2026-02-12 failed:2026-02-12 reason:shellcheck: .agents/scripts/claim-task-id.sh has violations; shellcheck: .agents/scripts/supervisor-helper.sh has violations
  files: .agents/scripts/claim-task-id.sh, .agents/scripts/coderabbit-task-creator-helper.sh, .agents/scripts/supervisor-helper.sh
  check: shellcheck .agents/scripts/claim-task-id.sh
  check: file-exists .agents/scripts/claim-task-id.sh
  check: shellcheck .agents/scripts/coderabbit-task-creator-helper.sh
  check: file-exists .agents/scripts/coderabbit-task-creator-helper.sh
  check: shellcheck .agents/scripts/supervisor-helper.sh
  check: file-exists .agents/scripts/supervisor-helper.sh

- [!] v040 t311.3 Extract supervisor modules — move functions into module... | PR #1220 | merged:2026-02-12 failed:2026-02-12 reason:shellcheck: .agents/scripts/supervisor-helper.sh has violations
  files: .agents/scripts/supervisor-helper.sh, .agents/scripts/supervisor/release.sh, .agents/scripts/supervisor/todo-sync.sh
  check: shellcheck .agents/scripts/supervisor-helper.sh
  check: file-exists .agents/scripts/supervisor-helper.sh
  check: shellcheck .agents/scripts/supervisor/release.sh
  check: file-exists .agents/scripts/supervisor/release.sh
  check: shellcheck .agents/scripts/supervisor/todo-sync.sh
  check: file-exists .agents/scripts/supervisor/todo-sync.sh

- [!] v041 t316.2 Create module skeleton for setup.sh — create `setup/` d... | PR #1240 | merged:2026-02-12 failed:2026-02-12 reason:shellcheck: .agents/scripts/setup/_backup.sh has violations; shellcheck: setup.sh has violations
  files: .agents/scripts/setup/_backup.sh, .agents/scripts/setup/_bootstrap.sh, .agents/scripts/setup/_common.sh, .agents/scripts/setup/_deployment.sh, .agents/scripts/setup/_installation.sh, .agents/scripts/setup/_migration.sh, .agents/scripts/setup/_opencode.sh, .agents/scripts/setup/_services.sh, .agents/scripts/setup/_shell.sh, .agents/scripts/setup/_tools.sh, .agents/scripts/setup/_validation.sh, setup.sh
  check: shellcheck .agents/scripts/setup/_backup.sh
  check: file-exists .agents/scripts/setup/_backup.sh
  check: shellcheck .agents/scripts/setup/_bootstrap.sh
  check: file-exists .agents/scripts/setup/_bootstrap.sh
  check: shellcheck .agents/scripts/setup/_common.sh
  check: file-exists .agents/scripts/setup/_common.sh
  check: shellcheck .agents/scripts/setup/_deployment.sh
  check: file-exists .agents/scripts/setup/_deployment.sh
  check: shellcheck .agents/scripts/setup/_installation.sh
  check: file-exists .agents/scripts/setup/_installation.sh
  check: shellcheck .agents/scripts/setup/_migration.sh
  check: file-exists .agents/scripts/setup/_migration.sh
  check: shellcheck .agents/scripts/setup/_opencode.sh
  check: file-exists .agents/scripts/setup/_opencode.sh
  check: shellcheck .agents/scripts/setup/_services.sh
  check: file-exists .agents/scripts/setup/_services.sh
  check: shellcheck .agents/scripts/setup/_shell.sh
  check: file-exists .agents/scripts/setup/_shell.sh
  check: shellcheck .agents/scripts/setup/_tools.sh
  check: file-exists .agents/scripts/setup/_tools.sh
  check: shellcheck .agents/scripts/setup/_validation.sh
  check: file-exists .agents/scripts/setup/_validation.sh
  check: shellcheck setup.sh
  check: file-exists setup.sh

- [!] v042 t317.2 Create complete_task() helper in planning-commit-helper.s... | PR #1251 | merged:2026-02-12 failed:2026-02-12 reason:shellcheck: .agents/scripts/planning-commit-helper.sh has violations
  files: .agents/scripts/planning-commit-helper.sh
  check: shellcheck .agents/scripts/planning-commit-helper.sh
  check: file-exists .agents/scripts/planning-commit-helper.sh

- [x] v043 t316.5 End-to-end verification — run full `./setup.sh --non-in... | PR #1241 | merged:2026-02-12 verified:2026-02-12
  files: VERIFY-t316.5.md
  check: file-exists VERIFY-t316.5.md

- [x] v044 t317.3 Update AGENTS.md task completion rules — add instructio... | PR #1250 | merged:2026-02-12 verified:2026-02-12
  files: .agents/AGENTS.md
  check: file-exists .agents/AGENTS.md

- [x] v045 t318.3 Update interactive PR workflow — update `workflows/git-... | PR #1254 | merged:2026-02-12 verified:2026-02-12
  files: .agents/AGENTS.md, .agents/workflows/git-workflow.md
  check: file-exists .agents/AGENTS.md
  check: file-exists .agents/workflows/git-workflow.md
  check: rg "git-workflow" .agents/subagent-index.toon

- [x] v046 t318.4 Backfill audit — scan all open PRs for missing task IDs... | PR #1255 | merged:2026-02-12 verified:2026-02-12
  files: PR_AUDIT_REPORT.md
  check: file-exists PR_AUDIT_REPORT.md

- [!] v047 t319.4 Add supervisor dedup Phase 0.5 — before Phase 1 (dispat... | PR #1261 | merged:2026-02-12 failed:2026-02-12 reason:shellcheck: .agents/scripts/supervisor-helper.sh has violations
  files: .agents/scripts/supervisor-helper.sh, .agents/scripts/supervisor/todo-sync.sh
  check: shellcheck .agents/scripts/supervisor-helper.sh
  check: file-exists .agents/scripts/supervisor-helper.sh
  check: shellcheck .agents/scripts/supervisor/todo-sync.sh
  check: file-exists .agents/scripts/supervisor/todo-sync.sh

- [x] v048 t319.5 Add pre-commit hook check for duplicate task IDs — when... | PR #1262 | merged:2026-02-12 verified:2026-02-12
  files: .agents/scripts/pre-commit-hook.sh
  check: shellcheck .agents/scripts/pre-commit-hook.sh
  check: file-exists .agents/scripts/pre-commit-hook.sh

- [!] v049 t319.6 Test end-to-end — simulate parallel task creation: two ... | PR #1263 | merged:2026-02-12 failed:2026-02-12 reason:shellcheck: .agents/scripts/test-task-id-collision.sh has violations
  files: .agents/scripts/test-task-id-collision.sh
  check: shellcheck .agents/scripts/test-task-id-collision.sh
  check: file-exists .agents/scripts/test-task-id-collision.sh

- [ ] v050 t318.2 Verify supervisor worker PRs include task ID | PR #1283 | merged:2026-02-12
  files: .agents/scripts/full-loop-helper.sh, .agents/scripts/supervisor-helper.sh
  check: shellcheck .agents/scripts/full-loop-helper.sh
  check: file-exists .agents/scripts/full-loop-helper.sh
  check: shellcheck .agents/scripts/supervisor-helper.sh
  check: file-exists .agents/scripts/supervisor-helper.sh

- [x] v051 t318.1 Create GitHub Action CI check for PR task ID | PR #1284 | merged:2026-02-12 verified:2026-02-12
  files: .github/PR-TASK-ID-CHECK-README.md
  check: file-exists .github/PR-TASK-ID-CHECK-README.md

- [!] v052 t1000 Matrix bot: SQLite session store with per-channel compact... | PR #1273 | merged:2026-02-12 failed:2026-02-12 reason:shellcheck: .agents/scripts/matrix-dispatch-helper.sh has violations
  files: .agents/scripts/matrix-dispatch-helper.sh, .agents/services/communications/matrix-bot.md, README.md
  check: shellcheck .agents/scripts/matrix-dispatch-helper.sh
  check: file-exists .agents/scripts/matrix-dispatch-helper.sh
  check: file-exists .agents/services/communications/matrix-bot.md
  check: file-exists README.md
  check: rg "matrix-bot" .agents/subagent-index.toon

- [x] v053 t1004 Ensure all task completion paths write pr:#NNN to TODO.md | PR #1295 | merged:2026-02-12 verified:2026-02-12
  files: .agents/scripts/supervisor/todo-sync.sh, .agents/scripts/version-manager.sh
  check: shellcheck .agents/scripts/supervisor/todo-sync.sh
  check: file-exists .agents/scripts/supervisor/todo-sync.sh
  check: shellcheck .agents/scripts/version-manager.sh
  check: file-exists .agents/scripts/version-manager.sh

- [ ] v054 t1009 Supervisor auto-updates GitHub issue status labels on eve... | PR #1299 | merged:2026-02-12
  files: .agents/scripts/issue-sync-helper.sh, .agents/scripts/supervisor-helper.sh, .agents/scripts/supervisor/issue-sync.sh
  check: shellcheck .agents/scripts/issue-sync-helper.sh
  check: file-exists .agents/scripts/issue-sync-helper.sh
  check: shellcheck .agents/scripts/supervisor-helper.sh
  check: file-exists .agents/scripts/supervisor-helper.sh
  check: shellcheck .agents/scripts/supervisor/issue-sync.sh
  check: file-exists .agents/scripts/supervisor/issue-sync.sh

- [!] v055 t1013 Pinned queue health issue — live supervisor status upda... | PR #1312 | merged:2026-02-12 failed:2026-02-12 reason:shellcheck: .agents/scripts/supervisor-helper.sh has violations
  files: .agents/scripts/supervisor-helper.sh, .agents/scripts/supervisor/pulse.sh
  check: shellcheck .agents/scripts/supervisor-helper.sh
  check: file-exists .agents/scripts/supervisor-helper.sh
  check: shellcheck .agents/scripts/supervisor/pulse.sh
  check: file-exists .agents/scripts/supervisor/pulse.sh

- [!] v056 t1008 Pre-dispatch reverification for previously-claimed tasks | PR #1316 | merged:2026-02-12 failed:2026-02-12 reason:shellcheck: .agents/scripts/supervisor-helper.sh has violations
  files: .agents/scripts/supervisor-helper.sh
  check: shellcheck .agents/scripts/supervisor-helper.sh
  check: file-exists .agents/scripts/supervisor-helper.sh

- [!] v057 t1021 Wire resolve_rebase_conflicts() into rebase_sibling_pr() ... | PR #1322 | merged:2026-02-12 failed:2026-02-12 reason:shellcheck: .agents/scripts/supervisor-helper.sh has violations
  files: .agents/scripts/supervisor-helper.sh
  check: shellcheck .agents/scripts/supervisor-helper.sh
  check: file-exists .agents/scripts/supervisor-helper.sh

- [!] v058 t1025 Track model usage per task via GitHub issue labels — ad... | PR #1345 | merged:2026-02-13 failed:2026-02-13 reason:shellcheck: .agents/scripts/model-label-helper.sh has violations
  files: .agents/scripts/model-label-helper.sh
  check: shellcheck .agents/scripts/model-label-helper.sh
  check: file-exists .agents/scripts/model-label-helper.sh

- [x] v059 t1027 Refactor opencode-aidevops/index.mjs — 14 qlty smells, ... | PR #1349 | merged:2026-02-13 verified:2026-02-13
  files: .agents/plugins/opencode-aidevops/index.mjs, .agents/plugins/opencode-aidevops/tools.mjs
  check: file-exists .agents/plugins/opencode-aidevops/index.mjs
  check: file-exists .agents/plugins/opencode-aidevops/tools.mjs

- [x] v060 t1026 Refactor playwright-automator.mjs — 33 qlty smells, 159... | PR #1350 | merged:2026-02-13 verified:2026-02-13
  files: .agents/scripts/higgsfield/playwright-automator.mjs
  check: file-exists .agents/scripts/higgsfield/playwright-automator.mjs

- [!] v061 t1028 Fix claim-task-id.sh to prefix GitHub/GitLab issue titles... | PR #1353 | merged:2026-02-13 failed:2026-02-13 reason:shellcheck: .agents/scripts/claim-task-id.sh has violations
  files: .agents/scripts/claim-task-id.sh
  check: shellcheck .agents/scripts/claim-task-id.sh
  check: file-exists .agents/scripts/claim-task-id.sh

- [!] v062 t1031 Modularize supervisor-helper.sh — move functions from 1... | PR #1359 | merged:2026-02-13 failed:2026-02-13 reason:shellcheck: .agents/scripts/supervisor-helper.sh has violations; shellcheck: .agents/scripts/supervisor/cron.sh has violations; shellcheck: .agents/scripts/supervisor/deploy.sh has violations;
  files: .agents/scripts/supervisor-helper.sh, .agents/scripts/supervisor/batch.sh, .agents/scripts/supervisor/cleanup.sh, .agents/scripts/supervisor/cron.sh, .agents/scripts/supervisor/database.sh, .agents/scripts/supervisor/deploy.sh, .agents/scripts/supervisor/dispatch.sh, .agents/scripts/supervisor/evaluate.sh, .agents/scripts/supervisor/issue-sync.sh, .agents/scripts/supervisor/memory-integration.sh, .agents/scripts/supervisor/pulse.sh, .agents/scripts/supervisor/self-heal.sh, .agents/scripts/supervisor/state.sh, .agents/scripts/supervisor/utility.sh
  check: shellcheck .agents/scripts/supervisor-helper.sh
  check: file-exists .agents/scripts/supervisor-helper.sh
  check: shellcheck .agents/scripts/supervisor/batch.sh
  check: file-exists .agents/scripts/supervisor/batch.sh
  check: shellcheck .agents/scripts/supervisor/cleanup.sh
  check: file-exists .agents/scripts/supervisor/cleanup.sh
  check: shellcheck .agents/scripts/supervisor/cron.sh
  check: file-exists .agents/scripts/supervisor/cron.sh
  check: shellcheck .agents/scripts/supervisor/database.sh
  check: file-exists .agents/scripts/supervisor/database.sh
  check: shellcheck .agents/scripts/supervisor/deploy.sh
  check: file-exists .agents/scripts/supervisor/deploy.sh
  check: shellcheck .agents/scripts/supervisor/dispatch.sh
  check: file-exists .agents/scripts/supervisor/dispatch.sh
  check: shellcheck .agents/scripts/supervisor/evaluate.sh
  check: file-exists .agents/scripts/supervisor/evaluate.sh
  check: shellcheck .agents/scripts/supervisor/issue-sync.sh
  check: file-exists .agents/scripts/supervisor/issue-sync.sh
  check: shellcheck .agents/scripts/supervisor/memory-integration.sh
  check: file-exists .agents/scripts/supervisor/memory-integration.sh
  check: shellcheck .agents/scripts/supervisor/pulse.sh
  check: file-exists .agents/scripts/supervisor/pulse.sh
  check: shellcheck .agents/scripts/supervisor/self-heal.sh
  check: file-exists .agents/scripts/supervisor/self-heal.sh
  check: shellcheck .agents/scripts/supervisor/state.sh
  check: file-exists .agents/scripts/supervisor/state.sh
  check: shellcheck .agents/scripts/supervisor/utility.sh
  check: file-exists .agents/scripts/supervisor/utility.sh

- [x] v063 t1032.4 Generalise task-creator to accept multi-source findings �... | PR #1379 | merged:2026-02-13 verified:2026-02-13
  files: .agents/scripts/audit-task-creator-helper.sh, .agents/scripts/coderabbit-task-creator-helper.sh, .agents/scripts/coderabbit-task-creator-helper.sh, .agents/subagent-index.toon
  check: shellcheck .agents/scripts/audit-task-creator-helper.sh
  check: file-exists .agents/scripts/audit-task-creator-helper.sh
  check: shellcheck .agents/scripts/coderabbit-task-creator-helper.sh
  check: file-exists .agents/scripts/coderabbit-task-creator-helper.sh
  check: shellcheck .agents/scripts/coderabbit-task-creator-helper.sh
  check: file-exists .agents/scripts/coderabbit-task-creator-helper.sh
  check: file-exists .agents/subagent-index.toon

- [!] v064 t1030 Guard complete-deployed transition to require PR merge wh... | PR #1385 | merged:2026-02-13 failed:2026-02-13 reason:shellcheck: .agents/scripts/supervisor/deploy.sh has violations; shellcheck: .agents/scripts/supervisor/pulse.sh has violations; shellcheck: tests/test-supervisor-state-machine.sh has violation
  files: .agents/scripts/supervisor/deploy.sh, .agents/scripts/supervisor/pulse.sh, .agents/scripts/supervisor/state.sh, tests/test-supervisor-state-machine.sh
  check: shellcheck .agents/scripts/supervisor/deploy.sh
  check: file-exists .agents/scripts/supervisor/deploy.sh
  check: shellcheck .agents/scripts/supervisor/pulse.sh
  check: file-exists .agents/scripts/supervisor/pulse.sh
  check: shellcheck .agents/scripts/supervisor/state.sh
  check: file-exists .agents/scripts/supervisor/state.sh
  check: shellcheck tests/test-supervisor-state-machine.sh
  check: file-exists tests/test-supervisor-state-machine.sh

- [!] v065 t1036 Migrate legacy [Supervisor] health issue to [Supervisor:u... | PR #1383 | merged:2026-02-13 failed:2026-02-13 reason:shellcheck: .agents/scripts/supervisor/issue-sync.sh has violations
  files: .agents/scripts/supervisor/issue-sync.sh
  check: shellcheck .agents/scripts/supervisor/issue-sync.sh
  check: file-exists .agents/scripts/supervisor/issue-sync.sh

- [!] v066 t1032.6 Add audit trend tracking — create an `audit_snapshots` ... | PR #1378 | merged:2026-02-13 failed:2026-02-13 reason:shellcheck: .agents/scripts/supervisor/pulse.sh has violations
  files: .agents/scripts/code-audit-helper.sh, .agents/scripts/supervisor/pulse.sh
  check: shellcheck .agents/scripts/code-audit-helper.sh
  check: file-exists .agents/scripts/code-audit-helper.sh
  check: shellcheck .agents/scripts/supervisor/pulse.sh
  check: file-exists .agents/scripts/supervisor/pulse.sh

- [x] v067 t1039 CI/pre-commit: reject PRs that add new files to repo root... | PR #1393 | merged:2026-02-13 verified:2026-02-13
  files: .agents/scripts/pre-commit-hook.sh
  check: shellcheck .agents/scripts/pre-commit-hook.sh
  check: file-exists .agents/scripts/pre-commit-hook.sh

- [x] v068 t1032.2 Add Codacy collector — poll Codacy API (`/analysis/orga... | PR #1384 | merged:2026-02-13 verified:2026-02-13
  files: .agents/scripts/codacy-collector-helper.sh
  check: shellcheck .agents/scripts/codacy-collector-helper.sh
  check: file-exists .agents/scripts/codacy-collector-helper.sh

- [!] v069 t1033 claim-task-id.sh should accept --labels or parse #tags fr... | PR #1398 | merged:2026-02-13 failed:2026-02-13 reason:shellcheck: .agents/scripts/claim-task-id.sh has violations; shellcheck: .agents/scripts/supervisor/pulse.sh has violations
  files: .agents/scripts/audit-task-creator-helper.sh, .agents/scripts/claim-task-id.sh, .agents/scripts/supervisor/pulse.sh
  check: shellcheck .agents/scripts/audit-task-creator-helper.sh
  check: file-exists .agents/scripts/audit-task-creator-helper.sh
  check: shellcheck .agents/scripts/claim-task-id.sh
  check: file-exists .agents/scripts/claim-task-id.sh
  check: shellcheck .agents/scripts/supervisor/pulse.sh
  check: file-exists .agents/scripts/supervisor/pulse.sh

- [!] v070 t1032.3 Add SonarCloud collector — poll SonarCloud API (`/issue... | PR #1380 | merged:2026-02-13 failed:2026-02-13 reason:shellcheck: .agents/scripts/sonarcloud-collector-helper.sh has violations
  files: .agents/scripts/sonarcloud-collector-helper.sh
  check: shellcheck .agents/scripts/sonarcloud-collector-helper.sh
  check: file-exists .agents/scripts/sonarcloud-collector-helper.sh

- [!] v071 t1041 Fix generate-opencode-agents.sh subagent stub generation ... | PR #1402 | merged:2026-02-13 failed:2026-02-13 reason:shellcheck: .agents/scripts/generate-opencode-agents.sh has violations
  files: .agents/scripts/generate-opencode-agents.sh
  check: shellcheck .agents/scripts/generate-opencode-agents.sh
  check: file-exists .agents/scripts/generate-opencode-agents.sh

- [!] v072 t1032.5 Wire Phase 10b to run unified audit orchestrator — repl... | PR #1377 | merged:2026-02-13 failed:2026-02-13 reason:shellcheck: .agents/scripts/supervisor/pulse.sh has violations
  files: .agents/scripts/supervisor/pulse.sh
  check: shellcheck .agents/scripts/supervisor/pulse.sh
  check: file-exists .agents/scripts/supervisor/pulse.sh

- [x] v073 t1032.8 Verify end-to-end — trigger a full audit cycle manually... | PR #1381 | merged:2026-02-13 verified:2026-02-13
  files: tests/test-audit-e2e.sh
  check: shellcheck tests/test-audit-e2e.sh
  check: file-exists tests/test-audit-e2e.sh

- [!] v074 t1032.7 Add audit section to pinned queue health issue — extend... | PR #1399 | merged:2026-02-13 failed:2026-02-13 reason:shellcheck: .agents/scripts/supervisor/issue-sync.sh has violations
  files: .agents/scripts/supervisor/issue-sync.sh
  check: shellcheck .agents/scripts/supervisor/issue-sync.sh
  check: file-exists .agents/scripts/supervisor/issue-sync.sh

- [x] v075 t1032.1 Implement code-audit-helper.sh — unified audit orchestr... | PR #1376 | merged:2026-02-13 verified:2026-02-13
  files: .agents/scripts/code-audit-helper.sh
  check: shellcheck .agents/scripts/code-audit-helper.sh
  check: file-exists .agents/scripts/code-audit-helper.sh

- [!] v076 t1043 Add Reader-LM and RolmOCR as conversion providers in docu... | PR #1411 | merged:2026-02-13 failed:2026-02-13 reason:rg: "document-creation" not found in .agents/subagent-index.toon
  files: .agents/scripts/document-creation-helper.sh, .agents/tools/document/document-creation.md
  check: shellcheck .agents/scripts/document-creation-helper.sh
  check: file-exists .agents/scripts/document-creation-helper.sh
  check: file-exists .agents/tools/document/document-creation.md
  check: rg "document-creation" .agents/subagent-index.toon

- [!] v077 t1044.2 Visible headers as YAML frontmatter — from, to, cc, bcc... | PR #1421 | merged:2026-02-14 failed:2026-02-14 reason:rg: "document-creation" not found in .agents/subagent-index.toon
  files: .agents/scripts/document-creation-helper.sh, .agents/scripts/email-to-markdown.py, .agents/tools/document/document-creation.md
  check: shellcheck .agents/scripts/document-creation-helper.sh
  check: file-exists .agents/scripts/document-creation-helper.sh
  check: file-exists .agents/scripts/email-to-markdown.py
  check: file-exists .agents/tools/document/document-creation.md
  check: rg "document-creation" .agents/subagent-index.toon

- [x] v078 t1044.3 Email signature parsing to contact TOON records — detec... | PR #1424 | merged:2026-02-14 verified:2026-02-14
  files: .agents/scripts/email-signature-parser-helper.sh, tests/email-signature-test-fixtures/best-regards.txt, tests/email-signature-test-fixtures/company-keywords.txt, tests/email-signature-test-fixtures/minimal.txt, tests/email-signature-test-fixtures/multiple-emails.txt, tests/email-signature-test-fixtures/no-signature.txt, tests/email-signature-test-fixtures/standard-business.txt, tests/email-signature-test-fixtures/with-address.txt, tests/test-email-signature-parser.sh
  check: shellcheck .agents/scripts/email-signature-parser-helper.sh
  check: file-exists .agents/scripts/email-signature-parser-helper.sh
  check: file-exists tests/email-signature-test-fixtures/best-regards.txt
  check: file-exists tests/email-signature-test-fixtures/company-keywords.txt
  check: file-exists tests/email-signature-test-fixtures/minimal.txt
  check: file-exists tests/email-signature-test-fixtures/multiple-emails.txt
  check: file-exists tests/email-signature-test-fixtures/no-signature.txt
  check: file-exists tests/email-signature-test-fixtures/standard-business.txt
  check: file-exists tests/email-signature-test-fixtures/with-address.txt
  check: shellcheck tests/test-email-signature-parser.sh
  check: file-exists tests/test-email-signature-parser.sh

- [x] v079 t1044.6 Entity extraction from email bodies — extract people, o... | PR #1438 | merged:2026-02-14 verified:2026-02-14
  files: .agents/scripts/document-creation-helper.sh, .agents/scripts/email-to-markdown.py, .agents/scripts/entity-extraction.py
  check: shellcheck .agents/scripts/document-creation-helper.sh
  check: file-exists .agents/scripts/document-creation-helper.sh
  check: file-exists .agents/scripts/email-to-markdown.py
  check: file-exists .agents/scripts/entity-extraction.py

- [x] v080 t1046.3 Integration with convert pipeline — auto-run normalise ... | PR #1456 | merged:2026-02-14 verified:2026-02-14
  files: .agents/scripts/document-creation-helper.sh
  check: shellcheck .agents/scripts/document-creation-helper.sh
  check: file-exists .agents/scripts/document-creation-helper.sh

- [x] v081 t1052.7 Auto-summary generation — generate 1-2 sentence summary... | PR #1459 | merged:2026-02-14 verified:2026-02-14
  files: .agents/scripts/email-summary.py, .agents/scripts/email-to-markdown.py
  check: file-exists .agents/scripts/email-summary.py
  check: file-exists .agents/scripts/email-to-markdown.py

- [x] v082 t1055.9 Collection manifest — generate `_index.toon` with doc/t... | PR #1468 | merged:2026-02-14 verified:2026-02-14
  files: .agents/scripts/document-creation-helper.sh, tests/test-collection-manifest.sh
  check: shellcheck .agents/scripts/document-creation-helper.sh
  check: file-exists .agents/scripts/document-creation-helper.sh
  check: shellcheck tests/test-collection-manifest.sh
  check: file-exists tests/test-collection-manifest.sh

- [x] v083 t1056.1 Add `install-app` and `uninstall-app` commands to cloudro... | PR #1470 | merged:2026-02-14 verified:2026-02-14
  files: .agents/scripts/cloudron-helper.sh
  check: shellcheck .agents/scripts/cloudron-helper.sh
  check: file-exists .agents/scripts/cloudron-helper.sh

- [x] v084 t1056.3 Implement `auto-setup` command — Orchestrates the full ... | PR #1474 | merged:2026-02-14 verified:2026-02-14
  files: .agents/scripts/matrix-dispatch-helper.sh
  check: shellcheck .agents/scripts/matrix-dispatch-helper.sh
  check: file-exists .agents/scripts/matrix-dispatch-helper.sh

- [!] v085 t1048 Fix auto-rebase: handle AI-completed rebase and increase ... | PR #1478 | merged:2026-02-14 failed:2026-02-14 reason:shellcheck: .agents/scripts/supervisor/deploy.sh has violations
  files: .agents/scripts/supervisor/deploy.sh
  check: shellcheck .agents/scripts/supervisor/deploy.sh
  check: file-exists .agents/scripts/supervisor/deploy.sh

- [!] v086 t1049 Fix auto-rebase: abort stale rebase state before retrying... | PR #1480 | merged:2026-02-14 failed:2026-02-14 reason:shellcheck: .agents/scripts/supervisor/deploy.sh has violations
  files: .agents/scripts/supervisor/deploy.sh
  check: shellcheck .agents/scripts/supervisor/deploy.sh
  check: file-exists .agents/scripts/supervisor/deploy.sh

- [!] v087 t1050 Escalate rebase-blocked PRs to opus worker for sequential... | PR #1484 | merged:2026-02-14 failed:2026-02-14 reason:shellcheck: .agents/scripts/supervisor/pulse.sh has violations
  files: .agents/scripts/supervisor/pulse.sh
  check: shellcheck .agents/scripts/supervisor/pulse.sh
  check: file-exists .agents/scripts/supervisor/pulse.sh

- [x] v088 t1047 Fix task ID race condition: replace TODO.md scanning with... | PR #1458 | merged:2026-02-14 verified:2026-02-14
  files: .agents/scripts/claim-task-id.sh
  check: shellcheck .agents/scripts/claim-task-id.sh
  check: file-exists .agents/scripts/claim-task-id.sh

- [!] v089 t1053 Auto-generate VERIFY.md entries during deploy phase — w... | PR #1497 | merged:2026-02-15 failed:2026-02-15 reason:shellcheck: .agents/scripts/supervisor/deploy.sh has violations
  files: .agents/scripts/supervisor/deploy.sh, .agents/scripts/supervisor/todo-sync.sh
  check: shellcheck .agents/scripts/supervisor/deploy.sh
  check: file-exists .agents/scripts/supervisor/deploy.sh
  check: shellcheck .agents/scripts/supervisor/todo-sync.sh
  check: file-exists .agents/scripts/supervisor/todo-sync.sh

- [x] v090 t1052 Batch post-completion actions to reduce auto-verification... | PR #1498 | merged:2026-02-15 verified:2026-02-15
  files: .agents/scripts/supervisor/pulse.sh, .agents/scripts/supervisor/state.sh
  check: shellcheck .agents/scripts/supervisor/pulse.sh
  check: file-exists .agents/scripts/supervisor/pulse.sh
  check: shellcheck .agents/scripts/supervisor/state.sh
  check: file-exists .agents/scripts/supervisor/state.sh

- [ ] v091 t1054 Import chrome-webstore-release-blueprint skill into aidev... | PR #1500 | merged:2026-02-15
  files: .agents/scripts/chrome-webstore-helper.sh, .agents/subagent-index.toon, .agents/tools/browser/chrome-webstore-release.md
  check: shellcheck .agents/scripts/chrome-webstore-helper.sh
  check: file-exists .agents/scripts/chrome-webstore-helper.sh
  check: file-exists .agents/subagent-index.toon
  check: file-exists .agents/tools/browser/chrome-webstore-release.md
  check: rg "chrome-webstore-release" .agents/subagent-index.toon

- [x] v092 t1061 Add Qwen3-TTS as TTS provider in voice agent — Qwen3-TT... | PR #1517 | merged:2026-02-16 verified:2026-02-16
  files: .agents/scripts/voice-helper.sh, .agents/subagent-index.toon, .agents/tools/voice/qwen3-tts.md, .agents/tools/voice/speech-to-speech.md
  check: shellcheck .agents/scripts/voice-helper.sh
  check: file-exists .agents/scripts/voice-helper.sh
  check: file-exists .agents/subagent-index.toon
  check: file-exists .agents/tools/voice/qwen3-tts.md
  check: file-exists .agents/tools/voice/speech-to-speech.md
  check: rg "qwen3-tts" .agents/subagent-index.toon
  check: rg "speech-to-speech" .agents/subagent-index.toon

- [x] v093 t1062 Supervisor auto-pickup should skip tasks with assignee: o... | PR #1520 | merged:2026-02-16 verified:2026-02-16
  files: .agents/AGENTS.md, .agents/scripts/supervisor/cron.sh
  check: file-exists .agents/AGENTS.md
  check: shellcheck .agents/scripts/supervisor/cron.sh
  check: file-exists .agents/scripts/supervisor/cron.sh

- [ ] v094 t1063.2 Create tools/research/tech-stack-lookup.md agent — prog... | PR #1531 | merged:2026-02-16
  files: .agents/tools/research/tech-stack-lookup.md
  check: file-exists .agents/tools/research/tech-stack-lookup.md
  check: rg "tech-stack-lookup" .agents/subagent-index.toon

- [ ] v095 t1066 Open Tech Explorer provider agent — create `tools/resea... | PR #1544 | merged:2026-02-16
  files: .agents/scripts/tech-stack-helper.sh, .agents/tools/research/providers/openexplorer.md
  check: shellcheck .agents/scripts/tech-stack-helper.sh
  check: file-exists .agents/scripts/tech-stack-helper.sh
  check: file-exists .agents/tools/research/providers/openexplorer.md
  check: rg "openexplorer" .agents/subagent-index.toon

- [x] v096 t1063.3 Add `/tech-stack` slash command — `tech-stack <url>` fo... | PR #1530 | merged:2026-02-16 verified:2026-02-16
  files: .agents/scripts/commands/tech-stack.md
  check: file-exists .agents/scripts/commands/tech-stack.md

- [ ] v097 t1067 Wappalyzer OSS provider agent — create `tools/research/... | PR #1536 | merged:2026-02-16
  files: .agents/scripts/package.json, .agents/scripts/wappalyzer-detect.mjs, .agents/scripts/wappalyzer-helper.sh, .agents/tools/research/providers/wappalyzer.md
  check: file-exists .agents/scripts/package.json
  check: file-exists .agents/scripts/wappalyzer-detect.mjs
  check: shellcheck .agents/scripts/wappalyzer-helper.sh
  check: file-exists .agents/scripts/wappalyzer-helper.sh
  check: file-exists .agents/tools/research/providers/wappalyzer.md
  check: rg "wappalyzer" .agents/subagent-index.toon

- [x] v098 t1069 Fix dedup_todo_task_ids() — rename-on-duplicate creates... | PR #1549 | merged:2026-02-16 verified:2026-02-16
  files: .agents/scripts/supervisor/todo-sync.sh
  check: shellcheck .agents/scripts/supervisor/todo-sync.sh
  check: file-exists .agents/scripts/supervisor/todo-sync.sh

- [x] v099 t1070 Post blocked reason comment on GitHub issues when status:... | PR #1551 | merged:2026-02-16 verified:2026-02-16
  files: .agents/scripts/supervisor/backfill-blocked-comments.sh, .agents/scripts/supervisor/issue-sync.sh
  check: shellcheck .agents/scripts/supervisor/backfill-blocked-comments.sh
  check: file-exists .agents/scripts/supervisor/backfill-blocked-comments.sh
  check: shellcheck .agents/scripts/supervisor/issue-sync.sh
  check: file-exists .agents/scripts/supervisor/issue-sync.sh

- [!] v100 t1064 Unbuilt.app provider agent — create `tools/research/pro... | PR #1542 | merged:2026-02-17 failed:2026-02-17 reason:shellcheck: .agents/scripts/tech-stack-helper.sh has violations
  files: .agents/scripts/tech-stack-helper.sh, .agents/subagent-index.toon, .agents/tools/research/providers/unbuilt.md
  check: shellcheck .agents/scripts/tech-stack-helper.sh
  check: file-exists .agents/scripts/tech-stack-helper.sh
  check: file-exists .agents/subagent-index.toon
  check: file-exists .agents/tools/research/providers/unbuilt.md
  check: rg "unbuilt" .agents/subagent-index.toon

- [!] v101 t1065 CRFT Lookup provider agent — create `tools/research/pro... | PR #1543 | merged:2026-02-17 failed:2026-02-17 reason:shellcheck: .agents/scripts/tech-stack-helper.sh has violations
  files: .agents/scripts/tech-stack-helper.sh, .agents/subagent-index.toon, .agents/tools/research/providers/crft-lookup.md
  check: shellcheck .agents/scripts/tech-stack-helper.sh
  check: file-exists .agents/scripts/tech-stack-helper.sh
  check: file-exists .agents/subagent-index.toon
  check: file-exists .agents/tools/research/providers/crft-lookup.md
  check: rg "crft-lookup" .agents/subagent-index.toon

- [!] v102 t1063 Tech stack lookup orchestrator agent and command — crea... | PR #1541 | merged:2026-02-17 failed:2026-02-17 reason:shellcheck: .agents/scripts/tech-stack-helper.sh has violations
  files: .agents/AGENTS.md, .agents/scripts/commands/tech-stack.md, .agents/scripts/tech-stack-helper.sh, .agents/subagent-index.toon
  check: file-exists .agents/AGENTS.md
  check: file-exists .agents/scripts/commands/tech-stack.md
  check: shellcheck .agents/scripts/tech-stack-helper.sh
  check: file-exists .agents/scripts/tech-stack-helper.sh
  check: file-exists .agents/subagent-index.toon

- [!] v103 t1072 Add rebase loop for multi-commit conflict resolution in r... | PR #1558 | merged:2026-02-17 failed:2026-02-17 reason:shellcheck: .agents/scripts/supervisor/deploy.sh has violations
  files: .agents/scripts/supervisor/deploy.sh, .agents/scripts/supervisor/state.sh
  check: shellcheck .agents/scripts/supervisor/deploy.sh
  check: file-exists .agents/scripts/supervisor/deploy.sh
  check: shellcheck .agents/scripts/supervisor/state.sh
  check: file-exists .agents/scripts/supervisor/state.sh

- [x] v104 t1063.1 Create tech-stack-helper.sh with `lookup <url>`, `reverse... | PR #1545 | merged:2026-02-17 verified:2026-02-17
  files: .agents/scripts/tech-stack-helper.sh
  check: shellcheck .agents/scripts/tech-stack-helper.sh
  check: file-exists .agents/scripts/tech-stack-helper.sh

- [!] v105 t1068 Reverse tech stack lookup with filtering — extend tech-... | PR #1546 | merged:2026-02-17 failed:2026-02-17 reason:shellcheck: .agents/scripts/tech-stack-helper.sh has violations
  files: .agents/scripts/tech-stack-helper.sh, .agents/seo/tech-stack.md
  check: shellcheck .agents/scripts/tech-stack-helper.sh
  check: file-exists .agents/scripts/tech-stack-helper.sh
  check: file-exists .agents/seo/tech-stack.md

- [x] v106 t1059 wp-helper.sh tenant-aware server reference resolution + S... | PR #1568 | merged:2026-02-17 verified:2026-02-17
  files: .agents/configs/wordpress-sites.json.txt, .agents/scripts/wp-helper.sh
  check: file-exists .agents/configs/wordpress-sites.json.txt
  check: shellcheck .agents/scripts/wp-helper.sh
  check: file-exists .agents/scripts/wp-helper.sh

- [x] v107 t1060 worktree-helper.sh detect stale remote branches before cr... | PR #1567 | merged:2026-02-17 verified:2026-02-17
  files: .agents/scripts/worktree-helper.sh
  check: shellcheck .agents/scripts/worktree-helper.sh
  check: file-exists .agents/scripts/worktree-helper.sh

- [!] v108 t1080 Delete archived scripts in `.agents/scripts/_archive/` �... | PR #1574 | merged:2026-02-17 failed:2026-02-17 reason:file-exists: .agents/scripts/_archive/README.md not found; shellcheck: .agents/scripts/_archive/add-missing-returns.sh has violations; file-exists: .agents/scripts/_archive/add-missing-return
  files: .agents/scripts/_archive/README.md, .agents/scripts/_archive/add-missing-returns.sh, .agents/scripts/_archive/comprehensive-quality-fix.sh, .agents/scripts/_archive/efficient-return-fix.sh, .agents/scripts/_archive/find-missing-returns.sh, .agents/scripts/_archive/fix-auth-headers.sh, .agents/scripts/_archive/fix-common-strings.sh, .agents/scripts/_archive/fix-content-type.sh, .agents/scripts/_archive/fix-error-messages.sh, .agents/scripts/_archive/fix-misplaced-returns.sh, .agents/scripts/_archive/fix-remaining-literals.sh, .agents/scripts/_archive/fix-return-statements.sh, .agents/scripts/_archive/fix-s131-default-cases.sh, .agents/scripts/_archive/fix-sc2155-simple.sh, .agents/scripts/_archive/fix-shellcheck-critical.sh, .agents/scripts/_archive/fix-string-literals.sh, .agents/scripts/_archive/mass-fix-returns.sh
  check: file-exists .agents/scripts/_archive/README.md
  check: shellcheck .agents/scripts/_archive/add-missing-returns.sh
  check: file-exists .agents/scripts/_archive/add-missing-returns.sh
  check: shellcheck .agents/scripts/_archive/comprehensive-quality-fix.sh
  check: file-exists .agents/scripts/_archive/comprehensive-quality-fix.sh
  check: shellcheck .agents/scripts/_archive/efficient-return-fix.sh
  check: file-exists .agents/scripts/_archive/efficient-return-fix.sh
  check: shellcheck .agents/scripts/_archive/find-missing-returns.sh
  check: file-exists .agents/scripts/_archive/find-missing-returns.sh
  check: shellcheck .agents/scripts/_archive/fix-auth-headers.sh
  check: file-exists .agents/scripts/_archive/fix-auth-headers.sh
  check: shellcheck .agents/scripts/_archive/fix-common-strings.sh
  check: file-exists .agents/scripts/_archive/fix-common-strings.sh
  check: shellcheck .agents/scripts/_archive/fix-content-type.sh
  check: file-exists .agents/scripts/_archive/fix-content-type.sh
  check: shellcheck .agents/scripts/_archive/fix-error-messages.sh
  check: file-exists .agents/scripts/_archive/fix-error-messages.sh
  check: shellcheck .agents/scripts/_archive/fix-misplaced-returns.sh
  check: file-exists .agents/scripts/_archive/fix-misplaced-returns.sh
  check: shellcheck .agents/scripts/_archive/fix-remaining-literals.sh
  check: file-exists .agents/scripts/_archive/fix-remaining-literals.sh
  check: shellcheck .agents/scripts/_archive/fix-return-statements.sh
  check: file-exists .agents/scripts/_archive/fix-return-statements.sh
  check: shellcheck .agents/scripts/_archive/fix-s131-default-cases.sh
  check: file-exists .agents/scripts/_archive/fix-s131-default-cases.sh
  check: shellcheck .agents/scripts/_archive/fix-sc2155-simple.sh
  check: file-exists .agents/scripts/_archive/fix-sc2155-simple.sh
  check: shellcheck .agents/scripts/_archive/fix-shellcheck-critical.sh
  check: file-exists .agents/scripts/_archive/fix-shellcheck-critical.sh
  check: shellcheck .agents/scripts/_archive/fix-string-literals.sh
  check: file-exists .agents/scripts/_archive/fix-string-literals.sh
  check: shellcheck .agents/scripts/_archive/mass-fix-returns.sh
  check: file-exists .agents/scripts/_archive/mass-fix-returns.sh

- [x] v109 t1077 Fix ShellCheck SC2034 warnings across 9 files (30 unused ... | PR #1576 | merged:2026-02-17 verified:2026-02-17
  files: .agents/scripts/code-audit-helper.sh, .agents/scripts/coderabbit-cli.sh, .agents/scripts/setup/_backup.sh, .agents/scripts/sonarcloud-autofix.sh, .agents/scripts/supervisor-helper.sh, .agents/scripts/supervisor/deploy.sh, .agents/scripts/supervisor/dispatch.sh, .agents/scripts/tech-stack-helper.sh, .agents/scripts/test-orphan-cleanup.sh
  check: shellcheck .agents/scripts/code-audit-helper.sh
  check: file-exists .agents/scripts/code-audit-helper.sh
  check: shellcheck .agents/scripts/coderabbit-cli.sh
  check: file-exists .agents/scripts/coderabbit-cli.sh
  check: shellcheck .agents/scripts/setup/_backup.sh
  check: file-exists .agents/scripts/setup/_backup.sh
  check: shellcheck .agents/scripts/sonarcloud-autofix.sh
  check: file-exists .agents/scripts/sonarcloud-autofix.sh
  check: shellcheck .agents/scripts/supervisor-helper.sh
  check: file-exists .agents/scripts/supervisor-helper.sh
  check: shellcheck .agents/scripts/supervisor/deploy.sh
  check: file-exists .agents/scripts/supervisor/deploy.sh
  check: shellcheck .agents/scripts/supervisor/dispatch.sh
  check: file-exists .agents/scripts/supervisor/dispatch.sh
  check: shellcheck .agents/scripts/tech-stack-helper.sh
  check: file-exists .agents/scripts/tech-stack-helper.sh
  check: shellcheck .agents/scripts/test-orphan-cleanup.sh
  check: file-exists .agents/scripts/test-orphan-cleanup.sh

- [x] v110 t1078 Add explicit return statements to 21 shell scripts missin... | PR #1575 | merged:2026-02-17 verified:2026-02-17
  files: .agents/scripts/cron-dispatch.sh, .agents/scripts/list-verify-helper.sh, .agents/scripts/session-distill-helper.sh, .agents/scripts/setup/_backup.sh, .agents/scripts/setup/_bootstrap.sh, .agents/scripts/setup/_deployment.sh, .agents/scripts/setup/_installation.sh, .agents/scripts/setup/_migration.sh, .agents/scripts/setup/_opencode.sh, .agents/scripts/setup/_services.sh, .agents/scripts/setup/_shell.sh, .agents/scripts/setup/_tools.sh, .agents/scripts/setup/_validation.sh, .agents/scripts/show-plan-helper.sh, .agents/scripts/subagent-index-helper.sh, .agents/scripts/supervisor/_common.sh, .agents/scripts/supervisor/git-ops.sh, .agents/scripts/supervisor/lifecycle.sh, .agents/scripts/test-orphan-cleanup.sh, .agents/scripts/test-pr-task-check.sh, .agents/scripts/test-task-id-collision.sh
  check: shellcheck .agents/scripts/cron-dispatch.sh
  check: file-exists .agents/scripts/cron-dispatch.sh
  check: shellcheck .agents/scripts/list-verify-helper.sh
  check: file-exists .agents/scripts/list-verify-helper.sh
  check: shellcheck .agents/scripts/session-distill-helper.sh
  check: file-exists .agents/scripts/session-distill-helper.sh
  check: shellcheck .agents/scripts/setup/_backup.sh
  check: file-exists .agents/scripts/setup/_backup.sh
  check: shellcheck .agents/scripts/setup/_bootstrap.sh
  check: file-exists .agents/scripts/setup/_bootstrap.sh
  check: shellcheck .agents/scripts/setup/_deployment.sh
  check: file-exists .agents/scripts/setup/_deployment.sh
  check: shellcheck .agents/scripts/setup/_installation.sh
  check: file-exists .agents/scripts/setup/_installation.sh
  check: shellcheck .agents/scripts/setup/_migration.sh
  check: file-exists .agents/scripts/setup/_migration.sh
  check: shellcheck .agents/scripts/setup/_opencode.sh
  check: file-exists .agents/scripts/setup/_opencode.sh
  check: shellcheck .agents/scripts/setup/_services.sh
  check: file-exists .agents/scripts/setup/_services.sh
  check: shellcheck .agents/scripts/setup/_shell.sh
  check: file-exists .agents/scripts/setup/_shell.sh
  check: shellcheck .agents/scripts/setup/_tools.sh
  check: file-exists .agents/scripts/setup/_tools.sh
  check: shellcheck .agents/scripts/setup/_validation.sh
  check: file-exists .agents/scripts/setup/_validation.sh
  check: shellcheck .agents/scripts/show-plan-helper.sh
  check: file-exists .agents/scripts/show-plan-helper.sh
  check: shellcheck .agents/scripts/subagent-index-helper.sh
  check: file-exists .agents/scripts/subagent-index-helper.sh
  check: shellcheck .agents/scripts/supervisor/_common.sh
  check: file-exists .agents/scripts/supervisor/_common.sh
  check: shellcheck .agents/scripts/supervisor/git-ops.sh
  check: file-exists .agents/scripts/supervisor/git-ops.sh
  check: shellcheck .agents/scripts/supervisor/lifecycle.sh
  check: file-exists .agents/scripts/supervisor/lifecycle.sh
  check: shellcheck .agents/scripts/test-orphan-cleanup.sh
  check: file-exists .agents/scripts/test-orphan-cleanup.sh
  check: shellcheck .agents/scripts/test-pr-task-check.sh
  check: file-exists .agents/scripts/test-pr-task-check.sh
  check: shellcheck .agents/scripts/test-task-id-collision.sh
  check: file-exists .agents/scripts/test-task-id-collision.sh

- [x] v111 t1081 Daily skill auto-update pipeline — add daily skill fres... | PR #1591 | merged:2026-02-17 verified:2026-02-17
  files: .agents/scripts/auto-update-helper.sh
  check: shellcheck .agents/scripts/auto-update-helper.sh
  check: file-exists .agents/scripts/auto-update-helper.sh

- [x] v112 t1082 Maintainer skill-update PR pipeline — new skill-update-... | PR #1593 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/skill-update-helper.sh
  check: shellcheck .agents/scripts/skill-update-helper.sh
  check: file-exists .agents/scripts/skill-update-helper.sh

- [!] v113 t1083 Update model references for Claude Sonnet 4.6 — Anthrop... | PR #1594 | merged:2026-02-18 failed:2026-02-18 reason:rg: "fallback-chains" not found in .agents/subagent-index.toon; rg: "opencode-github" not found in .agents/subagent-index.toon; rg: "opencode-gitlab" not found in .agents/subagent-index.toon; rg: "
  files: .agents/configs/fallback-chain-config.json.txt, .agents/scripts/agent-test-helper.sh, .agents/scripts/contest-helper.sh, .agents/scripts/cron-dispatch.sh, .agents/scripts/cron-helper.sh, .agents/scripts/document-extraction-helper.sh, .agents/scripts/fallback-chain-helper.sh, .agents/scripts/generate-opencode-agents.sh, .agents/scripts/model-availability-helper.sh, .agents/scripts/model-label-helper.sh, .agents/scripts/model-registry-helper.sh, .agents/scripts/objective-runner-helper.sh, .agents/scripts/opencode-github-setup-helper.sh, .agents/scripts/pipecat-helper.sh, .agents/scripts/runner-helper.sh, .agents/scripts/shared-constants.sh, .agents/scripts/supervisor/dispatch.sh, .agents/services/hosting/cloudflare-platform/references/ai-gateway/README.md, .agents/subagent-index.toon, .agents/tools/ai-assistants/fallback-chains.md, .agents/tools/ai-assistants/headless-dispatch.md, .agents/tools/ai-assistants/models/README.md, .agents/tools/ai-assistants/models/opus.md, .agents/tools/ai-assistants/models/pro.md, .agents/tools/ai-assistants/models/sonnet.md, .agents/tools/ai-assistants/opencode-server.md, .agents/tools/automation/cron-agent.md, .agents/tools/build-agent/agent-testing.md, .agents/tools/content/summarize.md, .agents/tools/context/model-routing.md, .agents/tools/git/opencode-github.md, .agents/tools/git/opencode-gitlab.md, .agents/tools/opencode/opencode-anthropic-auth.md, .agents/tools/opencode/opencode.md, .agents/tools/vision/image-understanding.md, .agents/tools/voice/pipecat-opencode.md, .opencode/lib/ai-research.ts, configs/mcp-templates/opencode-github-workflow.yml, tests/test-batch-quality-hardening.sh
  check: file-exists .agents/configs/fallback-chain-config.json.txt
  check: shellcheck .agents/scripts/agent-test-helper.sh
  check: file-exists .agents/scripts/agent-test-helper.sh
  check: shellcheck .agents/scripts/contest-helper.sh
  check: file-exists .agents/scripts/contest-helper.sh
  check: shellcheck .agents/scripts/cron-dispatch.sh
  check: file-exists .agents/scripts/cron-dispatch.sh
  check: shellcheck .agents/scripts/cron-helper.sh
  check: file-exists .agents/scripts/cron-helper.sh
  check: shellcheck .agents/scripts/document-extraction-helper.sh
  check: file-exists .agents/scripts/document-extraction-helper.sh
  check: shellcheck .agents/scripts/fallback-chain-helper.sh
  check: file-exists .agents/scripts/fallback-chain-helper.sh
  check: shellcheck .agents/scripts/generate-opencode-agents.sh
  check: file-exists .agents/scripts/generate-opencode-agents.sh
  check: shellcheck .agents/scripts/model-availability-helper.sh
  check: file-exists .agents/scripts/model-availability-helper.sh
  check: shellcheck .agents/scripts/model-label-helper.sh
  check: file-exists .agents/scripts/model-label-helper.sh
  check: shellcheck .agents/scripts/model-registry-helper.sh
  check: file-exists .agents/scripts/model-registry-helper.sh
  check: shellcheck .agents/scripts/objective-runner-helper.sh
  check: file-exists .agents/scripts/objective-runner-helper.sh
  check: shellcheck .agents/scripts/opencode-github-setup-helper.sh
  check: file-exists .agents/scripts/opencode-github-setup-helper.sh
  check: shellcheck .agents/scripts/pipecat-helper.sh
  check: file-exists .agents/scripts/pipecat-helper.sh
  check: shellcheck .agents/scripts/runner-helper.sh
  check: file-exists .agents/scripts/runner-helper.sh
  check: shellcheck .agents/scripts/shared-constants.sh
  check: file-exists .agents/scripts/shared-constants.sh
  check: shellcheck .agents/scripts/supervisor/dispatch.sh
  check: file-exists .agents/scripts/supervisor/dispatch.sh
  check: file-exists .agents/services/hosting/cloudflare-platform/references/ai-gateway/README.md
  check: file-exists .agents/subagent-index.toon
  check: file-exists .agents/tools/ai-assistants/fallback-chains.md
  check: file-exists .agents/tools/ai-assistants/headless-dispatch.md
  check: file-exists .agents/tools/ai-assistants/models/README.md
  check: file-exists .agents/tools/ai-assistants/models/opus.md
  check: file-exists .agents/tools/ai-assistants/models/pro.md
  check: file-exists .agents/tools/ai-assistants/models/sonnet.md
  check: file-exists .agents/tools/ai-assistants/opencode-server.md
  check: file-exists .agents/tools/automation/cron-agent.md
  check: file-exists .agents/tools/build-agent/agent-testing.md
  check: file-exists .agents/tools/content/summarize.md
  check: file-exists .agents/tools/context/model-routing.md
  check: file-exists .agents/tools/git/opencode-github.md
  check: file-exists .agents/tools/git/opencode-gitlab.md
  check: file-exists .agents/tools/opencode/opencode-anthropic-auth.md
  check: file-exists .agents/tools/opencode/opencode.md
  check: file-exists .agents/tools/vision/image-understanding.md
  check: file-exists .agents/tools/voice/pipecat-opencode.md
  check: file-exists .opencode/lib/ai-research.ts
  check: file-exists configs/mcp-templates/opencode-github-workflow.yml
  check: shellcheck tests/test-batch-quality-hardening.sh
  check: file-exists tests/test-batch-quality-hardening.sh
  check: rg "README" .agents/subagent-index.toon
  check: rg "fallback-chains" .agents/subagent-index.toon
  check: rg "headless-dispatch" .agents/subagent-index.toon
  check: rg "README" .agents/subagent-index.toon
  check: rg "opus" .agents/subagent-index.toon
  check: rg "pro" .agents/subagent-index.toon
  check: rg "sonnet" .agents/subagent-index.toon
  check: rg "opencode-server" .agents/subagent-index.toon
  check: rg "cron-agent" .agents/subagent-index.toon
  check: rg "agent-testing" .agents/subagent-index.toon
  check: rg "summarize" .agents/subagent-index.toon
  check: rg "model-routing" .agents/subagent-index.toon
  check: rg "opencode-github" .agents/subagent-index.toon
  check: rg "opencode-gitlab" .agents/subagent-index.toon
  check: rg "opencode-anthropic-auth" .agents/subagent-index.toon
  check: rg "opencode" .agents/subagent-index.toon
  check: rg "image-understanding" .agents/subagent-index.toon
  check: rg "pipecat-opencode" .agents/subagent-index.toon

- [x] v114 t1084 Fix auto-update-helper.sh CodeRabbit feedback from PR #15... | PR #1597 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/auto-update-helper.sh
  check: shellcheck .agents/scripts/auto-update-helper.sh
  check: file-exists .agents/scripts/auto-update-helper.sh

- [x] v115 t1082.1 Add skill-update-helper.sh pr subcommand — for each ski... | PR #1608 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/skill-update-helper.sh
  check: shellcheck .agents/scripts/skill-update-helper.sh
  check: file-exists .agents/scripts/skill-update-helper.sh

- [x] v116 t1082.2 Add supervisor phase for skill update PRs — optional ph... | PR #1610 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/supervisor-helper.sh, .agents/scripts/supervisor/pulse.sh
  check: shellcheck .agents/scripts/supervisor-helper.sh
  check: file-exists .agents/scripts/supervisor-helper.sh
  check: shellcheck .agents/scripts/supervisor/pulse.sh
  check: file-exists .agents/scripts/supervisor/pulse.sh

- [x] v117 t1085.3 Action executor — implement validated action types: com... | PR #1612 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/supervisor-helper.sh, .agents/scripts/supervisor/ai-actions.sh, tests/test-ai-actions.sh
  check: shellcheck .agents/scripts/supervisor-helper.sh
  check: file-exists .agents/scripts/supervisor-helper.sh
  check: shellcheck .agents/scripts/supervisor/ai-actions.sh
  check: file-exists .agents/scripts/supervisor/ai-actions.sh
  check: shellcheck tests/test-ai-actions.sh
  check: file-exists tests/test-ai-actions.sh

- [x] v118 t1082.4 Add skill update PR template — conventional commit mess... | PR #1615 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/skill-update-helper.sh
  check: shellcheck .agents/scripts/skill-update-helper.sh
  check: file-exists .agents/scripts/skill-update-helper.sh

- [x] v119 t1085.4 Subtask auto-dispatch enhancement — Phase 0 auto-pickup... | PR #1616 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/supervisor-helper.sh, .agents/scripts/supervisor/cron.sh
  check: shellcheck .agents/scripts/supervisor-helper.sh
  check: file-exists .agents/scripts/supervisor-helper.sh
  check: shellcheck .agents/scripts/supervisor/cron.sh
  check: file-exists .agents/scripts/supervisor/cron.sh

- [x] v120 t1082.3 Handle multi-skill batching — if multiple skills have u... | PR #1613 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/skill-update-helper.sh, .agents/scripts/supervisor/pulse.sh
  check: shellcheck .agents/scripts/skill-update-helper.sh
  check: file-exists .agents/scripts/skill-update-helper.sh
  check: shellcheck .agents/scripts/supervisor/pulse.sh
  check: file-exists .agents/scripts/supervisor/pulse.sh

- [x] v121 t1085.5 Pulse integration + scheduling — wire Phase 13 into pul... | PR #1617 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/supervisor-helper.sh, .agents/scripts/supervisor/pulse.sh
  check: shellcheck .agents/scripts/supervisor-helper.sh
  check: file-exists .agents/scripts/supervisor-helper.sh
  check: shellcheck .agents/scripts/supervisor/pulse.sh
  check: file-exists .agents/scripts/supervisor/pulse.sh

- [x] v122 t1085.6 Issue audit capabilities — closed issue audit (48h, ver... | PR #1627 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/supervisor-helper.sh, .agents/scripts/supervisor/ai-context.sh, .agents/scripts/supervisor/issue-audit.sh
  check: shellcheck .agents/scripts/supervisor-helper.sh
  check: file-exists .agents/scripts/supervisor-helper.sh
  check: shellcheck .agents/scripts/supervisor/ai-context.sh
  check: file-exists .agents/scripts/supervisor/ai-context.sh
  check: shellcheck .agents/scripts/supervisor/issue-audit.sh
  check: file-exists .agents/scripts/supervisor/issue-audit.sh

- [x] v123 t1085.7 Testing + validation — dry-run mode, mock context, toke... | PR #1635 | merged:2026-02-18 verified:2026-02-18
  files: tests/test-ai-supervisor-e2e.sh
  check: shellcheck tests/test-ai-supervisor-e2e.sh
  check: file-exists tests/test-ai-supervisor-e2e.sh

- [x] v124 t1093 Intelligent daily routine scheduling — AI reasoning (Ph... | PR #1619 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/supervisor-helper.sh, .agents/scripts/supervisor/pulse.sh, .agents/scripts/supervisor/routine-scheduler.sh
  check: shellcheck .agents/scripts/supervisor-helper.sh
  check: file-exists .agents/scripts/supervisor-helper.sh
  check: shellcheck .agents/scripts/supervisor/pulse.sh
  check: file-exists .agents/scripts/supervisor/pulse.sh
  check: shellcheck .agents/scripts/supervisor/routine-scheduler.sh
  check: file-exists .agents/scripts/supervisor/routine-scheduler.sh

- [x] v125 t1095 Extend pattern tracker schema — add columns: strategy (... | PR #1629 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/memory/_common.sh, .agents/scripts/pattern-tracker-helper.sh, .agents/scripts/shared-constants.sh
  check: shellcheck .agents/scripts/memory/_common.sh
  check: file-exists .agents/scripts/memory/_common.sh
  check: shellcheck .agents/scripts/pattern-tracker-helper.sh
  check: file-exists .agents/scripts/pattern-tracker-helper.sh
  check: shellcheck .agents/scripts/shared-constants.sh
  check: file-exists .agents/scripts/shared-constants.sh

- [x] v126 t1097 Add prompt-repeat retry strategy to dispatch.sh — befor... | PR #1631 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/supervisor/database.sh, .agents/scripts/supervisor/dispatch.sh, .agents/scripts/supervisor/pulse.sh
  check: shellcheck .agents/scripts/supervisor/database.sh
  check: file-exists .agents/scripts/supervisor/database.sh
  check: shellcheck .agents/scripts/supervisor/dispatch.sh
  check: file-exists .agents/scripts/supervisor/dispatch.sh
  check: shellcheck .agents/scripts/supervisor/pulse.sh
  check: file-exists .agents/scripts/supervisor/pulse.sh

- [x] v127 t1098 Wire compare-models to read live pattern data — /compar... | PR #1637 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/compare-models-helper.sh, .agents/tools/ai-assistants/compare-models.md
  check: shellcheck .agents/scripts/compare-models-helper.sh
  check: file-exists .agents/scripts/compare-models-helper.sh
  check: file-exists .agents/tools/ai-assistants/compare-models.md
  check: rg "compare-models" .agents/subagent-index.toon

- [x] v128 t1099 Wire response-scoring to write back to pattern tracker �... | PR #1634 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/commands/score-responses.md, .agents/scripts/response-scoring-helper.sh, .agents/tools/ai-assistants/response-scoring.md, tests/test-response-scoring.sh
  check: file-exists .agents/scripts/commands/score-responses.md
  check: shellcheck .agents/scripts/response-scoring-helper.sh
  check: file-exists .agents/scripts/response-scoring-helper.sh
  check: file-exists .agents/tools/ai-assistants/response-scoring.md
  check: shellcheck tests/test-response-scoring.sh
  check: file-exists tests/test-response-scoring.sh
  check: rg "response-scoring" .agents/subagent-index.toon

- [x] v129 t1100 Budget-aware model routing — two strategies based on bi... | PR #1636 | merged:2026-02-18 verified:2026-02-18
  files: .agents/AGENTS.md, .agents/scripts/budget-tracker-helper.sh, .agents/scripts/supervisor/dispatch.sh, .agents/scripts/supervisor/evaluate.sh, .agents/scripts/supervisor/pulse.sh
  check: file-exists .agents/AGENTS.md
  check: shellcheck .agents/scripts/budget-tracker-helper.sh
  check: file-exists .agents/scripts/budget-tracker-helper.sh
  check: shellcheck .agents/scripts/supervisor/dispatch.sh
  check: file-exists .agents/scripts/supervisor/dispatch.sh
  check: shellcheck .agents/scripts/supervisor/evaluate.sh
  check: file-exists .agents/scripts/supervisor/evaluate.sh
  check: shellcheck .agents/scripts/supervisor/pulse.sh
  check: file-exists .agents/scripts/supervisor/pulse.sh

- [x] v130 t1081.2 Add --non-interactive support to skill-update-helper.sh �... | PR #1630 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/skill-update-helper.sh
  check: shellcheck .agents/scripts/skill-update-helper.sh
  check: file-exists .agents/scripts/skill-update-helper.sh

- [x] v131 t1094.1 Update build-agent to reference pattern data for model ti... | PR #1633 | merged:2026-02-18 verified:2026-02-18
  files: .agents/tools/build-agent/build-agent.md
  check: file-exists .agents/tools/build-agent/build-agent.md
  check: rg "build-agent" .agents/subagent-index.toon

- [x] v132 t1081.3 Update auto-update state file schema — add last_skill_c... | PR #1638 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/auto-update-helper.sh
  check: shellcheck .agents/scripts/auto-update-helper.sh
  check: file-exists .agents/scripts/auto-update-helper.sh

- [x] v133 t1081.4 Update AGENTS.md and auto-update docs — document daily ... | PR #1639 | merged:2026-02-18 verified:2026-02-18
  files: .agents/AGENTS.md
  check: file-exists .agents/AGENTS.md

- [ ] v134 t1096 Update evaluate.sh to capture richer metadata — after w... | PR #1632 | merged:2026-02-18
  files: .agents/scripts/pattern-tracker-helper.sh, .agents/scripts/supervisor/evaluate.sh, .agents/scripts/supervisor/memory-integration.sh, .agents/scripts/supervisor/pulse.sh
  check: shellcheck .agents/scripts/pattern-tracker-helper.sh
  check: file-exists .agents/scripts/pattern-tracker-helper.sh
  check: shellcheck .agents/scripts/supervisor/evaluate.sh
  check: file-exists .agents/scripts/supervisor/evaluate.sh
  check: shellcheck .agents/scripts/supervisor/memory-integration.sh
  check: file-exists .agents/scripts/supervisor/memory-integration.sh
  check: shellcheck .agents/scripts/supervisor/pulse.sh
  check: file-exists .agents/scripts/supervisor/pulse.sh

- [ ] v135 t1141 Fix duplicate GitHub issues in issue-sync push — replac... | PR #1715 | merged:2026-02-18
  files: .agents/scripts/issue-sync-helper.sh
  check: shellcheck .agents/scripts/issue-sync-helper.sh
  check: file-exists .agents/scripts/issue-sync-helper.sh

- [x] v136 t1126 Fix adjust_priority action schema — add new_priority fi... | PR #1703 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/supervisor/ai-reason.sh, tests/test-ai-actions.sh
  check: shellcheck .agents/scripts/supervisor/ai-reason.sh
  check: file-exists .agents/scripts/supervisor/ai-reason.sh
  check: shellcheck tests/test-ai-actions.sh
  check: file-exists tests/test-ai-actions.sh

- [x] v137 t1125 Fix jq JSON parsing errors in supervisor action executor ... | PR #1702 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/supervisor/ai-actions.sh, .agents/scripts/supervisor/issue-audit.sh
  check: shellcheck .agents/scripts/supervisor/ai-actions.sh
  check: file-exists .agents/scripts/supervisor/ai-actions.sh
  check: shellcheck .agents/scripts/supervisor/issue-audit.sh
  check: file-exists .agents/scripts/supervisor/issue-audit.sh

- [x] v138 t1132 Add stale-state detection for supervisor DB running/evalu... | PR #1733 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/supervisor/pulse.sh, MODELS.md
  check: shellcheck .agents/scripts/supervisor/pulse.sh
  check: file-exists .agents/scripts/supervisor/pulse.sh
  check: file-exists MODELS.md

- [x] v139 t1139 Add supervisor DB consistency check — sync cancelled/ve... | PR #1735 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/supervisor/pulse.sh, .agents/scripts/supervisor/todo-sync.sh
  check: shellcheck .agents/scripts/supervisor/pulse.sh
  check: file-exists .agents/scripts/supervisor/pulse.sh
  check: shellcheck .agents/scripts/supervisor/todo-sync.sh
  check: file-exists .agents/scripts/supervisor/todo-sync.sh

- [x] v140 t1146 Add batch-task-creation capability to reduce worktree/PR ... | PR #1770 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/batch-cleanup-helper.sh, .agents/scripts/supervisor-helper.sh, .agents/scripts/supervisor/cron.sh
  check: shellcheck .agents/scripts/batch-cleanup-helper.sh
  check: file-exists .agents/scripts/batch-cleanup-helper.sh
  check: shellcheck .agents/scripts/supervisor-helper.sh
  check: file-exists .agents/scripts/supervisor-helper.sh
  check: shellcheck .agents/scripts/supervisor/cron.sh
  check: file-exists .agents/scripts/supervisor/cron.sh

- [x] v141 t1148 Add completed-task exclusion list to supervisor AI contex... | PR #1768 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/supervisor/ai-context.sh, .agents/scripts/supervisor/ai-reason.sh
  check: shellcheck .agents/scripts/supervisor/ai-context.sh
  check: file-exists .agents/scripts/supervisor/ai-context.sh
  check: shellcheck .agents/scripts/supervisor/ai-reason.sh
  check: file-exists .agents/scripts/supervisor/ai-reason.sh

- [x] v142 t1149 Add model tier cost-efficiency check to supervisor dispat... | PR #1769 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/pattern-tracker-helper.sh, .agents/scripts/supervisor/dispatch.sh
  check: shellcheck .agents/scripts/pattern-tracker-helper.sh
  check: file-exists .agents/scripts/pattern-tracker-helper.sh
  check: shellcheck .agents/scripts/supervisor/dispatch.sh
  check: file-exists .agents/scripts/supervisor/dispatch.sh

- [x] v143 t1138 Add cycle-level action dedup to prevent repeated actions ... | PR #1736 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/supervisor/ai-actions.sh, .agents/scripts/supervisor/database.sh, MODELS.md
  check: shellcheck .agents/scripts/supervisor/ai-actions.sh
  check: file-exists .agents/scripts/supervisor/ai-actions.sh
  check: shellcheck .agents/scripts/supervisor/database.sh
  check: file-exists .agents/scripts/supervisor/database.sh
  check: file-exists MODELS.md

- [x] v144 t1179 Add cycle-aware dedup to supervisor — skip targets acte... | PR #1780 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/supervisor/ai-actions.sh, .agents/scripts/supervisor/database.sh, tests/test-ai-actions.sh
  check: shellcheck .agents/scripts/supervisor/ai-actions.sh
  check: file-exists .agents/scripts/supervisor/ai-actions.sh
  check: shellcheck .agents/scripts/supervisor/database.sh
  check: file-exists .agents/scripts/supervisor/database.sh
  check: shellcheck tests/test-ai-actions.sh
  check: file-exists tests/test-ai-actions.sh

- [x] v145 t1180 Add dispatchable-queue reconciliation between supervisor ... | PR #1783 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/supervisor-helper.sh, .agents/scripts/supervisor/pulse.sh, .agents/scripts/supervisor/todo-sync.sh
  check: shellcheck .agents/scripts/supervisor-helper.sh
  check: file-exists .agents/scripts/supervisor-helper.sh
  check: shellcheck .agents/scripts/supervisor/pulse.sh
  check: file-exists .agents/scripts/supervisor/pulse.sh
  check: shellcheck .agents/scripts/supervisor/todo-sync.sh
  check: file-exists .agents/scripts/supervisor/todo-sync.sh

- [x] v146 t1134 Add auto-dispatch eligibility assessment to supervisor AI... | PR #1782 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/supervisor/ai-actions.sh, .agents/scripts/supervisor/ai-context.sh, .agents/scripts/supervisor/ai-reason.sh
  check: shellcheck .agents/scripts/supervisor/ai-actions.sh
  check: file-exists .agents/scripts/supervisor/ai-actions.sh
  check: shellcheck .agents/scripts/supervisor/ai-context.sh
  check: file-exists .agents/scripts/supervisor/ai-context.sh
  check: shellcheck .agents/scripts/supervisor/ai-reason.sh
  check: file-exists .agents/scripts/supervisor/ai-reason.sh

- [x] v147 t1133 Split MODELS.md into global + per-repo files and propagat... | PR #1786 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/generate-models-md.sh, .agents/scripts/supervisor/pulse.sh
  check: shellcheck .agents/scripts/generate-models-md.sh
  check: file-exists .agents/scripts/generate-models-md.sh
  check: shellcheck .agents/scripts/supervisor/pulse.sh
  check: file-exists .agents/scripts/supervisor/pulse.sh

- [x] v148 t1142 Add concurrency guard to issue-sync GitHub Action to prev... | PR #1741 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/issue-sync-helper.sh
  check: shellcheck .agents/scripts/issue-sync-helper.sh
  check: file-exists .agents/scripts/issue-sync-helper.sh

- [x] v149 t1181 Add action-target cooldown to supervisor reasoning to pre... | PR #1785 | merged:2026-02-18 verified:2026-02-18
  files: VERIFY.md
  check: file-exists VERIFY.md

- [ ] v150 t1156 Add supervisor DB cross-reference to issue audit tool to ... | PR #1773 | merged:2026-02-18
  files: .agents/scripts/supervisor/issue-audit.sh
  check: shellcheck .agents/scripts/supervisor/issue-audit.sh
  check: file-exists .agents/scripts/supervisor/issue-audit.sh

- [ ] v150 t1178 Add completed-task filter to supervisor AI context builde... | PR #1779 | merged:2026-02-18
  files: .agents/scripts/supervisor/ai-context.sh
  check: shellcheck .agents/scripts/supervisor/ai-context.sh
  check: file-exists .agents/scripts/supervisor/ai-context.sh

- [x] v151 t1145 Resolve supervisor DB inconsistency — 4 running + 3 eva... | PR #1771 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/supervisor-helper.sh, .agents/scripts/supervisor/cleanup.sh, .agents/scripts/supervisor/pulse.sh, MODELS.md
  check: shellcheck .agents/scripts/supervisor-helper.sh
  check: file-exists .agents/scripts/supervisor-helper.sh
  check: shellcheck .agents/scripts/supervisor/cleanup.sh
  check: file-exists .agents/scripts/supervisor/cleanup.sh
  check: shellcheck .agents/scripts/supervisor/pulse.sh
  check: file-exists .agents/scripts/supervisor/pulse.sh
  check: file-exists MODELS.md

- [x] v152 t1182 Fix AI actions pipeline 'expected array' parsing errors #... | PR #1792 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/supervisor/ai-actions.sh, .agents/scripts/supervisor/ai-reason.sh, tests/test-ai-supervisor-e2e.sh
  check: shellcheck .agents/scripts/supervisor/ai-actions.sh
  check: file-exists .agents/scripts/supervisor/ai-actions.sh
  check: shellcheck .agents/scripts/supervisor/ai-reason.sh
  check: file-exists .agents/scripts/supervisor/ai-reason.sh
  check: shellcheck tests/test-ai-supervisor-e2e.sh
  check: file-exists tests/test-ai-supervisor-e2e.sh

- [x] v153 t1184 Fix AI supervisor pipeline 'expected array, got empty' er... | PR #1797 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/supervisor/ai-actions.sh, .agents/scripts/supervisor/ai-reason.sh
  check: shellcheck .agents/scripts/supervisor/ai-actions.sh
  check: file-exists .agents/scripts/supervisor/ai-actions.sh
  check: shellcheck .agents/scripts/supervisor/ai-reason.sh
  check: file-exists .agents/scripts/supervisor/ai-reason.sh

- [x] v154 t1187 Harden AI actions pipeline against empty/malformed model ... | PR #1805 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/supervisor/ai-actions.sh, .agents/scripts/supervisor/ai-reason.sh
  check: shellcheck .agents/scripts/supervisor/ai-actions.sh
  check: file-exists .agents/scripts/supervisor/ai-actions.sh
  check: shellcheck .agents/scripts/supervisor/ai-reason.sh
  check: file-exists .agents/scripts/supervisor/ai-reason.sh

- [x] v155 t1186 Investigate frequent sonnet→opus tier escalation in dis... | PR #1806 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/supervisor/dispatch.sh, .agents/scripts/supervisor/self-heal.sh
  check: shellcheck .agents/scripts/supervisor/dispatch.sh
  check: file-exists .agents/scripts/supervisor/dispatch.sh
  check: shellcheck .agents/scripts/supervisor/self-heal.sh
  check: file-exists .agents/scripts/supervisor/self-heal.sh

- [x] v156 t1189 Fix AI actions pipeline empty-response handling to preven... | PR #1807 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/supervisor/ai-actions.sh, tests/test-ai-supervisor-e2e.sh
  check: shellcheck .agents/scripts/supervisor/ai-actions.sh
  check: file-exists .agents/scripts/supervisor/ai-actions.sh
  check: shellcheck tests/test-ai-supervisor-e2e.sh
  check: file-exists tests/test-ai-supervisor-e2e.sh

- [x] v157 t1191 Add sonnet-to-opus tier escalation tracking and cost anal... | PR #1808 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/budget-tracker-helper.sh, .agents/scripts/pattern-tracker-helper.sh, .agents/scripts/supervisor/evaluate.sh, .agents/scripts/supervisor/pulse.sh, .agents/tools/context/model-routing.md
  check: shellcheck .agents/scripts/budget-tracker-helper.sh
  check: file-exists .agents/scripts/budget-tracker-helper.sh
  check: shellcheck .agents/scripts/pattern-tracker-helper.sh
  check: file-exists .agents/scripts/pattern-tracker-helper.sh
  check: shellcheck .agents/scripts/supervisor/evaluate.sh
  check: file-exists .agents/scripts/supervisor/evaluate.sh
  check: shellcheck .agents/scripts/supervisor/pulse.sh
  check: file-exists .agents/scripts/supervisor/pulse.sh
  check: file-exists .agents/tools/context/model-routing.md
  check: rg "model-routing" .agents/subagent-index.toon

- [x] v158 t1120.3 Add platform detection from git remote URL + multi-platfo... | PR #1815 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/issue-sync-helper.sh
  check: shellcheck .agents/scripts/issue-sync-helper.sh
  check: file-exists .agents/scripts/issue-sync-helper.sh

- [!] v159 t1193 Reconcile supervisor DB running count with actual worker ... | PR #1813 | merged:2026-02-18 failed:2026-02-18 reason:shellcheck: tests/test-supervisor-state-machine.sh has violations
  files: .agents/scripts/supervisor/pulse.sh, tests/test-supervisor-state-machine.sh
  check: shellcheck .agents/scripts/supervisor/pulse.sh
  check: file-exists .agents/scripts/supervisor/pulse.sh
  check: shellcheck tests/test-supervisor-state-machine.sh
  check: file-exists tests/test-supervisor-state-machine.sh

- [x] v160 t1121 Fix tea CLI TTY requirement in non-interactive mode #bugf... | PR #1814 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/gitea-cli-helper.sh
  check: shellcheck .agents/scripts/gitea-cli-helper.sh
  check: file-exists .agents/scripts/gitea-cli-helper.sh

- [x] v161 t1196 Add worker hang detection timeout tuning based on task ty... | PR #1819 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/supervisor-helper.sh, .agents/scripts/supervisor/dispatch.sh, .agents/scripts/supervisor/pulse.sh
  check: shellcheck .agents/scripts/supervisor-helper.sh
  check: file-exists .agents/scripts/supervisor-helper.sh
  check: shellcheck .agents/scripts/supervisor/dispatch.sh
  check: file-exists .agents/scripts/supervisor/dispatch.sh
  check: shellcheck .agents/scripts/supervisor/pulse.sh
  check: file-exists .agents/scripts/supervisor/pulse.sh

- [x] v162 t1201 Fix AI supervisor pipeline 'expected array' parsing error... | PR #1829 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/supervisor/ai-actions.sh, .agents/scripts/supervisor/ai-reason.sh, tests/test-ai-actions.sh
  check: shellcheck .agents/scripts/supervisor/ai-actions.sh
  check: file-exists .agents/scripts/supervisor/ai-actions.sh
  check: shellcheck .agents/scripts/supervisor/ai-reason.sh
  check: file-exists .agents/scripts/supervisor/ai-reason.sh
  check: shellcheck tests/test-ai-actions.sh
  check: file-exists tests/test-ai-actions.sh

- [x] v163 t1202 Add stale 'evaluating' and 'running' state garbage collec... | PR #1828 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/supervisor-helper.sh, .agents/scripts/supervisor/database.sh, .agents/scripts/supervisor/pulse.sh
  check: shellcheck .agents/scripts/supervisor-helper.sh
  check: file-exists .agents/scripts/supervisor-helper.sh
  check: shellcheck .agents/scripts/supervisor/database.sh
  check: file-exists .agents/scripts/supervisor/database.sh
  check: shellcheck .agents/scripts/supervisor/pulse.sh
  check: file-exists .agents/scripts/supervisor/pulse.sh

- [x] v164 t1204 Add pipeline empty-response resilience verification test ... | PR #1832 | merged:2026-02-18 verified:2026-02-18
  files: tests/test-ai-actions.sh
  check: shellcheck tests/test-ai-actions.sh
  check: file-exists tests/test-ai-actions.sh

- [x] v165 t1197 Harden AI actions pipeline against empty/malformed model ... | PR #1823 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/supervisor/ai-actions.sh, .agents/scripts/supervisor/ai-reason.sh, tests/test-ai-actions.sh
  check: shellcheck .agents/scripts/supervisor/ai-actions.sh
  check: file-exists .agents/scripts/supervisor/ai-actions.sh
  check: shellcheck .agents/scripts/supervisor/ai-reason.sh
  check: file-exists .agents/scripts/supervisor/ai-reason.sh
  check: shellcheck tests/test-ai-actions.sh
  check: file-exists tests/test-ai-actions.sh

- [x] v166 t1199 Add worker hung timeout tuning based on task estimate #en... | PR #1826 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/supervisor/_common.sh, .agents/scripts/supervisor/dispatch.sh, .agents/scripts/supervisor/pulse.sh
  check: shellcheck .agents/scripts/supervisor/_common.sh
  check: file-exists .agents/scripts/supervisor/_common.sh
  check: shellcheck .agents/scripts/supervisor/dispatch.sh
  check: file-exists .agents/scripts/supervisor/dispatch.sh
  check: shellcheck .agents/scripts/supervisor/pulse.sh
  check: file-exists .agents/scripts/supervisor/pulse.sh

- [x] v167 t1208 Reconcile supervisor DB status inconsistencies (running/e... | PR #1837 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/supervisor/pulse.sh
  check: shellcheck .agents/scripts/supervisor/pulse.sh
  check: file-exists .agents/scripts/supervisor/pulse.sh

- [x] v168 t1206 Add dispatch deduplication guard for repeated task failur... | PR #1835 | merged:2026-02-18 verified:2026-02-18
  files: .agents/scripts/supervisor/database.sh, .agents/scripts/supervisor/dispatch.sh, .agents/scripts/supervisor/pulse.sh
  check: shellcheck .agents/scripts/supervisor/database.sh
  check: file-exists .agents/scripts/supervisor/database.sh
  check: shellcheck .agents/scripts/supervisor/dispatch.sh
  check: file-exists .agents/scripts/supervisor/dispatch.sh
  check: shellcheck .agents/scripts/supervisor/pulse.sh
  check: file-exists .agents/scripts/supervisor/pulse.sh

- [x] v169 t1210 Add create_subtasks parent_task_id validation to AI reaso... | PR #1839 | merged:2026-02-19 verified:2026-02-19
  files: .agents/scripts/supervisor/ai-reason.sh
  check: shellcheck .agents/scripts/supervisor/ai-reason.sh
  check: file-exists .agents/scripts/supervisor/ai-reason.sh

- [x] v170 t1211 Add empty/malformed response fallback to AI actions pipel... | PR #1843 | merged:2026-02-19 verified:2026-02-19
  files: .agents/scripts/supervisor/ai-actions.sh
  check: shellcheck .agents/scripts/supervisor/ai-actions.sh
  check: file-exists .agents/scripts/supervisor/ai-actions.sh

- [x] v171 t1214 Add t1200 subtask visibility check — subtasks created b... | PR #1850 | merged:2026-02-19 verified:2026-02-19
  files: .agents/scripts/supervisor/ai-actions.sh, .agents/scripts/supervisor/ai-context.sh
  check: shellcheck .agents/scripts/supervisor/ai-actions.sh
  check: file-exists .agents/scripts/supervisor/ai-actions.sh
  check: shellcheck .agents/scripts/supervisor/ai-context.sh
  check: file-exists .agents/scripts/supervisor/ai-context.sh

- [x] v172 t1200.1 Core orchestrator + free-tier providers — create `ip-re... | PR #1856 | merged:2026-02-19 verified:2026-02-19
  files: .agents/scripts/ip-reputation-helper.sh, .agents/scripts/providers/ip-rep-abuseipdb.sh, .agents/scripts/providers/ip-rep-blocklistde.sh, .agents/scripts/providers/ip-rep-proxycheck.sh, .agents/scripts/providers/ip-rep-spamhaus.sh, .agents/scripts/providers/ip-rep-stopforumspam.sh
  check: shellcheck .agents/scripts/ip-reputation-helper.sh
  check: file-exists .agents/scripts/ip-reputation-helper.sh
  check: shellcheck .agents/scripts/providers/ip-rep-abuseipdb.sh
  check: file-exists .agents/scripts/providers/ip-rep-abuseipdb.sh
  check: shellcheck .agents/scripts/providers/ip-rep-blocklistde.sh
  check: file-exists .agents/scripts/providers/ip-rep-blocklistde.sh
  check: shellcheck .agents/scripts/providers/ip-rep-proxycheck.sh
  check: file-exists .agents/scripts/providers/ip-rep-proxycheck.sh
  check: shellcheck .agents/scripts/providers/ip-rep-spamhaus.sh
  check: file-exists .agents/scripts/providers/ip-rep-spamhaus.sh
  check: shellcheck .agents/scripts/providers/ip-rep-stopforumspam.sh
  check: file-exists .agents/scripts/providers/ip-rep-stopforumspam.sh

- [x] v173 t1217 Add create_subtasks post-execution verification to confir... | PR #1858 | merged:2026-02-19 verified:2026-02-19
  files: .agents/scripts/supervisor/ai-actions.sh
  check: shellcheck .agents/scripts/supervisor/ai-actions.sh
  check: file-exists .agents/scripts/supervisor/ai-actions.sh

- [x] v174 t1200.2 Keyed providers + SQLite cache + batch mode — implement... | PR #1860 | merged:2026-02-19 verified:2026-02-19
  files: .agents/scripts/ip-reputation-helper.sh, .agents/scripts/providers/ip-rep-abuseipdb.sh, .agents/scripts/providers/ip-rep-blocklistde.sh, .agents/scripts/providers/ip-rep-greynoise.sh, .agents/scripts/providers/ip-rep-iphub.sh, .agents/scripts/providers/ip-rep-ipqualityscore.sh, .agents/scripts/providers/ip-rep-proxycheck.sh, .agents/scripts/providers/ip-rep-scamalytics.sh, .agents/scripts/providers/ip-rep-shodan.sh, .agents/scripts/providers/ip-rep-spamhaus.sh, .agents/scripts/providers/ip-rep-stopforumspam.sh
  check: shellcheck .agents/scripts/ip-reputation-helper.sh
  check: file-exists .agents/scripts/ip-reputation-helper.sh
  check: shellcheck .agents/scripts/providers/ip-rep-abuseipdb.sh
  check: file-exists .agents/scripts/providers/ip-rep-abuseipdb.sh
  check: shellcheck .agents/scripts/providers/ip-rep-blocklistde.sh
  check: file-exists .agents/scripts/providers/ip-rep-blocklistde.sh
  check: shellcheck .agents/scripts/providers/ip-rep-greynoise.sh
  check: file-exists .agents/scripts/providers/ip-rep-greynoise.sh
  check: shellcheck .agents/scripts/providers/ip-rep-iphub.sh
  check: file-exists .agents/scripts/providers/ip-rep-iphub.sh
  check: shellcheck .agents/scripts/providers/ip-rep-ipqualityscore.sh
  check: file-exists .agents/scripts/providers/ip-rep-ipqualityscore.sh
  check: shellcheck .agents/scripts/providers/ip-rep-proxycheck.sh
  check: file-exists .agents/scripts/providers/ip-rep-proxycheck.sh
  check: shellcheck .agents/scripts/providers/ip-rep-scamalytics.sh
  check: file-exists .agents/scripts/providers/ip-rep-scamalytics.sh
  check: shellcheck .agents/scripts/providers/ip-rep-shodan.sh
  check: file-exists .agents/scripts/providers/ip-rep-shodan.sh
  check: shellcheck .agents/scripts/providers/ip-rep-spamhaus.sh
  check: file-exists .agents/scripts/providers/ip-rep-spamhaus.sh
  check: shellcheck .agents/scripts/providers/ip-rep-stopforumspam.sh
  check: file-exists .agents/scripts/providers/ip-rep-stopforumspam.sh

- [x] v175 t1219 Use launchd LaunchAgents on macOS instead of cron — pla... | PR #1864 | merged:2026-02-19 verified:2026-02-19
  files: .agents/AGENTS.md, .agents/scripts/auto-update-helper.sh, .agents/scripts/supervisor/cron.sh, .agents/scripts/supervisor/launchd.sh
  check: file-exists .agents/AGENTS.md
  check: shellcheck .agents/scripts/auto-update-helper.sh
  check: file-exists .agents/scripts/auto-update-helper.sh
  check: shellcheck .agents/scripts/supervisor/cron.sh
  check: file-exists .agents/scripts/supervisor/cron.sh
  check: shellcheck .agents/scripts/supervisor/launchd.sh
  check: file-exists .agents/scripts/supervisor/launchd.sh

- [x] v176 t1200.3 Agent doc + slash command + index updates + output format... | PR #1867 | merged:2026-02-19 verified:2026-02-19
  files: .agents/AGENTS.md, .agents/scripts/commands/ip-check.md, .agents/scripts/ip-reputation-helper.sh, .agents/subagent-index.toon, .agents/tools/security/ip-reputation.md
  check: file-exists .agents/AGENTS.md
  check: file-exists .agents/scripts/commands/ip-check.md
  check: shellcheck .agents/scripts/ip-reputation-helper.sh
  check: file-exists .agents/scripts/ip-reputation-helper.sh
  check: file-exists .agents/subagent-index.toon
  check: file-exists .agents/tools/security/ip-reputation.md
  check: rg "ip-reputation" .agents/subagent-index.toon

- [x] v177 t1221 Fix create_subtasks executor — 10 consecutive failures ... | PR #1866 | merged:2026-02-19 verified:2026-02-19
  files: .agents/scripts/supervisor/ai-actions.sh, tests/test-ai-actions.sh
  check: shellcheck .agents/scripts/supervisor/ai-actions.sh
  check: file-exists .agents/scripts/supervisor/ai-actions.sh
  check: shellcheck tests/test-ai-actions.sh
  check: file-exists tests/test-ai-actions.sh

- [x] v178 t1200.4 Core IP reputation lookup module using AbuseIPDB and Viru... | PR #1871 | merged:2026-02-19 verified:2026-02-19
  files: .agents/scripts/ip-reputation-helper.sh, .agents/scripts/providers/ip-rep-virustotal.sh, .agents/tools/security/ip-reputation.md
  check: shellcheck .agents/scripts/ip-reputation-helper.sh
  check: file-exists .agents/scripts/ip-reputation-helper.sh
  check: shellcheck .agents/scripts/providers/ip-rep-virustotal.sh
  check: file-exists .agents/scripts/providers/ip-rep-virustotal.sh
  check: file-exists .agents/tools/security/ip-reputation.md
  check: rg "ip-reputation" .agents/subagent-index.toon

- [x] v179 t1223 Add input validation guard for AI reasoner non-array outp... | PR #1872 | merged:2026-02-19 verified:2026-02-19
  files: .agents/scripts/supervisor/ai-actions.sh
  check: shellcheck .agents/scripts/supervisor/ai-actions.sh
  check: file-exists .agents/scripts/supervisor/ai-actions.sh

- [x] v180 t1222 Add worker hang detection with graceful termination befor... | PR #1869 | merged:2026-02-19 verified:2026-02-19
  files: .agents/scripts/supervisor-helper.sh, .agents/scripts/supervisor/cleanup.sh, .agents/scripts/supervisor/pulse.sh
  check: shellcheck .agents/scripts/supervisor-helper.sh
  check: file-exists .agents/scripts/supervisor-helper.sh
  check: shellcheck .agents/scripts/supervisor/cleanup.sh
  check: file-exists .agents/scripts/supervisor/cleanup.sh
  check: shellcheck .agents/scripts/supervisor/pulse.sh
  check: file-exists .agents/scripts/supervisor/pulse.sh

- [x] v181 t1200.5 CLI interface and agent framework integration for IP repu... | PR #1883 | merged:2026-02-19 verified:2026-02-19
  files: .agents/AGENTS.md, aidevops.sh
  check: file-exists .agents/AGENTS.md
  check: shellcheck aidevops.sh
  check: file-exists aidevops.sh

- [x] v182 t1224.1 Create `localdev` shell script with `init` command — co... | PR #1884 | merged:2026-02-19 verified:2026-02-19
  files: .agents/scripts/localdev-helper.sh
  check: shellcheck .agents/scripts/localdev-helper.sh
  check: file-exists .agents/scripts/localdev-helper.sh

- [x] v183 t1200.6 Output formatting, caching layer, and rate limit handling... | PR #1911 | merged:2026-02-19 verified:2026-02-19
  files: .agents/scripts/ip-reputation-helper.sh, .agents/scripts/providers/ip-rep-abuseipdb.sh, .agents/scripts/providers/ip-rep-proxycheck.sh, .agents/tools/security/ip-reputation.md
  check: shellcheck .agents/scripts/ip-reputation-helper.sh
  check: file-exists .agents/scripts/ip-reputation-helper.sh
  check: shellcheck .agents/scripts/providers/ip-rep-abuseipdb.sh
  check: file-exists .agents/scripts/providers/ip-rep-abuseipdb.sh
  check: shellcheck .agents/scripts/providers/ip-rep-proxycheck.sh
  check: file-exists .agents/scripts/providers/ip-rep-proxycheck.sh
  check: file-exists .agents/tools/security/ip-reputation.md
  check: rg "ip-reputation" .agents/subagent-index.toon

- [x] v184 t1224.2 Implement `localdev add/rm` — port registry (`~/.local-... | PR #1908 | merged:2026-02-19 verified:2026-02-19
  files: .agents/scripts/localdev-helper.sh
  check: shellcheck .agents/scripts/localdev-helper.sh
  check: file-exists .agents/scripts/localdev-helper.sh

- [x] v185 t1235 Fix issue-sync-helper.sh `cmd_push()` cross-repo vulnerab... | PR #1913 | merged:2026-02-19 verified:2026-02-19
  files: .agents/scripts/issue-sync-helper.sh
  check: shellcheck .agents/scripts/issue-sync-helper.sh
  check: file-exists .agents/scripts/issue-sync-helper.sh

- [x] v186 t004.1 Design multi-org data isolation schema and tenant context... | PR #1914 | merged:2026-02-19 verified:2026-02-19
  files: .agents/AGENTS.md, .agents/scripts/multi-org-helper.sh, .agents/services/database/multi-org-isolation.md, .agents/services/database/schemas/multi-org.ts, .agents/services/database/schemas/rls-policies.sql, .agents/services/database/schemas/tenant-context.ts, .agents/subagent-index.toon, configs/multi-org-config.json.txt
  check: file-exists .agents/AGENTS.md
  check: shellcheck .agents/scripts/multi-org-helper.sh
  check: file-exists .agents/scripts/multi-org-helper.sh
  check: file-exists .agents/services/database/multi-org-isolation.md
  check: file-exists .agents/services/database/schemas/multi-org.ts
  check: file-exists .agents/services/database/schemas/rls-policies.sql
  check: file-exists .agents/services/database/schemas/tenant-context.ts
  check: file-exists .agents/subagent-index.toon
  check: file-exists configs/multi-org-config.json.txt
  check: rg "multi-org-isolation" .agents/subagent-index.toon

- [x] v187 t1236 Investigate stale 'running' state for 2 workers with no d... | PR #1918 | merged:2026-02-19 verified:2026-02-19
  files: .agents/scripts/supervisor/ai-context.sh
  check: shellcheck .agents/scripts/supervisor/ai-context.sh
  check: file-exists .agents/scripts/supervisor/ai-context.sh

- [x] v188 t1224.3 Implement `localdev branch` — subdomain routing for wor... | PR #1916 | merged:2026-02-19 verified:2026-02-19
  files: .agents/scripts/localdev-helper.sh
  check: shellcheck .agents/scripts/localdev-helper.sh
  check: file-exists .agents/scripts/localdev-helper.sh

- [!] v189 t005.1 Design AI chat sidebar component architecture and state m... | PR #1917 | merged:2026-02-19 failed:2026-02-19 reason:rg: "ai-chat-sidebar" not found in .agents/subagent-index.toon
  files: .agents/tools/ui/ai-chat-sidebar.md, .opencode/ui/chat-sidebar/constants.ts, .opencode/ui/chat-sidebar/context/chat-context.tsx, .opencode/ui/chat-sidebar/context/settings-context.tsx, .opencode/ui/chat-sidebar/context/sidebar-context.tsx, .opencode/ui/chat-sidebar/hooks/use-chat.ts, .opencode/ui/chat-sidebar/hooks/use-resize.ts, .opencode/ui/chat-sidebar/hooks/use-streaming.ts, .opencode/ui/chat-sidebar/index.tsx, .opencode/ui/chat-sidebar/lib/api-client.ts, .opencode/ui/chat-sidebar/lib/storage.ts, .opencode/ui/chat-sidebar/types.ts
  check: file-exists .agents/tools/ui/ai-chat-sidebar.md
  check: file-exists .opencode/ui/chat-sidebar/constants.ts
  check: file-exists .opencode/ui/chat-sidebar/context/chat-context.tsx
  check: file-exists .opencode/ui/chat-sidebar/context/settings-context.tsx
  check: file-exists .opencode/ui/chat-sidebar/context/sidebar-context.tsx
  check: file-exists .opencode/ui/chat-sidebar/hooks/use-chat.ts
  check: file-exists .opencode/ui/chat-sidebar/hooks/use-resize.ts
  check: file-exists .opencode/ui/chat-sidebar/hooks/use-streaming.ts
  check: file-exists .opencode/ui/chat-sidebar/index.tsx
  check: file-exists .opencode/ui/chat-sidebar/lib/api-client.ts
  check: file-exists .opencode/ui/chat-sidebar/lib/storage.ts
  check: file-exists .opencode/ui/chat-sidebar/types.ts
  check: rg "ai-chat-sidebar" .agents/subagent-index.toon

- [x] v190 t1238 Fix create_subtasks executor to handle edge cases causing... | PR #1924 | merged:2026-02-19 verified:2026-02-19
  files: .agents/scripts/supervisor/ai-actions.sh, .agents/scripts/supervisor/ai-context.sh
  check: shellcheck .agents/scripts/supervisor/ai-actions.sh
  check: file-exists .agents/scripts/supervisor/ai-actions.sh
  check: shellcheck .agents/scripts/supervisor/ai-context.sh
  check: file-exists .agents/scripts/supervisor/ai-context.sh

- [x] v191 t1239 Add cross-repo task registration validation to prevent mi... | PR #1926 | merged:2026-02-19 verified:2026-02-19
  files: .agents/scripts/supervisor/batch.sh, .agents/scripts/supervisor/cron.sh, .agents/scripts/supervisor/dispatch.sh
  check: shellcheck .agents/scripts/supervisor/batch.sh
  check: file-exists .agents/scripts/supervisor/batch.sh
  check: shellcheck .agents/scripts/supervisor/cron.sh
  check: file-exists .agents/scripts/supervisor/cron.sh
  check: shellcheck .agents/scripts/supervisor/dispatch.sh
  check: file-exists .agents/scripts/supervisor/dispatch.sh

- [x] v192 t1224.4 Implement `localdev db` — shared Postgres management. `... | PR #1920 | merged:2026-02-19 verified:2026-02-19
  files: .agents/scripts/localdev-helper.sh
  check: shellcheck .agents/scripts/localdev-helper.sh
  check: file-exists .agents/scripts/localdev-helper.sh

- [x] v193 t1240 Investigate awardsapp t004/t005 subtask state after cross... | PR #1925 | merged:2026-02-19 verified:2026-02-19
  files: .agents/scripts/supervisor/ai-actions.sh, .agents/scripts/supervisor/ai-context.sh
  check: shellcheck .agents/scripts/supervisor/ai-actions.sh
  check: file-exists .agents/scripts/supervisor/ai-actions.sh
  check: shellcheck .agents/scripts/supervisor/ai-context.sh
  check: file-exists .agents/scripts/supervisor/ai-context.sh

- [x] v194 t1241 Add minimum estimate threshold bypass for trivial bugfixe... | PR #1930 | merged:2026-02-19 verified:2026-02-19
  files: .agents/scripts/supervisor/ai-context.sh
  check: shellcheck .agents/scripts/supervisor/ai-context.sh
  check: file-exists .agents/scripts/supervisor/ai-context.sh

- [x] v195 t1242 Verify create_subtasks executor fix from t1238 is working... | PR #1929 | merged:2026-02-19 verified:2026-02-19
  files: tests/test-ai-actions.sh
  check: shellcheck tests/test-ai-actions.sh
  check: file-exists tests/test-ai-actions.sh

- [x] v196 t1224.5 Implement `localdev list/status` — dashboard showing al... | PR #1934 | merged:2026-02-19 verified:2026-02-19
  files: .agents/scripts/localdev-helper.sh
  check: shellcheck .agents/scripts/localdev-helper.sh
  check: file-exists .agents/scripts/localdev-helper.sh

- [x] v197 t1243 Add auto-unblock detection for tasks whose blockers are r... | PR #1935 | merged:2026-02-19 verified:2026-02-19
  files: .agents/scripts/supervisor/cron.sh, .agents/scripts/supervisor/pulse.sh, .agents/scripts/supervisor/todo-sync.sh
  check: shellcheck .agents/scripts/supervisor/cron.sh
  check: file-exists .agents/scripts/supervisor/cron.sh
  check: shellcheck .agents/scripts/supervisor/pulse.sh
  check: file-exists .agents/scripts/supervisor/pulse.sh
  check: shellcheck .agents/scripts/supervisor/todo-sync.sh
  check: file-exists .agents/scripts/supervisor/todo-sync.sh

- [x] v198 t1245 Investigate stale evaluating recovery pattern — root ca... | PR #1940 | merged:2026-02-19 verified:2026-02-19
  files: .agents/scripts/supervisor/evaluate.sh, .agents/scripts/supervisor/pulse.sh
  check: shellcheck .agents/scripts/supervisor/evaluate.sh
  check: file-exists .agents/scripts/supervisor/evaluate.sh
  check: shellcheck .agents/scripts/supervisor/pulse.sh
  check: file-exists .agents/scripts/supervisor/pulse.sh

- [!] v199 t1224.6 Create local-hosting agent (`.agents/services/hosting/loc... | PR #1939 | merged:2026-02-19 failed:2026-02-19 reason:rg: "local-hosting" not found in .agents/subagent-index.toon
  files: .agents/services/hosting/local-hosting.md
  check: file-exists .agents/services/hosting/local-hosting.md
  check: rg "local-hosting" .agents/subagent-index.toon

- [x] v200 t1246 Auto-unblock tasks when blockers are verified — verify ... | PR #1938 | merged:2026-02-19 verified:2026-02-19
  files: .agents/scripts/supervisor/todo-sync.sh
  check: shellcheck .agents/scripts/supervisor/todo-sync.sh
  check: file-exists .agents/scripts/supervisor/todo-sync.sh

- [!] v201 t1224.7 Migrate awardsapp to new localdev setup — validate end-... | PR #1943 | merged:2026-02-19 failed:2026-02-19 reason:rg: "local-hosting" not found in .agents/subagent-index.toon
  files: .agents/services/hosting/local-hosting.md
  check: file-exists .agents/services/hosting/local-hosting.md
  check: rg "local-hosting" .agents/subagent-index.toon

- [x] v202 t1122 Fix issue-sync-helper.sh IFS unbound variable error in cm... | PR #1941 | merged:2026-02-19 verified:2026-02-19
  files: .agents/scripts/issue-sync-helper.sh
  check: shellcheck .agents/scripts/issue-sync-helper.sh
  check: file-exists .agents/scripts/issue-sync-helper.sh

- [!] v203 t1247 Auto-unblock tasks when blocker transitions to deployed/v... | PR #1945 | merged:2026-02-19 failed:2026-02-19 reason:shellcheck: tests/test-supervisor-state-machine.sh has violations
  files: .agents/scripts/supervisor-helper.sh, .agents/scripts/supervisor/pulse.sh, .agents/scripts/supervisor/todo-sync.sh, tests/test-supervisor-state-machine.sh
  check: shellcheck .agents/scripts/supervisor-helper.sh
  check: file-exists .agents/scripts/supervisor-helper.sh
  check: shellcheck .agents/scripts/supervisor/pulse.sh
  check: file-exists .agents/scripts/supervisor/pulse.sh
  check: shellcheck .agents/scripts/supervisor/todo-sync.sh
  check: file-exists .agents/scripts/supervisor/todo-sync.sh
  check: shellcheck tests/test-supervisor-state-machine.sh
  check: file-exists tests/test-supervisor-state-machine.sh

- [x] v204 t1249 Add stale-evaluating root cause analysis to pulse cycle #... | PR #1949 | merged:2026-02-19 verified:2026-02-19
  files: .agents/scripts/supervisor/database.sh, .agents/scripts/supervisor/pulse.sh, .agents/scripts/supervisor/state.sh
  check: shellcheck .agents/scripts/supervisor/database.sh
  check: file-exists .agents/scripts/supervisor/database.sh
  check: shellcheck .agents/scripts/supervisor/pulse.sh
  check: file-exists .agents/scripts/supervisor/pulse.sh
  check: shellcheck .agents/scripts/supervisor/state.sh
  check: file-exists .agents/scripts/supervisor/state.sh

- [ ] v205 t1250 Reduce stale-evaluating recovery frequency by improving w... | PR #1950 | merged:2026-02-19
  files: .agents/scripts/supervisor/pulse.sh
  check: shellcheck .agents/scripts/supervisor/pulse.sh
  check: file-exists .agents/scripts/supervisor/pulse.sh
