#!/usr/bin/env python3
"""Check or install packaging tools without prompting for a sudo password."""
import argparse
import os
import shlex
import shutil
import subprocess

from common import ROOT, architecture

TOOLS = {
    'cargo': ('cargo', 'cargo', 'rust'),
    'readelf': ('binutils', 'binutils', 'binutils'),
    'dpkg-deb': ('dpkg-dev', 'dpkg', 'dpkg'),
    'rpmbuild': ('rpm', 'rpm-build', 'rpm-tools'),
    'rpm': ('rpm', 'rpm', 'rpm-tools'),
    'desktop-file-validate': ('desktop-file-utils', 'desktop-file-utils', 'desktop-file-utils'),
}


def check_cargo_metadata():
    """Fetch missing locked Rust sources, then verify offline license readiness."""
    arch = architecture()
    manifest = ROOT / 'native/media_core/Cargo.toml'
    command = [
        'cargo', 'metadata', '--locked', '--offline', '--format-version', '1',
        '--filter-platform', arch + '-unknown-linux-gnu', '--manifest-path', str(manifest),
    ]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode == 0:
        return True

    fetch = ['cargo', 'fetch', '--locked', '--target', arch + '-unknown-linux-gnu',
             '--manifest-path', str(manifest)]
    print('Preparing locked Cargo dependency sources: ' + shlex.join(fetch), flush=True)
    # Inherit output so download progress and network failures remain visible.
    if subprocess.run(fetch).returncode:
        print('Cargo fetch failed; check the error above and rerun this command.')
        return False

    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode == 0:
        return True
    print('Locked Cargo dependency sources are still not ready for offline Linux packaging.')
    if result.stderr.strip():
        print(result.stderr.strip())
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--install', action='store_true', help='Install missing tools if root or passwordless sudo is available')
    args = parser.parse_args()
    missing = [name for name in TOOLS if not shutil.which(name)]
    if missing:
        print('Missing packaging tools: ' + ', '.join(missing))
        installed = False
        for manager, column, options in [('apt-get', 0, ['install', '-y']), ('dnf', 1, ['install', '-y']), ('pacman', 2, ['-S', '--needed', '--noconfirm'])]:
            if shutil.which(manager):
                packages = sorted({TOOLS[name][column] for name in missing})
                command = [manager, *options, *packages]
                print('Install with: ' + shlex.join(['sudo', *command]))
                if not args.install:
                    return 1
                prefix = []
                if os.geteuid() != 0:
                    if not shutil.which('sudo') or subprocess.run(['sudo', '-n', 'true'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
                        print('No installation permission; run the sudo command above.')
                        return 1
                    prefix = ['sudo', '-n']
                if manager == 'apt-get':
                    subprocess.run([*prefix, manager, 'update'], check=True)
                subprocess.run([*prefix, *command], check=True)
                installed = all(shutil.which(name) for name in TOOLS)
                break
        if not installed:
            print('Install these tools with your distribution package manager.')
            return 1

    if not check_cargo_metadata():
        return 1
    print('Linux packaging tools and locked Cargo sources available')
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
