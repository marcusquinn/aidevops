#!/usr/bin/env python3
"""
Voice Bridge for aidevops - Talk to OpenCode via speech.

Architecture:
  Mic → VAD → STT → OpenCode (run/serve) → TTS → Speaker

Swappable components:
  STT: whisper-mlx (default), faster-whisper, macos-dictation
  TTS: edge-tts (default), macos-say, facebookMMS
  LLM: opencode run (default), opencode serve

Usage:
  python voice-bridge.py [--stt whisper-mlx] [--tts edge-tts] [--tts-voice en-US-GuyNeural]
"""

import argparse
import asyncio
import logging
import os
import subprocess
import sys
import tempfile
import threading
import time
from collections import deque

import numpy as np
import sounddevice as sd

# ─── Logging ──────────────────────────────────────────────────────────

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("voice-bridge")

# ─── Constants ────────────────────────────────────────────────────────

SAMPLE_RATE = 16000
CHANNELS = 1
DTYPE = "int16"
BLOCK_SIZE = 512  # 32ms at 16kHz (Silero VAD requires exactly 512 samples)
VAD_THRESHOLD = 0.5
SILENCE_DURATION = 1.5  # seconds of silence before processing
MIN_SPEECH_DURATION = 0.5  # minimum speech duration to process
MAX_RECORD_DURATION = 30  # max seconds per utterance

# ─── VAD (Silero) ─────────────────────────────────────────────────────


class SileroVAD:
    """Voice Activity Detection using Silero VAD."""

    def __init__(self, threshold=VAD_THRESHOLD):
        import torch

        self.threshold = threshold
        self.model, self.utils = torch.hub.load(
            "snakers4/silero-vad", "silero_vad", trust_repo=True
        )
        self.model.eval()
        log.info("VAD loaded (Silero)")

    def is_speech(self, audio_chunk_int16):
        """Check if audio chunk contains speech. Expects int16 numpy array."""
        import torch

        audio_float = audio_chunk_int16.astype(np.float32) / 32768.0
        tensor = torch.from_numpy(audio_float)
        confidence = self.model(tensor, SAMPLE_RATE).item()
        return confidence > self.threshold


# ─── STT Engines ──────────────────────────────────────────────────────


class WhisperMLXSTT:
    """Lightning Whisper MLX - fastest on Apple Silicon."""

    def __init__(self):
        from lightning_whisper_mlx import LightningWhisperMLX

        self.model = LightningWhisperMLX(
            model="distil-large-v3", batch_size=6, quant=None
        )
        log.info("STT loaded (whisper-mlx distil-large-v3)")

    def transcribe(self, audio_int16):
        """Transcribe int16 audio array to text."""
        audio_float = audio_int16.astype(np.float32) / 32768.0
        result = self.model.transcribe(audio_float)
        text = result.get("text", "").strip()
        return text


class FasterWhisperSTT:
    """Faster Whisper - CTranslate2 backend, CPU optimized."""

    def __init__(self):
        from faster_whisper import WhisperModel

        self.model = WhisperModel(
            "distil-large-v3", device="cpu", compute_type="int8"
        )
        log.info("STT loaded (faster-whisper distil-large-v3)")

    def transcribe(self, audio_int16):
        audio_float = audio_int16.astype(np.float32) / 32768.0
        segments, _ = self.model.transcribe(audio_float, language="en")
        text = " ".join(s.text for s in segments).strip()
        return text


class MacOSDictationSTT:
    """macOS built-in speech recognition (placeholder - uses whisper-mlx)."""

    def __init__(self):
        # macOS SFSpeechRecognizer requires Swift/ObjC bridge
        # Fall back to whisper-mlx for now
        log.warning("macOS dictation not yet implemented, using whisper-mlx")
        self._fallback = WhisperMLXSTT()

    def transcribe(self, audio_int16):
        return self._fallback.transcribe(audio_int16)


# ─── TTS Engines ──────────────────────────────────────────────────────


class EdgeTTS:
    """Microsoft Edge TTS - excellent quality, requires internet."""

    def __init__(self, voice="en-GB-SoniaNeural", rate="+20%"):
        import edge_tts  # noqa: F401 - verify import

        self.voice = voice
        self.rate = rate
        self._playback_proc = None
        self._tmp_path = None
        log.info(f"TTS loaded (edge-tts, voice: {voice}, rate: {rate})")

    def speak(self, text):
        """Convert text to speech and play it. Can be interrupted via stop()."""
        if not text or not text.strip():
            return

        async def _generate():
            import edge_tts

            communicate = edge_tts.Communicate(text, self.voice, rate=self.rate)
            with tempfile.NamedTemporaryFile(
                suffix=".mp3", delete=False
            ) as f:
                tmp_path = f.name
            await communicate.save(tmp_path)
            return tmp_path

        self._tmp_path = asyncio.run(_generate())
        try:
            self._playback_proc = subprocess.Popen(
                ["afplay", self._tmp_path],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            self._playback_proc.wait()
        finally:
            self._playback_proc = None
            if self._tmp_path and os.path.exists(self._tmp_path):
                os.unlink(self._tmp_path)
                self._tmp_path = None

    def stop(self):
        """Interrupt playback immediately."""
        if self._playback_proc and self._playback_proc.poll() is None:
            self._playback_proc.terminate()
            log.info("TTS interrupted (barge-in)")


class MacOSSayTTS:
    """macOS built-in say command - instant, no network needed."""

    def __init__(self, voice="Samantha"):
        self.voice = voice
        self._playback_proc = None
        log.info(f"TTS loaded (macOS say, voice: {voice})")

    def speak(self, text):
        if not text or not text.strip():
            return
        self._playback_proc = subprocess.Popen(
            ["say", "-v", self.voice, text],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        self._playback_proc.wait()
        self._playback_proc = None

    def stop(self):
        """Interrupt playback immediately."""
        if self._playback_proc and self._playback_proc.poll() is None:
            self._playback_proc.terminate()
            log.info("TTS interrupted (barge-in)")


class FacebookMMSTTS:
    """Facebook MMS VITS - local, no network, robotic quality."""

    def __init__(self):
        import torch
        from transformers import VitsModel, AutoTokenizer

        self.model = VitsModel.from_pretrained("facebook/mms-tts-eng")
        self.tokenizer = AutoTokenizer.from_pretrained("facebook/mms-tts-eng")
        self.sample_rate = self.model.config.sampling_rate
        self._interrupted = False
        log.info("TTS loaded (facebook MMS)")

    def speak(self, text):
        if not text or not text.strip():
            return
        import torch

        self._interrupted = False
        inputs = self.tokenizer(text, return_tensors="pt")
        with torch.no_grad():
            output = self.model(**inputs).waveform
        audio = output.squeeze().numpy()
        sd.play(audio, samplerate=self.sample_rate)
        sd.wait()

    def stop(self):
        """Interrupt playback."""
        self._interrupted = True
        sd.stop()
        log.info("TTS interrupted (barge-in)")


# ─── LLM Bridge (OpenCode) ───────────────────────────────────────────


class OpenCodeBridge:
    """Sends text to OpenCode and gets response.

    Uses --attach to connect to a running opencode serve instance for
    lower latency (~6s vs ~30s cold start). Falls back to standalone
    opencode run if no server is available.
    """

    def __init__(self, model="opencode/claude-sonnet-4", cwd=None, server_port=4096):
        self.model = model
        self.session_id = None
        self.cwd = cwd or os.getcwd()
        self.server_url = f"http://127.0.0.1:{server_port}"
        self.server_port = server_port
        self.use_attach = False
        self._check_server()
        mode = "attach" if self.use_attach else "standalone"
        log.info(f"LLM bridge: opencode {mode} (model: {model})")

    def _check_server(self):
        """Check if opencode serve is running."""
        try:
            import urllib.request

            req = urllib.request.Request(self.server_url, method="HEAD")
            urllib.request.urlopen(req, timeout=2)
            self.use_attach = True
            log.info(f"OpenCode server found at {self.server_url}")
        except Exception:
            self.use_attach = False
            log.info("No OpenCode server found, will use standalone mode")

    def query(self, text):
        """Send text to OpenCode and return response."""
        cmd = ["opencode", "run", "-m", self.model]

        if self.use_attach:
            cmd.extend(["--attach", self.server_url])

        if self.session_id:
            cmd.extend(["-s", self.session_id])
        else:
            # Continue last session for conversational context
            cmd.append("-c")

        cmd.append(text)

        start = time.time()
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=120,
                cwd=self.cwd,
            )
            # Strip ANSI escape codes from output
            import re

            raw = result.stdout
            response = re.sub(r"\x1b\[[0-9;]*m", "", raw).strip()

            # Remove opencode TUI artifacts from stdout. This is fragile
            # and may need updating if opencode changes its output format.
            # No structured output mode (e.g. --json) is available yet.
            lines = response.split("\n")
            clean_lines = []
            for line in lines:
                stripped = line.strip()
                if stripped.startswith("> Build+"):
                    continue
                if stripped.startswith("$") and "aidevops" in stripped:
                    continue
                if stripped.startswith("aidevops v"):
                    continue
                if not stripped:
                    continue
                clean_lines.append(stripped)
            response = " ".join(clean_lines)

            elapsed = time.time() - start

            if not response:
                log.warning(
                    f"Empty response from OpenCode (exit={result.returncode})"
                )
                if result.stderr:
                    log.debug(f"stderr: {result.stderr[:200]}")
                return "I couldn't process that. Please try again."

            log.info(
                f"OpenCode responded in {elapsed:.1f}s ({len(response)} chars)"
            )
            return response

        except subprocess.TimeoutExpired:
            log.error("OpenCode timed out (120s)")
            return "The request timed out. Please try again."
        except Exception as e:
            log.error(f"OpenCode error: {e}")
            return f"Error communicating with OpenCode: {e}"


# ─── Voice Bridge (main loop) ────────────────────────────────────────


class VoiceBridge:
    """Main voice bridge - coordinates VAD, STT, LLM, TTS."""

    def __init__(self, stt, tts, llm, input_device=None, output_device=None):
        self.vad = SileroVAD()
        self.stt = stt
        self.tts = tts
        self.llm = llm
        self.input_device = input_device
        self.output_device = output_device
        self.running = False
        self.is_speaking = False  # TTS playback active (mic muted)
        self.transcript = []  # [(role, text), ...] for session handback
        self.audio_buffer = deque()
        self.speech_frames = []
        self.silence_counter = 0
        self.speech_detected = False

    def _audio_callback(self, indata, frames, time_info, status):
        """Called by sounddevice for each audio block."""
        if status:
            log.debug(f"Audio status: {status}")

        audio = np.frombuffer(indata, dtype=np.int16).copy()

        # Mute mic during TTS playback to prevent speaker-to-mic feedback.
        # Without hardware echo cancellation, the TTS audio bleeds into the
        # mic and triggers false barge-in. Use headphones to enable barge-in.
        if self.is_speaking:
            return

        if self.vad.is_speech(audio):
            self.speech_detected = True
            self.silence_counter = 0
            self.speech_frames.append(audio)
        elif self.speech_detected:
            self.silence_counter += 1
            self.speech_frames.append(audio)  # keep trailing silence

            silence_seconds = self.silence_counter * BLOCK_SIZE / SAMPLE_RATE
            if silence_seconds >= SILENCE_DURATION:
                # Speech ended - process it
                full_audio = np.concatenate(self.speech_frames)
                duration = len(full_audio) / SAMPLE_RATE

                if duration >= MIN_SPEECH_DURATION:
                    self.audio_buffer.append(full_audio)

                self.speech_frames = []
                self.speech_detected = False
                self.silence_counter = 0

        # Safety: cap recording length
        if self.speech_detected:
            total_samples = sum(len(f) for f in self.speech_frames)
            if total_samples / SAMPLE_RATE > MAX_RECORD_DURATION:
                full_audio = np.concatenate(self.speech_frames)
                self.audio_buffer.append(full_audio)
                self.speech_frames = []
                self.speech_detected = False
                self.silence_counter = 0

    def _process_loop(self):
        """Background thread: STT → LLM → TTS."""
        # Prepend voice instruction to first query
        voice_prompt = (
            "IMPORTANT: You are in a voice conversation. "
            "Keep ALL responses to 1-2 short sentences. "
            "No markdown, no lists, no code blocks, no bullet points. "
            "Use plain spoken English suitable for text-to-speech. "
            "Do not give long explanations unless asked to elaborate. "
            "The input comes from speech-to-text and may contain transcription "
            "errors. Sanity-check names, paths, and technical terms before acting. "
            "For example 'test.txte' is obviously 'test.txt', 'get hub' is 'GitHub'. "
            "If genuinely ambiguous, ask the user to clarify before proceeding. "
            "You CAN: edit files, run commands, create PRs, git operations, "
            "write to TODO files, and any task that uses your tools. "
            "When asked to do these, execute them and confirm the outcome. "
            "Acknowledge with 'ok, I can do that' before tasks. "
            "Confirm with 'that's done, we've...' and a brief summary when finished. "
            "For ongoing work, say 'I've started [what], what's next?' "
            "You CANNOT: update the interactive TUI session you were launched from, "
            "or share context with it. You are a separate headless session. "
            "If asked something you cannot do, say so honestly. "
            "The user can say 'that's all' or 'bye' to end the voice session."
        )
        first_query = True

        while self.running:
            if not self.audio_buffer:
                time.sleep(0.1)
                continue

            audio = self.audio_buffer.popleft()
            duration = len(audio) / SAMPLE_RATE
            log.info(f"Processing {duration:.1f}s of speech...")

            # STT
            start = time.time()
            text = self.stt.transcribe(audio)
            stt_time = time.time() - start

            if not text or len(text.strip()) < 2:
                log.info("STT returned empty/short text, skipping")
                continue

            log.info(f"STT ({stt_time:.1f}s): \"{text}\"")
            self.transcript.append(("user", text))

            # Check for exit phrases (substring match -- natural speech
            # often wraps exit intent in extra words)
            text_lower = text.strip().lower().rstrip(".")
            exit_phrases = [
                "that's all", "thats all", "that is all",
                "all for now", "i'm done", "im done", "we're done",
                "end voice", "stop listening", "goodbye", "good bye",
                "go back", "back to text", "end conversation",
                "end session", "stop voice", "quit voice",
                "see you later", "talk to you later",
            ]
            if any(phrase in text_lower for phrase in exit_phrases):
                log.info(f"Exit phrase detected: \"{text}\"")
                self.tts.speak("Bye for now.")
                self.running = False
                break

            # LLM - prepend voice instruction on first query
            query_text = text
            if first_query:
                query_text = f"{voice_prompt}\n\nUser: {text}"
                first_query = False

            start = time.time()
            response = self.llm.query(query_text)
            llm_time = time.time() - start
            log.info(f"LLM ({llm_time:.1f}s): \"{response[:80]}...\"")
            self.transcript.append(("assistant", response))

            # TTS (with barge-in support)
            # Mute mic during TTS to prevent speaker-to-mic feedback
            self.is_speaking = True
            start = time.time()
            try:
                self.tts.speak(response)
            except Exception as e:
                log.error(f"TTS error: {e}")
            finally:
                tts_time = time.time() - start
                self.is_speaking = False

            total = stt_time + llm_time + tts_time
            log.info(
                f"Round-trip: {total:.1f}s "
                f"(STT:{stt_time:.1f} LLM:{llm_time:.1f} TTS:{tts_time:.1f})"
            )

    def run(self):
        """Start the voice bridge."""
        self.running = True

        w = sys.stderr.write
        w("\n" + "=" * 50 + "\n")
        w("  aidevops Voice Bridge\n")
        w("=" * 50 + "\n")
        w(f"  STT: {self.stt.__class__.__name__}\n")
        w(f"  TTS: {self.tts.__class__.__name__}\n")
        w(f"  LLM: {self.llm.__class__.__name__} ({self.llm.model})\n")
        w("=" * 50 + "\n")
        w("  Speak naturally. Pause to send.\n")
        if sys.stdin.isatty():
            w("  Esc = interrupt speech, Ctrl+C = quit.\n")
        else:
            w("  Say 'that's all' or 'goodbye' to end.\n")
        w("=" * 50 + "\n\n")

        # Start processing thread
        process_thread = threading.Thread(target=self._process_loop, daemon=True)
        process_thread.start()

        # Start keyboard listener for Esc key
        key_thread = threading.Thread(target=self._key_listener, daemon=True)
        key_thread.start()

        # Start audio capture
        try:
            with sd.RawInputStream(
                samplerate=SAMPLE_RATE,
                channels=CHANNELS,
                dtype=DTYPE,
                blocksize=BLOCK_SIZE,
                device=self.input_device,
                callback=self._audio_callback,
            ):
                log.info("Listening... (speak to interact, Esc to interrupt, Ctrl+C to quit)")
                while self.running:
                    time.sleep(0.1)
        except KeyboardInterrupt:
            sys.stderr.write("\nStopping...\n")
        finally:
            self.running = False
            log.info("Voice bridge stopped")
            self._print_handback()

    def _print_handback(self):
        """Print conversation transcript to stdout for session handback.

        When the voice bridge is launched from an AI tool's Bash, the
        calling agent session can read this output to understand what
        was discussed and done during the voice conversation.
        """
        if not self.transcript:
            return

        print("\n--- Voice Session Transcript ---")
        for role, text in self.transcript:
            prefix = "User:" if role == "user" else "Assistant:"
            print(f"  {prefix} {text}")
        print(f"--- End ({len(self.transcript)} messages) ---\n")

    def _key_listener(self):
        """Listen for Esc key to interrupt TTS playback.

        Requires a real tty on stdin. When launched as a subprocess from
        an AI tool (OpenCode, Claude Code), stdin is a pipe and key
        capture is unavailable -- voice exit phrases still work.
        """
        if not sys.stdin.isatty():
            log.info("No tty on stdin -- Esc key interrupt unavailable (use voice exit phrases)")
            return

        import tty
        import termios

        fd = sys.stdin.fileno()
        old_settings = termios.tcgetattr(fd)
        try:
            tty.setraw(fd)
            while self.running:
                ch = sys.stdin.read(1)
                if ch == "\x1b":  # Esc key
                    if self.is_speaking and hasattr(self.tts, "stop"):
                        self.tts.stop()
                        log.info("TTS interrupted by Esc key")
                elif ch == "\x03":  # Ctrl+C
                    self.running = False
                    break
        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)


# ─── Factory functions ────────────────────────────────────────────────


def create_stt(engine):
    """Create STT engine by name."""
    engines = {
        "whisper-mlx": WhisperMLXSTT,
        "faster-whisper": FasterWhisperSTT,
        "macos-dictation": MacOSDictationSTT,
    }
    if engine not in engines:
        log.error(f"Unknown STT engine: {engine}. Available: {list(engines.keys())}")
        sys.exit(1)
    return engines[engine]()


def create_tts(engine, voice=None, rate=None):
    """Create TTS engine by name."""
    defaults = {
        "edge-tts": ("en-GB-SoniaNeural", EdgeTTS),
        "macos-say": ("Samantha", MacOSSayTTS),
        "facebookMMS": (None, FacebookMMSTTS),
    }
    if engine not in defaults:
        log.error(f"Unknown TTS engine: {engine}. Available: {list(defaults.keys())}")
        sys.exit(1)

    default_voice, cls = defaults[engine]
    if voice is None:
        voice = default_voice

    if engine == "facebookMMS":
        return cls()
    if engine == "edge-tts":
        return cls(voice=voice, rate=rate or "+20%")
    return cls(voice=voice)


# ─── CLI ──────────────────────────────────────────────────────────────


def parse_args():
    parser = argparse.ArgumentParser(
        description="aidevops Voice Bridge - Talk to OpenCode",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s                                    # defaults: whisper-mlx + edge-tts
  %(prog)s --stt faster-whisper               # use faster-whisper STT
  %(prog)s --tts macos-say                    # use macOS say (offline)
  %(prog)s --tts-voice en-US-AriaNeural       # change edge-tts voice
  %(prog)s --model opencode/claude-opus-4-6   # use different model
  %(prog)s --input-device 7 --output-device 8 # MacBook mic + speakers
        """,
    )
    parser.add_argument(
        "--stt",
        choices=["whisper-mlx", "faster-whisper", "macos-dictation"],
        default="whisper-mlx",
        help="Speech-to-text engine (default: whisper-mlx)",
    )
    parser.add_argument(
        "--tts",
        choices=["edge-tts", "macos-say", "facebookMMS"],
        default="edge-tts",
        help="Text-to-speech engine (default: edge-tts)",
    )
    parser.add_argument(
        "--tts-voice",
        default=None,
        help="TTS voice name (default: en-GB-SoniaNeural)",
    )
    parser.add_argument(
        "--tts-rate",
        default="+20%",
        help="TTS speaking rate, e.g. +20%% (default: +20%%)",
    )
    parser.add_argument(
        "--model",
        default="opencode/claude-sonnet-4",
        help="OpenCode model (default: opencode/claude-sonnet-4)",
    )
    parser.add_argument(
        "--cwd",
        default=None,
        help="Working directory for OpenCode (default: current dir)",
    )
    parser.add_argument(
        "--input-device",
        type=int,
        default=None,
        help="Audio input device index (run with --list-devices to see options)",
    )
    parser.add_argument(
        "--output-device",
        type=int,
        default=None,
        help="Audio output device index",
    )
    parser.add_argument(
        "--list-devices",
        action="store_true",
        help="List audio devices and exit",
    )
    parser.add_argument(
        "--list-voices",
        action="store_true",
        help="List available edge-tts voices and exit",
    )
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="Enable debug logging",
    )
    return parser.parse_args()


def list_devices():
    print("\nAudio Devices:")
    print("-" * 60)
    devices = sd.query_devices()
    default_in, default_out = sd.default.device
    for i, d in enumerate(devices):
        marker = ""
        if i == default_in:
            marker += " [DEFAULT INPUT]"
        if i == default_out:
            marker += " [DEFAULT OUTPUT]"
        ins = d["max_input_channels"]
        outs = d["max_output_channels"]
        if ins > 0 or outs > 0:
            print(f"  {i:3d}: {d['name']:<45s} ({ins} in, {outs} out){marker}")
    print()


def list_voices():
    import asyncio

    async def _list():
        import edge_tts

        voices = await edge_tts.list_voices()
        print("\nEdge TTS Voices (English):")
        print("-" * 80)
        for v in voices:
            if v["Locale"].startswith("en-"):
                tags = ", ".join(v.get("VoiceTag", {}).values())
                print(f"  {v['ShortName']:<45s} {v['Gender']:<8s} {tags}")
        print()

    asyncio.run(_list())


def main():
    args = parse_args()

    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)

    if args.list_devices:
        list_devices()
        return

    if args.list_voices:
        list_voices()
        return

    log.info("Initializing voice bridge...")

    stt = create_stt(args.stt)
    tts = create_tts(args.tts, args.tts_voice, args.tts_rate)
    llm = OpenCodeBridge(model=args.model, cwd=args.cwd)

    bridge = VoiceBridge(
        stt=stt,
        tts=tts,
        llm=llm,
        input_device=args.input_device,
        output_device=args.output_device,
    )
    bridge.run()


if __name__ == "__main__":
    main()
