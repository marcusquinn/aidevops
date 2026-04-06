#!/usr/bin/env python3
"""mitmproxy addon for capturing Claude CLI API traffic.

Used by cch-traffic-monitor.sh capture command.
Requires OUTPUT_FILE environment variable to be set.
"""
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import json
import os
import mitmproxy.http

OUTPUT_FILE = os.environ["OUTPUT_FILE"]


class CCHCapture:
    def __init__(self):
        self.requests = []

    def request(self, flow: mitmproxy.http.HTTPFlow):
        if not self._is_anthropic_request(flow):
            return

        entry = self._build_entry(flow)
        self._parse_body(flow, entry)
        entry["headers"] = self._sanitise_headers(entry["headers"])
        self.requests.append(entry)

    def done(self):
        with open(OUTPUT_FILE, "w") as f:
            json.dump({
                "capture_count": len(self.requests),
                "requests": self.requests,
            }, f, indent=2)

    @staticmethod
    def _is_anthropic_request(flow):
        host = flow.request.pretty_host
        if "api.anthropic.com" not in host and "claude.ai" not in host:
            return False
        if "/v1/messages" not in flow.request.path:
            return False
        return True

    @staticmethod
    def _build_entry(flow):
        return {
            "url": flow.request.pretty_url,
            "method": flow.request.method,
            "path": flow.request.path,
            "headers": dict(flow.request.headers),
            "body": None,
            "billing_header": None,
            "system_blocks": None,
        }

    @staticmethod
    def _parse_body(flow, entry):
        if not flow.request.content:
            return

        try:
            body = json.loads(flow.request.content)
        except json.JSONDecodeError:
            entry["body"] = {"error": "not JSON"}
            return

        entry["body"] = {
            "model": body.get("model"),
            "thinking": body.get("thinking"),
            "speed": body.get("speed"),
            "research_preview_2026_02": body.get("research_preview_2026_02"),
            "context_management": body.get("context_management"),
            "has_tools": "tools" in body,
            "tool_count": len(body.get("tools", [])),
            "message_count": len(body.get("messages", [])),
            "has_metadata": "metadata" in body,
            "betas": body.get("betas"),
            "body_keys": sorted(body.keys()),
        }

        system = body.get("system", [])
        if not isinstance(system, list):
            return

        entry["system_blocks"] = []
        for i, block in enumerate(system):
            if not (isinstance(block, dict) and block.get("type") == "text"):
                continue
            text = block.get("text", "")
            if "billing-header" in text or "x-anthropic" in text:
                entry["billing_header"] = text
            entry["system_blocks"].append({
                "index": i,
                "type": block.get("type"),
                "has_cache_control": "cache_control" in block,
                "text_preview": text[:120] + "..." if len(text) > 120 else text,
            })

    @staticmethod
    def _sanitise_headers(headers):
        safe = {}
        for k, v in headers.items():
            kl = k.lower()
            if kl == "authorization":
                safe[k] = "Bearer <REDACTED>"
            elif kl == "cookie":
                safe[k] = "<REDACTED>"
            else:
                safe[k] = v
        return safe


addons = [CCHCapture()]
