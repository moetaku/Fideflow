"""Stage auditable source/license evidence for Linux release artifacts."""
from __future__ import annotations
import gzip
import json
from pathlib import Path
import shutil
import subprocess
import tarfile

from common import ROOT, epoch, run, sha256

APPLICATION_NOTICE = '''Fideflow application source and artwork

Licensed under the Apache License, Version 2.0.
A copy of the license is included as Apache-2.0.txt.
Third-party components retain the separate licenses included in this directory.
The corresponding-source archive accompanies this build for license compliance;
its presence does not change the license of any component.
'''


def stage(bundle, target, arch, flutter_root, cargo_metadata=None):
    target.mkdir(parents=True, exist_ok=True)
    original = bundle / 'data/licenses'
    if not original.is_dir():
        raise ValueError('Native license evidence is missing; rebuild the Release bundle')
    shutil.copytree(original, target, dirs_exist_ok=True)
    (target / 'Fideflow-COPYRIGHT.txt').write_text(APPLICATION_NOTICE)
    shutil.copy2(ROOT / 'LICENSE', target / 'Apache-2.0.txt')
    notices = bundle / 'data/flutter_assets/NOTICES.Z'
    if not notices.is_file():
        raise ValueError('Flutter NOTICES.Z missing')
    with gzip.open(notices, 'rb') as source:
        (target / 'Dart-Flutter-NOTICES.txt').write_bytes(source.read())
    sdk_license = flutter_root / 'LICENSE'
    if not sdk_license.is_file():
        raise ValueError('Pass --flutter-root with the SDK used to build this bundle')
    shutil.copy2(sdk_license, target / 'Flutter-LICENSE.txt')
    for path in (flutter_root / 'bin/cache').glob('LICENSE.*_archive.md'):
        shutil.copy2(path, target / path.name)
    for path in (flutter_root / 'bin/cache/artifacts/engine').glob('linux-*/LICENSE*'):
        if path.is_file():
            shutil.copy2(path, target / ('Flutter-engine-' + path.parent.name + '-' + path.name))
    font = ROOT / 'apps/fideflow_flutter/assets/fonts/SourceHanSans-LICENSE.txt'
    shutil.copy2(font, target / font.name)
    import importlib.util
    spec = importlib.util.spec_from_file_location('release_licenses', ROOT / 'tooling/release/licenses.py')
    collector = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(collector)
    metadata = json.loads(cargo_metadata.read_text()) if cargo_metadata else None
    return collector.stage(target, arch + '-unknown-linux-gnu', flutter_root, notices, metadata)


def sources(output, name, timestamp):
    manifest = json.loads((ROOT / 'tooling/native/sources.manifest.json').read_text())
    archives = []
    for component in ['ffmpeg', 'libsoxr', 'portaudio']:
        record = manifest['sources'][component]
        path = ROOT / 'native/build/third_party/downloads' / record['downloadName']
        if not path.is_file() or sha256(path) != record['sha256']:
            raise ValueError(f'Matching {component} source archive missing or changed: {path}')
        archives.append(path)
    tracked = subprocess.check_output(['git', '-C', str(ROOT), 'ls-files', '-z', '--cached', '--others', '--exclude-standard']).split(b'\0')
    files = sorted({ROOT / x.decode() for x in tracked if x})
    output.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(output, 'w:xz', preset=6) as archive:
        for path, destination in [(p, name + '/project/' + str(p.relative_to(ROOT))) for p in files] + [(p, name + '/upstream/' + p.name) for p in archives]:
            if not path.is_file() or path.is_symlink():
                continue
            info = archive.gettarinfo(str(path), destination)
            info.uid = info.gid = 0
            info.uname = info.gname = 'root'
            info.mtime = timestamp
            with path.open('rb') as data:
                archive.addfile(info, data)
    return {'file': output.name, 'sha256': sha256(output), 'upstream': [
        {'file': p.name, 'sha256': sha256(p)} for p in archives]}
