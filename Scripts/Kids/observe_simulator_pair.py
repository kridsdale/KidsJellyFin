#!/usr/bin/env python3
"""Opt-in passive UI evidence for the existing Parents/Kids simulator pair.

Never launches an app, actuates a control, contacts a server or grants playback.
A phase is an operator annotation; backend receipts and video/audio acceptance
must be verified separately. Input fields are refused before screenshot capture.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
from uuid import UUID

from parents_trial_guard import read_private_plan

SIMCTL = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl"
TV_BUNDLE = "com.kridsdale.JellyfinPlayer"
PHONE_BUNDLE = TV_BUNDLE + ".Parents"
PNG = b"\x89PNG\r\n\x1a\n"


def utc():
    return datetime.now(timezone.utc).isoformat()


def digest(value):
    if re.fullmatch(r"[0-9a-f]{64}", value or "") is None:
        raise ValueError("Expected an exact executable SHA256")
    return value


def device(value):
    if str(UUID(value)).upper() != value:
        raise ValueError("Expected an exact canonical simulator UUID")
    return value


def inspect_ui(tree, expected_label):
    nodes, applications = [], []

    def walk(value):
        if isinstance(value, dict):
            kind = value.get("type", "")
            if kind in {"TextField", "SecureTextField", "TextView", "WebArea"}:
                raise ValueError("Input or web content is visible; capture refused")
            if kind == "Application":
                applications.append(value.get("AXLabel"))
            if value.get("AXLabel") or value.get("AXUniqueId"):
                # AXValue can contain entered text. Never export it.
                nodes.append({key: value[key] for key in
                              ("type", "AXLabel", "AXUniqueId", "enabled") if key in value})
            for child in value.values():
                if isinstance(child, (dict, list)):
                    walk(child)
        elif isinstance(value, list):
            for child in value:
                walk(child)

    walk(tree)
    if applications != [expected_label]:
        raise ValueError("Expected app is not the sole foreground application")
    return {"observedUTC": utc(), "application": expected_label,
            "inputFieldsAbsentAtObservation": True, "nodes": nodes}


class NativeSimulator:
    synthetic = False

    def __init__(self, axe):
        self.axe = str(axe)

    @staticmethod
    def run(args):
        return subprocess.run(args, check=True, capture_output=True, text=True, timeout=20).stdout

    def verify(self, udid, bundle, expected_executable, revision=None):
        app = Path(self.run([SIMCTL, "get_app_container", udid, bundle, "app"]).strip()).resolve()
        root = (Path.home() / "Library/Developer/CoreSimulator/Devices" / udid /
                "data/Containers/Bundle/Application").resolve()
        if not app.is_relative_to(root) or len(app.relative_to(root).parts) != 2:
            raise ValueError("Unexpected app installation")
        info = plistlib.loads((app / "Info.plist").read_bytes())
        if info.get("CFBundleIdentifier") != bundle:
            raise ValueError("Unexpected app identity")
        if revision is not None and info.get("KidsEvidenceImplementationRevision") != revision:
            raise ValueError("Unexpected TV source revision")
        executable = info.get("CFBundleExecutable")
        if not isinstance(executable, str) or Path(executable).name != executable:
            raise ValueError("Unexpected executable name")
        actual = hashlib.sha256((app / executable).read_bytes()).hexdigest()
        if actual != digest(expected_executable):
            raise ValueError("Installed executable differs from the pinned build")
        self.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
        return {"simulatorID": udid, "bundleID": bundle, "executableSHA256": actual,
                "sourceRevision": revision, "signatureVerified": True}

    def describe(self, udid):
        return json.loads(self.run([self.axe, "describe-ui", "--udid", udid]))

    def screenshot(self, udid, destination):
        self.run([SIMCTL, "io", udid, "screenshot", str(destination)])


def capture_pair(host, installations, output, phase, *, private_root=Path("/private/tmp")):
    if output.parent != private_root or output.name in {"", ".", ".."}:
        raise ValueError("Use a new directory directly under /private/tmp")
    if output.exists() or output.is_symlink():
        raise ValueError("Observation directory must not already exist")
    # Read and validate BOTH screens before saving either image or any UI text.
    observed = {}
    for role, label in (("television", "KidsJellyFin"), ("phone", "KidsJellyFin Parents")):
        observed[role] = inspect_ui(host.describe(installations[role]["simulatorID"]), label)
    output.mkdir(mode=0o700)
    result = {"kind": "parents-paired-simulator-observation", "schemaVersion": 1,
              "synthetic": host.synthetic, "phase": phase, "phaseIsOperatorAnnotation": True,
              "actionsPerformedByCapture": 0, "backendReceiptsVerified": False,
              "continuousRendererOrAudioProof": False, "screens": {}}
    old_umask = os.umask(0o077)
    try:
        for role in ("television", "phone"):
            path = output / (role + ".png")
            host.screenshot(installations[role]["simulatorID"], path)
            os.chmod(path, 0o600)
            data = path.read_bytes()
            if not data.startswith(PNG):
                raise ValueError("Screenshot was not a PNG")
            result["screens"][role] = {**installations[role], **observed[role],
                "capturedUTC": utc(), "image": path.name,
                "imageSHA256": hashlib.sha256(data).hexdigest()}
        result["completedUTC"] = utc()
        descriptor = os.open(output / "observation.json", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as stream:
            json.dump(result, stream, sort_keys=True)
            stream.flush()
            os.fsync(stream.fileno())
    finally:
        os.umask(old_umask)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tv-guard-plan", type=Path, required=True)
    parser.add_argument("--tv-executable-sha256", type=digest, required=True)
    parser.add_argument("--phone-udid", type=device, required=True)
    parser.add_argument("--phone-executable-sha256", type=digest, required=True)
    parser.add_argument("--axe", type=Path, required=True)
    parser.add_argument("--output-directory", type=Path, required=True)
    parser.add_argument("--phase", choices=("baseline", "after-pause", "after-resume", "after-skip", "after-stop"), required=True)
    parser.add_argument("--run-approved-observation", action="store_true")
    args = parser.parse_args()
    if not args.run_approved_observation:
        parser.error("Explicit --run-approved-observation required after runtime authorization")
    plan = read_private_plan(args.tv_guard_plan, datetime.now(timezone.utc))
    if plan.simulator_id == args.phone_udid:
        parser.error("The phone and television must be distinct simulators")
    host = NativeSimulator(args.axe)
    installations = {
        "television": host.verify(plan.simulator_id, TV_BUNDLE, args.tv_executable_sha256, plan.build),
        "phone": host.verify(args.phone_udid, PHONE_BUNDLE, args.phone_executable_sha256)
    }
    capture_pair(host, installations, args.output_directory, args.phase)
    print(json.dumps({"directory": str(args.output_directory), "actionsPerformed": 0,
                      "backendReceiptsVerified": False, "synthetic": False}))


if __name__ == "__main__":
    main()
