"""Build once with a source revision; formatting is explicit and never performed here."""
from __future__ import annotations

from pathlib import Path
import subprocess
import sys

from evidence_revision import implementation_digest
from release_metadata import ReleaseVersion

ROOT = Path(__file__).resolve().parents[2]


def build(arguments, *, root=ROOT, runner=subprocess.run, digest=implementation_digest):
    arguments = list(arguments)
    release = None
    if arguments[:1] == ["--release-version"]:
        if len(arguments) < 2:
            print("error: --release-version requires YYYYMMDD-HHMM", file=sys.stderr)
            return 2
        try:
            release = ReleaseVersion.parse(arguments[1])
        except ValueError as error:
            print(f"error: {error}", file=sys.stderr)
            return 2
        arguments = arguments[2:]
    if arguments[:1] == ["--"]:
        arguments.pop(0)
    if not arguments or arguments == ["--help"]:
        print("Usage: python3 Scripts/Kids/build_with_revision.py -- <xcodebuild arguments>")
        return 0 if arguments == ["--help"] else 2
    if any(value.startswith("KIDS_EVIDENCE_REVISION=") for value in arguments):
        print("error: The wrapper supplies KIDS_EVIDENCE_REVISION; remove the manual setting.", file=sys.stderr)
        return 2
    release_keys = ("KIDS_RELEASE_VERSION=", "MARKETING_VERSION=", "CURRENT_PROJECT_VERSION=")
    if release is not None and any(value.startswith(release_keys) for value in arguments):
        print("error: --release-version supplies all bundle version settings.", file=sys.stderr)
        return 2
    before = digest(root)
    print(f"Kids implementation revision: {before}", flush=True)
    settings = [f"KIDS_EVIDENCE_REVISION={before}"]
    if release is not None:
        settings += [
            f"KIDS_RELEASE_VERSION={release.value}",
            f"MARKETING_VERSION={release.marketing_version}",
            f"CURRENT_PROJECT_VERSION={release.build_version}",
        ]
    result = runner(["xcodebuild", *arguments, *settings], cwd=root)
    if result.returncode:
        return result.returncode
    if digest(root) != before:
        print(
            "error: Source changed during the build; the embedded revision is stale. "
            "Keep the build result out of runtime acceptance and build once at the next planned boundary.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(build(sys.argv[1:]))
