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
        if args.mode == "capabilities":
            if any((args.directory, args.run_id, args.recipient, args.cwd, command)):
                raise ValueError("arguments")
            result, code = lease.CAPABILITIES, 0
        elif args.mode == "seal" and args.directory and args.run_id and args.recipient:
            if command or args.cwd:
                raise ValueError("arguments")
            raw = sys.stdin.buffer.read(lease.LIMIT + 1)
            if len(raw) > lease.LIMIT:
                raise ValueError("input")
            result, code = lease.seal(args.directory, args.run_id, args.recipient,
                                      json.loads(raw)), 0
        elif args.mode == "remove" and args.directory and args.run_id:
            if command or args.cwd or args.recipient:
                raise ValueError("arguments")
            result, code = lease.remove(args.directory, args.run_id), 0
        elif args.mode == "exec" and args.directory and args.run_id and args.cwd:
            if args.recipient:
                raise ValueError("arguments")
            result, code = lease.execute(args.directory, args.run_id, command,
                                         args.cwd, args.budget_seconds)
        else:
            raise ValueError("arguments")
    except (Exception, KeyboardInterrupt):  # noqa: BLE001 - errors can contain decrypted values
        result, code = {"status": "lease-refused", "version": lease.VERSION}, 1
    print(json.dumps(result))
    return code


if __name__ == "__main__":
    sys.exit(main())
