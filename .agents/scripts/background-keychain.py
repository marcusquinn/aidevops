#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Non-interactive macOS default-keychain readiness probe.

Exit codes: 0 unlocked, 1 locked or unavailable, 2 probe unsupported
(non-macOS or Security framework missing). SecKeychainGetStatus never prompts.
"""
import ctypes
import ctypes.util
import sys

K_SEC_UNLOCK_STATE_STATUS = 1


def main() -> int:
    if sys.platform != "darwin":
        return 2
    path = ctypes.util.find_library("Security")
    if not path:
        return 2
    try:
        sec = ctypes.CDLL(path)
        ref = ctypes.c_void_p()
        result = 1
        if sec.SecKeychainCopyDefault(ctypes.byref(ref)) == 0 and ref.value:
            status = ctypes.c_uint32(0)
            if sec.SecKeychainGetStatus(ref, ctypes.byref(status)) == 0:
                result = 0 if status.value & K_SEC_UNLOCK_STATE_STATUS else 1
        return result
    except (OSError, AttributeError):
        return 2


if __name__ == "__main__":
    sys.exit(main())
