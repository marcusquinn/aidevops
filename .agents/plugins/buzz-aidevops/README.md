<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# aidevops plugin for Buzz Desktop

Phase 0 of t18883. Adds an **aidevops** card under Buzz Settings that shows the
output of `aidevops buzz status` for this computer.

Needs a Buzz Desktop build with plugins: the `block/buzz-app` desktop preview
releases (0.7.0 previews, tested on `v0.7.0-preview.254.1`). Stable Buzz 0.5.x
has no plugin support. The preview uses its own data folder
(`xyz.block.buzz.desktop`), so it can be installed beside 0.5.x as
`/Applications/Buzz Preview.app`.

## Install (owner action)

1. Buzz Desktop → **Settings → Plugins → Manage plugins → Add**.
2. Under "Add from folder", choose **Browse** and pick this folder. Use Browse
   rather than drag and drop: a dropped folder is copied and can't be reloaded.
   In the file picker, press **Cmd+Shift+G**, paste the folder path, press
   Return, then select the folder itself (not a file inside it).
3. Review the host access and select **Install plugin**. The review should list
   only `aidevops buzz status`.
4. Open **Settings → aidevops** to see the card.

Folder paths:

| Source | Path |
|--------|------|
| Installed by `aidevops update` / `setup.sh` | `~/.aidevops/agents/plugins/buzz-aidevops` |
| aidevops repo checkout | `<repo>/.agents/plugins/buzz-aidevops` |

Prefer the installed path: it is refreshed on each `aidevops update`, so
**Reload** in Manage plugins picks up new versions.

## Host access

One command, `aidevops buzz status`, with no shell, a 5 s deadline and 16 KiB
of output. No network origins, processes, files, MCP or agent hooks.

`aidevops` is found on the login-shell PATH, not pinned by `artifact`. The
`/usr/local/bin/aidevops` launcher re-executes the setup-deployed
`~/.aidevops/agents/aidevops.sh`, so a launcher hash would not cover the code
that runs, and it differs per install, so a shipped manifest can't carry it.

## Remove

Settings → Plugins → aidevops → Remove. The plugin writes nothing outside its
own Settings card.

## Checks

- Manifest: `cargo run -q -p buzzodz-plugins -- --home <empty temp dir> plugin install <this folder>`
  in a buzz-app checkout.
- Module: `node --check plugin.js`.
