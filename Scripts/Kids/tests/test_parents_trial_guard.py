import importlib.util
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from uuid import uuid4

SPEC = importlib.util.spec_from_file_location("parents_trial_guard", Path(__file__).parents[1] / "parents_trial_guard.py")
M = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = M
SPEC.loader.exec_module(M)
NOW = datetime(2026, 10, 17, 20, tzinfo=timezone.utc)
DEVICE = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"


def value(**changes):
    result = dict(schemaVersion=1, purpose="parents-manual-playback-guard", simulatorID=DEVICE,
                  clientBuildSHA256="a" * 64, expiresAt=(NOW + timedelta(hours=1)).isoformat(), maximumSeconds=600)
    result.update(changes)
    return result


class FakeClock:
    elapsed = 0

    def monotonic(self):
        return self.elapsed

    def now(self):
        return NOW + timedelta(seconds=self.elapsed)

    def sleep(self, seconds):
        self.elapsed += seconds


class FakeSimulator:
    def __init__(self):
        self.calls = []

    def verify(self, plan):
        self.calls.append("verify")
        return ("same-installation", 7)

    def terminate(self, plan, installation):
        self.calls.append(("terminate", plan.simulator_id, installation))


class GuardTests(unittest.TestCase):
    def test_strict_scope_rejects_wrong_and_secret_fields(self):
        for changes in [dict(schemaVersion=True), dict(maximumSeconds=True), dict(maximumSeconds=601),
                        dict(maximumSeconds=0), dict(maximumSeconds=1.5), dict(purpose="play"),
                        dict(simulatorID="booted"), dict(clientBuildSHA256=""), dict(token="secret")]:
            with self.subTest(changes=changes), self.assertRaises((ValueError, TypeError)):
                M.validate_plan(value(**changes), NOW)

    def test_expired_or_ambiguous_expiry_rejected(self):
        for expiry in [NOW.isoformat(), "2026-10-17T20:00:00", "never", None]:
            with self.subTest(expiry=expiry), self.assertRaises(ValueError):
                M.validate_plan(value(expiresAt=expiry), NOW)

    def test_private_file_requires_owner_only_no_symlinks_or_duplicate_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "plan.json"
            path.write_text(json.dumps(value()))
            os.chmod(path, 0o600)
            self.assertEqual(M.read_private_plan(path, NOW).simulator_id, DEVICE)
            os.chmod(path, 0o644)
            with self.assertRaises(ValueError): M.read_private_plan(path, NOW)
            os.chmod(path, 0o600)
            linked = Path(directory) / "linked.json"
            linked.symlink_to(path)
            with self.assertRaises(OSError): M.read_private_plan(linked, NOW)
            path.write_text('{"schemaVersion":1,"schemaVersion":1}')
            with self.assertRaisesRegex(ValueError, "Duplicate"): M.read_private_plan(path, NOW)

    def test_deadline_requests_only_exact_app_stop_without_launching_or_server_io(self):
        clock, simulator, events = FakeClock(), FakeSimulator(), []
        M.run_guard(M.validate_plan(value(), NOW), simulator, events.append,
                    monotonic=clock.monotonic, now=clock.now, sleep=clock.sleep)
        self.assertEqual(clock.elapsed, 595)
        self.assertEqual(simulator.calls, ["verify", ("terminate", DEVICE, ("same-installation", 7))])
        self.assertEqual([e["event"] for e in events], ["guard_ready", "stop_requested", "termination_command_accepted"])
        self.assertIs(events[-1]["transportDrainVerified"], False)

    def test_near_expiry_shortens_guard_without_extending_window(self):
        clock, simulator, events = FakeClock(), FakeSimulator(), []
        plan = M.validate_plan(value(expiresAt=(NOW + timedelta(seconds=12)).isoformat()), NOW)
        M.run_guard(plan, simulator, events.append, monotonic=clock.monotonic, now=clock.now, sleep=clock.sleep)
        self.assertEqual(clock.elapsed, 7)

    def test_keyboard_interrupt_still_requests_exact_termination(self):
        simulator, events = FakeSimulator(), []
        def interrupt(_): raise KeyboardInterrupt()
        M.run_guard(M.validate_plan(value(), NOW), simulator, events.append,
                    monotonic=lambda: 0, now=lambda: NOW, sleep=interrupt)
        self.assertEqual(events[1]["reason"], "operator_interrupt")
        self.assertEqual(simulator.calls[-1][0], "terminate")

    def test_failed_stop_cannot_claim_accepted_or_drained(self):
        simulator, events = FakeSimulator(), []
        def fail(*_): raise subprocess.TimeoutExpired("fake stop", 5)
        simulator.terminate = fail
        with self.assertRaises(subprocess.TimeoutExpired):
            M.run_guard(M.validate_plan(value(maximumSeconds=1), NOW), simulator, events.append,
                        monotonic=lambda: 0, now=lambda: NOW)
        self.assertEqual([e["event"] for e in events], ["guard_ready", "stop_requested"])

    def test_receipt_failure_does_not_prevent_termination(self):
        simulator = FakeSimulator()
        def emit(event):
            if event["event"] == "stop_requested":
                raise OSError("fake full disk")
        with self.assertRaisesRegex(OSError, "full disk"):
            M.run_guard(M.validate_plan(value(maximumSeconds=1), NOW), simulator, emit,
                        monotonic=lambda: 0, now=lambda: NOW)
        self.assertEqual(simulator.calls[-1][0], "terminate")

    def test_timer_failure_stops_before_propagating_error(self):
        simulator, events = FakeSimulator(), []
        def fail(_): raise RuntimeError("fake clock failure")
        with self.assertRaisesRegex(RuntimeError, "clock failure"):
            M.run_guard(M.validate_plan(value(), NOW), simulator, events.append,
                        monotonic=lambda: 0, now=lambda: NOW, sleep=fail)
        self.assertEqual(events[1]["reason"], "guard_failure")
        self.assertEqual(simulator.calls[-1][0], "terminate")

    def test_changed_build_refuses_before_termination(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            app = home / "Library/Developer/CoreSimulator/Devices" / DEVICE / "data/Containers/Bundle/Application/container/Kids.app"
            app.mkdir(parents=True)
            info = app / "Info.plist"
            info.write_bytes(plistlib.dumps(dict(CFBundleIdentifier=M.BUNDLE, KidsEvidenceImplementationRevision="a" * 64)))
            calls = []
            def sender(command, **kwargs):
                calls.append(command)
                return subprocess.CompletedProcess(command, 0, str(app))
            simulator = M.Simulator(sender, home)
            plan = M.validate_plan(value(), NOW)
            installation = simulator.verify(plan)
            info.write_bytes(plistlib.dumps(dict(CFBundleIdentifier=M.BUNDLE, KidsEvidenceImplementationRevision="b" * 64)))
            with self.assertRaisesRegex(ValueError, "approved build"):
                simulator.terminate(plan, installation)
            self.assertEqual(len(calls), 2)
            self.assertTrue(all(c[1] == "get_app_container" for c in calls))

    def test_import_does_not_execute_commands(self):
        with patch("subprocess.run") as sender:
            SPEC.loader.exec_module(M)
        sender.assert_not_called()

    def test_receipt_is_exclusive_internal_and_owner_only(self):
        path = Path("/private/tmp") / ("kids-guard-unit-" + str(uuid4()) + ".jsonl")
        try:
            with M.create_private_receipt(path) as receipt:
                receipt.write("fixture only\n")
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError): M.create_private_receipt(path)
            self.assertEqual(path.read_text(), "fixture only\n")
            with self.assertRaises(ValueError): M.create_private_receipt(Path("/unapproved-volume/receipt"))
        finally:
            path.unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main()
