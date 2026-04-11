# t15474 — Extend setup.sh to deploy slash commands to all installed runtimes

## Problem

After merging [PR #18096](https://github.com/marcusquinn/aidevops/pull/18096) and running `./setup.sh --non-interactive`, only **OpenCode** and **Claude Code** received the new `aidevops-*` prefixed slash commands.

The other 7 installed clients on the same machine (Codex, Cursor, Droid, Gemini CLI, Continue, Kiro, Qwen) were detected by `rt_detect_installed` and their MCP servers were registered, but their command directories stayed empty until I manually ran:

```bash
for id in codex cursor droid gemini-cli continue kiro qwen; do
  .agents/scripts/generate-runtime-config.sh commands --runtime "$id"
done
```

Once the generator was invoked directly, each client received its 93 `aidevops-*` commands in the correct per-client format:

- Codex: stripped-frontmatter `.md` at `~/.codex/prompts/`
- Cursor: frontmatter-less `.md` at `~/.cursor/commands/`
- Droid: stripped-frontmatter `.md` at `~/.factory/commands/`
- Gemini CLI: `.toml` with `prompt = """…"""` at `~/.gemini/commands/`
- Continue: `.prompt` with `invokable: true` at `~/.continue/prompts/`
- Kiro: `.md` with `inclusion: manual` at `~/.kiro/steering/`
- Qwen: stripped-frontmatter `.md` at `~/.qwen/commands/`

So the generator works correctly — the gap is that `setup.sh` never calls it for these clients.

## Root cause

`setup.sh` orchestrates per-client install via per-client `update_*_config` functions under `setup-modules/` and `.agents/scripts/setup/`. Only `update_opencode_config` and `update_claude_config` have been migrated to the unified `generate-runtime-config.sh` path. The others (`update_codex_config`, `update_cursor_config`, `update_droid_config`, `update_gemini_config`, `update_continue_config`, `update_kiro_config`, etc.) still only handle MCP registration — they pre-date the unified command generator.

## Solution

Wire the unified command generator into every per-client update function for clients whose `_RT_COMMAND_DIR` entry in `runtime-registry.sh` is non-empty. Two possible shapes:

**Option A — inline the call into each `update_*_config` function.**

```bash
update_codex_config() {
    # existing MCP registration
    register_mcp_for_codex
    # new: command deployment via unified generator
    if declare -F _generate_commands_for_runtime >/dev/null 2>&1; then
        _generate_commands_for_runtime codex
    fi
}
```

Pros: each client's install flow stays self-contained; easy to disable per-client.
Cons: 10 functions to touch; copy-paste risk.

**Option B — add a single post-MCP pass in `setup.sh` that iterates installed clients and invokes the generator.**

```bash
# after all update_*_config calls
if [[ -x "$AGENTS_DIR/scripts/generate-runtime-config.sh" ]]; then
    for runtime_id in $(rt_detect_installed); do
        if [[ "$(rt_feature_commands "$runtime_id")" == "yes" ]] && [[ -n "$(rt_command_dir "$runtime_id")" ]]; then
            "$AGENTS_DIR/scripts/generate-runtime-config.sh" commands --runtime "$runtime_id"
        fi
    done
fi
```

Pros: one loop, honours feature flags, idempotent, doesn't modify per-client functions.
Cons: slight layering mess — the per-client update functions no longer have full ownership of their install flow.

**Recommendation: Option B.** The per-client functions were designed before the unified generator existed. Rather than duplicate the generator call into 10 places, bolt it on once at the end of the setup flow. It honours the existing `rt_feature_commands` gate added in PR #18096 for free.

## Files to modify

- `setup.sh` — add the post-MCP generator loop near the end of the runtime update section (currently ~line 1006–1011 where `update_claude_config` is called).
- `setup-modules/config.sh` — the per-runtime caller wiring may live here instead; check which file orchestrates `update_*_config` calls.

## Verification

Run `./setup.sh --non-interactive` on a machine with multiple clients installed. For each installed client with `_RT_COMMAND_DIR` non-empty, expect:

```bash
ls "$(rt_command_dir <id>)" | grep -c '^aidevops-'
```

to return the same count as `ls ~/.claude/commands | grep -c '^aidevops-'` (currently 93 commands). If the format is per-client (`.toml`, `.prompt`), match on the appropriate pattern.

## Scope

Small, bounded fix. One `setup.sh` loop (~15 lines) plus a quick cross-client verification. No runtime behaviour changes outside install — the generator is already exercised by OpenCode and Claude Code in production.

## Related

- PR #18096 — added the unified generator, per-client format transforms, and feature flag gating
- `.agents/scripts/generate-runtime-config.sh` — the target of the new loop
- `.agents/scripts/runtime-registry.sh` — source of `rt_detect_installed`, `rt_command_dir`, and `rt_feature_commands`
