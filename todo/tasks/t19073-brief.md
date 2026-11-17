<!-- aidevops:brief-schema=v2 -->

## Origin

- **Created:** 2026-11-17
- **Created by:** ai-interactive (follow-up to t19051 / GH#38563 Runpod CLI and SaladCloud CLI session)
- **Conversation context:** The operator stored account-named keys following the credential-inventory naming rule (`<PROVIDER>_<ACCOUNT>_<KIND>`): `RUNPOD_MARCUSQUINN_API_KEY` and `SALAD_MARCUSQUINN_API_KEY`. `runpodctl` reads `RUNPOD_API_KEY` and `saladcloud` reads `SALAD_API_KEY`, but those conventional variables can only resolve through `aidevops secret default PROVIDER NAME` for providers listed in `DEFAULT_ENV`, and neither provider is listed. The documented `aidevops secret RUNPOD_API_KEY -- runpodctl ...` path therefore fails for account-named keys.

## What

Add `runpod: RUNPOD_API_KEY` and `saladcloud: SALAD_API_KEY` to `DEFAULT_ENV` so an explicit `aidevops secret default runpod RUNPOD_<ACCOUNT>_API_KEY` makes `RUNPOD_API_KEY` resolve at injection (same for SaladCloud). Document the record/default step in the Runpod and SaladCloud guides and list the new conventional variables in the credential-inventory guide.

## Why

Without it, operators must store the bare conventional variable (which the credential-inventory guide forbids) or wrap every command in `sh -c 'RUNPOD_API_KEY="$RUNPOD_X_API_KEY" ...'`.

## Tier

**Selected tier:** `tier:simple`

**Tier rationale:** Two dictionary entries plus doc lines; verified with the existing registry CLI.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/credential_inventory_fields.py`: add the two `DEFAULT_ENV` entries (pattern: existing `hetzner: HCLOUD_TOKEN`).
- `EDIT: .agents/tools/credentials/credential-inventory.md`: add the variables to the "Resolution at injection" conventional-variable list.
- `EDIT: .agents/tools/infrastructure/runpod.md`, `.agents/tools/infrastructure/saladcloud.md`: account-named key setup (`record`, `default`) and SaladCloud CLI v0.2.0 notes (organization required).

### Files Scope

- `.agents/scripts/credential_inventory_fields.py`
- `.agents/tools/credentials/credential-inventory.md`
- `.agents/tools/infrastructure/runpod.md`
- `.agents/tools/infrastructure/saladcloud.md`

### Verification Before Dispatch

```bash
AIDEVOPS_CREDENTIAL_INVENTORY=<temp registry> python3 .agents/scripts/credential_inventory.py injection-map
```

With a temp registry recording `RUNPOD_X_API_KEY` (provider runpod) and `default runpod RUNPOD_X_API_KEY`, `injection-map` prints `RUNPOD_API_KEY<TAB>RUNPOD_X_API_KEY`; without a default it prints nothing.

## Acceptance Criteria

- [ ] `injection-map` maps `RUNPOD_API_KEY` and `SALAD_API_KEY` only after an explicit default.
- [ ] Existing credential-inventory tests pass.
- [ ] Guides show the account-named setup.
