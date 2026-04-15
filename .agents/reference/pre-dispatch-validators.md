# Pre-Dispatch Validators

Pre-dispatch validators run **after** dedup checks and **before** worker spawn for auto-generated issues. They verify the issue premise is still true — catching stale issues deterministically instead of relying on model self-triage. Fix 3 of the GH#19024 post-mortem; GH#19036 and GH#19037 address the ratchet-down bug at source; this adds a generalisable safety net for the "premise stale at dispatch time" failure class.

## Architecture

Auto-generated issues embed a hidden HTML comment marker extracted with `grep -oE '<!-- aidevops:generator=[a-z-]+ -->'`. Parsing titles or labels is rejected as brittle — markers survive editorial changes to human-visible fields.

```html
<!-- aidevops:generator=<name> -->
```

`pre-dispatch-validator-helper.sh` maintains `_VALIDATOR_REGISTRY` mapping generator names to validator functions, populated by `_register_validators()`. Unregistered generators fall through to exit 0 (dispatch proceeds).

### Exit-code contract

| Code | Meaning | Action |
|------|---------|--------|
| `0`  | Dispatch proceeds — premise holds or no validator registered | Worker spawned normally |
| `10` | Premise falsified — issue is stale | Helper posts rationale comment + closes issue as `not planned`; no worker spawned |
| `20` | Validator error — unexpected failure | Warning logged; dispatch proceeds (never block on validator bugs) |

### Hook point

Runs inside `dispatch_with_dedup()` in `pulse-dispatch-core.sh` via `_run_predispatch_validator()`:

```
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

Emergency recovery when a validator bug is blocking legitimate dispatches. The bypass is logged. Do not leave it set permanently.

## Closure comment format

When a validator returns exit 10, the helper posts:

```
> Premise falsified. Pre-dispatch validator for generator `<name>` determined
> the issue premise is no longer true. The `<name>` check reports no actionable
> work is available. Not dispatching a worker.

The issue was closed automatically by the pre-dispatch validator (GH#19118).
If conditions change … a new issue will be created by the next pulse cycle.

---
[signature footer]
```

Issue closed with `gh issue close --reason "not planned"`.

## Registered validators

### `ratchet-down`

**Generator:** `_complexity_scan_ratchet_check` in `pulse-simplification.sh`  
**Marker:** `<!-- aidevops:generator=ratchet-down -->`

**Logic:**

1. Clone target repo to scratch dir (`mktemp -d`, cleaned via `trap`)
2. Run `complexity-scan-helper.sh ratchet-check <clone> 5`
3. Output contains `No ratchet-down available` → exit 10 (premise falsified)
4. Error with empty output → exit 20 (validator error)
5. Otherwise → exit 0 (proposals available, dispatch)

**Why:** The ratchet-down scan is computed at issue creation. By dispatch time, prior simplification work may have closed the gap — exactly the failure mode in the GH#19024 post-mortem. Without this validator, a worker discovers no ratchet-down is possible and exits silently.

## How to add a new validator

1. **Define the generator function** in `pulse-simplification.sh` or whichever script creates auto-generated issues for your generator type.

2. **Emit the marker** in the issue body template:
   ```bash
   "...issue content...\n\n<!-- aidevops:generator=my-generator -->"
   ```

3. **Implement the validator function** in `pre-dispatch-validator-helper.sh`:
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

5. **Add a test case** in `tests/test-pre-dispatch-validator.sh` covering the falsified and legitimate paths.

6. **Verify:** `shellcheck .agents/scripts/pre-dispatch-validator-helper.sh`

## Testing

```bash
# Run the test harness
bash .agents/scripts/tests/test-pre-dispatch-validator.sh

# Manual smoke test (requires gh auth)
.agents/scripts/pre-dispatch-validator-helper.sh validate <issue-number> marcusquinn/aidevops
```

The test harness uses stub `gh`, `git`, and `complexity-scan-helper.sh` binaries injected via `PATH` and `COMPLEXITY_SCAN_HELPER` env var — no network access required.

## Related

- `pulse-dispatch-core.sh` — `dispatch_with_dedup`, `_run_predispatch_validator`
- `pulse-simplification.sh` — `_complexity_scan_ratchet_check` (ratchet-down generator)
- `reference/worker-diagnostics.md` — full worker lifecycle and diagnostic reference
- GH#19118, GH#19024 (post-mortem), GH#19036, GH#19037
