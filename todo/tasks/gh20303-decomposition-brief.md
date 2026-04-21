# Decomposition Brief: Parent #20303 — Audit local -n nameref usages

## Parent Issue

[#20303](https://github.com/marcusquinn/aidevops/issues/20303) — Audit remaining local -n nameref usages for zsh-source compatibility gaps.

## Decomposition Rationale

The parent identified 72 `local -n` usages across 6 files but explicitly scoped itself as a **research/audit task**, not a blanket rewrite. The natural decomposition splits the research phase from the targeted fix phase.

## Reachability Analysis Summary

| File | Count | Sourced? | Re-exec guard? | Verdict |
|---|---:|---|---|---|
| `compare-models-helper.sh` | 43 | No — standalone executable | N/A | **SAFE** |
| `email-delivery-test-helper.sh` | 12 | No — standalone executable | N/A | **SAFE** |
| `document-creation-helper.sh` | 11 | No — standalone executable | N/A | **SAFE** |
| `setup/_tools.sh` | 2 | Yes — by `setup.sh:83` | No — `setup.sh` does not source `shared-constants.sh` | **AT RISK** |
| `thumbnail-helper.sh` | 1 | No — standalone executable | N/A | **SAFE** |
| `label-sync-helper.sh` | 1 | Yes — by `issue-sync-helper.sh:379` | Yes — `issue-sync-helper.sh:38` sources `shared-constants.sh` | **SAFE** |

Key finding: only `setup/_tools.sh` is genuinely at risk. On macOS first-run (before Homebrew bash install), `setup.sh` runs under `/bin/bash` 3.2 via `#!/usr/bin/env bash`, and the `local -n` in `_tools.sh` lines 96 and 126 will fail.

## Children

| Child | Issue | Task ID | Scope |
|---|---|---|---|
| Reachability audit | #20392 | t2718 | Formal per-file analysis, document findings on parent |
| Fix `setup/_tools.sh` | #20393 | t2719 | Apply module-globals pattern to 2 sites, add regression test |

## Decomposition trigger

Filed by auto-decomposer scanner (#20388) after parent's `parent-needs-decomposition` nudge aged ≥24h.
