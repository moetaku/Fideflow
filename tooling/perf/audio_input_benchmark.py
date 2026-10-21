#!/usr/bin/env python3
"""Pair ABI-2 HTTP and ABI-3 AVIO using matching libraries and the same fixtures.

Build the old revision's native library before modifying it; save the dylib.
Example:
  python3 tooling/perf/audio_input_benchmark.py --baseline-revision <old-commit> \
    --baseline-library /tmp/libff_media_core-before.dylib \
    --native-library native/media_core/target/debug/libff_media_core.dylib \
    --output /tmp/ffinput-paired

This exports only the old host transport and FFI loader into a temporary folder.
The current controller, WAV fixture, network delays and CPU sampler are shared.
Each run includes 10 queue starts and 30 seeks per paused/playing state per mode.
CPU is process getrusage (Dart plus native threads), not isolated transport CPU.
"""
import argparse
import json
import math
import os
from pathlib import Path
import re
import statistics
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / 'apps/fideflow_flutter'

def export(revision, path):
    return subprocess.check_output(['git', 'show', f'{revision}:{path}'], cwd=ROOT, text=True)

def baseline_test(directory, revision):
    for name in ('playback_cache.dart', 'audio_range_cache.dart'):
        (directory / name).write_text(export(revision, f'apps/fideflow_flutter/lib/app/{name}'))
    ffi = export(revision, 'packages/media_host/lib/src/media_core_ffi.dart')
    for name in ('media_core_api.dart', 'library_locator.dart'):
        ffi = ffi.replace(f"import '{name}';", f"import 'package:fideflow_media_host/src/{name}';")
    (directory / 'media_core_ffi.dart').write_text(ffi)
    test = (APP / 'test/audio_range_cache_test.dart').read_text()
    test = test.replace("import 'package:fideflow/app/playback_cache.dart';", "import 'playback_cache.dart';\nimport 'media_core_ffi.dart' as baseline;")
    test = test.replace("import 'audio_input_test_bridge.dart';", '')
    for name in ('playback_cache_test.dart', 'process_cpu.dart'):
        test = test.replace(f"import '{name}'", f"import '{APP / 'test' / name}'")
    a = test.index('    uri = ', test.index('Future<void> openAudio()'))
    b = test.index('\n  }', a)
    test = test[:a] + "    uri = (await audio.resolve(const TrackId('song'), AudioQuality.high, NetworkPolicy.preferCache)).uri.replace(scheme: 'http');" + test[b:]
    # Direct-byte API tests have no ABI-2 counterpart; benchmark names select
    # only the shared playback benchmark cases.
    a = re.search(r"^  test\(\s*'direct input", test, re.M).start()
    b = test.index("  test('repeated precaching", a)
    test = test[:a] + test[b:]
    test = re.sub(r'await testInputUri\(audio, (\w+\.uri)\)', r"\1.replace(scheme: 'http')", test)
    test = test.replace('FfiMediaCoreApi.open(', 'baseline.FfiMediaCoreApi.open(')
    test = test.replace('api.inputReadRequests', '0').replace('api.inputBytesWritten', '0')
    result = directory / 'baseline_seek_test.dart'
    result.write_text(test)
    return result

def percentile(values, p):
    values = sorted(values)
    return values[max(0, math.ceil(len(values)*p)-1)]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-revision')
    parser.add_argument('--baseline-kind', choices=('http', 'avio'), default='http')
    parser.add_argument('--fixture', type=Path)
    parser.add_argument('--baseline-library', type=Path, required=True)
    parser.add_argument('--native-library', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--runs', type=int, default=3)
    parser.add_argument('--modes', default='full,network')
    args = parser.parse_args()
    if args.baseline_kind == 'http' and not args.baseline_revision:
        parser.error('--baseline-revision is required for an HTTP baseline')
    args.output.mkdir(parents=True, exist_ok=True)
    samples = {}
    observations = []
    with tempfile.TemporaryDirectory(prefix='ffinput-paired-') as tmp:
        before = (baseline_test(Path(tmp), args.baseline_revision)
                  if args.baseline_kind == 'http' else APP / 'test/audio_range_cache_test.dart')
        for run in range(args.runs):
            for variant, library, test in (
                ('before', args.baseline_library, before),
                ('after', args.native_library, APP / 'test/audio_range_cache_test.dart'),
            ):
                env = {**os.environ, 'FF_SEEK_BENCHMARK':'1', 'FF_SEEK_MODES':args.modes,
                       'FF_MEDIA_CORE_LIBRARY':str(library.resolve())}
                if args.fixture:
                    env['FF_SEEK_FIXTURE'] = str(args.fixture.resolve())
                log = args.output / f'{variant}-{run+1}.log'
                print(f'{variant} run {run+1}/{args.runs}', flush=True)
                with log.open('w') as output:
                    subprocess.run(['flutter', 'test', str(test), '--plain-name', 'seek benchmark', '--reporter', 'expanded'], cwd=APP, env=env, stdout=output, stderr=subprocess.STDOUT, check=True)
                for line in log.read_text().splitlines():
                    if 'SEEK_BENCH ' in line or 'SUSTAIN_BENCH ' in line:
                        observations.append({'variant':variant, 'run':run+1, 'measurement':line})
                    match = re.search(r'(SEEK_SAMPLES|STARTUP_SAMPLES) (\{.*\})', line)
                    if not match:
                        continue
                    kind, data = match.groups()
                    data = json.loads(data)
                    key = f"{variant}:{data['mode']}:{data.get('paused', 'startup')}"
                    result = samples.setdefault(key, {'latencyMicros':[], 'cpuMicros':[]})
                    result['latencyMicros'].extend(data['latencyMicros'])
                    result['cpuMicros'].extend(data.get('cpuMicros', []))
    summary = {}
    for key, data in samples.items():
        summary[key] = {name:{'n':len(values),'median':statistics.median(values),'p95':percentile(values,.95)} for name, values in data.items() if values}
    report = {'baselineRevision':args.baseline_revision, 'baselineKind':args.baseline_kind,
              'fixture':str(args.fixture) if args.fixture else None,
              'runs':args.runs,'modes':args.modes,'summary':summary,'samples':samples,
              'transportObservations':observations}
    (args.output / 'results.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(summary, indent=2))

if __name__ == '__main__':
    main()
