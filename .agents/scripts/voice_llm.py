#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
LLM bridge (OpenCode) for voice-bridge.py.

Extracted from voice-bridge.py to reduce file complexity.
Sends text to OpenCode (run or serve mode) and returns the response.
"""

import logging
import os
import subprocess
import time

log = logging.getLogger("voice-bridge")


class OpenCodeBridge:
    """Sends text to OpenCode and gets response.

    Uses --attach to connect to a running opencode serve instance for
    lower latency (~6s vs ~30s cold start). Falls back to standalone
    opencode run if no server is available.
    """

    def __init__(self, model="opencode/claude-sonnet-4-6", cwd=None, server_port=4096):
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

    def _build_command(self, text):
        """Build the opencode CLI command list."""
        cmd = ["opencode", "run", "-m", self.model]

        if self.use_attach:
            cmd.extend(["--attach", self.server_url])

        if self.session_id:
            cmd.extend(["-s", self.session_id])
        else:
            # Continue last session for conversational context
            cmd.append("-c")

        cmd.append(text)
        return cmd

    @staticmethod
    def _clean_response(raw):
        """Strip ANSI codes and TUI artifacts from opencode output."""
        import re

        response = re.sub(r"\x1b\[[0-9;]*m", "", raw).strip()

        # Remove opencode TUI artifacts from stdout. This is fragile
        # and may need updating if opencode changes its output format.
        # No structured output mode (e.g. --json) is available yet.
        clean_lines = []
        for line in response.split("\n"):
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
        return " ".join(clean_lines)

    def query(self, text):
        """Send text to OpenCode and return response."""
        cmd = self._build_command(text)

        start = time.time()
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=120,
                cwd=self.cwd,
            )
            response = self._clean_response(result.stdout)
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
