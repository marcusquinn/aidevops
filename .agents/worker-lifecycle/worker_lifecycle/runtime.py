"""Platform selection and early readiness; no persistence or process control."""

import os
import sys

from .process import ObservationUnavailable, ProcessAdapter


def adapter_for(installation_id: str) -> ProcessAdapter:
    if sys.platform == "linux":
        from .linux import LinuxProcesses
        return LinuxProcesses(installation_id)
    if sys.platform == "darwin":
        from .macos import MacOSProcesses
        return MacOSProcesses(installation_id)
    raise ObservationUnavailable("platform-not-implemented")


def require_ready(adapter: ProcessAdapter) -> None:
    """Validate boot and self identity before beginning any target processing.

    Call once per bounded pass. This does not guarantee visibility of other PIDs;
    every observation must still handle subsequent failures independently.
    """
    identity = adapter.capture(os.getpid())
    result = adapter.observe(identity)
    if result.status != "alive":
        raise ObservationUnavailable(f"readiness-{result.reason}")
