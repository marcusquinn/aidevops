<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Remote OpenCode workers over a private mesh

Run aidevops workers and OpenCode servers on other machines you own (Mac mini, workstation, GPU box, homelab, VPS), reached privately over a mesh VPN. The pattern is transport-neutral: **SSH is the authentication and authorization boundary; the mesh only provides reachability.** Validated between two Macs over Nostr VPN and self-hosted NetBird in GH#23846 and GH#32583.

## Choosing a mesh

Prefer coordination you control and peer-to-peer data paths. Avoid third-party control planes for anything that can reach your workers.

| Mesh | Coordination | Data path | Maturity | aidevops |
|------|--------------|-----------|----------|----------|
| **Nostr VPN** (`nvpn`) | None central: admin-signed roster; discovery via Nostr relays and bootstrap peers unless `direct-only` | Direct UDP; FIPS transit peers as fallback | Experimental, security audit pending | `services/networking/nostr-vpn.md`, `nostr-vpn-helper.sh` |
| **NetBird**, self-hosted | Your management server (AGPL) | Direct WireGuard; your relay as fallback | Production | `services/networking/netbird.md` |
| **Headscale** + Tailscale clients | Your server (open-source control plane) | Direct WireGuard; DERP relays you choose | Mature | Not documented in aidevops yet; use transport `ssh` |
| **Plain WireGuard** or **SSH** | None | Direct only; you manage keys, IPs, NAT/port forwards | Mature | Transport `wireguard` / `ssh` |
| **Tailscale** (hosted) | Vendor control plane | Direct WireGuard; vendor DERP | Mature | Transport `tailscale`; avoid when third-party control is unacceptable |

Two meshes side by side (for example NetBird plus Nostr VPN) give independent paths if one control plane or daemon fails. They do not stack: nvpn rejects CGNAT (`100.64.0.0/10`) endpoint hints and, on macOS, pins its underlay to the physical interface, so it cannot tunnel through NetBird or Tailscale. Keep nvpn off NetBird's UDP `51820`; `nostr-vpn-helper.sh setup-admin` does this.

## 1. Join the machines to a mesh

- **Nostr VPN**: install the app on each device, then run `nostr-vpn-helper.sh update`, `setup-admin` on the first device, `join` on the others, and `approve` on the admin. Each command prints the next one. Then `aliases` and `dns-check <alias>` for `<alias>.nvpn` names. Use `direct-only` to drop third-party bootstrap and relay discovery when devices share a LAN or have reachable endpoints.
- **NetBird**: enrol with a setup key into an `ai-workers` group, and allow only TCP 22 from your controller group.
- Confirm reachability: `ping <peer>` over the mesh address or name.

## 2. SSH key and alias

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub <user>@<peer-mesh-address>   # verify the host-key fingerprint out of band
cat >>~/.ssh/config <<'EOF'
Host mini-nvpn
  HostName mini.nvpn            # or the NetBird IP/FQDN
  User <user>
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
EOF
ssh mini-nvpn hostname
```

The same host key seen over two meshes is expected. Compare the fingerprints rather than accepting blindly.

## 3a. Headless workers (pulse/dispatch)

```bash
remote-dispatch-helper.sh add mini mini.nvpn --user <user>        # transport auto-detected: nvpn
remote-dispatch-helper.sh add mini-nb 100.64.0.10 --user <user>  # netbird (checked against netbird status)
remote-dispatch-helper.sh check mini                              # SSH, AI CLI (nvm-aware), agent forwarding, disk
remote-dispatch-helper.sh dispatch t123 mini --description "..."
```

Route tasks with a `target:<host>` label. Details, credential forwarding and cleanup: `tools/containers/remote-dispatch.md`. Workers receive forwarded API tokens and SSH agent access, so register only machines you trust as much as your workstation, and prefer short-lived tokens.

## 3b. Interactive OpenCode on the remote machine

Keep `opencode serve` on the remote machine's loopback and reach it through SSH. No listener is exposed on the mesh:

```bash
# Terminal 1 (a login shell finds nvm-installed opencode)
ssh -L 127.0.0.1:14096:127.0.0.1:4096 mini-nvpn "zsh -lic 'cd ~ && opencode serve --hostname 127.0.0.1 --port 4096'"
# Terminal 2
opencode attach http://127.0.0.1:14096 --dir <remote project path>
curl -s http://127.0.0.1:14096/path     # health check: returns the remote home
```

Closing SSH can leave the server running: `ssh mini-nvpn 'pkill -f "opencode serve --hostname 127.0.0.1 --port 4096"'`. Only bind to a mesh IP with `OPENCODE_SERVER_PASSWORD` set (`aidevops secret set OPENCODE_SERVER_TOKEN`) and a reviewed trust boundary. `nostr-vpn-helper.sh opencode-guide` prints these steps.

## Troubleshooting

| Symptom | Check |
|---------|-------|
| `check` reports no AI CLI | Update aidevops. Older helpers used non-login shells that missed nvm. Confirm with `ssh <host> 'zsh -lic "command -v opencode"'` |
| `.nvpn` name doesn't resolve | `nostr-vpn-helper.sh dns-check <alias>`: missing aliases (layer 1) or macOS resolver not re-read (layer 2; cycle the network, not mDNSResponder) |
| nvpn peer `pending` | `nostr-vpn-helper.sh conflicts` (port clash); in direct-only mode, endpoints must be LAN, public or DNS, not NetBird/Tailscale |
| NetBird peer Idle | Lazy connections wake on traffic; `netbird status -d` and check policies allow TCP 22 |
