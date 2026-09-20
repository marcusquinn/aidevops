#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Opt-in, synthetic-only Jev examples. No agents or continuations are executed."""

import argparse
import http.client
import json
import math
import os
import re
import urllib.error
import urllib.request
from dataclasses import dataclass, field

MODEL = "jev-1.13.0"
ENDPOINT = "https://api.typesafe.ai/v1/systemone"
MAX_RESPONSE = 65536
MAX_CONTINUATIONS = 12


def example_request(name):
    """Fixed public synthetic fixtures: deliberately no arbitrary payload input."""
    if name == "continuation":
        state = {
            "objective": "Classify three synthetic business descriptions",
            "accepted_work": "Two descriptions classified and checked",
            "remaining": "Classify the third supplied description",
            "blockers": "None; no external action needed",
        }
        questions = {"useful": {
            "type": "noul",
            "instructions": "Would a nudge advance the remaining authorised work now?",
        }}
    elif name == "seo":
        state = {
            "query": "how to clean a reusable water bottle",
            "passage": "Wash the bottle with warm soapy water, rinse, and air dry.",
        }
        questions = {"relevance": {
            "type": "score",
            "instructions": "How directly does the passage answer the query?",
            "criteria": ["Unrelated", "Related but no instructions", "Direct instructions"],
        }}
    elif name == "directory":
        state = "Example Workshop repairs bicycles and sells replacement bicycle tyres."
        questions = {
            "category": {
                "type": "choice",
                "instructions": "Which category describes the stated business activity?",
                "criteria": {
                    "bicycle_services": "Bicycle repair or parts",
                    "accounting": "Bookkeeping or accounting services",
                    "unknown": "Neither category is supported by the text",
                },
            },
            "repair": {"type": "noul", "instructions": "Does the business repair bicycles?"},
        }
    else:
        raise ValueError("Unknown example")
    return {"model": MODEL, "state": state, "questions": questions}


def bounded_number(value, lower=0, upper=1):
    return (type(value) in (int, float) and lower <= value <= upper
            and math.isfinite(value))


def distribution(value, keys):
    if not isinstance(value, dict) or set(value) != set(keys):
        raise ValueError("Invalid probability keys")
    if not all(bounded_number(number) for number in value.values()):
        raise ValueError("Invalid probability")
    if not math.isclose(sum(value.values()), 1, abs_tol=0.001):
        raise ValueError("Invalid probability sum")
    return value


def validate_answer(answer, question):
    """Project only validated fields; never echo provider prose or error bodies."""
    if not isinstance(answer, dict) or answer.get("type") != question["type"]:
        raise ValueError("Invalid answer type")
    kind = question["type"]
    if kind == "noul":
        if not bounded_number(answer.get("noul")):
            raise ValueError("Invalid noul")
        return {"type": kind, "noul": answer["noul"]}
    if not bounded_number(answer.get("confidence")):
        raise ValueError("Invalid confidence")
    result = {"type": kind, "confidence": answer["confidence"]}
    if kind == "choice":
        probabilities = distribution(answer.get("probabilities"), question["criteria"])
        choice = answer.get("choice")
        if not isinstance(choice, str) or choice not in probabilities:
            raise ValueError("Invalid choice")
        if probabilities[choice] != max(probabilities.values()):
            raise ValueError("Choice is not highest probability")
        result["choice"] = choice
    else:
        legend = {str(i): text for i, text in enumerate(question["criteria"])}
        probabilities = distribution(answer.get("probabilities"), legend)
        score = answer.get("score")
        if answer.get("legend") != legend or not bounded_number(score, 0, len(legend) - 1):
            raise ValueError("Invalid score or legend")
        expected = sum(int(key) * value for key, value in probabilities.items())
        if not math.isclose(score, expected, abs_tol=0.01):
            raise ValueError("Score is inconsistent with probabilities")
        result.update(score=score, legend=legend)
    result["probabilities"] = probabilities
    return result


def validate_response(payload, request):
    if not isinstance(payload, dict) or payload.get("model") != MODEL:
        raise ValueError("Missing or changed model")
    answers = payload.get("answers")
    if not isinstance(answers, dict) or set(answers) != set(request["questions"]):
        raise ValueError("Missing or extra answers")
    return {key: validate_answer(answers[key], question)
            for key, question in request["questions"].items()}


def accepted(answers):
    """Illustrative thresholds only, not calibrated production policy."""
    for answer in answers.values():
        if answer["type"] == "noul":
            if 0.1 < answer["noul"] < 0.9:
                return False
        elif answer["confidence"] < 0.9 or answer.get("choice") == "unknown":
            return False
    return True


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # Never forward the bearer credential to another location.
        return None


def fetch_response(request, key):
    req = urllib.request.Request(
        ENDPOINT, data=json.dumps(request).encode("utf-8"), method="POST",
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    )
    opener = urllib.request.build_opener(NoRedirect())
    with opener.open(req, timeout=15) as response:
        raw = response.read(MAX_RESPONSE + 1)
    if len(raw) > MAX_RESPONSE:
        raise ValueError("Oversized response")
    return json.loads(raw)


def evaluate(request, key):
    if not key:
        return {"status": "fallback_required", "reason": "missing_key"}
    try:
        answers = validate_response(fetch_response(request, key), request)
    except urllib.error.HTTPError as error:
        error.close()
        return {"status": "fallback_required", "reason": "http_error", "http_status": error.code}
    except (OSError, ValueError, TypeError, RecursionError,
            http.client.HTTPException, urllib.error.URLError):
        return {"status": "fallback_required", "reason": "unavailable_or_invalid_response"}
    if not accepted(answers):
        return {"status": "fallback_required", "reason": "abstained"}
    return {"status": "accepted", "model": MODEL, "answers": answers}


@dataclass
class ContinuationBudget:
    """Single-process example, NOT durable host state or a runtime stop hook.

    An actual host must persist and atomically reserve the objective's budget,
    supply verified progress tokens, and recheck cancellation before dispatch.
    """

    limit: int = MAX_CONTINUATIONS
    used: int = field(default=0, init=False)
    seen_progress: set = field(default_factory=set, init=False)

    def __post_init__(self):
        if type(self.limit) is not int or not 0 <= self.limit <= MAX_CONTINUATIONS:
            raise ValueError("Continuation limit must be between zero and twelve")

    def reserve(self, probability, *, progress_token, enabled=False,
                authorised=False, unfinished=False, cancelled=True,
                blocked=True, choosing=True):
        # These flags are trusted host facts, never model-returned authorization.
        if any(value is not True for value in (enabled, authorised, unfinished)):
            return False
        if any(value is not False for value in (cancelled, blocked, choosing)):
            return False
        if not bounded_number(probability) or probability < 0.9:
            return False
        if (not isinstance(progress_token, str) or not progress_token.strip()
                or progress_token in self.seen_progress):
            return False
        if self.used >= min(self.limit, MAX_CONTINUATIONS):
            return False
        self.used += 1
        self.seen_progress.add(progress_token)
        return True


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--example", choices=("directory", "seo", "continuation"), default="directory")
    parser.add_argument("--live", action="store_true", help="Send one fixed synthetic request")
    parser.add_argument("--key-env", default="TYPESAFE_API_KEY", help="Injected environment variable name")
    args = parser.parse_args(argv)
    if not re.fullmatch(r"TYPESAFE_API_KEY(?:_[A-Z0-9_]+)?", args.key_env):
        parser.error("Use TYPESAFE_API_KEY or a suffixed account variable")
    request = example_request(args.example)
    if not args.live:
        result = {"status": "dry_run", "request": request}
    else:
        result = evaluate(request, os.environ.get(args.key_env))
    print(json.dumps(result, sort_keys=True))
    return 2 if result["status"] == "fallback_required" else 0


if __name__ == "__main__":
    raise SystemExit(main())
