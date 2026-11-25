---
description: Triage and recovery for macOS login-password rejections, Recovery-mode password resets, set-aside login keychains, and keychain-stored app data
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# macOS Account and Login-Keychain Recovery

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Use when:** a correct Mac login password is rejected; a password was reset
  in Recovery; a `login_renamed_N.keychain-db` appears; keychain prompts loop;
  agent sessions lose ssh, `gh`, signed commits or Chrome; app data stored in
  the keychain (VPN tunnels, tokens) disappears; an unexpected screen-sharing
  indicator needs explaining.
- **Restart first:** if `id -un` prints a number, or ssh/`gh`/signing fail
  while plain HTTPS works, macOS user lookup is broken. Tell the user to
  restart; do not poll or retry for hours (GH#37260).
- **Passwords:** the user types every password at a Terminal or system prompt.
  Never ask for one in chat, never echo, store or log one.
- **Copies only:** test, repair and extract from copies. Ask before
  overwriting or deleting any user file, including earlier copies.
- **Evidence:** label each finding confirmed, hypothesis or unknown. Root-only
  sources (`/var/db/SystemKeys`, the system TCC database) are unknown unless
  the user runs the command.

<!-- AI-CONTEXT-END -->

## 1. Triage: compromise or local fault?

Build a timeline before recovering anything. Read-only commands; most need no
sudo. The aidevops command policy blocks multiline commands, redirection and
`$` expansion, so use single-line commands with whole-second times.

| Question | Evidence |
|----------|----------|
| Who logged in, and when? | `last -30`; `log show --start "<time>" --end "<time>" --predicate 'process == "loginwindow"'` |
| Was the password rejected or changed? | Same window with `process == "opendirectoryd"`, `"authd"`, `"securityd"`; `MKBUnlockDevice` errors; `dscl . -read` of the user's record, key `accountPolicyData` (`passwordLastSetTime`, `failedLoginCount`) |
| Did the Mac sleep, wake or reboot? | `pmset -g log` (filter for Wake, Sleep and Shutdown entries); `uptime`; `last reboot` |
| Was anyone connected remotely? | `screensharingd`, `sshd` and ARD entries in `log show`; `lsof -nP -iTCP -sTCP:LISTEN` for ports 22, 5900 and 3283 |
| Which remote-access agents exist? | `launchctl list`, `/Library/LaunchDaemons`, `/Library/LaunchAgents`, `~/Library/LaunchAgents`; look for TeamViewer, AnyDesk, Splashtop, Acronis/Remotix (`com.nulana.rxagentmac`), ConnectWise, LogMeIn |
| Unknown accounts or admins? | `dscl . -list /Users UniqueID`; `dscl . -read /Groups/admin GroupMembership`; `sudo fdesetup list` (user runs) |
| Did an agent session cause it? | Read-only queries of session databases (`reference/memory-lookup.md`) for `security`, `dscl`, `passwd`, `sysadminctl`, keychain paths |

The menu-bar screen-sharing indicator appears for any screen capture,
including recorders such as ScreenFlow. Ask what was running, and compare with
System Settings → Privacy & Security → Screen & System Audio Recording.

Before removing a remote-access agent, copy its logs to
`~/.aidevops/.agent-workspace/work/<incident>/`, then use the vendor's
uninstaller. Ask the user first.

## 2. What a Recovery-mode reset does

- The reset changes the account password without the old one. The login
  keychain is still encrypted with its own keychain password, which the new
  account password cannot unlock.
- At the next login macOS sets the old keychain aside as
  `~/Library/Keychains/login_renamed_N.keychain-db` and starts a new, empty
  `login.keychain-db`. Items in the old file are not lost, only locked.
- The old file opens only with the password it was last rekeyed with. If a
  fault rewrote it, that may not be any password the user remembers.
- Agent effects: `gh auth token`, ssh keys saved with `--apple-use-keychain`,
  commit signing and Chrome Safe Storage fail or prompt. Background routines
  calling `security find-generic-password` can queue dozens of processes and
  leave an undismissable SecurityAgent dialog; pause them until the live
  keychain is unlocked. Clear an existing queue as in section 3 (GH#37232).

## 3. Test passwords safely

- Account password: `dscl . -authonly <user>` (prompts; no output = match).
  Repeated failures can count towards lockout, so try once per password.
- **Absolute keychain paths only:** every keychain argument passed to `security`
  must be an absolute path, never a bare name or relative path. A bare
  `login.keychain-db` can resolve to the live file in `~/Library/Keychains/`,
  not the recovered copy. Replace `/absolute/path/to/recovery/` below with the
  actual recovery folder; quote paths containing spaces. Unquoted `~/` expands
  to an absolute home path; a quoted `"~/..."` does not.
- Keychain password: copy the file into its own new folder, named exactly
  `login.keychain-db`. Before **each** candidate password test, run
  `security lock-keychain "/absolute/path/to/recovery/login.keychain-db"`.
  Confirm the copy is locked (see the lock-state check below), then have the
  user run `security unlock-keychain "/absolute/path/to/recovery/login.keychain-db"`.
  No output = unlocked, not permission to read every item. An already-unlocked
  copy does not verify a candidate password. Keep the copy until recovery is
  verified, then lock it again using the same absolute path.
  Remove it from any temporary search list before deleting it, with user consent.
- Observed on macOS 26 (cause unknown): identical bytes rejected the correct
  password under another file name and accepted it as `login.keychain-db`.
  Never conclude a password is wrong from a test on a renamed copy.
- Never assume which password opens which file. Ask which password was current
  when that file was last used, and test each candidate separately.
- Check lock state without a prompt via `SecKeychainGetStatus` (Python
  `ctypes` against the Security framework), not commands that may trigger
  SecurityAgent.

### Stuck SecurityAgent dialog

1. Pause background agents, `gh` credential lookups and other keychain callers
   first, so they cannot refill the queue. Inspect processes with
   `ps -axo pid,uid,command`. Identify the current user's pending
   `security find-generic-password` processes; terminate only those confirmed
   PIDs with `kill <pid> ...`. Recheck the queue; do not broadly kill all
   `security` processes or touch another user's processes.
2. If Cancel/OK still cannot dismiss the dialog, identify the current user's
   SecurityAgent PID in the same process listing. Try `kill <SecurityAgent-pid>`;
   if SIGTERM is ignored and the dialog persists, use
   `kill -9 <SecurityAgent-pid>` as a last resort. This interrupts that user's
   active authorization dialogs; launchd respawns SecurityAgent when needed.
3. Have the user unlock the **live** keychain using its full path:
   `security unlock-keychain ~/Library/Keychains/login.keychain-db`.
   Use the live keychain's password, not automatically the recovered copy's old
   password. Confirm access before resuming background callers.

### Item-access prompt rejects the password

An unlocked copy can still show an item-level ACL prompt that rejects known
passwords. Do not keep retrying or infer that the keychain password is wrong;
prefer Keychain Access's **Show password** route:

1. Record the existing user search list with `security list-keychains -d user`.
   If the copy is already listed, leave the list unchanged and do not add it again.
   To make the copy visible, use `security list-keychains -d user -s` followed
   by **every existing absolute path in its original order**, then the copy's
   absolute path. The `-s` option replaces the list; do not discard other entries.
   If the list contains only the live login keychain, for example, run
   `security list-keychains -d user -s ~/Library/Keychains/login.keychain-db "/absolute/path/to/recovery/login.keychain-db"`.
2. Quit and relaunch Keychain Access, select the recovered copy by its location
   (both files may display as "login"), and unlock it with its own password.
   Open the required item, tick **Show password**, and let the user authenticate
   in the GUI. Copy and paste directly into the target app, never into chat,
   command arguments or logs. Clear the clipboard after use. If GUI access also
   fails, treat access as unknown and perform step 3 before stopping; do not
   weaken the item's ACL.
3. On success **or failure**, restore the recorded search list exactly with
   `security list-keychains -d user -s` followed by the original absolute paths
   in their original order. This removes the copy only if this procedure added
   it; a copy already in the recorded list must remain there.
   Verify with `security list-keychains -d user`, then lock the copy. Retain it
   until recovery is verified; removing a search-list entry does not delete it.

## 4. Recover old keychain items

Order of preference:

1. **Old password known:** unlock the set-aside file and move it back, or
   export items with Keychain Access. To restore it as the login keychain,
   first make its password match the current login password: the user runs
   `security set-keychain-password "/absolute/path/to/recovery/login.keychain-db"` and types the old, then the new,
   password. Login does not rekey a keychain whose password differs; it
   prompts, and may reset the keychain if the prompt fails. Before swapping,
   inventory and securely preserve items created in the new login keychain;
   the old copy will not contain them. Include WireGuard tunnel configurations
   and their options (section 5). Quit dependent apps and temporarily suppress
   their login items and background launchers. Keep a dated backup of the
    current `login.keychain-db`, then swap the files and restart. After the
    restart, confirm the login keychain unlocks without a prompt. Open
    WireGuard only to import the preserved configurations (section 5); keep
    other dependent apps and automatic launches paused until all preserved
    items are restored.
2. **Older copy with a known password:** a Time Machine backup, a local APFS
   snapshot, or the previous Mac's `~/Library/Keychains/login.keychain-db`.
   - Local snapshots: `tmutil listlocalsnapshots /`; mount read-only with
     `mount_apfs -o ro -s <snapshot> /System/Volumes/Data <empty-dir>` (may
     need sudo), copy the file, then `umount <empty-dir>`.
   - Snapshots are deleted automatically within about 24 hours. Copy what you
     need early.
   - Recent macOS login keychains can also depend on per-device key material
     outside the file (unified logs show a derived-entropy unlock path backed
     by root-only `/var/db/SystemKeys`). In the incident behind this guide, a
     copy from the previous Mac still opened with its password. A copied
     keychain may also require protected entropy from the source Mac; access
     to `/var/db/SystemKeys` is restricted and obtaining it is not an ordinary
     file-copy step. Check this prerequisite before treating the password or
     copy as unusable. If a copy refuses a password the user is sure of,
     retest it as `login.keychain-db` (section 3) and treat a further failure
     as unknown, not as proof of a wrong password.
3. **Header graft (advanced):** a keychain password change rewraps the same
   database key; items are not re-encrypted. If an older copy of the same
   keychain opens with a known password, its header can unlock a newer copy's
   items. The header is the DbBlob record beginning with magic `fade0711`
   (0xa8 = 168 bytes in the files observed). Copy the newer file, replace its
   DbBlob with the older one, name the result `login.keychain-db` in its own
   folder, and test as in section 3. This fails if the database key was
   rotated (new keychain, not a password change). Work only on copies; never
   graft into the live login keychain.
4. **No usable password or copy:** treat the items as lost. Keep the
   set-aside file in case the password is remembered later.

After restoring: `ssh-add --apple-use-keychain ~/.ssh/id_ed25519` (user types
the passphrase), `gh auth status`, a signed test commit, and a Chrome launch.

## 5. Keychain-stored app data

- Some apps keep their only copy of a configuration in the login keychain. When
  the item cannot be read after a keychain swap, the app may treat it as
  orphaned and delete it at next launch. Snapshot or copy the old keychain
  before restarting, and before reopening such apps.
- **WireGuard (macOS app):** each tunnel config is a generic-password item with
  service `com.wireguard.macos`. To recover, unlock a copy that holds the item
  and find its account with `security dump-keychain "/absolute/path/to/recovery/login.keychain-db"` (attributes only,
  no secrets). Extract the configs from a separate copy before opening
  WireGuard, and keep that copy until recovery is verified: WireGuard may
  delete tunnel items whose preferences are missing at startup. The config contains a private key, so it must never reach the
  transcript: have a script or the user write the
  `security find-generic-password -s com.wireguard.macos -a <account> -w "/absolute/path/to/recovery/login.keychain-db"`
  output straight to a `600` `.conf` file in the agent workspace. Import it in
  WireGuard, confirm the tunnel connects (`scutil --nc list`), then delete the
  plaintext file. On-demand rules live in the system VPN configuration, not the
  item; ask the user to re-check tunnel options after import.

## 6. Change the keychain password

Prefer `security set-keychain-password ~/Library/Keychains/login.keychain-db`;
the user types the old and new passwords at the prompts. The Keychain Access
menu item has moved between macOS releases, so do not guess its location. If
the login keychain already unlocks silently at login, the passwords match and
nothing needs changing.

## 7. Close-out

- Delete temporary keychain copies, plaintext exports and snapshot mounts; keep
  log evidence copies.
- Record the incident summary in the user's notes, not in public issues: no
  hostnames, account IDs, keychain item names or local paths.
- File framework defects (prompt loops, misleading guidance) with
  `framework-issue-helper.sh log`.
