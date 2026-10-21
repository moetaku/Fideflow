#!/usr/bin/env python3
"""Exercise active and disabled Linux MPRIS state with the test Dart target.

Run under a private display and session bus, for example:
  xvfb-run -a dbus-run-session -- python3 tooling/native/linux/media_controls_smoke.py \
    --binary apps/fideflow_flutter/build/linux/x64/debug/bundle/fideflow
The binary must be built with --target tooling/linux_media_controls_harness.dart.
"""
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
from urllib.parse import unquote, urlparse

ROOT = Path(__file__).resolve().parents[3]
PATH = '/org/mpris/MediaPlayer2'
ROOT_IFACE = 'org.mpris.MediaPlayer2'
PLAYER = ROOT_IFACE + '.Player'
DBUS = 'org.freedesktop.DBus'


def run(*args, env=None, check=True):
    result = subprocess.run(args, text=True, capture_output=True, env=env, timeout=15)
    if check and result.returncode:
        raise RuntimeError(f'{args[0]} failed ({result.returncode}): {result.stderr}')
    return result


def call(service, interface, method, *args, check=True):
    return run('gdbus', 'call', '--session', '--dest', service,
               '--object-path', PATH, '--method', interface + '.' + method,
               '--', *args, check=check)


def get(service, interface, name):
    return call(service, 'org.freedesktop.DBus.Properties', 'Get', interface,
                name).stdout


def wait_for(predicate, message, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.1)
    raise RuntimeError('Timed out: ' + message)


def service_for_pid(pid):
    names = run('gdbus', 'call', '--session', '--dest', DBUS,
                '--object-path', '/org/freedesktop/DBus', '--method',
                DBUS + '.ListNames').stdout
    services = re.findall(r"'(org\.mpris\.MediaPlayer2\.fideflow[^']*)'", names)
    for name in services:
        owner = run('gdbus', 'call', '--session', '--dest', DBUS,
                    '--object-path', '/org/freedesktop/DBus', '--method',
                    DBUS + '.GetConnectionUnixProcessID', name, check=False).stdout
        if re.search(r'uint32\s+' + str(pid) + r'\b', owner):
            return name
    return None


def ready_service(pid, marker, artwork=False):
    name = service_for_pid(pid)
    if name is None:
        return None
    try:
        data = metadata(name)
        if marker not in data or (artwork and 'mpris:artUrl' not in data):
            return None
        if 'true' not in get(name, ROOT_IFACE, 'CanQuit'):
            return None
        return name
    except RuntimeError:
        return None


def property_number(service, name):
    value = get(service, PLAYER, name)
    match = re.search(r'(?:int64|double)\s+(-?[0-9]+(?:\.[0-9]+)?)', value)
    if not match:
        match = re.search(r'<(-?[0-9]+(?:\.[0-9]+)?)>', value)
    if not match:
        raise RuntimeError(f'Could not parse {name}: {value}')
    return float(match.group(1))


def wait_property(service, name, expected, tolerance=0.05):
    return wait_for(lambda: abs(property_number(service, name) - expected) <= tolerance,
                    f'{name}={expected}')


def metadata(service):
    return get(service, PLAYER, 'Metadata')


def assert_active(service):
    data = metadata(service)
    assert 'Harness: punctuation / title' in data, data
    assert 'Fideflow Fixture' in data and 'MPRIS Test Suite' in data, data
    assert 'uint64 240750000' in data or 'int64 240750000' in data, data
    track = re.search(r"objectpath '([^']+)'", data)
    assert track and track.group(1).startswith('/com/moetaku/fideflow/track/t'), data
    art = re.search(r"mpris:artUrl': <'([^']+)'", data)
    assert art, data
    art_path = Path(unquote(urlparse(art.group(1)).path))
    assert art_path.is_file() and art_path.stat().st_size > 40, art_path
    assert "<'Playing'>" in get(service, PLAYER, 'PlaybackStatus')
    assert abs(property_number(service, 'Position') - 12_500_000) < 1000
    assert abs(property_number(service, 'Volume') - 0.4) < 0.001
    assert "<'None'>" in get(service, PLAYER, 'LoopStatus')
    return track.group(1), art_path


def verify_active(service):
    track_id, artwork = assert_active(service)
    call(service, PLAYER, 'PlayPause')
    wait_for(lambda: "<'Paused'>" in get(service, PLAYER, 'PlaybackStatus'), 'paused state')
    call(service, PLAYER, 'PlayPause')
    wait_for(lambda: "<'Playing'>" in get(service, PLAYER, 'PlaybackStatus'), 'playing state')

    call(service, PLAYER, 'Seek', '5000000')
    wait_property(service, 'Position', 17_500_000, tolerance=5000)
    call(service, PLAYER, 'Seek', '100000')
    wait_property(service, 'Position', 17_600_000, tolerance=5000)
    call(service, PLAYER, 'SetPosition', track_id, '33000000')
    wait_property(service, 'Position', 33_000_000, tolerance=5000)
    call(service, PLAYER, 'SetPosition', '/com/moetaku/fideflow/track/stale', '44000000')
    assert abs(property_number(service, 'Position') - 33_000_000) < 5000
    call(service, PLAYER, 'SetPosition', track_id, '240750000')
    assert abs(property_number(service, 'Position') - 33_000_000) < 5000

    set_property(service, 'Volume', '<0.75>')
    wait_property(service, 'Volume', 0.75, tolerance=0.001)
    set_property(service, 'Volume', '<-0.25>')
    wait_property(service, 'Volume', 0.0, tolerance=0.001)
    bad_volume = set_property(service, 'Volume', '<double nan>', check=False)
    assert bad_volume.returncode != 0, bad_volume.stdout + bad_volume.stderr
    set_property(service, 'Shuffle', '<true>')
    wait_for(lambda: 'true' in get(service, PLAYER, 'Shuffle'), 'Shuffle true')
    set_property(service, 'LoopStatus', "<'Track'>")
    wait_for(lambda: "<'Track'>" in get(service, PLAYER, 'LoopStatus'), 'LoopStatus Track')
    bad_loop = set_property(service, 'LoopStatus', "<'Invalid'>", check=False)
    assert bad_loop.returncode != 0, bad_loop.stdout + bad_loop.stderr

    set_property(service, 'Rate', '<0.0>')
    wait_for(lambda: "<'Paused'>" in get(service, PLAYER, 'PlaybackStatus'), 'Rate zero pauses')
    set_property(service, 'Rate', '<1.0>')
    call(service, PLAYER, 'Stop')
    wait_for(lambda: "<'Stopped'>" in get(service, PLAYER, 'PlaybackStatus'), 'Stop state')
    call(service, ROOT_IFACE, 'Quit')
    return artwork


def set_property(service, name, value, check=True):
    return run('gdbus', 'call', '--session', '--dest', service,
               '--object-path', PATH, '--method',
               'org.freedesktop.DBus.Properties.Set', PLAYER, name, value,
               check=check)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--session', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args()
    binary = args.binary.resolve()
    if not binary.is_file():
        parser.error(f'Binary does not exist: {binary}')
    if not args.session:
        with tempfile.TemporaryDirectory(prefix='ff-mpris-session-') as temp:
            environment = os.environ.copy()
            for key, directory in [('XDG_DATA_HOME', 'data'), ('XDG_CACHE_HOME', 'cache'),
                                   ('XDG_CONFIG_HOME', 'config'), ('XDG_RUNTIME_DIR', 'runtime')]:
                path = Path(temp) / directory
                path.mkdir(mode=0o700)
                environment[key] = str(path)
            environment['GSETTINGS_BACKEND'] = 'memory'
            environment['GTK_USE_PORTAL'] = '0'
            environment['NO_AT_BRIDGE'] = '1'
            bus_config = Path(temp) / 'session.conf'
            bus_config.write_text('<busconfig><type>session</type><listen>unix:tmpdir=/tmp</listen>'
                                  '<policy context="default"><allow send_destination="*"/>'
                                  '<allow receive_sender="*"/><allow own="*"/></policy></busconfig>')
            subprocess.run(['dbus-run-session', '--config-file=' + str(bus_config), '--', 'xvfb-run', '-a', sys.executable,
                            str(Path(__file__).resolve()), '--binary', str(binary), '--session'],
                           check=True, env=environment)
        return
    with tempfile.TemporaryDirectory(prefix='fideflow-mpris-smoke-') as temp:
        base_env = os.environ.copy()
        active_env = base_env.copy()
        active_env['XDG_DATA_HOME'] = str(Path(temp) / 'active')
        active = subprocess.Popen([str(binary)], env=active_env,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                  text=True)
        disabled = None
        try:
            active_service = wait_for(
                lambda: ready_service(active.pid, 'Harness: punctuation / title', artwork=True),
                'active MPRIS metadata and artwork')
            artwork = verify_active(active_service)
            assert active.wait(timeout=15) == 0, 'MPRIS Quit did not exit active fixture'
            wait_for(lambda: not artwork.exists(), 'artwork cleanup on dispose')

            disabled_env = base_env.copy()
            disabled_env['XDG_DATA_HOME'] = str(Path(temp) / 'disabled')
            disabled_env['FIDEFLOW_TEST_MEDIA_DISABLED'] = '1'
            disabled = subprocess.Popen([str(binary)], env=disabled_env,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                        text=True)
            disabled_service = wait_for(
                lambda: ready_service(disabled.pid, 'NoTrack'),
                'disabled MPRIS metadata')
            assert 'NoTrack' in metadata(disabled_service)
            assert 'false' in get(disabled_service, PLAYER, 'CanSeek')
            rejected = call(disabled_service, PLAYER, 'PlayPause', check=False)
            assert rejected.returncode != 0, 'disabled player accepted PlayPause'
            call(disabled_service, ROOT_IFACE, 'Quit')
            assert disabled.wait(timeout=15) == 0, 'MPRIS Quit did not exit disabled fixture'
        finally:
            for child in (disabled, active):
                if child and child.poll() is None:
                    child.terminate()
                    try:
                        child.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        child.kill()
                        child.wait(timeout=5)
                if child and child.stderr:
                    diagnostics = child.stderr.read()
                    if sys.exc_info()[0] is not None:
                        print(diagnostics[-12000:], file=sys.stderr)
                    child.stderr.close()
    print('Active MPRIS metadata, actions, setters, disabled state, and artwork cleanup passed.')


if __name__ == '__main__':
    main()
