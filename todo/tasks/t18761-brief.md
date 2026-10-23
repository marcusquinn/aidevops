<!-- aidevops:brief-schema=v2 -->

# cert-watch: Certificate Transparency + CAA routine that files issues in each site's private repo

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `certificate transparency CAA monitoring` → 0 hits
- [x] Discovery pass: 0 open/merged PRs for CT or CAA monitoring. `crt.sh` is already in `.agents/configs/allowed-urls.txt:247`. CAA appears only as a record type in `services/hosting/dns-providers.md`.
- [x] File refs verified: 6 refs checked, all present at HEAD (`85938e7209`)
- [x] Tier: `tier:standard` — new helper plus core routine registration; data sources, routing and safety rules are decided below
- [x] Seeded draft PR decision recorded: skipped — new helper; the contract is in the brief

## Origin

- **Created:** 2026-10-23
- **Session:** opencode:unknown-2026-10-23
- **Created by:** ai-interactive
- **Parent context:** follow-up to the eMudhra CA compromise response (t18748, GH#35277). The maintainer asked for an aidevops routine that watches certificate issuance and CAA for the domains they operate, and that files issues in the relevant private repos when it finds problems.
- **Why:** trust-store checks (`tls-trust`) only protect clients after a distrust is announced. The direct risk from a compromised or misbehaving CA is a certificate issued for *our* domains. Certificate Transparency logs show those issuances within hours, often before an incident is public. CAA limits which honest CAs may issue at all.

## What

### 1. New helper `.agents/scripts/cert-watch-helper.sh`

It sources `shared-constants.sh`, uses explicit `return 0/1` and `local var="$1"`, and is Bash 3.2 compatible. It defaults to a read-only dry run.

- **`domains [--format text|json]`:** build the monitored set of registrable domains (apexes). Each apex records the hostnames that came from it. Sources, in order:
  1. `~/.config/aidevops/site-inventory.json`: each site's `canonical_hostname` and `aliases`.
  2. The Hostinger fleet inventory under `~/.aidevops/.agent-workspace/work/hostinger-fleet/` (`hostinger-helper.sh fleet`), when present.
  3. `~/.config/aidevops/repos.json`: slugs whose repo name is a domain (`<owner>/<domain>`, the fleet naming in `services/hosting/hostinger.md` "Plan and drift").
  4. `extra_domains` and `ignore` from the optional config `~/.config/aidevops/cert-watch.json`, which must be a regular 0600 file. Ship the template as `.agents/configs/cert-watch.json.txt`.

  Skip missing sources with an INFO line.

- **`ct [--domain D]`:** for each apex, query `https://crt.sh/?q=%25.<apex>&output=json&exclude=expired`. Space requests at least 2 s apart and allow 30 s per request. Keep per-apex state (seen certificate ids, issuer org, `not_before`, SANs) in a 0600 JSON state file under `~/.aidevops/.agent-workspace/work/cert-watch/`.
  - **First run:** record a baseline and report no findings.
  - **Fetch errors:** crt.sh is often slow or returns 502. A failed fetch is `UNKNOWN` for that apex. It must never be read as "no certificates" and never erases state.
  - Findings for certificates not seen before:
    - **`ct-unexpected-issuer` (high):** the issuer org is not in the apex's expected set. The expected set is the CAA-permitted issuers if CAA exists, otherwise issuers seen for that apex in the last 180 days of state, plus config `expected_issuers`.
    - **`ct-distrusted-issuer` (critical):** the issuer matches `.agents/configs/cert-watch-distrusted-issuers.conf` (one issuer CN/org substring per line). Seed it with the eMudhra intermediates named in `.agents/advisories/emudhra-ca-compromise-2026-10.advisory`.
    - **`ct-unknown-hostname` (medium):** a SAN under the apex that matches no known hostname or alias and no wildcard we already hold.

- **`caa [--domain D]`:** resolve CAA with `dig +short CAA`, walking up to the apex (RFC 8659 tree climbing). Findings:
  - **`caa-missing` (low):** no CAA anywhere up the tree. Include a recommended record set built from issuers observed over the last 180 days of CT state, plus an `iodef` suggestion.
  - **`caa-blocks-active-issuer` (high):** CAA exists but does not permit an issuer that issued a currently valid certificate for that apex. The next renewal will fail. This is common with Cloudflare Universal SSL and host auto-SSL, which may rotate between CAs.

  The helper **never writes DNS**. It only recommends; applying records is a human or DNS-agent decision through `dns-helper.sh`.

- **`run [--apply] [--format text|json]`:** runs `domains`, then `ct`, then `caa`. Without `--apply`, print the findings only. With `--apply`, file issues as described in section 2.

### 2. Issue routing (`run --apply`)

**Target repo per apex.** Use the first match:

1. `site_repos` in `~/.config/aidevops/hosting-fleet.json`.
2. The site's `knowledge_repo` in site-inventory.
3. The repos.json slug whose name equals the apex or one of its hostnames.
4. `fallback_repo` from `cert-watch.json`.

If nothing resolves, print the finding and do not file it.

**Privacy gate (`#aidevops:trust-boundary`).** Before filing, run `gh repo view <slug> --json visibility`.

- If the visibility is not `PRIVATE`, or the check fails, file in `fallback_repo` instead, and only if that repo is itself verified `PRIVATE`.
- Domain names, client names and certificate details never go into a public repo. In particular they never go into `marcusquinn/aidevops`.

**Filing.** Create issues only through `gh_create_issue` (see the existing pattern in `.agents/scripts/cloudron-package-monitor-helper.sh:393-500`).

- **Body marker:** `<!-- aidevops:generator=cert-watch apex=<apex> finding=<kind> key=<crt.sh id or CAA hash> -->`.
- **Labels:** `security` and `source:cert-watch`; `priority:high` for high findings, `priority:critical` for critical ones. No `auto-dispatch`: these are operator triage, because confirming a certificate is ours or changing DNS needs owner authority.
- **Body content:** apex, hostnames, cert id with a crt.sh link built from the id, issuer, `not_before`/`not_after`, SANs, why it was flagged, and the next steps. For a certificate that isn't ours: revoke it through the issuing CA, review DNS/registrar access, add or tighten CAA. For CAA findings: the exact recommended records plus `dns-helper.sh` usage.

**Dedup.** Skip a finding if an open issue in the target repo already carries the same marker. A `caa-missing` finding that is still present stays on its single open issue; never file it twice.

### 3. Core routine and CLI

- **Routine.** Add the next free core routine id (r923 at time of writing) to `get_core_routine_entries` in `.agents/scripts/routines/core-routines.sh`:
  `r923|x|Cert watch — CT issuance and CAA audit for operated domains|repeat:daily(@06:40)|~3m|scripts/cert-watch-helper.sh run --apply|script`
- **Description.** Add `describe_r923` following `describe_r921` (overview, schedule table, safety rails, pulse diagnostics).
- **CLI.** Add `aidevops security cert-watch [args]` dispatch in `aidevops.sh` `_cmd_security`, defaulting to `run` (dry run).
- **Doc.** Add `.agents/tools/security/cert-watch.md`: sources, config keys, finding kinds and severities, routing order, privacy gate, and how to triage an unexpected certificate.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** Data sources, finding kinds, routing order, privacy gate and routine registration are all specified, and each has a verified in-repo pattern → tier:standard.

## How

- Issue filing, dedup and label-ensure pattern: `.agents/scripts/cloudron-package-monitor-helper.sh:370-500`.
- Core routine entry and description pattern: `.agents/scripts/routines/core-routines.sh:17-43` and `describe_r921` (around line 1040).
- Security subcommand dispatch: `aidevops.sh` `_cmd_security`. See how `tls-trust` was wired in PR #35282.
- Inventory readers: `.agents/scripts/site-context-helper.sh` (site-inventory) and `.agents/services/hosting/hostinger.md` "Plan and drift" (fleet inventory, `hosting-fleet.json`).
- CAA background and record syntax: `.agents/services/hosting/dns-providers.md`.

### Files Scope

- `.agents/scripts/cert-watch-helper.sh`
- `.agents/configs/cert-watch.json.txt`
- `.agents/configs/cert-watch-distrusted-issuers.conf`
- `.agents/tools/security/cert-watch.md`
- `.agents/scripts/routines/core-routines.sh`
- `.agents/reference/routines.md`
- `aidevops.sh`

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/cert-watch-helper.sh
.agents/scripts/cert-watch-helper.sh domains --format json | jq -e 'length >= 0'
.agents/scripts/cert-watch-helper.sh caa --domain example.com        # dry run, no network writes
.agents/scripts/cert-watch-helper.sh run --format json | jq -e 'type == "array"'
bash .agents/scripts/tests/test-pulse-routines-selector.sh
.agents/scripts/linters-local.sh --changed
```

## Acceptance Criteria

- [ ] `run` (dry run) lists monitored apexes and findings and makes no GitHub writes. The first `ct` run per apex produces a baseline only.
- [ ] A crt.sh fetch failure yields `UNKNOWN` for that apex and leaves its stored state unchanged.
- [ ] `run --apply` files each finding once, in the resolved private repo, with the `generator=cert-watch` marker. A second run with the same findings creates no new issues.
- [ ] Negative: findings are never filed in a repo whose visibility is not verified `PRIVATE`.

  ```yaml
  verify:
    method: codebase
    pattern: "visibility"
    path: ".agents/scripts/cert-watch-helper.sh"
    expect: present
  ```

- [ ] Negative: the helper never changes DNS.

  ```yaml
  verify:
    method: codebase
    pattern: "dns-helper\\.sh (add|update|delete|set)"
    path: ".agents/scripts/cert-watch-helper.sh"
    expect: absent
  ```

- [ ] r923, or the next free id, appears in `get_core_routine_entries`, and `describe_r923` renders. Existing routine tests pass.
- [ ] `shellcheck` is clean, and `linters-local.sh --changed` passes.

## Non-goals

- Automatic DNS changes and automatic certificate revocation.
- Monitoring third-party domains we do not operate.
- Re-running `tls-trust` fleet probes. Those are covered by t18750; a follow-up may route their TRUSTED rows through the same issue router.
