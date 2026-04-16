# Pre-Dispatch Validators

Pre-dispatch validators run **after** dedup checks and **before** worker spawn for auto-generated issues, verifying the premise is still true (GH#19118). Root causes: GH#19036, GH#19037; post-mortem: GH#19024.

## Architecture

Auto-generated issues embed a hidden marker — parsed with `grep -oE '<!-- aidevops:generator=[a-z-]+ -->'`. Parsing titles or labels is rejected; markers survive editorial changes to human-visible fields.

```text
<!-- aidevops:generator=<name> -->
```

`pre-dispatch-validator-helper.sh` maintains `_VALIDATOR_REGISTRY` mapping generator names to validator functions, populated by `_register_validators()`. Unregistered generators exit 0 (dispatch proceeds).

### Exit-code contract

| Code | Meaning | Action |
|------|---------|--------|
| `0`  | Dispatch proceeds — premise holds or no validator registered | Worker spawned normally |
| `10` | Premise falsified — issue is stale | Rationale comment posted + issue closed as `not planned`; no worker |
| `20` | Validator error | Warning logged; dispatch proceeds (never block on validator bugs) |

### Hook point in `dispatch_with_dedup()` (`pulse-dispatch-core.sh`)

```text
_dispatch_dedup_check_layers()   ← all dedup gates
_ensure_issue_body_has_brief()   ← t2063 freshness guard
_run_predispatch_validator()     ← GH#19118 ← HERE
_dispatch_launch_worker()        ← worker spawn
```

Non-fatal: if the helper is missing or returns an unexpected code, dispatch proceeds.

## Bypass

```bash
AIDEVOPS_SKIP_PREDISPATCH_VALIDATOR=1 ./pulse-wrapper.sh
```

Emergency recovery when a validator bug blocks legitimate dispatches. Bypass is logged. Do not leave set permanently.

## On exit 10

Posts a `> Premise falsified` blockquote naming the generator, noting no actionable work, and citing GH#19118. Closes with `gh issue close --reason "not planned"`. A new issue is created if conditions change on the next pulse cycle.

## Registered validators

### `ratchet-down`

**Generator:** `_complexity_scan_ratchet_check` in `pulse-simplification.sh`
**Marker:** `<!-- aidevops:generator=ratchet-down -->`

1. Clone the target repo into `mktemp -d` (trap-cleaned on exit)
2. Run `complexity-scan-helper.sh ratchet-check <clone> 5`
3. `No ratchet-down available` in output → exit 10 (premise falsified)
4. Empty output + any error → exit 20 (validator error)
5. Otherwise → exit 0 (proposals available, dispatch)

Without this check, workers spawn only to discover no ratchet-down work exists (GH#19024 failure mode).

## Adding a validator

1. **Define the generator function** in `pulse-simplification.sh` or the issue-creation script.

2. **Emit the marker** in the issue body template:

   ```bash
   "...issue content...\n\n<!-- aidevops:generator=my-generator -->"
   ```

3. **Implement the validator** in `pre-dispatch-validator-helper.sh`:

   ```bash
   _validator_my_generator() {
       local slug="$1"
       # Use $SCRATCH_DIR for temp files — trap cleanup is already set
       # Return: 0 = dispatch, 10 = falsified, 20 = error
       return 0
   }
   ```

4. **Register** in `_register_validators()`:

   ```bash
   _VALIDATOR_REGISTRY["my-generator"]="_validator_my_generator"
   ```

5. **Add test cases** in `tests/test-pre-dispatch-validator.sh` covering the falsified and legitimate paths.

6. **Run shellcheck**: `shellcheck .agents/scripts/pre-dispatch-validator-helper.sh`

## Testing

```bash
# Run the test harness
bash .agents/scripts/tests/test-pre-dispatch-validator.sh
# Manual smoke test (requires gh auth)
.agents/scripts/pre-dispatch-validator-helper.sh validate <issue-number> marcusquinn/aidevops
```

Stub `gh`, `git`, and `complexity-scan-helper.sh` binaries are injected via `PATH` and `COMPLEXITY_SCAN_HELPER` — no network access required.

## Related

- `pulse-dispatch-core.sh` — `dispatch_with_dedup`, `_run_predispatch_validator`
- `pulse-simplification.sh` — `_complexity_scan_ratchet_check` (ratchet-down generator)
- `reference/worker-diagnostics.md` — full worker lifecycle and diagnostic reference
- GH#19118, GH#19024 (post-mortem), GH#19036, GH#19037
