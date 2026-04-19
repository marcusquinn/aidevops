# t2367: pre-dispatch validator: re-measure scanner-cited files before worker dispatch

## Session origin

Filed from the t2207 / PR #19821 session after observing `pulse-dispatch-core.sh` large-file simplification gate file issue #19822 **1m 49s after** PR #19821 merged — with a body asserting "current size verified by gate" when the cited file was already 949 lines on `main`. Root cause: the scanner did not re-measure the file against HEAD before filing/dispatching.

## What

Register scanner-filed file-size / complexity issues under the existing pre-dispatch validator infrastructure (GH#19118). On each dispatch attempt, re-run the scanner's measurement against the current HEAD. If the premise has been falsified (file is now under threshold, function is now under complexity limit, etc.), exit 10 and let the validator auto-close the issue with a premise-falsified comment — never spawn a worker against already-solved debt.

## Why

The race is structural: the scanner enumerates the repo, emits findings, and files issues. If a fix merges during that window, the resulting issue is a duplicate by the time it reaches the dispatch queue. Issue #19822 cost a full filing + scanner run + later (human) triage for a debt that had been resolved two minutes earlier. The same class applies to `function-complexity`, `nesting-depth`, `bash32-compat`, and any future scanner. Fixing this at the validator layer (one place) is far cheaper than teaching every worker to premise-check.

The infrastructure already exists (`pre-dispatch-validator-helper.sh`, GH#19118). What's missing is: (a) the scanners emit a generator marker, and (b) a validator registered for that marker runs the re-measurement.

## How

1. **Scanner emits a generator marker**

   - EDIT: `.agents/scripts/pulse-dispatch-large-file-gate.sh` around line 545-600 where the issue body is composed.
   - Add an HTML comment marker to the body:

     ```html
     <!-- aidevops:generator=large-file-simplification-gate cited_file=<path> threshold=2000 -->
     ```

   - Do the same for the sibling gates that file `function-complexity` and `nesting-depth` issues (check `.agents/scripts/pulse-dispatch-*.sh` and `.agents/scripts/*complexity*.sh`). One marker per generator class.

2. **Validator registers for the marker**

   - NEW: `.agents/scripts/validators/large-file-simplification-validator.sh` (or extend the existing validator file — model on whatever pattern `pre-dispatch-validator-helper.sh` already uses; see existing validators for the right file location).
   - Parse `cited_file` and `threshold` from the marker.
   - Run `wc -l "$cited_file"` (or the complexity equivalent) against current HEAD.
   - If measurement is below threshold → exit 10 (validator auto-closes with premise-falsified comment per GH#18538 Outcome A).
   - If still over → exit 0 (let dispatch proceed normally).

3. **Wire the validator**

   - EDIT: `.agents/scripts/pre-dispatch-validator-helper.sh` — add the new generator name to the validator routing table. Look at how other validators are registered (search for existing generator names in that file).

4. **Model this on:** the existing pre-dispatch validator for review-followup or contribution-watch generators (GH#19118 shipped those). Find one and copy the structure.

## Verification

- Stage a fake scanner-filed issue with the new marker, cite a file that is under threshold, dispatch. Expect: validator exits 10 → issue auto-closes with premise-falsified comment → no worker spawned.
- Stage a fake issue citing a file ACTUALLY over threshold. Expect: validator exits 0 → worker dispatches normally.
- Audit recent closed issues in the last 30 days — run `gh issue list --state closed --search "file-size-debt"` and verify the new marker appears on scanner-filed ones after this lands.

## Acceptance criteria

- [ ] All scanner-filed large-file / complexity issues carry a `<!-- aidevops:generator=... -->` marker
- [ ] `pre-dispatch-validator-helper.sh` routes to the new validator on that marker
- [ ] Validator re-measures the cited file against HEAD and exits 10 if premise is now false
- [ ] Auto-close comment includes the measurement evidence (format: "File X is now Y lines, threshold Z. Premise falsified. Not dispatching.")
- [ ] Unit test: `.agents/scripts/tests/test-pre-dispatch-validator-large-file.sh` covers both premise-true and premise-false cases
- [ ] Pulse log emits an INFO line when a premise-falsified auto-close fires, for observability

## Tier

`tier:standard` — concrete file targets, existing pattern to copy, clear acceptance criteria, multi-file but not cross-package.

## Related

- #19822 — canonical evidence of the bug (scanner filed duplicate 1m 49s after merge)
- #19699 — original simplification issue (resolved)
- #19821 — the PR whose merge the scanner missed
- GH#19118 — pre-dispatch validator infrastructure
- GH#18538 — worker triage responsibility (the three-outcome rule this automates for scanner-filed issues)
