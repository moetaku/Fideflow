#!/usr/bin/env python3
"""Verify release checksums, architecture and extracted deb payload offline."""
import argparse
import json
from pathlib import Path
import tempfile
from common import ARCHES, architecture, check_baseline, elf_metadata, run, sha256


def verify(directory, rpm="rpm"):
    directory = directory.resolve()
    entries = []
    for line in (directory / 'SHA256SUMS').read_text().splitlines():
        digest, name = line.split('  ', 1)
        if Path(name).name != name or sha256(directory / name) != digest:
            raise ValueError('Invalid artifact checksum: ' + name)
        entries.append(name)
    manifests = [directory / name for name in entries if name.endswith('.json')]
    if len(manifests) != 1:
        raise ValueError('Expected exactly one release manifest')
    record = json.loads(manifests[0].read_text())
    arch = record['architecture']
    for artifact in record['artifacts']:
        path = directory / artifact['name']
        if path.name not in entries or path.stat().st_size != artifact['bytes'] or sha256(path) != artifact['sha256']:
            raise ValueError('Manifest differs from artifact: ' + path.name)
    debs = list(directory.glob('*.deb'))
    if len(debs) != 1:
        raise ValueError('Expected one deb')
    if run('dpkg-deb', '-f', debs[0], 'Architecture').strip() != ARCHES[arch]['deb']:
        raise ValueError('Deb architecture mismatch')
    with tempfile.TemporaryDirectory(prefix='verify-', dir=directory) as temporary:
        root = Path(temporary)
        run('dpkg-deb', '-x', debs[0], root)
        bundle = root / 'opt/fideflow'
        abi = elf_metadata(bundle, arch)
        if abi['elfFiles'] != record['elf']:
            raise ValueError('Packaged ELF bytes differ from verified bundle')
        check_baseline(abi['glibc'], record['minimumGlibc'])
        for name in ['BUILD.json', 'Fideflow-COPYRIGHT.txt', 'Dart-Flutter-NOTICES.txt', 'rust-dependencies.json', 'Apache-2.0.txt', 'Fideflow-media-core-MIT.txt', 'THIRD_PARTY_NOTICES.md']:
            if not (bundle / 'data/licenses' / name).is_file():
                raise ValueError('Missing license evidence: ' + name)
        if (root / 'usr/bin/fideflow').resolve() != bundle / 'fideflow':
            raise ValueError('Broken application launcher')
    rpms = list(directory.glob('*.rpm'))
    images = list(directory.glob('*.AppImage'))
    if len(rpms) != 1 or len(images) != 1:
        raise ValueError('Full verification requires one rpm and one AppImage')
    if run(rpm, '-qp', '--qf', '%{ARCH}', rpms[0]).strip() != ARCHES[arch]['rpm']:
        raise ValueError('RPM architecture mismatch')
    digests = dict(line.split(' ', 1) for line in run(rpm, '-qp', '--qf', '[%{FILENAMES} %{FILEDIGESTS}\\n]', rpms[0]).splitlines())
    for item in record['elf']:
        if digests.get('/opt/fideflow/' + item['path']) != item['sha256']:
            raise ValueError('RPM ELF file digest differs: ' + item['path'])
    # Extraction executes only the AppImage runtime, never the player itself.
    if arch != architecture():
        raise ValueError('AppImage extraction verification needs the matching native runner')
    with tempfile.TemporaryDirectory(prefix='appimage-verify-', dir=directory) as temporary:
        run(images[0], '--appimage-extract', cwd=temporary)
        appdir = Path(temporary) / 'squashfs-root'
        image_abi = elf_metadata(appdir / 'opt/fideflow', arch)
        if image_abi['elfFiles'] != record['elf']:
            raise ValueError('AppImage ELF bytes differ from verified bundle')
        if not (appdir / 'AppRun').is_file():
            raise ValueError('Missing AppRun')
        desktop = appdir / 'usr/share/applications/com.moetaku.fideflow.desktop'
        run('desktop-file-validate', desktop)
    print('Verified all three formats: checksums, architectures, ELF digests, desktop entry and license inventory:', arch)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--rpm', default='rpm')
    args = parser.parse_args()
    verify(args.directory, args.rpm)
