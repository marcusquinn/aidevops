"""Build deterministic validation zipapps without third-party Python packages."""

import argparse
import io
from pathlib import Path
import zipfile


SOURCES = ("__init__.py", "process.py", "runtime.py", "linux.py", "macos.py", "validation.py")
ENTRYPOINT = b"from worker_lifecycle.validation import main\nraise SystemExit(main())\n"
REGISTRY_SOURCES = ("__init__.py", "process.py", "runtime.py", "linux.py", "macos.py",
                    "storage.py", "events.py", "registry.py", "launch.py", "integration_validation.py",
                    "launch_state.py",
                    "admission.py", "directory_handle.py", "cleanup_policy.py", "enrollment.py",
                    "cleanup_plan.py", "preservation.py", "session.py", "creation.py",
                    "retirement.py", "cleanup.py", "bundle.py")
REGISTRY_TESTS = ("test_storage.py", "test_events.py", "test_launch.py", "test_admission.py",
                  "test_admitted_launch.py", "test_directory_handle.py", "test_cleanup_policy.py",
                  "test_creation.py", "test_preservation.py", "test_retirement.py")
ARCHIVE_SOURCES = (
    "native_git.py", "runtime-env.sh", "shared-constants.sh",
    "portable-stat.sh", "managed-label-provisioning-lib.sh",
    "shared-gh-wrappers.sh", "shared-todo-commit.sh", "shared-temp-workspace.sh",
    "shared-model-tier.sh", "shared-feature-toggles.sh",
    "shared-gh-wrappers-session.sh", "shared-gh-wrappers-create.sh",
    "shared-gh-wrappers-safe-edit.sh", "shared-gh-wrappers-status.sh",
    "shared-gh-wrappers-checks.sh", "privacy-guard-helper.sh",
    "worktree-archive-helper.sh", "worktree_recovery_timing.py",
    "worktree_archive_administration.py", "worktree_archive_auto_merge.py",
    "worktree_archive_base_source.py", "worktree_archive_fingerprint.py",
    "worktree_archive_filesystem.py", "worktree_archive_git.py",
    "worktree_archive_history.py", "worktree_archive_index.py",
    "worktree_archive_merge_capture.py", "worktree_archive_merge_index.py",
    "worktree_archive_merge_objects.py", "worktree_archive_merge_restore.py",
    "worktree_archive_objects.py", "worktree_archive_readiness.py",
    "worktree_archive_receipt.py", "worktree_archive_restore.py",
    "worktree_archive_snapshot.py", "worktree_archive_state.py",
    "worktree_archive_untracked.py", "worktree_archive_xattrs.py",
)


def registry_members() -> set[str]:
    """Exact extraction allowlist, shared with the portable registry runner."""
    return {
        "__main__.py", "worker-launch.py", "worker-registry.py", "tests/__init__.py",
        *(f"worker_lifecycle/{name}" for name in REGISTRY_SOURCES),
        *(f"tests/{name}" for name in REGISTRY_TESTS),
        *(f"scripts/{name}" for name in ARCHIVE_SOURCES),
    }


def build(output: Path, suite: str = "process") -> None:
    """Write only a new artifact; callers choose another filename to rebuild."""
    root = Path(__file__).parent
    entries = {"__main__.py": ENTRYPOINT}
    if suite not in ("process", "registry"):
        raise ValueError("unsupported-validation-suite")
    sources = SOURCES if suite == "process" else REGISTRY_SOURCES
    entries.update({f"worker_lifecycle/{name}": (root / name).read_bytes() for name in sources})
    if suite == "registry":
        entries["__main__.py"] = b"from worker_lifecycle.integration_validation import main\nraise SystemExit(main())\n"
        entries["worker-launch.py"] = (root.parent / "worker-launch.py").read_bytes()
        entries["worker-registry.py"] = (root.parent / "worker-registry.py").read_bytes()
        entries["tests/__init__.py"] = b""
        entries.update({f"tests/{name}": (root.parent / "tests" / name).read_bytes() for name in REGISTRY_TESTS})
        scripts = root.parent.parent / "scripts"
        entries.update({f"scripts/{name}": (scripts / name).read_bytes()
                        for name in ARCHIVE_SOURCES})
        if set(entries) != registry_members():
            raise ValueError("registry-bundle-members-mismatch")
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, content in sorted(entries.items()):
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, content)
    with output.open("xb") as stream:
        stream.write(buffer.getvalue())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="new .pyz filename; existing files are never overwritten")
    parser.add_argument("--suite", choices=("process", "registry"), default="process")
    args = parser.parse_args()
    try:
        build(args.output, args.suite)
    except OSError:
        parser.exit(2, "Cannot create bundle: verify source files and choose a new output in an existing directory.\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
