# TODO

Project task tracking for aidevops framework.

Compatible with [todo-md](https://github.com/todo-md/todo-md), [todomd](https://github.com/todomd/todo.md), [taskell](https://github.com/smallhadroncollider/taskell), and TOON-enhanced parsing.

## Format

**Human-readable:**

```markdown
- [ ] Task description @owner #tag ~4h (ai:2h test:1h read:30m) logged:2025-01-15
- [x] Completed task ~2h actual:1.5h logged:2025-01-10 completed:2025-01-15
- [-] Declined task
```

**Time fields:**
- `~estimate` - Total time estimate with optional breakdown `(ai:Xh test:Xh read:Xm research:Xm)`
- `actual:` - Actual time spent (recorded at commit/release)
- `logged:` - When task was added
- `started:` - When branch was created (work began)
- `completed:` - When task was marked done

**Machine data:** TOON blocks in HTML comments (invisible when rendered).

<!--TOON:meta{version,format,updated}:
1.0,todo-md+toon,2025-12-20T00:00:00Z
-->

## Backlog

- [ ] Demote wordpress.md from main agent to subagent #architecture ~1h (ai:30m test:30m) logged:2025-12-21
- [ ] Evaluate Merging build-agent and build-mcp into aidevops #plan → [todo/PLANS.md#evaluate-merging-build-agent-and-build-mcp-into-aidevops] ~4h (ai:2h test:1h read:1h) logged:2025-12-21
- [ ] Claude Code Destructive Command Hooks #plan → [todo/PLANS.md#claude-code-destructive-command-hooks] ~4h (ai:2h test:1h read:1h) logged:2025-12-21
- [ ] aidevops-opencode Plugin #plan → [todo/PLANS.md#aidevops-opencode-plugin] ~2d (ai:1d test:0.5d read:0.5d) logged:2025-12-21
- [ ] Add Ahrefs MCP server integration #seo ~2d (ai:1d test:0.5d read:0.5d) logged:2025-12-20
- [ ] Implement multi-tenant credential storage #security ~5d (ai:3d test:1.5d read:0.5d) logged:2025-12-20
- [ ] Add Playwright MCP auto-setup to setup.sh #browser ~1d (ai:0.5d test:0.5d) logged:2025-12-20
- [ ] Create MCP server for QuickFile accounting API #accounting ~3d (ai:2d test:1d) logged:2025-12-20
- [ ] OCR Invoice/Receipt Extraction Pipeline #plan → [todo/PLANS.md#ocr-invoicereceipt-extraction-pipeline] ~3d (ai:1.5d test:1d read:0.5d) logged:2025-12-21
- [ ] Image SEO Enhancement with AI Vision #plan → [todo/PLANS.md#image-seo-enhancement-with-ai-vision] ~6h (ai:3h test:2h read:1h) logged:2025-12-21
- [ ] Document RapidFuzz library for fuzzy string matching #tools #context ~30m (ai:20m read:10m) logged:2025-12-21
- [ ] Add MinerU subagent as alternative to Pandoc for PDF conversion #tools #conversion ~1h (ai:30m read:30m) logged:2025-12-21
- [ ] Uncloud Integration for aidevops #plan → [todo/PLANS.md#uncloud-integration-for-aidevops] ~1d (ai:4h test:4h read:2h) logged:2025-12-21
- [ ] SEO Machine Integration for aidevops #plan → [todo/PLANS.md#seo-machine-integration-for-aidevops] ~2d (ai:1d test:0.5d read:0.5d) logged:2025-12-21
- [ ] Enhance Plan+ and Build+ with OpenCode's Latest Features #plan → [todo/PLANS.md#enhance-plan-and-build-with-opencodes-latest-features] ~3h (ai:1.5h test:1h read:30m) logged:2025-12-21

<!--TOON:backlog[15]{id,desc,owner,tags,est,est_ai,est_test,est_read,logged,status}:
t011,Demote wordpress.md from main agent to subagent,,architecture,1h,30m,30m,,2025-12-21T14:30Z,pending
t010,Evaluate Merging build-agent and build-mcp into aidevops,,plan|architecture|agents,4h,2h,1h,1h,2025-12-21T14:00Z,pending
t009,Claude Code Destructive Command Hooks,,plan|claude|git|security,4h,2h,1h,1h,2025-12-21T12:00Z,pending
t008,aidevops-opencode Plugin,,plan,2d,1d,0.5d,0.5d,2025-12-21T01:50Z,pending
t004,Add Ahrefs MCP server integration,,seo,2d,1d,0.5d,0.5d,2025-12-20T00:00Z,pending
t005,Implement multi-tenant credential storage,,security,5d,3d,1.5d,0.5d,2025-12-20T00:00Z,pending
t006,Add Playwright MCP auto-setup to setup.sh,,browser,1d,0.5d,0.5d,,2025-12-20T00:00Z,pending
t007,Create MCP server for QuickFile accounting API,,accounting,3d,2d,1d,,2025-12-20T00:00Z,pending
t012,OCR Invoice/Receipt Extraction Pipeline,,plan|accounting|ocr|automation,3d,1.5d,1d,0.5d,2025-12-21T22:00Z,pending
t013,Image SEO Enhancement with AI Vision,,plan|seo|images|ai|accessibility,6h,3h,2h,1h,2025-12-21T23:30Z,pending
t014,Document RapidFuzz library for fuzzy string matching,,tools|context,30m,20m,,10m,2025-12-21T12:00Z,pending
t015,Add MinerU subagent as alternative to Pandoc for PDF conversion,,tools|conversion,1h,30m,,30m,2025-12-21T15:00Z,pending
t016,Uncloud Integration for aidevops,,plan|deployment|docker|orchestration,1d,4h,4h,2h,2025-12-21T04:00Z,pending
t017,SEO Machine Integration for aidevops,,plan|seo|content|agents,2d,1d,0.5d,0.5d,2025-12-21T15:00Z,pending
t018,Enhance Plan+ and Build+ with OpenCode's Latest Features,,plan|opencode|agents|enhancement,3h,1.5h,1h,30m,2025-12-21T04:30Z,pending
-->

## In Progress

<!--TOON:in_progress[0]{id,desc,owner,tags,est,est_ai,est_test,est_read,logged,started,status}:
-->

## Done

- [x] Add TODO.md and planning workflow #workflow ~2h actual:1.5h logged:2025-12-18 completed:2025-12-20
- [x] Add shadcn/ui MCP support #tools ~1h actual:45m logged:2025-12-18 completed:2025-12-18
- [x] Add oh-my-opencode integration #tools ~30m actual:25m logged:2025-12-18 completed:2025-12-18

<!--TOON:done[3]{id,desc,owner,tags,est,actual,logged,started,completed,status}:
t001,Add TODO.md and planning workflow,,workflow,2h,1.5h,2025-12-18T00:00Z,2025-12-18T10:00Z,2025-12-20T00:00Z,done
t002,Add shadcn/ui MCP support,,tools,1h,45m,2025-12-18T00:00Z,2025-12-18T08:00Z,2025-12-18T09:00Z,done
t003,Add oh-my-opencode integration,,tools,30m,25m,2025-12-18T00:00Z,2025-12-18T09:00Z,2025-12-18T10:00Z,done
-->

## Declined

<!-- Tasks that were considered but decided against -->

<!--TOON:declined[0]{id,desc,reason,logged,status}:
-->

<!--TOON:summary{total,pending,in_progress,done,declined,total_est,total_actual}:
18,15,0,3,0,19d23h,2h40m
-->
