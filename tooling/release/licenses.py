#!/usr/bin/env python3
"""Collect release license evidence; missing text is fatal, online metadata is opt-in."""
from __future__ import annotations
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[2]
COMPONENTS = {
    'android': ('ffmpeg', 'libsoxr', 'miniaudio'),
    'ios': ('ffmpeg', 'libsoxr', 'miniaudio'),
    'macos': ('ffmpeg', 'libsoxr', 'portaudio'),
    'windows': ('ffmpeg', 'libsoxr', 'portaudio'),
    'linux': ('ffmpeg', 'libsoxr', 'portaudio'),
}


def rust_notices(target, triple, metadata=None):
    if metadata is None:
        metadata = json.loads(subprocess.check_output([
            'cargo', 'metadata', '--locked', '--offline', '--format-version', '1',
            '--filter-platform', triple, '--manifest-path', str(ROOT / 'native/media_core/Cargo.toml')], text=True))
    nodes = {node['id']: node for node in metadata['resolve']['nodes']}
    reachable, pending = set(), list(metadata['workspace_members'])
    while pending:
        item = pending.pop()
        if item in reachable:
            continue
        reachable.add(item)
        pending.extend(dep['pkg'] for dep in nodes.get(item, {}).get('deps', []))
    index = []
    for package in sorted(metadata['packages'], key=lambda p: (p['name'], p['version'])):
        if package['id'] not in reachable:
            continue
        directory = Path(package['manifest_path']).parent
        candidates = {p for p in directory.iterdir() if p.is_file() and p.name.upper().startswith(
            ('LICENSE', 'LICENCE', 'COPYING', 'NOTICE', 'AUTHORS', 'COPYRIGHT'))}
        if package.get('license_file'):
            candidates.add(directory / package['license_file'])
        # Workspace-owned MIT crates inherit the media_core license, not root Apache.
        if not package.get('source') and package.get('license') == 'MIT' and directory.is_relative_to(ROOT / 'native/media_core/crates'):
            candidates.add(ROOT / 'native/media_core/LICENSE')
        if not package.get('source') and package.get('license') == 'Apache-2.0' and directory.is_relative_to(ROOT / 'native/media_core/crates'):
            candidates.add(ROOT / 'LICENSE')
        supplement = ROOT / 'tooling/release/rust-license-evidence'
        supplemental_evidence = None
        if not candidates and (supplement / 'sources.json').is_file():
            key = package['name'] + '-' + package['version']
            supplemental_evidence = json.loads((supplement / 'sources.json').read_text()).get(key)
            if supplemental_evidence:
                if supplemental_evidence['repository'] != package.get('repository'):
                    raise ValueError(f'License evidence repository mismatch: {key}')
                for filename, record in supplemental_evidence['files'].items():
                    path = supplement / key / filename
                    if hashlib.sha256(path.read_bytes()).hexdigest() != record['sha256']:
                        raise ValueError(f'License evidence checksum mismatch: {key}')
                    candidates.add(path)
        destination = target / 'rust' / (package['name'] + '-' + package['version'])
        evidence = []
        for path in sorted(candidates):
            if not path.is_file() or not path.read_bytes().strip():
                raise ValueError(f'Missing or empty declared license: {path}')
            destination.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, destination / path.name)
            evidence.append(path.name)
        if supplemental_evidence:
            shutil.copy2(supplement / 'sources.json', destination / 'SOURCE-EVIDENCE.json')
            evidence.append('SOURCE-EVIDENCE.json')
        if not evidence:
            raise ValueError(f'No license text for Rust dependency {package["name"]}')
        index.append({'name': package['name'], 'version': package['version'],
                      'license': package.get('license'), 'source': package.get('source'), 'files': evidence})
    (target / 'rust-dependencies.json').write_text(json.dumps(index, indent=2) + '\n')
    return index


def stage(target, triple, flutter_root, notices=None, metadata=None):
    target.mkdir(parents=True, exist_ok=True)
    for source, name in [(ROOT / 'LICENSE', 'Apache-2.0.txt'),
                         (ROOT / 'native/media_core/LICENSE', 'Fideflow-media-core-MIT.txt'),
                         (ROOT / 'THIRD_PARTY_NOTICES.md', 'THIRD_PARTY_NOTICES.md'),
                         (ROOT / 'pubspec.lock', 'pubspec.lock'),
                         (ROOT / 'native/media_core/vendor/ncm-api-rs/LICENSE', 'ncm-api-rs-LICENSE')]:
        shutil.copy2(source, target / name)
    for name in ('SourceHanSans-LICENSE.txt', 'SourceHanSans-SOURCE.txt'):
        shutil.copy2(ROOT / 'apps/fideflow_flutter/assets/fonts' / name, target / name)
    shutil.copy2(flutter_root / 'LICENSE', target / 'Flutter-LICENSE.txt')
    # Flutter includes package and engine notices in its generated NOTICES.Z.
    # Mobile release builds generate it after staging; verification checks the final archive.
    if notices is not None:
        with gzip.open(notices, 'rb') as source:
            (target / 'Dart-Flutter-NOTICES.txt').write_bytes(source.read())
    for source in (flutter_root / 'bin/cache').glob('LICENSE.*_archive.md'):
        shutil.copy2(source, target / source.name)
    rust_target = target / 'rust-targets' / triple
    if rust_target.exists():
        shutil.rmtree(rust_target)
    rust_target.mkdir(parents=True)
    index = rust_notices(rust_target, triple, metadata)
    # Separate records retain both Android ABIs instead of overwriting one graph.
    inventories = {p.parent.name: p.relative_to(target).as_posix()
                   for p in sorted((target / 'rust-targets').glob('*/rust-dependencies.json'))}
    (target / 'rust-dependencies.json').write_text(json.dumps({
        'scope': 'target-filtered workspace dependency closure, including build/dev dependencies',
        'targets': inventories}, indent=2) + '\n')
    return index


def sources(output, platform):
    """Ship pinned upstream sources plus native build scripts/configuration."""
    manifest = json.loads((ROOT / 'tooling/native/sources.manifest.json').read_text())
    files = []
    for component in COMPONENTS[platform]:
        entry = manifest['sources'][component]
        path = ROOT / 'native/build/third_party/downloads' / entry['downloadName']
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != entry['sha256']:
            raise ValueError(f'Matching {component} source archive missing or changed: {path}')
        files.append((path, 'upstream/' + path.name))
        source_tree = ROOT / ('native/build/third_party/windows-src' if platform == 'windows' else 'native/build/third_party/src') / entry['topDir']
        if not source_tree.is_dir():
            raise ValueError(f'Actual {component} source tree missing: {source_tree}')
        for source in source_tree.rglob('*'):
            if source.is_file() and not source.is_symlink():
                files.append((source, 'configured-sources/' + entry['topDir'] + '/' + source.relative_to(source_tree).as_posix()))
    # Capture actual configure arguments and build evidence, when generated by builders.
    for base in (ROOT / 'tooling/native', ROOT / 'native/build/third_party' / platform,
                 ROOT / 'native/build/mobile'):
        if not base.exists():
            continue
        for path in base.rglob('*'):
            if path.is_file() and not path.is_symlink() and path.suffix in {'.py', '.sh', '.ps1', '.json', '.txt', '.log', '.mak'} and not any(
                    part in {'target', 'cargo', '__pycache__'} for part in path.relative_to(base).parts):
                files.append((path, 'build/' + path.relative_to(ROOT).as_posix()))
    for path in (ROOT / ('native/build/third_party/windows-build' if platform == 'windows' else 'native/build/third_party/build')).rglob('*'):
        if path.is_file() and path.name in {'config.log', 'config.mak', 'CMakeCache.txt'}:
            files.append((path, 'build/' + path.relative_to(ROOT).as_posix()))
    output.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(output, 'w:xz') as archive:
        for path, name in sorted(files, key=lambda item: item[1]):
            archive.add(path, arcname=name, recursive=False)


def verify_archive(path, platform):
    import zipfile
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        for required in ('Apache-2.0.txt', 'Fideflow-media-core-MIT.txt', 'rust-dependencies.json', 'THIRD_PARTY_NOTICES.md', 'Flutter-LICENSE.txt', 'SourceHanSans-LICENSE.txt'):
            matches = [name for name in names if name.endswith('/licenses/' + required)]
            if not matches or not archive.read(matches[0]).strip():
                raise ValueError(f'{path}: missing or empty license evidence {required}')
        inventory_name = next(name for name in names if name.endswith('/licenses/rust-dependencies.json'))
        prefix = inventory_name.removesuffix('rust-dependencies.json')
        inventory = json.loads(archive.read(inventory_name))
        if not inventory.get('targets'):
            raise ValueError(f'{path}: Rust target inventory empty')
        for record in inventory['targets'].values():
            entries = json.loads(archive.read(prefix + record))
            for entry in entries:
                if not entry['files']:
                    raise ValueError(f'{path}: Rust license evidence empty')
                for filename in entry['files']:
                    location = str(Path(record).parent).replace('\\', '/') + '/rust/' + entry['name'] + '-' + entry['version'] + '/' + filename
                    archive.getinfo(prefix + location)
        notices = next((name for name in names if name.endswith('/flutter_assets/NOTICES.Z')), None)
        if notices is None or not gzip.decompress(archive.read(notices)):
            raise ValueError(f'{path}: Flutter notices missing or empty')
        manifest = json.loads((ROOT / 'tooling/native/sources.manifest.json').read_text())
        for component in COMPONENTS[platform]:
            for filename in manifest['sources'][component]['licenseFiles']:
                matches = [name for name in names if name.endswith('/licenses/' + component + '-' + Path(filename).name)]
                if not matches or not archive.read(matches[0]).strip():
                    raise ValueError(f'{path}: missing or empty {component} license')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', type=Path)
    parser.add_argument('--triple')
    parser.add_argument('--flutter-root', type=Path)
    parser.add_argument('--notices', type=Path)
    parser.add_argument('--fetch-metadata', action='store_true', help='Allow Cargo to fetch locked source metadata before collection')
    parser.add_argument('--sources', type=Path)
    parser.add_argument('--platform', choices=COMPONENTS)
    parser.add_argument('--verify-archive', type=Path)
    args = parser.parse_args()
    if args.target:
        flutter = args.flutter_root or Path(os.environ.get('FLUTTER_ROOT') or Path(shutil.which('flutter')).resolve().parents[1])
        if not args.triple:
            parser.error('--target requires --triple')
        metadata = None
        if args.fetch_metadata:
            metadata = json.loads(subprocess.check_output([
                'cargo', 'metadata', '--locked', '--format-version', '1', '--filter-platform', args.triple,
                '--manifest-path', str(ROOT / 'native/media_core/Cargo.toml')], text=True))
        stage(args.target, args.triple, flutter, args.notices, metadata)
    if args.sources:
        if not args.platform:
            parser.error('--sources requires --platform')
        sources(args.sources, args.platform)
    if args.verify_archive:
        if not args.platform:
            parser.error('--verify-archive requires --platform')
        verify_archive(args.verify_archive, args.platform)


if __name__ == '__main__':
    main()
