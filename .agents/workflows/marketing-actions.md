<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Approval-Bound Local Marketing Actions

Use this workflow only for exact, reversible edits to version-controlled files in
an isolated linked worktree. It turns recommendations validated against
`.agents/configs/marketing-decision.schema.json` into a separate action proposal;
the decision report remains a non-mutating handoff and is never approval.

## Supported Surface

The executor supports one exact UTF-8 replacement per file for `title`,
`meta_description`, and `internal_link`. The plan binds the current bytes,
resulting bytes, exact diff, source evidence, owner, project/worktree identity,
action set, limits, and rollback method into `plan_digest`.

`noindex`, canonical, redirect, delete, budget, bid, negative-keyword, campaign,
pixel, conversion, moderation, and posting proposals are rendered as
`handoff_only` by this local executor; they cannot be applied here. Canonical checkouts, default branches,
symlinks, untracked files, CMS/ad accounts, generated deployments, commits,
pushes, publication, and account operations are always rejected or absent.
A narrow set of Google Ads account changes has its own adapter: see
[Google Ads Account Actions](#google-ads-account-actions).

```bash
python3 .agents/scripts/marketing-action-helper.py plan \
  --input .agents/scripts/tests/fixtures/marketing-decisions/actions-plan.json \
  --dry-run
```

## Operator Approval

Apply and rollback run only with a fresh operator approval record. The operator
creates it in their own terminal; agents and workers must never run this
(it needs sudo and an interactive TTY):

```bash
sudo aidevops approve marketing-plan /path/to/reviewed-plan.json
sudo aidevops approve marketing-plan --rollback /path/to/receipt.json
```

The ceremony (`marketing_action_approval.mint`) refuses unless it runs as root
with `SUDO_USER` set and an interactive stdin. It reads the plan or receipt
without following symlinks and only when the operator owns the file. It
recomputes the plan digest, then prints the authorised action set and every
ready action. Each action shows its before hash and the exact `old`/`new` text
that apply will execute, not the stored diff. It also lists the handoff-only
items. Control characters are escaped. A review over 400 lines is refused rather
than truncated. Then it requires a typed `APPROVE` and writes a v2
record (`aidevops.marketing-action-approval/v2`) to
`~/.aidevops/approval-keys/marketing-actions/{apply|rollback}-<digest>.json`.
That directory is root-owned and not group/other writable. The record binds:

- the operation
- the plan schema and digest
- the plan's schema-specific binding (for local plans: project root and worktree identity)
- the ordered action set and the OS owner
- issue and expiry times (at most 15 minutes apart)
- a nonce and the cancellation path
- for rollback, the exact receipt digest

`apply` and `rollback` accept only a regular, root-owned record in that
directory that matches exactly. A missing, user-owned, symlinked, stale,
wrong-operation, wrong-digest, wrong-binding or cancelled record fails closed
before any file changes. The v1 inherited-pipe variables
(`AIDEVOPS_MARKETING_APPROVAL_FD`) no longer grant anything. Same-user processes
cannot create root-owned files, which is what separates the operator from agents.

The ceremony also creates an operator-owned mode-0600 cancellation file
(`~/.aidevops/.agent-workspace/marketing-action-cancellations/<nonce>`, created
with dropped privileges) containing `active:<nonce>`. The executor checks it
immediately before each write. Overwrite it to cancel an in-flight approval.
Re-approving the same digest replaces the record with a new nonce.

Within the approval window, the operator or an agent may run:

```bash
python3 .agents/scripts/marketing-action-helper.py apply \
  --plan /path/to/reviewed-plan.json \
  --receipt-dir "$HOME/.aidevops/.agent-workspace/marketing-action-receipts"
python3 .agents/scripts/marketing-action-helper.py rollback \
  --receipt "$HOME/.aidevops/.agent-workspace/marketing-action-receipts/PLAN_DIGEST.json"
```

The paths above are placeholders, not authorization. Scheduled runs need a fresh
operator record per plan; nothing infers approval merely because the CLI exists.
Other plan schemas (for example, remote ad-account adapters) register their bound
fields in `PLAN_BINDINGS` in `.agents/scripts/marketing_action_approval.py`.

## Recovery and Rollback

Each operation takes a non-blocking worktree lock. Before a file write, a private
mode-0600 receipt records its exact before bytes and before/after hashes. After
the write, the checkpoint removes that action from `remaining_action_ids`.
A fresh exact approval can deterministically resume an interrupted `applying`
receipt when every touched file is still at its recorded before or after state.
An exact replay of a completed plan is a verified no-op.

Rollback requires a fresh operation-specific approval and verifies every current
file still equals this operation's after-state before restoring any file. A
single mismatch preserves all evidence and refuses the entire rollback, so
unrelated edits are never overwritten. Repeated rollback is a no-op. Recovery
never runs reset, clean, commit, push, publication, or remote/account commands.

## Google Ads Account Actions

`.agents/scripts/google-ads-action-helper.py` applies only these kinds, each with
an exact recorded inverse:

| Kind | Input fields | Inverse |
|------|--------------|---------|
| `campaign_negative_keyword` | `campaign_id`, `text`, `match_type` | remove the created criterion |
| `ad_group_negative_keyword` | `ad_group_id`, `text`, `match_type` | remove the created criterion |
| `keyword_status` | `ad_group_id`, `criterion_id`, `status` (`ENABLED`/`PAUSED`) | restore the previous status |
| `maximize_clicks` | `campaign_id`, `cpc_bid_ceiling_micros` | restore `MANUAL_CPC` (eCPC flag) or the previous ceiling |
| `campaign_budget` | `campaign_id`, `amount_micros` | restore the previous amount |

It refuses:

- portfolio bidding, any bidding other than `MANUAL_CPC` or `TARGET_SPEND`, and shared budgets
- duplicate negatives, no-op changes, and two actions on the same resource
- values over the config caps, and customers outside the allowlist

The operator writes the input (`aidevops.google-ads-action-input/v1`: `customer_id`,
optional `login_customer_id`, `owner`, `source_evidence`, `actions`). Triage output
from `google_ads_triage.py` stays a proposal. Use a per-project config
(`aidevops.google-ads-action-config/v1`) with `customer_allowlist`,
`max_daily_budget_micros`, `max_cpc_bid_ceiling_micros` and `max_operations`.

```bash
python3 .agents/scripts/google-ads-action-helper.py plan \
  --input actions.json --config google-ads-actions.json --output /path/to/new-plan.json
sudo aidevops approve marketing-plan /path/to/new-plan.json        # operator only
python3 .agents/scripts/google-ads-action-helper.py apply \
  --plan /path/to/new-plan.json \
  --receipt-dir "$HOME/.aidevops/.agent-workspace/google-ads-action-receipts"
sudo aidevops approve marketing-plan --rollback RECEIPT.json        # operator only
python3 .agents/scripts/google-ads-action-helper.py rollback --receipt RECEIPT.json
```

How each step works:

- `plan` reads the live state through fixed GAQL queries. It sends the exact
  operations as one `googleAds:mutate` with `validateOnly: true`, then
  exclusive-creates a mode-0600 plan. The plan records the operations, before
  and after states, inverses, caps, and a 24-hour expiry, all under `plan_digest`.
- `apply` re-checks the digest, expiry, allowlist and caps. It rebuilds every
  operation, inverse and after-state from the validated parameters and the
  recorded before-state, and refuses any stored payload that differs. It
  requires the root approval record (bound to `customer_id`) and takes a
  receipt-directory lock. It refuses drift, including a different live resource
  with an equal value (for example, a swapped budget). It writes an `applying`
  receipt and re-checks the approval and plan expiry. Then it sends one mutate
  with `partialFailure: false`, so every operation applies or none do. Finally
  it records the resource names and appends to `audit.jsonl`.
- Replaying an applied plan is a verified no-op that repairs a missing audit
  entry. After a crash, a plan whose live state equals the after-state is marked
  applied without a second write.
- `rollback` needs a fresh rollback approval bound to the receipt digest. Every
  live state must still equal its after-state, including the created criterion
  resource names. It validates the inverses (validate-only) and persists a
  `rolling_back` receipt. It then sends the inverses. If the response is lost,
  approve the `rolling_back` receipt and retry: when every live state already
  equals its before-state, the receipt is completed without another write.
  Repeating a rollback is a no-op.

Credentials come only from the environment. `GOOGLE_ADS_ACCESS_TOKEN` (an OAuth
access token with the `adwords` scope) is required. `GOOGLE_ADS_DEVELOPER_TOKEN`
is optional: Google's developer-token policy says tokens were sunset on
2026-09-09 and are ignored. The adapter uses the same API version as
`marketing_account_google.py`.

## Verification Boundary

Focused tests use synthetic linked worktrees, and they patch the trusted approver
UID and operator home so they can run without root. They prove the
local guard and recovery contract only; they do not establish ROI, authorize a
real proposal, or activate scheduled/live-site execution. Google Ads tests use an
in-memory fake account. Only a live validate-only `plan` against a test account
proves that Google accepts the payloads.
