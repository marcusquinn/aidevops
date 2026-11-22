"""Read-only process inspection CLI. No storage or execution side effects."""

import argparse
import json
import sys

from .process import ObservationUnavailable, ProcessIdentity
from .runtime import adapter_for, require_ready


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--installation-id", required=True, help="stable UUID of this installation")
    commands = parser.add_subparsers(dest="command", required=True)
    capture = commands.add_parser("capture", help="sample a process identity")
    capture.add_argument("pid", type=int)
    commands.add_parser("observe", help="read one identity JSON object from stdin")
    commands.add_parser("readiness", help="check native APIs and self identity before processing")
    args = parser.parse_args()
    try:
        adapter = adapter_for(args.installation_id)
        require_ready(adapter)
        result: dict[str, object]
        if args.command == "readiness":
            result = {"status": "ready", "platform": sys.platform}
        elif args.command == "capture":
            result = {"identity": adapter.capture(args.pid).to_dict()}
        else:
            payload = sys.stdin.read(16385)
            if len(payload) > 16384:
                raise ValueError("identity-input-too-large")
            result = adapter.observe(ProcessIdentity.from_dict(json.loads(payload))).to_dict()
        print(json.dumps({"schema": 1, "mode": "observe-only", **result}, sort_keys=True))
        return 2 if result.get("status") == "unknown" else 0
    except ObservationUnavailable as error:
        print(json.dumps({"schema": 1, "mode": "observe-only", "status": "unknown",
                          "reason": str(error)}, sort_keys=True))
        return 2
    except (ValueError, TypeError, OSError, AttributeError, RecursionError):
        # Do not echo input, paths, command lines or arbitrary exception text.
        print(json.dumps({"schema": 1, "mode": "observe-only", "status": "unknown",
                          "reason": "invalid-input-or-observation-unavailable"}, sort_keys=True))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
