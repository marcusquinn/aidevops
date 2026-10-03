# t18574: docs: re-sync and restructure Remotion and Cloudflare platform skills

## Origin

- **Created:** 2026-09-30
- **Created by:** ai-interactive
- **Issue:** GH#33150
- **Conversation context:** Framework value audit (parent GH#33139); maintainer approved retiring redundant tooling while keeping the useful ideas.

blocked-by: GH#33135

## Why

Both skills were last synced on 2026-01-21, and Remotion upstream has changed since. The Cloudflare tree is large and mixes operations content already covered by the MCP and `cf` CLI docs, which makes it slow to navigate.

## What

The maintainer uses Remotion and Cloudflare heavily, so keep both knowledge bases, but make them current and quicker to navigate. Parent: GH#33139.

Both were last synced on 2026-01-21 (`.agents/configs/skill-sources.json`). Upstream `remotion-dev/skills` had a commit on 2026-09-29. The sync stalled because of the checker bug fixed in GH#33135, which must merge first.

## How

### Remotion (official upstream, 30 loose `tools/video/remotion-*.md` files)

- Re-sync from upstream through `add-skill-helper.sh` / `skill-update-helper.sh update remotion`, not by hand.
- Move the chapters into a `tools/video/remotion` subfolder, with `remotion.md` as the index, so `tools/video` stops holding 30 near-duplicate names.
- Keep upstream wording. If it would otherwise re-import, set the importer's target path in `skill-sources.json`.
- Keep the aidevops-specific integration notes: the heygen and threejs links, and `scripts/higgsfield/remotion`.

### Cloudflare (third-party `dmmulroy/cloudflare-skill`, about 188 files)

- First, look for an official Cloudflare-published agent skill (`gh search repos --owner cloudflare skill`). If one exists and is maintained, switch `skill-sources.json` to it.
- The Cloudflare MCP (`tools/api/cloudflare-mcp.md`, `tools/mcp/cloudflare-code-mode.md`) and the `cf` CLI (`tools/api/cloudflare-cf-cli.md`) cover operations. The skill's job is knowing which product to use and how to use it. Keep:
  - the top-level decision tree
  - every `*-gotchas.md`
  - docs for newer products (containers, agents-sdk, ai-search, r2-data-catalog, sandbox, realtimekit, workflows)
- Drop the generic `*-patterns.md` sets, the `r2-patterns` and `do-storage-patterns` example folders, and the `pulumi*` and `terraform*` docs.
- Record every local trim in `skill-sources.json`, as an exclude list or a post-sync step, so the next sync does not re-import dropped files.

## Reference pattern

Use the existing import and exclude mechanics in `.agents/scripts/add-skill-helper-import.sh` and the `skill-sources.json` schema. Do not hand-copy upstream content.

### Files Scope

- `.agents/configs/skill-sources.json`
- `.agents/tools/video`
- `.agents/services/hosting/cloudflare-platform-skill`
- `.agents/services/hosting/cloudflare-platform-skill.md`
- `.agents/services/hosting/cloudflare.md`
- `.agents/tools/api/cloudflare-mcp.md`
- `.agents/tools/api/cloudflare-cf-cli.md`
- `.agents/tools/infrastructure/cloudflare-ai.md`
- `.agents/tools/database/vector-search/per-tenant-rag.md`
- `.agents/content/heygen-skill/rules-remotion-integration.md`
- `.agents/tools/design/threejs.md`
- `.agents/scripts/add-skill-helper-import.sh`
- `.agents/scripts/setup/modules/migrations.sh`
- `.agents/configs/simplification-state.json`
- `.agents/subagent-index.toon`
- `biome.json`
- `.codacy.yml`

## Acceptance criteria

- [ ] `skill-update-helper.sh check` reports both skills up to date after the PR.
- [ ] The Remotion chapters live under `tools/video/remotion`, and all inbound links resolve.
- [ ] The Cloudflare tree keeps the decision tree, gotchas and newer products; the trims are recorded so re-sync keeps them.
- [ ] Deployed installs lose the moved or removed files through migrations.
- [ ] Markdown lint and link checks pass.

## Verification

```bash
.agents/scripts/skill-update-helper.sh check
rg -n 'tools/video/remotion-' .agents
.agents/scripts/linters-local.sh
```

Parent: #33139
