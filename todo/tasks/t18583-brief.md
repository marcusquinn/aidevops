# t18583: Reusable Hostinger fleet onboarding and drift sync

Status: Backlog; brief only. No implementation issue, automatic dispatch, or
production deployment is authorized by saving this brief. A future execution
request is required.

## Goal and observed evidence

Turn a successfully completed 30-site onboarding into a reusable capability:
inventory the hosting account, map shared WordPress networks, provision private
repositories, initialize aidevops, and verify background readiness without
modifying production. The observed fleet comprised 25 hosting-panel entries,
30 distinct sites, and 17 shared WordPress codebases.

The one-off process required materially adapted inventory, initialization,
delivery, verification and completion-receipt scripts. It encountered legacy
feature opt-outs, missing remote default-branch references, inherited source
whitespace, owner transfers, and onboarding-document artifact restrictions.
Fleet verification ultimately passed 30/30. Keep customer identities, local
paths and credentials out of shared examples and public diagnostics.

## Reference patterns and candidate files

- `.agents/scripts/hostinger-helper.sh`: existing hosting command surface;
  evaluate authenticated API discovery versus its configured-site inventory.
- `.agents/scripts/aidevops-cli/aidevops-repos-lib.sh`: registry integration.
- `.agents/scripts/repo-layout-migrate-helper.sh` and
  `.agents/reference/repo-organization.md`: owner-aware canonical locations and
  reviewed, receipt-backed migrations; never improvise directory moves.
- `.agents/scripts/canonical-recovery-helper.sh`: audited mirror convergence.
- `.agents/scripts/headless-runtime-helper.sh`: worker runtime/canary checks.
- Existing native init, GitHub write, secret scanning and PHP lint interfaces:
  reuse their current supported contracts rather than duplicating them.
- New fleet-helper module and reference-document paths are not finalized;
  discover the current integration points before choosing them.

## Proposed behavior

1. Provide a non-mutating inventory/plan mode with explicit account, owner and
   site scope. Separate hosting-panel entries, WordPress networks, blogs and
   aliases. Associate shared code with its primary network repository.
2. Default organization clones to `~/Git/<owner>/<repo>` and personal clones to
   `~/Git/<repo>`, respecting explicit exceptions and collisions. Support a
   caller-specified personal-owner exception. Never include unrelated repos in
   an approved fleet transaction.
3. Use existing authenticated interfaces and secure credential storage. Do not
   emit credentials or copy production configuration, databases, uploads or
   backups. Optional custom-code imports need scanning and scoped syntax checks.
4. Reuse native initialization for planning, Git workflow and code quality.
   Check effective feature flags, not only requested-feature output or registry
   labels. Treat inherited source-formatting debt separately from authored
   onboarding metadata, without disabling relevant native gates.
5. Verify private visibility, intended remote ownership, permissions, canonical
   registration, default-branch heads, initialization, Pulse/maintenance flags,
   worker authentication and full-loop prerequisites. Distinguish configured
   readiness from actual successful worker runs.
6. Support resumable, per-site receipts and explicit partial/failure results.
   Validate GitHub targets before writes; handle existing repos, transfers,
   drafts and pending versus terminal CI states without blind retries or merges.
7. Offer read-only drift checks for new, missing, moved or misregistered sites.
   Require explicit execution authority for repairs. Do not create a recurring
   schedule, dispatch implementation, or deploy merely because a brief exists.

## Verification and acceptance

- Exercise native inventory/plan and supported CLI paths on an authorized,
  explicitly scoped account; verify repeat runs make no unnecessary changes.
- Reconcile counts and per-site receipts against live hosting/GitHub facts.
- Include shared-network children, an existing repo, an owner exception, a
  destination collision, disabled effective features and interrupted delivery
  when they are available through existing fixtures or operational checks.
- Inspect effective configuration, Git capture state, mirror heads, registry
  values and scheduler health. Canary success alone is not fleet job success.
- A partial fleet cannot produce an all-ready receipt or close failed audit
  issues. No production mutation or accidental publication is acceptable.
- Run existing scoped lint/type/syntax checks for touched files. Add focused
  coverage only when needed to resolve material uncertainty; do not introduce
  new runners, mocks, test-only interfaces or CI gates by default.
