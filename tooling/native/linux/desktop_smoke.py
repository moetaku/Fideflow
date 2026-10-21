#!/usr/bin/env python3
"""Run the actual Linux app against a private tray watcher and X server."""
import argparse
import ctypes
import ctypes.util
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[3]
WATCHER = 'org.kde.StatusNotifierWatcher'
WATCHER_PATH = '/StatusNotifierWatcher'
CONTROL = 'org.fideflow.TestStatusNotifierWatcher'


def run(*args, **kwargs):
    result = subprocess.run(args, text=True, capture_output=True, timeout=15, **kwargs)
    if result.returncode != 0:
        raise RuntimeError(f'{args[0]} failed ({result.returncode}): {result.stderr}')
    return result.stdout


def wait_for(predicate, description, seconds=20):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.1)
    raise RuntimeError('Timed out: ' + description)


def dbus(destination, path, method, *args):
    return run('gdbus', 'call', '--session', '--dest', destination,
               '--object-path', path, '--method', method, '--', *args)


MPRIS_PATH = '/org/mpris/MediaPlayer2'
MPRIS_ROOT = 'org.mpris.MediaPlayer2'
MPRIS_PLAYER = MPRIS_ROOT + '.Player'


def mpris_services():
    names = dbus('org.freedesktop.DBus', '/org/freedesktop/DBus',
                 'org.freedesktop.DBus.ListNames')
    return re.findall(r"'(org\.mpris\.MediaPlayer2\.fideflow[^']*)'", names)


def mpris_for_pid(pid):
    for name in mpris_services():
        try:
            owner = dbus('org.freedesktop.DBus', '/org/freedesktop/DBus',
                         'org.freedesktop.DBus.GetConnectionUnixProcessID', name)
            if re.search(r'uint32\s+' + str(pid) + r'\b', owner):
                return name
        except RuntimeError:
            pass  # The owner may disappear during shutdown.
    return None


def verify_mpris(service):
    xml = run('gdbus', 'introspect', '--session', '--dest', service,
              '--object-path', MPRIS_PATH, '--xml')
    player = ET.fromstring(xml).find(f"interface[@name='{MPRIS_PLAYER}']")
    assert player is not None, 'Missing MPRIS player interface'
    for method, types in {'Seek': 'x', 'SetPosition': 'ox', 'PlayPause': ''}.items():
        node = player.find(f"method[@name='{method}']")
        assert node is not None, method
        actual = ''.join(arg.get('type') for arg in node.findall('arg')
                         if arg.get('direction', 'in') == 'in')
        assert actual == types, (method, actual)
    properties = dbus(service, MPRIS_PATH, 'org.freedesktop.DBus.Properties.GetAll',
                      MPRIS_PLAYER)
    assert 'Stopped' in properties, properties
    assert 'CanSeek' in properties and 'Metadata' in properties, properties
    root = dbus(service, MPRIS_PATH, 'org.freedesktop.DBus.Properties.GetAll', MPRIS_ROOT)
    assert 'Fideflow' in root and 'HasTrackList' in root, root
    assert 'true' in dbus(service, MPRIS_PATH, 'org.freedesktop.DBus.Properties.Get',
                          MPRIS_ROOT, 'CanQuit')


def windows():
    output = run('xwininfo', '-root', '-tree')
    return re.findall(r'^\s*(0x[0-9a-fA-F]+) "Fideflow"', output, re.MULTILINE)


def visible(window):
    try:
        return 'Map State: IsViewable' in run('xwininfo', '-id', window)
    except RuntimeError:
        return False


def close_window(window):
    # WM_DELETE_WINDOW, sent only to a window on this fixture's Xvfb display.
    class Data(ctypes.Union):
        _fields_ = [('b', ctypes.c_char * 20), ('s', ctypes.c_short * 10),
                    ('l', ctypes.c_long * 5)]

    class ClientMessage(ctypes.Structure):
        _fields_ = [('type', ctypes.c_int), ('serial', ctypes.c_ulong),
                    ('send_event', ctypes.c_int), ('display', ctypes.c_void_p),
                    ('window', ctypes.c_ulong), ('message_type', ctypes.c_ulong),
                    ('format', ctypes.c_int), ('data', Data)]

    x11 = ctypes.CDLL(ctypes.util.find_library('X11'))
    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x11.XInternAtom.restype = ctypes.c_ulong
    x11.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
    x11.XSendEvent.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int,
                              ctypes.c_long, ctypes.c_void_p]
    x11.XFlush.argtypes = [ctypes.c_void_p]
    x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
    display = x11.XOpenDisplay(None)
    if not display:
        raise RuntimeError('Cannot open private Xvfb display')
    try:
        event = ClientMessage()
        event.type, event.send_event, event.format = 33, 1, 32
        event.display, event.window = display, int(window, 16)
        event.message_type = x11.XInternAtom(display, b'WM_PROTOCOLS', False)
        event.data.l[0] = x11.XInternAtom(display, b'WM_DELETE_WINDOW', False)
        if not x11.XSendEvent(display, event.window, False, 0, ctypes.byref(event)):
            raise RuntimeError('WM_DELETE_WINDOW delivery failed')
        x11.XFlush(display)
    finally:
        x11.XCloseDisplay(display)


def verify_menu(service):
    xml = run('gdbus', 'introspect', '--session', '--dest', service,
              '--object-path', '/MenuBar', '--xml')
    interface = ET.fromstring(xml).find("interface[@name='com.canonical.dbusmenu']")
    expected = {'GetGroupProperties': ('aias', 'a(ia{sv})'),
                'EventGroup': ('a(isvu)', 'ai'),
                'AboutToShowGroup': ('ai', 'aiai')}
    for method, signatures in expected.items():
        node = interface.find(f"method[@name='{method}']")
        actual = tuple(''.join(arg.get('type') for arg in node.findall('arg')
                               if arg.get('direction', 'in') == direction)
                       for direction in ('in', 'out'))
        assert actual == signatures, (method, actual)
    layout = dbus(service, '/MenuBar', 'com.canonical.dbusmenu.GetLayout',
                  '0', '-1', '[]')
    assert 'submenu' in layout and 'Quit' in layout, layout
    dbus(service, '/MenuBar', 'com.canonical.dbusmenu.GetLayout', '1', '0', '[]')
    properties = dbus(service, '/MenuBar', 'com.canonical.dbusmenu.GetGroupProperties',
                      '[0, 1, 2]', '[]')
    assert 'Quit' in properties and 'submenu' in properties, properties
    assert 'true' in dbus(service, '/MenuBar', 'com.canonical.dbusmenu.GetProperty',
                          '0', 'enabled')
    errors = dbus(service, '/MenuBar', 'com.canonical.dbusmenu.EventGroup',
                  "[(99, 'clicked', <0>, 0)]")
    assert '99' in errors, errors
    errors = dbus(service, '/MenuBar', 'com.canonical.dbusmenu.AboutToShowGroup',
                  '[0, 1, 99]')
    assert '99' in errors, errors


def session(test_root, bundle):
    processes = []
    logs = []

    def launch(argv, name, environment=None):
        log = (test_root / (name + '.log')).open('w')
        logs.append(log)
        process = subprocess.Popen(argv, stdout=log, stderr=subprocess.STDOUT,
                                   env=environment)
        processes.append(process)
        return process

    def start_watcher():
        process = launch([str(test_root / 'watcher'), '--watcher-only'],
                         'watcher-' + str(len(processes)))
        run('gdbus', 'wait', '--session', '--timeout=10', WATCHER)
        return process

    def set_host(value):
        dbus(WATCHER, WATCHER_PATH, CONTROL + '.SetHost', str(value).lower())

    def registered_items():
        result = dbus(WATCHER, WATCHER_PATH, 'org.freedesktop.DBus.Properties.Get',
                      WATCHER, 'RegisteredStatusNotifierItems')
        return re.findall(r"'([^']+/StatusNotifierItem)'", result)

    def item_call(address, method, *args):
        service, path = address.split('/', 1)
        return dbus(service, '/' + path, method, *args)

    def app_environment(name):
        environment = os.environ.copy()
        root = test_root / name
        settings = root / 'Fideflow/settings'
        settings.mkdir(parents=True)
        (settings / 'desktop-close.json').write_text(
            '{"version":1,"behavior":"background"}')
        environment['XDG_DATA_HOME'] = str(root)
        return environment

    try:
        no_bus = os.environ.copy()
        no_bus['DBUS_SESSION_BUS_ADDRESS'] = 'unix:path=' + str(test_root / 'missing-bus')
        failed = subprocess.run([str(bundle / 'fideflow')], env=no_bus,
                                capture_output=True, text=True, timeout=10)
        assert failed.returncode != 0 and 'single-instance safety' in failed.stderr, failed.stderr
        watcher = start_watcher()
        environment = app_environment('primary')
        app = launch([str(bundle / 'fideflow')], 'app', environment)
        window = wait_for(lambda: next((w for w in windows() if visible(w)), None),
                          'first application window')
        address = wait_for(lambda: next(iter(registered_items()), None),
                           'StatusNotifierItem registration')
        pixmap = item_call(address, 'org.freedesktop.DBus.Properties.Get',
                           'org.kde.StatusNotifierItem', 'IconPixmap')
        assert re.search(r'32,\s*32', pixmap), 'Missing tray icon fallback'
        verify_menu(address.split('/', 1)[0])
        # The first frame precedes asynchronous prepare/bridge setup on some hosts.
        time.sleep(2)
        media_service = wait_for(lambda: mpris_for_pid(app.pid), 'MPRIS registration')
        verify_mpris(media_service)
        close_window(window)
        wait_for(lambda: not visible(window), 'background close hides window')
        assert app.poll() is None, f'background process exited: {app.poll()}'
        dbus(media_service, MPRIS_PATH, MPRIS_ROOT + '.Raise')
        wait_for(lambda: visible(window), 'MPRIS Raise restores background window')
        close_window(window)
        wait_for(lambda: not visible(window), 'hide after MPRIS Raise')

        duplicate_env = environment.copy()
        duplicate_env['XDG_DATA_HOME'] += '/'
        duplicate = launch([str(bundle / 'fideflow')], 'duplicate', duplicate_env)
        assert duplicate.wait(timeout=10) == 0, 'duplicate launch failed'
        wait_for(lambda: visible(window), 'duplicate launch restores window')
        assert len(windows()) == 1, 'duplicate launch created another window'

        close_window(window)
        wait_for(lambda: not visible(window), 'second background close')
        item_call(address, 'org.kde.StatusNotifierItem.ContextMenu', '0', '0')
        time.sleep(0.2)
        assert not visible(window), 'tray context menu unexpectedly raised the window'
        item_call(address, 'org.kde.StatusNotifierItem.Activate', '0', '0')
        wait_for(lambda: visible(window), 'tray Activate restores window')

        close_window(window)
        wait_for(lambda: not visible(window), 'hide before tray host loss')
        set_host(False)
        wait_for(lambda: visible(window), 'tray host loss restores hidden window')
        set_host(True)
        time.sleep(0.5)
        close_window(window)
        wait_for(lambda: not visible(window), 'hide before watcher disappearance')
        watcher.terminate()
        watcher.wait(timeout=5)
        wait_for(lambda: visible(window), 'watcher disappearance restores hidden window')
        watcher = start_watcher()
        address = wait_for(lambda: next(iter(registered_items()), None),
                           'registration after watcher restart')
        set_host(False)
        close_window(window)
        time.sleep(0.5)
        assert visible(window), 'window hidden despite no tray host'
        # A close prompt remains open here. Tray Quit must still bypass that
        # pending close decision, await cleanup and exit rather than hide.
        set_host(True)

        other = launch([str(bundle / 'fideflow')], 'other', app_environment('other'))
        assert other.wait(timeout=10) == 0, 'different-data-root launch failed'
        assert len(windows()) == 1, 'different data root created another window'
        assert len(registered_items()) == 1, 'duplicate tray registration'
        assert mpris_services() == [media_service], 'duplicate MPRIS registration'
        # Menu IDs are the stable testable Restore(1) / Quit(2) actions.
        service = address.split('/', 1)[0]
        dbus(service, '/MenuBar', 'com.canonical.dbusmenu.Event',
             '2', 'clicked', '<0>', '0')
        assert app.wait(timeout=15) == 0, 'tray quit did not complete application cleanup'
        wait_for(lambda: not windows(), 'window teardown')
        wait_for(lambda: not mpris_services(), 'all MPRIS names released')
        for log in logs:
            log.flush()
        for path in test_root.glob('*.log'):
            output = path.read_text()
            assert not re.search(r'(GLib|Gtk|GObject).*(CRITICAL|ERROR)|double free|Segmentation fault', output), output[-4000:]
        print('Linux desktop single-instance, tray recovery, real MPRIS integration and cleanup checks passed.')
    except Exception:
        for log in logs:
            log.flush()
        for path in test_root.glob('*.log'):
            print('\n' + path.name + ':\n' + path.read_text()[-6000:], file=sys.stderr)
        raise
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
        for log in logs:
            log.close()


def verify_exception_unwinding(bundle, test_root):
    # Match the installed runner's direct dependency order rather than linking
    # a probe against a hand-picked runtime that could conceal interposition.
    dynamic = run('readelf', '-d', str(bundle / 'fideflow'))
    libraries = re.findall(r'\(NEEDED\).*?\[([^\]]+)\]', dynamic)
    assert libraries, 'The installed runner has no dynamic dependencies'
    probe = test_root / 'exception-probe'
    run('g++', '-std=c++14', '-Wall', '-Wextra', '-Werror',
        str(ROOT / 'tooling/native/checks/linux_exception_probe.cc'),
        '-Wl,--no-as-needed', '-L' + str(bundle / 'lib'),
        '-Wl,-rpath,' + str(bundle / 'lib'),
        *('-l:' + library for library in libraries), '-o', str(probe))
    print(run(str(probe)).strip(), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    arch = 'arm64' if platform.machine() in ('aarch64', 'arm64') else 'x64'
    parser.add_argument('--bundle', type=Path, default=ROOT / f'apps/fideflow_flutter/build/linux/{arch}/release/bundle')
    parser.add_argument('--session', type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    bundle = args.bundle.resolve()
    if args.session:
        if (os.environ.get('FF_DESKTOP_TEST_ISOLATED') != str(args.session) or
                not (args.session / 'fixture-owned').is_file()):
            parser.error('Internal session mode requires the isolated fixture')
        session(args.session, bundle)
        return
    for tool in ('g++', 'pkg-config', 'xvfb-run', 'Xvfb', 'xauth', 'gdbus',
                 'dbus-run-session', 'xwininfo', 'readelf'):
        if shutil.which(tool) is None:
            parser.error(f'Missing {tool}; run tooling/bootstrap-linux.sh --with-validation-tools')
    if not (bundle / 'fideflow').is_file():
        parser.error('Build the Linux release bundle first, or pass --bundle')
    with tempfile.TemporaryDirectory(prefix='fideflow-desktop-smoke-') as scratch:
        test_root = Path(scratch)
        (test_root / 'fixture-owned').touch()
        verify_exception_unwinding(bundle, test_root)
        probe = ROOT / 'apps/fideflow_flutter/linux/runner/linux_status_notifier_probe.cc'
        run('g++', '-std=c++14', '-Wall', '-Wextra', '-Werror', str(probe),
            '-o', str(test_root / 'watcher'),
            *shlex.split(run('pkg-config', '--cflags', '--libs', 'gio-2.0')))
        identity_probe = ROOT / 'apps/fideflow_flutter/linux/runner/linux_desktop_probe.cc'
        run('g++', '-std=c++14', '-Wall', '-Wextra', '-Werror', str(identity_probe),
            '-o', str(test_root / 'identity-probe'),
            *shlex.split(run('pkg-config', '--cflags', '--libs', 'gio-2.0')))
        print(run(str(test_root / 'identity-probe')).strip(), flush=True)
        environment = os.environ.copy()
        for variable, directory in (('XDG_RUNTIME_DIR', 'runtime'),
                                    ('XDG_DATA_HOME', 'data'),
                                    ('XDG_CONFIG_HOME', 'config'),
                                    ('XDG_CACHE_HOME', 'cache')):
            path = test_root / directory
            path.mkdir(mode=0o700)
            environment[variable] = str(path)
        environment['FF_DESKTOP_TEST_ISOLATED'] = str(test_root)
        environment['GDK_BACKEND'] = 'x11'
        environment['NO_AT_BRIDGE'] = '1'
        environment['GTK_A11Y'] = 'none'
        config = test_root / 'bus.conf'
        config.write_text(f'''<busconfig><type>session</type>
<listen>unix:tmpdir={test_root}</listen><auth>EXTERNAL</auth>
<policy context="default"><allow send_destination="*"/><allow own="*"/>
<allow receive_sender="*"/></policy></busconfig>''')
        subprocess.run(['xvfb-run', '-a', 'dbus-run-session', '--config-file=' + str(config),
                        '--', sys.executable, str(Path(__file__).resolve()),
                        '--session', str(test_root), '--bundle', str(bundle)],
                       check=True, env=environment, timeout=150)


if __name__ == '__main__':
    main()
