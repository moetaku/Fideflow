#!/usr/bin/env python3
"""Small architecture gates; behavioral contracts live in regression tests.

These deliberately restrict layers rather than banning wire strings globally.
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def check():
    failures = []

    def reject(path, pattern, explanation, text=None):
        source = path.read_text() if text is None else text
        for match in re.finditer(pattern, source):
            line = source.count("\n", 0, match.start()) + 1
            failures.append(f"{path.relative_to(ROOT)}:{line}: {explanation}")

    for path in (ROOT / "packages/local_data/lib").rglob("*.dart"):
        reject(path, r"\b\w+\.index\b", "persist explicit storage codes, not enum declaration positions")

    for path in (ROOT / "packages/application/lib").rglob("*.dart"):
        reject(path, r"\.startsWith\(['\"](?:source|ncm\.)['\"]\)",
               "business recovery must use structured failure origin")

    for path in (ROOT / "native/media_core/crates/media-session/src").glob("*.rs"):
        production = path.read_text().split("#[cfg(test)]")[0]
        reject(path, r"\.reply(?:\.to_json\(\))?\s*\[\s*\"status\"\s*\]",
               "internal decisions must use CommandReply variants", production)

    for path in (ROOT / "apps/fideflow_flutter/lib").rglob("*.dart"):
        reject(path, r"\.title\.contains\(['\"]喜欢的音乐['\"]\)",
               "display text is not evidence of playlist identity")

    if failures:
        raise SystemExit("\n".join(failures))
    print("Architecture boundaries OK")


if __name__ == "__main__":
    check()
