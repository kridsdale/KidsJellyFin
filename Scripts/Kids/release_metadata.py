"""Generate canonical client release versions and immutable release manifests."""
from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import subprocess
from zoneinfo import ZoneInfo


PACIFIC = ZoneInfo("America/Los_Angeles")
VERSION_PATTERN = re.compile(r"^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})$")
HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")


@dataclass(frozen=True)
class ReleaseVersion:
    value: str

    @classmethod
    def parse(cls, value: str) -> "ReleaseVersion":
        if VERSION_PATTERN.fullmatch(value) is None:
            raise ValueError("release version must use Pacific YYYYMMDD-HHMM")
        datetime.strptime(value, "%Y%m%d-%H%M")
        return cls(value)

    @classmethod
    def current(cls, now: datetime | None = None) -> "ReleaseVersion":
        current = datetime.now(PACIFIC) if now is None else now.astimezone(PACIFIC)
        return cls(current.strftime("%Y%m%d-%H%M"))

    @property
    def marketing_version(self) -> str:
        return datetime.strptime(self.value, "%Y%m%d-%H%M").strftime("%Y.%m.%d")

    @property
    def build_version(self) -> str:
        return self.value.replace("-", "")

    @property
    def tag(self) -> str:
        return f"client-v{self.value}"


def _file_digest(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _path_record(root: Path, path: Path) -> dict[str, object]:
    resolved = path.resolve()
    if not resolved.exists():
        raise ValueError(f"release input does not exist: {path}")
    try:
        locator = str(resolved.relative_to(root.resolve()))
    except ValueError:
        locator = resolved.name
    if resolved.is_file():
        return {
            "path": locator,
            "kind": "file",
            "bytes": resolved.stat().st_size,
            "sha256": _file_digest(resolved),
        }
    digest = hashlib.sha256()
    total = 0
    files = 0
    for child in sorted(item for item in resolved.rglob("*") if item.is_file()):
        relative = str(child.relative_to(resolved))
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(bytes.fromhex(_file_digest(child)))
        total += child.stat().st_size
        files += 1
    return {
        "path": locator,
        "kind": "directory",
        "files": files,
        "bytes": total,
        "sha256": digest.hexdigest(),
    }


def manifest(
    *,
    root: Path,
    version: ReleaseVersion,
    source_commit: str,
    source_revision: str,
    branch: str,
    rollback_version: str,
    rollback_commit: str,
    artifacts: list[Path],
    qa_evidence: list[Path],
    backend_message_id: str | None = None,
) -> dict[str, object]:
    if HEX40.fullmatch(source_commit) is None or HEX40.fullmatch(rollback_commit) is None:
        raise ValueError("source and rollback commits must be full lowercase Git object IDs")
    if HEX64.fullmatch(source_revision) is None:
        raise ValueError("implementation revision must be a lowercase SHA-256 digest")
    ReleaseVersion.parse(rollback_version)
    return {
        "schemaVersion": 1,
        "releaseVersion": version.value,
        "bundle": {
            "marketingVersion": version.marketing_version,
            "buildVersion": version.build_version,
        },
        "source": {
            "branch": branch,
            "commit": source_commit,
            "implementationRevision": source_revision,
            "tag": version.tag,
        },
        "artifacts": [_path_record(root, path) for path in artifacts],
        "qaEvidence": [_path_record(root, path) for path in qa_evidence],
        "rollback": {
            "releaseVersion": rollback_version,
            "commit": rollback_commit,
            "tag": ReleaseVersion.parse(rollback_version).tag,
        },
        "backendNotification": {
            "threadId": "kids-xca",
            "messageId": backend_message_id,
            "transport": "agent_mail",
        },
    }


def _git(root: Path, *arguments: str) -> str:
    return subprocess.check_output(["git", *arguments], cwd=root, text=True).strip()


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    version_parser = subparsers.add_parser("version")
    version_parser.add_argument("--value")
    manifest_parser = subparsers.add_parser("manifest")
    manifest_parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    manifest_parser.add_argument("--version", required=True)
    manifest_parser.add_argument("--source-commit")
    manifest_parser.add_argument("--source-revision", required=True)
    manifest_parser.add_argument("--branch")
    manifest_parser.add_argument("--rollback-version", required=True)
    manifest_parser.add_argument("--rollback-commit", required=True)
    manifest_parser.add_argument("--artifact", action="append", type=Path, default=[])
    manifest_parser.add_argument("--qa-evidence", action="append", type=Path, default=[])
    manifest_parser.add_argument("--backend-message-id")
    manifest_parser.add_argument("--output", type=Path, required=True)
    options = parser.parse_args(arguments)
    if options.command == "version":
        value = ReleaseVersion.current() if options.value is None else ReleaseVersion.parse(options.value)
        print(json.dumps({
            "releaseVersion": value.value,
            "marketingVersion": value.marketing_version,
            "buildVersion": value.build_version,
            "tag": value.tag,
        }, sort_keys=True))
        return 0
    root = options.root.resolve()
    value = ReleaseVersion.parse(options.version)
    record = manifest(
        root=root,
        version=value,
        source_commit=options.source_commit or _git(root, "rev-parse", "HEAD"),
        source_revision=options.source_revision,
        branch=options.branch or _git(root, "branch", "--show-current"),
        rollback_version=options.rollback_version,
        rollback_commit=options.rollback_commit,
        artifacts=options.artifact,
        qa_evidence=options.qa_evidence,
        backend_message_id=options.backend_message_id,
    )
    options.output.parent.mkdir(parents=True, exist_ok=True)
    options.output.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
