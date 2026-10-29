"""Read-only Linux procfs adapter, confined to this user's PID namespace.

Start ticks have kernel clock-tick precision, not a cryptographic uniqueness
guarantee. Evidence never authorizes deletion or proves descendant quiescence.
"""

import os
from pathlib import Path
from uuid import UUID

from .process import ObservationUnavailable, ProcessIdentity, ProcessObservation


class LinuxProcesses:
    def __init__(self, installation_id: str):
        if str(UUID(installation_id)) != installation_id:
            raise ValueError("invalid-installation-id")
        self.installation_id = installation_id

    @staticmethod
    def _context() -> tuple[str, str]:
        try:
            boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
        except PermissionError as error:
            raise ObservationUnavailable("boot-identity-permission-denied") from error
        if str(UUID(boot)) != boot:
            raise ObservationUnavailable("invalid-boot-identity")
        namespace = Path("/proc/self/ns/pid").stat()
        # Verify procfs maps our numeric PID to this process, not an ancestor
        # namespace in a container with an inherited proc mount.
        own = Path("/proc/self/stat").read_text()
        numeric = Path(f"/proc/{os.getpid()}/stat").read_text()
        if int(own.split("(", 1)[0]) != os.getpid():
            raise ObservationUnavailable("procfs-namespace-mismatch")
        if LinuxProcesses._parse(own)[0] != LinuxProcesses._parse(numeric)[0]:
            raise ObservationUnavailable("procfs-context-changed")
        return boot, f"pidns:{namespace.st_dev}:{namespace.st_ino}"

    @staticmethod
    def _parse(raw: str) -> tuple[str, str]:
        fields = raw.rsplit(")", 1)[1].split()
        if len(fields) < 20 or not fields[19].isascii() or not fields[19].isdigit():
            raise ObservationUnavailable("invalid-process-stat")
        if fields[0] not in {"R", "S", "D", "Z", "T", "t", "X", "x", "K", "W", "P", "I"}:
            raise ObservationUnavailable("unsupported-process-state")
        return fields[19], fields[0]

    @staticmethod
    def _sample(pid: int) -> tuple[str, str, int]:
        root = Path(f"/proc/{pid}")
        first = root.stat()
        if first.st_uid != os.getuid():
            raise ObservationUnavailable("different-user")
        generation, state = LinuxProcesses._parse((root / "stat").read_text())
        second_generation, second_state = LinuxProcesses._parse((root / "stat").read_text())
        second = root.stat()
        if (first.st_dev, first.st_ino, first.st_uid) != (second.st_dev, second.st_ino, second.st_uid):
            raise ObservationUnavailable("process-changed-during-sample")
        if generation != second_generation:
            raise ObservationUnavailable("process-changed-during-sample")
        terminal = {"Z", "X", "x"}
        if (state in terminal) != (second_state in terminal):
            raise ObservationUnavailable("process-changed-during-sample")
        return generation, second_state, second.st_uid

    def capture(self, pid: int) -> ProcessIdentity:
        if type(pid) is not int or not 0 < pid <= 2**31 - 1:  # pylint: disable=unidiomatic-typecheck  # Reject bool
            raise ValueError("invalid-pid")
        try:
            before = self._context()
            generation, state, uid = self._sample(pid)
            if before != self._context():
                raise ObservationUnavailable("context-changed")
            if state in {"Z", "X", "x"}:
                raise ObservationUnavailable("process-already-ended")
            return ProcessIdentity(1, self.installation_id, "linux", before[0], before[1], pid, generation, uid)
        except (OSError, ValueError, IndexError) as error:
            raise ObservationUnavailable("process-identity-unavailable") from error

    def observe(self, identity: ProcessIdentity) -> ProcessObservation:
        try:
            identity.validate()
            if identity.platform != "linux" or identity.installation_id != self.installation_id:
                raise ObservationUnavailable("foreign-identity")
            if identity.uid != os.getuid():
                raise ObservationUnavailable("different-user")
            if not identity.generation.isascii() or not identity.generation.isdigit():
                raise ObservationUnavailable("invalid-process-generation")
            before = self._context()
            if identity.boot_id != before[0]:
                result = ProcessObservation("ended", "previous-boot")
            elif identity.scope != before[1]:
                raise ObservationUnavailable("different-pid-namespace")
            else:
                result = self._observe_current(identity)
            if before != self._context():
                raise ObservationUnavailable("context-changed")
            return result
        except ObservationUnavailable as error:
            return ProcessObservation("unknown", str(error))
        except (OSError, ValueError, IndexError, TypeError, AttributeError):
            return ProcessObservation("unknown", "process-identity-unavailable")

    def _observe_current(self, identity: ProcessIdentity) -> ProcessObservation:
        try:
            generation, state, _ = self._sample(identity.pid)
        except FileNotFoundError:
            # stat ENOENT alone could be a race. Check the directory separately;
            # permission errors propagate as unknown, never absence.
            try:
                Path(f"/proc/{identity.pid}").stat()
            except FileNotFoundError:
                return self._confirm_absence(identity.pid)
            return ProcessObservation("unknown", "process-changed-during-sample")
        if generation != identity.generation:
            return ProcessObservation("ended", "pid-reused")
        if state in {"Z", "X", "x"}:
            return ProcessObservation("ended", "process-exited")
        return ProcessObservation("alive", "identity-matched")

    @staticmethod
    def _confirm_absence(pid: int) -> ProcessObservation:
        # Restrictive procfs can hide live processes with ENOENT. Signal zero
        # checks only this PID and sends no signal; existence is not identity.
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return ProcessObservation("ended", "pid-absent")
        except PermissionError:
            return ProcessObservation("unknown", "process-existence-permission-denied")
        return ProcessObservation("unknown", "procfs-visibility-unavailable")
