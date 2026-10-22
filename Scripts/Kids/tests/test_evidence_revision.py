import importlib.util
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "evidence_revision.py"
SPEC = importlib.util.spec_from_file_location("receiver_evidence_revision", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ReceiverEvidenceRevisionTests(unittest.TestCase):
    def populate(self, root):
        for name in MODULE.INPUTS:
            path = root / name
            if path.suffix:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("fixture\n")
            else:
                path.mkdir(parents=True)
                (path / "Fixture.swift").write_text("// fixture\n")

    def test_new_receiver_source_changes_the_embedded_evidence_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.populate(root)
            before = MODULE.implementation_digest(root)
            (root / "Packages/KidsViewingControl/Sources/KidsViewingControl/Lease.swift").write_text("// revised lease gate\n")
            self.assertNotEqual(before, MODULE.implementation_digest(root))


    def test_catalog_eligibility_changes_the_embedded_evidence_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.populate(root)
            domain = root / "Packages/KidsDomain/Sources/KidsDomain"
            domain.mkdir(parents=True, exist_ok=True)
            source = domain / "Eligibility.swift"
            source.write_text("// initial eligibility\n")
            before = MODULE.implementation_digest(root)
            source.write_text("// revised eligibility\n")
            self.assertNotEqual(before, MODULE.implementation_digest(root))

    def test_symlinked_catalog_module_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.populate(root)
            domain = root / "Packages/KidsDomain/Sources/KidsDomain"
            if domain.exists():
                for source in domain.iterdir():
                    source.unlink()
                domain.rmdir()
            domain.parent.mkdir(parents=True, exist_ok=True)
            domain.symlink_to(root / "Packages/KidsApplication/Sources/KidsApplication", target_is_directory=True)
            with self.assertRaisesRegex(ValueError, "implementation_symlink"):
                MODULE.implementation_digest(root)

    def test_symlinked_receiver_source_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.populate(root)
            source = root / "Packages/KidsApplication/Sources/KidsApplication/Fixture.swift"
            source.unlink()
            source.symlink_to(root / "Scripts/Kids/evidence_revision.py")
            with self.assertRaisesRegex(ValueError, "implementation_input_invalid"):
                MODULE.implementation_digest(root)


if __name__ == "__main__":
    unittest.main()
