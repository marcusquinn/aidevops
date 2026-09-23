"""Focused offline coverage for YouTube transcript source selection."""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "youtube-transcript.py"
SPEC = importlib.util.spec_from_file_location("youtube_transcript", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class YouTubeTranscriptTest(unittest.TestCase):
    def test_rejects_non_youtube_and_invalid_ids(self):
        for value in ("https://example.com/watch?v=dQw4w9WgXcQ", "http://youtu.be/dQw4w9WgXcQ", "bad"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                MODULE.video_id(value)

    def test_caption_parsing_and_source_preference(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "video.en.srt"
            path.write_text("1\n00:00:01,000 --> 00:00:03,000\n<i>Hello</i> &amp; goodbye\n", encoding="utf-8")
            with patch.object(MODULE.subprocess, "run") as run:
                segments = MODULE.local_captions("https://www.youtube.com/watch?v=dQw4w9WgXcQ", "en", Path(folder))
            self.assertEqual(segments, [{"start": 1.0, "duration": 2.0, "text": "Hello & goodbye"}])
            self.assertTrue(run.called)

    def test_api_requires_explicit_key_without_network(self):
        with patch.dict(MODULE.os.environ, {}, clear=True), patch.object(MODULE, "build_opener") as open_url:
            with self.assertRaises(ValueError):
                MODULE.hosted("https://www.youtube.com/watch?v=dQw4w9WgXcQ", "en")
            open_url.assert_not_called()

    def test_main_captions_no_asr_or_api(self):
        output = io.StringIO()
        with patch.object(sys, "argv", ["youtube-transcript.py", "dQw4w9WgXcQ"]), \
             patch.object(MODULE, "local_captions", return_value=[{"start": 0, "duration": 1, "text": "Hi"}]), \
             patch.object(MODULE, "local_asr") as asr, patch.object(MODULE, "hosted") as api, \
             patch.object(sys, "stdout", output):
            self.assertEqual(MODULE.main(), 0)
        self.assertEqual(json.loads(output.getvalue())["source"], "captions")
        asr.assert_not_called()
        api.assert_not_called()

    def test_main_local_fallback(self):
        output = io.StringIO()
        with patch.object(sys, "argv", ["youtube-transcript.py", "dQw4w9WgXcQ"]), \
             patch.object(MODULE, "local_captions", return_value=None), \
             patch.object(MODULE, "local_asr", return_value=([{"start": 1, "duration": 2, "text": "Hi"}], "en")), \
             patch.object(sys, "stdout", output):
            self.assertEqual(MODULE.main(), 0)
        self.assertEqual(json.loads(output.getvalue())["source"], "local-asr")

    def test_asr_pins_local_backend_not_automatic_cloud_selection(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(MODULE.subprocess, "run") as run:
            def simulate(command, **_kwargs):
                if command[0] == "yt-dlp":
                    (Path(folder) / "audio.wav").write_bytes(b"audio")
                    return type("Result", (), {"returncode": 0})()
                return type("Result", (), {"returncode": 1})()

            run.side_effect = simulate
            with self.assertRaises(ValueError):
                MODULE.local_asr("https://www.youtube.com/watch?v=dQw4w9WgXcQ", "en", Path(folder), "faster-whisper")
            command = run.call_args.args[0]
            self.assertEqual(command[command.index("--backend") + 1], "faster-whisper")

    def test_api_selected_only_explicitly_and_sends_bearer_to_fixed_host(self):
        response = io.BytesIO(json.dumps({"language": "en", "transcript": [
            {"start": 0, "duration": 1, "text": "Hi"}]}).encode())
        output = io.StringIO()
        with patch.dict(MODULE.os.environ, {"TRANSCRIPTAPI_API_KEY": "test-key"}), \
             patch.object(sys, "argv", ["youtube-transcript.py", "dQw4w9WgXcQ", "--source", "api"]), \
             patch.object(MODULE, "build_opener") as opener, patch.object(MODULE, "local_captions") as local, \
             patch.object(sys, "stdout", output):
            opener.return_value.open.return_value.__enter__.return_value = response
            self.assertEqual(MODULE.main(), 0)
            request = opener.return_value.open.call_args.args[0]
        self.assertEqual(request.host, "transcriptapi.com")
        self.assertEqual(request.get_header("Authorization"), "Bearer test-key")
        self.assertEqual(json.loads(output.getvalue())["source"], "transcriptapi")
        local.assert_not_called()


if __name__ == "__main__":
    unittest.main()
