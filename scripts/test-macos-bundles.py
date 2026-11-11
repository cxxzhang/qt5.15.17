#!/usr/bin/env python3
"""Check actual upstream icons and plist preservation without requiring macOS."""

import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("macos_bundles", Path(__file__).with_name("prepare-macos-bundles.py"))
bundles = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundles)
SOURCE = Path(__file__).resolve().parent.parent


class MetadataTests(unittest.TestCase):
    def test_upstream_application_icons_and_document_metadata(self):
        for name in ("designer", "assistant", "linguist", "qdbusviewer", "qml", "qmlscene"):
            with self.subTest(product=name), tempfile.TemporaryDirectory() as temporary:
                app = Path(temporary) / (name + ".app")
                contents = app / "Contents"
                (contents / "MacOS").mkdir(parents=True)
                (contents / "MacOS" / name).write_bytes(b"executable fixture")
                (contents / "MacOS" / name).chmod(0o755)
                info = {"CFBundleExecutable": name, "CFBundleIconFile": "@ICON@",
                        "CFBundleIdentifier": "org.qt-project." + name,
                        "NSHumanReadableCopyright": "Preserved upstream copyright",
                        "CFBundleDocumentTypes": [{"CFBundleTypeRole": "Editor", "CFBundleTypeExtensions": ["ui"]}]}
                if name == "designer":
                    info["CFBundleDocumentTypes"][0]["CFBundleTypeIconFile"] = "uifile.icns"
                with (contents / "Info.plist").open("wb") as stream:
                    plistlib.dump(info, stream)

                def unexpected_fallback():
                    self.fail("An existing upstream product icon should be used")

                bundles.embed_bundle(app, SOURCE, "5.15.17", unexpected_fallback)
                result = bundles.verify_bundle(app, "5.15.17")
                self.assertEqual(result["CFBundleName"], bundles.PRODUCTS[name][0])
                self.assertEqual(result["CFBundleDisplayName"], bundles.PRODUCTS[name][0])
                self.assertEqual(result["CFBundleDocumentTypes"], info["CFBundleDocumentTypes"])
                self.assertEqual(result["NSHumanReadableCopyright"], info["NSHumanReadableCopyright"])
                self.assertEqual(result["CFBundleVersion"], "5.15.17")
                original = SOURCE / bundles.PRODUCTS[name][2]
                self.assertEqual((contents / "Resources" / result["CFBundleIconFile"]).read_bytes(), original.read_bytes())
                (contents / "Resources" / result["CFBundleIconFile"]).unlink()
                with self.assertRaises((OSError, ValueError)):
                    bundles.verify_bundle(app, "5.15.17")


if __name__ == "__main__":
    unittest.main()
