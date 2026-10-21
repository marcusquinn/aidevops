#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
source "$SCRIPT_DIR/shared-constants.sh"

print_usage() {
	printf '%s\n' 'Usage: tls-trust-helper.sh local [--canary ID] [--format text|json]' \
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

main() {
	local command="${1:-local}"
	[[ $# -eq 0 ]] || shift
	case "$command" in
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
