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

`pulse-merge.sh` also auto-merges `origin:worker` PRs when the underlying issue was **maintainer-briefed** (filed by `OWNER`/`MEMBER`). Trust chain is equivalent to interactive: maintainer brief + worker implementation + CI verification + no human objection.

ALL criteria must hold:

1. PR carries the `origin:worker` label.
2. Linked issue (via `Resolves #NNN` / `Closes #NNN` / `Fixes #NNN`) was authored by a user with `OWNER` or `MEMBER` association.
3. Linked issue never carried `needs-maintainer-review` OR NMR was cleared via **cryptographic** approval (`sudo aidevops approve issue N`), not via `auto_approve_maintainer_issues`.
4. All required status checks PASS or SKIPPED.
5. No `CHANGES_REQUESTED` review from any reviewer with non-bot association.
6. PR is **not a draft**.
7. PR does **not** carry the `hold-for-review` label.
8. PR passes `review-bot-gate` (bots settled beyond `min_edit_lag_seconds`).
9. PR does **not** carry `origin:worker-takeover` (takeover PRs follow normal review flow).

Feature flag: `AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE` (default `1`=on). Set to `0` to fall back to manual-merge-only for `origin:worker` PRs.

Audit log: `[pulse-merge] auto-merged origin:worker (worker-briefed) PR #N (author=<login>, linked_issue=#M)`.

Test coverage: `.agents/scripts/tests/test-pulse-merge-worker-briefed.sh` (10 cases).

### Security Gate: NMR Crypto-vs-Auto Distinction (Criterion 3)

`auto_approve_maintainer_issues` runs as the pulse's own GitHub token — if auto-approval were accepted as NMR clearance, any review-scanner issue could auto-spawn a worker AND auto-merge without human touch (closed loop).

Cryptographic approval (`sudo aidevops approve issue N`) requires the maintainer's root-protected SSH key, which workers cannot access — this is the only reliable human-in-the-loop signal.

## NMR Automation Signatures (t2386, Split Semantics)

The pulse runs as the maintainer's GitHub token, so `needs-maintainer-review` label events always record the maintainer as actor. `auto_approve_maintainer_issues` in `pulse-nmr-approval.sh` distinguishes three cases by comment markers:

- **Creation-default** (`source:review-scanner` comment marker, or `review-followup` / `source:review-scanner` label on issue) → scanner applied NMR by default at creation time; auto-approval CLEARS NMR so the issue can dispatch.
- **Circuit-breaker trip** (`stale-recovery-tick:escalated`, `cost-circuit-breaker:fired`, `circuit-breaker-escalated` comment markers) → t2007/t2008 safety mechanism fired after retry/cost limit exceeded; auto-approval PRESERVES NMR. Clear with `sudo aidevops approve issue <N>` once the underlying problem is fixed.
- **Manual hold** (no markers) → genuine maintainer decision to pause the issue; auto-approval PRESERVES NMR.

**Background — why the split matters:** Pre-t2386, both automation cases were conflated. The result was the GH#19756 infinite loop: stale-recovery applied NMR → auto-approve stripped it → worker re-dispatched → crashed → stale-recovery re-applied NMR. 22 watchdog kills + 5 auto-approve cycles in one afternoon. The split prevents this by preserving NMR on circuit-breaker trips.

Two helpers enforce the split: `_nmr_application_has_automation_signature` (creation defaults only) and `_nmr_application_is_circuit_breaker_trip` (breaker trips only). Regression test: `.agents/scripts/tests/test-pulse-nmr-automation-signature.sh::test_19756_loop_prevention_breaker_trip_preserves_nmr`.

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
