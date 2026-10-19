# GH#35110: bounded producer implementation sequence

The user requested smaller tasks. #35110 is now a parent tracker, not a single executable leaf. Its original acceptance criteria remain authoritative, but its old leaf-PR convention is superseded: child PRs reference #35110 and #35078 without closing either parent prematurely.

| Order | Child | Deliverable | Dependency |
| --- | --- | --- | --- |
| 1 | #35144 | Verified compact capture transaction; no production caller switched | None |
| 2 | #35145 | Compact receipt validation before native removal; retain legacy readers | #35144 |
| 3 | #35146 | Central producer and four callers switch; legacy fixture-only compatibility | #35144, #35145 |
| 4 | #35147 | Real CLI recovery evidence, archive discoverability and operator docs | #35146 |

All four children have `origin:interactive`, linked native sub-issue relationships and explicit manual ownership inherited from #35078/#35110. They retain `no-auto-dispatch`; this split must not launch competing workers. The first child is claimed by the originating session; the remaining children are blocked on the recorded native dependencies.

Durable briefs are in `todo/tasks/gh35110-producer-transaction.md`, `gh35110-compact-removal-guards.md`, `gh35110-producer-cutover.md` and `gh35110-producer-acceptance.md` in the same directory. Each names the relevant functions, file scope, verification and negative cases.

Delivered: #35144 via PR #35148 (`827faf186`), #35145 via PR #35150 (`47c888871`), and #35146 via PR #35157 (`a7ec8207a`). The central producer and all four callers now use verified compact evidence. #35147 adds actual CLI restoration, safe list discovery and operator documentation; its measured fixture evidence and original-criteria coverage are recorded in `gh35110-producer-acceptance.md`. Only that final child's merge and parent reconciliation remain; no installed-store retirement or deployment is claimed.

Completion contract: keep #35110 open until all four children are delivered and the original producer criteria have verified evidence. The broader #35078 has its own completion contract. This decomposition does not authorize release, deployment, real-source retirement or additional legacy cleanup.
