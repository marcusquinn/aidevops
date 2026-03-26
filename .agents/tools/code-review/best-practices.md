---
description: Best practices for AI-assisted coding
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: true
  grep: true
  webfetch: false
  task: true
---

# AI-Assisted Coding Best Practices

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Mandatory Patterns**: Local variables for params (`local param="$1"`), explicit returns, constants for 3+ strings
- **SC2155**: Separate `local var` and `var=$(command)`
- **S7679**: Never use `$1` directly - assign to local variables
- **S1192**: Create `readonly CONSTANT="value"` for repeated strings
- **S1481**: Remove unused variables or enhance functionality
- **Pre-Dev**: Run `linters-local.sh`, note current issues, plan improvements
- **Post-Dev**: Re-run quality check, test functionality, commit with metrics
- **Quality Scripts**: `linters-local.sh`, `fix-content-type.sh`, `fix-auth-headers.sh`, `fix-error-messages.sh`
- **Targets**: SonarCloud <50 issues, 0 critical violations, 100% feature preservation
<!-- AI-CONTEXT-END -->

## Framework-Specific Guidelines for AI Agents

> **IMPORTANT**: This document is supplementary to the [AGENTS.md](../AGENTS.md).
> For any conflicts, the main AGENTS.md takes precedence as the single source of truth.

### Overview

This document provides detailed implementation examples and advanced patterns for AI agents working on the AI DevOps Framework.

### Code Quality Requirements

#### Shell Script Standards (MANDATORY)

**These patterns are REQUIRED for SonarCloud/CodeFactor/Codacy compliance:**

```bash
# ✅ CORRECT Function Structure
function_name() {
    local param1="$1"
    local param2="$2"

    # Function logic here

    return 0  # MANDATORY: Every function must have explicit return
}

# ✅ CORRECT Variable Declaration (SC2155 compliance)
local variable_name
variable_name=$(command_here)

# ✅ CORRECT String Literal Management (S1192 compliance)
readonly COMMON_STRING="repeated text"
echo "$COMMON_STRING"  # Use constant for 3+ occurrences

# ✅ CORRECT Positional Parameter Handling (S7679 compliance)
printf 'Price: %s50/month\n' '$'  # Not: echo "Price: $50/month"
```

#### Quality Issue Prevention

**Before making ANY changes, check for these patterns:**

1. **Positional Parameters**: Never use `$50`, `$200` in strings - use printf format
2. **String Literals**: If text appears 3+ times, create a readonly constant
3. **Unused Variables**: Every variable must be used or removed
4. **Return Statements**: Every function must end with `return 0` or appropriate code
5. **Variable Declaration**: Separate `local var` and `var=$(command)`

### Development Workflow

#### Pre-Development Checklist

1. **Run quality check**: `bash .agents/scripts/linters-local.sh`
2. **Check current issues**: Note SonarCloud/Codacy/CodeFactor status
3. **Plan improvements**: How will changes enhance quality?
4. **Test functionality**: Ensure no feature loss

#### Post-Development Validation

1. **Quality verification**: Re-run linters-local.sh
2. **Functionality testing**: Verify all features work
3. **Documentation updates**: Update AGENTS.md if needed
4. **Commit with metrics**: Include before/after quality metrics

### Common Patterns & Solutions

#### String Literal Consolidation

**Target patterns with 3+ occurrences:**

- HTTP headers: `Content-Type: application/json`, `Authorization: Bearer`
- Error messages: `Unknown command:`, `Usage:`, help text
- API endpoints: Repeated URLs or paths
- Configuration values: Common settings or defaults

```bash
# Create constants section after colors
readonly NC='\033[0m' # No Color

# Common constants
readonly CONTENT_TYPE_JSON="Content-Type: application/json"
readonly AUTH_BEARER_PREFIX="Authorization: Bearer"
readonly ERROR_UNKNOWN_COMMAND="Unknown command:"
```

#### Error Message Standardization

**Consistent error handling patterns:**

```bash
# Error message constants
readonly ERROR_UNKNOWN_COMMAND="Unknown command:"
readonly ERROR_CONFIG_NOT_FOUND="Configuration file not found"
readonly ERROR_INVALID_OPTION="Invalid option"
readonly USAGE_PREFIX="Usage:"
readonly HELP_MESSAGE_SUFFIX="Show this help message"

# Usage in functions
print_error "$ERROR_UNKNOWN_COMMAND $command"
echo "$USAGE_PREFIX $0 [options]"
```

#### Function Enhancement Over Deletion

**When fixing unused variables, prefer enhancement:**

```bash
# ❌ DON'T: Remove functionality
# local port  # Removed to fix unused variable

# ✅ DO: Enhance functionality
local port
read -r port
if [[ -n "$port" && "$port" != "22" ]]; then
    ssh -p "$port" "$host"  # Enhanced SSH with port support
else
    ssh "$host"
fi
```

### Quality Tools Usage

#### Available Quality Scripts

- **linters-local.sh**: Run before and after changes
- **fix-content-type.sh**: Fix Content-Type header duplications
- **fix-auth-headers.sh**: Fix Authorization header patterns
- **fix-error-messages.sh**: Standardize error messages
- **markdown-formatter.sh**: Fix markdown formatting issues

#### Quality CLI Integration

```bash
# CodeRabbit analysis
bash .agents/scripts/coderabbit-cli.sh review

# Comprehensive analysis
bash .agents/scripts/quality-cli-manager.sh analyze all

# Individual platform analysis
bash .agents/scripts/codacy-cli.sh analyze
bash .agents/scripts/sonarscanner-cli.sh analyze
```

### Success Metrics

#### Quality Targets

- **SonarCloud**: <50 total issues (currently 42)
- **Critical Issues**: 0 S7679, 0 S1481 violations
- **String Literals**: <10 S1192 violations
- **ShellCheck**: <5 critical issues per file
- **Functionality**: 100% feature preservation

#### Commit Standards

**Include quality metrics in commit messages:**

```text
🔧 FEATURE: Enhanced SSH functionality with port support

✅ QUALITY IMPROVEMENTS:
- Fixed S1481: Unused 'port' variable → Enhanced SSH port support
- Maintained functionality: All existing SSH features preserved
- Added capability: Custom port support for non-standard configurations

📊 METRICS:
- SonarCloud: 43 → 42 issues (1 issue resolved)
- Functionality: 100% preserved + enhanced
```

This framework maintains industry-leading quality standards through systematic application of these practices.

---

## Runtime Behaviour Patterns

These patterns apply to any code that manages state over time — UI components, background workers, payment flows, auth sessions, and polling loops. Violations here cause silent failures, infinite loops, and race conditions that only appear at runtime.

### State Machine Patterns

#### Entry-State Completeness

Every state machine must handle **all possible entry states**, not just the happy path. Missing entry states cause silent no-ops or crashes when the system enters an unexpected state.

**Detection keywords** (flag these for runtime testing): `status`, `state`, `phase`, `stage`, `step`, `mode`, `lifecycle`

```typescript
// ❌ INCOMPLETE: Only handles expected states — crashes on unexpected input
function handlePaymentStatus(status: string) {
  if (status === 'succeeded') {
    showSuccess();
  } else if (status === 'failed') {
    showError();
  }
  // Missing: 'pending', 'processing', 'cancelled', 'refunded', 'disputed'
  // These silently do nothing — user sees a frozen UI
}

// ✅ COMPLETE: Exhaustive state handling with explicit default
function handlePaymentStatus(status: string) {
  switch (status) {
    case 'succeeded':
      showSuccess();
      break;
    case 'failed':
      showError();
      break;
    case 'pending':
    case 'processing':
      showPending();
      break;
    case 'cancelled':
      showCancelled();
      break;
    case 'refunded':
      showRefunded();
      break;
    default:
      // Explicit default: log unknown state, show safe fallback
      console.error(`Unhandled payment status: ${status}`);
      showError(`Unexpected status: ${status}`);
  }
}
```

```bash
# ❌ INCOMPLETE shell state machine
handle_deploy_state() {
    local state="$1"
    if [[ "$state" == "success" ]]; then
        notify_success
    elif [[ "$state" == "failed" ]]; then
        notify_failure
    fi
    # Missing: 'pending', 'cancelled', 'timeout' — silently ignored
    return 0
}

# ✅ COMPLETE shell state machine
handle_deploy_state() {
    local state="$1"
    case "$state" in
        success)
            notify_success
            ;;
        failed)
            notify_failure
            ;;
        pending|running)
            notify_pending
            ;;
        cancelled)
            notify_cancelled
            ;;
        timeout)
            notify_timeout
            ;;
        *)
            echo "[handle_deploy_state] Unknown state: $state" >&2
            notify_failure "Unknown deploy state: $state"
            return 1
            ;;
    esac
    return 0
}
```

#### Transition Guards

State transitions must be **guarded** — only allow valid transitions from the current state. Unguarded transitions cause double-processing, duplicate charges, and race conditions.

```typescript
// ❌ UNGUARDED: Any state can transition to any other state
class OrderProcessor {
  status = 'pending';

  async charge() {
    // No guard — can be called multiple times, causing duplicate charges
    this.status = 'charging';
    await stripe.charge(this.amount);
    this.status = 'charged';
  }
}

// ✅ GUARDED: Transitions only allowed from valid prior states
class OrderProcessor {
  status: 'pending' | 'charging' | 'charged' | 'failed' = 'pending';

  private readonly VALID_TRANSITIONS: Record<string, string[]> = {
    pending:  ['charging'],
    charging: ['charged', 'failed'],
    charged:  [],           // Terminal state — no further transitions
    failed:   ['pending'],  // Allow retry from failed
  };

  private canTransition(to: string): boolean {
    return this.VALID_TRANSITIONS[this.status]?.includes(to) ?? false;
  }

  async charge() {
    if (!this.canTransition('charging')) {
      throw new Error(`Cannot charge from state: ${this.status}`);
    }
    this.status = 'charging';
    try {
      await stripe.charge(this.amount);
      this.status = 'charged';
    } catch (err) {
      this.status = 'failed';
      throw err;
    }
  }
}
```

```bash
# ✅ Shell transition guard pattern
DEPLOY_STATE="idle"

transition_deploy_state() {
    local from_state="$1"
    local to_state="$2"

    if [[ "$DEPLOY_STATE" != "$from_state" ]]; then
        echo "[transition_deploy_state] Invalid transition: $DEPLOY_STATE → $to_state (expected from: $from_state)" >&2
        return 1
    fi
    DEPLOY_STATE="$to_state"
    return 0
}

# Usage: only proceeds if currently in 'idle' state
transition_deploy_state "idle" "deploying" || { echo "Deploy already in progress"; exit 1; }
```

### Polling Patterns

#### Polling Termination (Mandatory)

Every polling loop **must** have a termination condition beyond the success case. Infinite polling loops are the #1 cause of hung workers and zombie processes.

**Required termination conditions:**
1. **Success** — the expected state was reached
2. **Timeout** — maximum wait time exceeded
3. **Terminal failure** — a state that will never recover (e.g., `failed`, `cancelled`, `error`)
4. **Max iterations** — hard cap as a safety net

```bash
# ❌ DANGEROUS: No timeout, no terminal failure detection
wait_for_deploy() {
    local deploy_id="$1"
    while true; do
        local status
        status=$(get_deploy_status "$deploy_id")
        if [[ "$status" == "success" ]]; then
            return 0
        fi
        sleep 10
    done
    # Hangs forever if deploy fails or gets stuck
}

# ✅ SAFE: Timeout + terminal failure + max iterations
wait_for_deploy() {
    local deploy_id="$1"
    local max_wait="${2:-300}"   # Default 5 minutes
    local interval="${3:-10}"    # Poll every 10 seconds
    local elapsed=0
    local max_iterations
    max_iterations=$(( max_wait / interval ))
    local iteration=0

    while [[ "$iteration" -lt "$max_iterations" ]]; do
        local status
        status=$(get_deploy_status "$deploy_id") || {
            echo "[wait_for_deploy] Status check failed for $deploy_id" >&2
            return 1
        }

        case "$status" in
            success|deployed|complete)
                echo "[wait_for_deploy] Deploy $deploy_id succeeded after ${elapsed}s"
                return 0
                ;;
            failed|error|cancelled|aborted)
                # Terminal failure — will never recover, stop immediately
                echo "[wait_for_deploy] Deploy $deploy_id reached terminal state: $status" >&2
                return 1
                ;;
            pending|running|deploying)
                # Still in progress — continue polling
                ;;
            *)
                echo "[wait_for_deploy] Unknown status '$status' for $deploy_id" >&2
                ;;
        esac

        sleep "$interval"
        elapsed=$(( elapsed + interval ))
        iteration=$(( iteration + 1 ))
    done

    echo "[wait_for_deploy] Timeout after ${max_wait}s waiting for deploy $deploy_id" >&2
    return 1
}
```

```typescript
// ✅ TypeScript polling with timeout and terminal failure detection
async function waitForJobCompletion(
  jobId: string,
  options: { maxWaitMs?: number; intervalMs?: number } = {}
): Promise<'success' | 'failed' | 'timeout'> {
  const { maxWaitMs = 300_000, intervalMs = 5_000 } = options;
  const deadline = Date.now() + maxWaitMs;

  const TERMINAL_STATES = new Set(['failed', 'error', 'cancelled', 'aborted']);
  const SUCCESS_STATES  = new Set(['success', 'complete', 'done']);

  while (Date.now() < deadline) {
    const status = await getJobStatus(jobId);

    if (SUCCESS_STATES.has(status)) {
      return 'success';
    }
    if (TERMINAL_STATES.has(status)) {
      console.error(`Job ${jobId} reached terminal state: ${status}`);
      return 'failed';
    }

    // Still in progress — wait before next poll
    await new Promise(resolve => setTimeout(resolve, intervalMs));
  }

  console.error(`Job ${jobId} timed out after ${maxWaitMs}ms`);
  return 'timeout';
}
```

#### Quiescence Detection

For UI polling (waiting for a page to stop loading, animations to finish, or network requests to settle), use **quiescence detection** — wait until the system has been stable for a minimum duration, not just until a single check passes.

```typescript
// ❌ FRAGILE: Single check — passes during a brief stable moment mid-animation
async function waitForPageLoad(page: Page) {
  await page.waitForLoadState('networkidle');
  // May pass while a spinner is still visible between requests
}

// ✅ QUIESCENT: Stable for a minimum duration before proceeding
async function waitForQuiescence(
  page: Page,
  options: { stableMs?: number; timeoutMs?: number } = {}
): Promise<void> {
  const { stableMs = 500, timeoutMs = 10_000 } = options;
  const deadline = Date.now() + timeoutMs;
  let stableSince: number | null = null;

  while (Date.now() < deadline) {
    const isStable = await page.evaluate(() => {
      // Check: no pending network requests, no active animations, no spinners
      const hasPendingRequests = (window as any).__pendingRequests > 0;
      const hasSpinners = document.querySelectorAll('[data-loading], .spinner, [aria-busy="true"]').length > 0;
      return !hasPendingRequests && !hasSpinners;
    });

    if (isStable) {
      if (stableSince === null) {
        stableSince = Date.now();
      } else if (Date.now() - stableSince >= stableMs) {
        return; // Stable for the required duration
      }
    } else {
      stableSince = null; // Reset — not stable
    }

    await new Promise(resolve => setTimeout(resolve, 100));
  }

  throw new Error(`Page did not reach quiescence within ${timeoutMs}ms`);
}
```

#### Polling Backoff

Long-running polls should use **exponential backoff** to avoid hammering APIs during slow operations.

```bash
# ✅ Exponential backoff polling
poll_with_backoff() {
    local check_cmd="$1"
    local max_wait="${2:-300}"
    local initial_interval="${3:-2}"
    local max_interval="${4:-30}"

    local elapsed=0
    local interval="$initial_interval"

    while [[ "$elapsed" -lt "$max_wait" ]]; do
        if $check_cmd; then
            return 0
        fi

        sleep "$interval"
        elapsed=$(( elapsed + interval ))

        # Double interval up to max_interval
        interval=$(( interval * 2 ))
        if [[ "$interval" -gt "$max_interval" ]]; then
            interval="$max_interval"
        fi
    done

    echo "[poll_with_backoff] Timeout after ${max_wait}s" >&2
    return 1
}
```

### Runtime Testing Signals

These patterns are **high-risk for runtime-only failures** — they cannot be verified by static analysis alone. When the full-loop runtime testing gate (t1660.7) detects these patterns in a diff, it escalates the required testing level:

| Pattern | Risk | Required testing |
|---------|------|-----------------|
| `switch`/`case` on status/state fields | Missing entry states | Runtime: trigger each state |
| `while true` or unbounded loops | Infinite loop | Runtime: verify termination |
| `setTimeout`/`setInterval` | Timer leak | Runtime: verify cleanup |
| Payment/checkout flows | Duplicate charge | Runtime: full payment flow |
| Auth token refresh | Race condition | Runtime: concurrent requests |
| Webhook handlers | Missing event types | Runtime: send each event type |
| Database migrations | Irreversible | Runtime: test on staging first |

**Prevention rule:** Before implementing any of these patterns, define the complete state space first — list every possible state/event/status value the system can receive, including error and edge cases. Implement handlers for all of them before writing the happy path.

### Quick Reference

- **State machines**: Handle all entry states, guard all transitions, define terminal states
- **Polling**: Always set timeout + terminal failure detection + max iterations
- **Quiescence**: Wait for stability duration, not just a single passing check
- **Backoff**: Use exponential backoff for long-running polls
- **Testing**: Static analysis cannot verify runtime behaviour — these patterns require runtime testing
