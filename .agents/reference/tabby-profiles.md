<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Tabby profiles

Use `.agents/scripts/tabby-profile-sync.py` to generate aidevops project profiles
from `repos.json`.

OpenCode profiles must not launch with `zsh -i -c opencode`. That shape runs an
interactive zsh startup while executing a command string, which can make
Powerlevel10k/gitstatus initialize before job control is available and emit
errors such as `setopt: can't change option: monitor` or `gitstatus failed to
initialize` before the TUI starts.

Do not use `TABBY_AUTORUN=opencode` for generated profiles. It depends on a
`.zshrc` startup hook and can fail silently, leaving users in a plain shell.

The safe generated shape is:

```yaml
command: /bin/zsh
args:
  - '-l'
  - '-c'
  - 'opencode; exec zsh'
env: {}
```

For manual one-off profiles that should run OpenCode and then leave a shell open,
use the same non-interactive login command instead of mixing `-i` and `-c`:

```yaml
command: /bin/zsh
args:
  - '-l'
  - '-c'
  - 'opencode; exec zsh'
```
