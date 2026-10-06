---
description: Owner-signed exact SSH alias authorization for operational workers
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Exact SSH bindings

An SSH alias is not an endpoint. Unknown aliases remain denied. Neither the
parser nor dispatch reads SSH config, keys, or resolves names over the network.
The supported path is an **exact owner-signed command**, not a wildcard host,
filesystem grant, subnet grant, or exemption from the network tier policy.

## Prepare and owner-approve

Use this command shape, substituting a non-secret operator-owned endpoint,
account, port, alias, and remote command. Supply the remote command as one
non-option string (for example `"id -u"`). Keep the exact same argv for preflight
and execution; whitespace changes inside arguments also invalidate approval.

```bash
python3 .agents/scripts/ssh_binding_helper.py prepare --cwd "$AUTHORIZED_REPO" \
  --argv-json '["ssh","-F","/dev/null","-o","HostName=ci.example.com","-o","ProxyCommand=none","-o","ProxyJump=none","-o","ClearAllForwardings=yes","-o","PermitLocalCommand=no","-o","BatchMode=yes","-o","StrictHostKeyChecking=yes","-l","deploy","-p","22","ci-alias","id"]'
```

Preparation writes an **unsigned** request under
`~/.aidevops/ssh-bindings/<command-and-repository-sha256>.json`. It does not
authorize execution. The operator reviews every byte of that request, including
the remote command, repository and endpoint, then signs that exact file using the
existing root-protected approval key:

```bash
sudo ssh-keygen -Y sign \
  -f "$HOME/.aidevops/approval-keys/private/approval.key" \
  -n aidevops-ssh-binding-v1 "$REQUEST_FILE"
```

Do not change the approval key permissions, expose its contents, automate owner
consent, or grant workers access to its directory. The parser reads only the
request, its `.sig` companion, and the installed owner public trust anchor
`~/.aidevops/approval-keys/approval.pub`. As with existing approvals, protect that
trust anchor from worker replacement. Signature verification is offline and
uses a separate namespace from issue/PR approvals. Grants expire after four hours;
remove the request or signature to revoke. Renewal requires a new reviewed,
signed request. Preparation never overwrites an existing grant.

The signed command disables both user and system SSH config (`-F /dev/null`),
pins HostName, account and port, clears forwarding, disables proxies and local
commands, and requires noninteractive host-key verification. All other options,
duplicate options, forwarding, proxy commands, alternate config files and
command/account/port/endpoint changes fail closed. SSH host keys and credentials
still require their existing independently authorized setup; this binding does
not provision them or authorize filesystem reads.

## Preclaim operational requirements

Declare required exact argv arrays in the repository's existing dispatch class
map (`.aidevops.json`):

```json
{
  "dispatch_class_requirements": {
    "operations": {
      "ssh_commands": [["ssh", "ci-alias", "id"]]
    }
  }
}
```

That illustrative **unbound** command defers before claim/launch. Replace it with
the fully pinned, signed argv above. Apply `dispatch-class:operations` to the
operational issue. Alternatively an issue may declare one JSON argv per line:
`requires-ssh: ["ssh", "ci-alias", "id"]`. Such declarations are requirement data,
not approval and never executed. Keep private endpoints/aliases out of public
issue bodies; use the private operator repository's class requirements instead.

Both early and fresh preclaim capability checks use the normal worker
`network-tier-helper.sh check-argv` path. A failed check reports
`ssh_network_requirement_unmet recovery=reference/ssh-bindings.md`, not credential
failure. Bindings are reverified on every check (no cycle cache). The grant is
repository-bound through the exact GitHub origin slug **and installed Git common
directory**, so linked worktrees of that installation can use its grant without
authorizing an unrelated clone with a spoofed origin. Other/multiple origins and
other installations fail closed. Private local identity stays in the local grant.

After verification the endpoint still goes through the existing tier lookup.
Tier 5 wins, including IP/private-network restrictions. A binding never changes
kernel egress policy or weakens backend sandbox requirements; a runner whose
backend cannot reach the endpoint remains blocked. No automatic tier override,
SSH-config read, proxy grant or credential recovery is implied.
