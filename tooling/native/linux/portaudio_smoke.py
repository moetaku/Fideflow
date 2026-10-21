#!/usr/bin/env python3
"""Exercise real PortAudio/ALSA callbacks without touching a desktop audio server."""
import array
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
ROOT = Path(__file__).resolve().parents[3]


def configure(directory, include_shared=True, fallback=False):
    shared = 'pcm.ff_shared { type null hint { show on description "Fideflow shared fixture" ioid "Output" } }' if include_shared else ''
    default = 'type plug slave.pcm "FideflowMissingPCM"' if fallback else 'type null'
    server = 'pcm.!pipewire { type null }' if fallback else ''
    content = f'''</usr/share/alsa/alsa.conf>
pcm.!default {{ {default} hint {{ show on description "Fideflow default fixture" ioid "Output" }} }}
{shared}
{server}
pcm.ff_processor {{ type plug slave.pcm "null" hint {{ show on description "Not a speaker" ioid "Output" }} }}
pcm.ff_capture {{ type file slave.pcm "null" file "{directory}/capture.raw" format "raw" hint {{ show on description "Fideflow capture fixture" ioid "Output" }} }}
'''
    config = directory / 'alsa.conf'
    config.write_text(content)
    # ALSA caches its configuration. A distinct mtime also works with versions
    # that only compare seconds, even when both changes occur in the same second.
    stamp = directory / 'revision'
    revision = max(int(time.time()), int(stamp.read_text()) + 1 if stamp.exists() else 0)
    stamp.write_text(str(revision))
    os.utime(config, (revision, revision))


def main():
    if len(sys.argv) == 2 and sys.argv[1] in ('remove', 'restore', 'fallback'):
        directory = Path(os.environ['FF_PORTAUDIO_SMOKE_DIR'])
        assert (directory / '.owned').is_file(), 'not an owned audio fixture'
        configure(directory, sys.argv[1] != 'remove', sys.argv[1] == 'fallback')
        return
    if len(sys.argv) != 1:
        raise SystemExit('Usage: tooling/native/linux/portaudio_smoke.sh')
    with tempfile.TemporaryDirectory(prefix='fideflow-portaudio-') as scratch:
        directory = Path(scratch)
        (directory / '.owned').touch()
        configure(directory)
        environment = os.environ.copy()
        environment.update(ALSA_CONFIG_PATH=str(directory / 'alsa.conf'),
                           FF_PORTAUDIO_SMOKE_DIR=str(directory), FF_RUN_PORTAUDIO_SMOKE='1',
                           PULSE_SERVER=f'unix:{directory}/no-desktop-server',
                           FF_PORTAUDIO_SMOKE_CONTROL=str(ROOT / 'tooling/native/linux/portaudio_smoke.sh'),
                           FF_NATIVE_PREFIX=str(ROOT / 'native/build/third_party/linux' / ('aarch64' if os.uname().machine in ('aarch64', 'arm64') else 'x86_64')))
        cargo = shutil.which('cargo') or str(Path(os.environ.get('CARGO_HOME', str(Path.home() / '.cargo'))) / 'bin/cargo')
        subprocess.run([cargo, 'test', '--locked', '--manifest-path', str(ROOT / 'native/media_core/Cargo.toml'),
                        '-p', 'fideflow-media-output', '--lib'], check=True, env=environment, timeout=240)
        subprocess.run([cargo, 'test', '--locked', '--manifest-path', str(ROOT / 'native/media_core/Cargo.toml'),
                        '-p', 'fideflow-media-output', '--test', 'linux_portaudio', '--', '--ignored', '--test-threads=1'],
                       check=True, env=environment, timeout=240)
        raw = (directory / 'capture.raw').read_bytes()
        samples = array.array('f')
        samples.frombytes(raw[:len(raw) - len(raw) % 4])
        if sys.byteorder != 'little': samples.byteswap()
        assert samples and all(math.isfinite(value) for value in samples), 'non-finite PortAudio output'
        assert any(abs(value - .125) < 1e-5 for value in samples), 'PortAudio PCM did not reach the ALSA file sink'
        print('PortAudio/ALSA enumeration, callback waveform, pause/resume and route recovery passed.')


if __name__ == '__main__':
    main()
