# Pre-Dispatch Validators

Pre-dispatch validators run **after** dedup checks and **before** worker spawn for auto-generated issues. They verify the issue premise is still true before a worker is dispatched — catching stale auto-generated issues deterministically rather than relying on model self-triage.

This is Fix 3 of the [#19024 post-mortem](https://github.com/marcusquinn/aidevops/issues/19024). Fixes 1 and 2 (GH#19036, GH#19037) address the ratchet-down bug at its source; this adds a generalisable safety net for the whole class of "premise stale at dispatch time" failures.

## Architecture

### Generator identification

Auto-generated issues embed a hidden HTML comment marker in their body:

```
<!-- aidevops:generator=<name> -->
```

The validator extracts this marker with `grep -oE '<!-- aidevops:generator=[a-z-]+ -->'`. Parsing titles or labels is explicitly rejected as too brittle — markers are unambiguous and survive editorial changes to human-visible fields.

### Registry

`pre-dispatch-validator-helper.sh` maintains an internal registry (`_VALIDATOR_REGISTRY`) mapping generator names to validator functions. The registry is populated by `_register_validators()`. Unregistered generators fall through to exit 0 (dispatch proceeds).

### Exit-code contract

| Code | Meaning | Action |
|------|---------|--------|
| `0`  | Dispatch proceeds — premise holds or no validator registered | Worker is spawned normally |
| `10` | Premise falsified — the auto-generated issue is stale | Helper posts rationale comment + closes issue as `not planned`; no worker spawned |
| `20` | Validator error — unexpected failure during validation | Warning logged; dispatch proceeds (never block on validator bugs) |

### Hook point

The validator runs inside `dispatch_with_dedup()` in `pulse-dispatch-core.sh`, via `_run_predispatch_validator()`. Placement:

```
_dispatch_dedup_check_layers()   ← all dedup gates
_ensure_issue_body_has_brief()   ← t2063 freshness guard
_run_predispatch_validator()     ← GH#19118 ← HERE
_dispatch_launch_worker()        ← worker spawn
```

`_run_predispatch_validator()` is non-fatal: if `pre-dispatch-validator-helper.sh` is missing or returns an unexpected code, dispatch proceeds.

## Bypass mechanism

Set `AIDEVOPS_SKIP_PREDISPATCH_VALIDATOR=1` to skip all validators unconditionally:

```bash
AIDEVOPS_SKIP_PREDISPATCH_VALIDATOR=1 ./pulse-wrapper.sh
```

Intended use: emergency recovery when a validator has a bug that is blocking legitimate dispatches. The bypass is logged. Do not leave it set permanently — validators exist to prevent wasted worker sessions.

## Closure comment format

When a validator returns exit 10, the helper posts a comment of the form:

```
> Premise falsified. Pre-dispatch validator for generator `<name>` determined
> the issue premise is no longer true. The `<name>` check reports no actionable
> work is available. Not dispatching a worker.

The issue was closed automatically by the pre-dispatch validator (GH#19118).
If conditions change … a new issue will be created by the next pulse cycle.

---
[signature footer]
```

The issue is then closed with `gh issue close --reason "not planned"`.

## Registered validators

### `ratchet-down`

**Generator:** `_complexity_scan_ratchet_check` in `pulse-simplification.sh`

**Marker:** `<!-- aidevops:generator=ratchet-down -->`

**Logic:**

1. Clone the target repo into a scratch directory (`mktemp -d`, cleaned on exit via `trap`)
2. Run `complexity-scan-helper.sh ratchet-check <clone> 5`
3. If output contains `No ratchet-down available` → exit 10 (premise falsified)
4. Any other error with empty output → exit 20 (validator error)
5. Otherwise → exit 0 (proposals available, dispatch)

**Motivation:** The ratchet-down scan is computed at issue creation time. By dispatch time, simplification work may have already closed the gap. Without this validator, a worker is spawned, reads the complexity state, discovers no ratchet-down is possible, and exits silently — exactly the failure mode documented in the #19024 post-mortem.

## How to add a new validator

1. **Define the generator function** in `pulse-simplification.sh` or whichever script creates auto-generated issues for your generator type.

2. **Emit the marker** in the issue body template:
   ```bash
   # In the issue body string
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

4. **Register the validator** in `_register_validators()`:
   ```bash
   _VALIDATOR_REGISTRY["my-generator"]="_validator_my_generator"
   ```

5. **Add a test case** in `tests/test-pre-dispatch-validator.sh` covering at minimum the falsified and legitimate paths.

6. **Run shellcheck**: `shellcheck .agents/scripts/pre-dispatch-validator-helper.sh`

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
