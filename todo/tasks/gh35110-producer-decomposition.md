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

Current implementation evidence: an uncommitted draft of `worktree_recovery_producer.py` and a shared journal-loader adjustment exist; Python compilation passed. No production caller has switched, no runtime acceptance is claimed, and no live recovery data has been changed for this phase. The draft belongs to #35144 and must be tested/reviewed before delivery.

Completion contract: keep #35110 open until all four children are delivered and the original producer criteria have verified evidence. The broader #35078 has its own completion contract. This decomposition does not authorize release, deployment, real-source retirement or additional legacy cleanup.
