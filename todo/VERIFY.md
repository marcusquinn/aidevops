
- [ ] v001 t267 Higgsfield image count detection fails after generation -... | PR #1068 | merged:2026-02-11
  files: .agents/scripts/higgsfield/playwright-automator.mjs
  check: file-exists .agents/scripts/higgsfield/playwright-automator.mjs

- [ ] v002 t269 Higgsfield video download fails silently - downloadLatest... | PR #1067 | merged:2026-02-11
  files: .agents/scripts/higgsfield/playwright-automator.mjs
  check: file-exists .agents/scripts/higgsfield/playwright-automator.mjs

- [ ] v003 t008 aidevops-opencode Plugin #plan → [todo/PLANS.md#aidevop... | PR #1073 | merged:2026-02-11
  files: .agents/plugins/opencode-aidevops/index.mjs, .agents/plugins/opencode-aidevops/package.json, .agents/tools/build-mcp/aidevops-plugin.md
  check: file-exists .agents/plugins/opencode-aidevops/index.mjs
  check: file-exists .agents/plugins/opencode-aidevops/package.json
  check: file-exists .agents/tools/build-mcp/aidevops-plugin.md
  check: rg "aidevops-plugin" .agents/subagent-index.toon

- [ ] v004 t012 OCR Invoice/Receipt Extraction Pipeline #plan → [todo/P... | PR #1074 | merged:2026-02-11
  files: .agents/accounts.md, .agents/scripts/ocr-receipt-helper.sh, .agents/subagent-index.toon, .agents/tools/accounts/receipt-ocr.md, .agents/tools/document/extraction-workflow.md
  check: file-exists .agents/accounts.md
  check: shellcheck .agents/scripts/ocr-receipt-helper.sh
  check: file-exists .agents/scripts/ocr-receipt-helper.sh
  check: file-exists .agents/subagent-index.toon
  check: file-exists .agents/tools/accounts/receipt-ocr.md
  check: file-exists .agents/tools/document/extraction-workflow.md
  check: rg "receipt-ocr" .agents/subagent-index.toon
  check: rg "extraction-workflow" .agents/subagent-index.toon

- [ ] v005 t012.2 Design extraction schema (vendor, amount, date, VAT, item... | PR #1080 | merged:2026-02-11
  files: .agents/scripts/document-extraction-helper.sh, .agents/subagent-index.toon, .agents/tools/document/document-extraction.md, .agents/tools/document/extraction-schemas.md
  check: shellcheck .agents/scripts/document-extraction-helper.sh
  check: file-exists .agents/scripts/document-extraction-helper.sh
  check: file-exists .agents/subagent-index.toon
  check: file-exists .agents/tools/document/document-extraction.md
  check: file-exists .agents/tools/document/extraction-schemas.md
  check: rg "document-extraction" .agents/subagent-index.toon
  check: rg "extraction-schemas" .agents/subagent-index.toon

- [ ] v006 t283 issue-sync cmd_close iterates all 533 completed tasks mak... | PR #1084 | merged:2026-02-11
  files: .agents/scripts/issue-sync-helper.sh, .github/workflows/issue-sync.yml
  check: shellcheck .agents/scripts/issue-sync-helper.sh
  check: file-exists .agents/scripts/issue-sync-helper.sh
  check: file-exists .github/workflows/issue-sync.yml
