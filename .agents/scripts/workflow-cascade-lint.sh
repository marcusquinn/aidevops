#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# workflow-cascade-lint.sh — CI lint gate for cascade-vulnerable workflows (t2229)
#
# Scans .github/workflows/*.yml for the cascade-vulnerable combination:
#   1. Cascade-prone event types (labeled, unlabeled, assigned, etc.)
#      in trigger configuration
#   2. cancel-in-progress: true in any concurrency block
#   3. No mitigation (paths-ignore/paths filter, or job-level event-action guard)
#
# The vulnerability: events like `labeled` fire once per item. When
# `gh pr create --label "a,b,c,d"` runs, GitHub fires 4 separate `labeled`
# events. With `cancel-in-progress: true`, each new run cancels the
# previous, causing cascading cancellations (t2220 evidence: 15 cancelled
# + 2 success runs on PR #19704).
#
# Usage:
#   workflow-cascade-lint.sh [options] [file...]
#   workflow-cascade-lint.sh --dry-run
#   workflow-cascade-lint.sh --help
#
# If no files are given, scans all .github/workflows/*.yml in the repo.
#
# Options:
#   --dry-run          List vulnerable files without failing (exit 0)
#   --scan-dir <dir>   Directory to scan (default: .github/workflows)
#   --output-md <file> Write markdown report to <file>
#   -h, --help         Show usage and exit 0
#
# Exit codes:
#   0 — no vulnerable workflows found (or --dry-run)
#   1 — one or more vulnerable workflows found
#   2 — usage or environment error

set -uo pipefail

SCRIPT_NAME=$(basename "$0")

# --- Colour constants (guard pattern per shell-style-guide.md) -----------
if [[ -z "${RED+x}" ]]; then RED='\033[0;31m'; fi
if [[ -z "${GREEN+x}" ]]; then GREEN='\033[0;32m'; fi
if [[ -z "${YELLOW+x}" ]]; then YELLOW='\033[1;33m'; fi
if [[ -z "${NC+x}" ]]; then NC='\033[0m'; fi

# --- Cascade-prone event types -------------------------------------------
# These fire one trigger per item (each label added, each assignee, etc.)
CASCADE_TYPES_REGEX='(labeled|unlabeled|assigned|unassigned|review_requested|review_request_removed)'

# --- Globals -------------------------------------------------------------
DRY_RUN=false
SCAN_DIR=".github/workflows"
OUTPUT_MD=""
VULN_COUNT=0
VULN_FILES=()
VULN_DETAILS=()

# --- Helpers --------------------------------------------------------------
# Unified logger: _log <level> <message>
# Levels: info (plain), error, warn, ok
_log() {
    local _level="$1"
    local _text="$2"
    case "$_level" in
        error) printf "${RED}[ERROR]${NC} %s\n" "$_text" >&2 ;;
        warn)  printf "${YELLOW}[WARN]${NC} %s\n" "$_text" >&2 ;;
        ok)    printf "${GREEN}[OK]${NC} %s\n" "$_text" >&2 ;;
        *)     printf '%s\n' "$_text" >&2 ;;
    esac
    return 0
}

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [options] [file...]

Scan GitHub Actions workflow YAML files for cascade-vulnerable patterns.

Options:
  --dry-run          List findings without failing (exit 0)
  --scan-dir <dir>   Directory to scan (default: .github/workflows)
  --output-md <file> Write markdown report to <file>
  -h, --help         Show this help and exit

Exit codes:
  0 — clean (or --dry-run)
  1 — vulnerable workflow(s) found
  2 — usage/environment error
EOF
    return 0
}

# --- Extract the trigger section from on: to the next top-level key ------
# Outputs the trigger section (everything between ^on: and the next
# unindented key like permissions:, env:, jobs:, defaults:, etc.)
extract_trigger_section() {
    local _file="$1"
    local _in_trigger=false
    local _section=""

    while IFS= read -r line; do
        # Start of trigger section
        if [[ "$line" =~ ^on: ]] || [[ "$line" =~ ^\"on\": ]] || [[ "$line" =~ ^\'on\': ]]; then
            _in_trigger=true
            _section="${line}"
            continue
        fi

        if [[ "$_in_trigger" == true ]]; then
            # End of trigger section: next top-level key (no leading whitespace)
            if [[ "$line" =~ ^[a-zA-Z] ]] && [[ ! "$line" =~ ^[[:space:]] ]]; then
                break
            fi
            _section="${_section}"$'\n'"${line}"
        fi
    done < "$_file"

    printf '%s\n' "$_section"
    return 0
}

# --- Check if trigger section contains cascade-prone event types ---------
# Returns 0 if found, 1 if not.
# Only matches types within types: arrays, filtering out comments.
check_cascade_types() {
    local _trigger_section="$1"
    local _found_types=""

    # Filter out comment lines, then check for cascade types
    # within types: array context
    _found_types=$(printf '%s\n' "$_trigger_section" \
        | grep -v '^\s*#' \
        | grep -oE "\\b${CASCADE_TYPES_REGEX}\\b" \
        | sort -u || true)

    if [[ -n "$_found_types" ]]; then
        printf '%s\n' "$_found_types"
        return 0
    fi
    return 1
}

# --- Check if file has cancel-in-progress: true --------------------------
check_cancel_in_progress() {
    local _file="$1"

    # Match cancel-in-progress: true (ignoring comments)
    if grep -v '^\s*#' "$_file" | grep -qE 'cancel-in-progress:\s*true'; then
        return 0
    fi
    return 1
}

# --- Check if trigger section has paths-ignore or paths filter -----------
check_paths_filter() {
    local _trigger_section="$1"

    # Look for paths-ignore: or paths: in the trigger section (non-comment lines)
    if printf '%s\n' "$_trigger_section" \
        | grep -v '^\s*#' \
        | grep -qE '^\s+(paths-ignore|paths):'; then
        return 0
    fi
    return 1
}

# --- Check if any job has an if: guard on event.action -------------------
# Looks for job-level if: conditions that reference github.event.action
# (the standard mitigation pattern for labeled/unlabeled events).
check_action_guard() {
    local _file="$1"

    # Look for if: expressions referencing github.event.action
    if grep -v '^\s*#' "$_file" \
        | grep -qE 'if:.*github\.event\.action'; then
        return 0
    fi
    return 1
}

# --- Scan a single workflow file -----------------------------------------
scan_file() {
    local _file="$1"
    local _trigger_section=""
    local _cascade_types=""
    local _vuln_reason=""

    # Step 1: Extract trigger section
    _trigger_section=$(extract_trigger_section "$_file")
    if [[ -z "$_trigger_section" ]]; then
        return 0
    fi

    # Step 2: Check for cascade-prone event types in trigger
    _cascade_types=$(check_cascade_types "$_trigger_section") || return 0

    # Step 3: Check for cancel-in-progress: true
    if ! check_cancel_in_progress "$_file"; then
        return 0
    fi

    # Step 4: Check mitigations
    # 4a: paths-ignore or paths filter in trigger section
    if check_paths_filter "$_trigger_section"; then
        _log info "  MITIGATED (paths filter): $_file"
        return 0
    fi

    # 4b: Job-level if: guard on github.event.action
    if check_action_guard "$_file"; then
        _log info "  MITIGATED (event.action guard): $_file"
        return 0
    fi

    # No mitigation found — this is vulnerable
    _vuln_reason="cascade-prone types: $(printf '%s' "$_cascade_types" | tr '\n' ', ' | sed 's/,$//')"
    VULN_COUNT=$((VULN_COUNT + 1))
    VULN_FILES+=("$_file")
    VULN_DETAILS+=("$_vuln_reason")
    printf "${RED}VULN${NC} %s — %s\n" "$_file" "$_vuln_reason"
    return 0
}

# --- Write markdown report -----------------------------------------------
# Backticks in printf strings below are intentional markdown formatting
# (inline code spans), not command substitution.
write_report() {
    local _output_file="$1"
    local _marker="<!-- workflow-cascade-lint -->"

    # SC2016: backticks below are markdown code spans, not shell expansion
    # shellcheck disable=SC2016
    {
        printf '%s\n' "$_marker"
        printf '## Workflow Cascade Vulnerability Report\n\n'

        if [[ "$VULN_COUNT" -eq 0 ]]; then
            printf 'No cascade-vulnerable workflows found.\n'
        else
            printf '**%d workflow(s) have the cascade-vulnerable combination** of:\n' "$VULN_COUNT"
            printf '1. Cascade-prone event types (`labeled`, `unlabeled`, etc.) in triggers\n'
            printf '2. `cancel-in-progress: true` in a concurrency block\n'
            printf '3. No mitigation (`paths-ignore`/`paths` filter or job-level `event.action` guard)\n\n'

            printf '| File | Cascade Types |\n'
            printf '|------|---------------|\n'

            local _i
            for _i in "${!VULN_FILES[@]}"; do
                printf '| `%s` | %s |\n' "${VULN_FILES[$_i]}" "${VULN_DETAILS[$_i]}"
            done

            printf '\n### Remediation\n\n'
            printf 'For each vulnerable workflow, apply ONE of these mitigations:\n\n'
            printf '1. **Add `paths-ignore`** to the trigger to exclude docs-only changes:\n'
            printf '   ```yaml\n'
            printf '   on:\n'
            printf '     pull_request:\n'
            printf '       types: [opened, synchronize, reopened, labeled]\n'
            printf '       paths-ignore:\n'
            printf "         - '**/*.md'\n"
            printf "         - 'todo/**'\n"
            printf '   ```\n\n'
            printf '2. **Add a job-level `if:` guard** that exits early on label events:\n'
            printf '   ```yaml\n'
            printf '   jobs:\n'
            printf '     my-job:\n'
            printf "       if: github.event.action != 'labeled' || contains(github.event.pull_request.labels.*.name, 'my-override-label')\n"
            printf '   ```\n\n'
            printf '3. **Remove `cancel-in-progress: true`** if the workflow is fast enough.\n\n'
            printf 'To bypass this check for a specific PR, apply the `workflow-cascade-ok` label\n'
            printf 'AND add a `## Cascade Lint Justification` section to the PR description.\n'
        fi
    } > "$_output_file"

    return 0
}

# --- Main -----------------------------------------------------------------
main() {
    local _files=()

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        local _arg="$1"
        case "$_arg" in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --scan-dir)
                if [[ $# -lt 2 ]]; then
                    _log error "--scan-dir requires an argument"
                    return 2
                fi
                local _scan_dir_val="$2"
                SCAN_DIR="$_scan_dir_val"
                shift 2
                ;;
            --output-md)
                if [[ $# -lt 2 ]]; then
                    _log error "--output-md requires an argument"
                    return 2
                fi
                local _output_md_val="$2"
                OUTPUT_MD="$_output_md_val"
                shift 2
                ;;
            -h|--help)
                usage
                return 0
                ;;
            -*)
                _log error "Unknown option: $_arg"
                usage
                return 2
                ;;
            *)
                _files+=("$_arg")
                shift
                ;;
        esac
    done

    # If no files specified, scan the directory
    if [[ ${#_files[@]} -eq 0 ]]; then
        if [[ ! -d "$SCAN_DIR" ]]; then
            _log error "Scan directory not found: $SCAN_DIR"
            return 2
        fi
        # Collect all .yml files
        while IFS= read -r -d '' f; do
            _files+=("$f")
        done < <(find "$SCAN_DIR" -maxdepth 1 -name '*.yml' -print0 | sort -z)

        if [[ ${#_files[@]} -eq 0 ]]; then
            _log info "No workflow files found in $SCAN_DIR"
            return 0
        fi
    fi

    _log info "Scanning ${#_files[@]} workflow file(s) for cascade vulnerabilities..."

    local _f
    for _f in "${_files[@]}"; do
        if [[ ! -f "$_f" ]]; then
            _log warn "File not found: $_f (skipping)"
            continue
        fi
        scan_file "$_f"
    done

    # Write markdown report if requested
    if [[ -n "$OUTPUT_MD" ]]; then
        write_report "$OUTPUT_MD"
        _log info "Report written to $OUTPUT_MD"
    fi

    # Summary
    if [[ "$VULN_COUNT" -eq 0 ]]; then
        _log ok "No cascade-vulnerable workflows found."
        return 0
    fi

    _log info ""
    _log warn "${VULN_COUNT} cascade-vulnerable workflow(s) found."

    if [[ "$DRY_RUN" == true ]]; then
        _log info "(--dry-run: exiting 0 despite findings)"
        return 0
    fi

    return 1
}

main "$@"
