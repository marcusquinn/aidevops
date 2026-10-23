#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Bash 3.2 entrypoint; Python 3 handles untrusted JSON without shell evaluation.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

cert_watch_file_issue() {
	local slug="$1"
	local title="$2"
	local body_file="$3"
	local priority="$4"
	local visibility=""
	# aidevops:trust-boundary — independently recheck immediately before writes.
	slug=$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')
	[[ "$slug" =~ ^[a-z0-9_.-]+/[a-z0-9_.-]+$ ]] || return 1
	[[ "$slug" != marcusquinn/aidevops ]] || return 1
	visibility=$(gh repo view "$slug" --json visibility --jq '.visibility') || return 1
	[[ "$visibility" == PRIVATE ]] || return 1
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

if [[ "${1:-}" == __file_issue ]]; then
	shift
	cert_watch_file_issue "$@"
	exit $?
fi

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


class ApexResolver:
    """Use the system PSL, or an operator-supplied PSL; never guess co.uk etc."""
    def __init__(self, config):
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
        unknown = [san for san in cert['sans'] if (san == row['apex'] or san.endswith('.' + row['apex']))
                   and san not in row['hostnames'] and not any(matches(san, p) for p in held)]
        if unknown and not retry:
            findings.append(finding(row, 'ct-unknown-hostname', 'medium', ident, 'Unrecognised SANs: ' + ', '.join(unknown), cert))
    # Retain unfiled CT findings so a dry run cannot consume an operator alert.
    pending = (state or {}).get('pending', []) + findings
    state = {'certificates': dict(old, **certs), 'pending': pending, 'deferred_issuer_checks': deferred}
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
    if missing:
        key = hashlib.sha256((apex + ':caa-missing').encode()).hexdigest()[:20]
        findings.append(finding(row, 'caa-missing', 'low', key,
                                'No CAA through apex for: ' + ', '.join(sorted(missing)) + '; review records and iodef address',
                                records=recommendations))
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


def file_findings(row, findings, repos, fleet, config):
    actionable = [f for f in findings if f['severity'] != 'unknown']
    if not actionable:
        return False
    slug = route(row, repos, fleet, config)
    if not slug:
        info('INFO: no verified private route; findings remain local')
        return False
    # A failed/incomplete dedup read must never become permission to create issues.
    pages = command(['gh', 'api', '--paginate', '--slurp', f'repos/{slug}/issues?state=open&per_page=100'])
    bodies = [issue.get('body') or '' for page in json.loads(pages) for issue in page if 'pull_request' not in issue]
    for f in actionable:
        marker = f'<!-- aidevops:generator=cert-watch apex={f["apex"]} finding={f["kind"]} key={f["key"]} -->'
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
                    filed = file_findings(row, found, repos, fleet, config)
                    if filed and state and not any(f['kind'] == 'ct-unknown' for f in found):
                        state['pending'] = []
                        private_save(path, state)
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
