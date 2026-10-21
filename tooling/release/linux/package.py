#!/usr/bin/env python3
"""Build relocatable AppImage, deb and rpm releases from a verified Linux bundle."""
from __future__ import annotations
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from common import APP_ID, ARCHES, CACHE, ROOT, architecture, check_baseline, download, elf_metadata, epoch, run, sha256, version
import licenses

DEB_DEPENDS = ('libc6 (>= {glibc}), libstdc++6 (>= 11), libgcc-s1, libgtk-3-0 (>= 3.22) | libgtk-3-0t64, '
               'libglib2.0-0 | libglib2.0-0t64, libsecret-1-0, libasound2 | libasound2t64, '
               'libasound2-plugins, libx11-6, libsqlite3-0, pulseaudio-utils')
RPM_REQUIRES = ('glibc >= {glibc}', 'libstdc++', 'libgcc', 'gtk3 >= 3.22', 'glib2', 'libsecret',
                'alsa-lib', 'alsa-plugins-pulseaudio', 'libX11', 'sqlite-libs', 'pulseaudio-utils')


def release_name(arch, value):
    return f'Fideflow-linux-{"arm64" if arch == "aarch64" else arch}-{value}'


DESKTOP = f'''[Desktop Entry]
Type=Application
Name=Fideflow
Comment=Music player
Exec=fideflow
TryExec=fideflow
Icon={APP_ID}
StartupWMClass={APP_ID}
Terminal=false
Categories=AudioVideo;Audio;Player;
'''
APPRUN = '''#!/bin/sh
set -eu
appdir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export XDG_DATA_DIRS="$appdir/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
exec "$appdir/opt/fideflow/fideflow" "$@"
'''


def deb_version(value):
    return value.replace('-', '~', 1)


def rpm_version(value):
    base, _, build = value.partition('+')
    stable, _, pre = base.partition('-')
    return stable, ('0.' + pre if pre else '1') + ('.' + build if build else '')


def verify(bundle):
    path = ROOT / 'tooling/native/linux/verify_bundle.py'
    spec = importlib.util.spec_from_file_location('verify_linux_bundle', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.verify(bundle, False, 'release')


def copy_bundle(bundle, target):
    for path in bundle.rglob('*'):
        if path.is_symlink() and (Path(os.readlink(path)).is_absolute() or not path.resolve().is_relative_to(bundle.resolve())):
            raise ValueError(f'Non-relocatable bundle symlink: {path}')
    shutil.copytree(bundle, target, symlinks=True)


def stage(bundle, directory, arch, value, abi, flutter_root, metadata, source):
    payload = directory / 'opt/fideflow'
    copy_bundle(bundle, payload)
    licenses.stage(bundle, payload / 'data/licenses', arch, flutter_root, metadata)
    build = {'applicationId': APP_ID, 'version': value, 'architecture': arch,
             'minimumGlibc': abi['glibc'], 'requiredGlibcxx': abi['glibcxx'],
             'source': source, 'gitCommit': run('git', '-C', ROOT, 'rev-parse', 'HEAD').strip(),
             'license': 'LicenseRef-Fideflow', 'sourceDateEpoch': epoch()}
    (payload / 'data/licenses/BUILD.json').write_text(json.dumps(build, indent=2) + '\n')
    bins = directory / 'usr/bin'
    bins.mkdir(parents=True)
    (bins / 'fideflow').symlink_to('../../opt/fideflow/fideflow')
    desktop = directory / 'usr/share/applications' / (APP_ID + '.desktop')
    desktop.parent.mkdir(parents=True)
    desktop.write_text(DESKTOP)
    if shutil.which("desktop-file-validate"):
        run("desktop-file-validate", desktop)
    icon = directory / 'usr/share/icons/hicolor/512x512/apps' / (APP_ID + '.png')
    icon.parent.mkdir(parents=True)
    shutil.copy2(bundle / 'fideflow.png', icon)
    doc = directory / 'usr/share/doc/fideflow'
    doc.mkdir(parents=True)
    (doc / 'copyright').write_text(licenses.APPLICATION_NOTICE + '\nThird-party license inventory: /opt/fideflow/data/licenses\n')
    return payload


def normalize(directory, timestamp):
    for path in sorted(directory.rglob('*'), reverse=True):
        if path.is_symlink():
            os.utime(path, (timestamp, timestamp), follow_symlinks=False)
        else:
            mode = 0o755 if path.is_dir() or os.access(path, os.X_OK) else 0o644
            path.chmod(mode)
            os.utime(path, (timestamp, timestamp))
    directory.chmod(0o755)
    os.utime(directory, (timestamp, timestamp))


def build_deb(directory, output, arch, value, abi, timestamp):
    control = directory / 'DEBIAN'
    control.mkdir()
    installed_size = sum(p.stat().st_size for p in directory.rglob('*') if p.is_file() and not p.is_symlink()) // 1024
    (control / 'control').write_text(
        f'Package: fideflow\nVersion: {deb_version(value)}\nSection: sound\nPriority: optional\n'
        f'Architecture: {ARCHES[arch]["deb"]}\nMaintainer: Fideflow contributors\n'
        f'Installed-Size: {installed_size}\nDepends: {DEB_DEPENDS.format(glibc=abi["glibc"])}\n'
        'Description: Fideflow desktop music player\n Native audio, desktop media controls and configurable shortcuts.\n')
    normalize(directory, timestamp)
    destination = output / (release_name(arch, value) + '.deb')
    run('dpkg-deb', '--root-owner-group', '--build', '-Zxz', directory, destination,
        env={**os.environ, 'SOURCE_DATE_EPOCH': str(timestamp)})
    shutil.rmtree(control)
    return destination


def build_rpm(directory, output, arch, value, abi, timestamp, rpmbuild):
    stable, release = rpm_version(value)
    work = directory.parent / 'rpm'
    for name in ['BUILD', 'BUILDROOT', 'RPMS', 'SOURCES', 'SPECS', 'SRPMS']:
        (work / name).mkdir(parents=True, exist_ok=True)
    spec = work / 'SPECS/fideflow.spec'
    # All bytes have been built and verified already. RPM must not strip/rewrite
    # bundled libraries or infer platform-specific Provides from private FFmpeg.
    spec.write_text(f'''%global __os_install_post %{{nil}}
%global debug_package %{{nil}}
%global __spec_install_post %{{nil}}
Name: fideflow
Version: {stable}
Release: {release}
Summary: Fideflow desktop music player
License: LicenseRef-Fideflow AND LicenseRef-Bundled-Components
BuildArch: {ARCHES[arch]['rpm']}
AutoReqProv: no
''' + ''.join('Requires: ' + x.format(glibc=abi['glibc']) + '\n' for x in RPM_REQUIRES) + '''
%description
Fideflow desktop music player with native audio and media controls.
%prep
%build
%install
mkdir -p "%{buildroot}"
cp -a "%{payload}/." "%{buildroot}/"
%files
/opt/fideflow
/usr/bin/fideflow
/usr/share/applications/com.moetaku.fideflow.desktop
/usr/share/icons/hicolor/512x512/apps/com.moetaku.fideflow.png
%dir /usr/share/doc/fideflow
%license /usr/share/doc/fideflow/copyright
''')
    normalize(directory, timestamp)
    run(rpmbuild, '-bb', '--target', ARCHES[arch]['rpm'], '--define', '_topdir ' + str(work),
        '--define', 'payload ' + str(directory), '--define', '_build_id_links none',
        '--define', 'use_source_date_epoch_as_buildtime 1', '--define', 'clamp_mtime_to_source_date_epoch 1', spec,
        env={**os.environ, 'SOURCE_DATE_EPOCH': str(timestamp)})
    result, = (work / 'RPMS').rglob('*.rpm')
    destination = output / (release_name(arch, value) + '.rpm')
    shutil.copy2(result, destination)
    return destination


def build_appimage(directory, output, arch, value, timestamp, tools, cache):
    appdir = directory.parent / 'Fideflow.AppDir'
    shutil.copytree(directory, appdir, symlinks=True)
    (appdir / 'AppRun').write_text(APPRUN)
    (appdir / 'AppRun').chmod(0o755)
    (appdir / (APP_ID + '.desktop')).symlink_to('usr/share/applications/' + APP_ID + '.desktop')
    (appdir / (APP_ID + '.png')).symlink_to('usr/share/icons/hicolor/512x512/apps/' + APP_ID + '.png')
    (appdir / '.DirIcon').symlink_to(APP_ID + '.png')
    normalize(appdir, timestamp)
    host = architecture()
    tool = download(tools['appimagetool']['assets'][host], cache)
    runtime = download(tools['runtime']['assets'][arch], cache)
    tool.chmod(0o755)
    runtime.chmod(0o755)
    destination = output / (release_name(arch, value) + '.AppImage')
    run(tool, '--appimage-extract-and-run', '--no-appstream', '--runtime-file', runtime, appdir, destination,
        env={**os.environ, 'ARCH': arch, 'SOURCE_DATE_EPOCH': str(timestamp), 'APPIMAGE_EXTRACT_AND_RUN': '1'})
    destination.chmod(0o755)
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--arch', choices=ARCHES, default=architecture())
    parser.add_argument('--bundle', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--version')
    parser.add_argument('--formats', nargs='+', choices=['appimage', 'deb', 'rpm'], default=['appimage', 'deb', 'rpm'])
    parser.add_argument('--minimum-glibc', default='2.35', help='Maximum ABI requirement accepted; newer builds must opt in explicitly')
    parser.add_argument('--flutter-root', type=Path, default=Path(os.environ.get('FLUTTER_ROOT') or (str(Path(shutil.which('flutter')).resolve().parents[1]) if shutil.which('flutter') else '/missing')))
    parser.add_argument('--cargo-metadata', type=Path)
    parser.add_argument('--rpmbuild', default='rpmbuild')
    parser.add_argument('--tool-cache', type=Path, default=CACHE / 'tools')
    args = parser.parse_args()
    host_arch = architecture()
    if args.arch != host_arch:
        raise ValueError(f'Linux packages must be built on the matching native host: host={host_arch}, requested={args.arch}')
    value = version(args.version)
    bundle = (args.bundle or ROOT / f'apps/fideflow_flutter/build/linux/{ARCHES[args.arch]["flutter"]}/release/bundle').resolve()
    output = (args.output or ROOT / f'build/release/linux/{value}/{args.arch}').resolve()
    if output.is_relative_to(bundle) or bundle.is_relative_to(output):
        raise ValueError('Bundle and output directories must not contain one another')
    verify(bundle)
    abi = elf_metadata(bundle, args.arch)
    check_baseline(abi['glibc'], args.minimum_glibc)
    output.mkdir(parents=True, exist_ok=True)
    timestamp = epoch()
    source_path = output / (release_name(args.arch, value) + '-sources.tar.xz')
    source = licenses.sources(source_path, 'fideflow-' + value, timestamp)
    tools = json.loads((Path(__file__).parent / 'tools.lock.json').read_text())
    with tempfile.TemporaryDirectory(prefix='stage-', dir=output) as scratch:
        directory = Path(scratch) / 'root'
        stage(bundle, directory, args.arch, value, abi, args.flutter_root.resolve(), args.cargo_metadata, source)
        artifacts = [source_path]
        for kind in args.formats:
            if kind == 'deb':
                artifacts.append(build_deb(directory, output, args.arch, value, abi, timestamp))
            elif kind == 'rpm':
                artifacts.append(build_rpm(directory, output, args.arch, value, abi, timestamp, args.rpmbuild))
            else:
                artifacts.append(build_appimage(directory, output, args.arch, value, timestamp, tools, args.tool_cache))
        manifest = {'version': value, 'architecture': args.arch, 'minimumGlibc': abi['glibc'],
                    'requiredGlibcxx': abi['glibcxx'], 'sourceDateEpoch': timestamp,
                    'artifacts': [{'name': p.name, 'sha256': sha256(p), 'bytes': p.stat().st_size} for p in artifacts],
                    'elf': abi['elfFiles'], 'tools': tools, 'runtimeDependencies': {
                        'deb': DEB_DEPENDS.format(glibc=abi['glibc']),
                        'rpm': [x.format(glibc=abi['glibc']) for x in RPM_REQUIRES]}}
        record = output / (release_name(args.arch, value) + '-release-manifest.json')
        record.write_text(json.dumps(manifest, indent=2) + '\n')
        (output / 'SHA256SUMS').write_text(''.join(f'{sha256(p)}  {p.name}\n' for p in [*artifacts, record]))
    print(f'Linux release packages written to {output}')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print('linux-package: ' + str(error), file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError):
            print(error.stdout or '', file=sys.stderr)
            print(error.stderr or '', file=sys.stderr)
        raise SystemExit(1)
