#!/usr/bin/env python3
"""Unit and drift tests for the capability readiness contract."""

import argparse
from contextlib import redirect_stdout
import importlib.util
from http.client import IncompleteRead
import io
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from urllib.error import HTTPError, URLError
from urllib.parse import urlunsplit

TEST_DIR = Path(__file__).resolve().parent
HELPER = TEST_DIR.parent / "capability-readiness-helper.py"
FIXTURE = TEST_DIR / "fixtures" / "capability-readiness-states.json"


class RenderReadinessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        sys.path.insert(0, str(HELPER.parent))
        import capability_render_probe
        cls.probe = capability_render_probe
        spec = importlib.util.spec_from_file_location("readiness_helper", HELPER)
        cls.helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.helper)
        cls.registry = json.loads(cls.helper.DEFAULT_REGISTRY.read_text())

    def setUp(self) -> None:
        self.target = "srv-example123"
        self.secret = "redaction-token-placeholder"
        self.payload = {"id": self.target, "serviceDetails": {
            "runtime": "docker", "url": "https://example.onrender.com",
            "envSpecificDetails": {"dockerCommand": "private-config-placeholder"},
        }}
        self.environment = mock.patch.dict(os.environ, {"RENDER_API_KEY": self.secret})
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.response = mock.MagicMock()
        self.response.status = 200
        self.response.__enter__.return_value = self.response
        self.response.read.return_value = json.dumps(self.payload).encode()
        self.opener = mock.Mock()
        self.opener.open.return_value = self.response
        self.builder = mock.patch.object(self.probe, "build_opener", return_value=self.opener)
        self.build = self.builder.start()
        self.addCleanup(self.builder.stop)

    def route(self, **overrides) -> tuple[int, dict]:
        args = argparse.Namespace(capability="render", runtime="opencode", fixture=None,
                                  target=self.target, operation="read", transport=None,
                                  workdir=None, command="route")
        for name, value in overrides.items():
            setattr(args, name, value)
        with redirect_stdout(io.StringIO()) as output:
            status = self.helper.query_or_route(self.registry, args)
        text = output.getvalue()
        for secret in (self.secret, "private-config-placeholder", "private-error-placeholder"):
            self.assertNotIn(secret, text)
        return status, json.loads(text)

    def test_success_is_exact_get_metadata_only(self) -> None:
        status, output = self.route()
        self.assertEqual(0, status)
        self.assertEqual("route", output["decision"])
        self.assertEqual("Build+", output["owner"])
        self.assertEqual({"provider": "render", "target": self.target, "operation": "read",
                          "resource": "service-metadata", "reason": "ready"}, output["evidence_scope"])
        for dimension in ("authenticated", "authorized", "usable", "reachable"):
            self.assertEqual("true", output["readiness"][dimension])
        self.opener.open.assert_called_once()
        call = self.opener.open.call_args
        request = call.args[0]
        self.assertEqual("GET", request.get_method())
        self.assertEqual(f"https://api.render.com/v1/services/{self.target}", request.full_url)
        self.assertIsNone(request.data)
        self.assertEqual(f"Bearer {self.secret}", request.get_header("Authorization"))
        self.assertEqual(10, call.kwargs["timeout"])
        self.response.read.assert_called_once_with(self.probe.MAX_RESPONSE_BYTES + 1)
        proxy, redirects = self.build.call_args.args
        self.assertEqual({}, proxy.proxies)
        self.assertIsInstance(redirects, self.probe.RejectRedirects)
        self.assertIsNone(redirects.redirect_request(None, None, 302, None, {}, "https://example.test"))

    def test_missing_or_invalid_token_makes_no_requests(self) -> None:
        for token, reason in (("", "missing_token"), ("bad\nprivate-error-placeholder", "invalid_token"),
                              ("x" * 4097, "invalid_token"), ("nonascii-\u00e9", "invalid_token")):
            with self.subTest(reason=reason), mock.patch.dict(os.environ, {"RENDER_API_KEY": token}):
                status, output = self.route()
                self.assertEqual(3, status)
                self.assertEqual(reason, output["evidence_scope"]["reason"])
                self.build.assert_not_called()

    def test_invalid_scopes_rejected_before_credentials_or_requests(self) -> None:
        cases = [({"operation": op}, "render_read_only") for op in ("write", "admin")]
        cases += [({"runtime": name}, "render_unsupported_runtime") for name in ("unknown", "other")]
        cases += [({"target": target}, "render_invalid_target") for target in
                  (None, "", "logical-service", "srv-UPPER", "srv-a/b", "srv-a?x=1", "srv-a\n",
                   "https://private-error-placeholder@example.test")]
        cases += [({"fixture": Path("unread-fixture.json")}, "render_fixture_not_allowed")]
        for kwargs, reason in cases:
            with self.subTest(kwargs=kwargs), mock.patch.object(self.probe.os, "environ") as env:
                status, output = self.route(**kwargs)
                self.assertEqual(2, status)
                self.assertEqual(reason, output["error"])
                env.get.assert_not_called()
                self.build.assert_not_called()
                self.opener.open.assert_not_called()

    def test_direct_probe_scope_checks_cannot_be_bypassed(self) -> None:
        for target, operation, runtime, fixture in (
            (None, "read", "opencode", False), (self.target, "admin", "opencode", False),
            (self.target, "read", "unsupported", False), (self.target, "read", "opencode", True),
        ):
            with self.subTest(operation=operation, runtime=runtime, fixture=fixture):
                with mock.patch.object(self.probe.os, "environ") as env, self.assertRaises(ValueError):
                    self.probe.render_live_evidence(target, operation, runtime, fixture)
                env.get.assert_not_called()
                self.build.assert_not_called()

    def test_provider_errors_fail_closed_and_are_redacted(self) -> None:
        for code, reason in ((301, "redirect_rejected"), (302, "redirect_rejected"),
                             (307, "redirect_rejected"), (308, "redirect_rejected"),
                             (401, "unauthenticated"), (403, "forbidden"),
                             (404, "service_not_found"), (429, "rate_limited"), (500, "http_error")):
            with self.subTest(code=code):
                self.opener.open.side_effect = HTTPError("https://example.test", code,
                    "private-error-placeholder", {"Private": self.secret}, io.BytesIO(self.secret.encode()))
                status, output = self.route()
                self.assertEqual(3, status)
                self.assertEqual(reason, output["evidence_scope"]["reason"])
                self.assertEqual("false", output["readiness"]["authorized"])

    def test_network_errors_are_finite_and_redacted(self) -> None:
        for error in (URLError(self.secret), TimeoutError(self.secret), OSError(self.secret)):
            with self.subTest(error=type(error).__name__):
                self.opener.open.side_effect = error
                status, output = self.route()
                self.assertEqual(3, status)
                self.assertEqual("network_error", output["evidence_scope"]["reason"])

    def test_incomplete_body_does_not_leak_partial_data(self) -> None:
        self.response.read.side_effect = IncompleteRead(self.secret.encode())
        status, output = self.route()
        self.assertEqual(3, status)
        self.assertEqual("network_error", output["evidence_scope"]["reason"])

    def test_target_mismatch_cannot_authorize(self) -> None:
        self.payload["id"] = "srv-other"
        self.response.read.return_value = json.dumps(self.payload).encode()
        status, output = self.route()
        self.assertEqual(3, status)
        self.assertEqual("target_mismatch", output["evidence_scope"]["reason"])

    def test_malformed_and_oversized_responses_fail_closed(self) -> None:
        for body, reason in ((b"not JSON private-error-placeholder", "invalid_response"),
                             (b"\xff", "invalid_response"), (b"[]", "invalid_response"),
                             (b'{"id":"a","id":"b"}', "invalid_response"),
                             (b'{"x":NaN}', "invalid_response"),
                             (b"x" * (self.probe.MAX_RESPONSE_BYTES + 1), "response_too_large")):
            with self.subTest(reason=reason):
                self.response.read.return_value = body
                status, output = self.route()
                self.assertEqual(3, status)
                self.assertEqual(reason, output["evidence_scope"]["reason"])

    def test_invalid_config_is_not_http_200_readiness(self) -> None:
        configs = (None, [], {}, {"runtime": "docker"}, {"runtime": 1, "url": "https://example.test"},
                   {"runtime": "", "url": "https://example.test"},
                   {"runtime": "docker", "url": "http://example.test"},
                   {"runtime": "docker", "url": "https://user:private-error-placeholder@example.test"},
                   {"runtime": "docker", "url": "https://example.test", "envSpecificDetails": []},
                   {"runtime": "docker", "url": "https://example.test", "envSpecificDetails": {"dockerCommand": []}})
        for details in configs:
            with self.subTest(details=details):
                self.response.read.return_value = json.dumps({"id": self.target, "serviceDetails": details}).encode()
                status, output = self.route()
                self.assertEqual(3, status)
                self.assertEqual("invalid_service_config", output["evidence_scope"]["reason"])

    def test_unexpected_success_status_fails_closed(self) -> None:
        self.response.status = 204
        status, output = self.route()
        self.assertEqual(3, status)
        self.assertEqual("unexpected_status", output["evidence_scope"]["reason"])

    def test_fixtures_never_replace_denial_or_grant_catalogue_authority(self) -> None:
        render = self.helper.capability_for(self.registry, "render")
        fixture = {"capabilities": {render["name"]: dict.fromkeys(self.registry["dimensions"], "true")}}
        for content in ({}, fixture):
            with self.subTest(content=content), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "fixture.json"
                path.write_text(json.dumps(content))
                denial = HTTPError("https://example.test", 403, self.secret, {}, io.BytesIO())
                self.addCleanup(denial.close)
                self.opener.open.side_effect = denial
                status, output = self.route(fixture=path)
                self.assertEqual(2, status)
                self.assertEqual("render_fixture_not_allowed", output["error"])
                self.opener.open.assert_not_called()
                args = argparse.Namespace(capability=None, runtime="opencode", fixture=path,
                                          target=None, operation="read", transport=None, command="query")
                with redirect_stdout(io.StringIO()) as output:
                    self.helper.query_or_route({**self.registry, "capabilities": [render]}, args)
                result = json.loads(output.getvalue())["capabilities"][0]
                self.assertFalse(result["route_ready"])
                self.assertEqual("unknown", result["readiness"]["authorized"])
                self.opener.open.assert_not_called()


class CapabilityReadinessTests(unittest.TestCase):
    def run_helper(
        self, *args: str, expected: int = 0, fixture: Path = FIXTURE
    ) -> dict:
        result = subprocess.run(
            [sys.executable, str(HELPER), "--fixture", str(fixture), *args],
            text=True,
            capture_output=True,
            check=False,
        )  # nosec B603
        self.assertEqual(expected, result.returncode, result.stderr or result.stdout)
        return json.loads(result.stdout) if result.stdout else {}

    def test_registry_has_no_drift(self) -> None:
        result = subprocess.run(
            [sys.executable, str(HELPER), "check"],
            text=True,
            capture_output=True,
            check=False,
        )  # nosec B603
        self.assertEqual(0, result.returncode, result.stdout)
        self.assertTrue(json.loads(result.stdout)["valid"])

    def test_registry_rejects_duplicate_declared_views(self) -> None:
        registry = json.loads((HELPER.parents[1] / "configs" / "capability-registry.json").read_text())
        registry["views"].append(dict(registry["views"][0]))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "registry.json"
            path.write_text(json.dumps(registry))
            result = subprocess.run(
                [sys.executable, str(HELPER), "--registry", str(path), "check"],
                text=True,
                capture_output=True,
                check=False,
            )  # nosec B603
        self.assertEqual(1, result.returncode)
        self.assertIn("duplicate view: primary-registration", result.stdout)

    def test_registry_rejects_stale_declared_view_path(self) -> None:
        registry = json.loads((HELPER.parents[1] / "configs" / "capability-registry.json").read_text())
        registry["views"][0]["source"] = "missing-primary-registration.toon"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "registry.json"
            path.write_text(json.dumps(registry))
            result = subprocess.run(
                [sys.executable, str(HELPER), "--registry", str(path), "check"],
                text=True,
                capture_output=True,
                check=False,
            )  # nosec B603
        self.assertEqual(1, result.returncode)
        self.assertIn("invalid source view path", result.stdout)

    def test_healthy_capability_routes(self) -> None:
        output = self.run_helper("route", "code", "--runtime", "opencode")
        self.assertEqual("route", output["decision"])
        self.assertEqual("Build+", output["owner"])

    def test_creative_app_catalogue_does_not_imply_execution_readiness(self) -> None:
        for name in ("blender", "freecad", "ableton", "davinci-resolve"):
            with self.subTest(name=name):
                output = self.run_helper("route", name, "--runtime", "opencode", expected=3)
                self.assertEqual("gated-creative-app-guidance", output["fallback"])
                self.assertIn("authorized", output["coverage_impact"])
                self.assertIn("usable", output["coverage_impact"])

    def test_unavailable_credentials_fall_back(self) -> None:
        output = self.run_helper("route", "github", "--runtime", "opencode", expected=3)
        self.assertEqual("fallback", output["decision"])
        self.assertIn("authenticated", output["coverage_impact"])

    def test_github_live_evidence_is_target_and_operation_bound(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fake_gh = Path(directory) / "gh"
            fake_gh.write_text(
                "#!/bin/sh\n"
                "if [ \"$1\" = auth ]; then exit 0; fi\n"
                "if [ \"$1\" = api ] && [ \"$2\" = repos/owner/repo ]; then\n"
                "  printf \"%s\\n\" '{\"permissions\":{\"push\":true,\"admin\":false}}'\n"
                "  exit 0\n"
                "fi\n"
                "exit 1\n"
            )
            fake_gh.chmod(0o755)
            environment = dict(os.environ)
            environment["PATH"] = f"{directory}{os.pathsep}{environment['PATH']}"
            result = subprocess.run(  # nosec B603
                [sys.executable, str(HELPER), "route", "github", "--runtime", "opencode", "--target", "owner/repo", "--operation", "write"],
                text=True,
                capture_output=True,
                check=False,
                env=environment,
            )
        self.assertEqual(0, result.returncode, result.stderr or result.stdout)
        output = json.loads(result.stdout)
        self.assertEqual("route", output["decision"])
        self.assertEqual({"target": "owner/repo", "operation": "write"}, output["evidence_scope"])
        self.assertEqual("true", output["readiness"]["reachable"])
        self.assertEqual("true", output["readiness"]["authorized"])

    def test_github_live_evidence_denies_unproven_admin(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fake_gh = Path(directory) / "gh"
            fake_gh.write_text(
                "#!/bin/sh\n"
                "if [ \"$1\" = auth ]; then exit 0; fi\n"
                "printf \"%s\\n\" '{\"permissions\":{\"push\":true,\"admin\":false}}'\n"
            )
            fake_gh.chmod(0o755)
            environment = dict(os.environ)
            environment["PATH"] = f"{directory}{os.pathsep}{environment['PATH']}"
            result = subprocess.run(  # nosec B603
                [sys.executable, str(HELPER), "route", "github", "--runtime", "opencode", "--target", "owner/repo", "--operation", "admin"],
                text=True,
                capture_output=True,
                check=False,
                env=environment,
            )
        self.assertEqual(3, result.returncode, result.stderr or result.stdout)
        output = json.loads(result.stdout)
        self.assertEqual("true", output["readiness"]["reachable"])
        self.assertEqual("false", output["readiness"]["authorized"])

    def test_unreachable_service_falls_back(self) -> None:
        output = self.run_helper("route", "seo-data", "--runtime", "opencode", expected=3)
        self.assertIn("reachable", output["coverage_impact"])

    def test_missing_permission_falls_back(self) -> None:
        output = self.run_helper("route", "cloudflare", "--runtime", "opencode", expected=3)
        self.assertIn("authorized", output["coverage_impact"])

    def test_hidden_tool_falls_back(self) -> None:
        output = self.run_helper("route", "browser", "--runtime", "opencode", expected=3)
        self.assertIn("tool_visible", output["coverage_impact"])

    def run_playwright_transport(self, payload: dict, exit_code: int = 0) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "package.json").write_text('{}')
            node = root / "node"
            node.write_text(
                '#!/bin/sh\n'
                'if [ -n "$NODE_OPTIONS$PROBE_TEST_CREDENTIAL" ]; then exit 9; fi\n'
                f"printf '%s\\n' {shlex.quote(json.dumps(payload))}\n"
                f'exit {exit_code}\n'
            )
            node.chmod(0o755)
            environment = dict(os.environ)
            environment.update({
                "PATH": f"{root}{os.pathsep}{environment['PATH']}",
                "NODE_OPTIONS": "untrusted-preload-placeholder",
                "PROBE_TEST_CREDENTIAL": "not-a-real-credential",
                "AIDEVOPS_VISIBLE_TOOLS": "bash",
            })
            return subprocess.run(  # nosec B603
                [sys.executable, str(HELPER), "route", "browser", "--runtime", "opencode",
                 "--transport", "playwright", "--workdir", directory, "--target", "localhost"],
                env=environment, text=True, capture_output=True, check=False,
            )

    def test_repository_transport_uses_live_runner_evidence_without_mcp(self) -> None:
        result = self.run_playwright_transport({
            "schema": "aidevops.playwright-readiness/v1", "packageImportable": True,
            "runnerAvailable": True, "roundTrip": True, "closed": True, "reason": "ready",
        })
        self.assertEqual(0, result.returncode, result.stdout)
        output = json.loads(result.stdout)
        self.assertEqual("route", output["decision"])
        self.assertEqual("playwright", output["evidence_scope"]["transport"])
        self.assertFalse(output["evidence_scope"]["target_contacted"])
        self.assertFalse(output["evidence_scope"]["authenticated"])
        self.assertEqual("unknown", output["readiness"]["authorized"])

    def test_repository_transport_fails_closed_on_partial_or_failed_probe(self) -> None:
        ready = {
            "schema": "aidevops.playwright-readiness/v1", "packageImportable": True,
            "runnerAvailable": True, "roundTrip": True, "closed": True, "reason": "ready",
        }
        for field in ("packageImportable", "runnerAvailable", "roundTrip", "closed"):
            with self.subTest(field=field):
                result = self.run_playwright_transport({**ready, field: False})
                self.assertEqual(3, result.returncode, result.stdout)
                self.assertEqual("fallback", json.loads(result.stdout)["decision"])
        result = self.run_playwright_transport(ready, exit_code=1)
        self.assertEqual(3, result.returncode, result.stdout)

    def test_repository_transport_does_not_relay_untrusted_diagnostics(self) -> None:
        for reason in ("private-diagnostic-placeholder", ["private-diagnostic-placeholder"], {}):
            with self.subTest(reason=reason):
                result = self.run_playwright_transport({
                    "schema": "aidevops.playwright-readiness/v1", "reason": reason,
                })
                self.assertEqual(3, result.returncode)
                self.assertNotIn("private-diagnostic-placeholder", result.stdout + result.stderr)
                self.assertEqual("invalid_probe_result", json.loads(result.stdout)["evidence_scope"]["reason"])

    def test_repository_transport_rejects_fixture_authority(self) -> None:
        output = self.run_helper(
            "route", "browser", "--runtime", "opencode", "--transport", "playwright",
            "--workdir", str(TEST_DIR), "--target", "localhost", expected=2,
        )
        self.assertEqual("live_playwright_requires_workdir_without_fixture", output["error"])

    def test_repository_transport_rejects_empty_fixture_authority(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / "fixture.json"
            fixture.write_text('{}')
            output = self.run_helper(
                "route", "browser", "--runtime", "opencode", "--transport", "playwright",
                "--workdir", str(TEST_DIR), "--target", "localhost", expected=2, fixture=fixture,
            )
        self.assertEqual("live_playwright_requires_workdir_without_fixture", output["error"])

    def test_transport_is_not_a_general_provider_override(self) -> None:
        output = self.run_helper(
            "route", "github", "--runtime", "opencode", "--transport", "playwright", expected=2,
        )
        self.assertEqual("transport_requires_browser_capability", output["error"])

    def test_repository_transport_rejects_credential_bearing_target_before_launch(self) -> None:
        target = urlunsplit(("https", "user:private-placeholder@example.test", "/", "", ""))
        result = subprocess.run(  # nosec B603
            [sys.executable, str(HELPER), "route", "browser", "--runtime", "opencode",
             "--transport", "playwright", "--workdir", str(TEST_DIR),
             "--target", target],
            text=True, capture_output=True, check=False,
        )
        self.assertEqual(2, result.returncode)
        self.assertNotIn("private-placeholder", result.stdout + result.stderr)

    def test_provider_neutral_accounting_routes_without_a_provider(self) -> None:
        output = self.run_helper("route", "accounting", "--runtime", "opencode")
        self.assertEqual("route", output["decision"])
        self.assertEqual("Business", output["owner"])

    def test_ready_quickfile_accounting_routes(self) -> None:
        output = self.run_helper("route", "quickfile", "--runtime", "opencode")
        self.assertEqual("route", output["decision"])
        self.assertEqual("Business", output["owner"])

    def test_quickfile_authentication_uncertainty_falls_back(self) -> None:
        fixture = json.loads(FIXTURE.read_text())
        fixture["capabilities"]["quickfile-accounting"]["authenticated"] = "unknown"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "states.json"
            path.write_text(json.dumps(fixture))
            output = self.run_helper(
                "route", "quickfile", "--runtime", "opencode", expected=3, fixture=path
            )
        self.assertEqual("accounting-export-workpaper", output["fallback"])
        self.assertIn("authenticated", output["coverage_impact"])

    def test_home_path_probe_accepts_an_alternative_install(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            legacy_entrypoint = home / "Git" / "quickfile-mcp" / "dist" / "index.js"
            legacy_entrypoint.parent.mkdir(parents=True)
            legacy_entrypoint.write_text("")
            registry_path = home / "registry.json"
            registry_path.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "dimensions": [
                            "catalogued",
                            "installed",
                            "runtime_compatible",
                        ],
                        "capabilities": [
                            {
                                "name": "alternative-home-path",
                                "aliases": ["alternative"],
                                "owner": "Business",
                                "runtimes": ["opencode"],
                                "entry_points": [],
                                "fallback": "manual",
                                "required": ["installed", "runtime_compatible"],
                                "probes": {
                                    "installed": {
                                        "path_home_any": [
                                            "Git/mcp/quickfile-mcp/dist/index.js",
                                            "Git/quickfile-mcp/dist/index.js",
                                        ]
                                    }
                                },
                            }
                        ],
                    }
                )
            )
            environment = dict(os.environ)
            environment["HOME"] = str(home)
            result = subprocess.run(
                [
                    sys.executable,
                    str(HELPER),
                    "--registry",
                    str(registry_path),
                    "route",
                    "alternative",
                    "--runtime",
                    "opencode",
                ],
                text=True,
                capture_output=True,
                check=False,
                env=environment,
            )  # nosec B603
        self.assertEqual(0, result.returncode, result.stderr or result.stdout)
        self.assertEqual("route", json.loads(result.stdout)["decision"])

    def test_environment_pattern_probe_matches_a_profile_secret(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            registry_path = Path(directory) / "registry.json"
            registry_path.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "dimensions": [
                            "catalogued",
                            "configured",
                            "runtime_compatible",
                        ],
                        "capabilities": [
                            {
                                "name": "profile-secret",
                                "aliases": ["profile"],
                                "owner": "Business",
                                "runtimes": ["opencode"],
                                "entry_points": [],
                                "fallback": "manual",
                                "required": ["configured", "runtime_compatible"],
                                "probes": {
                                    "configured": {
                                        "env_pattern": "SERVICE_<PROFILE>_TOKEN"
                                    }
                                },
                            }
                        ],
                    }
                )
            )
            environment = dict(os.environ)
            environment["SERVICE_BUSINESS_TOKEN"] = directory
            result = subprocess.run(
                [
                    sys.executable,
                    str(HELPER),
                    "--registry",
                    str(registry_path),
                    "route",
                    "profile",
                    "--runtime",
                    "opencode",
                ],
                text=True,
                capture_output=True,
                check=False,
                env=environment,
            )  # nosec B603
        self.assertEqual(0, result.returncode, result.stderr or result.stdout)
        self.assertEqual("route", json.loads(result.stdout)["decision"])

    def test_generated_index_is_stable(self) -> None:
        committed = HELPER.parents[1] / "reference" / "capability-registry.md"
        with tempfile.TemporaryDirectory() as directory:
            generated = Path(directory) / "index.md"
            subprocess.run(
                [
                    sys.executable,
                    str(HELPER),
                    "generate",
                    "--output",
                    str(generated),
                ],
                check=True,
            )  # nosec B603
            self.assertEqual(committed.read_text(), generated.read_text())


if __name__ == "__main__":
    unittest.main()
