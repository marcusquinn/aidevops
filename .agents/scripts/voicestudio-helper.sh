#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Use a self-hosted VoiceStudio speech server from any project: text to speech,
# transcription, voice profiles, and the stdio MCP proxy the registry launches.
#
# The bearer key is injected from aidevops secrets (OMNIVOICE_API_KEY, or the
# name in VOICESTUDIO_SECRET) so it never appears in argv or agent context.
# Docs: tools/voice/voicestudio.md
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
CLIENT="${SCRIPT_DIR}/voicestudio_client.py"

usage() {
	cat <<'EOF'
Usage: voicestudio-helper.sh <command> [options]

Commands:
  status [--json]                     Health, auth and active engine
  voices [--json]                     Saved voice profiles (ids for --voice)
  speak --out FILE (--text T | --file F | stdin) [--voice ID] [--language CODE]
        [--instruct STYLE] [--speed N]
                                      Long text is split at sentences and joined
  transcribe AUDIO [--format json|text|srt|vtt] [--language CODE] [--out FILE]
  clone --name NAME --ref AUDIO [--ref-text TEXT] [--language CODE]
                                      Save a voice profile from 5-30 s of audio
  mcp                                 Stdio MCP proxy (used by the voicestudio agent)
  help                                This text; `<command> --help` for all options

Environment:
  VOICESTUDIO_URL     Server (default http://127.0.0.1:3900)
  VOICESTUDIO_SECRET  Secret name holding the key (default OMNIVOICE_API_KEY)

Store the key once: aidevops secret set OMNIVOICE_API_KEY
EOF
	return 0
}

run_client() {
	local python_bin="${PYTHON_BIN:-python3}"
	local aidevops_bin="${AIDEVOPS_BIN:-aidevops}"
	local secret_name="${VOICESTUDIO_SECRET:-OMNIVOICE_API_KEY}"

	command -v "$python_bin" >/dev/null 2>&1 || {
		printf 'voicestudio-helper.sh requires Python 3.9+\n' >&2
		return 1
	}
	[[ "$secret_name" =~ ^[A-Z][A-Z0-9_]*$ ]] || {
		printf 'VOICESTUDIO_SECRET must be an upper-case variable name\n' >&2
		return 1
	}
	export VOICESTUDIO_SECRET="$secret_name"

	# A key already in the environment wins; otherwise inject it from the store.
	# Without either, the client still works against an unauthenticated loopback server.
	if [[ -z "${!secret_name:-}" ]] && command -v "$aidevops_bin" >/dev/null 2>&1 &&
		"$aidevops_bin" secret check "$secret_name" >/dev/null 2>&1; then
		exec "$aidevops_bin" secret "$secret_name" -- "$python_bin" "$CLIENT" "$@"
	fi
	exec "$python_bin" "$CLIENT" "$@"
	return 1
}

main() {
	local command="${1:-help}"

	case "$command" in
	help | -h | --help)
		usage
		return 0
		;;
	status | voices | speak | transcribe | clone | mcp)
		run_client "$@"
		return $?
		;;
	*)
		printf 'Unknown command: %s\n\n' "$command" >&2
		usage >&2
		return 1
		;;
	esac
}

main "$@"
