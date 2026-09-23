"""Offline tests for explicit local-only Nemotron diarization."""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

import argparse
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import wave


SCRIPT = Path(__file__).resolve().parents[1] / "diarization-helper.py"
SPEC = importlib.util.spec_from_file_location("diarization_helper", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class DiarizationHelperTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.audio = self.root / "audio.m4a"
        self.model = self.root / "model.gguf"
        self.binary = self.root / "audiocpp_cli"
        self.audio.write_bytes(b"test")
        self.model.write_bytes(b"model")
        self.binary.write_bytes(b"binary")
        self.binary.chmod(0o700)
        self.args = argparse.Namespace(audio=self.audio, model=self.model, binary=str(self.binary),
                                       backend="cpu", threads=4, output=None)

    def test_local_run_preserves_anonymous_turns_and_overlap(self):
        commands = []

        def simulate(command, **_kwargs):
            commands.append(command)
            if command[0] == "ffmpeg":
                with wave.open(command[-1], "wb") as wav:
                    wav.setnchannels(1)
                    wav.setsampwidth(2)
                    wav.setframerate(16000)
                    wav.writeframes(b"\0\0" * 48000)
            else:
                Path(command[command.index("--turns-out") + 1]).write_text(json.dumps([
                    {"start_sample": 16000, "end_sample": 32000,
                     "speaker_id": "speaker_0", "confidence": 0.9},
                    {"start_sample": 24000, "end_sample": 40000,
                     "speaker_id": "speaker_1", "confidence": 0.8},
                ]), encoding="utf-8")
            return argparse.Namespace(returncode=0)

        with patch.object(MODULE.subprocess, "run", side_effect=simulate), \
             patch.dict(MODULE.os.environ, {"AIDEVOPS_TEMP_DIR": str(self.root)}):
            result = MODULE.diarize(self.args)
        self.assertEqual(result["audio_duration"], 3.0)
        self.assertEqual([(t["speaker_id"], t["start"], t["end"]) for t in result["speaker_turns"]],
                         [("speaker_0", 1.0, 2.0), ("speaker_1", 1.5, 2.5)])
        self.assertEqual(commands[1][0], str(self.binary.resolve()))
        self.assertEqual(commands[1][commands[1].index("--backend") + 1], "cpu")

    def test_invalid_label_and_time_fail_closed(self):
        for row in ({"speaker_id": "Alice", "start_sample": 0, "end_sample": 100, "confidence": 1},
                    {"speaker_id": "speaker_0", "start_sample": 0, "end_sample": 64000, "confidence": 1},
                    {"speaker_id": "speaker_0", "start_sample": 0, "end_sample": 100, "confidence": 2}):
            with self.subTest(row=row), self.assertRaises(ValueError):
                MODULE.normalize_turns([row], 3.0)

    def test_missing_model_binary_and_existing_output_do_not_run(self):
        with patch.object(MODULE.subprocess, "run") as run:
            self.args.model = self.root / "missing.gguf"
            with self.assertRaises(ValueError):
                MODULE.diarize(self.args)
            self.args.model = self.model
            self.args.binary = None
            with self.assertRaises(ValueError):
                MODULE.diarize(self.args)
            self.args.binary = str(self.binary)
            self.args.output = self.model
            with self.assertRaises(ValueError):
                MODULE.diarize(self.args)
            run.assert_not_called()

    def test_main_does_not_overwrite_output_and_writes_private_file(self):
        output = self.root / "turns.json"
        self.args.output = output
        with patch.object(sys, "argv", ["diarization-helper.py", str(self.audio), "--model", str(self.model),
                                        "--binary", str(self.binary), "--output", str(output)]), \
             patch.object(MODULE, "diarize", return_value={"speaker_turns": []}):
            self.assertEqual(MODULE.main(), 0)
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            with patch.object(sys, "stderr", io.StringIO()):
                self.assertEqual(MODULE.main(), 1)
        self.assertEqual(json.loads(output.read_text(encoding="utf-8")), {"speaker_turns": []})


if __name__ == "__main__":
    unittest.main()
