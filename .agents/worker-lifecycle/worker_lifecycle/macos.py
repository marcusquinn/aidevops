"""Unprivileged libproc/sysctl adapter. Native validation is required per platform.

BSDInfo layout is verified against MacOSX13.1.sdk sys/proc_info.h (136 bytes).
See NATIVE-ABI.md for ABI evidence and the private-API exclusions.
"""

import ctypes as c
import errno
import os
import platform
from uuid import UUID

from .process import ObservationUnavailable, ProcessIdentity, ProcessObservation


class BSDInfo(c.Structure):
    _fields_ = [
        (name, c.c_uint32)
        for name in (
            "flags", "status", "xstatus", "pid", "ppid", "uid", "gid",
            "ruid", "rgid", "svuid", "svgid", "reserved",
        )
    ] + [
        ("comm", c.c_char * 16), ("name", c.c_char * 32),
        ("nfiles", c.c_uint32), ("pgid", c.c_uint32), ("jobc", c.c_uint32),
        ("tdev", c.c_uint32), ("tpgid", c.c_uint32), ("nice", c.c_int32),
        ("start_seconds", c.c_uint64), ("start_microseconds", c.c_uint64),
    ]


class MacOSProcesses:
    def __init__(self, installation_id: str):
        if str(UUID(installation_id)) != installation_id:
            raise ValueError("invalid-installation-id")
        if platform.machine() not in {"x86_64", "arm64"}:
            raise ObservationUnavailable("unsupported-macos-architecture")
        if (c.sizeof(BSDInfo), c.alignment(BSDInfo), BSDInfo.pid.offset,
                BSDInfo.uid.offset, BSDInfo.start_seconds.offset,
                BSDInfo.start_microseconds.offset) != (136, 8, 12, 20, 120, 128):
            raise ObservationUnavailable("unsupported-process-abi")
        self.installation_id = installation_id
        self._system = c.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
        self._proc = c.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        self._sysctl = self._system.sysctlbyname
        self._sysctl.argtypes = [c.c_char_p, c.c_void_p, c.POINTER(c.c_size_t), c.c_void_p, c.c_size_t]
        self._sysctl.restype = c.c_int
        self._pidinfo = self._proc.proc_pidinfo
        self._pidinfo.argtypes = [c.c_int, c.c_int, c.c_uint64, c.c_void_p, c.c_int]
        self._pidinfo.restype = c.c_int

    @staticmethod
    def _failure(operation: str) -> ObservationUnavailable:
        reason = "permission-denied" if c.get_errno() in {errno.EPERM, errno.EACCES} else "unavailable"
        return ObservationUnavailable(f"{operation}-{reason}")

    def _boot(self) -> str:
        size = c.c_size_t()
        c.set_errno(0)
        if self._sysctl(b"kern.bootsessionuuid", None, c.byref(size), None, 0) != 0:
            raise self._failure("boot-identity")
        if size.value != 37:
            raise ObservationUnavailable("invalid-boot-identity-size")
        buffer = c.create_string_buffer(size.value)
        c.set_errno(0)
        if self._sysctl(b"kern.bootsessionuuid", buffer, c.byref(size), None, 0) != 0:
            raise self._failure("boot-identity")
        if size.value != 37 or buffer.raw[-1:] != b"\0":
            raise ObservationUnavailable("invalid-boot-identity-size")
        value = buffer.raw[:-1].decode("ascii").lower()
        if str(UUID(value)) != value:
            raise ObservationUnavailable("invalid-boot-identity")
        return value

    def _sample(self, pid: int) -> tuple[str, int, int]:
        info = BSDInfo()
        c.set_errno(0)
        # arg=1 includes zombies: ESRCH then means no entry, not merely zombie.
        count = self._pidinfo(pid, 3, 1, c.byref(info), c.sizeof(info))
        if count == 0 and c.get_errno() == errno.ESRCH:
            raise ProcessLookupError(errno.ESRCH, "process-absent")
        if count == 0:
            raise self._failure("process-metadata")
        if count != c.sizeof(info) or info.pid != pid:
            raise ObservationUnavailable("invalid-process-metadata")
        if info.uid != os.geteuid():
            raise ObservationUnavailable("different-user")
        if info.status not in {1, 2, 3, 4, 5} or info.start_microseconds >= 1_000_000:
            raise ObservationUnavailable("invalid-process-metadata")
        return f"{info.start_seconds}:{info.start_microseconds}", info.status, info.uid

    def capture(self, pid: int) -> ProcessIdentity:
        if type(pid) is not int or not 0 < pid <= 2**31 - 1:  # pylint: disable=unidiomatic-typecheck  # Reject bool
            raise ValueError("invalid-pid")
        try:
            boot = self._boot()
            first = self._sample(pid)
            second = self._sample(pid)
            if first[0] != second[0] or boot != self._boot():
                raise ObservationUnavailable("process-changed-during-sample")
            if second[1] == 5:
                raise ObservationUnavailable("process-already-ended")
            return ProcessIdentity(1, self.installation_id, "darwin", boot,
                                   "host", pid, second[0], second[2])
        except (OSError, ValueError, UnicodeError) as error:
            raise ObservationUnavailable("process-identity-unavailable") from error

    def observe(self, identity: ProcessIdentity) -> ProcessObservation:
        try:
            identity.validate()
            if identity.platform != "darwin" or identity.installation_id != self.installation_id:
                raise ObservationUnavailable("foreign-identity")
            if identity.scope != "host" or identity.uid != os.geteuid():
                raise ObservationUnavailable("foreign-context")
            parts = identity.generation.split(":")
            if len(parts) != 2 or not all(part.isascii() and part.isdigit() for part in parts):
                raise ObservationUnavailable("invalid-process-generation")
            if int(parts[1]) >= 1_000_000:
                raise ObservationUnavailable("invalid-process-generation")
            boot = self._boot()
            result = (ProcessObservation("ended", "previous-boot")
                      if boot != identity.boot_id else self._observe_current(identity))
            if boot != self._boot():
                raise ObservationUnavailable("context-changed")
            return result
        except ObservationUnavailable as error:
            return ProcessObservation("unknown", str(error))
        except (OSError, ValueError, TypeError, AttributeError):
            return ProcessObservation("unknown", "process-identity-unavailable")

    def _observe_current(self, identity: ProcessIdentity) -> ProcessObservation:
        try:
            generation, state, _ = self._sample(identity.pid)
        except ProcessLookupError:
            return ProcessObservation("ended", "pid-absent")
        if generation != identity.generation:
            return ProcessObservation("ended", "pid-reused")
        if state == 5:
            return ProcessObservation("ended", "process-exited")
        return ProcessObservation("alive", "identity-matched")
