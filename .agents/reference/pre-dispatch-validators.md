# Pre-Dispatch Validators

Runs **after** dedup checks and **before** worker spawn for auto-generated issues — verifies the premise still holds (GH#19118).

## Architecture

Auto-generated issues embed `<!-- aidevops:generator=<name> -->` in the body (HTML comments survive title/label changes). `pre-dispatch-validator-helper.sh` maps generators to validators via `_VALIDATOR_REGISTRY`. Unregistered generators, missing helper, or unexpected exit code → exit 0 (dispatch proceeds).

### Exit codes

| Code | Meaning | Action |
|------|---------|--------|
| `0`  | Premise holds or no validator registered | Worker spawned |
| `10` | Premise falsified | Comment posted (`> Premise falsified`, citing GH#19118) + `gh issue close --reason "not planned"` |
| `20` | Validator error | Warning logged; dispatch proceeds (never block on validator bugs) |

### Hook point (`pulse-dispatch-core.sh`)

```text
_dispatch_dedup_check_layers()   ← all dedup gates
_ensure_issue_body_has_brief()   ← t2063 freshness guard
_run_predispatch_validator()     ← GH#19118 ← HERE
_dispatch_launch_worker()        ← worker spawn
```

## Bypass

```bash
AIDEVOPS_SKIP_PREDISPATCH_VALIDATOR=1 ./pulse-wrapper.sh
```

Emergency recovery when a validator bug blocks legitimate dispatches. Bypass is logged; do not leave set permanently.

## Registered validators

### `ratchet-down`

**Generator:** `_complexity_scan_ratchet_check` in `pulse-simplification.sh`
**Marker:** `<!-- aidevops:generator=ratchet-down -->`

1. Clone target repo into `mktemp -d` (trap-cleaned); run `complexity-scan-helper.sh ratchet-check <clone> 5`.
2. `No ratchet-down available` in output → exit 10 (falsified); empty output + any error → exit 20; otherwise → exit 0.

Prevents workers spawning only to find no ratchet-down work exists (GH#19024).

## Adding a validator

1. Define the generator function in `pulse-simplification.sh` or the issue-creation script.
2. Emit the marker in the issue body: `<!-- aidevops:generator=my-generator -->`
3. Implement in `pre-dispatch-validator-helper.sh`:
   ```bash
   _validator_my_generator() {
       local slug="$1"
       # Use $SCRATCH_DIR for temp files — trap cleanup already set
       return 0  # 0=dispatch, 10=falsified, 20=error
   }
   ```
4. Register in `_register_validators()`:
   ```bash
   _VALIDATOR_REGISTRY["my-generator"]="_validator_my_generator"
   ```
5. Add test cases in `tests/test-pre-dispatch-validator.sh` (falsified + legitimate paths).
6. Run `shellcheck .agents/scripts/pre-dispatch-validator-helper.sh`.

## Testing

```bash
bash .agents/scripts/tests/test-pre-dispatch-validator.sh
.agents/scripts/pre-dispatch-validator-helper.sh validate <issue-number> marcusquinn/aidevops
```

`gh`, `git`, and `complexity-scan-helper.sh` stubbed via `PATH` and `COMPLEXITY_SCAN_HELPER` — no network required.

## Related

- `pulse-dispatch-core.sh` — `dispatch_with_dedup`, `_run_predispatch_validator`
- `pulse-simplification.sh` — `_complexity_scan_ratchet_check` (ratchet-down generator)
- `reference/worker-diagnostics.md` — full worker lifecycle
- GH#19118 (feature), GH#19024 (post-mortem), GH#19036, GH#19037 (root causes)
