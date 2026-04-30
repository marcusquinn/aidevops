# Auto-Merge Reference

Full detail for the two pulse auto-merge gates. For the one-line summary, see `AGENTS.md` "Auto-Dispatch and Completion".

## t2411 — `origin:interactive` Auto-Merge

`pulse-merge.sh` automatically merges `origin:interactive` PRs from `OWNER`/`MEMBER` authors once ALL criteria hold:

1. PR carries the `origin:interactive` label.
2. PR author has `admin` or `maintain` permission on the repo (OWNER or org MEMBER — write-only COLLABORATORs go through the normal review gate instead).
3. All required status checks PASS or SKIPPED.
4. No `CHANGES_REQUESTED` review from a human reviewer.
5. PR is **not a draft** — convert to ready (`gh pr ready <PR>`) before the pulse picks it up.
6. PR does **not** carry the `hold-for-review` label.

Merge typically happens within one pulse cycle (4-10 minutes) after all checks go green. Review bots (gemini-code-assist, coderabbitai) post within ~1-3 minutes. Audit log line: `[pulse-merge] auto-merged origin:interactive PR #N (author=<login>, role=<role>)`.

**To opt out of auto-merge on a specific PR:** apply the `hold-for-review` label. Remove it when ready.

**Folding bot nits into the same PR — options:**
- `review-bot-gate-helper.sh check <PR>` before pushing — streams current bot feedback.
- `gh pr create --draft`, wait for reviews to settle, `gh pr ready <PR>` when content is final.
- Accept the window and file a follow-up PR for nits.

**Note:** "pulse never auto-closes `origin:interactive` PRs" applies to AUTO-CLOSE (abandoning stale incremental PRs on the same task ID), NOT to auto-merge of green PRs. These are separate pulse actions.

## t2449 — `origin:worker` (Worker-Briefed) Auto-Merge

`pulse-merge.sh` also auto-merges `origin:worker` PRs when the underlying issue was **maintainer-briefed** (filed by `OWNER`/`MEMBER`) OR authored by a **trusted peer runner** in the allowlist (t3062) OR **cryptographically approved** by a maintainer (`sudo aidevops approve issue N`). Trust chain is equivalent to interactive: maintainer brief (or explicit vouching) + worker implementation + CI verification + no human objection.

ALL criteria must hold:

1. PR carries the `origin:worker` label.
2. Linked issue (via `Resolves #NNN` / `Closes #NNN` / `Fixes #NNN`) was authored by a user with `OWNER` or `MEMBER` association — **OR** the issue author's GitHub login is listed in `.agents/configs/trusted-issue-authors.conf` (t3062: peer runners trusted as operators, not external contributors) — **OR** the linked issue has a cryptographic approval signature (`aidevops:approval-signature:` in a comment body), proving a maintainer has personally vouched for the work with their SSH key (t3052).
3. Linked issue never carried `needs-maintainer-review` OR NMR was cleared via **cryptographic** approval (`sudo aidevops approve issue N`), not via `auto_approve_maintainer_issues`.
4. All required status checks PASS or SKIPPED.
5. No `CHANGES_REQUESTED` review from any reviewer with non-bot association.
6. PR is **not a draft**.
7. PR does **not** carry the `hold-for-review` label.
8. PR passes `review-bot-gate` (bots settled beyond `min_edit_lag_seconds`).
9. PR does **not** carry `origin:worker-takeover` (takeover PRs follow normal review flow).

Feature flag: `AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE` (default `1`=on). Set to `0` to fall back to manual-merge-only for `origin:worker` PRs.

Audit log: `[pulse-merge] auto-merged origin:worker (worker-briefed) PR #N (author=<login>, linked_issue=#M)`.

Test coverage: `.agents/scripts/tests/test-pulse-merge-worker-briefed.sh` (15 cases: a–o).

### Trusted-Issue-Author Allowlist (t3062, Criterion 2 extension)

The allowlist allows peer runners (separate machine/account, `COLLABORATOR` association) to file issues that workers can then auto-merge without per-issue crypto ceremony.

**Config file:** `.agents/configs/trusted-issue-authors.conf` — one GitHub login per line; `#` comments and blank lines ignored. Deployed copy: `~/.aidevops/agents/configs/trusted-issue-authors.conf`. Override path: `AIDEVOPS_TRUSTED_AUTHORS_CONF` env var.

**What the allowlist bypasses:** the `OWNER`/`MEMBER` `author_association` check only. Everything else still applies: the NMR crypto-vs-auto gate (criterion 3), the feature flag, draft/hold-for-review/CHANGES_REQUESTED gates, and CI checks.

**What it does NOT bypass:** A trusted-author issue that received `needs-maintainer-review` and was auto-approved (not crypto-cleared) still blocks — the closed-loop prevention from t2449 criterion 3 is independent of criterion 2.

**Security posture:** Allowlist entries are local-trust grants from the maintainer of the runner machine. A rogue allowlist entry cannot bypass CI or NMR-crypto gates; it only relaxes the GitHub author_association check which is itself a proxy for maintainer trust.

### Security Gate: NMR Crypto-vs-Auto Distinction (Criterion 3)

`auto_approve_maintainer_issues` runs as the pulse's own GitHub token — if auto-approval were accepted as NMR clearance, any review-scanner issue could auto-spawn a worker AND auto-merge without human touch (closed loop).

Cryptographic approval (`sudo aidevops approve issue N`) requires the maintainer's root-protected SSH key, which workers cannot access — this is the only reliable human-in-the-loop signal.

### Author-Association Gate Crypto Bypass (t3063)

Symmetric extension of t3052 to the **deterministic merge cascade** — the `_check_pr_merge_gates` collaborator check and the `approve_collaborator_pr` function in `pulse-merge-gates.sh`.

**Background:** t3052 (PR #21767) allowed cryptographic maintainer approval on a linked issue to satisfy the `OWNER`/`MEMBER` author-association gate in the worker-briefed auto-merge path. t3063 extends the same signal to:

1. **`_check_pr_merge_gates`** (`pulse-merge.sh:185-196`) — the gate that short-circuits the merge pass for all non-collaborator PRs. With t3063, a verified crypto signature on the PR or its linked issue (checked by `_has_maintainer_crypto_approval` in `pulse-merge-gates.sh`) allows the PR to proceed through the gate instead of being skipped.
2. **`approve_collaborator_pr`** (`pulse-merge-gates.sh`) — the function that posts the approval review before merge. With t3063, it accepts the same crypto signal as a bypass for the GH#17671 author guard before refusing to approve.

**Trust chain:** `sudo aidevops approve` requires a root-owned SSH private key that workers cannot forge. The signal is stronger than GitHub author-association, which is a proxy for maintainer trust. The four-layer GH#17671 defence-in-depth is preserved — Case P (CONTRIBUTOR + no crypto = refuse) is pinned by `test-pulse-merge-approve-collaborator-guard.sh`.

**Helper:** `_has_maintainer_crypto_approval "$pr_number" "$repo_slug"` in `pulse-merge-gates.sh`. Checks PR-level comments first, then linked-issue comments, for `<!-- aidevops-signed-approval -->`. Falls back to marker-presence check when `approval-helper.sh` is unavailable (full crypto verification provided by `_external_pr_linked_issue_crypto_approved` downstream).

**Test coverage:** `.agents/scripts/tests/test-pulse-merge-approve-collaborator-guard.sh` cases N, O, P.

## NMR Automation Signatures (t2386, Split Semantics)

The pulse runs as the maintainer's GitHub token, so `needs-maintainer-review` label events always record the maintainer as actor. `auto_approve_maintainer_issues` in `pulse-nmr-approval.sh` distinguishes three cases by comment markers:

- **Creation-default** (`source:review-scanner` comment marker, or `review-followup` / `source:review-scanner` label on issue) → scanner applied NMR by default at creation time; auto-approval CLEARS NMR so the issue can dispatch.
- **Circuit-breaker trip** (`stale-recovery-tick:escalated`, `cost-circuit-breaker:fired`, `circuit-breaker-escalated` comment markers) → t2007/t2008 safety mechanism fired after retry/cost limit exceeded; auto-approval PRESERVES NMR. Clear with `sudo aidevops approve issue <N>` once the underlying problem is fixed.
- **Manual hold** (no markers) → genuine maintainer decision to pause the issue; auto-approval PRESERVES NMR.

**Background — why the split matters:** Pre-t2386, both automation cases were conflated. The result was the GH#19756 infinite loop: stale-recovery applied NMR → auto-approve stripped it → worker re-dispatched → crashed → stale-recovery re-applied NMR. 22 watchdog kills + 5 auto-approve cycles in one afternoon. The split prevents this by preserving NMR on circuit-breaker trips.

Two helpers enforce the split: `_nmr_application_has_automation_signature` (creation defaults only) and `_nmr_application_is_circuit_breaker_trip` (breaker trips only). Regression test: `.agents/scripts/tests/test-pulse-nmr-automation-signature.sh::test_19756_loop_prevention_breaker_trip_preserves_nmr`.

## t3068 — Approval-Triggered Pulse Kick

**Problem:** before t3068, `sudo aidevops approve issue|pr <N>` posted a verified signature comment but the pulse-merge cycle was up to ~120s away. The maintainer had no feedback that the approval had landed in the merge queue, and ~2 min × N stuck PRs added up across an interactive cleanup session.

**Fix:** every successful `_approve_target` call now triggers the pulse via two independent layers in `approval-helper.sh::_kick_pulse_after_approval`:

1. **Marker file** at `~/.aidevops/cache/pulse-merge-trigger.txt` — append a tab-separated record `<slug>\t<num>\t<type>\t<iso8601_ts>`. Crash-safe and idempotent: even if the pulse process is dead, the marker survives until the next cycle drains it.
2. **Background spawn** of `pulse-wrapper.sh --merge-only` — best-effort, nohup + disown. Sub-second latency in the common case (60s `--merge-only` plist NOT already running).

**Drain side** — `pulse-wrapper-bootstrap.sh::_drain_merge_trigger_file_if_present`:

- Atomically rotates the marker (mv to `.processing.$$`) before parsing — no double-processing on concurrent drains.
- For each record: validates slug/num/type, resolves issue records to the linked open PR via `_resolve_linked_pr_for_issue`, and dispatches to the existing `process_pr "$slug" "$pr_num"` from pulse-merge.sh (same path as the t3038 webhook receiver).
- Malformed records logged and skipped — never aborts the drain.
- Wired in TWO places: at the top of every regular pulse cycle (`pulse-wrapper.sh::main()` before `_run_preflight_stages`) AND at the top of `_pulse_run_merge_only` for the dedicated 60s merge-only plist.

**Latency profile:**

| Approval scenario | Old latency (pre-t3068) | New latency (post-t3068) |
|-------------------|--------------------------|---------------------------|
| Approve, pulse idle | up to 120s | < 5s (background spawn fires) |
| Approve, --merge-only mid-cycle | up to 120s | up to 60s (marker drains on next merge-only tick) |
| Approve, full cycle running | up to 120s | up to 60s (next merge-only tick) |
| Approve, pulse dead | next pulse boot | next pulse boot (marker survives, drained on first cycle) |

**Bypass:**

- `AIDEVOPS_SKIP_APPROVE_KICK_PULSE=1` — disable both layers (used in CI / hermetic tests).
- `AIDEVOPS_SKIP_TRIGGER_DRAIN=1` — disable the drain (test-only knob to verify no-spawn path).

**Test coverage:** `.agents/scripts/tests/test-approve-kicks-pulse.sh` (21 assertions across 7 cases — marker shape, drain happy path, malformed-record skip, missing-marker no-op, bypass flag, atomic rotation, issue→PR resolution).

**Audit log:** every drain emits `[ts] _drain_merge_trigger_file_if_present: process_pr <slug> #<pr> (from approve <type> #<num>)` and a summary `drained N record(s), M non-merge outcomes`.

## t3070 — Native Auto-Merge Fast-Track

**Trigger:** every PR that reaches the merge call site in `_process_single_ready_pr` after passing all gates (review, maintainer, scope, review-bot-gate, complexity, admin safety check).

**What it does:** instead of unconditionally calling `gh pr merge --squash --admin` against pending CI, the pulse asks GitHub to merge the PR as soon as the last required check turns green via `gh pr merge --auto --squash`. GitHub then schedules the merge server-side and fires it within seconds of CI green — no further pulse-cycle wait required.

**Decision tree** (`_set_native_auto_merge_or_skip` in `pulse-merge-process.sh`):

| Condition | Action | Caller behaviour |
|-----------|--------|------------------|
| PR already has `autoMergeRequest` set | No-op | Caller returns success — GitHub finishes the merge |
| Repo `allow_auto_merge=false` | Fall through | Caller invokes `gh pr merge --squash --admin` |
| All required checks already done (no `pending` bucket) | Fall through | Caller invokes `gh pr merge --squash --admin` (immediate is faster than round-tripping through GitHub's auto-merge engine) |
| At least one required check pending | `gh pr merge --auto --squash` | Caller returns success — GitHub merges on green |
| `gh pr merge --auto` exits non-zero | Fall through with audit log | Caller invokes `gh pr merge --squash --admin` |

**Repo prerequisite:** `allow_auto_merge=true` on the repo. Bulk-enable across all owned repos:

```bash
jq -r '.initialized_repos[] | select(.local_only != true) | .slug' \
    ~/.config/aidevops/repos.json | while read -r slug; do
  gh api -X PATCH "repos/${slug}" -f allow_auto_merge=true >/dev/null \
    && printf 'enabled %s\n' "$slug"
done
```

**Latency improvement:** baseline measurement on owner/peer green PR push→merged was 3-22 min — dominated by the 120s polling cycle plus per-cycle gate evaluation. With native auto-merge, GitHub fires the merge within ~5-30s of the last required check finishing, regardless of when the next pulse cycle would have polled.

**Trade-offs:**

- **No `--admin` bypass on the auto-scheduled merge.** Native auto-merge respects branch protection. If the repo has required checks that ultimately fail, GitHub will hold the PR indefinitely instead of merging — exactly the safety property branch protection exists to provide. The pulse still falls back to `--admin` for repos that opted out (`allow_auto_merge=false`), preserving the historical bypass-pending behaviour for those repos.
- **No `_handle_post_merge_actions` invocation on the native-auto path.** The "Merged via PR #N" comment with `merge_summary` is NOT posted on the linked issue when GitHub completes the merge later. GitHub's `Resolves #NNN` keyword still auto-closes the issue — only the structured closing comment is lost. Acceptable for the speedup; users who need the comment can apply `hold-for-review` to opt out.

**Audit log:** `[pulse-merge] PR #N in slug: native auto-merge set (CI K pending), GitHub merges on green (t3070)`.

**Caching:** `_repo_allows_auto_merge` caches the per-repo `allow_auto_merge` flag in a tempdir keyed on PID for the lifetime of the pulse cycle. Avoids repeated `gh api repos/<slug>` calls when iterating multiple PRs from the same repo.

**Test coverage:** `.agents/scripts/tests/test-pulse-merge-native-auto.sh` (4 cases — pending/green/already-set/repo-disallows).

**Bypass:** apply `hold-for-review` to opt out of all auto-merge paths (this gate is upstream of t3070 — a held PR never reaches the native-auto call site). For per-repo opt-out, set `allow_auto_merge=false` via `gh api -X PATCH repos/<slug> -f allow_auto_merge=false`.

## Webhook-Driven Auto-Merge (t3038)

The 120s `pulse-merge-routine.sh` polling loop is the **backstop**. The fast path is a webhook receiver that fires `pulse-merge.sh::process_pr` within seconds of a GitHub event:

- `check_suite.completed` (conclusion=success) — CI just went green.
- `pull_request_review.submitted` (state in {APPROVED, CHANGES_REQUESTED}) — last reviewer settled.
- `pull_request.labeled` for `auto-dispatch`, `coderabbit-nits-ok`, `ai-approved` — gate flipped.

End-to-end latency drops from ~4-12 min (cycle wait + auto-merge gate window) to ~30s — a 4-6x speedup that translates directly into faster slot recycling for the worker pool.

**Architecture (defense-in-depth):**

| Path | Trigger | Latency | Reliability |
|------|---------|---------|-------------|
| Webhook | GitHub event | ~5-30s | Optimization — needs receiver up + tunnel up |
| Polling routine (`pulse-merge-routine.sh`) | 120s launchd interval | ≤120s + cycle | Always on, no external dependencies |
| In-cycle merge pass (`pulse-wrapper.sh`) | 5-10 min pulse cycle | Slow, kept as final defense | Always on |

If the webhook receiver crashes or the tunnel breaks, eligible PRs still merge on the next 120s polling cycle. There is no single point of failure that can wedge the merge pipeline.

### Setup

1. **Generate the webhook secret** (≥32 random bytes, hex):

   ```bash
   openssl rand -hex 32 | aidevops secret set GITHUB_WEBHOOK_SECRET
   # Or if not using gopass:
   #   echo "export GITHUB_WEBHOOK_SECRET='<hex-secret>'" >> ~/.config/aidevops/credentials.sh
   #   chmod 600 ~/.config/aidevops/credentials.sh
   ```

2. **Validate config + secret** before starting:

   ```bash
   pulse-merge-webhook-receiver.sh --check
   ```

3. **Expose the receiver via Cloudflare Tunnel** (canonical exposure path; the receiver binds to `127.0.0.1:9301` only and never speaks plaintext HTTP to the public internet):

   ```bash
   cloudflared tunnel create aidevops-webhook
   # Edit ~/.cloudflared/config.yml:
   #   tunnel: <tunnel-id>
   #   credentials-file: ~/.cloudflared/<tunnel-id>.json
   #   ingress:
   #     - hostname: hooks.example.com
   #       service: http://127.0.0.1:9301
   #     - service: http_status:404
   cloudflared tunnel route dns aidevops-webhook hooks.example.com
   cloudflared tunnel run aidevops-webhook
   ```

4. **Install the launchd service** (macOS — for Linux, install as a systemd user service following the same ProgramArguments):

   ```bash
   sed -e "s|{{HOME}}|$HOME|g" \
       -e "s|{{BASH_BIN}}|$(command -v bash)|g" \
       -e "s|{{AIDEVOPS_AGENTS_SCRIPTS}}|$HOME/.aidevops/agents/scripts|g" \
       ~/.aidevops/agents/templates/launchd/sh.aidevops.merge-webhook-receiver.plist.tmpl \
     > ~/Library/LaunchAgents/sh.aidevops.merge-webhook-receiver.plist
   launchctl load ~/Library/LaunchAgents/sh.aidevops.merge-webhook-receiver.plist
   ```

5. **Configure each repo webhook** (Settings → Webhooks → Add webhook):
   - Payload URL: `https://hooks.example.com/webhook`
   - Content type: `application/json`
   - Secret: the same hex value stored in `GITHUB_WEBHOOK_SECRET`
   - Events: tick **Check suites**, **Pull request reviews**, **Pull requests** (or **Send me everything** — non-handled events return `204 No Content`).

### Configuration

`.agents/configs/webhook-receiver.conf` controls listen address, max body size, handled-event allowlist, and log path. The secret itself is **never** in the conf file — only the env var name (`WEBHOOK_SECRET_ENV`).

### Verification

- `pulse-merge-webhook-receiver.sh --check` — validates secret + python3 availability without starting the listener.
- `curl -X POST -H 'X-Hub-Signature-256: sha256=bad' http://127.0.0.1:9301/webhook -d '{}'` — must return 401 (HMAC rejection).
- `curl http://127.0.0.1:9301/health` — must return 200 OK.
- Send a synthesized `check_suite.completed` payload for a known-mergeable PR with a valid signature → `pulse-merge-webhook.log` shows `accepted check_suite → owner/repo#NNN` and `pulse.log` shows `[pulse-merge] process_pr: webhook-triggered merge attempt …`.
- Stop the receiver (`launchctl unload …`) and confirm the next 120s `pulse-merge-routine.sh` cycle still merges eligible PRs — that proves the backstop is live.
