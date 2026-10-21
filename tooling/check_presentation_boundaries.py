"""Check the page boundaries that Dart's type/lint checks do not express."""

from pathlib import Path
import re
import sys


LEGACY_IMPORTS = {
    "app/navigation_ids.dart",
    "features/catalog/music_management.dart",
    "features/player/quality_selector.dart",
    "features/discovery/widgets/collection_card.dart",
    "features/settings/settings_tile.dart",
}


def check(lib: Path) -> list[str]:
    failures = []
    for source in sorted(lib.rglob("*.dart")):
        relative = source.relative_to(lib).as_posix()
        text = source.read_text(encoding="utf-8")
        for match in re.finditer(r"^import\s+'([^']+)'", text, re.MULTILINE):
            uri = match.group(1)
            if uri.startswith("package:fideflow/"):
                target = lib / uri.removeprefix("package:fideflow/")
            elif uri.startswith(("package:", "dart:")):
                continue
            else:
                target = source.parent / uri
            try:
                imported = target.resolve().relative_to(lib.resolve()).as_posix()
            except ValueError:
                failures.append(f"{relative}: import escapes lib: {uri}")
                continue
            if not target.is_file():
                failures.append(f"{relative}: import target missing: {uri}")
            if imported in LEGACY_IMPORTS:
                failures.append(f"{relative}: import the shared module directly: {imported}")
            if relative.startswith("presentation/") and imported.startswith(("app/", "features/")):
                failures.append(f"{relative}: presentation depends on implementation: {imported}")
            if relative.startswith("shared/") and imported.startswith("features/"):
                failures.append(f"{relative}: shared UI depends on a feature: {imported}")
        if relative.startswith("features/"):
            if re.search(r"\bClipboard\s*\.\s*setData\s*\(", text):
                failures.append(f"{relative}: use the clipboard presentation action")
            if "FLUTTER_TEST" in text:
                failures.append(f"{relative}: product behavior must not depend on the test environment")
    return failures


if __name__ == "__main__":
    root = Path(__file__).resolve().parents[1]
    violations = check(root / "apps/fideflow_flutter/lib")
    if violations:
        print("\n".join(violations), file=sys.stderr)
        raise SystemExit(1)
    print("Presentation boundaries passed.")
