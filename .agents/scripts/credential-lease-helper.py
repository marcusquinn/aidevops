#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Encrypted lease CLI; values enter only through stdin and leave only in child env."""
import argparse
import json
import sys

import credential_lease as lease


def refuse_arguments(_message):
    raise ValueError("arguments")


def validate_options(args, command, required=(), forbidden=()):
    lease.require(all(getattr(args, name) for name in required), "arguments")
    lease.require(not any(getattr(args, name) for name in forbidden), "arguments")
    lease.require(args.mode == "exec" or not command, "arguments")


def capabilities_command(args, command):
    validate_options(args, command, forbidden=("directory", "run_id", "recipient", "cwd"))
    return lease.CAPABILITIES, 0


def seal_command(args, command):
    validate_options(args, command, ("directory", "run_id", "recipient"), ("cwd",))
    raw = sys.stdin.buffer.read(lease.LIMIT + 1)
    lease.require(len(raw) <= lease.LIMIT, "input")
    return lease.seal(args.directory, args.run_id, args.recipient, json.loads(raw)), 0


def remove_command(args, command):
    validate_options(args, command, ("directory", "run_id"), ("cwd", "recipient"))
    return lease.remove(args.directory, args.run_id), 0


def exec_command(args, command):
    validate_options(args, command, ("directory", "run_id", "cwd"), ("recipient",))
    return lease.execute(args.directory, args.run_id, command, args.cwd, args.budget_seconds)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.error = refuse_arguments
    parser.add_argument("mode", choices=["capabilities", "seal", "exec", "remove"])
    parser.add_argument("--directory")
    parser.add_argument("--run-id")
    parser.add_argument("--recipient")
    parser.add_argument("--cwd")
    parser.add_argument("--budget-seconds", type=int, default=1200)
    argv = sys.argv[1:]
    separator = argv.index("--") if "--" in argv else len(argv)
    command = argv[separator + 1:]
    try:
        args = parser.parse_args(argv[:separator])
        handlers = {"capabilities": capabilities_command, "seal": seal_command,
                    "remove": remove_command, "exec": exec_command}
        result, code = handlers[args.mode](args, command)
    except (Exception, KeyboardInterrupt):  # noqa: BLE001 - errors can contain decrypted values
        result, code = {"status": "lease-refused", "version": lease.VERSION}, 1
    print(json.dumps(result))
    return code


if __name__ == "__main__":
    sys.exit(main())
