"""Shared Linux release metadata and verified tool downloads."""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parents[3]
ARCHES = {
    'x86_64': {'deb': 'amd64', 'rpm': 'x86_64', 'flutter': 'x64', 'elf': 'Advanced Micro Devices X86-64', 'oci': 'amd64'},
    'aarch64': {'deb': 'arm64', 'rpm': 'aarch64', 'flutter': 'arm64', 'elf': 'AArch64', 'oci': 'arm64'},
}
APP_ID = 'com.moetaku.fideflow'
CACHE = ROOT / 'build/linux-packaging'


def architecture(value=None):
    value = value or platform.machine()
    value = {'amd64': 'x86_64', 'arm64': 'aarch64'}.get(value, value)
    if value not in ARCHES:
        raise ValueError(f'Unsupported architecture: {value}')
    return value


def run(*args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, text=True,
                          capture_output=True, **kwargs).stdout


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def download(record, directory):
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / record['name']
    if path.is_file() and sha256(path) == record['sha256']:
        return path
    errors = []
    for url in record.get('urls', [record.get('url')]):
        try:
            request = urllib.request.Request(url, headers={'User-Agent': 'Fideflow-packager/1', 'Accept': 'application/octet-stream'})
            temporary = path.with_suffix(path.suffix + '.partial')
            with urllib.request.urlopen(request, timeout=90) as source, temporary.open('wb') as target:
                while chunk := source.read(1024 * 1024):
                    target.write(chunk)
            if sha256(temporary) != record['sha256']:
                temporary.unlink()
                raise ValueError(f'Checksum mismatch for {record["name"]}')
            temporary.replace(path)
            return path
        except (OSError, ValueError) as error:
            errors.append(str(error))
    raise RuntimeError('Unable to download verified tool: ' + '; '.join(errors))


def version(value=None):
    if value is None:
        value = re.search(r'^version:\s*(\S+)', (ROOT / 'apps/fideflow_flutter/pubspec.yaml').read_text(), re.M).group(1)
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[A-Za-z0-9.]+)?(?:\+\d+)?', value):
        raise ValueError('Version must be MAJOR.MINOR.PATCH[-prerelease][+build]')
    return value


def elf_metadata(bundle, arch):
    bundle = bundle.resolve()
    wanted = ARCHES[arch]['elf']
    requirements = {'GLIBC': (0,), 'GLIBCXX': (0,)}
    files = []
    for path in [bundle / 'fideflow', *sorted((bundle / 'lib').glob('*'))]:
        if not path.is_file() or path.is_symlink() or path.read_bytes()[:4] != b'\x7fELF':
            continue
        # Keep binutils output parseable on builders configured with a
        # non-English locale.  Debian packaging may run under the user's
        # locale even when the host is otherwise a supported build machine.
        header = run('readelf', '-h', path, env={**os.environ, 'LC_ALL': 'C'})
        match = re.search(r'^\s*Machine:\s*(.+?)\s*$', header, re.M)
        if match is None:
            excerpt = '\n'.join(header.splitlines()[:12])
            raise ValueError(f'{path}: readelf -h did not report an ELF Machine field; output:\n{excerpt}')
        machine = match.group(1).strip()
        if machine != wanted:
            raise ValueError(f'{path.name}: ELF architecture {machine} differs from {arch}')
        versions = run('readelf', '--version-info', path)
        for kind in requirements:
            for value in re.findall(r'\b' + kind + r'_([0-9.]+)', versions):
                requirements[kind] = max(requirements[kind], tuple(map(int, value.split('.'))))
        files.append({'path': str(path.relative_to(bundle)), 'sha256': sha256(path)})
    if not any(x['path'] == 'fideflow' for x in files):
        raise ValueError('Missing ELF application executable')
    return {**{k.lower(): '.'.join(map(str, v)) for k, v in requirements.items()}, 'elfFiles': files}


def check_baseline(actual, maximum):
    if tuple(map(int, actual.split('.'))) > tuple(map(int, maximum.split('.'))):
        raise ValueError(f'Bundle requires glibc {actual}, exceeding selected baseline {maximum}. '
                         'Rebuild on the supported baseline or explicitly select the newer minimum; do not relabel the ELF.')


def epoch():
    value = os.environ.get('SOURCE_DATE_EPOCH')
    if value is None:
        value = run('git', '-C', ROOT, 'log', '-1', '--format=%ct').strip()
    if not value.isdigit():
        raise ValueError('SOURCE_DATE_EPOCH must be a nonnegative integer')
    return int(value)
