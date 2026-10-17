"""Run actual UIKit-free parent model sources with fake storage/transport on macOS.

Copies the checked-in model, not a parallel implementation, into an isolated SwiftPM
harness. No simulator, real Keychain reads, device-auth prompts or network calls.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scratch-path", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="kids-parents-model-") as temporary:
        directory = Path(temporary)
        sources = directory / "Sources"
        tests = directory / "Tests"
        sources.mkdir()
        tests.mkdir()
        for name in ("ParentsModel.swift", "ParentsModel+Features.swift", "ParentCredentialVault.swift"):
            shutil.copyfile(ROOT / "KidsParents" / name, sources / name)
        shutil.copyfile(ROOT / "KidsParentsTests/ParentsLifecycleTests.swift", tests / "ParentsLifecycleTests.swift")
        parent_path = json.dumps(str(ROOT / "Packages/KidsParentControl"))
        permission_path = json.dumps(str(ROOT / "Packages/SwiftfinPermissions"))
        (directory / "Package.swift").write_text(f'''// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "KidsParentsModelValidation",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: {parent_path}), .package(path: {permission_path})],
    targets: [
        .target(name: "ParentsModelHarness", dependencies: ["KidsParentControl", "SwiftfinPermissions"], path: "Sources"),
        .testTarget(name: "ParentsLifecycleTests", dependencies: ["ParentsModelHarness", "KidsParentControl"], path: "Tests")
    ]
)
''')
        command = ["xcrun", "swift", "test", "--build-system", "native", "--disable-sandbox", "--package-path", str(directory)]
        if args.scratch_path:
            command += ["--scratch-path", str(args.scratch_path)]
        return subprocess.run(command, cwd=ROOT, check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
