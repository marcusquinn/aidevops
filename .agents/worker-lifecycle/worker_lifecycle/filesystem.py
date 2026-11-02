"""Read-only POSIX path checks and controlled local diagnostic fields.

Same-UID processes and administrators remain trusted. Group write is accepted
only where no other principal can use it: the owner's user-private group, or
below an owned directory that other principals cannot search. Both exceptions
require a Linux directory without an extended access ACL; otherwise extended
ACL models are not evaluated. Other write is never accepted. Never chmod or
create paths.
"""

from __future__ import annotations

from collections.abc import Iterator
from contextlib import contextmanager
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


def filesystem_error_details(error: FilesystemValidationError) -> dict[str, object]:
    """Serialize only this known error, never raw exception or subprocess text."""
    details: dict[str, object] = {
        "reason": error.reason, "filesystem_path": str(error.path),
    }
    if error.violation:
        details["filesystem_violation"] = error.violation
    cause = error.__cause__
    if isinstance(cause, OSError) and cause.errno is not None:
        details["errno"] = cause.errno
    return details


def user_private_group(gid: int) -> bool:
    """True when gid is the owner's primary group and no other account is in it.

    umask 002 with user-private groups (the Ubuntu/Debian `USERGROUPS_ENAB`
    default) yields group-writable directories that only the owner can write.
    Shared or unknown groups stay untrusted. The group must also carry the
    owner's login name: NSS sources with enumeration disabled (e.g. SSSD) can
    omit accounts from getpwall(), so a shared primary group such as `users`
    is never accepted on member enumeration alone.
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


def no_extended_access_acl(directory: Path | int) -> bool:
    """Allow mode-bit exceptions only without a Linux access ACL.

    With a POSIX ACL, group mode bits describe the mask, not just the owning
    group's rights. Reject all extended access ACLs rather than trusting named
    entries. Other platforms retain the original no-group-write restriction.
    """
    if sys.platform != "linux":
        return False
    try:
        os.getxattr(directory, "system.posix_acl_access")
    except OSError as error:
        # Only a supported query reporting an absent ACL qualifies. ENOTSUP
        # can hide another ACL model (e.g. NFSv4), not prove the absence of ACLs.
        # Fail closed even on ACL-less filesystems rather than guess their model.
        return error.errno == errno.ENODATA
    return False


def _seals_descendants(descriptor: int, info: os.stat_result) -> bool:
    """An owned directory nobody else can search hides its descendants' group bits."""
    return (info.st_uid == os.getuid() and not info.st_mode & 0o011
            and no_extended_access_acl(descriptor))


def _check_directory(
    descriptor: int, path: Path, owned_root: Path | None, sealed: bool = False,
) -> bool:
    """Validate one chain component; return whether it seals later components."""
    info = os.fstat(descriptor)
    inside = owned_root is not None and path.is_relative_to(owned_root)
    owners = (os.getuid(),) if inside else (0, os.getuid())
    if info.st_uid not in owners:
        raise FilesystemValidationError("filesystem-path-wrong-owner", path)
    sticky_ancestor = not inside and bool(info.st_mode & stat.S_ISVTX)
    if not sticky_ancestor:
        if info.st_mode & 0o002:
            raise FilesystemValidationError("filesystem-path-externally-writable", path)
        if info.st_mode & 0o020 and not _group_write_is_private(descriptor, info, sealed):
            raise FilesystemValidationError("filesystem-path-externally-writable", path)
    return sealed or _seals_descendants(descriptor, info)


def _group_write_is_private(descriptor: int, info: os.stat_result, sealed: bool) -> bool:
    if not no_extended_access_acl(descriptor):
        return False
    return sealed or (info.st_uid == os.getuid() and user_private_group(info.st_gid))


def _check_path_scope(path: Path, owned_root: Path | None) -> None:
    for candidate in (path, owned_root):
        if candidate is not None:
            if not candidate.is_absolute() or ".." in candidate.parts:
                raise FilesystemValidationError("invalid-filesystem-path", candidate)
    if owned_root is not None and not path.is_relative_to(owned_root):
        raise FilesystemValidationError("invalid-filesystem-path", path)


@contextmanager
def checked_directory(path: Path, *, owned_root: Path | None = None) -> Iterator[int]:
    """Open and check the full chain, yielding its final directory descriptor.

    Ancestors allow root/current-user ownership and sticky system temp paths.
    At/below owned_root require current-user ownership and no external writes;
    group write counts as private only under the module's two exceptions.
    Preserve OSError subclasses, notably FileNotFoundError used by initialization.
    """
    _check_path_scope(path, owned_root)
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    current = Path(path.anchor)
    descriptor = os.open(current, flags)
    sealed = False
    try:
        for component in (*path.parts[1:], None):
            sealed = _check_directory(descriptor, current, owned_root, sealed)
            if component is None:
                break
            current = current / component
            try:
                child = os.open(component, flags, dir_fd=descriptor)
            except OSError as error:
                error.filename = str(current)
                raise
            os.close(descriptor)
            descriptor = child
        yield descriptor
    finally:
        os.close(descriptor)


def _private_stat(path: Path) -> os.stat_result:
    try:
        with checked_directory(path.parent) as parent:
            return os.stat(path.name or ".", dir_fd=parent, follow_symlinks=False)
    except FileNotFoundError:
        raise  # Absence is an initialization/cursor signal, not invalid state.
    except OSError as error:
        component = Path(error.filename) if error.filename else path
        if not component.is_absolute():
            component = path
        raise FilesystemValidationError("filesystem-path-unavailable", component) from error


def validate_private_path(path: Path, *, directory: bool = False) -> None:
    """Check trusted ancestors and a private owned final file/directory.

    Parent directories need integrity, not 0700. Preserve the historical private
    state reason code; a separate violation identifies type, owner or permissions.
    """
    path = path.absolute()
    _check_path_scope(path, None)
    info = _private_stat(path)
    kind = stat.S_ISDIR if directory else stat.S_ISREG
    if not kind(info.st_mode):
        violation = "wrong-type"
    elif info.st_uid != os.getuid():
        violation = "wrong-owner"
    elif info.st_mode & 0o077:
        violation = "not-private"
    else:
        return
    raise FilesystemValidationError(
        "state-path-must-be-private-and-owned", path, violation=violation,
    )
