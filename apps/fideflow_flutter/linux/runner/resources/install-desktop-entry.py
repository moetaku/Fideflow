#!/usr/bin/env python3
"""Install Fideflow's stable desktop/portal application entry."""
from __future__ import annotations

import hashlib
import os
import shutil
import argparse
from pathlib import Path


APPLICATION_ID = "com.moetaku.fideflow"


def legacy_application_id() -> str:
    xdg_data_home = os.environ.get("XDG_DATA_HOME", "")
    home = os.environ.get("HOME", "")
    if xdg_data_home.startswith("/"):
        data_root = Path(xdg_data_home) / "Fideflow"
    elif home.startswith("/"):
        data_root = Path(home) / ".local/share/Fideflow"
    else:
        raise RuntimeError("Fideflow requires an absolute HOME or XDG_DATA_HOME")
    canonical_root = os.path.realpath(data_root)
    digest = hashlib.sha256(canonical_root.encode()).hexdigest()[:20]
    return f"com.moetaku.fideflow.root-{digest}"


def desktop_quote(value: str) -> str:
    # Desktop Exec values use their own quoting rules rather than shell syntax.
    value = value.replace("%", "%%").replace("\\", "\\\\").replace('"', '\\"')
    return f'"{value}"'


def desktop_string(value: str) -> str:
    # TryExec and Icon are Desktop Entry strings, not Exec command lines.
    # Quotes would become part of the filename and make GDesktopAppInfo reject
    # an otherwise installed application.
    return (value.replace("\\", "\\\\").replace("\n", "\\n")
            .replace("\r", "\\r").replace("\t", "\\t"))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, default=Path(__file__).resolve().parent)
    args = parser.parse_args()
    bundle = args.bundle.resolve()
    executable = bundle / "fideflow"
    icon_source = bundle / "fideflow.png"
    if not executable.is_file() or not icon_source.is_file():
        raise RuntimeError("run this installer from a complete Fideflow Linux bundle")

    data_home = Path(os.environ.get("XDG_DATA_HOME", "") or Path.home() / ".local/share")
    applications = data_home / "applications"
    icon_dir = data_home / "icons/hicolor/512x512/apps"
    app_id = APPLICATION_ID
    desktop_file = applications / f"{app_id}.desktop"
    icon_file = icon_dir / "fideflow.png"

    applications.mkdir(parents=True, exist_ok=True)
    icon_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(icon_source, icon_file)
    desktop_file.write_text(
        "[Desktop Entry]\n"
        "Type=Application\n"
        "Name=Fideflow\n"
        "Comment=Music player\n"
        f"Exec={desktop_quote(str(executable))}\n"
        f"TryExec={desktop_string(str(executable))}\n"
        f"Icon={desktop_string(str(icon_file))}\n"
        f"StartupWMClass={app_id}\n"
        "Terminal=false\n"
        "Categories=AudioVideo;Audio;Player;\n",
        encoding="utf-8",
    )
    # Migrate entries produced by earlier versions of this installer. Leave
    # user-authored entries alone unless they match our generated identity.
    legacy_id = legacy_application_id()
    legacy_file = applications / f"{legacy_id}.desktop"
    if legacy_file.is_file():
        legacy_text = legacy_file.read_text(encoding="utf-8")
        if ("\nName=Fideflow\n" in legacy_text and
                f"\nStartupWMClass={legacy_id}\n" in legacy_text):
            legacy_file.unlink()
    print(f"Installed {desktop_file}")
    print("Pin the new Fideflow launcher to your dock/taskbar if it is already pinned.")


if __name__ == "__main__":
    main()
