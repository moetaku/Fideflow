from pathlib import Path
import tempfile
import unittest

from check_presentation_boundaries import check


class PresentationBoundariesTest(unittest.TestCase):
    def test_shared_and_platform_violations_are_detected(self):
        with tempfile.TemporaryDirectory() as directory:
            lib = Path(directory)
            (lib / "features").mkdir()
            (lib / "presentation").mkdir()
            (lib / "features/page.dart").write_text(
                "Clipboard.setData(value); // FLUTTER_TEST", encoding="utf-8"
            )
            (lib / "presentation/model.dart").write_text(
                "import '../features/page.dart';", encoding="utf-8"
            )
            self.assertEqual(len(check(lib)), 3)

    def test_narrow_shared_dependency_is_allowed_and_missing_import_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            lib = Path(directory)
            (lib / "presentation").mkdir()
            (lib / "shared").mkdir()
            (lib / "presentation/model.dart").write_text("", encoding="utf-8")
            source = lib / "shared/widget.dart"
            source.write_text("import '../presentation/model.dart';", encoding="utf-8")
            self.assertEqual(check(lib), [])
            source.write_text("import '../../missing.dart';", encoding="utf-8")
            self.assertEqual(len(check(lib)), 1)


if __name__ == "__main__":
    unittest.main()
