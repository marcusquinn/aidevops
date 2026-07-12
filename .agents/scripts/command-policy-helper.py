#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Runtime-neutral, argv-first shell-command safety-floor decisions."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

from command_policy_config import (  # noqa: F401 -- compatibility facade re-exports
    PolicyError,
    _default_policy_path,
    _decision,
    _has_required_guard,
    _load_policy,
    _parse_error,
    _policy_error,
    _validate_policy_guards,
    _validate_policy_rules,
    _validate_policy_shape,
)
from command_policy_matchers import (  # noqa: F401 -- compatibility facade re-exports
    _canonical_operand,
    _git_parts,
    _has_flag,
    _is_root_or_home_operand,
    _is_temp_operand,
    _matches,
    _matches_git,
    _matches_rm,
    _rm_operands,
    _short_flags,
)
from command_policy_evaluation import (  # noqa: F401 -- compatibility facade re-exports
    _EvaluationOptions,
    _canonical_guard_path,
    _evaluate_canonical_git,
    _evaluate_static,
    _evaluate_worker_network,
    _evaluation_options,
    _network_guard_path,
    evaluate_invocations,
)
from command_policy_dispatch import CommandParseError, _validate_argv, analyze_network_argv  # noqa: F401 -- compatibility facade re-exports
from command_policy_http import (  # noqa: F401 -- compatibility facade re-exports
    _analyze_curl,
    _curl_connect_option,
    _curl_destination_option,
    _curl_other_arg,
    _curl_resolve_option,
    _curl_short_value_index,
    _option_value,
)
from command_policy_git import (  # noqa: F401 -- compatibility facade re-exports
    _analyze_git,
    _analyze_git_remote,
    _classify_git_candidate,
    _git_network_candidate,
    _record_git_config_overrides,
)
from command_policy_network import (  # noqa: F401 -- compatibility facade re-exports
    _add_destination,
    _git_effective_cwd,
    _host_candidate,
    _normalize_host,
    _resolve_git_remote,
)
from command_policy_transport import (  # noqa: F401 -- compatibility facade re-exports
    _analyze_scp,
    _analyze_ssh,
    _classify_scp_option,
    _scp_arg,
    _ssh_arg,
    _ssh_extended_option,
    _ssh_forward_destination,
    _ssh_value_option,
)
from command_policy_runtime import (  # noqa: F401 -- compatibility facade re-exports
    WORKER_ENV_KEYS,
    _argument_parser,
    _network_action,
    _report_policy_error,
    _worker_from_environment,
)
from command_policy_wget import _analyze_wget, _wget_arg, _wget_execute_option  # noqa: F401 -- compatibility facade re-exports
from command_policy_parser import (  # noqa: F401 -- compatibility facade re-exports
    SHELL_OPERATORS,
    _expand_argv,
    _scan_supported_shell,
    _shell_invocations,
    _shell_quote_state,
    _validate_shell_character,
)
from command_policy_wrappers import (  # noqa: F401 -- compatibility facade re-exports
    SHELLS,
    _consume_option,
    _expand_launcher as _expand_wrapper_launcher,
    _expand_shell_launcher as _expand_wrapper_shell_launcher,
    _is_attached_value_option,
    _is_combined_short_flags,
    _is_safety_sensitive_assignment,
    _reject_dynamic_launcher,
    _shell_command_index,
    _shell_value_option_index,
    _strip_leading_assignments,
    _unwrap_command,
    _unwrap_env,
    _unwrap_exec,
    _unwrap_simple_wrapper,
    _unwrap_sudo,
    _unwrap_time,
)

# Keep the original module-level private callables available to importlib users.
# Referencing compatibility imports explicitly also satisfies static analyzers.
_COMPAT_EXPORTS = (
    _decision,
    _has_required_guard,
    _canonical_operand,
    _git_parts,
    _EvaluationOptions,
    _canonical_guard_path,
    analyze_network_argv,
    _analyze_curl,
    _curl_connect_option,
    _analyze_git,
    _analyze_git_remote,
    _add_destination,
    _git_effective_cwd,
    _analyze_scp,
    _analyze_ssh,
    WORKER_ENV_KEYS,
    _analyze_wget,
    _wget_arg,
    SHELL_OPERATORS,
    _scan_supported_shell,
    SHELLS,
    _consume_option,
)
__all__ = [name for name in globals() if name.startswith("_") and not name.startswith("__")]

FORBID_EXIT = 20
POLICY_ERROR_EXIT = 21


def _expand_launcher(
    argv: list[str], executable: str
) -> tuple[list[list[str]] | None, list[str]]:
    return _expand_wrapper_launcher(argv, executable, _shell_invocations)


def _expand_shell_launcher(argv: list[str]) -> list[list[str]]:
    return _expand_wrapper_shell_launcher(argv, _shell_invocations)


def _fixture_invocations(fixture: dict[str, Any]) -> tuple[list[list[str]], bool]:
    has_command = "command" in fixture
    has_argv = "argv" in fixture
    if has_command == has_argv:
        raise PolicyError("command policy fixture requires exactly one of command or argv")
    try:
        invocations = _shell_invocations(fixture["command"]) if has_command else _expand_argv(_validate_argv(fixture["argv"]))
    except CommandParseError as exc:
        if fixture.get("rule_id") == "command.parse-error":
            return [], True
        raise PolicyError(f"command policy fixture parse failed: {fixture.get('name', '?')}: {exc}") from exc
    return invocations, False


def _validate_fixtures(policy: dict[str, Any]) -> None:
    for fixture in policy["fixtures"]:
        if not isinstance(fixture, dict) or not all(key in fixture for key in ("name", "decision", "rule_id")):
            raise PolicyError("command policy fixture is incomplete")
        invocations, rejected = _fixture_invocations(fixture)
        if fixture["rule_id"] == "command.parse-error":
            if not rejected:
                raise PolicyError(
                    f"command policy fixture should fail parsing but did not: {fixture['name']}"
                )
            actual = _parse_error("fixture intentionally rejected")
        else:
            actual = _evaluate_static(invocations, "/work", policy)
        if (actual["decision"], actual["rule_id"]) != (fixture["decision"], fixture["rule_id"]):
            raise PolicyError(
                f"command policy fixture failed: {fixture['name']}: "
                f"expected {fixture['decision']}/{fixture['rule_id']}, "
                f"got {actual['decision']}/{actual['rule_id']}"
            )


def _parse_invocations(args: argparse.Namespace) -> list[list[str]]:
    if args.argv_json:
        return _expand_argv(_validate_argv(json.loads(args.argv_json)))
    if args.command:
        return _shell_invocations(args.command)
    return []


def _policy_action(args: argparse.Namespace, invocations: list[list[str]]) -> int:
    policy_path = Path(args.policy) if args.policy else _default_policy_path()
    try:
        policy = _load_policy(policy_path)
        _validate_fixtures(policy)
    except PolicyError as exc:
        return _report_policy_error(args.action, exc)
    if args.action == "validate":
        print(f"Command policy valid: {policy_path}")
        return 0
    if not invocations:
        print(json.dumps(_parse_error("command or argv input is required"), sort_keys=True))
        return FORBID_EXIT
    result = evaluate_invocations(
        invocations,
        args.cwd,
        policy,
        args.canonical_git_guard,
        args.worker or _worker_from_environment(),
        args.worker_id,
        args.network_helper,
    )
    print(json.dumps(result, sort_keys=True))
    return 0 if result["decision"] == "allow" else FORBID_EXIT


def main() -> int:
    args = _argument_parser().parse_args()

    try:
        invocations = _parse_invocations(args)
    except (json.JSONDecodeError, CommandParseError) as exc:
        print(json.dumps(_parse_error(str(exc)), sort_keys=True))
        return FORBID_EXIT
    if args.action == "network-destinations":
        return _network_action(invocations, args.cwd)
    return _policy_action(args, invocations)


if __name__ == "__main__":
    raise SystemExit(main())
