## Problem

`opencode2` (isolated OpenCode V2 preview, 2.0.3) reports the aidevops plugin as failed on every start. `opencode2 api GET /api/plugin` returns two `aidevops` entries. One is `active`; the other is `failed` with `"error":"Duplicate plugin ID: aidevops"`. `opencode2 plugin list` also shows the duplicate.

## Root cause

`setup_opencode_plugins` in `.agents/scripts/setup/modules/mcp-setup.sh` registers the plugin twice for the V2 profile:

1. a `file://.../v2-plugin` entry in the V2 config `plugins` array
2. an auto-discovered symlink at `<v2 config>/plugins/aidevops-v2`

V1 tolerates duplicate loading. V2 defines the plugin with `Plugin.define({ id: "aidevops" })` (`.agents/plugins/opencode-aidevops/v2.mjs`) and rejects a second registration with the same ID. `.agents/scripts/tests/test-opencode-v2-setup.sh` asserted that both mechanisms exist, which locked in the conflict.

## Files Scope

- `.agents/scripts/setup/modules/mcp-setup.sh`
- `.agents/scripts/tests/test-opencode-v2-setup.sh`
- `.agents/tools/opencode/opencode.md`

## Reference pattern

Model the change on the existing `_setup_opencode_plugins_register_symlink` helper in `mcp-setup.sh`.

## Acceptance

- [ ] V2 setup registers the plugin exactly once, using the config `plugins` entry. The symlink is used only as a fallback when config registration fails.
- [ ] Setup/update removes an existing managed `plugins/aidevops-v2` symlink that points into the aidevops plugin tree. User-owned entries are left untouched.
- [ ] The regression test covers single registration and stale-symlink cleanup.

## Verification

```bash
bash .agents/scripts/tests/test-opencode-v2-setup.sh
shellcheck .agents/scripts/setup/modules/mcp-setup.sh
opencode2 api GET /api/plugin   # exactly one aidevops entry, status active
```
