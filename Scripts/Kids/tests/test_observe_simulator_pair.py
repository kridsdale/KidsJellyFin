import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT))
SPEC = importlib.util.spec_from_file_location("observe_simulator_pair", ROOT / "observe_simulator_pair.py")
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)


def tree(label, children=None):
    return [{"type": "Application", "AXLabel": label, "children": children or []}]


class Host:
    synthetic = True

    def __init__(self, phone=None, fail_phone=False):
        self.ui = {"tv": tree("KidsJellyFin"), "phone": phone or tree("KidsJellyFin Parents")}
        self.calls = []
        self.fail_phone = fail_phone

    def describe(self, device):
        self.calls.append(("describe", device))
        return self.ui[device]

    def screenshot(self, device, destination):
        self.calls.append(("screenshot", device))
        if device == "phone" and self.fail_phone:
            raise RuntimeError("synthetic capture failure")
        destination.write_bytes(M.PNG + b"synthetic-not-runtime-evidence")


INSTALLATIONS = {"television": {"simulatorID": "tv"}, "phone": {"simulatorID": "phone"}}


class PairTests(unittest.TestCase):
    def test_rejects_nested_input_without_creating_output_or_screenshots(self):
        for kind in ("TextField", "SecureTextField", "TextView", "WebArea"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                host = Host(tree("KidsJellyFin Parents", [{"type": "Group", "children": [
                    {"type": kind, "AXValue": "synthetic-private-input"}]}]))
                output = Path(directory) / "pair"
                with self.assertRaises(ValueError):
                    M.capture_pair(host, INSTALLATIONS, output, "after-pause", private_root=Path(directory))
                self.assertEqual(host.calls, [("describe", "tv"), ("describe", "phone")])
                self.assertFalse(output.exists())

    def test_foreign_or_multiple_foreground_apps_refuse_capture(self):
        for ui in (tree("SpringBoard"), tree("KidsJellyFin Parents") + tree("Other app")):
            with self.subTest(ui=ui), tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / "pair"
                with self.assertRaises(ValueError):
                    M.capture_pair(Host(ui), INSTALLATIONS, output, "baseline", private_root=Path(directory))
                self.assertFalse(output.exists())

    def test_private_outputs_follow_both_checks_and_do_not_claim_actions_or_receipts(self):
        with tempfile.TemporaryDirectory() as directory:
            host = Host(tree("KidsJellyFin Parents", [{"type": "Button", "AXLabel": "Pause", "AXValue": "not-exported"}]))
            output = Path(directory) / "pair"
            result = M.capture_pair(host, INSTALLATIONS, output, "after-pause", private_root=Path(directory))
            self.assertEqual(host.calls, [("describe", "tv"), ("describe", "phone"),
                                          ("screenshot", "tv"), ("screenshot", "phone")])
            self.assertTrue(result["synthetic"])
            self.assertTrue(result["phaseIsOperatorAnnotation"])
            self.assertEqual(result["actionsPerformedByCapture"], 0)
            self.assertFalse(result["backendReceiptsVerified"])
            self.assertFalse(result["continuousRendererOrAudioProof"])
            self.assertNotIn("not-exported", (output / "observation.json").read_text())
            self.assertEqual(os.stat(output).st_mode & 0o777, 0o700)
            for name in ("television.png", "phone.png", "observation.json"):
                self.assertEqual(os.stat(output / name).st_mode & 0o777, 0o600)
            self.assertEqual(json.loads((output / "observation.json").read_text()), result)

    def test_partial_failure_never_writes_success_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "pair"
            with self.assertRaises(RuntimeError):
                M.capture_pair(Host(fail_phone=True), INSTALLATIONS, output, "after-resume", private_root=Path(directory))
            self.assertFalse((output / "observation.json").exists())

    def test_existing_or_outside_directory_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "pair"
            output.mkdir()
            marker = output / "keep"
            marker.write_text("preserved")
            for candidate in (output, root / "nested" / "pair"):
                with self.assertRaises(ValueError):
                    M.capture_pair(Host(), INSTALLATIONS, candidate, "baseline", private_root=root)
            self.assertEqual(marker.read_text(), "preserved")

    def test_input_values_are_never_exported_and_identifiers_are_strict(self):
        observed = M.inspect_ui(tree("KidsJellyFin", [{"type": "Button", "AXValue": "private", "AXLabel": "Parents"}]), "KidsJellyFin")
        self.assertNotIn("AXValue", json.dumps(observed))
        for bad in ("booted", "", "a" * 64):
            with self.assertRaises(ValueError): M.device(bad)
        for bad in ("", "a" * 63, "A" * 64, "not-a-hash"):
            with self.assertRaises(ValueError): M.digest(bad)


if __name__ == "__main__":
    unittest.main()
