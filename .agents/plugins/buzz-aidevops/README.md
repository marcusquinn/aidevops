<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# aidevops plugin for Buzz Desktop

Part of t18883. The plugin adds:

- **Settings → aidevops**: a card showing `aidevops buzz status` for this
  computer (phase 0).
- **An aidevops agent type** (phase 1, GH#37233): Buzz agents that run aidevops
  OpenCode agents on this computer, each in its own linked worktree of a
  registered project, using your normal OpenCode models and logins.

It needs a Buzz Desktop build with plugins: the `block/buzz-app` desktop preview
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
3. Review the host access (see below) and select **Install plugin**.
4. Open **Settings → aidevops** to see the card.

Folder paths:

| Source | Path |
|--------|------|
| Installed by `aidevops update` / `setup.sh` (stable) | `~/.aidevops/plugins/buzz-aidevops` |
| aidevops repo checkout | `<repo>/.agents/plugins/buzz-aidevops` |

Use the stable path. It is a real folder (not a symlink) that `aidevops update`
refreshes in place, so Buzz's folder watcher picks up new versions within
seconds. Do not add the plugin from `~/.aidevops/agents/plugins/...`: that
path resolves into a versioned runtime bundle, and Buzz saves the versioned
path, so later updates never reach it. After an update that adds host access,
Buzz asks you to review it again.

**One-time migration** if you installed from the old path: open **Settings →
Plugins → Manage plugins → aidevops**, choose **⋯ → remove**, then **Add** and
choose `~/.aidevops/plugins/buzz-aidevops` (in the macOS folder picker, press
⌘⇧G and paste the path). Buzz has no control to change an installed plugin's
source folder: its **Update** button appears only after the saved folder
changes, and adding the plugin again without removing it fails with "Already
installed".

## Create an aidevops agent

1. **Agents → New agent**, choose the **aidevops** type.
2. Name it after the aidevops agent and this computer, such as
   `aidevops-marcus-macbook-pro-01` or `build-plus-marcus-macbook-pro-01`. The
   names are the same per-computer names `aidevops` uses for Buzz 0.5 agents:
   `<agent>-<LocalHostName>`. Each Mac needs a distinct `LocalHostName`
   (`scutil --get LocalHostName`); see
   `.agents/reference/team-interface-buzz-provisioning.md`.
3. Set **Project folder** to the folder of a repository registered with
   aidevops (`repos.json`): a full path, or one starting with `~/`. The agent
   works in its own linked worktree (`<repo>-buzz-<computer>-<agent>` in the
   aidevops worktree folder), never in the folder itself.
4. Leave **aidevops agent** empty to use the Buzz agent's name, or enter the
   per-computer name when the Buzz agent has a different one (for example a
   test agent named `aidevops-test`). A name that is not an aidevops agent, or
   was made for another computer, is refused.

To change these later, open **Agents**, choose the agent, and edit the fields
on its **Identity** tab, then press **Save**. Buzz shows the plugin's settings
there; the agent's own **Settings** tab only has Buzz's details.
5. Mention the agent, or DM it. Only your own messages (or ones you attested)
   start a turn; Buzz enforces that before the plugin sees them.

How a turn runs:

- The first message starts `aidevops buzz acp` for that agent (about 4 to 8
  seconds). It stops after 30 minutes without a turn.
- Each thread is one OpenCode session, or each channel with **One session per
  channel**.
- For "what version are you running?", agents should run `aidevops --version`
  (instant) or `aidevops status --quick` (offline, seconds). Plain
  `aidevops status` is the full report and can take over a minute on a large
  OpenCode database.
- Turns run one at a time per agent. A message sent during a turn waits, then
  runs with everything the agent has not seen yet.
- The agent replies with Buzz's `send` tool. If it only writes text, the plugin
  posts that text as its reply.
- Session-bus messages (`aidevops_sessions`) reach the agent on its next Buzz
  turn and never wake it. Its sends carry a `chat:` origin and never wake local
  sessions.
- **Stop** cancels the running turn.
- OpenCode permission prompts are declined. The aidevops remote-interactive
  profile already allows ordinary tools and asks only for actions that need a
  person at the computer, which nobody can approve from Buzz. (Buzz's bundled
  harnesses allow instead.)

## Host access

| Access | Purpose |
|--------|---------|
| Command `aidevops buzz status` | The Settings card; no shell, 5 s deadline, 16 KiB of output |
| Process `aidevops buzz acp` | One aidevops OpenCode ACP process per agent; the plugin appends `--member <name> --project <folder>` |
| MCP | Serves each agent's Buzz tools to its OpenCode process on a loopback address |

No network origins, files or agent hooks. No Buzz key reaches the process: the
Buzz tools arrive over the loopback MCP server, and the plugin clears
`BUZZ_PRIVATE_KEY`, `BUZZ_AUTH_TAG` and `BUZZ_RELAY_URL` from its environment.

`aidevops` is found on the login-shell PATH, not pinned by `artifact`. The
`/usr/local/bin/aidevops` launcher re-executes the setup-deployed
`~/.aidevops/agents/aidevops.sh`, so a launcher hash would not cover the code
that runs, and it differs per install, so a shipped manifest can't carry it.

## Limits

- OpenCode registers MCP servers per folder, not per session, so an agent's
  sessions share one Buzz tools server and its turns run one at a time. OpenCode
  2.x names the session on each tool call (`ai.opencode/sessionID`); the plugin
  already routes by it when present (OpenCode upgrade: GH#35902).
- Sessions last while the process runs. After a restart, the next turn opens a
  new session that is shown the conversation so far.
- Buzz 0.5 agents are unaffected: they keep using the runtime installed by
  `aidevops buzz` and the 0.5 agent store.

## Remove

Settings → Plugins → aidevops → Remove. aidevops agents stop with it. Their
worktrees stay in the aidevops worktree folder for normal worktree cleanup.

## Checks

- Manifest: `cargo run -q -p buzzodz-plugins -- --home <empty temp dir> plugin install <this folder>`
  in a buzz-app checkout.
- Module: `node --check plugin.js`.
- Launcher: send an ACP `initialize` and `session/new` to
  `aidevops buzz acp --member <name> --project <folder>` over stdio; stdout
  must carry only JSON-RPC lines, and closing stdin must end it with exit 0.
