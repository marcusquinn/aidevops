#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
source "$SCRIPT_DIR/shared-constants.sh"

print_usage() {
	printf '%s\n' 'Usage: tls-trust-helper.sh local [--canary ID] [--format text|json]' \
		'       tls-trust-helper.sh fleet [--target NAME] [--format text|json]' \
		'       tls-trust-helper.sh probe-script' \
		'Read-only TLS checks. Exit: 0 no TRUSTED clients, 2 exposed, 1 usage error.'
	return 0
}

# This is the sole implementation of client classification, used locally and remotely.
# Optional arguments select a client and executable; without them choose the first present.
cmd_probe_script() {
	cat <<'PROBE'
#!/bin/sh
url=${1:-}
client=${2:-}
bin=${3:-$client}
case "$url" in
https://*) ;;
*) printf '%s\n' 'none UNKNOWN'; exit 0 ;;
esac
if [ -z "$client" ]; then
    for candidate in curl node python3 wget; do
        if command -v "$candidate" >/dev/null 2>&1; then
            client=$candidate
            bin=$candidate
            break
        fi
    done
fi
result=UNKNOWN
case "$client" in
curl)
    # Ignore curlrc: it may change verification, timeouts, output or HTTP semantics.
    "$bin" -q --silent --output /dev/null --connect-timeout 15 --max-time 15 "$url" 2>/dev/null
    code=$?
    case "$code" in
        0) result=TRUSTED ;;
        60|35|51|77) result=REJECTED ;;
    esac
    ;;
node)
    result=$("$bin" - "$url" 2>/dev/null <<'NODE'
const https = require('https');
const finish = result => { console.log(result); process.exit(0); };
setTimeout(() => finish('UNKNOWN'), 15000);
try {
  https.get(process.argv[2], response => finish('TRUSTED')).on('error', error => {
    const code = error.code || '';
    const certificateErrors = ['UNABLE_TO_GET_ISSUER_CERT_LOCALLY',
      'DEPTH_ZERO_SELF_SIGNED_CERT', 'UNABLE_TO_VERIFY_LEAF_SIGNATURE',
      'ERR_TLS_CERT_ALTNAME_INVALID', 'INVALID_PURPOSE'];
    finish(certificateErrors.includes(code) ||
      code.startsWith('CERT_') || code.startsWith('SELF_SIGNED_') ? 'REJECTED' : 'UNKNOWN');
  });
} catch (_) { finish('UNKNOWN'); }
NODE
    )
    ;;
python3)
    result=$("$bin" - "$url" 2>/dev/null <<'PYTHON'
import signal
import ssl
import sys
import urllib.error
import urllib.request

def timed_out(signum, frame):
    raise TimeoutError()

try:
    signal.signal(signal.SIGALRM, timed_out)
    signal.alarm(15)
    # Do not follow redirects: the canary's TLS handshake is the observation.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None
    opener = urllib.request.build_opener(NoRedirect)
    with opener.open(sys.argv[1], timeout=15):
        print('TRUSTED')
except urllib.error.HTTPError:
    print('TRUSTED')
except ssl.SSLCertVerificationError:
    print('REJECTED')
except urllib.error.URLError as error:
    print('REJECTED' if isinstance(error.reason, ssl.SSLCertVerificationError) else 'UNKNOWN')
except Exception:
    print('UNKNOWN')
PYTHON
    )
    ;;
php)
    result=$("$bin" -r '
if (!function_exists("curl_init")) { echo "UNKNOWN\n"; exit(0); }
$handle = curl_init($argv[1]);
curl_setopt($handle, CURLOPT_TIMEOUT, 15);
curl_setopt($handle, CURLOPT_CONNECTTIMEOUT, 15);
curl_setopt($handle, CURLOPT_WRITEFUNCTION, static function ($handle, $data) { return strlen($data); });
$ok = curl_exec($handle);
$error = curl_errno($handle);
echo ($error === 60 ? "REJECTED" : ($ok !== false ? "TRUSTED" : "UNKNOWN")), "\n";
' "$url" 2>/dev/null)
    ;;
# wget is unsupported; in particular BusyBox cannot attest certificate rejection.
esac
case "$result" in TRUSTED|REJECTED|UNKNOWN) ;; *) result=UNKNOWN ;; esac
printf '%s %s\n' "${client:-none}" "$result"
PROBE
	return 0
}

remediation_hint() {
	local client="$1"
	local bin="$2"
	local incident="$3"
	local node_prefix
	if [[ "$client" == node ]] && command -v brew >/dev/null 2>&1; then
		node_prefix=$(brew --prefix node 2>/dev/null || true)
		if [[ -n "$node_prefix" && "$bin" -ef "$node_prefix/bin/node" ]]; then
			printf '%s' 'brew upgrade ca-certificates node'
			return 0
		fi
	fi
	case "$client:$bin" in
	node:*brew* | node:/usr/local/Cellar/*)
		printf '%s' 'brew upgrade ca-certificates node'
		;;
	node:*) printf '%s' 'Upgrade Node, or use --use-openssl-ca plus SSL_CERT_FILE pointing to a patched CA bundle (not --use-system-ca)' ;;
	curl:/usr/bin/curl)
		if [[ "$(uname -s)" == Darwin ]]; then
			printf 'Apple curl trust store: see %s' "$incident"
		else
			printf '%s' 'Update system ca-certificates and curl'
		fi
		;;
	curl:*brew* | curl:*/opt/curl/*) printf '%s' 'brew upgrade ca-certificates curl' ;;
	python3:*) printf '%s' 'Update Python and its configured CA bundle; system updates may not cover bundled stores' ;;
	php:*) printf '%s' 'Update PHP curl CA bundle; on shared hosting request the host-controlled update' ;;
	*) printf 'Update this client and its CA bundle; see %s' "$incident" ;;
	esac
	return 0
}

cmd_local() {
	local selected='' format=text
	while [[ $# -gt 0 ]]; do
		local option="$1"
		local value="${2:-}"
		case "$option" in
		--canary | --format)
			[[ $# -ge 2 && -n "$value" ]] || {
				print_usage >&2
				return 1
			}
			if [[ "$option" == --canary ]]; then selected="$value"; else format="$value"; fi
			shift 2
			;;
		*)
			print_usage >&2
			return 1
			;;
		esac
	done
	[[ "$format" == text || "$format" == json ]] || {
		print_usage >&2
		return 1
	}
	if [[ "$format" == json ]] && ! command -v jq >/dev/null 2>&1; then
		printf '%s\n' 'JSON output requires jq' >&2
		return 1
	fi
	local clients=() bins=() path prefix client
	if [[ -x /usr/bin/curl ]]; then
		clients+=(curl)
		bins+=(/usr/bin/curl)
	fi
	for client in curl node python3 php wget; do
		path=$(command -v "$client" || true)
		if [[ -n "$path" ]]; then
			clients+=("$client")
			bins+=("$path")
		fi
	done
	if command -v brew >/dev/null 2>&1; then
		prefix=$(brew --prefix 2>/dev/null || true)
		if [[ -n "$prefix" && -x "$prefix/opt/curl/bin/curl" ]]; then
			clients+=(curl)
			bins+=("$prefix/opt/curl/bin/curl")
		fi
	fi
	local config="$SCRIPT_DIR/../configs/tls-trust-canaries.conf"
	local id url incident added extra found=0 exposed=0 i result hint rows='' row
	[[ -r "$config" ]] || {
		printf '%s\n' 'Cannot read canary config' >&2
		return 1
	}
	# Validate the entire input before issuing any probes or partial JSON.
	while IFS='|' read -r id url incident added extra || [[ -n "$id" ]]; do
		[[ -z "$id" || "$id" == \#* ]] && continue
		if [[ ! "$id" =~ ^[a-zA-Z0-9._-]+$ || "$url" != https://* || "$incident" != https://* || -z "$added" || -n "$extra" ]]; then
			printf '%s\n' 'Invalid canary config row' >&2
			return 1
		fi
		[[ -z "$selected" || "$selected" == "$id" ]] && found=1
	done <"$config"
	[[ "$found" == 1 ]] || {
		printf '%s\n' 'No matching canary' >&2
		return 1
	}
	while IFS='|' read -r id url incident added extra || [[ -n "$id" ]]; do
		[[ -z "$id" || "$id" == \#* ]] && continue
		[[ -z "$selected" || "$selected" == "$id" ]] || continue
		for ((i = 0; i < ${#clients[@]}; i++)); do
			result=$(cmd_probe_script | sh -s -- "$url" "${clients[i]}" "${bins[i]}")
			result=${result##* }
			hint=''
			if [[ "$result" == TRUSTED ]]; then
				exposed=1
				hint=$(remediation_hint "${clients[i]}" "${bins[i]}" "$incident")
			fi
			if [[ "$format" == json ]]; then
				row=$(jq -cn --arg client "${clients[i]}" --arg executable "${bins[i]}" \
					--arg canary "$id" --arg url "$url" --arg incident "$incident" \
					--arg result "$result" --arg remediation "$hint" \
					'{client:$client,executable:$executable,canary:$canary,url:$url,incident:$incident,result:$result,remediation:$remediation}')
				rows+="$row"$'\n'
			else
				printf '%s (%s) %s %s\n' "${clients[i]}" "${bins[i]}" "$id" "$result"
				[[ -z "$hint" ]] || printf '  Next: %s\n' "$hint"
			fi
		done
	done <"$config"
	if [[ "$format" == json ]]; then printf '%s' "$rows" | jq -s '.'; fi
	if [[ "$exposed" == 1 ]]; then return 2; fi
	return 0
}

# Python handles inventory JSON and SSH argument quoting; the TLS probe stays shared.
cmd_fleet() {
	if ! command -v python3 >/dev/null 2>&1; then
		printf '%s\n' 'Fleet checks require python3' >&2
		return 1
	fi
	python3 - "$SCRIPT_DIR" "$@" <<'FLEET'
import argparse
import collections
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys

class FleetParser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        print(message, file=sys.stderr)
        sys.exit(1)

parser = FleetParser(description='Read-only inventoried SSH TLS probes')
parser.add_argument('--target')
parser.add_argument('--format', choices=('text', 'json'), default='text')
script_dir = Path(sys.argv[1])
args = parser.parse_args(sys.argv[2:])

def load_inventory(path):
    if not path.exists():
        print('INFO: skipping absent inventory ' + path.name, file=sys.stderr)
        return {}
    with path.open() as handle:
        return json.load(handle)

def fail(message):
    print(message, file=sys.stderr)
    sys.exit(1)

try:
    home = Path.home()
    cloudron = load_inventory(home / '.cloudron.json')
    remote = load_inventory(home / '.config/aidevops/remote-hosts.json')
    inventory = load_inventory(home / '.config/aidevops/site-inventory.json')
    canaries = []
    for line in (script_dir / '../configs/tls-trust-canaries.conf').read_text().splitlines():
        if not line or line.startswith('#'):
            continue
        fields = line.split('|')
        if (len(fields) != 4 or not re.fullmatch(r'[a-zA-Z0-9._-]+', fields[0])
                or not fields[1].startswith('https://')
                or not fields[2].startswith('https://') or not fields[3]):
            fail('Invalid canary config row')
        canaries.append(fields)
except (OSError, ValueError):
    fail('Cannot read inventory or canary configuration')
if not canaries:
    fail('No canaries configured')

targets = []
for name, entry in cloudron.get('servers', {}).items():
    targets.append((name, entry.get('ip') or entry.get('domain'),
                    entry.get('ssh_user', 'root'), entry.get('ssh_port', 22), []))
for name, entry in remote.get('hosts', {}).items():
    if entry.get('transport', 'ssh') == 'ssh':
        targets.append((name, entry.get('address'), entry.get('user', ''),
                        entry.get('port', entry.get('ssh_port', 22)), []))
for name, entry in inventory.get('hosting_accounts', {}).items():
    paths = []
    for site in inventory.get('sites', {}).values():
        hosting = site.get('hosting', {})
        if hosting.get('account_ref') == name and hosting.get('deployment_path'):
            paths.append(hosting['deployment_path'])
        if hosting.get('account_ref') == name:
            for child in site.get('children', {}).values():
                if child.get('deployment_path'):
                    paths.append(child['deployment_path'])
    targets.append((name, entry.get('ssh_host'), entry.get('ssh_user', ''),
                    entry.get('ssh_port', 22), sorted(set(paths))))
if args.target:
    targets = [target for target in targets if target[0] == args.target]
    if not targets:
        fail('Target is not in an inventory')

probe = subprocess.check_output(['bash', str(script_dir / 'tls-trust-helper.sh'),
                                 'probe-script'], text=True)
# No remote temporary files: the same probe body is piped to host/container shells.
remote_script = r'''
emit() {
    printf 'TLSROW'
    for emit_field do
        printf '\t%s' "$emit_field"
    done
    printf '\n'
    return 0
}
for client in curl node python3 wget; do
    if command -v "$client" >/dev/null 2>&1; then
        answer=$(printf '%s\n' "$probe" | sh -s -- "$url" "$client" "$client")
        emit host "$client" "$client" "${answer##* }" ''
    fi
done
printf 'PKG\tinstalled\t%s\n' "$(dpkg-query -W -f='${Version}' ca-certificates 2>/dev/null)"
policy=$(apt-cache policy ca-certificates 2>/dev/null)
printf '%s\n' "$policy" | while IFS= read -r line; do
    printf 'POLICY\t%s\n' "$line"
done
versions=$(printf '%s\n' "$policy" | awk '
    { split($0, fields) }
    fields[1] == "***" { version=fields[2]; next }
    NF == 2 && fields[2] ~ /^[0-9]+$/ { version=fields[1]; next }
    /https?:\/\// && version != "" {
        if ($0 ~ /https?:\/\/security\.ubuntu\.com\// && $0 ~ /-security\//) print "security", version;
        else if ($0 !~ /security\.ubuntu\.com/) print "mirror", version;
    }')
mirrors=$(printf '%s\n' "$versions" | awk '{ split($0, fields); if (fields[1] == "mirror") print fields[2] }')
printf '%s\n' "$versions" | while read -r pocket version; do
    [ "$pocket" = security ] && [ -n "$mirrors" ] || continue
    lag=yes
    for mirror in $mirrors; do
        dpkg --compare-versions "$version" gt "$mirror" 2>/dev/null || lag=no
    done
    [ "$lag" != yes ] || printf 'MIRROR-LAG\n'
done
if command -v docker >/dev/null 2>&1 && docker ps >/dev/null 2>&1; then
    docker ps --format '{{.ID}} {{.Image}} {{.Names}}' | while read -r id image name; do
        # Prefer Node in Node-derived images, whose bundled store differs from curl.
        answer=$(printf '%s\n' "$probe" | docker exec -i "$id" sh -c '
            canary_url=${1:-}
            if command -v node >/dev/null 2>&1; then
                exec sh -s -- "$canary_url" node node
            else
                exec sh -s -- "$canary_url"
            fi' sh "$url" 2>/dev/null) || answer='none UNKNOWN'
        emit container-image "$image" "${answer%% *}" "${answer##* }" "$id:$name"
    done
else
    emit container-image unavailable none UNKNOWN 'Docker unavailable without elevated permissions'
fi
php_found=no
for bin in /opt/alt/php*/usr/bin/php "$(command -v php 2>/dev/null)"; do
    [ -x "$bin" ] || continue
    php_found=yes
    "$bin" -r "$php_probe" "$url" "$bin" 2>/dev/null || emit php-binary "$bin" php UNKNOWN 'PHP probe unavailable'
done
[ "$php_found" = yes ] || emit php-binary unavailable php UNKNOWN 'No PHP binary available'
root_flag=''
[ "$(id -u)" != 0 ] || root_flag=--allow-root
for path do
    if [ ! -f "$path/wp-config.php" ]; then
        emit wp-site "$path" wp UNKNOWN 'No readable wp-config.php'
        continue
    fi
    hash=$(sha256sum "$path/wp-includes/certificates/ca-bundle.crt" 2>/dev/null)
    hash=${hash%% *}
    answer=$(TLS_TRUST_CANARY="$url" wp ${root_flag:+"$root_flag"} --path="$path" eval "$wp_probe" 2>/dev/null) || answer=UNKNOWN
    case "$answer" in TRUSTED|REJECTED|BLOCKED-OUTBOUND) ;; *) answer=UNKNOWN ;; esac
    emit wp-site "$path" wp "$answer" "$hash"
done
printf 'TLSEND\n'
'''
php_probe = r'''
function row($client, $result, $details) {
    echo "TLSROW\tphp-binary\t", $GLOBALS['argv'][2], "\t", $client, "\t", $result, "\t", json_encode($details), "\n";
}
$ini = ini_get_all();
$curlAccess = $ini['curl.cainfo']['access'] ?? null;
$streamAccess = $ini['openssl.cafile']['access'] ?? null;
$result = 'UNKNOWN';
if (function_exists('curl_init')) {
    $ch = curl_init($argv[1]);
    curl_setopt($ch, CURLOPT_TIMEOUT, 15);
    curl_setopt($ch, CURLOPT_CONNECTTIMEOUT, 15);
    curl_setopt($ch, CURLOPT_WRITEFUNCTION, static function ($ch, $data) { return strlen($data); });
    $ok = curl_exec($ch);
    $result = curl_errno($ch) === 60 ? 'REJECTED' : ($ok !== false ? 'TRUSTED' : 'UNKNOWN');
}
$hint = '';
if ($result === 'TRUSTED' && $curlAccess === 4) {
    $result = 'HOST-CONTROLLED';
    $hint = 'ask the host to update the system CA store';
}
row('curl', $result, ['curl.cainfo_access' => $curlAccess, 'hint' => $hint]);
$context = stream_context_create(['http' => ['timeout' => 15, 'follow_location' => 0, 'ignore_errors' => true]]);
error_clear_last();
$ok = @file_get_contents($argv[1], false, $context);
$error = error_get_last()['message'] ?? '';
$result = $ok !== false ? 'TRUSTED' : (preg_match('/certificate|SSL operation failed/i', $error) ? 'REJECTED' : 'UNKNOWN');
$hint = $result === 'TRUSTED' && $streamAccess === 2 ? 'per-site .user.ini openssl.cafile=<patched bundle> fixes streams only' : '';
row('streams', $result, ['openssl.cafile_access' => $streamAccess, 'hint' => $hint]);
'''
wp_probe = r'''
$url = getenv('TLS_TRUST_CANARY');
// Identify policy/plugin short-circuits before treating certificate text as TLS evidence.
$http = new WP_Http();
if ($http->block_request($url)) { echo 'BLOCKED-OUTBOUND'; return; }
$blocked = false;
add_filter('pre_http_request', static function ($pre) use (&$blocked) {
    if ($pre !== false) { $blocked = true; }
    return $pre;
}, PHP_INT_MAX, 3);
$response = wp_remote_get($url, ['timeout' => 15, 'redirection' => 0]);
echo $blocked ? 'BLOCKED-OUTBOUND' : (is_wp_error($response)
    ? (preg_match('/SSL|certificate/i', $response->get_error_message()) ? 'REJECTED' : 'UNKNOWN')
    : 'TRUSTED');
'''
rows = []
allowed = {'TRUSTED', 'REJECTED', 'UNKNOWN', 'HOST-CONTROLLED', 'BLOCKED-OUTBOUND'}
for name, host, user, port, paths in targets:
    # Reject option-like destinations, control characters and malformed inventory data.
    valid = (isinstance(host, str) and re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9.:%_-]*', host)
             and isinstance(user, str) and re.fullmatch(r'[a-zA-Z0-9_.-]*', user)
             and str(port).isdigit() and 0 < int(port) < 65536
             and all(isinstance(p, str) and not any(c in p for c in '\r\n\t\0') for p in paths))
    for canary, url, incident, _ in canaries:
        base = dict(target=name, canary=canary, url=url, incident=incident)
        def unknown(reason):
            rows.append(dict(base, layer='host', artifact='ssh', client='none',
                             result='UNKNOWN', details=reason))
        if not valid:
            unknown('Invalid inventory SSH fields')
            continue
        payload = ('probe=' + shlex.quote(probe) + '\nurl=' + shlex.quote(url)
                   + '\nphp_probe=' + shlex.quote(php_probe)
                   + '\nwp_probe=' + shlex.quote(wp_probe) + '\n' + remote_script)
        destination = (user + '@' if user else '') + host
        command = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15',
                   '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=2',
                   '-p', str(port), destination,
                   'sh -s -- ' + ' '.join(shlex.quote(p) for p in paths)]
        try:
            # Per-target budget bounds fleets with broken CLI tools or very many artifacts.
            completed = subprocess.run(command, input=payload, text=True, stdout=subprocess.PIPE,
                                       stderr=subprocess.DEVNULL, timeout=240)
            output = completed.stdout
        except (OSError, subprocess.TimeoutExpired):
            unknown('SSH unavailable or target probe budget exceeded')
            continue
        package = {'installed': 'UNKNOWN', 'candidate': 'UNKNOWN',
                   'mirror_lag': 'MIRROR-LAG' in output.splitlines()}
        policy = []
        target_rows = []
        for line in output.splitlines():
            if line.startswith('PKG\tinstalled\t'):
                package['installed'] = line.split('\t', 2)[2] or 'UNKNOWN'
            elif line.startswith('POLICY\t'):
                policy.append(line.split('\t', 1)[1])
            elif line.startswith('TLSROW\t'):
                fields = line.split('\t', 5)
                if len(fields) != 6 or fields[4] not in allowed:
                    continue
                _, layer, artifact, client, result, details = fields
                if layer not in ('host', 'container-image', 'wp-site', 'php-binary'):
                    continue
                if layer == 'php-binary':
                    try:
                        details = json.loads(details)
                    except ValueError:
                        pass
                row = dict(base, layer=layer, artifact=artifact, client=client,
                           result=result, details=details)
                if layer == 'container-image' and client == 'node' and result == 'TRUSTED':
                    row['remediation'] = 'Use --use-openssl-ca plus SSL_CERT_FILE pointing to a patched bundle (not --use-system-ca)'
                target_rows.append(row)
        version = None
        security_versions, mirror_versions = set(), set()
        for line in policy:
            match = re.search(r'Candidate:\s*(\S+)', line)
            if match:
                package['candidate'] = match[1]
            match = re.match(r'\s*(?:\*\*\*\s+)?(\S+)\s+\d+\s*$', line)
            if match:
                version = match[1]
            elif version and re.search(r'https?://', line):
                if 'security.ubuntu.com' in line and re.search(r'\S+-security/', line):
                    security_versions.add(version)
                elif 'security.ubuntu.com' not in line:
                    mirror_versions.add(version)
        package['security_versions'] = sorted(security_versions)
        package['mirror_versions'] = sorted(mirror_versions)
        for row in target_rows:
            if row['layer'] == 'host':
                row['ca_certificates'] = package
        rows.extend(target_rows)
        if completed.returncode != 0 or 'TLSEND' not in output.splitlines():
            unknown('SSH failed or remote probe incomplete')
        elif not any(row['layer'] == 'host' for row in target_rows):
            unknown('No supported host TLS client')

# Preserve every observation but present identical image/bundle results only once.
grouped = {}
for row in rows:
    key = None
    if row['layer'] == 'container-image':
        key = (row['target'], row['canary'], row['layer'], row['artifact'], row['client'])
    elif row['layer'] == 'wp-site' and re.fullmatch(r'[a-fA-F0-9]{64}', row['details']):
        key = (row['target'], row['canary'], row['layer'], row['details'])
    if key is None:
        key = ('unique', len(grouped))
    if key in grouped:
        group = grouped[key]
        group.setdefault('observations', []).append(row)
        # Never hide exposure or uncertainty behind a rejecting sibling artifact.
        priority = {'TRUSTED': 5, 'UNKNOWN': 4, 'HOST-CONTROLLED': 3, 'BLOCKED-OUTBOUND': 2, 'REJECTED': 1}
        if priority[row['result']] > priority[group['result']]:
            group['result'] = row['result']
            if row.get('remediation'):
                group['remediation'] = row['remediation']
    else:
        grouped[key] = dict(row, observations=[row]) if row['layer'] in ('container-image', 'wp-site') else row
rows = list(grouped.values())
if args.format == 'json':
    print(json.dumps(rows, indent=2))
else:
    for row in rows:
        print('{target} {layer} {artifact} {client} {canary} {result}'.format(**row))
        print('  ' + json.dumps(row.get('details', '')))
        if row.get('remediation'):
            print('  ' + row['remediation'])
        if 'ca_certificates' in row:
            print('  ca-certificates ' + json.dumps(row['ca_certificates'])
                  + (' MIRROR-LAG' if row['ca_certificates']['mirror_lag'] else ''))
summary = collections.Counter(row['result'] for row in rows)
print('INFO: summary ' + json.dumps(dict(summary), sort_keys=True), file=sys.stderr)
sys.exit(2 if any(row['result'] == 'TRUSTED' for row in rows) else 0)
FLEET
	return $?
}

main() {
	local command="${1:-local}"
	[[ $# -eq 0 ]] || shift
	case "$command" in
	fleet)
		cmd_fleet "$@"
		return $?
		;;
	local)
		cmd_local "$@"
		return $?
		;;
	probe-script)
		[[ $# -eq 0 ]] || return 1
		cmd_probe_script
		;;
	help | --help | -h) print_usage ;;
	*)
		print_usage >&2
		return 1
		;;
	esac
	return 0
}

main "$@"
