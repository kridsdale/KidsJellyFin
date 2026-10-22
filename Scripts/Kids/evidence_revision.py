"""Print the digest of the implementation inputs; never runs an app or contacts a server."""
from __future__ import annotations
import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
INPUTS = (
    "Packages/KidsDiagnostics/Sources/KidsDiagnostics",
    "Packages/SwiftfinVLC/Sources/SwiftfinVLC",
    "Packages/KidsPlaybackSession/Sources/KidsPlaybackSession",
    "Packages/KidsApplication/Sources/KidsApplication",
    "Packages/KidsDomain/Sources/KidsDomain",
    "Packages/KidsViewingControl/Sources/KidsViewingControl",
    "Packages/KidsParentControl/Sources/KidsParentControl",
    "Packages/KidsAccounts/Sources/KidsAccounts",
    "Packages/KidsExperience/Sources/KidsExperience",
    "Packages/KidsServerDiscovery/Sources/KidsServerDiscovery",
    "Packages/SwiftfinCredentials/Sources/SwiftfinCredentials",
    "KidsParents",
    "KidsParents/Info.plist",
    "Swiftfin tvOS/App/KidsPlaybackAdapter.swift",
    "Swiftfin tvOS/App/KidsAccountAdapter.swift",
    "Swiftfin tvOS/App/SwiftfinApp.swift",
    "Swiftfin tvOS/Resources/Info.plist",
    "Scripts/Kids/evidence_revision.py",
)

def implementation_digest(root: Path = ROOT) -> str:
    paths = []
    for name in INPUTS:
        path = root / name
        if path.is_symlink():
            raise ValueError("implementation_symlink")
        if path.is_dir():
            paths.extend(path.glob("*.swift"))
        else:
            paths.append(path)
    digest = hashlib.sha256()
    for path in sorted(paths):
        if path.is_symlink() or not path.is_file():
            raise ValueError("implementation_input_invalid")
        name = path.relative_to(root).as_posix().encode()
        content = path.read_bytes()
        digest.update(len(name).to_bytes(8, "big")); digest.update(name)
        digest.update(len(content).to_bytes(8, "big")); digest.update(content)
    return digest.hexdigest()

if __name__ == "__main__":
    print(implementation_digest())
