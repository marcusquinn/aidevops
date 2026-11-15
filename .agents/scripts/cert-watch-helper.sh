#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Bash 3.2 entrypoint; Python 3 handles untrusted JSON without shell evaluation.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

cert_watch_verify_slug() {
	local slug="$1"
	local visibility=""
	# aidevops:trust-boundary — independently recheck immediately before writes.
	slug=$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')
	[[ "$slug" =~ ^[a-z0-9_.-]+/[a-z0-9_.-]+$ ]] || return 1
	[[ "$slug" != marcusquinn/aidevops ]] || return 1
	visibility=$(gh repo view "$slug" --json visibility --jq '.visibility') || return 1
	[[ "$visibility" == PRIVATE ]] || return 1
	CERT_WATCH_SLUG="$slug"
	return 0
}

cert_watch_edit_issue() {
	local slug="$1"
	local number="$2"
	local body_file="$3"
	[[ "$number" =~ ^[0-9]+$ ]] || return 1
	cert_watch_verify_slug "$slug" || return 1
	slug="$CERT_WATCH_SLUG"
	# shellcheck source=shared-gh-wrappers.sh
	source "${SCRIPT_DIR}/shared-gh-wrappers.sh"
	gh_issue_edit_safe "$number" --repo "$slug" --body-file "$body_file" >&2 || return 1
	return 0
}

cert_watch_close_issue() {
	local slug="$1"
	local number="$2"
	local comment="$3"
	[[ "$number" =~ ^[0-9]+$ ]] || return 1
	cert_watch_verify_slug "$slug" || return 1
	slug="$CERT_WATCH_SLUG"
	# shellcheck source=shared-gh-wrappers.sh
	source "${SCRIPT_DIR}/shared-gh-wrappers.sh"
	gh_issue_close_safe "$number" --repo "$slug" --comment "$comment" >&2 || return 1
	return 0
}

cert_watch_file_issue() {
	local slug="$1"
	local title="$2"
	local body_file="$3"
	local priority="$4"
	cert_watch_verify_slug "$slug" || return 1
	slug="$CERT_WATCH_SLUG"
	# shellcheck source=shared-gh-wrappers.sh
	source "${SCRIPT_DIR}/shared-gh-wrappers.sh"
	local label=""
	local labels=(security source:cert-watch no-auto-dispatch)
	[[ "$priority" != high && "$priority" != critical ]] || labels+=("priority:${priority}")
	local args=(--repo "$slug" --title "$title" --body-file "$body_file")
	for label in "${labels[@]}"; do
		gh label create "$label" --repo "$slug" --color D73A4A --force >/dev/null || return 1
		args+=(--label "$label")
	done
	gh_create_issue "${args[@]}" >&2 || return 1
	return 0
}

case "${1:-}" in
__file_issue)
	shift
	cert_watch_file_issue "$@"
	exit $?
	;;
__edit_issue)
	shift
	cert_watch_edit_issue "$@"
	exit $?
	;;
__close_issue)
	shift
	cert_watch_close_issue "$@"
	exit $?
	;;
esac

exec python3 - "${BASH_SOURCE[0]}" "$@" <<'PY'
import argparse
import ctypes
import ctypes.util
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import sys
import tempfile
import time

SCRIPT = Path(sys.argv.pop(1)).resolve()
HOME = Path.home()
CONFIG = HOME / '.config/aidevops'
WORK = HOME / '.aidevops/.agent-workspace/work'
NOW = dt.datetime.now(dt.timezone.utc)
RECENT = NOW - dt.timedelta(days=180)


def info(message):
    print(message, file=sys.stderr)


def load(path, default, private=False):
    if not path.exists() and not path.is_symlink():
        info('INFO: missing source ' + path.name)
        return default
    mode = path.lstat().st_mode
    if private and (not stat.S_ISREG(mode) or stat.S_IMODE(mode) != 0o600):
        raise ValueError(path.name + ' must be a regular 0600 file')
    return json.loads(path.read_text())


def command(args, timeout=35):
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise ValueError('command failed: ' + args[0])
    return result.stdout


def hostname(value):
    if not isinstance(value, str):
        raise ValueError('hostname must be a string')
    name = value.lower().rstrip('.').removeprefix('*.').encode('idna').decode('ascii')
    if len(name) > 253 or not re.fullmatch(r'(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}', name):
        raise ValueError('invalid hostname')
    return name


# Providers hosting unrelated customers directly under one registrable domain.
# libpsl returns the provider domain for them, so CT would watch every tenant.
SHARED_PARENT_DOMAINS = ('hostingersite.com',)


class ApexResolver:
    """Use the system PSL, or an operator-supplied PSL; never guess co.uk etc."""
    def __init__(self, config):
        self.shared = {hostname(x) for x in SHARED_PARENT_DOMAINS}
        self.shared.update(hostname(x) for x in config.get('shared_parent_domains', []))
        self.anchors = sorted({hostname(x) for x in config.get('extra_domains', [])}, key=len, reverse=True)
        self.rules = None
        self.lib = None
        if config.get('public_suffix_file'):
            path = Path(config['public_suffix_file']).expanduser()
            self.rules = {x.strip().lower() for x in path.read_text().splitlines()
                          if x.strip() and not x.startswith('//')}
        else:
            library = ctypes.util.find_library('psl')
            if library:
                self.lib = ctypes.CDLL(library)
                self.lib.psl_builtin.restype = ctypes.c_void_p
                self.lib.psl_registrable_domain.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
                self.lib.psl_registrable_domain.restype = ctypes.c_char_p

    def resolve(self, name):
        """Registrable domain, or the exact host under a shared hosting parent."""
        return name if self.is_shared(name) else self.registrable(name)

    def is_shared(self, name):
        # Independent of explicit anchors: a tenant host stays a tenant host.
        return name in self.shared or any(name.endswith('.' + x) for x in self.shared) \
            or self.registrable(name) in self.shared

    def registrable(self, name):
        for apex in self.anchors:
            if name == apex or name.endswith('.' + apex):
                return apex
        if self.lib:
            apex = self.lib.psl_registrable_domain(self.lib.psl_builtin(), name.encode())
            if apex:
                return apex.decode()
        if self.rules is not None:
            parts = name.split('.')
            count = 1
            for i in range(len(parts)):
                suffix = '.'.join(parts[i:])
                if '!' + suffix in self.rules:
                    count = len(parts) - i - 1
                    break
                if suffix in self.rules or (i > 0 and '*.' + suffix in self.rules):
                    count = max(count, len(parts) - i + (i > 0 and '*.' + suffix in self.rules))
            if len(parts) > count:
                return '.'.join(parts[-count - 1:])
        raise ValueError('Cannot determine apex: configure extra_domains or public_suffix_file (or install libpsl)')


def objects(value):
    return value.values() if isinstance(value, dict) else value


def inventory(config):
    resolver = ApexResolver(config)
    sites = load(CONFIG / 'site-inventory.json', {}).get('sites', {})
    registry = load(CONFIG / 'repos.json', {})
    repos = registry.get('initialized_repos', registry.get('repos', []))
    entries = {}
    ignored = {hostname(x) for x in config.get('ignore', [])}

    def add(raw, repo=None):
        name = hostname(raw)
        if any(name == x or name.endswith('.' + x) for x in ignored):
            return
        apex = resolver.resolve(name)
        row = entries.setdefault(apex, {'apex': apex, 'hostnames': [], 'knowledge_repos': {}})
        if resolver.is_shared(name):
            row['shared_parent'] = True
        known = ('*.' if raw.startswith('*.') else '') + name
        if known not in row['hostnames']:
            row['hostnames'].append(known)
        if repo:
            row['knowledge_repos'][name] = repo

    for site in objects(sites):
        for name in [site['canonical_hostname']] + site.get('aliases', []):
            add(name, site.get('knowledge_repo'))
    fleet = WORK / 'hostinger-fleet/inventory.json'
    fleet_data = load(fleet, {})
    for site in objects(fleet_data.get('sites', [])):
        add(site['domain'])
    for repo in objects(repos):
        slug = repo.get('slug', '')
        if '/' in slug and '.' in slug.split('/')[-1]:
            add(slug.split('/')[-1])
    for name in config.get('extra_domains', []):
        add(name)
    return sorted(entries.values(), key=lambda row: row['apex']), list(objects(repos))


def timestamp(value):
    parsed = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed.astimezone(dt.timezone.utc)


def matches(name, pattern):
    if pattern.startswith('*.'):
        return name.endswith(pattern[1:]) and name.count('.') == pattern.count('.')
    return name == pattern


CA_NAMES = {
    'letsencrypt.org': ["let's encrypt"],
    'pki.goog': ['google trust services'],
    'digicert.com': ['digicert', 'geotrust', 'thawte'],
    'sectigo.com': ['sectigo', 'comodo'],
    'comodoca.com': ['sectigo', 'comodo'],
    'globalsign.com': ['globalsign'],
    'amazon.com': ['amazon'],
    'amazontrust.com': ['amazon'],
    'awstrust.com': ['amazon'],
    'amazonaws.com': ['amazon'],
    'ssl.com': ['ssl.com'],
    'entrust.net': ['entrust'],
    'emsign.com': ['emsign', 'emudhra'],
}


def allowed(issuer, records, wildcard, config):
    if any(flags & 128 and tag not in ('issue', 'issuewild', 'iodef') for flags, tag, value in records):
        return None
    tags = [r[2] for r in records if r[1] == ('issuewild' if wildcard else 'issue')]
    if wildcard and not tags:
        tags = [r[2] for r in records if r[1] == 'issue']
    if not tags:
        return True  # iodef-only and issuewild-only do not restrict ordinary issuance
    mapping = dict(CA_NAMES, **config.get('issuer_caa_map', {}))
    unknown = False
    for value in tags:
        ca = value.split(';')[0].strip().lower()
        if not ca:
            continue  # issue ";" denies all issuance
        aliases = mapping.get(ca)
        if aliases is None:
            unknown = True
        elif any(alias.lower() in issuer.lower() for alias in aliases):
            return True
    return None if unknown else False


def caa_records(name, apex):
    while True:
        # +short alone conflates NXDOMAIN/SERVFAIL with NODATA: inspect status too.
        response = command(['dig', '+time=5', '+tries=1', '+noall', '+comments', '+answer', 'CAA', name])
        if not re.search(r'status: (?:NOERROR|NXDOMAIN),', response):
            raise ValueError('DNS status UNKNOWN')
        records = []
        for line in response.splitlines():
            if not line.strip() or line.lstrip().startswith(';'):
                continue
            fields = shlex.split(line)
            if len(fields) >= 5 and fields[3] in ('CNAME', 'DNAME'):
                raise ValueError('CAA alias needs operator inspection; UNKNOWN')
            if len(fields) >= 7 and fields[3] == 'CAA':
                if fields[0].lower().rstrip('.') != name:
                    raise ValueError('Unexpected CAA answer owner; UNKNOWN')
                flags, tag = int(fields[4]), fields[5].lower()
                if flags & 128 and tag not in ('issue', 'issuewild', 'iodef'):
                    raise ValueError('Unsupported critical CAA property; UNKNOWN')
                records.append((flags, tag, ' '.join(fields[6:])))
        if records or name == apex:
            return records
        name = name.split('.', 1)[1]


def policy_for(name, apex, policies):
    name = name.removeprefix('*.')
    if name not in policies:
        try:
            policies[name] = caa_records(name, apex)
        except (ValueError, OSError, subprocess.SubprocessError):
            policies[name] = None
    return policies[name]


def normalize_cert(row):
    ident = str(row['id'])
    if not ident.isdigit():
        raise ValueError('invalid certificate ID')
    issuer_name = row['issuer_name']
    org = re.search(r'(?:^|,\s*)O=("[^"]+"|[^,]+)', issuer_name)
    issuer = org.group(1).strip('"') if org else issuer_name
    before, after = row['not_before'], row['not_after']
    timestamp(before)
    timestamp(after)
    sans = sorted({('*.' if s.startswith('*.') else '') + hostname(s)
                   for s in row['name_value'].splitlines()})
    return {'id': ident, 'issuer': issuer, 'issuer_name': issuer_name,
            'not_before': before, 'not_after': after, 'sans': sans}


def private_save(path, value):
    fd, temp = tempfile.mkstemp(dir=path.parent, prefix='.state-')
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, indent=2)
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def finding(row, kind, severity, key, reason, cert=None, records=None):
    return {'apex': row['apex'], 'hostnames': row['hostnames'], 'kind': kind,
            'severity': severity, 'key': str(key), 'reason': reason,
            'certificate': cert, 'recommended_records': records or []}


def ct_scan(row, state, path, config, policies, last_fetch):
    wait = 2 - (time.monotonic() - last_fetch[0])
    if wait > 0:
        time.sleep(wait)
    last_fetch[0] = time.monotonic()
    try:
        response = command(['curl', '--fail', '--silent', '--show-error', '--max-time', '30',
                            'https://crt.sh/?q=%25.' + row['apex'] + '&output=json&exclude=expired'])
        data = json.loads(response)
        if not isinstance(data, list):
            raise ValueError('CT response is not an array')
        certs = {c['id']: c for c in map(normalize_cert, data)}
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError):
        info('UNKNOWN CT: ' + row['apex'] + ' (state unchanged)')
        return [finding(row, 'ct-unknown', 'unknown', 'fetch', 'CT fetch failed; state unchanged')], state
    baseline = state is None
    old = (state or {}).get('certificates', {})
    deferred = (state or {}).get('deferred_issuer_checks', {})
    expected = {c['issuer'].lower() for ident, c in old.items()
                if ident not in deferred and timestamp(c['not_before']) >= RECENT}
    expected.update(x.lower() for x in config.get('expected_issuers', {}).get(row['apex'], []))
    held = [san for c in old.values() for san in c['sans']
            if san.startswith('*.') and timestamp(c['not_after']) >= NOW]
    held += [san for san in row['hostnames'] if san.startswith('*.')]
    distrusted = [x.strip().lower() for x in (SCRIPT.parent.parent / 'configs/cert-watch-distrusted-issuers.conf').read_text().splitlines()
                  if x.strip() and not x.startswith('#')]
    auto_known = dict((state or {}).get('auto_known_sans', {}))
    plain_hosts = [h for h in row['hostnames'] if not h.startswith('*.')]
    findings = []
    unresolved = []
    observations = dict(certs)
    observations.update({ident: old[ident] for ident in deferred if ident in old})
    for ident, cert in observations.items():
        retry = ident in deferred
        if baseline or (ident in old and not retry):
            continue
        issuer_expected = set(deferred.get(ident, expected))
        issuer_expected.update(x.lower() for x in config.get('expected_issuers', {}).get(row['apex'], []))
        if not retry and any(x in cert['issuer_name'].lower() for x in distrusted):
            findings.append(finding(row, 'ct-distrusted-issuer', 'critical', ident, 'Issuer matches distrust list', cert))
        decisions = []
        for san in cert['sans']:
            name = san.removeprefix('*.')
            if name != row['apex'] and not name.endswith('.' + row['apex']):
                continue
            policy = policy_for(name, row['apex'], policies)
            if policy is None:
                decisions.append(None)
            elif policy:
                decisions.append(allowed(cert['issuer'], policy, san.startswith('*.'), config))
            else:
                decisions.append(cert['issuer'].lower() in issuer_expected)
        if False in decisions:
            findings.append(finding(row, 'ct-unexpected-issuer', 'high', ident, 'Issuer is outside the expected issuer set', cert))
        if None in decisions and False not in decisions:
            # A DNS outage must not let a new issuer establish its own baseline.
            deferred[ident] = sorted(issuer_expected)
            unresolved.append(finding(row, 'ct-policy-unknown', 'unknown', ident,
                                      'Issuer evaluation deferred until CAA observation recovers', cert))
        else:
            deferred.pop(ident, None)
        benign_issuer = (cert['issuer'].lower() in issuer_expected
                         and not any(x in cert['issuer_name'].lower() for x in distrusted))
        unknown = []
        for san in cert['sans']:
            if not (san == row['apex'] or san.endswith('.' + row['apex'])):
                continue
            if san in row['hostnames'] or any(matches(san, p) for p in held):
                continue
            if benign_issuer and any(san == 'www.' + h or h == 'www.' + san for h in plain_hosts):
                auto_known[san] = ident  # auditable: certificate that justified it
                continue
            unknown.append(san)
        if unknown and not retry:
            findings.append(finding(row, 'ct-unknown-hostname', 'medium', ident, 'Unrecognised SANs: ' + ', '.join(unknown), cert))
    # Retain unfiled CT findings so a dry run cannot consume an operator alert.
    pending = (state or {}).get('pending', []) + findings
    state = {'certificates': dict(old, **certs), 'pending': pending, 'deferred_issuer_checks': deferred,
             'auto_known_sans': auto_known}
    private_save(path, state)
    info(('BASELINE CT: ' if baseline else 'OK CT: ') + row['apex'])
    return pending + unresolved, state


def caa_scan(row, state, config, policies):
    apex = row['apex']
    certs = (state or {}).get('certificates', {}).values()
    recent = [c for c in certs if timestamp(c['not_before']) >= RECENT]
    mapping = dict(CA_NAMES, **config.get('issuer_caa_map', {}))
    cas = sorted({ca for c in recent for ca, aliases in mapping.items()
                  if any(alias.lower() in c['issuer'].lower() for alias in aliases)})
    for cert in certs:
        for san in cert['sans']:
            name = san.removeprefix('*.')
            if name == apex or name.endswith('.' + apex):
                policy_for(name, apex, policies)
    recommendations = [f'{apex}. CAA 0 issue "{ca}"' for ca in cas]
    recommendations.append(f'{apex}. CAA 0 iodef "mailto:security@{apex}"')
    findings = []
    missing = []
    for name, policy in policies.items():
        if policy is None:
            findings.append(finding(row, 'caa-unknown', 'unknown', name, 'DNS lookup failed; not interpreted as missing CAA'))
        elif not policy:
            missing.append(name)
        else:
            for cert in certs:
                relevant = [s for s in cert['sans'] if s.removeprefix('*.') == name]
                if timestamp(cert['not_before']) <= NOW <= timestamp(cert['not_after']) and relevant:
                    if any(allowed(cert['issuer'], policy, s.startswith('*.'), config) is False for s in relevant):
                        key = hashlib.sha256(json.dumps([name, policy, cert['issuer']], sort_keys=True).encode()).hexdigest()[:20]
                        findings.append(finding(row, 'caa-blocks-active-issuer', 'high', key,
                                                'CAA on ' + name + ' blocks an active certificate issuer; review renewal requirements', cert,
                                                [record.replace(apex + '. CAA', name + '. CAA', 1) for record in recommendations]))
    if missing and not row.get('shared_parent'):  # customers cannot set CAA on a provider zone
        key = hashlib.sha256((apex + ':caa-missing').encode()).hexdigest()[:20]
        findings.append(finding(row, 'caa-missing', 'low', key,
                                'No CAA through apex for: ' + ', '.join(sorted(missing)) + '; review records and iodef address',
                                records=recommendations))
        findings[-1]['issuers'] = sorted({re.sub(r"[^A-Za-z0-9 .,'()&/-]", '', c['issuer'])[:80] for c in recent})
    return findings


def private_repo(slug):
    if not isinstance(slug, str) or not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', slug) or slug.lower() == 'marcusquinn/aidevops':
        return False
    # aidevops:trust-boundary — failures and non-PRIVATE visibility deny writes.
    try:
        return json.loads(command(['gh', 'repo', 'view', slug, '--json', 'visibility']))['visibility'] == 'PRIVATE'
    except (ValueError, KeyError, OSError, subprocess.SubprocessError):
        return False


def route(row, repos, fleet, config):
    names = [row['apex']] + row['hostnames']
    candidates = []
    for name in names:
        repo = fleet.get('site_repos', {}).get(name)
        if repo and '/' not in repo:
            owner = fleet.get('owner_exceptions', {}).get(name, fleet.get('owner'))
            repo = owner + '/' + repo if owner else None
        candidates.append(repo)
    candidates += [row['knowledge_repos'].get(n) for n in names]
    candidates += [r.get('slug') for r in repos if r.get('slug', '').split('/')[-1] in names]
    selected = next((c for c in candidates if c), config.get('fallback_repo'))
    if private_repo(selected):
        return selected
    fallback = config.get('fallback_repo')
    return fallback if private_repo(fallback) else None


def open_issues(slug):
    # A failed/incomplete dedup read must never become permission to write.
    pages = command(['gh', 'api', '--paginate', '--slurp', f'repos/{slug}/issues?state=open&per_page=100'])
    return [issue for page in json.loads(pages) for issue in page if 'pull_request' not in issue]


def marker_for(f):
    return f'<!-- aidevops:generator=cert-watch apex={f["apex"]} finding={f["kind"]} key={f["key"]} -->'


DIGEST_MARKER = '<!-- aidevops:generator=cert-watch digest=caa-missing -->'
SECTION_END = '<!-- /aidevops:cert-watch-section -->'
SECTION_RE = re.compile(r'<!-- aidevops:generator=cert-watch apex=(\S+) finding=caa-missing key=\S+ -->\n.*?\n'
                        + re.escape(SECTION_END), re.S)


def digest_section(f):
    issuers = ', '.join(f.get('issuers') or []) or 'none observed in the last 180 days'
    records = '\n'.join(f['recommended_records'])
    return f'''{marker_for(f)}
### {f['apex']}

Hostnames: {', '.join(f['hostnames'])}
Reason: {f['reason']}
CAs seen in certificates from the last 180 days: {issuers}

```text
{records}
```
{SECTION_END}'''


def digest_body(sections):
    return DIGEST_MARKER + '''
## Owner decision: add CAA records — no automatic remediation

Each section lists a domain with no CAA record and the records cert-watch proposes,
based on the CAs seen in Certificate Transparency over the last 180 days. Reply with
one decision: **approve all**, **approve** a listed subset, or **decline**. Do not
change DNS without that authorization; applying records is a separate step using
`dns-helper.sh help` to select the provider workflow. Confirm the iodef mailbox
before approving.

''' + '\n\n'.join(sections[k] for k in sorted(sections)) + '''

Repository source paths are unknown: this concerns live DNS configuration.
Re-run `cert-watch-helper.sh run` after authorized changes; fixed domains drop out
of this digest on the next full run. This is operator triage, not a worker brief.
'''


def private_write(args, text):
    fd, path = tempfile.mkstemp(dir=WORK / 'cert-watch', prefix='.issue-')
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(text)
        command(['bash', str(SCRIPT)] + [path if a is None else a for a in args], timeout=180)
    finally:
        os.unlink(path)


def file_digest(slug, entries, scanned_apexes, repos, fleet, config):
    """File or update ONE owner-decision issue for every apex missing CAA."""
    issues = open_issues(slug)
    existing = next((i for i in issues if DIGEST_MARKER in (i.get('body') or '')), None)
    sections = {}
    if existing and scanned_apexes is not None:  # retain only unscanned apexes on a --domain run
        sections.update({m.group(1): m.group(0) for m in SECTION_RE.finditer(existing.get('body') or '')
                         if m.group(1) not in scanned_apexes})
    sections.update({f['apex']: digest_section(f) for _, f in entries})
    if not sections:
        if existing:
            command(['bash', str(SCRIPT), '__close_issue', slug, str(existing['number']),
                     'No missing CAA findings remain after successful DNS reconciliation.'], timeout=180)
        return
    body = digest_body(sections)
    title = 'Cert watch: caa-missing digest — owner decision'
    if existing is None:
        private_write(['__file_issue', slug, title, None, 'low'], body)
        issues = open_issues(slug)
        existing = next((i for i in issues if DIGEST_MARKER in (i.get('body') or '')), None)
    elif (existing.get('body') or '') != body:
        private_write(['__edit_issue', slug, str(existing['number']), None], body)
    if existing is None or 'number' not in existing:
        return
    # Close legacy per-repo issues now represented in the digest (same trust boundary).
    legacy = {f'{marker_for(f)}' for _, f in entries}
    repo_slugs = {slug}
    for row, _ in entries:
        routed = route(row, repos, fleet, config)
        if routed:
            repo_slugs.add(routed)
    for repo in sorted(repo_slugs):
        try:
            candidates = issues if repo == slug else open_issues(repo)
        except (ValueError, OSError, subprocess.SubprocessError):
            info('INFO: legacy caa-missing scan skipped for one repository')
            continue
        for issue in candidates:
            text = issue.get('body') or ''
            if (repo == slug and issue.get('number') == existing['number']) or DIGEST_MARKER in text:
                continue
            if any(marker in text for marker in legacy):
                url = f'https://github.com/{slug}/issues/{existing["number"]}'
                command(['bash', str(SCRIPT), '__close_issue', repo, str(issue['number']),
                         'Superseded by the consolidated CAA owner-decision digest: ' + url], timeout=180)


def file_findings(row, findings, repos, fleet, config, digest=False):
    actionable = [f for f in findings if f['severity'] != 'unknown' and not (digest and f['kind'] == 'caa-missing')]
    if not actionable:
        return False
    slug = route(row, repos, fleet, config)
    if not slug:
        info('INFO: no verified private route; findings remain local')
        return False
    bodies = [issue.get('body') or '' for issue in open_issues(slug)]
    for f in actionable:
        marker = marker_for(f)
        if any(marker in body for body in bodies):
            continue
        cert = f['certificate']
        detail = json.dumps(cert, indent=2) if cert else 'Not applicable (CAA finding).'
        link = ('\nCertificate: https://crt.sh/?id=' + cert['id']) if cert else ''
        records = '\n'.join(f['recommended_records'])
        body = f'''{marker}
## Operator triage — no automatic remediation

Apex: {f['apex']}
Hostnames: {', '.join(f['hostnames'])}
Finding: {f['kind']} ({f['severity']})
Reason: {f['reason']}
{link}
```json
{detail}
```

## Next steps

Confirm ownership against the hosting/CDN certificate inventory. If this certificate
is not ours, request revocation from the issuing CA, review DNS and registrar access,
and add or tighten CAA. Do not revoke or change DNS without owner authorization.

Review proposed records (including the iodef mailbox and any missing issuer mappings):
```text
{records}
```
Use `dns-helper.sh help` to select the DNS provider and review its CAA workflow.
Repository source paths are unknown: this finding concerns live certificate/DNS
configuration. Verify with `cert-watch-helper.sh run` after authorized remediation.
This is operator triage, not a worker implementation brief.
'''
        fd, path = tempfile.mkstemp(dir=WORK / 'cert-watch', prefix='.issue-')
        try:
            with os.fdopen(fd, 'w') as stream:
                stream.write(body)
            command(['bash', str(SCRIPT), '__file_issue', slug,
                     f'Cert watch: {f["kind"]} — {f["apex"]}', path, f['severity']], timeout=180)
            bodies.append(body)
        finally:
            os.unlink(path)
    return True


def main():
    parser = argparse.ArgumentParser(description='Read-only CT/CAA monitoring; --apply files private operator issues only')
    parser.add_argument('command', nargs='?', choices=['domains', 'ct', 'caa', 'run'], default='run')
    parser.add_argument('--domain')
    parser.add_argument('--format', choices=['text', 'json'], default='text')
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    if args.apply and args.command != 'run':
        parser.error('--apply is only valid with run')
    os.umask(0o077)
    config = load(CONFIG / 'cert-watch.json', {}, private=True)
    rows, repos = inventory(config)
    if args.domain:
        name = hostname(args.domain)
        rows = [r for r in rows if r['apex'] == name or name in r['hostnames']]
        if not rows:
            rows = [{'apex': name, 'hostnames': [name], 'knowledge_repos': {}}]
            try:
                if ApexResolver(config).is_shared(name):
                    rows[0]['shared_parent'] = True
            except ValueError:
                pass  # no PSL: ad hoc names keep their own apex, as before
    if args.command == 'domains':
        output = rows
    else:
        directory = WORK / 'cert-watch'
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        if directory.is_symlink() or stat.S_IMODE(directory.stat().st_mode) != 0o700:
            raise ValueError('cert-watch state directory must be private (0700), not a symlink')
        output = []
        fleet = load(CONFIG / 'hosting-fleet.json', {}, private=True) if args.apply else {}
        last_fetch = [0]
        digest_slug = None
        digest_entries = []
        uncertain = set()
        if args.apply and config.get('fallback_repo') and private_repo(config['fallback_repo']):
            digest_slug = config['fallback_repo']  # one consolidated caa-missing issue
        with open(directory / '.lock', 'a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            for row in rows:
                info('DOMAIN: ' + row['apex'])
                path = directory / (row['apex'] + '.json')
                state = load(path, None, private=True)
                if state is not None and (not isinstance(state, dict)
                                          or not isinstance(state.get('certificates'), dict)
                                          or not isinstance(state.get('pending', []), list)
                                          or not isinstance(state.get('deferred_issuer_checks', {}), dict)):
                    raise ValueError('Invalid CT state schema; refusing to reset baseline')
                policies = {}
                for name in sorted(set(row['hostnames'] + [row['apex']])):
                    policy_for(name, row['apex'], policies)
                found = []
                if args.command in ('ct', 'run'):
                    found, state = ct_scan(row, state, path, config, policies, last_fetch)
                if args.command in ('caa', 'run'):
                    found += caa_scan(row, state, config, policies)
                output += found
                if args.apply:
                    filed = file_findings(row, found, repos, fleet, config, bool(digest_slug))
                    if filed and state and not any(f['kind'] == 'ct-unknown' for f in found):
                        state['pending'] = []
                        private_save(path, state)
                    if digest_slug:
                        digest_entries += [(row, f) for f in found if f['kind'] == 'caa-missing']
                        if any(f['kind'] == 'caa-unknown' for f in found):
                            uncertain.add(row['apex'])  # DNS failure is not proof a finding disappeared
            if digest_slug and args.command in ('caa', 'run'):
                # Confirmed findings are always delivered; only uncertain apexes keep their prior section.
                if args.domain:
                    scanned_apexes = {row['apex'] for row in rows} - uncertain
                else:
                    scanned_apexes = ({row['apex'] for row in rows} - uncertain) if uncertain else None
                file_digest(digest_slug, digest_entries, scanned_apexes, repos, fleet, config)
    if args.format == 'json':
        print(json.dumps(output, indent=2))
    else:
        for row in output:
            print(json.dumps(row, sort_keys=True))
    return 0


try:
    sys.exit(main())
except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError) as error:
    info('ERROR cert-watch: ' + str(error))
    sys.exit(1)
PY
