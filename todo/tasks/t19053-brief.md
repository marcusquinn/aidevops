<!-- aidevops:brief-schema=v2 -->

## Origin

- **Created:** 2026-11-16
- **Created by:** ai-interactive (t19051 / GH#38563 Runpod CLI and MCP session)
- **Conversation context:** While documenting current `runpodctl` usage for t19051, PR #38559 (GH#38556) merged `blender-render-helper.sh` using the deprecated legacy `runpodctl` commands. Review note: https://github.com/marcusquinn/aidevops/pull/38559#issuecomment-6904473351

## What

Migrate the Runpod adapter in `.agents/scripts/blender-render-helper.sh` from deprecated legacy `runpodctl` commands to the current noun-verb JSON interface:

- `_brh_runpod_create` (around line 423): `runpodctl create pod --gpuType/--gpuCount/--imageName/--volumeSize/--ports/--args` → `runpodctl pod create --name ... --image ... --gpu-id ... [volume/ports/args flags from 'runpodctl pod create --help']`.
- Pod-id parsing in `submit` (around line 588): replace the `sed` match on the plaintext `pod "<id>" created` line with a JSON read of `.id` (jq is already a framework dependency); treat stderr JSON `code` `create_uncertain` / `wait_timeout` (with `id`) as "may exist and bill": record the id and stop.
- `_brh_runpod_status` / teardown check (around lines 436 and 745): `runpodctl get pod` → `runpodctl pod list`, matching job pod ids in JSON.
- `_brh_runpod_teardown_one` (around line 442): `stop pod`/`remove pod` → `pod stop`/`pod delete`.
- In-pod self-terminate in `_brh_render_command` (around line 418): `runpodctl remove pod $RUNPOD_POD_ID` → `runpodctl pod delete $RUNPOD_POD_ID`.

## Why

Legacy commands are deprecated upstream (runpod/runpodctl README "legacy commands") and print plaintext errors without the JSON `code`/`id` fields, so the helper cannot distinguish a failed create from one that left a billing pod. Current syntax reference: `.agents/tools/infrastructure/runpod.md`.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** One adapter block plus id parsing in a single script; live verification needs operator spend.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/blender-render-helper.sh`: Runpod adapter functions and the submit pod-id parse; keep dry-run default, Bash 3.2 compatibility and explicit returns.
- `EDIT: .agents/tools/design/3d-render-backends.md`: only if the printed commands shown in the helper section change.

### Files Scope

- `.agents/scripts/blender-render-helper.sh`
- `.agents/tools/design/3d-render-backends.md`

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/blender-render-helper.sh
.agents/scripts/blender-render-helper.sh help
```

Run `plan` and `submit` in default dry-run mode with a fixture manifest as the existing PR did, and confirm the printed commands use `runpodctl pod create|list|stop|delete`. Live verification (needs a Runpod account and spend approval) is operator-owned; say so in the PR.

## Acceptance Criteria

- [ ] No `runpodctl create pod`, `get pod`, `stop pod` or `remove pod` remain: `rg -n "runpodctl (create|get|stop|remove) pod" .agents/scripts/blender-render-helper.sh` returns nothing.
- [ ] Pod id is read from JSON; `create_uncertain`/`wait_timeout` paths record the reported `id` and stop.
- [ ] ShellCheck zero violations; dry-run output shows current syntax.
