<!-- aidevops:brief-schema=v2 -->

# tls-trust phase 1: local client probe helper, canary config, `aidevops security tls-trust`

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `emudhra CA trust store` → 1 hit — lessons copied into the parent brief
- [x] Discovery pass: 0 PRs touch `tls-trust`; `aidevops.sh` `_cmd_security` last changed for the supply-chain scanner (e0d8d05995)
- [x] File refs verified: 3 refs checked, all present at HEAD
- [x] Tier: `tier:standard` — new helper following a verified pattern; probe semantics are decided below
- [x] Seeded draft PR decision recorded: skipped — new files; the contract is in the brief

## Origin

- **Created:** 2026-10-21
- **Session:** opencode:unknown-2026-10-21
- **Created by:** ai-interactive
- **Parent task:** t18748 (GH#35277). Read the parent's "Context & Decisions" first.

## What

1. **New file `.agents/configs/tls-trust-canaries.conf`.** One canary per line, formatted `id|url|incident|added`. Lines starting with `#` are comments. Seed it with:
   ```
   emudhra-2026-10-direct|https://dv-g3b-emudhra.we-have-a-problem.com/|https://emudhra.we-have-a-problem.com|2026-10-21
   emudhra-2026-10-aaa|https://dv-g3b-aaa-emudhra.we-have-a-problem.com/|https://emudhra.we-have-a-problem.com|2026-10-21
   ```
   Every canary's expected safe result is "certificate rejected".
2. **New helper `.agents/scripts/tls-trust-helper.sh`.** It sources `shared-constants.sh` and follows the `supply-chain-advisory-helper.sh` structure: `print_usage`, a `cmd_*` per subcommand, `main`.
   - **`local [--canary ID] [--format text|json]`:** for each client present, probe each canary (or only `--canary ID`). Return one result per client/canary:
     - **curl clients:** `/usr/bin/curl`, `curl` on PATH, and keg-only Homebrew curl at `$(brew --prefix)/opt/curl/bin/curl` when present.
     - **Runtimes:** `node`, `python3` and `php` on PATH.
     - **Values:** `TRUSTED` (exposed), `REJECTED` (safe), `UNKNOWN` (network error, timeout or unsupported client). Busybox `wget` is always UNKNOWN.
     - **Exit codes:** 0 when no client is TRUSTED, 2 when any is TRUSTED, 1 on usage error.
   - **`probe-script`:** print a self-contained POSIX `sh` probe body. It takes a URL as `$1`, tries curl, then node, python3, wget, and prints exactly one line `<client> <TRUSTED|REJECTED|UNKNOWN>`. Phase 2 reuses it for remote hosts and containers. `local` must use the same per-client logic, so the two paths cannot drift.
   - **Classification:**
     - curl exit 60/35/51/77 → REJECTED; exit 0 (any HTTP status) → TRUSTED; others → UNKNOWN.
     - node error codes `UNABLE_TO_GET_ISSUER_CERT_LOCALLY`, `CERT_*`, `SELF_SIGNED_*` → REJECTED; a response → TRUSTED; others → UNKNOWN.
     - python `ssl.SSLCertVerificationError` → REJECTED.
     - php `curl_errno` 60 → REJECTED.
     - Node probes must `process.exit()` in both callbacks, because keep-alive sockets otherwise hang the probe. Timeout: 15 s per probe.
   - **Remediation hint:** for each TRUSTED result, print the next action keyed by client. Examples: Homebrew Node → `brew upgrade ca-certificates node`; official Node → upgrade Node, or `--use-openssl-ca` plus `SSL_CERT_FILE`; `/usr/bin/curl` on macOS → see the canary's incident URL.
3. **Edit `aidevops.sh` `_cmd_security`.**
   - Add a case `tls-trust) shift || true; _dispatch_helper "tls-trust-helper.sh" "tls-trust-helper.sh" "${@:-local}" ;;`.
   - Add `tls-trust-helper.sh local || true` to the no-arg full assessment, after the supply-chain scan.
4. **New doc `.agents/tools/security/tls-trust.md`.** It holds usage, the canary file format, result semantics, and the parent's lessons list. Keep it short.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The pattern and classification table are decided; the worker writes a new helper following `supply-chain-advisory-helper.sh` → tier:standard.

## How

- Pattern: `.agents/scripts/supply-chain-advisory-helper.sh` (structure, `shared-constants.sh` sourcing, explicit `return 0/1`, `local var="$1"`).
- Dispatch: `aidevops.sh:1764-1810` (`_cmd_security`).
- Bash 3.2 compatible (macOS): no associative arrays and no `${var,,}`. See `reference/bash-compat.md`.

### Files Scope

- `.agents/scripts/tls-trust-helper.sh`
- `.agents/configs/tls-trust-canaries.conf`
- `.agents/tools/security/tls-trust.md`
- `aidevops.sh`

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/tls-trust-helper.sh
.agents/scripts/tls-trust-helper.sh local --format json | jq -e 'length > 0'
.agents/scripts/tls-trust-helper.sh probe-script | sh -s -- https://example.com/   # expect "<client> TRUSTED"
.agents/scripts/linters-local.sh --changed
```

## Acceptance Criteria

- [ ] `aidevops security tls-trust` lists every installed client × canary with TRUSTED/REJECTED/UNKNOWN. It exits 0 on a host patched per the parent's notes (for example Homebrew `ca-certificates` ≥ 2026-10-20) and 2 when any client is TRUSTED.

  ```yaml
  verify:
    method: bash
    run: ".agents/scripts/tls-trust-helper.sh local --format json | jq -e 'all(.[]; .result == \"TRUSTED\" or .result == \"REJECTED\" or .result == \"UNKNOWN\")'"
  ```

- [ ] The `probe-script` output run against `https://example.com/` reports TRUSTED: valid chains are not misreported.

  ```yaml
  verify:
    method: bash
    run: ".agents/scripts/tls-trust-helper.sh probe-script | sh -s -- https://example.com/ | grep -q ' TRUSTED$'"
  ```

- [ ] Negative: the helper never disables verification (no `-k`, `--insecure`, `NODE_TLS_REJECT_UNAUTHORIZED`, `verify=False`, `CURLOPT_SSL_VERIFYPEER`).

  ```yaml
  verify:
    method: codebase
    pattern: "(--insecure|NODE_TLS_REJECT_UNAUTHORIZED|verify=False|SSL_VERIFYPEER| -k )"
    path: ".agents/scripts/tls-trust-helper.sh"
    expect: absent
  ```

- [ ] `shellcheck` is clean, and `linters-local.sh --changed` passes.
