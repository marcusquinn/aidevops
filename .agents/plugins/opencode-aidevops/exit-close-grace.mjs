// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

export const EXIT_CLOSE_GRACE_MS = 2000;

// GH#39916: "close" waits for every holder of the supervisor's stdio pipes.
// An escaped descendant holding them would leave a failed command in
// running/timing_out with no output. After the supervisor itself has exited,
// finalize with its real status once a short grace for trailing output passes.
export function closeAfterExitGrace({ child, setTimer, clearTimer, finalize }) {
  const timer = setTimer(() => {
    for (const stream of [child.stdout, child.stderr]) stream?.destroy?.();
    finalize();
  }, EXIT_CLOSE_GRACE_MS);
  timer?.unref?.();
  child.once("close", () => clearTimer(timer));
}
