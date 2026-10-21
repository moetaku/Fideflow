#!/usr/bin/env python3
"""Prepare flat, uniquely named GitHub Release assets with auditable checksums."""
import argparse
import hashlib
import json
import re
from pathlib import Path
import shutil
import tarfile

REQUIRED = {
    'android': ('.apk', '-sources.tar.xz'),
    'ios': ('.ipa', '-sources.tar.xz'),
    'macos': ('.zip', '.dmg', '-sources.tar.xz'),
    'windows': ('.zip', '.exe', '-sources.tar.xz'),
    'linux': ('.AppImage', '.deb', '.rpm', '-sources.tar.xz'),
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


ARCH_NAMES = {'x64': 'x86_64', 'amd64': 'x86_64', 'x86_64': 'x86_64',
              'aarch64': 'arm64', 'arm64': 'arm64', 'universal': 'universal'}


def asset_prefix(platform, arch, version):
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+', version):
        raise ValueError('Invalid release version')
    return f'Fideflow-{platform}-{ARCH_NAMES[arch]}-{version}'


def asset_filename(name, platform, arch, version):
    prefix = asset_prefix(platform, arch, version)
    if platform == 'windows' and name.endswith(('-portable.zip', '-setup.exe')):
        return prefix + Path(name).suffix
    for suffix in ('-sources.tar.xz', '-portable.zip', '-setup.exe',
                   '.apk', '.ipa', '.zip', '.exe', '.dmg', '.AppImage', '.deb', '.rpm'):
        if name.endswith(suffix):
            return prefix + suffix
    if name.lower().startswith('fideflow') and name.endswith('.json'):
        name = 'release-manifest.json'
    return prefix + '-' + name



def stage(source, output, platform, arch, revision, version):
    arch = ARCH_NAMES[arch]
    group = platform + '-' + arch
    prefix = asset_prefix(platform, arch, version)
    files = sorted(p for p in source.iterdir() if p.is_file() and p.name != 'SHA256SUMS')
    for suffix in REQUIRED[platform]:
        if not any(p.name.endswith(suffix) for p in files):
            raise ValueError(f'{group}: missing artifact {suffix}')
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise ValueError('Asset output must be empty')
    entries = []
    for path in files:
        name = asset_filename(path.name, platform, arch, version)
        if (output / name).exists():
            raise ValueError(f'Duplicate normalized asset name: {name}')
        shutil.copy2(path, output / name)
        entries.append({'originalName': path.name, 'name': name, 'sha256': digest(output / name), 'bytes': path.stat().st_size})
    # Original build manifests stay intact. This mapping resolves their original
    # filenames to the unique Release asset names without modifying signed bytes.
    (output / (prefix + '-build.json')).write_text(json.dumps({
        'platform': platform, 'architecture': arch, 'version': version,
        'revision': revision, 'files': entries}, indent=2) + '\n')
    checksums(output, prefix + '-SHA256SUMS')


def checksums(directory, name):
    (directory / name).write_text(''.join(f'{digest(p)}  {p.name}\n' for p in sorted(directory.iterdir())
                                        if p.is_file() and p.name != name))


def verify(directory, revision):
    expected = {'android-universal', 'ios-arm64', 'macos-arm64', 'macos-x86_64',
                'windows-x86_64', 'linux-x86_64', 'linux-arm64'}
    records = list(directory.glob('*-build.json'))
    actual = {record['platform'] + '-' + record['architecture']
              for record in (json.loads(path.read_text()) for path in records)}
    if actual != expected or len(records) != len(expected):
        raise ValueError(f'Incomplete release: {actual}; expected {expected}')
    all_names = set()
    versions = set()
    for path in records:
        record = json.loads(path.read_text())
        prefix = asset_prefix(record['platform'], record['architecture'], record['version'])
        if path.name != prefix + '-build.json':
            raise ValueError('Invalid build manifest name: ' + path.name)
        versions.add(record['version'])
        if record['revision'] != revision:
            raise ValueError('Mixed build revisions')
        for entry in record['files']:
            if entry['name'] != asset_filename(entry['originalName'], record['platform'], record['architecture'], record['version']):
                raise ValueError('Invalid release asset name: ' + entry['name'])
            asset = directory / entry['name']
            if asset.parent != directory or not asset.is_file() or digest(asset) != entry['sha256']:
                raise ValueError(f'Asset missing or changed: {entry["name"]}')
            all_names.add(entry['name'])
        all_names.update({path.name, path.name.replace('-build.json', '-SHA256SUMS')})
    if len(versions) != 1:
        raise ValueError('Mixed build versions')
    if all_names != {p.name for p in directory.iterdir() if p.is_file() and p.name != 'SHA256SUMS'}:
        raise ValueError('Unexpected or missing release assets')
    checksums(directory, 'SHA256SUMS')



def publish_assets(directory, output, revision, version):
    """Keep exact platform source archives in one downloadable source bundle."""
    verify(directory, revision)
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+', version):
        raise ValueError('Invalid release version')
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise ValueError('Publish output must be empty')
    sources = sorted(directory.glob('*-sources.tar.xz'))
    for record in directory.glob('*-build.json'):
        if json.loads(record.read_text())['version'] != version:
            raise ValueError('Build version differs from release version')
    with tarfile.open(output / f'Fideflow-all-universal-{version}-sources.tar.xz', 'w:xz') as archive:
        for path in sources:
            archive.add(path, arcname=path.name, recursive=False)
    for path in directory.iterdir():
        if path.is_file() and path not in sources and path.name != 'SHA256SUMS':
            shutil.copy2(path, output / path.name)
    checksums(output, 'SHA256SUMS')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--platform', choices=REQUIRED)
    parser.add_argument('--arch')
    parser.add_argument('--revision', required=True)
    parser.add_argument('--verify', action='store_true')
    parser.add_argument('--publish', action='store_true')
    parser.add_argument('--version')
    args = parser.parse_args()
    if args.publish:
        if not args.source or not args.version:
            parser.error('publishing requires --source and --version')
        publish_assets(args.source, args.output, args.revision, args.version)
    elif args.verify:
        verify(args.output, args.revision)
    else:
        if not all((args.source, args.platform, args.arch, args.version)):
            parser.error('staging requires --source, --platform, --arch and --version')
        stage(args.source, args.output, args.platform, args.arch, args.revision, args.version)


if __name__ == '__main__':
    main()
