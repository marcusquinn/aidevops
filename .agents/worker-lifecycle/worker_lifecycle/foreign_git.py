"""Bounded read-only Git and file hashing for foreign retirement proof."""

import hashlib
import os
from pathlib import Path
import shutil
import subprocess  # nosec B404 # fixed Git argv
import threading


def _git_environment() -> tuple[str, dict[str, str]]:
    git = shutil.which("git")
    if git is None:
        raise ValueError("archive-git-unavailable")
    environment = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    environment.update(GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0")
    return git, environment


def stream_git_sha(path: Path, *arguments: str) -> str:
    """SHA-256 of Git output computed incrementally with bounded memory."""
    git, environment = _git_environment()
    digest = hashlib.sha256()
    with subprocess.Popen(  # nosec B603 # resolved git and literal flags
        [git, "--no-optional-locks", "-C", str(path), *arguments],
        env=environment, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, shell=False,
    ) as process:
        stream = process.stdout
        if stream is None:
            raise ValueError("archive-git-unavailable")
        timer = threading.Timer(120, process.kill)
        timer.start()
        try:
            for chunk in iter(lambda: stream.read(1 << 20), b""):
                digest.update(chunk)
            returncode = process.wait()
        finally:
            timer.cancel()
        if returncode != 0:
            raise subprocess.CalledProcessError(returncode, arguments)
    return digest.hexdigest()


def file_sha(file: Path) -> str:
    """SHA-256 of a file read in bounded chunks."""
    digest = hashlib.sha256()
    with file.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_git(path: Path, *arguments: str, network: bool = False) -> bytes:
    """Run native Git without optional index refreshes or prompts."""
    git, environment = _git_environment()
    return subprocess.run(  # nosec B603 # resolved git, literal flags
        [git, "--no-optional-locks", "-C", str(path), *arguments],
        env=environment, capture_output=True, check=True,
        timeout=60 if network else 120, shell=False,
    ).stdout
