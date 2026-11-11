#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Offline GitHub transport for checkpoint tests; unknown operations fail closed."""

import datetime as dt
import json
import os
import pathlib
import sys


def comment(number, body, author="worker", association="COLLABORATOR"):
    return {"id": number, "node_id": "fixture-" + str(number), "body": body, "user": {"login": author},
            "author_association": association, "created_at": "2026-09-05T12:00:00Z"}


def set_issue(args, data):
    issue = data["issue"]
    issue["labels"] = [label for label in issue["labels"] if not label["name"].startswith("status:")]
    issue["labels"].append({"name": "status:" + args[3]})
    owners = {a["login"] for a in issue["assignees"]}
    for index, arg in enumerate(args):
        if arg == "--add-assignee":
            owners.add(args[index + 1])
        elif arg == "--remove-assignee":
            owners.discard(args[index + 1])
    issue["assignees"] = [{"login": owner} for owner in sorted(owners)]


def comments_request(args, data, state):
    if "POST" not in args:
        print(json.dumps([data["comments"]] if "--slurp" in args else data["comments"]))
        return
    body = next(a[5:] for a in args if a.startswith("body="))
    mode = os.environ.get("CHECKPOINT_TEST_DRIFT", "")
    prefix = "CLAIM_RELEASED " if "release" in mode else "DISPATCH_LEASE phase=terminal "
    fail = mode.startswith("fail-") and body.startswith(prefix) and not data.get("post_failed")
    if fail:
        data["post_failed"] = True
        state.write_text(json.dumps(data))
        if mode.endswith("before"):
            sys.exit(1)
    number = max((c["id"] for c in data["comments"]), default=0) + 1
    added = comment(number, body, "next-worker")
    added["created_at"] = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    data["comments"].append(added)
    data["issue"]["updated_at"] = added["created_at"]
    state.write_text(json.dumps(data))
    if fail:
        sys.exit(1)
    print(number)


def read_response(args, data):
    if args[:2] == ["api", "graphql"]:
        requested = [arg[6:] for arg in args if arg.startswith("ids[]=")]
        print(json.dumps({"data": {"nodes": [
            {"id": c["node_id"], "lastEditedAt": c.get("lastEditedAt")}
            for c in data["comments"] if c.get("node_id") in requested]}}))
        return
    responses = {
        "api user": "next-worker" if "--jq" in args else json.dumps({"login": "next-worker"}),
        "api repos/owner/repo/collaborators/maintainer/permission": "write",
        "pr view": json.dumps(data["pr"]),
        "issue view": json.dumps({**data["issue"], "state": "OPEN"}),
        "api repos/owner/repo/issues/123": json.dumps(data["issue"]),
        "api repos/owner/repo/issues/123/events?per_page=100": json.dumps([data.get("issue_events", [])]),
    }
    key = " ".join(args[:2])
    if key not in responses:
        raise ValueError("Unexpected mocked GitHub call: " + repr(args))
    print(responses[key])


def issue_update_request(args, data, state):
    mode = os.environ.get("CHECKPOINT_TEST_DRIFT", "")
    if args[3] == "in-progress" and mode.startswith("transfer-"):
        labels = data["issue"]["labels"][:]
        owners = data["issue"]["assignees"][:]
        if mode != "transfer-before":
            set_issue(args, data)
            if mode == "transfer-status":
                data["issue"]["assignees"] = owners
            else:
                data["issue"]["labels"] = labels
        state.write_text(json.dumps(data))
        sys.exit(1)
    failure = data.pop("transfer_failure", None)
    if failure:
        if failure == "status":
            data["issue"]["labels"] = [label for label in data["issue"]["labels"]
                                       if not label["name"].startswith("status:")]
            data["issue"]["labels"].append({"name": "status:in-progress"})
        elif failure == "add":
            data["issue"]["assignees"].append({"login": "next-worker"})
        elif failure == "remove":
            data["issue"]["assignees"] = []
        state.write_text(json.dumps(data))
        sys.exit(1)
    set_issue(args, data)
    state.write_text(json.dumps(data))


def main(args):
    state = pathlib.Path(os.environ["CHECKPOINT_TEST_STATE"])
    data = json.loads(state.read_text())
    if args[0] == "--drift":
        mode = args[1]
        if mode == "head":
            data["pr"]["headRefOid"] = "2" * 40
        elif mode == "owner":
            data["issue"]["assignees"] = [{"login": "replacement-owner"}]
        elif mode == "human":
            number = max(c["id"] for c in data["comments"]) + 1
            added = comment(number, "Interactive session claimed", "maintainer", "OWNER")
            added["created_at"] = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            data["comments"].append(added)
        elif mode not in {"none", "launched", "transfer-before", "transfer-status", "transfer-owner"} and not mode.startswith("fail-"):
            raise ValueError("Unknown checkpoint drift")
        state.write_text(json.dumps(data))
    elif args[0] == "--set-issue":
        issue_update_request(args, data, state)
    elif args[0] == "api" and "/comments" in args[1]:
        comments_request(args, data, state)
    else:
        read_response(args, data)


if __name__ == "__main__":
    main(sys.argv[2:] if sys.argv[1] == "--gh" else sys.argv[1:])
