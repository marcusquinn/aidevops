"""Proof that a copied foreign-generation worktree's work lives elsewhere (GH#37828).

Either a verified rescue bundle whose hashes still match the source, or a clean
tree whose HEAD a remote verifiably holds. Proof is re-run immediately before the
source is relocated, so an interrupted retirement never trusts stale evidence.
"""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import shutil
import subprocess  # nosec B404 # fixed read-only Git queries, explicit argv

from .cleanup_plan import marker_digest
from .enrollment import MARKER, _directory_inode, _git_directory
from .storage import StoreConflict

RECEIPT = "receipt.txt"
DIFF_ARGS = (
    "diff", "--binary", "--full-index", "--no-color", "--no-ext-diff", "--no-textconv",
    "--no-renames", "--diff-algorithm=myers", "--no-indent-heuristic",
    "--src-prefix=a/", "--dst-prefix=b/", "HEAD",
)
STATE_MARKERS = (
    "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply",
    "BISECT_LOG",
)


def read_git(path: Path, *arguments: str, network: bool = False) -> bytes:
    """Run native Git on the source without optional index refreshes or prompts."""
    git = shutil.which("git")
    if git is None:
        raise ValueError("archive-git-unavailable")
    environment = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    environment.update(GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0")
    return subprocess.run(  # nosec B603 # resolved git, literal flags, path as one argv item
        [git, "--no-optional-locks", "-C", str(path), *arguments],
        env=environment, capture_output=True, check=True,
        timeout=60 if network else 120, shell=False,
    ).stdout


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def source_hashes(path: Path) -> dict[str, str]:
    """Reproduce the rescue helper's patch and untracked-file hashes for `path`."""
    listing = read_git(path, "ls-files", "--others", "--exclude-standard", "-z")
    records = bytearray()
    for raw in listing.split(b"\0")[:-1] if listing else []:
        name = os.fsdecode(raw)
        entry = path / name.rstrip("/")
        if name.endswith("/") or (entry.is_dir() and not entry.is_symlink()):
            raise StoreConflict("untracked-directory-unsupported")
        digest = (b"link:" + os.fsencode(os.readlink(entry)) if entry.is_symlink()
                  else f"sha256:{_sha(entry.read_bytes())}".encode())
        records += digest + b"\t" + raw.rstrip(b"/") + b"\0"
    return {
        "head": read_git(path, "rev-parse", "HEAD").decode().strip(),
        "patch_sha256": _sha(read_git(path, *DIFF_ARGS)),
        "untracked_hashes_sha256": _sha(bytes(records)),
        "untracked_list_sha256": _sha(listing),
    }


def _in_progress(path: Path) -> bool:
    admin = Path(read_git(path, "rev-parse", "--absolute-git-dir").decode().strip())
    return any(os.path.lexists(admin / name) for name in STATE_MARKERS)


def _key_values(file: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    if file.is_symlink() or not file.is_file() or file.stat().st_size > 65536:
        raise StoreConflict("rescue-receipt-unavailable")
    for line in file.read_text(encoding="utf-8").splitlines():
        key, separator, value = line.partition("=")
        if not separator or key in result:
            raise StoreConflict("rescue-receipt-invalid")
        result[key] = value
    return result


def _bundle_files(bundle: Path) -> tuple[dict[str, str], dict[str, str]]:
    manifest, receipt = _key_values(bundle / "manifest.txt"), _key_values(bundle / RECEIPT)
    if manifest.get("format") != "1" or receipt.get("format") != "1":
        raise StoreConflict("rescue-format-unsupported")
    if receipt.get("bundle_manifest_sha256") != _sha((bundle / "manifest.txt").read_bytes()):
        raise StoreConflict("rescue-receipt-manifest-mismatch")
    patch = bundle / "changes.patch"
    if patch.is_symlink() or _sha(patch.read_bytes()) != manifest.get("patch_sha256"):
        raise StoreConflict("rescue-bundle-corrupt")
    return manifest, receipt


def _verified_destination(receipt: dict[str, str]) -> str:
    """The rescue destination must still be a Git worktree holding the rescued HEAD."""
    destination = Path(receipt.get("verified_destination", ""))
    if not destination.is_absolute() or not destination.is_dir():
        raise StoreConflict("rescue-destination-missing")
    try:
        head = read_git(destination, "rev-parse", "HEAD").decode().strip()
    except (subprocess.CalledProcessError, OSError):
        raise StoreConflict("rescue-destination-missing") from None
    if head != receipt.get("head"):
        raise StoreConflict("rescue-destination-changed")
    return str(destination)


def _rescue_proof(path: Path, bundle: Path, current: dict[str, str]) -> dict[str, str]:
    """Require the bundle, its verify receipt, its destination and the source to agree."""
    if bundle.resolve(strict=True) != bundle or bundle.is_relative_to(path):
        raise StoreConflict("rescue-bundle-must-be-outside-source")
    manifest, receipt = _bundle_files(bundle)
    for name in ("source", "head", "patch_sha256", "untracked_hashes_sha256",
                 "untracked_list_sha256"):
        if receipt.get(name) != manifest.get(name):
            raise StoreConflict("rescue-receipt-manifest-mismatch")
    if manifest["source"] != str(path):
        raise StoreConflict("rescue-receipt-other-source")
    if any(manifest.get(name) != value for name, value in current.items()):
        raise StoreConflict("source-changed-since-rescue")
    return {"kind": "rescue-receipt", "manifest_sha256": receipt["bundle_manifest_sha256"],
            "destination": _verified_destination(receipt)}


def _remote_tip(path: Path, remote: str, branch: str) -> str:
    try:
        listing = read_git(path, "ls-remote", "--exit-code", remote,
                           f"refs/heads/{branch}", network=True)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError):
        raise StoreConflict("pushed-ref-unverifiable") from None
    return listing.decode().split()[0] if listing else ""


def _pushed_proof(path: Path, head: str) -> dict[str, str]:
    """A clean tree whose HEAD a remote branch tip, queried live, still equals or holds."""
    if read_git(path, "status", "--porcelain", "--untracked-files=all"):
        raise StoreConflict("rescue-or-clean-pushed-proof-required")
    listing = read_git(path, "for-each-ref", "--format=%(refname) %(objectname)",
                       "--contains", head, "refs/remotes/").decode().splitlines()
    candidates = [line.split() for line in listing if not line.split()[0].endswith("/HEAD")]
    if not candidates:
        raise StoreConflict("head-not-reachable-from-pushed-ref")
    for reference, tip in candidates:
        remote, _, branch = reference.removeprefix("refs/remotes/").partition("/")
        if branch and _remote_tip(path, remote, branch) == tip:
            return {"kind": "pushed-head", "head": head, "remote": remote, "branch": branch}
    raise StoreConflict("pushed-ref-stale-or-unverified")


def prove(path: Path, bundle: Path | None) -> dict[str, str]:
    """Return proof evidence or raise; callable again to revalidate before relocation."""
    if _in_progress(path):
        raise StoreConflict("source-operation-in-progress")
    current = source_hashes(path)
    if bundle is None:
        return _pushed_proof(path, current["head"])
    return _rescue_proof(path, bundle, current)


def require_foreign_identity(
    _store: object, _path: Path, plan: dict, target: Path, admin: Path,
) -> None:
    """Bind a relocated foreign tree, its Git administration and marker bytes to the plan."""
    if (_directory_inode(target) != plan["directory_identity"]
            or _git_directory(target) != admin
            or _directory_inode(admin) != plan["git_identity"]
            or marker_digest(admin / MARKER) != plan["marker_sha256"]):
        raise StoreConflict("private-worktree-changed")
