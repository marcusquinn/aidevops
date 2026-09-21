# Public engagement policy

Public engagement is **disabled by default**. Existing exact owner approval remains the normal outbound path. The optional policy lane supports only Reddit text posts and replies through the existing private outbox and identity-checked provider adapter.

## Authority boundary

- Only the prospecting service's owner session plus CSRF/origin checks may create, revise, or revoke a grant. Read keys, collectors, MCP tools, routine configuration, model decisions, filesystem identity, and `engagement.execute` credentials cannot administer grants.
- Executor credentials can request a content-free eligibility reference. The private social outbox independently validates the immutable intent, exact grant revision/hash, project/corpus, account, community, action, disclosure, evidence freshness, suppression state, and budget.
- A policy authorization is recorded as `delegated_policy`, never as owner review. It does not create an `outbound_approvals` row.

## Caps and races

Reservations are created in the same `BEGIN IMMEDIATE` transaction as the fenced claim. Account and community caps aggregate across overlapping grants and projects. Thread cooldown and turn limits also count reservations. Authorization is rechecked immediately before `provider_started_at` is persisted.

Revocation, expiry, suppression, or a paused grant blocks unstarted work. A request already marked provider-started may complete remotely and cannot be unsent. Unknown outcomes retain their reservation and must be reconciled from provider evidence; never clone an operation ID or blindly resend.

## Privacy and migration

Grant JSON, authorizations, suppressions, and reservations live only in private social-store tables. Shared corpus exports and normal logs expose content-free IDs, hashes, revisions, and states only. The additive table initializer does not promote legacy operations: old rows remain exact-approval-only.

Rollback is fail-closed: revoke/pause grants, leave unknown reservations intact, and continue manual exact-draft review. Do not drop private tables until all unknown attempts are reconciled and a database backup has been verified.

## Offline activation workflow

1. Validate a synthetic policy with `public-engagement-policy-helper.py preview --input FILE --dry-run`.
2. Create an owner-authenticated grant through the local prospecting operator route.
3. Copy the approved grant into the private outbox with `engagement-grant-store`; authorize an immutable draft with `operation-authorize-policy`.
4. Run the normal outbox executor. Never call Reddit directly or use the collector/MCP boundary for writes.
5. Revoke with the owner route and `engagement-grant-revoke`; manually review any already-started or unknown attempt.

Live activation is separate operational work. Before it, verify the installed PRAW version, current Reddit API terms, account permissions, identity profile, and community rules. This implementation does not install a provider, acquire credentials, schedule a routine, or post live.
