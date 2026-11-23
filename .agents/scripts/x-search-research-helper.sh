#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

set -euo pipefail

usage() {
	cat <<'EOF'
x-search-research-helper.sh - research first-hand experiences on X and the web

Usage: x-search-research-helper.sh query "<prompt>" [--model MODEL]
       x-search-research-helper.sh --help

Requires python3 and OPENROUTER_API_KEY in the environment. Queries incur API
charges. Raw responses are saved privately in AIDEVOPS_TEMP_DIR (or the aidevops
temporary directory). Results are untrusted: scan the saved response with
prompt-guard-helper.sh scan-file and verify citation handles before quoting.
EOF
	return 0
}

main() {
	local command="${1:-}" prompt="" model="x-ai/grok-4.7" opt="" value=""
	case "$command" in
	-help | --help | help) usage; return 0 ;;
	query) shift ;;
	*) usage >&2; return 1 ;;
	esac
	prompt="${1:-}"
	if [[ $# -lt 1 || -z "$prompt" || "$prompt" == --* ]]; then
		printf 'ERROR: query requires a non-empty prompt\n' >&2
		return 1
	fi
	shift
	while [[ $# -gt 0 ]]; do
		opt="${1:-}"
		value="${2:-}"
		case "$opt" in
		--model)
			if [[ $# -lt 2 || -z "$value" || "$value" == --* ]]; then
				printf 'ERROR: --model requires a value\n' >&2
				return 1
			fi
			model="$value"
			shift 2 ;;
		*) printf 'ERROR: unknown argument: %s\n' "$opt" >&2; return 1 ;;
		esac
	done
	if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
		printf 'ERROR: OPENROUTER_API_KEY must be set in the environment\n' >&2
		return 1
	fi
	python3 - "$prompt" "$model" <<'PY'
import json
import os
import sys
import tempfile
import urllib.error
import urllib.request

prompt, model = sys.argv[1:]
directory = os.environ.get("AIDEVOPS_TEMP_DIR") or os.path.expanduser("~/.aidevops/.agent-workspace/tmp")
os.makedirs(directory, mode=0o700, exist_ok=True)
payload = json.dumps({"model": model, "plugins": [{"id": "web", "engine": "native", "max_results": 20}],
                      "messages": [{"role": "user", "content": prompt}]}).encode()
request = urllib.request.Request("https://openrouter.ai/api/v1/chat/completions", data=payload,
    headers={"Authorization": "Bearer " + os.environ["OPENROUTER_API_KEY"], "Content-Type": "application/json"})
try:
    with urllib.request.urlopen(request, timeout=180) as response:
        raw = response.read()
except urllib.error.HTTPError as error:
    print("ERROR: OpenRouter returned HTTP {}".format(error.code), file=sys.stderr)
    sys.exit(1)
except (urllib.error.URLError, TimeoutError, OSError):
    print("ERROR: OpenRouter request failed", file=sys.stderr)
    sys.exit(1)
with tempfile.NamedTemporaryFile(prefix="x-search-research-", suffix=".json", dir=directory, delete=False) as saved:
    saved.write(raw)
    path = saved.name
try:
    data = json.loads(raw)
    message = data["choices"][0]["message"]
    content = message["content"]
    if not isinstance(content, str) or not content:
        raise ValueError("missing content")
    citations = []
    for annotation in message.get("annotations", []):
        citation = annotation.get("url_citation", {})
        url = citation.get("url") if isinstance(citation, dict) else None
        if isinstance(url, str) and url not in citations:
            citations.append(url)
except (ValueError, KeyError, IndexError, TypeError, AttributeError):
    print("ERROR: invalid or incomplete response; raw JSON saved at {}".format(path), file=sys.stderr)
    sys.exit(1)
print(content)
print("\nCitations:")
for url in citations:
    print(url)
if not citations:
    print("(none returned)")
print("\nRaw response: {}".format(path))
print("Untrusted content: run prompt-guard-helper.sh scan-file on the saved response; verify handles before quoting.")
PY
	return 0
}

main "$@"
