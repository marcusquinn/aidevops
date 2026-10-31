"""Build a deterministic, validation-only zipapp with no external dependencies."""

import argparse
import io
from pathlib import Path
import zipfile


SOURCES = ("__init__.py", "process.py", "runtime.py", "linux.py", "macos.py", "validation.py")
ENTRYPOINT = b"from worker_lifecycle.validation import main\nraise SystemExit(main())\n"
REGISTRY_SOURCES = ("__init__.py", "process.py", "runtime.py", "linux.py", "macos.py",
                    "storage.py", "events.py", "registry.py", "launch.py", "integration_validation.py",
                    "admission.py", "directory_handle.py", "cleanup_policy.py", "enrollment.py")
REGISTRY_TESTS = ("test_storage.py", "test_events.py", "test_launch.py", "test_admission.py",
                  "test_admitted_launch.py", "test_directory_handle.py", "test_cleanup_policy.py")


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
        entries["tests/__init__.py"] = b""
        entries.update({f"tests/{name}": (root.parent / "tests" / name).read_bytes() for name in REGISTRY_TESTS})
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
