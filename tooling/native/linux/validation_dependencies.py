"""Optional Linux validation tools, kept separate from product build dependencies."""
import shutil
import subprocess

PACKAGES = {
    "apt": {
        "pactl": "pulseaudio-utils", "secret-tool": "libsecret-tools", "xwininfo": "x11-utils",
        "xvfb-run": "xvfb", "Xvfb": "xvfb", "xauth": "xauth",
        "dbus-run-session": "dbus", "dbus-daemon": "dbus", "gdbus": "libglib2.0-bin",
        "gnome-keyring-daemon": "gnome-keyring",
        "xtst": "libxtst-dev",
    },
    "dnf": {
        "pactl": "pulseaudio-utils", "secret-tool": "libsecret", "xwininfo": "xwininfo",
        "xvfb-run": "xorg-x11-server-Xvfb", "Xvfb": "xorg-x11-server-Xvfb",
        "xauth": "xorg-x11-xauth", "dbus-run-session": "dbus-daemon",
        "dbus-daemon": "dbus-daemon", "gdbus": "glib2",
        "gnome-keyring-daemon": "gnome-keyring",
        "xtst": "libXtst-devel",
    },
    "pacman": {
        "pactl": "libpulse", "secret-tool": "libsecret", "xwininfo": "xorg-xwininfo",
        "xvfb-run": "xorg-server-xvfb", "Xvfb": "xorg-server-xvfb",
        "xauth": "xorg-xauth", "dbus-run-session": "dbus", "dbus-daemon": "dbus", "gdbus": "glib2",
        "gnome-keyring-daemon": "gnome-keyring",
        "xtst": "libxtst",
    },
}



def missing_tools():
    missing = [tool for tool in PACKAGES["apt"]
               if tool != "xtst" and shutil.which(tool) is None]
    try:
        available = subprocess.run(["pkg-config", "--exists", "xtst"],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                   check=False).returncode == 0
    except OSError:
        available = False
    if not available:
        missing.append("xtst")
    return missing


def ensure(dependencies, check_only=False):
    for manager, packages in PACKAGES.items():
        dependencies.PACKAGES[manager].update(packages)
    if not dependencies.install_system(missing_tools(), check_only):
        return False
    remaining = missing_tools()
    if remaining:
        dependencies.log("Validation tools still unavailable: " + ", ".join(remaining))
        return False
    dependencies.log("Optional validation tools are ready.")
    return True
