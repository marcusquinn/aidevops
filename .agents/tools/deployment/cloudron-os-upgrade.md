---
description: Cloudron host OS-upgrade runbook (Ubuntu 22.04 -> 24.04 -> 26.04) with GRUB, network, API and agent-safety traps
mode: subagent
tools:
  read: true
  bash: true
  webfetch: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Cloudron Host OS Upgrade (22.04 -> 24.04 -> 26.04)

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Official guides**: `docs.cloudron.io/guides/upgrade-ubuntu-24` and `docs.cloudron.io/guides/upgrade-ubuntu-26`. They assume an interactive SSH session and a healthy host; this runbook covers the traps they omit.
- **Order**: one hop at a time (22.04 -> 24.04, verify, then 24.04 -> 26.04). Never skip a release.
- **Scope**: root SSH on the Cloudron host. Provider-neutral except the clearly labelled Hetzner section.
- **Agent rule**: never issue `reboot` in the same parallel tool batch as package operations (see Trap 8).
- **Related**: `tools/deployment/cloudron-server-ops-skill.md`, `services/hosting/cloudron.md`, `services/hosting/hetzner.md`.

<!-- AI-CONTEXT-END -->

## 1. Preflight Gates (all must pass before each hop)

- [ ] **Cloudron version** meets the minimum in the official guide for the target release: `cloudron-support --version` (or the dashboard footer). Update Cloudron first if not.
- [ ] **dpkg clean**: `dpkg --audit` prints nothing; `apt-get check` succeeds.
- [ ] **GRUB debconf matches real disks** (Trap 1): `debconf-show grub-efi-amd64 grub-pc` compared with `ls -l /dev/disk/by-id/`.
- [ ] **Boot mode known** (Trap 2): `test -d /sys/firmware/efi && echo UEFI || echo BIOS`.
- [ ] **Network owner inventoried** (Trap 3): see section below.
- [ ] **Fresh Cloudron backup** completed and verified in the dashboard (Trap 7). A provider snapshot is not a substitute.
- [ ] **Provider snapshot** taken, noting that it excludes attached Volumes and CIFS Storage Boxes.
- [ ] **Baseline saved**: `cloudron list` output (app, domain, state, image) stored off-host for the post-hop diff.
- [ ] **All updates applied** (Trap 5) and no pending reboot: `test -f /var/run/reboot-required`.
- [ ] **Out-of-band access** available (provider console/rescue) in case SSH does not return.

## 2. Traps and Detection

### Trap 1: Stale GRUB debconf device IDs cause an infinite prompt loop

After a provider disk change, `grub-efi/install_devices` can reference a by-id disk that no longer exists. The `shim-signed` postinst calls `grub-multi-install --target=x86_64-efi`, which loops forever on the prompt even with `DEBIAN_FRONTEND=noninteractive`, hanging `dpkg --configure -a`.

```bash
debconf-show grub-efi-amd64 grub-pc | rg install_devices
ls -l /dev/disk/by-id/
# Correct BEFORE any apt run (example value; use the real by-id path or device):
echo "grub-efi-amd64 grub-efi/install_devices multiselect /dev/disk/by-id/<real-disk-id>" | debconf-set-selections
echo "grub-pc grub-pc/install_devices multiselect /dev/disk/by-id/<real-disk-id>" | debconf-set-selections
```

### Trap 2: BIOS-booted hosts only ship `grub-efi-amd64`

Some providers (including Hetzner Cloud x86) boot via BIOS while images ship `grub-efi-amd64` plus `grub-pc-bin`. Package upgrades never refresh the BIOS core image in the `BIOS boot` partition. After each release upgrade, before reboot:

```bash
test -d /sys/firmware/efi || { grub-install --target=i386-pc /dev/sda && update-grub; }
```

Use the actual boot disk (`lsblk`) instead of `/dev/sda` if different.

### Trap 3: Legacy ifupdown vs netplan

Older images ship a cloud-init generated ifupdown config (`50-cloud-init.cfg` in the ifupdown `interfaces.d` directory). Observed: a stale IPv6 /64 there (old address preferred as source, so all outbound IPv6 broke) duplicating a correct netplan config; and a host configured only by ifupdown while netplan targeted a non-existent NIC name. ifupdown survived 22.04 -> 26.04 in testing, but inventory before reboot:

```bash
ip -br addr; ip -6 route
ls /etc/netplan/ /etc/network/interfaces.d/ 2>/dev/null
netplan get 2>/dev/null; dpkg -l ifupdown | tail -1
systemctl is-active systemd-networkd NetworkManager networking
```

Decide which system owns the primary NIC, and compare the IPv6 prefix with the provider API/console. Remove stale duplicates only after confirming the correct config is active.

### Trap 4: Non-interactive release upgrade via transient unit

Run the upgrade detached from SSH so a dropped session does not kill it, with all prompts answered "keep" (matching the guide):

```bash
systemd-run --unit=cloudron-os-upgrade \
  --setenv=DEBIAN_FRONTEND=noninteractive \
  -p StandardInput=null \
  -p StandardOutput=append:/root/os-upgrade.log \
  -p StandardError=append:/root/os-upgrade.log \
  do-release-upgrade -f DistUpgradeViewNonInteractive
```

Create the log first as root-owned `0600`. Expect SSH on port 22 to refuse connections for 10-20 minutes during the configure phase. Monitor via provider metrics (CPU/network), open-port probes and `systemctl status cloudron-os-upgrade` once SSH returns; do not retry SSH aggressively.

### Trap 5: `do-release-upgrade` refuses until all updates are applied

```bash
apt-get update && apt-get dist-upgrade -y          # handles held-back packages
apt-get -s upgrade | rg -i phased                   # list phased updates
apt-get install -y <phased-package>                 # install them explicitly
test -f /var/run/reboot-required && echo "reboot first (separate step)"
```

### Trap 6: 26.04 post-steps vary per host

- `sudo-rs` may or may not be installed: check `sudo --version` before assuming GNU sudo behaviour.
- MySQL 8.0 is removed. Follow the official 26.04 guide: stop the `box` service, `apt install mysql-server` (installs 8.4), re-run Cloudron's box setup script (`box/setup/start.sh` in the Cloudron install tree), then start `box`.

### Trap 7: Provider snapshots exclude Volumes and CIFS Storage Boxes

Hetzner snapshots exclude attached Volumes and CIFS Storage Boxes. Cloudron app data on volumes is protected only by the Cloudron backup, so the backup must be fresh even when a snapshot exists. Confirm the backup timestamp in the dashboard or `cloudron-support` output before starting.

### Trap 8: Agent safety, reboot isolation

Never issue a reboot in the same parallel tool batch as package operations; an agent did this and interrupted a post-upgrade apt step. Sequence: package work completes and `dpkg --audit` is clean -> GRUB step (Trap 2) -> inspect result -> separate, single reboot call -> wait for SSH.

### Trap 9: Cloudron API access gotchas

- Cloudron 10 CLI sessions can be invalidated by DB migrations: old `cloudron login` tokens return 401. Re-authenticate (or use a fresh scoped token) rather than assuming the server is down.
- Cloudron 10.1 stores `apiTokens.accessToken` as SHA-256; a raw token cannot be read back from the database.
- Dashboards proxied by Cloudflare return `error code: 1010` to Python's default User-Agent. This looks like a 403 auth failure but is not; send an explicit `User-Agent` header.

### Trap 10: TLS observation (informational)

On 26.04 (OpenSSL 3.5.5, nginx 1.28.3) Cloudron's host nginx on 443 negotiates `X25519MLKEM768` by default with no Cloudron config change; on 24.04 (OpenSSL 3.0) it was refused. Classic X25519/P-256 stay accepted.

```bash
openssl s_client -connect my.example.com:443 -groups X25519MLKEM768 </dev/null 2>&1 | rg -i "group|error"
openssl s_client -connect my.example.com:443 -groups X25519 </dev/null 2>&1 | rg -i "group|error"
```

## 3. Per-Hop Procedure

1. Pass all preflight gates (section 1).
2. `apt-get update && apt-get dist-upgrade -y`; install phased updates; reboot (isolated call) if `reboot-required`.
3. Start the upgrade with the transient unit (Trap 4); monitor via provider metrics and port probes.
4. When SSH returns: `systemctl is-active cloudron-os-upgrade`, read the log tail, `dpkg --audit`, `lsb_release -a`.
5. Post-hop steps: BIOS GRUB refresh (Trap 2) before reboot; on 26.04 the `sudo-rs` check and MySQL 8.4 steps (Trap 6).
6. Re-check network ownership and IPv6 (Trap 3); then a single isolated reboot (Trap 8).
7. Verify (section 4) before starting the next hop.

## 4. Verification

- App list diff against the saved baseline: `cloudron list` vs baseline, all apps `running`/`installed`.
- Host services: `cloudron-support --check-services` and `cloudron-support --troubleshoot`.
- External HTTP checks: dashboard (`https://my.example.com`) and a sample of app domains return expected status.
- IPv4 and IPv6 outbound: `curl -4 -sS https://example.com -o /dev/null -w '%{http_code}\n'` and the same with `-6`.
- TLS group probe (Trap 10) and certificate validity.
- Fresh Cloudron backup after success, then delete provider snapshots per retention policy.

## 5. Hetzner Cloud Specifics

- x86 Cloud servers boot via BIOS: apply Trap 2 after every release upgrade.
- Snapshots exclude Volumes and Storage Boxes (Trap 7).
- Compare host IPv6 /64 with the Cloud Console or API (Trap 3).
- Use the Console/rescue system as out-of-band access if SSH stays closed past 30 minutes.
- Keep server names, IPs and tokens out of public notes; use placeholders.
