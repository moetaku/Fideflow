"""Regression checks for the macOS native bundle cache (no Xcode required)."""

import pathlib
import subprocess
import tempfile
import unittest


class EmbedFingerprintTest(unittest.TestCase):
    def test_rust_source_changes_invalidate_existing_artifact(self):
        script = pathlib.Path(__file__).parents[1] / "macos/embed.sh"
        source = script.read_text()
        function = source.split("bundle_fingerprint() {", 1)[1].split(
            "\ncheck_bundle_up_to_date()", 1
        )[0]
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            crates = root / "native/media_core/crates"
            crates.mkdir(parents=True)
            (root / "native/media_core/build-support").mkdir()
            vendor = root / "native/media_core/vendor"
            vendor.mkdir()
            (root / "native/media_core/Cargo.toml").write_text("workspace")
            scripts = root / "tooling/native/macos"
            scripts.mkdir(parents=True)
            (scripts / "rust.sh").write_text("build")
            (scripts / "embed.sh").write_text(source)
            rust = crates / "session.rs"
            rust.write_text("old")
            shell = (
                'REPO_ROOT="$1"; RUST=1; NETWORK_MODE=openssl; '
                'SIGN_IDENTITY=-; deployment_target() { echo 11; }; '
                'prefix_for() { echo "$REPO_ROOT/missing"; }; '
                "bundle_fingerprint() {" + function + '\nbundle_fingerprint app arm64'
            )

            def fingerprint():
                return subprocess.check_output(
                    ["bash", "-c", shell, "test", str(root)], text=True
                )

            before = fingerprint()
            self.assertEqual(before, fingerprint())
            rust.write_text("new")  # Same size and potentially same mtime.
            changed = fingerprint()
            self.assertNotEqual(before, changed)
            added = crates / "added.rs"
            added.write_text("new module")
            self.assertNotEqual(changed, fingerprint())
            added.unlink()
            self.assertEqual(changed, fingerprint())
            rust.rename(crates / "renamed.rs")
            self.assertNotEqual(changed, fingerprint())
            for filename in ("shim.c", "shim.h", "Cargo.toml", "build.rs"):
                before = fingerprint()
                (crates / filename).write_text("build input")
                self.assertNotEqual(before, fingerprint())
            before = fingerprint()
            (vendor / "request.rs").write_text("patched SDK")
            self.assertNotEqual(before, fingerprint())
            before = fingerprint()
            shell = 'RUSTFLAGS="-C opt-level=1"; ' + shell
            self.assertNotEqual(before, fingerprint())

    def test_atomic_replace_preserves_open_old_image_and_cleans_failures(self):
        source = (pathlib.Path(__file__).parents[1] / "macos/embed.sh").read_text()
        function = source.split("replace_packaged_file() {", 1)[1].split(
            "\n# Copies the packaged executables", 1
        )[0]
        shell = (
            'set -euo pipefail; die() { echo "$*" >&2; exit 1; }; '
            "replace_packaged_file() {" + function +
            '\nreplace_packaged_file "$1" "$2"'
        )
        with tempfile.TemporaryDirectory(prefix="embed test ") as directory:
            root = pathlib.Path(directory)
            original = root / "packaged.dylib"
            incoming = root / "staged.dylib"
            original.write_bytes(b"old image")
            incoming.write_bytes(b"new image")
            with original.open("rb") as mapped:
                subprocess.run(
                    ["bash", "-c", shell, "test", str(incoming), str(original)],
                    check=True,
                )
                self.assertEqual(mapped.read(), b"old image")
            self.assertEqual(original.read_bytes(), b"new image")
            self.assertEqual(original.stat().st_mode & 0o777, 0o755)
            result = subprocess.run(
                ["bash", "-c", shell, "test", str(root / "missing"), str(original)],
                capture_output=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(original.read_bytes(), b"new image")
            self.assertEqual(list(root.glob("*.embed.*")), [])


if __name__ == "__main__":
    unittest.main()
