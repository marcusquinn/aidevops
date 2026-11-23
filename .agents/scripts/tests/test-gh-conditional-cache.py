#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""GH#38566: governed REST GETs revalidate with If-None-Match and replay on 304.

Runs the real governor as a subprocess against a fixture `gh` that honours
If-None-Match, so stdout/stderr/exit and attempt metadata are observed at the
process boundary the shim uses.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
GOVERNOR = SCRIPTS / "gh-transport-governor.py"
sys.path.insert(0, str(SCRIPTS))

from gh_conditional_cache import MAX_AGE_SECONDS, prune  # noqa: E402
from gh_conditional_request import eligible, page_frame_replayable  # noqa: E402

FAKE_GH = r'''#!/usr/bin/env python3
import json, os, sys, time
args = sys.argv[1:]
with open(os.environ["FAKE_GH_LOG"], "a", encoding="utf-8") as log:
    log.write(json.dumps(args) + "\n")
state = json.load(open(os.environ["FAKE_GH_STATE"], encoding="utf-8"))
sent = [args[i + 1].split(":", 1)[1].strip() for i, a in enumerate(args[:-1])
        if a in ("-H", "--header") and args[i + 1].lower().startswith("if-none-match:")]
jq = next((args[i + 1] for i, a in enumerate(args[:-1]) if a in ("-q", "--jq")), None)
reset = int(time.time()) + 3600
rate = ("X-Ratelimit-Resource: core\r\nX-Ratelimit-Limit: 5000\r\n"
        "X-Ratelimit-Remaining: 4000\r\nX-Ratelimit-Used: 1000\r\n"
        "X-Ratelimit-Reset: %d\r\n" % reset)
strong = state["etag"].removeprefix("W/")
if state["status"] == 200 and any(tag.removeprefix("W/") == strong for tag in sent):
    sys.stdout.write("HTTP/2.0 304 Not Modified\r\nEtag: %s\r\n%s\r\n" % (strong, rate))
    sys.stderr.write("gh: HTTP 304\n")
    sys.exit(1)
if state["status"] != 200:
    sys.stdout.write("HTTP/2.0 %d Error\r\n%s\r\n" % (state["status"], rate))
    sys.stderr.write("gh: HTTP %d\n" % state["status"])
    sys.exit(1)
etag = "Etag: %s\r\n" % state["etag"] if state["etag"] else ""
# Like GitHub, only a 200 carries Link; the 304 above never does.
link = "Link: %s\r\n" % state["link"] if state.get("link") else ""
body = "%s|%s\n" % (jq, state["body"]) if jq else state["body"] + "\n"
sys.stdout.write("HTTP/2.0 200 OK\r\n%s%s%s\r\n%s" % (etag, link, rate, body))
'''
PAGE = {"AIDEVOPS_GH_PAGINATION_INCLUDE_OWNED": "1"}
NEXT = '<https://api.github.com/repositories/1/issues/1/comments?per_page=2&page=2>; rel="next"'


class GovernorFixture(unittest.TestCase):
    def setUp(self):
        root = Path(os.environ.get("AIDEVOPS_TEMP_DIR", str(Path.home() / ".aidevops/.agent-workspace/tmp")))
        root.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="gh-conditional-", dir=root)
        self.root = Path(self.temp.name)
        self.gh = self.root / "gh"
        self.gh.write_text(FAKE_GH, encoding="utf-8")
        self.gh.chmod(0o700)
        self.log = self.root / "calls.jsonl"
        self.state = self.root / "state.json"
        self.cache_dir = self.root / "transport" / "conditional"
        self.env = {
            **os.environ,
            "GH_TOKEN": "fixture-token-one",
            "AIDEVOPS_GH_QUOTA_OWNER": "fixture-owner",
            "AIDEVOPS_GH_TRANSPORT_STATE_DIR": str(self.root / "transport"),
            "AIDEVOPS_TEMP_DIR": str(self.root / "tmp"),
            "FAKE_GH_LOG": str(self.log),
            "FAKE_GH_STATE": str(self.state),
        }
        for name in ("GITHUB_TOKEN", "GH_HOST", "GH_DEBUG", "AIDEVOPS_GH_CONDITIONAL_CACHE_DISABLE"):
            self.env.pop(name, None)
        self.serve(200, 'W/"v1"', "body-one")

    def tearDown(self):
        self.temp.cleanup()

    def serve(self, status: int, etag: str, body: str, link: str = "") -> None:
        state = {"status": status, "etag": etag, "body": body, "link": link}
        self.state.write_text(json.dumps(state), encoding="utf-8")

    def call(self, *args: str, **env: str):
        metadata = self.root / "metadata.json"
        result = subprocess.run(
            [sys.executable, str(GOVERNOR), str(metadata), str(self.gh), "api", *args],
            capture_output=True, text=True, env={**self.env, **env}, timeout=60,
        )
        return result, json.loads(metadata.read_text(encoding="utf-8"))

    def last_validators(self) -> list[str]:
        args = json.loads(self.log.read_text(encoding="utf-8").splitlines()[-1])
        return [args[i + 1] for i, arg in enumerate(args[:-1])
                if arg == "-H" and args[i + 1].lower().startswith("if-none-match")]

    def entries(self) -> list[Path]:
        if not self.cache_dir.exists():
            return []
        return [path for path in self.cache_dir.iterdir() if not path.name.startswith(".")]


class ConditionalGovernorTest(GovernorFixture):
    def test_unchanged_resource_replays_stdout_for_free(self):
        first, meta = self.call("repos/o/r/issues/1", "--jq", ".state")
        self.assertEqual((first.returncode, first.stdout), (0, ".state|body-one\n"))
        self.assertEqual((meta["status"], meta["cost"]), (200, 1))
        self.assertEqual(self.last_validators(), [])
        second, meta = self.call("repos/o/r/issues/1", "--jq", ".state")
        self.assertEqual(self.last_validators(), ['If-None-Match: W/"v1"'])
        self.assertEqual((second.returncode, second.stdout), (0, ".state|body-one\n"))
        self.assertNotIn("HTTP 304", second.stderr)
        self.assertEqual((meta["status"], meta["cost"]), (304, 0))
        mode = self.cache_dir.stat().st_mode & 0o777, self.entries()[0].stat().st_mode & 0o777
        self.assertEqual(mode, (0o700, 0o600))

    def test_changed_resource_replaces_the_entry(self):
        self.call("repos/o/r/issues/1")
        self.serve(200, 'W/"v2"', "body-two")
        changed, meta = self.call("repos/o/r/issues/1")
        self.assertEqual((changed.stdout, meta["status"]), ("body-two\n", 200))
        replay, meta = self.call("repos/o/r/issues/1")
        self.assertEqual(self.last_validators(), ['If-None-Match: W/"v2"'])
        self.assertEqual((replay.stdout, meta["status"]), ("body-two\n", 304))
        self.assertEqual(len(self.entries()), 1)

    def test_errors_stay_native_and_404_forgets(self):
        self.call("repos/o/r/issues/1")
        self.serve(502, 'W/"v1"', "")
        failed, _ = self.call("repos/o/r/issues/1")
        self.assertNotEqual(failed.returncode, 0)
        self.assertEqual(failed.stdout, "")
        self.assertIn("gh: HTTP 502", failed.stderr)
        self.assertEqual(len(self.entries()), 1, "a transient failure keeps the entry")
        self.serve(404, "", "")
        self.call("repos/o/r/issues/1")
        self.assertEqual(self.entries(), [])
        self.serve(200, 'W/"v3"', "body-three")
        fresh, _ = self.call("repos/o/r/issues/1")
        self.assertEqual((fresh.stdout, self.last_validators()), ("body-three\n", []))

    def test_response_without_etag_is_not_stored(self):
        self.serve(200, "", "no-tag")
        self.call("repos/o/r/issues/1")
        self.call("repos/o/r/issues/1")
        self.assertEqual((self.entries(), self.last_validators()), ([], []))

    def test_other_credential_never_shares_an_entry(self):
        self.call("repos/o/r/issues/1")
        _other, meta = self.call("repos/o/r/issues/1", GH_TOKEN="fixture-token-two")
        self.assertEqual((self.last_validators(), meta["status"]), ([], 200))
        self.assertEqual(len(self.entries()), 2)

    def test_ineligible_shapes_send_no_validator_and_store_nothing(self):
        shapes = [
            ("repos/o/r/issues/1", "--include"),
            ("repos/o/r/issues/1", "--silent"),
            ("repos/o/r/issues/1", "--template", "{{.state}}"),
            ("repos/o/r/issues/1", "--jq", ".updated_at < (now | todate)"),
            ("repos/o/r/issues/1", "--jq", "env.HOME"),
        ]
        for shape in shapes:
            for _ in range(2):
                self.call(*shape)
            self.assertEqual(self.last_validators(), [], shape)
        self.assertEqual(self.entries(), [])
        self.call("repos/o/r/issues/1", AIDEVOPS_GH_CONDITIONAL_CACHE_DISABLE="1")
        self.assertEqual(self.entries(), [])

    def test_caller_validator_is_left_alone(self):
        self.call("repos/o/r/issues/1", "-H", 'If-None-Match: W/"v1"')
        self.assertEqual(self.last_validators(), ['If-None-Match: W/"v1"'])
        self.assertEqual(self.entries(), [])

    def test_corrupt_entry_is_dropped_not_sent(self):
        self.call("repos/o/r/issues/1")
        entry = self.entries()[0]
        entry.write_bytes(b'bad\r\netag\nbody')
        self.call("repos/o/r/issues/1")
        self.assertEqual(self.last_validators(), [])
        self.assertEqual(len(self.entries()), 1, "the fresh 200 re-stores a valid entry")
        self.assertTrue(entry.read_bytes().startswith(b'W/"v1"\n'))


class PageFrameGovernorTest(GovernorFixture):
    """GH#39233: explicit pagination pages revalidate their whole frame."""

    COMMENTS = "repos/o/r/issues/1/comments?per_page=2"

    def page(self, *extra: str, **env: str):
        return self.call(self.COMMENTS, *extra, "--include", **{**PAGE, **env})

    def test_final_page_with_room_replays_the_whole_frame(self):
        self.serve(200, 'W/"p1"', '[{"id":1}]')
        first, _ = self.page()
        second, meta = self.page()
        self.assertEqual(self.last_validators(), ['If-None-Match: W/"p1"'])
        self.assertEqual((second.returncode, second.stdout), (0, first.stdout))
        self.assertTrue(second.stdout.startswith("HTTP/2.0 200 OK"), "the page loop reads the stored frame")
        self.assertNotIn("HTTP 304", second.stderr)
        self.assertEqual((meta["status"], meta["cost"]), (304, 0))

    def test_full_final_page_is_never_replayed(self):
        # An appended comment would land on page 2 and leave this body and
        # ETag unchanged; the 304 carries no Link to reveal it.
        self.serve(200, 'W/"p2"', '[{"id":1},{"id":2}]')
        self.page()
        _second, meta = self.page()
        self.assertEqual((self.last_validators(), self.entries(), meta["status"]), ([], [], 200))

    def test_full_final_counted_page_replays(self):
        # GH#39244: an appended check run changes total_count, so the body
        # and ETag of this full final page change too.
        self.serve(200, 'W/"c1"', '{"total_count":2,"check_runs":[{"id":1},{"id":2}]}')
        first, _ = self.page()
        second, meta = self.page()
        self.assertEqual((meta["status"], second.stdout), (304, first.stdout))

    def test_page_that_links_onward_replays_its_link(self):
        self.serve(200, 'W/"p3"', '[{"id":1},{"id":2}]', link=NEXT)
        self.page()
        replay, meta = self.page()
        self.assertEqual(meta["status"], 304)
        self.assertIn('rel="next"', replay.stdout)

    def test_filtered_final_page_is_not_stored_but_onward_page_is(self):
        self.serve(200, 'W/"p4"', '[{"id":1}]')
        self.page("--jq", ".[].id")
        self.page("--jq", ".[].id")
        self.assertEqual((self.last_validators(), self.entries()), ([], []))
        self.serve(200, 'W/"p5"', '[{"id":1},{"id":2}]', link=NEXT)
        self.page("--jq", ".[].id")
        _replay, meta = self.page("--jq", ".[].id")
        self.assertEqual(meta["status"], 304)

    def test_caller_requested_headers_stay_live(self):
        self.serve(200, 'W/"p6"', '[{"id":1}]')
        for _ in range(2):
            self.page(AIDEVOPS_GH_PAGINATION_INCLUDE_OWNED="0")
        self.assertEqual((self.last_validators(), self.entries()), ([], []))


class EligibilityAndPruneTest(unittest.TestCase):
    def test_eligibility_rules(self):
        self.assertTrue(eligible(["api", "repos/o/r/pulls/2", "--jq", ".head.sha"], "core", False, False))
        self.assertTrue(eligible(["api", "repos/o/r/issues", "-f", "state=open", "-X", "GET"], "core", False, False))
        self.assertFalse(eligible(["api", "search/issues", "-f", "q=x"], "search", False, False))
        self.assertFalse(eligible(["api", "repos/o/r/issues/1", "--jq=now"], "core", False, False))
        self.assertFalse(eligible(["api", "repos/o/r/issues/1", "--header=if-modified-since: x"], "core", False, False))

    def test_page_frame_replay_rules(self):
        def replayable(endpoint, items, *extra, link=b""):
            head = b"HTTP/2.0 200 OK\r\nLink: " + link + b"\r\n\r\n" if link else b"HTTP/2.0 200 OK\r\n\r\n"
            body = json.dumps([{"id": n} for n in range(items)]).encode()
            return page_frame_replayable(["api", endpoint, *extra, "--include"], head, body)

        self.assertTrue(replayable("repos/o/r/issues/1/comments", 29), "default page size is 30")
        self.assertFalse(replayable("repos/o/r/issues/1/comments", 30))
        self.assertTrue(replayable("repos/o/r/issues/1/comments?per_page=500", 99), "GitHub caps at 100")
        self.assertFalse(replayable("repos/o/r/issues/1/comments?per_page=500", 100))
        self.assertFalse(replayable("repos/o/r/notifications?per_page=100", 1))
        self.assertFalse(replayable("repos/o/r/issues/1/comments?per_page=0", 0))
        self.assertFalse(replayable("repos/o/r/issues", 1, "-f", "per_page=100", "-X", "GET"))
        self.assertFalse(replayable("repos/o/r/issues/1/comments", 1, "-q", ".[].id"))
        self.assertTrue(replayable("repos/o/r/issues/1/comments", 30, link=NEXT.encode()))
        last_only = b'<https://api.github.com/x?page=1>; rel="prev", <https://api.github.com/x?page=1>; rel="first"'
        self.assertFalse(replayable("repos/o/r/issues/1/comments", 30, link=last_only))
        self.assertTrue(replayable("repos/o/r/issues/1/comments", 3, link=last_only))
        self.assertFalse(page_frame_replayable(["api", "repos/o/r/issues/1", "--include"],
                                               b"HTTP/2.0 200 OK\r\n\r\n", b'{"id":1}'))

    def test_counted_list_replay_rules(self):
        def counted(body, *extra):
            return page_frame_replayable(["api", "repos/o/r/commits/s/check-runs?per_page=1", *extra, "--include"],
                                         b"HTTP/2.0 200 OK\r\n\r\n", body.encode())

        self.assertTrue(counted('{"total_count":1,"check_runs":[{"id":1}]}'), "full counted final page")
        self.assertTrue(counted('{"total_count":0,"statuses":[],"state":"pending"}'))
        self.assertFalse(counted('{"total_count":true,"check_runs":[{"id":1}]}'), "bool is not a count")
        self.assertFalse(counted('{"total_count":"1","check_runs":[{"id":1}]}'))
        self.assertFalse(counted('{"check_runs":[{"id":1}]}'))
        self.assertFalse(counted('{"total_count":1,"check_runs":[{"id":1}]}', "--jq", ".check_runs"),
                         "filtered stdout cannot show total_count")

    def test_prune_removes_only_stale_entries(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            stale, fresh = directory / "stale", directory / "fresh"
            stale.write_bytes(b'"a"\n')
            fresh.write_bytes(b'"b"\n')
            old = time.time() - MAX_AGE_SECONDS - 60
            os.utime(stale, (old, old))
            self.assertEqual(prune(directory), 1)
            self.assertEqual([path.name for path in directory.iterdir()], ["fresh"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
