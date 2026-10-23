---
description: Monitor operated domains for new CT certificates and CAA renewal risks
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Certificate watch

`aidevops security cert-watch` defaults to `run`, a dry run with **no GitHub
writes**. It updates private CT baseline state but never changes DNS or revokes
certificates. Core routine **r923** runs `run --apply` daily at 06:40 to file
operator-triage issues. Findings are not implementation dispatch instructions.

```bash
cert-watch-helper.sh domains --format json
cert-watch-helper.sh ct --domain example.com
cert-watch-helper.sh caa --domain example.com
cert-watch-helper.sh run --format json
cert-watch-helper.sh run --apply
```

## Dependencies and configuration

Requires Bash 3.2+, Python 3.9+, `curl`, and `dig`; filing additionally requires
authenticated `gh` and the framework's `gh_create_issue` wrapper. Apex discovery
uses the system **libpsl** (including private suffixes), or a local Public Suffix
List specified by `public_suffix_file`. If neither is available, explicitly list
the operated apexes in `extra_domains`: these anchor their inventory subdomains.
The helper fails rather than guessing registrable boundaries (for example `co.uk`
or tenant hosting suffixes). Keep the installed PSL current; no PSL downloads or
dependency installation are performed by the routine.

Copy `configs/cert-watch.json.txt` to `~/.config/aidevops/cert-watch.json` and set
mode **0600**. It must be a regular file, not a symlink. Supported keys:

| Key | Meaning |
|-----|---------|
| `extra_domains` | Explicit operated apexes; also anchors when PSL is unavailable |
| `ignore` | Exclude a hostname/apex and its descendants from discovery |
| `expected_issuers` | Object mapping apex to issuer organization strings; supplements 180-day history when no CAA applies |
| `issuer_caa_map` | Object mapping CAA issuer domains to arrays of issuer-name substrings; extends the bundled common CA mapping |
| `fallback_repo` | Optional private `owner/repo` for findings without a safe primary route |
| `public_suffix_file` | Optional path to a locally maintained PSL, including wildcard and exception rules |

Example configuration:

```json
{
  "extra_domains": ["example.com"],
  "ignore": ["retired.example.com"],
  "expected_issuers": {"example.com": ["Let's Encrypt"]},
  "issuer_caa_map": {},
  "fallback_repo": "OWNER/PRIVATE_SECURITY_REPO",
  "public_suffix_file": null
}
```

Domain discovery reads, in order:

1. `~/.config/aidevops/site-inventory.json`: `sites` entries' `canonical_hostname`
   and `aliases` (wildcard aliases are preserved).
2. Saved `~/.aidevops/.agent-workspace/work/hostinger-fleet/inventory.json`:
   `sites[].domain`; no hosting API call or refresh is performed.
3. `~/.config/aidevops/repos.json`: `initialized_repos[].slug` with a domain as
   repository name (also accepts legacy `repos`).
4. Configured `extra_domains`, filtered by `ignore`.

Missing sources are INFO diagnostics on stderr; JSON stdout remains parseable.
Each discovered apex retains its known hostnames and aliases.

## Baselines, errors and findings

CT requests use crt.sh with a 30-second timeout and at least two seconds between
request starts. The first **successful, valid array** response for an apex is a
baseline and produces no CT findings. Empty valid arrays are baselines too.
HTTP errors, timeouts, invalid JSON and malformed certificate rows are **UNKNOWN**,
never an empty result: the existing state file is left byte-for-byte unchanged.
State lives under `~/.aidevops/.agent-workspace/work/cert-watch/` (0700 directory,
0600 JSON files). Updates are atomic and runs are serialized with a nonblocking
lock. Corrupt/insecure state fails closed rather than resetting the baseline.

| Kind | Severity | Meaning |
|------|----------|---------|
| `ct-unexpected-issuer` | high | Newly seen certificate issuer is outside applicable CAA, or outside 180-day issuance history plus configured issuers when no CAA exists |
| `ct-distrusted-issuer` | critical | New certificate matches a substring in `cert-watch-distrusted-issuers.conf` |
| `ct-unknown-hostname` | medium | New SAN under our apex matches no known hostname/alias or previously held unexpired wildcard |
| `caa-missing` | low | No CAA found from a hostname through its apex; one stable finding per apex |
| `caa-blocks-active-issuer` | high | Effective CAA prevents an issuer of a currently valid certificate; renewal may fail |
| `ct-unknown` / `caa-unknown` | unknown | Incomplete observation; printed only, never filed as a security finding |
| `ct-policy-unknown` | unknown | A new certificate's issuer check is deferred until its CAA policy can be evaluated |

CAA resolution inspects DNS response status so SERVFAIL cannot become
`caa-missing`. It climbs each hostname to the operated apex and stops at the first
CAA RRset. This audit is deliberately apex-bounded: it does not inspect records
above that boundary and is not a complete CA issuance authorization validator.
`issuewild` overrides `issue` for wildcard
issuance; without `issuewild`, wildcard issuance uses `issue`. An empty issuer
(`issue ";"`) denies issuance; an iodef-only RRset does not restrict issuance.
CNAME/DNAME answers, unexpected answer owners and unsupported issuer-critical
properties are reported UNKNOWN for manual inspection, not as missing CAA.
Unknown CAA issuer domains do not imply either permission or denial; extend
`issuer_caa_map` after reviewing the CA documentation. CAA parameters such as
account binding and validation methods need operator review, not automated
issuer-name matching.

Missing-CAA recommendations use issuers in the last 180 days of CT state plus
an iodef mailbox suggestion. With no observed/mapped issuers, only iodef can be
suggested safely: confirm the active CA before adding issuance restrictions.
CAA-blocking findings propose records at the affected hostname. Review both
ordinary and wildcard issuance and the contact address before applying them.

Unfiled CT findings persist across dry runs, failed filing attempts and missing
private routes. After successful filing/dedup, they are acknowledged in state;
the same certificate ID does not generate a new alert on subsequent runs.
An UNKNOWN CAA observation does not consume a new certificate's issuer check:
the original expected-issuer set is retained and the check retried, without
letting the unresolved issuer establish its own historical expectation.

## Routing and privacy boundary

The first configured match wins:

1. `hosting-fleet.json` `site_repos`, matching apex then known hostnames. Full
   slugs are accepted; repository-domain values use the fleet `owner` or matching
   `owner_exceptions` entry.
2. Site inventory `knowledge_repo`.
3. Registered repository whose name equals the apex or a known hostname.
4. Configured `fallback_repo`.

Before **any label or issue write**, the target must have visibility verified as
`PRIVATE` with `gh repo view`. A public/internal/unavailable primary route falls
back only to a separately verified private fallback. No safe route means local
output only. The public framework repository is always refused, even if its
visibility changes. The shell filing entrypoint independently rechecks visibility.
Never paste operational domain lists or certificate findings into public issues.

Filing uses `gh_create_issue` with `security`, `source:cert-watch`, and
`no-auto-dispatch` (operator authority is required). High/critical findings add
their priority label. Bodies carry:

```text
<!-- aidevops:generator=cert-watch apex=APEX finding=KIND key=ID_OR_CAA_HASH -->
```

All open issues are paginated for exact-marker dedup. A failed dedup read stops
filing. A persistent missing-CAA finding stays on its one open issue. Once an
operator closes it, a still-present CAA problem can be reported again.

## Triage an unexpected certificate

1. Compare SANs, issuer and validity with the site's hosting/CDN inventory.
   Cloudflare Universal SSL and hosting auto-SSL can legitimately rotate CAs.
2. Inspect the linked crt.sh certificate and validate ownership with the operator.
   CT observations are evidence, not proof of malicious use or deployed TLS state.
3. If unauthorized, request revocation from the issuing CA and review registrar,
   DNS, CDN and hosting access. Preserve the certificate ID and incident evidence.
4. Review proposed CAA with the DNS agent using `dns-helper.sh help`. DNS changes
   and revocation require separate owner authorization; this monitor cannot do them.
5. Re-run the audit after authorized remediation. Inspect Pulse's stored state
   with `jq '.r923' ~/.aidevops/.agent-workspace/pulse/routine-state.json` when
   investigating scheduled runs.
