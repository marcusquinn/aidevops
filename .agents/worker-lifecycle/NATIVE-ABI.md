# Native process metadata evidence

## macOS

Operator's native probe: macOS 12.7.6, Darwin 21.6.0, x86-64, Python 3.14.6,
MacOSX13.1.sdk. `proc_bsdinfo` field order was compared with the SDK before calls.
Header `usr/include/sys/proc_info.h` SHA-256:
`ffb6ae2d8d074b7ef146f342d1575454976cd6d6cac9652c06c18271d8f8fb83`.

| Contract | Evidence |
|----------|----------|
| `proc_pidinfo` | `int(int, int, uint64_t, void *, int)`, libproc.h:96 |
| `PROC_PIDTBSDINFO` | selector 3, proc_info.h:707–708 |
| `proc_bsdinfo` | 136 bytes, alignment 8; PID offset 12, UID 20, start seconds 120, microseconds 128 |
| `sysctlbyname` | `int(const char *, void *, size_t *, void *, size_t)`, sys/sysctl.h:794 |
| Boot UUID | `kern.bootsessionuuid`, size-query/read returned 37 bytes including terminator |
| Reaped process | returned 0 with ESRCH |
| Zombie | arg=1 returned 136 bytes with state 5; arg=0 returned 0 with ESRCH |
| Short input buffer | 135-byte buffer returned 0 with ENOMEM |

Start time units are nominally seconds/microseconds. This does not establish a
uniqueness guarantee. Private `PROC_PIDUNIQIDENTIFIERINFO` is intentionally not
used; its executable UUID must not be confused with a process incarnation.
Error semantics were compared with Apple XNU 8020.140.41, not the exact running
kernel source. Runtime byte-count checks do not replace ABI qualification on a
new architecture. Apple Silicon native verification remains outstanding.

An initial Codex-sandbox probe could not read boot identity (EPERM). A later
unprivileged run succeeded; the operator identified the sandbox as the cause.
Report access failures early without prescribing a particular AI host or bypass.

## Linux

Boot identity is `/proc/sys/kernel/random/boot_id`. Process generation is field 22
of `/proc/PID/stat`, parsed after the final command-name closing parenthesis.
The token has kernel tick resolution, not guaranteed infinite uniqueness.
UID, namespace context and stable repeated sampling are checked. No global CWD
scan, systemd dependency or cgroup requirement is imposed for basic observation.
