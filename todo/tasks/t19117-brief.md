## What

Publish a security advisory for the NGINX2Root nginx CVEs (CVE-2026-123007 HTTP/2 memory corruption, CVE-2026-123633 HTTP/2 use-after-free, plus CVE-2026-113425 mail proxy, CVE-2026-123634 resolver, CVE-2026-121810 HTTP/3), with a Cloudron mitigation playbook. Upstream fixes: nginx 1.30.7 / 1.31.9. As of 2026-11-18 Ubuntu 26.04 `nginx 1.28.3-2ubuntu1.12` is unpatched.

## Why

aidevops users running nginx (directly or via Cloudron's managed reverse proxy) need the check, interim mitigation and revert steps. The Cloudron forum workaround (`sed` of `http2 on`) misses legacy `listen ... http2` vhosts and is reverted when Cloudron regenerates configs; these were observed while mitigating three Cloudron 10.1.6 hosts.

## How

- NEW: `.agents/advisories/nginx2root-2026-11.advisory` following `.agents/advisories/php-rce-2026-10.advisory` (headline line, check, mitigate, revert, links, dismiss command).
- EDIT: `.agents/services/hosting/cloudron.md` add an "nginx (host reverse proxy) security releases" subsection after "PHP and runtime security releases" with observed Cloudron specifics: generated configs under `/etc/nginx/applications`, legacy `listen ... http2` form, config regeneration after boot, external `curl --resolve` verification, coturn SCTP usage, reboot baseline for restart=no containers, revert.

### Files Scope

- `.agents/advisories/nginx2root-2026-11.advisory`
- `.agents/services/hosting/cloudron.md`

## Acceptance

- Advisory renders in the same format as existing advisories; no private hostnames/IPs.
- `markdownlint-cli2` passes on `cloudron.md`.
- Linked PR merged and included in a patch release.

## Verification

`.agents/scripts/linters-local.sh` (or markdown lint for the changed file); `rg -n "CVE-2026-123007" .agents/advisories .agents/services/hosting/cloudron.md`.
