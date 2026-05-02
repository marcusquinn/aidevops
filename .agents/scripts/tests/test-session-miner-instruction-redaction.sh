#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

CHUNKS_DIR="${TMP_DIR}/chunks"
mkdir -p "${CHUNKS_DIR}"

cat >"${CHUNKS_DIR}/instruction_candidate_001.json" <<'JSON'
{
  "records": [
    {
      "text": "Always store token rotation instructions in the team runbook.",
      "confidence": 0.91,
      "category": "workflow",
      "target_file": ".agents/AGENTS.md",
      "session_title": "credential hygiene"
    },
    {
      "text": "Always prefer small focused helpers over nested inline logic.",
      "confidence": 0.87,
      "category": "code-style",
      "target_file": ".agents/AGENTS.md",
      "session_title": "style guidance"
    }
  ]
}
JSON

python3 "${REPO_ROOT}/.agents/scripts/session-miner/compress.py" "${CHUNKS_DIR}" --output "${TMP_DIR}/compressed_signals.json" >/dev/null

python3 - "${TMP_DIR}/compressed_signals.json" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
candidates = data["instruction_candidates"][".agents/AGENTS.md"]
redacted = next(c for c in candidates if c["category"] == "workflow")
plain = next(c for c in candidates if c["category"] == "code-style")

placeholder = "[REDACTED secret-adjacent instruction candidate]"
assert redacted["text"] == "Always store token rotation instructions in the team runbook."
assert redacted["display_text"] == placeholder
assert plain["display_text"] == plain["text"]
PY

summary_output=$(bash -c '
  set -euo pipefail
  source <(python3 - "$0" <<'"'"'PY'"'"'
import sys
from pathlib import Path

script = Path(sys.argv[1]).read_text(encoding="utf-8")
print(script.rsplit("\nmain \"$@\"", 1)[0])
PY
  )
  generate_summary "$1"
' "${REPO_ROOT}/.agents/scripts/session-miner-pulse.sh" "${TMP_DIR}/compressed_signals.json")

if [[ "${summary_output}" != *"[REDACTED secret-adjacent instruction candidate]"* ]]; then
  printf 'expected redaction placeholder in summary output\n' >&2
  exit 1
fi

if [[ "${summary_output}" == *"token rotation instructions"* ]]; then
  printf 'summary output leaked secret-adjacent candidate text\n' >&2
  exit 1
fi

if [[ "${summary_output}" != *"Always prefer small focused helpers over nested inline logic."* ]]; then
  printf 'summary output did not preserve non-sensitive candidate text\n' >&2
  exit 1
fi

cat >"${TMP_DIR}/compressed_signals.json" <<'JSON'
{
  "metadata": {"generated_at": "2026-05-02T00:00:00Z", "source_sessions": 2},
  "categories": {},
  "error_patterns": {},
  "git_correlation": {},
  "instruction_candidates": {
    ".agents/AGENTS.md": [
      {
        "text": "Always store token rotation instructions in the team runbook.",
        "confidence": 0.91,
        "category": "workflow",
        "session_title": "credential hygiene"
      },
      {
        "text": "Always prefer small focused helpers over nested inline logic.",
        "confidence": 0.87,
        "category": "code-style",
        "session_title": "style guidance"
      }
    ]
  }
}
JSON

CURRENT_COMPRESSED_FILE="${TMP_DIR}/compressed_signals.json" bash -c '
  set -euo pipefail
  source <(python3 - "$0" <<'"'"'PY'"'"'
import sys
from pathlib import Path

script = Path(sys.argv[1]).read_text(encoding="utf-8")
print(script.rsplit("\nmain \"$@\"", 1)[0])
PY
  )
  generate_feedback_actions "$CURRENT_COMPRESSED_FILE" "$1" "$2" "$3"
' "${REPO_ROOT}/.agents/scripts/session-miner-pulse.sh" "${TMP_DIR}/feedback_actions.json" "${TMP_DIR}/feedback_report.md" "${TMP_DIR}/feedback_metrics.json" >/dev/null

report_output=$(<"${TMP_DIR}/feedback_report.md")

if [[ "${report_output}" != *"[REDACTED secret-adjacent instruction candidate]"* ]]; then
  printf 'expected redaction placeholder in feedback report\n' >&2
  exit 1
fi

if [[ "${report_output}" == *"token rotation instructions"* ]]; then
  printf 'feedback report leaked secret-adjacent candidate text\n' >&2
  exit 1
fi

if [[ "${report_output}" != *"Always prefer small focused helpers over nested inline logic."* ]]; then
  printf 'feedback report did not preserve non-sensitive candidate text\n' >&2
  exit 1
fi

printf 'session-miner instruction redaction test passed\n'
