## What

`shellcheck-wrapper.sh` must load `mkdir-exclusive.sh` from its own resolved directory, so it keeps working when it runs through the `~/.aidevops/bin/shellcheck` PATH-shim symlink.

## Why

Observed on 2026-11-27 (macOS, aidevops v3.39.290):

```text
$ ~/.aidevops/bin/shellcheck --version
~/.aidevops/bin/shellcheck: line 5: ~/.aidevops/bin/mkdir-exclusive.sh: No such file or directory
ShellCheck - shell script analysis tool
```

- t19425 (`84e055e44a`, GH#40582) added `source "${BASH_SOURCE[0]%/*}/mkdir-exclusive.sh"` at `.agents/scripts/shellcheck-wrapper.sh:5`.
- setup creates `~/.aidevops/bin/shellcheck` as a symlink to the deployed wrapper (`.agents/scripts/setup/modules/shell-env.sh` `_shellcheck_wrapper_setup_shim`, GH#2993). Through that symlink, `BASH_SOURCE[0]` is the shim path, so the `source` fails.
- Every PATH-resolved `shellcheck` call, including bash-language-server, prints this error to stderr. On uutils hosts the wrapper's `mkdir "$lock_dir"` lock (`shellcheck-wrapper.sh:258`) also loses the GH#40582 exclusivity guarantee, because `aidevops_mkdir_exclusive` and the `mkdir` override are never defined.
- The wrapper already resolves itself at `shellcheck-wrapper.sh:117` (`realpath "${BASH_SOURCE[0]}" || readlink -f ...`), but only after line 5.

## How

### Files to Modify

- `EDIT: .agents/scripts/shellcheck-wrapper.sh:4-5` — resolve the script's real directory first (portable: `realpath` / `readlink -f` fallback, as at line 117), then `source` `mkdir-exclusive.sh` from it

### Files Scope

- `.agents/scripts/shellcheck-wrapper.sh`

### Notes

Other scripts that use the same `source "${BASH_SOURCE[0]%/*}/mkdir-exclusive.sh"` line (`git grep -l 'mkdir-exclusive.sh"' -- .agents/scripts`) are not symlinked into `~/.aidevops/bin` today. The other shims (`git`, `aidevops-auto-update`, `aidevops-repo-aidevops-health`) were checked and run cleanly. Fix only the wrapper unless a new symlinked entry point turns up.

## Acceptance

- `~/.aidevops/bin/shellcheck --version` prints no `mkdir-exclusive.sh` error after `setup.sh --non-interactive`.
- `bash -c 'source <wrapper via symlink>; declare -F aidevops_mkdir_exclusive'` succeeds when the wrapper is invoked through a symlink in another directory.
- ShellCheck is clean on the wrapper.
