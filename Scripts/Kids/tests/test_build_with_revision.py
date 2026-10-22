import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("kids_build_with_revision", SCRIPTS / "build_with_revision.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class BuildWithRevisionTests(unittest.TestCase):
    def test_single_build_uses_fresh_revision_and_retains_caller_arguments(self):
        commands = []
        def runner(command, **kwargs):
            commands.append((command, kwargs))
            return subprocess.CompletedProcess(command, 0)
        root = Path("/fixture")
        self.assertEqual(MODULE.build(["--", "-scheme", "KidsJellyFin tvOS", "build"], root=root,
                                      runner=runner, digest=lambda _: "a" * 64), 0)
        self.assertEqual(commands, [(["xcodebuild", "-scheme", "KidsJellyFin tvOS", "build",
                                     "KIDS_EVIDENCE_REVISION=" + "a" * 64], {"cwd": root})])

    def test_source_mutation_refuses_acceptance_without_retrying_build(self):
        reads = iter(["a" * 64, "b" * 64])
        commands = []
        def runner(command, **kwargs):
            commands.append(command)
            return subprocess.CompletedProcess(command, 0)
        self.assertEqual(MODULE.build(["build"], runner=runner, digest=lambda _: next(reads)), 1)
        self.assertEqual(len(commands), 1)

    def test_release_version_supplies_canonical_bundle_settings(self):
        commands = []
        def runner(command, **kwargs):
            commands.append(command)
            return subprocess.CompletedProcess(command, 0)
        self.assertEqual(MODULE.build(
            ["--release-version", "20261022-0907", "--", "-scheme", "KidsJellyFin tvOS", "build"],
            runner=runner,
            digest=lambda _: "a" * 64,
        ), 0)
        self.assertEqual(commands[0][-4:], [
            "KIDS_EVIDENCE_REVISION=" + "a" * 64,
            "KIDS_RELEASE_VERSION=20261022-0907",
            "MARKETING_VERSION=2026.10.22",
            "CURRENT_PROJECT_VERSION=202610220907",
        ])

    def test_release_version_rejects_manual_bundle_settings(self):
        self.assertEqual(MODULE.build(
            ["--release-version", "20261022-0907", "MARKETING_VERSION=1.0", "build"],
            runner=lambda *a, **k: self.fail("invalid release must not build"),
            digest=lambda *a, **k: self.fail("invalid release must not read source"),
        ), 2)

    def test_compiler_failure_is_preserved_without_extra_digest_or_retry(self):
        reads = []
        def digest(root):
            reads.append(root)
            return "a" * 64
        self.assertEqual(MODULE.build(["build"], digest=digest,
                                      runner=lambda *a, **k: subprocess.CompletedProcess(a[0], 65)), 65)
        self.assertEqual(len(reads), 1)

    def test_manual_stamp_is_rejected_before_source_reads_or_command(self):
        def forbidden(*args, **kwargs):
            self.fail("manual stamp must fail before work")
        self.assertEqual(MODULE.build(["KIDS_EVIDENCE_REVISION=old", "build"],
                                      runner=forbidden, digest=forbidden), 2)

    def test_both_project_format_phases_are_read_only(self):
        project = (SCRIPTS.parents[1] / "KidsJellyFin.xcodeproj/project.pbxproj").read_text()
        self.assertEqual(project.count("    swiftformat --lint .\\n"), 2)
        self.assertNotIn("    swiftformat .\\n", project)

    def test_real_formatter_lint_refuses_unformatted_input_without_modifying_it(self):
        formatter = Path("/opt/homebrew/bin/swiftformat")
        if not formatter.exists():
            self.skipTest("SwiftFormat not installed")
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / "Unformatted.swift"
            original = b"let value=1;\n"
            fixture.write_bytes(original)
            result = subprocess.run([str(formatter), "--lint", str(fixture), "--config",
                                     str(SCRIPTS.parents[1] / ".swiftformat")], capture_output=True)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(fixture.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
