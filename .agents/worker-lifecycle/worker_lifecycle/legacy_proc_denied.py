"""Handle denied process references without weakening census safeguards."""

from .protected_proc import ProcessCensusUnavailable


def inspect_denied_references(path, task, proc, stage, observers):
    require_daemon, require_protected = observers
    try:
        require_daemon(path, task, proc)
    except ProcessCensusUnavailable as unavailable:
        unavailable.observation.update({"stage": stage, "daemon_cause": "daemon-evidence-unavailable"})
        raise
    except ValueError as error:
        if str(error) == "live-process-reference":
            raise
        cause = str(error.__cause__)
        if cause not in {"unknown-daemon", "daemon-not-older", "invalid-process-clock"}:
            cause = "daemon-evidence-unavailable"
        try:
            require_protected(path, task, proc)
        except ProcessCensusUnavailable as unavailable:
            unavailable.observation.update({"stage": stage, "daemon_cause": cause})
            raise unavailable from error
