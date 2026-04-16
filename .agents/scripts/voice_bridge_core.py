#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
VoiceBridge main loop and pipeline for voice-bridge.py.

Extracted from voice-bridge.py to reduce file complexity.
Coordinates VAD, STT, LLM, and TTS into a real-time voice loop.
"""

import logging
import sys
import threading
import time
from collections import deque

import numpy as np
import sounddevice as sd

from voice_stt import SileroVAD

# Audio constants — must match voice-bridge.py
SAMPLE_RATE = 16000
CHANNELS = 1
DTYPE = "int16"
BLOCK_SIZE = 512  # 32ms at 16kHz (Silero VAD requires exactly 512 samples)
SILENCE_DURATION = 1.5  # seconds of silence before processing
MIN_SPEECH_DURATION = 0.5  # minimum speech duration to process
MAX_RECORD_DURATION = 30  # max seconds per utterance

log = logging.getLogger("voice-bridge")


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

    # ── Audio capture phase ──────────────────────────────────────────────

    def _flush_speech_buffer(self) -> None:
        """Flush accumulated speech frames to the audio buffer and reset state."""
        full_audio = np.concatenate(self.speech_frames)
        duration = len(full_audio) / SAMPLE_RATE
        if duration >= MIN_SPEECH_DURATION:
            self.audio_buffer.append(full_audio)
        self.speech_frames = []
        self.speech_detected = False
        self.silence_counter = 0

    def _handle_speech_frame(self, audio) -> None:
        """Process a single audio frame during active speech detection."""
        self.silence_counter += 1
        self.speech_frames.append(audio)
        silence_seconds = self.silence_counter * BLOCK_SIZE / SAMPLE_RATE
        if silence_seconds >= SILENCE_DURATION:
            self._flush_speech_buffer()

    def _check_max_duration(self) -> None:
        """Force-flush if recording exceeds maximum duration."""
        if not self.speech_detected:
            return
        total_samples = sum(len(f) for f in self.speech_frames)
        if total_samples / SAMPLE_RATE > MAX_RECORD_DURATION:
            self._flush_speech_buffer()

    def _audio_callback(self, indata, frames, time_info, status):
        """Called by sounddevice for each audio block.

        Mute mic during TTS playback to prevent speaker-to-mic feedback.
        Without acoustic echo cancellation (AEC), TTS audio bleeds into the
        mic and triggers false speech detection. Barge-in is not supported;
        implementing it would require hardware AEC or a software AEC library.
        """
        if status:
            log.debug(f"Audio status: {status}")

        audio = np.frombuffer(indata, dtype=np.int16).copy()

        if self.is_speaking:
            return

        if self.vad.is_speech(audio):
            self.speech_detected = True
            self.silence_counter = 0
            self.speech_frames.append(audio)
        elif self.speech_detected:
            self._handle_speech_frame(audio)

        self._check_max_duration()

    # ── Transcription phase ──────────────────────────────────────────────

    _EXIT_PHRASES = [
        "that's all", "thats all", "that is all",
        "all for now", "i'm done", "im done", "we're done",
        "end voice", "stop listening", "goodbye", "good bye",
        "go back", "back to text", "end conversation",
        "end session", "stop voice", "quit voice",
        "see you later", "talk to you later",
    ]

    _VOICE_PROMPT = (
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

    def _transcribe_audio(self, audio) -> tuple[str, float]:
        """Run STT on audio. Returns (text, elapsed_seconds)."""
        start = time.time()
        text = self.stt.transcribe(audio)
        return text, time.time() - start

    def _is_exit_phrase(self, text: str) -> bool:
        """Check if transcribed text contains an exit phrase."""
        text_lower = text.strip().lower().rstrip(".")
        return any(phrase in text_lower for phrase in self._EXIT_PHRASES)

    def _build_query(self, text: str, first_query: bool) -> str:
        """Build LLM query, prepending voice prompt on first query."""
        if first_query:
            return f"{self._VOICE_PROMPT}\n\nUser: {text}"
        return text

    # ── Command dispatch phase ───────────────────────────────────────────

    def _dispatch_to_llm(self, query_text: str) -> tuple[str, float]:
        """Send query to LLM. Returns (response, elapsed_seconds)."""
        start = time.time()
        response = self.llm.query(query_text)
        return response, time.time() - start

    # ── TTS playback phase ───────────────────────────────────────────────

    def _speak_response(self, response: str) -> float:
        """Play TTS response with mic muting. Returns elapsed seconds."""
        self.is_speaking = True
        start = time.time()
        try:
            self.tts.speak(response)
        except Exception as e:
            log.error(f"TTS error: {e}")
        finally:
            self.is_speaking = False
        return time.time() - start

    def _process_utterance(self, audio, first_query: bool) -> tuple[bool, bool]:
        """Process one utterance through STT → LLM → TTS pipeline.

        Returns (should_exit, first_query_used).
        """
        duration = len(audio) / SAMPLE_RATE
        log.info(f"Processing {duration:.1f}s of speech...")

        text, stt_time = self._transcribe_audio(audio)
        if not text or len(text.strip()) < 2:
            log.info("STT returned empty/short text, skipping")
            return False, first_query

        log.info(f"STT ({stt_time:.1f}s): \"{text}\"")
        self.transcript.append(("user", text))

        if self._is_exit_phrase(text):
            log.info(f"Exit phrase detected: \"{text}\"")
            self.tts.speak("Bye for now.")
            return True, first_query

        query_text = self._build_query(text, first_query)
        response, llm_time = self._dispatch_to_llm(query_text)
        log.info(f"LLM ({llm_time:.1f}s): \"{response[:80]}...\"")
        self.transcript.append(("assistant", response))

        tts_time = self._speak_response(response)
        total = stt_time + llm_time + tts_time
        log.info(
            f"Round-trip: {total:.1f}s "
            f"(STT:{stt_time:.1f} LLM:{llm_time:.1f} TTS:{tts_time:.1f})"
        )
        return False, False

    def _process_loop(self):
        """Background thread: STT → LLM → TTS pipeline coordinator."""
        first_query = True

        while self.running:
            if not self.audio_buffer:
                time.sleep(0.1)
                continue

            audio = self.audio_buffer.popleft()
            should_exit, first_query = self._process_utterance(audio, first_query)
            if should_exit:
                self.running = False
                break

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
