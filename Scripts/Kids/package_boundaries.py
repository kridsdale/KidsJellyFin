#!/usr/bin/env python3
"""Verify declared library edges and source imports without reading media or server state.

This covers the extracted libraries. It does not claim the remaining application
sources have been refactored or that public APIs/runtime behavior are correct.
"""
from pathlib import Path
import argparse
import json
import re
import subprocess

# Explicit responsibilities, not a permission derived from whatever code happens to import.
EXTERNAL_POLICIES = {
    "SwiftfinAccountStore": [("jellyfin-sdk-swift", "https://github.com/jellyfin/jellyfin-sdk-swift.git", "3.2.0"), ("defaults", "https://github.com/sindresorhus/Defaults", "9.0.9")],
    "SwiftfinImageProcessing": [("svgkit", "https://github.com/SVGKit/SVGKit", "3.0.0"), ("cocoalumberjack", "https://github.com/CocoaLumberjack/CocoaLumberjack.git", "3.9.1")],
    "SwiftfinMPV": [("mpvui", "https://github.com/LePips/MPVUI", "0.1.1")],
    "SwiftfinCollections": [("swift-collections", "https://github.com/apple/swift-collections.git", "1.6.0")],
    "SwiftfinAccountAccess": [("jellyfin-sdk-swift", "https://github.com/jellyfin/jellyfin-sdk-swift.git", "3.2.0"), ("get", "https://github.com/kean/Get", "2.2.1")],
    "SwiftfinUserMediaState": [("jellyfin-sdk-swift", "https://github.com/jellyfin/jellyfin-sdk-swift.git", "3.2.0"), ("get", "https://github.com/kean/Get", "2.2.1")],
    "SwiftfinPlaybackReporting": [("jellyfin-sdk-swift", "https://github.com/jellyfin/jellyfin-sdk-swift.git", "3.2.0"), ("get", "https://github.com/kean/Get", "2.2.1")],
    "SwiftfinPlaybackPreparation": [("jellyfin-sdk-swift", "https://github.com/jellyfin/jellyfin-sdk-swift.git", "3.2.0"), ("get", "https://github.com/kean/Get", "2.2.1")],
    "SwiftfinRecordingTimers": [("jellyfin-sdk-swift", "https://github.com/jellyfin/jellyfin-sdk-swift.git", "3.2.0"), ("get", "https://github.com/kean/Get", "2.2.1")],
    "SwiftfinFilters": [("jellyfin-sdk-swift", "https://github.com/jellyfin/jellyfin-sdk-swift.git", "3.2.0"), ("get", "https://github.com/kean/Get", "2.2.1")],
    "SwiftfinItemMetadata": [("jellyfin-sdk-swift", "https://github.com/jellyfin/jellyfin-sdk-swift.git", "3.2.0"), ("get", "https://github.com/kean/Get", "2.2.1")],
    "SwiftfinUserAdministration": [("jellyfin-sdk-swift", "https://github.com/jellyfin/jellyfin-sdk-swift.git", "3.2.0"), ("get", "https://github.com/kean/Get", "2.2.1")],
    "SwiftfinServerOperations": [("jellyfin-sdk-swift", "https://github.com/jellyfin/jellyfin-sdk-swift.git", "3.2.0"), ("get", "https://github.com/kean/Get", "2.2.1")],
    "SwiftfinMediaCatalog": [("jellyfin-sdk-swift", "https://github.com/jellyfin/jellyfin-sdk-swift.git", "3.2.0"), ("get", "https://github.com/kean/Get", "2.2.1")],
    "SwiftfinMediaTracks": [("jellyfin-sdk-swift", "https://github.com/jellyfin/jellyfin-sdk-swift.git", "3.2.0")],
    "SwiftfinPlaybackProfiles": [("jellyfin-sdk-swift", "https://github.com/jellyfin/jellyfin-sdk-swift.git", "3.2.0")],
    "SwiftfinImages": [("nuke", "https://github.com/kean/Nuke", "13.0.6")],
    "SwiftfinVLC": [("swiftvlc", "https://github.com/harflabs/SwiftVLC", "1.0.0")],
    "SwiftfinStorage": [("corestore", "https://github.com/JohnEstropia/CoreStore.git", "9.2.0")],
    "SwiftfinStoredValues": [("defaults", "https://github.com/sindresorhus/Defaults", "9.0.9")],
    "SwiftfinNetworking": [
        ("jellyfin-sdk-swift", "https://github.com/jellyfin/jellyfin-sdk-swift.git", "3.2.0"),
        ("get", "https://github.com/kean/Get", "2.2.1"),
    ],
}
POLICIES = {
    "KidsParentControl": ({}, {"Foundation"}),
    "KidsViewingControl": ({"KidsDomain", "KidsParentControl"}, {"Foundation"}),
    "SwiftfinPermissions": ({}, {"Foundation", "os", "CoreLocation", "LocalAuthentication"}),
    "SwiftfinImageProcessing": ({}, {"Foundation", "CoreGraphics", "UIKit", "SVGKit"}),
    "SwiftfinMPV": ({}, {"Foundation", "MPVUI", "Observation", "SwiftUI"}),
    "SwiftfinText": ({}, {"Foundation", "CryptoKit", "CoreTransferable", "UniformTypeIdentifiers"}),
    "SwiftfinValues": ({}, {"Foundation"}),
    "SwiftfinTime": ({}, {"Foundation"}),
    "SwiftfinFormatting": ({"SwiftfinValues", "SwiftfinLocalization"}, {"Foundation"}),
    "SwiftfinAccountAccess": ({"SwiftfinNetworking"}, {"Foundation", "JellyfinAPI"}),
    "SwiftfinUserMediaState": ({"SwiftfinNetworking"}, {"Foundation", "JellyfinAPI"}),
    "SwiftfinPlaybackReporting": ({"SwiftfinNetworking", "SwiftfinAsyncStreams"}, {"Foundation", "JellyfinAPI"}),
    "SwiftfinPlaybackPreparation": ({"SwiftfinNetworking", "SwiftfinMediaTracks", "SwiftfinPlaybackReporting"}, {"Foundation", "Get", "JellyfinAPI"}),
    "SwiftfinRecordingTimers": ({"SwiftfinNetworking", "SwiftfinMediaCatalog"}, {"Foundation", "JellyfinAPI"}),
    "SwiftfinFilters": ({"SwiftfinNetworking", "SwiftfinMediaCatalog"}, {"Foundation", "JellyfinAPI"}),
    "SwiftfinItemMetadata": ({"SwiftfinNetworking"}, {"Foundation", "Get", "JellyfinAPI"}),
    "SwiftfinUserAdministration": ({"SwiftfinNetworking", "SwiftfinCollections"}, {"Foundation", "Get", "JellyfinAPI"}),
    "SwiftfinServerOperations": ({"SwiftfinNetworking", "SwiftfinCollections"}, {"Foundation", "Get", "JellyfinAPI"}),
    "SwiftfinMediaCatalog": ({"SwiftfinNetworking", "SwiftfinCollections", "SwiftfinTime"}, {"Foundation", "Get", "JellyfinAPI"}),
    "SwiftfinPaging": ({}, {"Foundation", "Combine"}),
    "SwiftfinScrolling": ({}, {"Foundation", "UIKit", "Combine"}),
    "SwiftfinMediaTracks": ({"SwiftfinPlaybackProfiles"}, {"Foundation", "CryptoKit", "JellyfinAPI"}),
    "SwiftfinPlaybackPreviews": ({}, {"Foundation", "UIKit", "Combine"}),
    "SwiftfinNativePlayback": ({}, {"Foundation", "AVFoundation", "AVKit", "SwiftUI", "Metal", "VideoToolbox"}),
    "SwiftfinCollections": ({}, {"Foundation", "OrderedCollections"}),
    "SwiftfinPlaybackProfiles": ({"SwiftfinCollections"}, {"Foundation", "JellyfinAPI"}),
    "SwiftfinImages": ({}, {"Foundation", "Nuke", "CryptoKit", "os"}),
    "SwiftfinSessions": ({"SwiftfinAsyncStreams"}, {"Foundation"}),
    "SwiftfinNetworking": ({}, {"Foundation", "Get", "JellyfinAPI"}),
    "SwiftfinAsyncStreams": ({}, {"Foundation", "Combine", "os"}),
    "SwiftfinConnections": ({"SwiftfinAccountModels"}, {"Foundation"}),
    "SwiftfinAccountStore": ({"SwiftfinAccountModels", "SwiftfinStorage", "SwiftfinStoredValues", "SwiftfinCredentials"}, {"Foundation", "JellyfinAPI", "Defaults"}),
    "SwiftfinCredentials": ({}, {"Foundation", "Security"}),
    "SwiftfinConnectivity": ({"SwiftfinAccountModels"}, {"Foundation", "Network", "NetworkExtension", "os"}),
    "SwiftfinAccountModels": ({"SwiftfinLocalization"}, {"Foundation"}),
    "SwiftfinStorage": ({"SwiftfinAccountModels"}, {"CoreStore", "Foundation"}),
    "SwiftfinStoredValues": ({"SwiftfinStorage", "SwiftfinAccountModels", "SwiftfinPlaybackProfiles"}, {"Defaults", "Foundation", "Combine"}),
    "SwiftfinStoredValuesUI": ({"SwiftfinStoredValues"}, {"SwiftUI"}),
    "SwiftfinVLC": ({"KidsDiagnostics"}, {"Foundation", "Combine", "SwiftUI", "SwiftVLC", "UIKit", "AppKit"}),
    "SwiftfinNowPlaying": ({}, {"Foundation", "MediaPlayer", "UIKit"}),
    "SwiftfinAudioSession": ({"KidsDiagnostics"}, {"Foundation", "OSLog", "AVFAudio"}),
    "KidsApplication": ({"KidsAccounts","KidsArtwork","KidsArtworkUI","KidsCatalog","KidsDiagnostics","KidsDomain","KidsPersistence","KidsPlaybackSession","KidsParentControl","KidsViewingControl"}, {"Foundation", "Combine", "CoreData", "SwiftData", "UIKit", "AVFoundation"}),
    "KidsExperience": ({"KidsAccounts","KidsApplication","KidsCatalog","KidsDiagnostics","KidsDiagnosticsUI","KidsDomain","KidsPlaybackSession","SwiftfinUIState"}, {"SwiftUI", "Combine"}),
    "KidsDomain": ({}, {"Foundation"}),
    "KidsAccounts": ({"KidsDomain","SwiftfinAsyncStreams"}, {"Foundation", "Combine"}),
    "KidsDiagnostics": ({"KidsDomain"}, {"Foundation", "OSLog", "os", "CoreFoundation", "Darwin", "Glibc", "CryptoKit"}),
    "KidsCatalog": ({"KidsDomain", "KidsDiagnostics"}, {"Foundation"}),
    "KidsArtwork": ({"KidsDomain", "KidsCatalog", "KidsDiagnostics"}, {"Foundation"}),
    "KidsArtworkUI": ({"KidsDomain", "KidsCatalog", "KidsDiagnostics", "KidsArtwork"}, {"UIKit", "Combine"}),
    "KidsDiagnosticsUI": ({"KidsDiagnostics"}, {"UIKit", "SwiftUI"}),
    "KidsPlaybackSession": ({"KidsDomain", "KidsPlayback", "KidsDiagnostics"}, {"Foundation", "Combine"}),
    "KidsPlayback": ({"KidsDiagnostics", "SwiftfinAsyncStreams"}, {"Foundation"}),
    "KidsPersistence": ({"KidsDomain", "KidsDiagnostics"}, {"Foundation", "SwiftData", "CryptoKit"}),
    "SwiftfinLocalization": ({}, {"Foundation"}),
    "SwiftfinUIState": ({}, {"SwiftUI", "Combine", "Foundation"}),
}
IMPORT = re.compile(r"(?m)^\s*(?:@\w+(?:\([^\n)]*\))?\s+)*(?:(?:public|package|internal|fileprivate|private)\s+)?import\s+(?:(?:typealias|struct|class|enum|protocol|func|let|var)\s+)?(\w+)")


def cycles(graph):
    visiting = []
    done = set()
    result = []

    def visit(node):
        if node in visiting:
            result.append(visiting[visiting.index(node):] + [node])
            return
        if node in done:
            return
        visiting.append(node)
        for dependency in sorted(graph.get(node, [])):
            visit(dependency)
        visiting.pop()
        done.add(node)

    for node in sorted(graph):
        visit(node)
    return result


def validate_source(name, source, dependencies, frameworks):
    allowed = set(dependencies) | set(frameworks)
    problems = [f"{name}: forbidden or undeclared import {module}" for module in sorted(set(IMPORT.findall(source)) - allowed)]
    if any("@_exported" in match.group(0) for match in IMPORT.finditer(source)):
        problems.append(f"{name}: umbrella re-export hides an explicit dependency")
    if name == "SwiftfinAccountStore" and re.search(r"\b(?:JellyfinClient|JellyfinTransport|Paths|URLSession|URLRequest)\b", source):
        problems.append(f"{name}: account metadata storage must not issue network requests")
    return problems


def application_import_problems(root):
    """Composition uses explicit imports; native permission drivers stay with their owner."""
    problems = []
    for directory in ("Shared", "Swiftfin", "Swiftfin tvOS", "KidsParents"):
        for source in sorted((root / directory).rglob("*.swift")):
            if not source.resolve().is_relative_to(root.resolve()):
                problems.append(f"{source.relative_to(root)}: application source escapes the checkout")
                continue
            for match in IMPORT.finditer(source.read_text()):
                if match.group(1) == "SVGKit":
                    problems.append(f"{source.relative_to(root)}: native SVG parsing/rendering belongs to SwiftfinImageProcessing")
                if match.group(1) in {"CoreLocation", "LocalAuthentication"}:
                    problems.append(f"{source.relative_to(root)}: native permission import {match.group(1)} belongs to SwiftfinPermissions")
                if "@_exported" in match.group(0):
                    problems.append(f"{source.relative_to(root)}: application re-export of {match.group(1)} hides a file dependency")
    return problems


def inspect_package(path, root):
    manifest = json.loads(subprocess.check_output(["swift", "package", "--package-path", str(path), "dump-package"], text=True))
    dependencies = set()
    external_identities = set()
    for dependency in manifest["dependencies"]:
        filesystem = dependency.get("fileSystem")
        if not filesystem:
            source = dependency.get("sourceControl", [])
            policies = EXTERNAL_POLICIES.get(path.name, [])
            identity = source[0].get("identity") if len(source) == 1 else None
            policy = next((p for p in policies if p[0] == identity), None)
            if (policy is None or identity in external_identities
                    or source[0].get("location") != {"remote": [{"urlString": policy[1]}]}
                    or source[0].get("requirement") != {"exact": [policy[2]]}):
                raise ValueError(f"{path.name}: external dependency is outside its recorded responsibility")
            external_identities.add(identity)
            continue
        destination = Path(filesystem[0]["path"]).resolve()
        if not destination.is_relative_to(root / "Packages"):
            raise ValueError(f"{path.name}: dependency escapes the local library graph")
        dependencies.add(destination.name)
    if external_identities != {policy[0] for policy in EXTERNAL_POLICIES.get(path.name, [])}:
        raise ValueError(f"{path.name}: every exactly pinned owned SDK dependency is required")
    return manifest, dependencies


def check(root):
    root = root.resolve()
    problems = []
    graph = {}
    actual = {p.parent.name for p in (root / "Packages").glob("*/Package.swift")}
    if actual != set(POLICIES):
        problems.append(f"Package responsibility inventory differs: missing={sorted(set(POLICIES)-actual)}, unassigned={sorted(actual-set(POLICIES))}")
    for name in sorted(actual & set(POLICIES)):
        path = root / "Packages" / name
        manifest, dependencies = inspect_package(path, root)
        graph[name] = dependencies
        expected, frameworks = POLICIES[name]
        if dependencies != set(expected):
            problems.append(f"{name}: expected dependencies {sorted(expected)}, found {sorted(dependencies)}")
        production = [t for t in manifest["targets"] if t["type"] == "regular"]
        if manifest["name"] != name or [t["name"] for t in production] != [name]:
            problems.append(f"{name}: library/module identity does not match its owner")
        products = manifest["products"]
        if len(products) != 1 or products[0]["name"] != name or products[0]["targets"] != [name] or "library" not in products[0]["type"]:
            problems.append(f"{name}: expected one focused production library")
        sources = list((path / "Sources" / name).rglob("*.swift"))
        if not sources:
            problems.append(f"{name}: production implementation is missing")
        for source in sources:
            if not source.resolve().is_relative_to(path.resolve()):
                problems.append(f"{name}: source escapes its owning library")
                continue
            problems.extend(f"{source.relative_to(root)}: {problem}" for problem in validate_source(name, source.read_text(), dependencies, frameworks))
    problems.extend(application_import_problems(root))
    problems.extend("Library dependency cycle: " + " -> ".join(cycle) for cycle in cycles(graph))
    tools = json.loads(subprocess.check_output(["swift", "package", "--package-path", str(root / "KidsCore"), "dump-package"], text=True))
    if any("library" in product["type"] for product in tools["products"]):
        problems.append("KidsCore: production aggregate facade must not be restored")
    return graph, problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()
    graph, problems = check(args.root)
    if problems:
        for problem in problems:
            print(problem)
        raise SystemExit(1)
    print(f"PASS: {len(graph)} individually owned libraries; exact declared edges; no cycles, hidden re-exports, or app/SDK imports outside their responsibilities.")
    print("Remaining application extraction is a separate completion requirement.")


if __name__ == "__main__":
    main()
