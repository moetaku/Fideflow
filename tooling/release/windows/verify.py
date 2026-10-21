"""Release verification and inventory using only the Python standard library."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import tomllib
import zipfile


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def create_archive(bundle, destination):
    # Flutter/native assets can carry reproducible timestamps before 1980.
    # ZIP only supports 1980..2107; clamp metadata without altering file bytes.
    with zipfile.ZipFile(destination, 'x', compression=zipfile.ZIP_DEFLATED,
                         compresslevel=9, strict_timestamps=False) as archive:
        for file in sorted(bundle.rglob('*')):
            if file.is_file():
                archive.write(file, 'Fideflow/' + file.relative_to(bundle).as_posix())


def pe_imports(path, *, include_delay=True):
    data = path.read_bytes()
    assert data[:2] == b'MZ', f'Not PE: {path.name}'
    offset = struct.unpack_from('<I', data, 0x3c)[0]
    assert data[offset:offset + 4] == b'PE\0\0', path.name
    machine, count = struct.unpack_from('<HH', data, offset + 4)
    assert machine == 0x8664, f'Not Windows x64: {path.name}'
    optional_size = struct.unpack_from('<H', data, offset + 20)[0]
    optional = offset + 24
    assert struct.unpack_from('<H', data, optional)[0] == 0x20b, path.name
    sections = []
    for index in range(count):
        section = optional + optional_size + index * 40
        virtual_size, address, raw_size, raw = struct.unpack_from('<IIII', data, section + 8)
        sections.append((address, max(virtual_size, raw_size), raw))

    def file_offset(rva):
        for address, size, raw in sections:
            if address <= rva < address + size:
                return raw + rva - address
        raise ValueError(f'Invalid PE RVA: {path.name}')

    def name(rva):
        start = file_offset(rva)
        return data[start:data.index(b'\0', start)].decode('ascii').lower()

    imports = set()
    # Keep delay imports distinguishable: a few are optional feature runtimes.
    for index, descriptor_size, name_offset in [(1, 20, 12), (13, 32, 4)]:
        if index == 13 and not include_delay:
            continue
        rva, size = struct.unpack_from('<II', data, optional + 112 + index * 8)
        if not rva or not size:
            continue
        cursor = file_offset(rva)
        while any(data[cursor:cursor + descriptor_size]):
            imports.add(name(struct.unpack_from('<I', data, cursor + name_offset)[0]))
            cursor += descriptor_size
    return sorted(imports)


def verify(bundle):
    required = ['fideflow.exe', 'ff_media_core.dll', 'flutter_windows.dll',
                'sqlite3.dll', 'soxr.dll', 'vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll',
                'data/app.so', 'data/icudtl.dat', 'data/flutter_assets/NOTICES.Z',
                'licenses/ffmpeg-COPYING.LGPLv2.1', 'licenses/libsoxr-LICENCE',
                'licenses/portaudio-LICENSE.txt', 'licenses/sqlite.txt',
                'licenses/ncm-api-rs-LICENSE', 'licenses/ncm-host-UPSTREAM.json',
                'licenses/ncm-host-PATCH.md', 'sources.manifest.json']
    for filename in required:
        assert (bundle / filename).is_file(), f'Missing release file: {filename}'
    for prefix in ['avcodec', 'avformat', 'avutil', 'swresample', 'swscale']:
        assert len(list(bundle.glob(f'{prefix}-*.dll'))) == 1, prefix
    system = Path(os.environ['SystemRoot']) / 'System32'
    local = {file.name.lower() for file in bundle.iterdir() if file.is_file()}
    binary_records = []
    for file in sorted(bundle.rglob('*')):
        if not file.is_file():
            continue
        relative = file.relative_to(bundle).as_posix()
        assert not file.is_symlink(), relative
        assert file.suffix.lower() not in {'.pdb', '.log', '.sqlite', '.db', '.pfx', '.pem'}, relative
        assert not any(part.lower() in {'credentials', 'cache', 'target', 'test', 'tests', 'fixtures'} for part in file.relative_to(bundle).parts), relative
        assert not file.name.startswith('.env'), relative
        assert 'probe' not in file.name.lower(), relative
        if file.suffix.lower() in {'.exe', '.dll'}:
            imports = pe_imports(file)
            # JNI is a transitive Flutter dependency. This app never starts a
            # desktop JVM; dartjni delay-loads it only when Jni.spawn is called.
            # Allow only this exact delay import, never a normal JVM import or
            # missing dependencies of other plugins.
            optional_imports = []
            if relative.lower() == 'dartjni.dll' and 'jvm.dll' in imports:
                if 'jvm.dll' not in pe_imports(file, include_delay=False):
                    optional_imports.append('jvm.dll')
            for dependency in imports:
                assert not any(word in dependency for word in ('libssl', 'libcrypto')), dependency
                assert dependency in optional_imports or dependency in local or dependency.startswith(('api-ms-', 'ext-ms-')) or (system / dependency).is_file(), f'{relative}: unresolved {dependency}'
                if dependency.startswith(('msvcp', 'vcruntime', 'concrt')):
                    assert dependency in local, f'Unbundled MSVC runtime: {dependency}'
            record = {'path': relative, 'imports': imports}
            if optional_imports:
                record['optionalImports'] = optional_imports
            binary_records.append(record)
    assert not (bundle / 'ssl').exists(), 'Obsolete native CA directory'
    return binary_records


def inventory(repo, bundle, version, signing):
    binaries = verify(bundle)
    manifest = json.loads((bundle / 'sources.manifest.json').read_text(encoding='utf-8-sig'))
    components = []
    for name in ['ffmpeg', 'libsoxr', 'portaudio']:
        entry = manifest['sources'][name]
        components.append({'type': 'library', 'name': name, 'version': entry['version'],
                           'hashes': [{'alg': 'SHA-256', 'content': entry['sha256']}],
                           'licenses': [{'license': {'name': entry['license']}}]})
    sqlite = manifest['platforms']['windows']['sqlite']
    components.append({'type': 'library', 'name': 'sqlite', 'version': sqlite['version'],
                       'hashes': [{'alg': 'SHA-256', 'content': sqlite['sha256']}],
                       'licenses': [{'license': {'name': 'public-domain'}}]})
    # Lock inventories deliberately include build/dev dependencies. They are
    # provenance, not a claim that every listed package is linked into the app.
    for path in [repo / 'native/media_core/Cargo.lock']:
        for package in tomllib.loads(path.read_text())['package']:
            component = {'type': 'library', 'name': package['name'], 'version': package['version']}
            if package.get('checksum'):
                component['hashes'] = [{'alg': 'SHA-256', 'content': package['checksum']}]
            component['properties'] = [{'name': 'ff:lockfile', 'value': path.relative_to(repo).as_posix() if path.is_relative_to(repo) else path.name}]
            components.append(component)
    lock = (repo / 'pubspec.lock').read_text()
    for match in re.finditer(r'^  ([\w]+):\n(.*?)(?=^  [\w]+:|^sdks:|\Z)', lock, re.M | re.S):
        package_version = re.search(r'^    version: "([^"]+)"', match[2], re.M)
        if package_version:
            components.append({'type': 'library', 'name': match[1], 'version': package_version[1],
                               'properties': [{'name': 'ff:lockfile', 'value': 'pubspec.lock'}]})
    unique = {json.dumps(component, sort_keys=True): component for component in components}
    sbom = {'bomFormat': 'CycloneDX', 'specVersion': '1.5', 'version': 1,
            'metadata': {'component': {'type': 'application', 'name': 'Fideflow', 'version': version}},
            'components': list(unique.values())}
    files = [{'path': file.relative_to(bundle).as_posix(), 'bytes': file.stat().st_size, 'sha256': digest(file)}
             for file in sorted(bundle.rglob('*')) if file.is_file()]
    return sbom, {'version': version, 'platform': 'windows-x64', 'signing': signing,
                  'minimumWindows': '10.0.19041', 'files': files, 'binaries': binaries,
                  'dependencyInventoryScope': 'Pinned native sources and complete Rust/Dart lockfiles including build/dev dependencies'}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('bundle', type=Path)
    parser.add_argument('--repo', type=Path)
    parser.add_argument('--version')
    parser.add_argument('--signing', default='unsigned')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--create-archive', type=Path)
    parser.add_argument('--manifest', type=Path)
    args = parser.parse_args()
    if args.create_archive:
        create_archive(args.bundle, args.create_archive)
        print('Created portable ZIP with ZIP-compatible timestamps')
        return
    if args.archive:
        record = json.loads(args.manifest.read_text(encoding='utf-8-sig'))
        expected = {'Fideflow/' + entry['path']: entry for entry in record['files']}
        with zipfile.ZipFile(args.archive) as archive:
            actual = [entry.filename for entry in archive.infolist() if not entry.is_dir()]
            assert len(actual) == len(set(actual)), 'Duplicate ZIP paths'
            assert set(actual) == set(expected), 'ZIP inventory mismatch'
            for name, entry in expected.items():
                assert hashlib.sha256(archive.read(name)).hexdigest() == entry['sha256'], name
        print('Verified portable ZIP inventory and all file hashes')
        return
    if args.output:
        sbom, record = inventory(args.repo, args.bundle, args.version, args.signing)
        args.output.mkdir(parents=True, exist_ok=True)
        (args.output / 'SBOM.cdx.json').write_text(json.dumps(sbom, ensure_ascii=False, indent=2), encoding='utf-8')
        (args.output / 'release-manifest.json').write_text(json.dumps(record, ensure_ascii=False, indent=2), encoding='utf-8')
        print(f"Verified {len(record['binaries'])} x64 PE files, {len(record['files'])} release files")
    else:
        print(f'Verified {len(verify(args.bundle))} x64 PE files')


if __name__ == '__main__':
    main()
