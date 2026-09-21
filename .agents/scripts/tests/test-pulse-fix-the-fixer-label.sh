#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
DETECTOR="${SCRIPT_DIR}/../pulse-fix-the-fixer-detector.sh"
TEST_MODE="present"
CREATE_CALLS=0

# shellcheck source=../pulse-fix-the-fixer-detector.sh
source "$DETECTOR"

gh() {
	case "$1 $2" in
	"label list")
		case "$TEST_MODE" in
		present) printf '[{"name":"fix-the-fixer"}]\n' ;;
		missing) printf '[]\n' ;;
		failure) return 75 ;;
		esac
		return 0
		;;
	"label create")
		CREATE_CALLS=$((CREATE_CALLS + 1))
		return 0
		;;
	"issue edit") return 1 ;;
	esac
	return 1
}

TEST_MODE="present"
_ensure_fix_the_fixer_label "owner/repo"
[[ "$CREATE_CALLS" -eq 0 ]]

TEST_MODE="missing"
_ensure_fix_the_fixer_label "owner/repo"
[[ "$CREATE_CALLS" -eq 1 ]]

TEST_MODE="failure"
if _ensure_fix_the_fixer_label "owner/repo"; then
	printf 'expected label inspection failure to propagate\n' >&2
	exit 1
fi

TEST_MODE="present"
if _apply_label_and_comment "42" "owner/repo" "fixture"; then
	printf 'expected label application failure to propagate\n' >&2
	exit 1
fi

printf 'PASS fix-the-fixer label contract\n'
