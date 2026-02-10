# Archived Scripts

One-time fix scripts that have completed their purpose. Preserved for reference
and git history (patterns may be useful for future bulk fixes).

## Scripts

| Script | Purpose | Origin |
|--------|---------|--------|
| fix-auth-headers.sh | Fix Authorization header string literals | .agent->.agents rename |
| fix-common-strings.sh | Common string literals fix | .agent->.agents rename |
| fix-content-type.sh | Fix Content-Type string literals | .agent->.agents rename |
| fix-error-messages.sh | Fix common error message string literals | .agent->.agents rename |
| fix-misplaced-returns.sh | Fix misplaced return statements in mainwp-helper | .agent->.agents rename |
| fix-remaining-literals.sh | Fix remaining string literals | .agent->.agents rename |
| fix-return-statements.sh | Add return statements to functions | .agent->.agents rename |
| fix-s131-default-cases.sh | Add default case to case statements (SonarCloud S131) | Quality hardening |
| fix-sc2155-simple.sh | Fix SC2155 (declare and assign separately) | ShellCheck compliance |
| fix-shellcheck-critical.sh | Fix critical ShellCheck issues | ShellCheck compliance |
| fix-string-literals.sh | String literals fix | .agent->.agents rename |
| comprehensive-quality-fix.sh | Comprehensive quality fixes (returns, SC2155, strings) | Quality hardening |
| efficient-return-fix.sh | Efficient bulk return statement fixer | Quality hardening |
| find-missing-returns.sh | Find functions missing explicit returns | Quality hardening |
| mass-fix-returns.sh | Mass add return statements to functions | Quality hardening |

All scripts have 0 references in the active codebase as of 2026-02-10.
