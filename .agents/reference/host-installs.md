<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Host installs by sessions

Before installing a tool or a temporary workaround:

1. Look for an existing aidevops helper or already available command first; use it
   instead of adding another install when it meets the need.
2. Prefer the host OS package manager for host tools, so its normal update path
   owns them. If installation requires `sudo`, do not run it yourself: give the
   user one exact command for their OS and package, and wait for it to finish.
   Follow the session's permission and dependency-installation rules as well.
3. Install Python packages in a project virtual environment or with `uv tool`,
   never into user or system Python scope. See `tools/code-review/code-standards.md`.
4. Do not put unmanaged binaries under `~/.aidevops/`. Use a managed package
   or an approved location with a clear update and removal path instead.

After every successful install, including a temporary workaround, record it:

```bash
~/.aidevops/agents/scripts/install-record-helper.sh add \
  --name "tool-name" --method "package-manager" --path "/absolute/path/to/tool" \
  --reason "why needed; remove when the workaround is no longer needed" \
  --update "package-manager updates"
```

Use the actual name, method, absolute installed path, reason and update path.
For temporary installs state the specific condition for removal in the reason;
for ongoing installs explain their purpose. Record metadata only, never secrets,
tokens or complete install commands. Re-recording the same name, method and path
does not create a duplicate or update its existing record. If recording fails,
report the failure rather than claiming the install was recorded. Run
`aidevops installs` for the read-only inventory and untracked-install report.
