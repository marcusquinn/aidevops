# t2204 — docs: warn about closing-keyword foot-gun + add attribution-before-verification rule

**Session origin:** interactive (marcusquinn, t2190 follow-up)
**Issue:** GH#19690

## What

Add two documentation bullets to the framework's prompt-level guidance:

1. **Traceability section in `.agents/prompts/build.txt`** — warn that the `_extract_linked_issue` regex in `pulse-merge.sh` is stringly-typed: markdown code spans, fences, blockquotes, HTML comments, and link text DO NOT shield closing keywords (`Closes`, `Resolves`, `Fixes` + `#NNN`) from being matched.

2. **New numbered rule 11 in `.agents/prompts/build.txt`** — attribution-before-verification: before publishing a comment/report blaming a specific task ID or bug for an incident, READ the cited function body. Symptom-pattern match ≠ root cause.

3. **Brief template `.agents/templates/brief-template.md`** — add the same markdown-doesn't-shield warning inline with the existing PR KEYWORD RULE comment block, so anyone drafting a brief sees it.

## Why

Two framework-level gaps were exposed during the t2190 session:

**Gap A (markdown foot-gun):** PR #19680 was a planning-only PR with correct `For #19678` in its body (per the existing rule). But its body also said "the fix PR will use a closing keyword" wrapped in backticks as reference text for what a future PR would do. The pulse-merge extraction regex doesn't parse markdown — it's a plain grep. It matched the literal string, extracted the issue number, and `_handle_post_merge_actions` auto-closed GH#19678 on merge.

**Gap B (attribution-before-verification):** after observing the auto-close, the session agent (me) published a public comment blaming t2108's known bug. t2108's fix had merged 3 days earlier (PR #19076) and was working correctly — the actual cause was the markdown foot-gun in my own PR body. I had pattern-matched at the symptom level without reading `_extract_linked_issue`'s function body. Published misattribution creates noise, misleads the next session, and requires a correction comment to retract.

Both failures apply to every future session — they're not one-off mistakes. Documenting them in the prompt harness prevents recurrence.

## How (Approach)

### Files to Modify

- EDIT: `.agents/prompts/build.txt` — insert one bullet in the "Traceability (MANDATORY)" section (after the "Code fix commit messages" bullet, before "Every dispatched task" bullet).
- EDIT: `.agents/prompts/build.txt` — insert new `# 11. Attribution before verification` section immediately after the existing `# 10. Stale-symptom investigations` section (before the `**Pre-edit rules:**` heading).
- EDIT: `.agents/templates/brief-template.md` — append a `MARKDOWN DOES NOT SHIELD KEYWORDS` paragraph inside the existing `<!-- PR KEYWORD RULE -->` HTML comment block, after the "Leaf (non-parent) issue PRs" sentence.

### Reference patterns

- Bullet style: follow the existing bullet patterns in the Traceability section (markdown bold for lead, task ID reference in parens, concrete example).
- New-section style: follow the existing `# 10. Stale-symptom investigations` section structure — `# NN. Title (t<NNN> — MANDATORY ...)` heading, `#` prefixed explanation block, `-` bullets with concrete guidance, Related: pointer at the end.
- Template-comment style: keep the existing HTML comment block, add a new paragraph in the same voice.

### Verification

- `markdownlint-cli2 .agents/templates/brief-template.md` — no new violations.
- Manual re-read of both edits to confirm they scan correctly and the examples themselves don't contain the foot-gun (placeholder `NNN` instead of real digit sequences, `Closes-hash-NNN` hyphenated, etc.).
- Self-test: grep the diff for `(close[ds]?|fix(es|ed)?|resolve[ds]?)\s+#[0-9]+` — should find ONLY the regex itself as a literal inside the prose, never as an accidental close directive.

## Acceptance

- [ ] `.agents/prompts/build.txt` "Traceability" section contains a markdown-doesn't-shield bullet referencing t2204.
- [ ] `.agents/prompts/build.txt` has a new `# 11. Attribution before verification` section after section 10.
- [ ] `.agents/templates/brief-template.md` PR KEYWORD RULE block mentions t2204 and the markdown foot-gun.
- [ ] PR body uses the standard leaf-task closing-keyword pattern pointing at GH#19690 (not a parent-task issue, so `For`/`Ref` are wrong), and does NOT accidentally match the closing-keyword regex against any other issue number.
- [ ] No `.sh` / no `.mjs` / no `.py` changes (docs-only).

## Out of Scope

- Changing `_extract_linked_issue` to strip markdown code spans before regex (behavioural change, separate task).
- Adding a pre-push / CI check that warns on closing keywords in code spans (possible follow-up).
- Retroactively editing the existing t2108/t2046/t2099 doc to cross-link the new rule (can be done later if noise is observed).

## Tier

`tier:simple` — three targeted documentation edits with exact file/location references, no code changes, well under 1h estimate. 3 acceptance criteria (trivial enumeration), no judgment keywords in the actual edits.
