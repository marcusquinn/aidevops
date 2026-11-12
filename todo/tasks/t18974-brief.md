<!-- aidevops:brief-schema=v2 -->

## Origin

- **Created:** 2026-11-12
- **Created by:** ai-interactive (requested by the maintainer)
- **Parent task:** none. Helper introduced by #37391 (t18924).
- **Blocked by:** none
- **Conversation context:** After `actions-event-policy-helper.sh apply --repo marcusquinn/cloudron-orbit-app` returned `APPLIED ... (POST)`, `status` still printed `UNCOVERED` for all three workflows. The policy itself is correct.

## What

Make `actions-event-policy-helper.sh status` (and `security-posture-helper-repo.sh`, which uses it) report coverage from each policy's full definition. A correctly applied policy must then report covered.

## Why

`_policy_read_policies` (`.agents/scripts/actions-event-policy-helper.sh:233-237`) reads only the list endpoint `repos/{slug}/actions/policies?has_parents=true`. The live list response omits `conditions` and `rules`:

```text
gh api -H "X-GitHub-Api-Version: 2026-03-10" "repos/marcusquinn/cloudron-orbit-app/actions/policies?has_parents=true"
→ {"total_count":1,"policies":[{"id":13288,"name":"aidevops-pull-request-target-gates","target":"actions","source_type":"Repository","enforcement":"active","_links":{"self":{"href":".../repos/marcusquinn/cloudron-orbit-app/actions/policies/13288"}},...}]}
gh api -H "X-GitHub-Api-Version: 2026-03-10" repos/marcusquinn/cloudron-orbit-app/actions/policies/13288 --jq '{conditions, rules}'
→ conditions.workflow_path.include = the three workflow paths; rules = [restrict_action_events with pull_request_target]
```

`_policy_uncovered_paths` (`:213-231`) therefore never finds a matching rule, so every repository reports `UNCOVERED` forever. The security posture check keeps warning, and nobody can verify a fix before GitHub's 2026-12-02 default block. The test fixtures (`.agents/scripts/tests/test-actions-event-policy-helper.sh:115,122,127,132`) embed `rules` in the list response, so the tests do not catch it.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** Single-function fix plus fixture changes; the API shapes are evidenced above. Standard rather than simple because org/enterprise parent policies need the same treatment.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/actions-event-policy-helper.sh:233-237` — after the list call, fetch each policy's detail from its `_links.self.href` (strip the `https://api.github.com/` prefix; this covers repository and parent `source_type`s) with the same API version header. Then emit `{"policies":[<details>]}` for `_policy_uncovered_paths`. Keep `apply`'s by-name lookup working (`:303`).
- `EDIT: .agents/scripts/tests/test-actions-event-policy-helper.sh` — make list fixtures summary-only (id, name, enforcement, `_links.self.href`) and add detail fixtures, so the test reproduces the live shape.
- `EDIT: .agents/reference/repo-onboarding.md` — remove the sentence saying `status` can report `UNCOVERED` after a successful apply.

### Complete Write Surface

- **Callers/readers:** `security-posture-helper-repo.sh` and `sync-workflows-helper.sh` call this helper's `status`; `status --all-managed` iterates the registry.
- **Writers/mutation paths:** `apply` POST/PUT is unchanged; this change only affects reads.
- **Existing verification/tests:** `.agents/scripts/tests/test-actions-event-policy-helper.sh`.
- **Schemas/config:** N/A because no config or registry fields change.
- **Generated/deployed mirrors:** deployed via `setup.sh`.
- **Migrations/backfills:** N/A because the fix is a read-path change with no stored state.
- **Cleanup/rollback paths:** N/A because reverting restores the previous read path with no residue.

### Implementation Steps

1. In `_policy_read_policies`, list, then for each `.policies[]._links.self.href` call `_policy_api_read` on the relative path, failing the whole read (return non-zero) if any detail read fails, so a partial read is never reported as covered or uncovered.
2. Assemble the details with `jq -s '{total_count: length, policies: .}'`.
3. Update fixtures and assertions; add a case where list-only data lacks rules but the detail covers the paths, expecting `COVERED`/exit 0.
4. Remove the caveat sentence from `reference/repo-onboarding.md`.

### Hazards and Compatibility

- **Concurrency/atomicity:** N/A because the change only reads.
- **Migration/rollback:** none.
- **Mixed-version/backward compatibility:** if a future API version includes rules in the list, detail reads still return the same objects.
- **Idempotency/retry:** reads only.
- **Partial failure/recovery:** any failed detail read returns exit 2 ("cannot read Actions policies"), never a coverage verdict.

### Complexity Impact

- **Target function:** `_policy_read_policies` in `.agents/scripts/actions-event-policy-helper.sh`
- **Current line count:** 5 lines (threshold: 100 lines for function-complexity)
- **Estimated growth:** +15 lines
- **Projected post-change:** 20 lines (20% of threshold)
- **Action required:** None.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-actions-event-policy-helper.sh
shellcheck .agents/scripts/actions-event-policy-helper.sh
```

- **Surface mapping:** the updated fixtures reproduce the live list/detail split. Tests prove covered, uncovered, a non-matching path and a detail-read failure (exit 2), and that apply's POST/PUT paths are unchanged. ShellCheck covers style.
- **Broad verification trigger:** Not required.

### Scope Boundaries

**Hard boundaries:** do not run `apply` on any repository; that stays an explicit maintainer action. Do not change the policy body `plan` produces.

**AI brief owner:** the maintainer's interactive session that filed this issue.

### Files Scope

- `.agents/scripts/actions-event-policy-helper.sh`
- `.agents/scripts/tests/test-actions-event-policy-helper.sh`
- `.agents/reference/repo-onboarding.md`

## Acceptance Criteria

- [ ] With a policy whose detail covers every `pull_request_target` workflow, `actions-event-policy-helper.sh status --repo <slug>` exits 0 even though the list response omits rules.
- [ ] A failed detail read exits 2 with "cannot read Actions policies".
- [ ] Regression guard: a policy that does not cover a path still reports that path `UNCOVERED`, and `apply`'s POST/PUT behaviour and existing tests are unchanged.

## Context & Decisions

- Following `_links.self.href` avoids guessing org or enterprise detail endpoints for parent policies returned by `has_parents=true`.
