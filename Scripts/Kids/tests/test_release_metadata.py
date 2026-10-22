from datetime import datetime
import json
from pathlib import Path
import sys
import tempfile
import unittest
from zoneinfo import ZoneInfo

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

from release_metadata import ReleaseVersion, manifest


class ReleaseMetadataTests(unittest.TestCase):
    def test_pacific_version_and_bundle_mapping(self):
        utc = datetime(2026, 10, 22, 16, 7, tzinfo=ZoneInfo("UTC"))
        version = ReleaseVersion.current(utc)
        self.assertEqual(version.value, "20261022-0907")
        self.assertEqual(version.marketing_version, "2026.10.22")
        self.assertEqual(version.build_version, "202610220907")
        self.assertEqual(version.tag, "client-v20261022-0907")

    def test_invalid_or_impossible_versions_are_rejected(self):
        for value in ["2026-10-22-0907", "20261022", "20261322-0907"]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                ReleaseVersion.parse(value)

    def test_manifest_hashes_files_and_directories_and_records_rollback(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifact = root / "KidsJellyFin.app"
            artifact.mkdir()
            (artifact / "binary").write_bytes(b"app")
            evidence = root / "qa.md"
            evidence.write_text("pass\n")
            record = manifest(
                root=root,
                version=ReleaseVersion.parse("20261022-0907"),
                source_commit="a" * 40,
                source_revision="b" * 64,
                branch="feature/kids-release-candidate",
                rollback_version="20261021-1840",
                rollback_commit="c" * 40,
                artifacts=[artifact],
                qa_evidence=[evidence],
                backend_message_id="105",
            )
            self.assertEqual(record["releaseVersion"], "20261022-0907")
            self.assertEqual(record["artifacts"][0]["files"], 1)
            self.assertEqual(record["qaEvidence"][0]["path"], "qa.md")
            self.assertEqual(record["rollback"]["tag"], "client-v20261021-1840")
            self.assertEqual(record["backendNotification"]["messageId"], "105")
            json.dumps(record)


if __name__ == "__main__":
    unittest.main()
