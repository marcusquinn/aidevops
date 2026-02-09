#!/usr/bin/env bash
# shellcheck disable=SC2034
# verify-run-helper.sh - Execute verification checks and log proof
# Part of aidevops framework: https://aidevops.sh
#
# Usage:
#   verify-run-helper.sh run <vNNN>          Run checks for a single entry
#   verify-run-helper.sh run --pending       Run all pending verifications
#   verify-run-helper.sh run --all           Re-run all verifications
#   verify-run-helper.sh log [vNNN]          Show verify-proof-log (optionally filtered)
#   verify-run-helper.sh log --last N        Show last N log entries
#   verify-run-helper.sh help                Show this help
#
# Check directives supported:
#   file-exists <path>                       Test file exists
#   rg "pattern" <path>                      Ripgrep pattern match (count matches)
#                                            Note: \| in patterns auto-normalized to | (grep→rg compat)
#   ShellCheck <path>                        Run ShellCheck -x -S warning on script
#   bash <path>                              Run test script, capture summary
#
# Output:
#   Appends structured proof to todo/verify-proof-log.md
#   Updates VERIFY.md entry status ([x] or [!]) based on results

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Logging
C_GREEN="\033[0;32m"
C_RED="\033[0;31m"
C_YELLOW="\033[1;33m"
C_BLUE="\033[0;34m"
C_NC="\033[0m"

log_info()  { echo -e "${C_BLUE}[VERIFY]${C_NC} $*"; }
log_warn()  { echo -e "${C_YELLOW}[WARN]${C_NC} $*" >&2; }
log_error() { echo -e "${C_RED}[ERROR]${C_NC} $*" >&2; }

# Find project root
find_project_root() {
    local dir="$PWD"
    while [[ "$dir" != "/" ]]; do
        if [[ -f "$dir/TODO.md" ]]; then
            echo "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    log_error "No TODO.md found in directory tree"
    return 1
}

# Parse a single verification entry from VERIFY.md
# Outputs key=value lines for the target vid
parse_entry() {
    local verify_file="$1"
    local target_vid="$2"
    local in_entry=false
    local vid="" tid="" entry_status="" pr="" merged=""
    local check_index=0

    while IFS= read -r line; do
        # Match entry header
        if [[ "$line" =~ ^-\ \[(.)\]\ (v[0-9]+)\ (t[0-9.]+)\ (.+) ]]; then
            if $in_entry; then
                break
            fi
            local marker="${BASH_REMATCH[1]}"
            vid="${BASH_REMATCH[2]}"
            tid="${BASH_REMATCH[3]}"
            local rest="${BASH_REMATCH[4]}"

            if [[ "$vid" != "$target_vid" ]]; then
                continue
            fi

            in_entry=true
            case "$marker" in
                " ") entry_status="pending" ;;
                "x") entry_status="passed" ;;
                "!") entry_status="failed" ;;
                *) entry_status="unknown" ;;
            esac

            if [[ "$rest" =~ \|\ PR\ #([0-9]+) ]]; then
                pr="#${BASH_REMATCH[1]}"
            elif [[ "$rest" =~ \|\ cherry-picked:([a-f0-9]+) ]]; then
                pr="cherry:${BASH_REMATCH[1]}"
            fi
            if [[ "$rest" =~ merged:([0-9-]+) ]]; then
                merged="${BASH_REMATCH[1]}"
            fi
            continue
        fi

        # Collect metadata if inside target entry
        if $in_entry; then
            if [[ "$line" =~ ^[[:space:]]+check:\ (.+) ]]; then
                check_index=$((check_index + 1))
                echo "CHECK=${check_index}:${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^[[:space:]]+files:\ (.+) ]]; then
                echo "FILES=${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^-\ \[ ]]; then
                break
            fi
        fi
    done < "$verify_file"

    if ! $in_entry; then
        log_error "Entry $target_vid not found in VERIFY.md"
        return 1
    fi

    echo "VID=$vid"
    echo "TID=$tid"
    echo "STATUS=$entry_status"
    echo "PR=$pr"
    echo "MERGED=$merged"
    echo "CHECK_COUNT=$check_index"
    return 0
}

# Execute a single check directive and return result
# Sets global RESULT_SUMMARY with human-readable output
RESULT_SUMMARY=""

execute_check() {
    local directive="$1"
    local project_root="$2"
    local exit_code=0
    local output=""
    RESULT_SUMMARY=""

    # file-exists <path>
    if [[ "$directive" =~ ^file-exists\ (.+) ]]; then
        local fpath="${BASH_REMATCH[1]}"
        if [[ -f "$project_root/$fpath" ]]; then
            local fsize
            fsize=$(wc -c < "$project_root/$fpath" | xargs)
            RESULT_SUMMARY="exists (${fsize} bytes)"
            return 0
        else
            RESULT_SUMMARY="NOT FOUND"
            return 1
        fi
    fi

    # rg "pattern" <path>
    if [[ "$directive" =~ ^rg\ (.+) ]]; then
        local rg_args="${BASH_REMATCH[1]}"
        # Normalize grep BRE \| to rg ERE | inside quoted patterns
        # Many VERIFY.md entries use \| (grep syntax) but rg uses | for alternation
        rg_args="${rg_args//\\|/|}"
        output=$(eval "rg -c $rg_args" 2>&1) && exit_code=0 || exit_code=$?
        if [[ $exit_code -eq 0 ]]; then
            local match_count
            match_count=$(echo "$output" | awk -F: '{s+=$NF} END {print s+0}')
            RESULT_SUMMARY="${match_count} matches"
            return 0
        else
            RESULT_SUMMARY="no matches (exit:${exit_code})"
            return 1
        fi
    fi

    # ShellCheck <path>
    if [[ "$directive" =~ ^shellcheck\ (.+) ]]; then
        local sc_path="${BASH_REMATCH[1]}"
        # Use -x to follow sourced files (shared-constants.sh etc.) and
        # -S warning to ignore info-level SC1091/SC2329
        output=$(shellcheck -x -S warning "$project_root/$sc_path" 2>&1) && exit_code=0 || exit_code=$?
        if [[ $exit_code -eq 0 ]]; then
            RESULT_SUMMARY="0 issues"
            return 0
        else
            local issue_count
            issue_count=$(echo "$output" | grep -c "^In " 2>/dev/null || echo "?")
            RESULT_SUMMARY="${issue_count} issues (exit:${exit_code})"
            return 1
        fi
    fi

    # bash -n <path> (syntax check)
    if [[ "$directive" =~ ^bash\ -n\ (.+) ]]; then
        local script_path="${BASH_REMATCH[1]}"
        local full_path="$project_root/$script_path"
        output=$(bash -n "$full_path" 2>&1) && exit_code=0 || exit_code=$?
        if [[ $exit_code -eq 0 ]]; then
            RESULT_SUMMARY="syntax OK"
        else
            RESULT_SUMMARY="syntax error | ${output:0:80}"
        fi
        [[ $exit_code -eq 0 ]] && return 0 || return 1
    fi

    # bash <path> (test scripts)
    if [[ "$directive" =~ ^bash\ (.+) ]]; then
        local script_path="${BASH_REMATCH[1]}"
        output=$(bash "$project_root/$script_path" 2>&1) && exit_code=0 || exit_code=$?
        local passed failed
        passed=$(echo "$output" | grep -oE '[0-9]+ passed' | tail -1 || echo "")
        failed=$(echo "$output" | grep -oE '[0-9]+ failed' | tail -1 || echo "")
        if [[ -n "$passed" || -n "$failed" ]]; then
            RESULT_SUMMARY="${passed:-0 passed}, ${failed:-0 failed} (exit:${exit_code})"
        else
            local last_line
            last_line=$(echo "$output" | tail -1)
            RESULT_SUMMARY="exit:${exit_code} | ${last_line:0:80}"
        fi
        [[ $exit_code -eq 0 ]] && return 0 || return 1
    fi

    RESULT_SUMMARY="UNKNOWN DIRECTIVE: ${directive:0:60}"
    return 1
}

# Append a verification run to the proof log
append_proof_log() {
    local project_root="$1"
    local vid="$2"
    local tid="$3"
    local pr="$4"
    local overall="$5"
    local check_results="$6"
    local log_file="$project_root/todo/verify-proof-log.md"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local verifier
    verifier=$(whoami 2>/dev/null || echo "unknown")

    if [[ ! -f "$log_file" ]]; then
        cat > "$log_file" << 'HEADER'
# Verification Proof Log

Append-only evidence trail for verification runs. Each entry records the exact
check directives executed, their exit codes, and result summaries.

This is the proof that verification actually ran and what it found.
VERIFY.md has the check definitions and pass/fail status.

---

HEADER
    fi

    {
        echo "## ${vid} ${tid} | ${overall} | ${timestamp} | by:${verifier} | ${pr}"
        echo ""
        echo "$check_results"
    } >> "$log_file"

    return 0
}

# Update VERIFY.md entry status
update_verify_status() {
    local verify_file="$1"
    local vid="$2"
    local new_status="$3"
    local reason="${4:-}"
    local today
    today=$(date -u +"%Y-%m-%d")

    local marker
    case "$new_status" in
        passed) marker="x" ;;
        failed) marker="!" ;;
        *) marker=" " ;;
    esac

    local line_num
    line_num=$(grep -n "^\- \[.\] ${vid} " "$verify_file" | head -1 | cut -d: -f1)
    if [[ -z "$line_num" ]]; then
        log_error "Could not find ${vid} in VERIFY.md to update"
        return 1
    fi

    local current_line
    current_line=$(sed -n "${line_num}p" "$verify_file")

    # Replace checkbox marker — regex needed for [.] pattern
    local new_line
    # shellcheck disable=SC2001
    new_line=$(echo "$current_line" | sed "s/^\- \[.\]/- [${marker}]/")

    # Remove existing timestamps
    # shellcheck disable=SC2001
    new_line=$(echo "$new_line" | sed 's/ verified:[0-9-]*//g; s/ failed:[0-9-]*//g; s/ reason:[^ ]*//g')

    if [[ "$new_status" == "passed" ]]; then
        new_line="${new_line} verified:${today}"
    elif [[ "$new_status" == "failed" ]]; then
        new_line="${new_line} failed:${today}"
        if [[ -n "$reason" ]]; then
            new_line="${new_line} reason:${reason}"
        fi
    fi

    # Write the replacement using awk (sed delimiters conflict with | in content)
    local tmp_file
    tmp_file=$(mktemp)
    trap 'rm -f "$tmp_file"' RETURN
    awk -v ln="$line_num" -v rep="$new_line" 'NR==ln{print rep; next}{print}' "$verify_file" > "$tmp_file"
    mv "$tmp_file" "$verify_file"

    return 0
}

# List verification IDs matching a filter
list_vids() {
    local verify_file="$1"
    local filter="$2"

    local pattern
    case "$filter" in
        pending) pattern='^\- \[ \] (v[0-9]+)' ;;
        failed)  pattern='^\- \[!\] (v[0-9]+)' ;;
        all)     pattern='^\- \[.\] (v[0-9]+)' ;;
        *) log_error "Unknown filter: $filter"; return 1 ;;
    esac

    grep -oE "$pattern" "$verify_file" | grep -oE 'v[0-9]+' || true
    return 0
}

# Run verification for a single entry
run_single() {
    local project_root="$1"
    local verify_file="$2"
    local vid="$3"

    log_info "Running verification: ${vid}"

    local entry_data
    entry_data=$(parse_entry "$verify_file" "$vid") || return 1

    local tid pr check_count
    tid=$(echo "$entry_data" | grep "^TID=" | cut -d= -f2)
    pr=$(echo "$entry_data" | grep "^PR=" | cut -d= -f2)
    check_count=$(echo "$entry_data" | grep "^CHECK_COUNT=" | cut -d= -f2)

    if [[ "$check_count" -eq 0 ]]; then
        log_warn "${vid}: No check directives found"
        return 0
    fi

    local all_passed=true
    local check_results=""
    local fail_reasons=""

    while IFS= read -r check_line; do
        local check_num="${check_line%%:*}"
        local directive="${check_line#*:}"

        local check_exit=0
        RESULT_SUMMARY=""
        pushd "$project_root" > /dev/null 2>&1 || true
        execute_check "$directive" "$project_root" && check_exit=0 || check_exit=$?
        popd > /dev/null 2>&1 || true

        local status_icon
        if [[ $check_exit -eq 0 ]]; then
            status_icon="PASS"
        else
            status_icon="FAIL"
            all_passed=false
            fail_reasons="${fail_reasons}${directive:0:40}; "
        fi

        check_results="${check_results}  ${status_icon} | check ${check_num}: \`${directive}\`"$'\n'
        check_results="${check_results}  exit: ${check_exit} | ${RESULT_SUMMARY}"$'\n'

    done < <(echo "$entry_data" | grep "^CHECK=" | sed 's/^CHECK=//')

    local overall
    if $all_passed; then
        overall="PASSED"
        log_info "${vid} ${tid}: ALL CHECKS PASSED (${check_count} checks)"
    else
        overall="FAILED"
        log_error "${vid} ${tid}: SOME CHECKS FAILED"
    fi

    append_proof_log "$project_root" "$vid" "$tid" "$pr" "$overall" "$check_results"

    if $all_passed; then
        update_verify_status "$verify_file" "$vid" "passed"
    else
        update_verify_status "$verify_file" "$vid" "failed" "${fail_reasons:0:60}"
    fi

    return 0
}

# Show proof log entries
cmd_log() {
    local project_root="$1"
    shift
    local log_file="$project_root/todo/verify-proof-log.md"
    local filter_vid=""
    local last_n=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            v[0-9]*) filter_vid="$1"; shift ;;
            --last) last_n="${2:-10}"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [[ ! -f "$log_file" ]]; then
        echo "No verify proof log found (todo/verify-proof-log.md does not exist)."
        return 0
    fi

    if [[ -n "$filter_vid" ]]; then
        # Print from matching header until next header (exclusive)
        awk "/^## ${filter_vid} /{found=1} found && /^## v[0-9]/ && !/^## ${filter_vid} /{exit} found{print}" "$log_file"
    elif [[ $last_n -gt 0 ]]; then
        local total_runs
        total_runs=$(grep -c "^## v[0-9]" "$log_file" || echo "0")
        echo "Total runs: ${total_runs}"
        echo ""
        local start_pattern
        start_pattern=$(grep "^## v[0-9]" "$log_file" | tail -"$last_n" | head -1 | sed 's/[[\.*^$()+?{|]/\\&/g')
        if [[ -n "$start_pattern" ]]; then
            sed -n "/${start_pattern}/,\$p" "$log_file"
        fi
    else
        cat "$log_file"
    fi

    return 0
}

show_help() {
    cat << 'EOF'
Usage: verify-run-helper.sh <command> [options]

Commands:
  run <vNNN>         Run checks for a single verification entry
  run --pending      Run all pending verifications
  run --failed       Re-run all failed verifications
  run --all          Re-run all verifications
  log [vNNN]         Show proof log (optionally filtered by entry)
  log --last N       Show last N proof log entries
  help               Show this help

Check directives (in VERIFY.md):
  file-exists <path>           Test file exists, report size
  rg "pattern" <path>          Ripgrep match count
  shellcheck <path>            ShellCheck analysis
  bash -n <path>               Syntax check (bash -n), no execution
  bash <path>                  Run test script, capture pass/fail

Proof log:
  Results are appended to todo/verify-proof-log.md with timestamps,
  exit codes, and result summaries as auditable evidence.

Examples:
  verify-run-helper.sh run v025              # Run checks for v025
  verify-run-helper.sh run --pending         # Run all pending
  verify-run-helper.sh log v025              # Show proof for v025
  verify-run-helper.sh log --last 5          # Last 5 verification runs
EOF
}

main() {
    if [[ $# -eq 0 ]]; then
        show_help
        return 0
    fi

    local project_root
    project_root=$(find_project_root) || exit 1

    local verify_file="$project_root/todo/VERIFY.md"
    if [[ ! -f "$verify_file" ]]; then
        log_error "No VERIFY.md found at $verify_file"
        return 1
    fi

    local cmd="$1"
    shift

    case "$cmd" in
        run)
            if [[ $# -eq 0 ]]; then
                log_error "Usage: verify-run-helper.sh run <vNNN|--pending|--all>"
                return 1
            fi

            local target="$1"
            shift

            case "$target" in
                v[0-9]*)
                    run_single "$project_root" "$verify_file" "$target"
                    ;;
                --pending)
                    local vids
                    vids=$(list_vids "$verify_file" "pending")
                    if [[ -z "$vids" ]]; then
                        log_info "No pending verifications"
                        return 0
                    fi
                    local vid
                    for vid in $vids; do
                        run_single "$project_root" "$verify_file" "$vid" || true
                    done
                    ;;
                --failed)
                    local vids
                    vids=$(list_vids "$verify_file" "failed")
                    if [[ -z "$vids" ]]; then
                        log_info "No failed verifications"
                        return 0
                    fi
                    local vid
                    for vid in $vids; do
                        run_single "$project_root" "$verify_file" "$vid" || true
                    done
                    ;;
                --all)
                    local vids
                    vids=$(list_vids "$verify_file" "all")
                    if [[ -z "$vids" ]]; then
                        log_info "No verification entries"
                        return 0
                    fi
                    local vid
                    for vid in $vids; do
                        run_single "$project_root" "$verify_file" "$vid" || true
                    done
                    ;;
                *)
                    log_error "Unknown target: $target (expected vNNN, --pending, --failed, or --all)"
                    return 1
                    ;;
            esac
            ;;
        log)
            cmd_log "$project_root" "$@"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            log_error "Unknown command: $cmd"
            show_help
            return 1
            ;;
    esac

    return 0
}

main "$@"
