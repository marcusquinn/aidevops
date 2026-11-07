"""Single home for lifecycle ownership and mode-bit decisions.

Same-UID processes and administrators remain trusted. Group write is accepted
only when no other principal can use it: the owner's user-private group (the
Ubuntu/Debian `USERGROUPS_ENAB` + umask 002 default) without an extended access
ACL. Other write is never accepted. Callers must not hand-roll `st_mode` checks.
"""

from __future__ import annotations

from dataclasses import dataclass
import errno
import grp
import os
from pathlib import Path
import pwd
import stat
import sys


class FilesystemValidationError(ValueError):
    """A fixed reason code with separate operator-local filesystem context."""

    def __init__(self, reason: str, path: Path, *, violation: str = ""):
        super().__init__(reason)
        self.reason = reason
        self.path = path
        self.violation = violation


def user_private_group(gid: int) -> bool:
    """True when gid is the owner's primary group and no other account is in it.

    umask 002 with user-private groups yields group-writable paths that only the
    owner can write. Shared or unknown groups stay untrusted. The group must also
    carry the owner's login name: NSS sources with enumeration disabled (e.g.
    SSSD) can omit accounts from getpwall(), so a shared primary group such as
    `users` is never accepted on member enumeration alone.
    """
    try:
        owner = pwd.getpwuid(os.getuid())
        group = grp.getgrgid(gid)
    except KeyError:
        return False
    if gid != owner.pw_gid or group.gr_name != owner.pw_name:
        return False
    if any(member != owner.pw_name for member in group.gr_mem):
        return False
    return all(entry.pw_gid != gid or entry.pw_uid == owner.pw_uid for entry in pwd.getpwall())


def no_extended_access_acl(target: Path | int) -> bool:
    """Allow mode-bit exceptions only without a Linux access ACL (file or directory).

    With a POSIX ACL, group mode bits describe the mask, not just the owning
    group's rights. Reject all extended access ACLs rather than trusting named
    entries. Other platforms retain the original no-group-write restriction.
    """
    if sys.platform != "linux":
        return False
    try:
        os.getxattr(target, "system.posix_acl_access")
    except OSError as error:
        # Only a supported query reporting an absent ACL qualifies. ENOTSUP
        # can hide another ACL model (e.g. NFSv4), not prove the absence of ACLs.
        # Fail closed even on ACL-less filesystems rather than guess their model.
        return error.errno == errno.ENODATA
    return False


def is_private_mode(info: os.stat_result) -> bool:
    """No group or other permission bits at all (0600/0700 style)."""
    return not info.st_mode & 0o077


def group_write_is_private(target: Path | int, info: os.stat_result) -> bool:
    """Group write that only the owner can use: owned, user-private group, no ACL."""
    return (info.st_uid == os.getuid() and user_private_group(info.st_gid)
            and no_extended_access_acl(target))


def shared_writable(target: Path | int, info: os.stat_result) -> bool:
    """True when a principal other than the owner could write ``target``.

    Other write always counts; group write counts unless it is private.
    """
    if info.st_mode & 0o002:
        return True
    return bool(info.st_mode & 0o020) and not group_write_is_private(target, info)


@dataclass(frozen=True)
class FilePolicy:
    """Rules for `read_owned_file`; `reason` is the caller's stable reason code.

    ``private`` requires no group/other bits; otherwise only shared write is
    refused.
    """

    reason: str
    max_size: int
    private: bool
    single_link: bool = True


def _file_violation(target: int, info: os.stat_result, policy: FilePolicy) -> str:
    checks = (
        (not stat.S_ISREG(info.st_mode), "wrong-type"),
        (info.st_uid != os.getuid(), "wrong-owner"),
        (policy.single_link and info.st_nlink != 1, "multiple-links"),
        (info.st_size > policy.max_size, "too-large"),
        (policy.private and not is_private_mode(info), "not-private"),
    )
    for failed, violation in checks:
        if failed:
            return violation
    if not policy.private and shared_writable(target, info):
        return "shared-writable"
    return ""


def read_owned_file(path: Path, policy: FilePolicy) -> bytes:
    """Read a bounded regular file owned by the current user, never following links.

    Any violation raises ``FilesystemValidationError(policy.reason)`` so callers
    keep their stable reason codes.
    """
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        violation = _file_violation(descriptor, os.fstat(descriptor), policy)
        if not violation:
            data = stream.read(policy.max_size + 1)
            if len(data) <= policy.max_size:
                return data
            violation = "too-large"
    raise FilesystemValidationError(policy.reason, path, violation=violation)
