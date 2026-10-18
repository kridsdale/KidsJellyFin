#!/usr/bin/env python3
"""An opt-in local stop timer for one manually operated Parents simulator trial.

Never launches an app, starts playback, contacts a server or restores progress.
Use only after human runtime approval. A plan/flag is not evidence of that approval.
The timer requests termination; actual transport stop/drain requires observation.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import stat
import subprocess
import time
from uuid import UUID

BUNDLE = "com.kridsdale.JellyfinPlayer"
SIMCTL = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl"
KEYS = {"schemaVersion", "purpose", "simulatorID", "clientBuildSHA256", "expiresAt", "maximumSeconds"}


@dataclass(frozen=True)
class Plan:
    simulator_id: str
    build: str
    expires: datetime
    maximum_seconds: int


def validate_plan(value, now: datetime) -> Plan:
    if not isinstance(value, dict) or set(value) != KEYS:
        raise ValueError("Unexpected local guard plan fields")
    if type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1:
        raise ValueError("Unsupported guard schema")
    if value["purpose"] != "parents-manual-playback-guard":
        raise ValueError("Wrong guard purpose")
    device = value["simulatorID"]
    if not isinstance(device, str) or str(UUID(device)).upper() != device:
        raise ValueError("Expected the exact canonical simulator UUID")
    build = value["clientBuildSHA256"]
    if not isinstance(build, str) or re.fullmatch("[0-9a-f]{64}", build) is None:
        raise ValueError("Missing client fingerprint")
    seconds = value["maximumSeconds"]
    if type(seconds) is not int or not 1 <= seconds <= 600:
        raise ValueError("Guard duration must be 1 through 600 seconds")
    try:
        expires = datetime.fromisoformat(value["expiresAt"])
    except (ValueError, TypeError):
        raise ValueError("Malformed guard expiry") from None
    if expires.tzinfo is None or now.tzinfo is None or expires <= now:
        raise ValueError("Guard expiry must be explicit and still in the future")
    return Plan(device, build, expires, seconds)


def read_private_plan(path: Path, now: datetime) -> Plan:
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        info = os.fstat(stream.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1
                or info.st_size > 8192):
            raise ValueError("Plan must be an owner-only regular file of at most 8 KiB")
        data = stream.read(8193)
    if len(data) > 8192:
        raise ValueError("Guard plan grew beyond its bound")

    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("Duplicate guard plan key")
            result[key] = value
        return result

    return validate_plan(json.loads(data, object_pairs_hook=unique_object), now)


class Simulator:
    def __init__(self, sender=subprocess.run, home: Path | None = None):
        self.sender = sender
        self.home = home or Path.home()

    def verify(self, plan: Plan):
        result = self.sender([SIMCTL, "get_app_container", plan.simulator_id, BUNDLE, "app"],
                             check=True, capture_output=True, text=True, timeout=5)
        app = Path(result.stdout.strip()).resolve()
        root = (self.home / "Library/Developer/CoreSimulator/Devices" / plan.simulator_id
                / "data/Containers/Bundle/Application").resolve()
        if not app.is_relative_to(root) or len(app.relative_to(root).parts) != 2:
            raise ValueError("Unexpected simulator app container")
        info_path = app / "Info.plist"
        if info_path.is_symlink():
            raise ValueError("Redirected app metadata")
        info = plistlib.loads(info_path.read_bytes())
        if (info.get("CFBundleIdentifier") != BUNDLE
                or info.get("KidsEvidenceImplementationRevision") != plan.build):
            raise ValueError("Installed app does not match approved build")
        return app, app.stat().st_ino

    def terminate(self, plan: Plan, installation):
        if self.verify(plan) != installation:
            raise ValueError("Installation changed; do not stop an unreviewed replacement")
        self.sender([SIMCTL, "terminate", plan.simulator_id, BUNDLE],
                    check=True, capture_output=True, text=True, timeout=5)


def run_guard(plan: Plan, simulator, emit, *, monotonic=time.monotonic,
              now=lambda: datetime.now(timezone.utc), sleep=time.sleep):
    start = monotonic()
    remaining = (plan.expires - now()).total_seconds()
    if remaining <= 0:
        raise ValueError("Expired guard plan")
    # Reserve five seconds for the bounded termination command. This is not a
    # guarantee about an unresponsive host, nor proof that output has stopped.
    delay = max(0, min(plan.maximum_seconds, remaining) - 5)
    installation = simulator.verify(plan)
    emit({"event": "guard_ready", "stopRequestAfterSeconds": delay})
    reason = "guard_failure"
    try:
        while True:
            left = min(start + delay - monotonic(), (plan.expires - now()).total_seconds())
            if left <= 0:
                reason = "deadline"
                break
            sleep(min(left, 0.25))
    except KeyboardInterrupt:
        reason = "operator_interrupt"
    finally:
        try:
            emit({"event": "stop_requested", "reason": reason})
        finally:
            # A full receipt disk must never prevent the stop request.
            simulator.terminate(plan, installation)
        emit({"event": "termination_command_accepted", "transportDrainVerified": False})


def create_private_receipt(path: Path):
    if path.parent.resolve() != Path("/private/tmp"):
        raise ValueError("Use a new receipt directly in /private/tmp")
    # Pin the internal directory before opening the exclusive basename; a parent
    # symlink replacement must not redirect a write to another volume.
    directory = os.open("/private/tmp", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        fd = os.open(path.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o600, dir_fd=directory)
    finally:
        os.close(directory)
    os.fchmod(fd, 0o600)
    return os.fdopen(fd, "w")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--run-approved-trial", action="store_true")
    args = parser.parse_args()
    if not args.run_approved_trial:
        parser.error("Explicit --run-approved-trial required after human runtime approval")
    plan = read_private_plan(args.plan, datetime.now(timezone.utc))
    with create_private_receipt(args.receipt) as receipt:
        def emit(event):
            event.update(kind="parents-trial-local-guard", actualReceiverTrial=False)
            receipt.write(json.dumps(event, sort_keys=True) + "\n")
            receipt.flush()
            os.fsync(receipt.fileno())
            print(json.dumps(event, sort_keys=True), flush=True)

        def interrupt(_signal, _frame):
            raise KeyboardInterrupt()

        previous = {s: signal.signal(s, interrupt) for s in (signal.SIGTERM, signal.SIGHUP)}
        try:
            run_guard(plan, Simulator(), emit)
        finally:
            for s, handler in previous.items():
                signal.signal(s, handler)


if __name__ == "__main__":
    main()
