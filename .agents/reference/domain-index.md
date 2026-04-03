# Domain Index

Read subagents on-demand. Full index: `subagent-index.toon`.

| Domain | Entry point |
|--------|-------------|
| Business | `business.md`, `business/company-runners.md` |
| Planning | `workflows/plans.md`, `scripts/commands/define.md`, `tools/task-management/beads.md` |
| Code quality | `tools/code-review/code-standards.md` |
| Git/PRs/Releases | `workflows/git-workflow.md`, `tools/git/github-cli.md`, `workflows/release.md` |
| Documents/PDF | `tools/document/document-creation.md`, `tools/pdf/overview.md`, `tools/conversion/pandoc.md` |
| OCR | `tools/ocr/overview.md`, `tools/ocr/paddleocr.md`, `tools/ocr/glm-ocr.md` |
| Product (shared) | `product/validation.md`, `product/onboarding.md`, `product/monetisation.md`, `product/growth.md`, `product/ui-design.md`, `product/analytics.md` |
| Browser/Mobile | `tools/browser/browser-automation.md`, `tools/browser/browser-qa.md`, `tools/browser/browser-use.md`, `tools/browser/chromium-debug-use.md`, `tools/browser/skyvern.md`, `tools/mobile/app-dev.md`, `tools/mobile/app-store-connect.md`, `tools/browser/extension-dev.md` |
| Content/Video/Voice | `content.md`, `tools/video/video-prompt-design.md`, `tools/voice/speech-to-speech.md`, `tools/voice/transcription.md` |
| Design | `tools/design/ui-ux-inspiration.md`, `tools/design/ui-ux-catalogue.toon`, `tools/design/brand-identity.md` |
| SEO | `seo/dataforseo.md`, `seo/google-search-console.md` |
| Paid Ads/CRO | `marketing-sales/meta-ads.md`, `marketing-sales/ad-creative.md`, `marketing-sales/direct-response-copy.md`, `marketing-sales/cro.md` |
| WordPress | `tools/wordpress/wp-dev.md`, `tools/wordpress/mainwp.md` |
| Communications | `services/communications/bitchat.md`, `services/communications/convos.md`, `services/communications/discord.md`, `services/communications/google-chat.md`, `services/communications/imessage.md`, `services/communications/matterbridge.md`, `services/communications/matrix-bot.md`, `services/communications/msteams.md`, `services/communications/nextcloud-talk.md`, `services/communications/nostr.md`, `services/communications/signal.md`, `services/communications/simplex.md`, `services/communications/slack.md`, `services/communications/telegram.md`, `services/communications/urbit.md`, `services/communications/whatsapp.md`, `services/communications/xmpp.md` |
| Email | `tools/ui/react-email.md`, `services/email/email-agent.md`, `services/email/email-mailbox.md`, `services/email/email-actions.md`, `services/email/email-intelligence.md`, `services/email/email-providers.md`, `services/email/email-security.md`, `services/email/email-testing.md`, `services/email/email-composition.md`, `services/email/email-inbound-commands.md`, `services/email/google-workspace.md` |
| Outreach | `services/outreach/cold-outreach.md`, `services/outreach/smartlead.md`, `services/outreach/instantly.md`, `services/outreach/manyreach.md` |
| Payments | `services/payments/revenuecat.md`, `services/payments/stripe.md`, `services/payments/procurement.md` |
| Auth troubleshooting | `tools/credentials/auth-troubleshooting.md` |
| Security/Encryption | `tools/security/tirith.md`, `tools/security/opsec.md`, `tools/security/prompt-injection-defender.md`, `tools/security/tamper-evident-audit.md`, `tools/credentials/encryption-stack.md`, `scripts/secret-hygiene-helper.sh` |
| Database/Local-first | `tools/database/pglite-local-first.md`, `services/database/postgres-drizzle-skill.md` |
| Vector Search | `tools/database/vector-search.md`, `tools/database/vector-search/zvec.md` |
| Local Development | `services/hosting/local-hosting.md` |
| Hosting/Deployment | `tools/deployment/hosting-comparison.md`, `tools/deployment/fly-io.md`, `tools/deployment/coolify.md`, `tools/deployment/vercel.md`, `tools/deployment/uncloud.md`, `tools/deployment/daytona.md` |
| Infrastructure | `tools/infrastructure/cloud-gpu.md`, `tools/containers/orbstack.md`, `tools/containers/remote-dispatch.md` |
| Accessibility | `tools/accessibility/accessibility-audit.md` |
| OpenAPI exploration | `tools/context/openapi-search.md` |
| Local models | `tools/local-models/local-models.md`, `tools/local-models/huggingface.md`, `scripts/local-model-helper.sh` |
| Bundles | `bundles/*.json`, `scripts/bundle-helper.sh`, `tools/context/model-routing.md` |
| Agent routing | `reference/agent-routing.md` |
| Model routing | `tools/context/model-routing.md`, `reference/orchestration.md` |
| Orchestration | `reference/orchestration.md`, `tools/ai-assistants/headless-dispatch.md`, `scripts/commands/pulse.md`, `scripts/commands/dashboard.md` |
| Upstream watch | `scripts/upstream-watch-helper.sh`, `.agents/configs/upstream-watch.json` |
| Testing | `scripts/commands/testing-setup.md`, `tools/build-agent/agent-testing.md`, `scripts/testing-setup-helper.sh` |
| Agent/MCP dev | `tools/build-agent/build-agent.md`, `tools/build-mcp/build-mcp.md`, `tools/mcp-toolkit/mcporter.md` |
| Self-Improvement | `reference/self-improvement.md`, `tools/autoagent/autoagent.md`, `scripts/commands/autoagent.md` |
| Framework | `aidevops/architecture.md`, `scripts/commands/skills.md` |

**Creating agents**: When a user asks to create, build, or design an agent — regardless of which primary agent is active — always read `tools/build-agent/build-agent.md` first. It contains the tier prompt (draft/custom/shared), design checklist, and lifecycle rules.
