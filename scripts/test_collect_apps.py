import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("collector", Path(__file__).with_name("collect-apps.py"))
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)


class CoordinatedOutputTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        for platform, extension in collector.PLATFORMS.items():
            (self.root / f"CloudReader-1.2.0-{platform}{extension}").write_bytes(platform.encode())
            collector.stamp(self.root, platform, "1.2.0", "same-revision")

    def test_collects_three_verified_packages(self):
        collector.collect(self.root, "1.2.0", "same-revision")
        self.assertEqual(3, len(json.loads((self.root / "delivery.json").read_text())["packages"]))

    def test_missing_platform_blocks_output(self):
        (self.root / "linux.json").unlink()
        with self.assertRaises(ValueError):
            collector.collect(self.root, "1.2.0", "same-revision")

    def test_wrong_revision_blocks_output(self):
        collector.stamp(self.root, "windows", "1.2.0", "other-revision")
        with self.assertRaises(ValueError):
            collector.collect(self.root, "1.2.0", "same-revision")

    def test_modified_package_blocks_output(self):
        next(self.root.glob("*.apk")).write_bytes(b"changed")
        with self.assertRaises(ValueError):
            collector.collect(self.root, "1.2.0", "same-revision")
