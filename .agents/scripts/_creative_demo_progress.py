# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Keep native-app progress bounded while retaining its full process log."""

import os
import subprocess
import threading
import time

APP_STAGES = {
    "blender": {"geometry", "exported", "rendering", "saved"},
    "freecad": {"solids", "native-saved", "roundtrip"},
}


def progress(phase):
    print(f"AIDEVOPS_PROGRESS: {phase}", flush=True)


def _stage(path):
    try:
        return path.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        return None


def _observe_stages(stop, path, name):
    last = None
    while True:
        stage = _stage(path)
        if stage in APP_STAGES[name] and stage != last:
            progress(f"{name}:{stage}")
            last = stage
        if stop.wait(0.25):
            break
    # The app can finish between checks; retain its last recorded stage.
    stage = _stage(path)
    if stage in APP_STAGES[name] and stage != last:
        progress(f"{name}:{stage}")


def run_app(command, out, name, timeout):
    env = {key: value for key, value in os.environ.items() if key in
           ("PATH", "HOME", "USER", "LANG", "LC_ALL", "SYSTEMROOT", "WINDIR", "DISPLAY", "XDG_RUNTIME_DIR")}
    env["TMPDIR"] = str(out)
    progress(f"{name}:started (limit={timeout}s; log={name}.log)")
    stop = threading.Event()
    started = time.monotonic()
    with (out / f"{name}.log").open("x", encoding="utf-8") as log:
        watcher = threading.Thread(target=_observe_stages, args=(stop, out / f"{name}.stage", name), daemon=True)
        watcher.start()
        try:
            result = subprocess.run(command, env=env, stdin=subprocess.DEVNULL, stdout=log,
                                    stderr=subprocess.STDOUT, timeout=timeout, check=False)
        finally:
            stop.set()
            watcher.join()
    if result.returncode:
        raise ValueError(f"{name} failed with exit {result.returncode}; inspect its retained run log")
    progress(f"{name}:completed (elapsed_s={time.monotonic()-started:.1f})")
