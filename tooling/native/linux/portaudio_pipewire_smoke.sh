#!/usr/bin/env bash
# Optional real-time validation using only a private PipeWire graph and null sink.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
if [ "${1:-}" = --session ]; then
  fixture=$2
  export XDG_RUNTIME_DIR="$fixture/runtime" PIPEWIRE_RUNTIME_DIR="$fixture/runtime"
  export XDG_CONFIG_HOME="$fixture/config" XDG_DATA_HOME="$fixture/data" XDG_CACHE_HOME="$fixture/cache"
  export PULSE_SERVER="unix:$fixture/runtime/pulse/native"
  export PIPEWIRE_REMOTE=pipewire-0
  mkdir -m 700 "$XDG_RUNTIME_DIR" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME"
  children=()
  cleanup() {
    for child in "${children[@]}"; do kill "$child" 2>/dev/null || true; done
    for child in "${children[@]}"; do wait "$child" 2>/dev/null || true; done
  }
  trap cleanup EXIT
  pipewire > "$fixture/pipewire.log" 2>&1 & children+=("$!")
  for ((i=0;i<100;i++)); do [ -S "$XDG_RUNTIME_DIR/pipewire-0" ] && break; sleep .1; done
  # The policy profile links software nodes without loading hardware monitors.
  wireplumber -p policy > "$fixture/policy.log" 2>&1 & children+=("$!")
  pipewire-pulse > "$fixture/compat.log" 2>&1 & children+=("$!")
  ready=0
  for ((i=0;i<100;i++)); do if pactl info >/dev/null 2>&1; then ready=1; break; fi; sleep .1; done
  if [ "$ready" != 1 ]; then cat "$fixture/compat.log"; exit 1; fi
  # Native software sinks work even when pulse module loading is disabled.
  for sink in ff_portaudio ff_portaudio_second; do
    pw-cli create-node adapter "{ factory.name=support.null-audio-sink node.name=$sink media.class=Audio/Sink object.linger=true audio.position=[ FL FR ] }" >/dev/null
  done
  for ((i=0;i<100;i++)); do
    if pactl list short sinks | grep -q ff_portaudio_second; then break; fi
    sleep .1
  done
  pactl set-default-sink ff_portaudio
  cat > "$fixture/alsa.conf" <<EOF
</usr/share/alsa/alsa.conf>
pcm.!default { type pulse server "$PULSE_SERVER" hint { show on description "Private PortAudio desktop route" ioid "Output" } }
EOF
  export ALSA_CONFIG_PATH="$fixture/alsa.conf"
  export FF_NATIVE_PREFIX="$ROOT/native/build/third_party/linux/$(uname -m)"
  export PATH="$PATH:${CARGO_HOME:-$HOME/.cargo}/bin"
  cargo build --locked --manifest-path "$ROOT/native/media_core/Cargo.toml" -p fideflow-media-ffi --example play_file
  python3 - "$fixture/fixture.wav" <<'PY'
import math, struct, sys, wave
with wave.open(sys.argv[1], 'wb') as output:
    output.setnchannels(2); output.setsampwidth(2); output.setframerate(44100)
    output.writeframes(b''.join(struct.pack('<hh', value, value) for value in
        (int(1600 * math.sin(2 * math.pi * 440 * i / 44100)) for i in range(44100 * 6))))
PY
  timeout 8 parec --device=ff_portaudio.monitor --format=float32le --rate=48000 --channels=2 > "$fixture/monitor.raw" &
  recorder=$!; children+=("$recorder")
  timeout 8 parec --device=ff_portaudio_second.monitor --format=float32le --rate=48000 --channels=2 > "$fixture/second.raw" &
  children+=("$!")
  (sleep 1.8; pactl set-default-sink ff_portaudio_second) & children+=("$!")
  cargo run --quiet --locked --manifest-path "$ROOT/native/media_core/Cargo.toml" -p fideflow-media-ffi \
    --example play_file -- "$fixture/fixture.wav" --seconds 4 --seek-ms 2000 --quiet | tee "$fixture/playback.jsonl"
  wait "$recorder" || true
  python3 - "$fixture/monitor.raw" "$fixture/second.raw" "$fixture/playback.jsonl" <<'PY'
import array, math, sys, json
samples = array.array('f'); raw = open(sys.argv[1], 'rb').read(); samples.frombytes(raw[:len(raw)-len(raw)%4])
if sys.byteorder != 'little': samples.byteswap()
assert samples and all(math.isfinite(v) for v in samples)
assert max(samples) - min(samples) > .02, 'Decoded PCM did not reach the private monitor'
second = array.array('f'); raw = open(sys.argv[2], 'rb').read(); second.frombytes(raw[:len(raw)-len(raw)%4])
if sys.byteorder != 'little': second.byteswap()
assert second and max(second)-min(second) > .02, 'Playback did not follow the desktop default to the second sink'
result = json.loads(next(line for line in reversed(open(sys.argv[3]).read().splitlines()) if line.startswith('{')))
assert result['device'] == 'ff_portaudio_second', 'Native output stream did not reopen on the new default sink'
print('PortAudio -> ALSA -> private PipeWire: playback, pause/seek, default-sink switch and both captured waveforms passed.')
PY
  exit 0
fi
for tool in pipewire pipewire-pulse wireplumber pactl parec pw-cli dbus-run-session timeout python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then echo "Optional private desktop validation requires $tool; use a CI/container with these tools." >&2; exit 1; fi
done
fixture=$(mktemp -d "${TMPDIR:-/tmp}/fideflow-pa-pipewire.XXXXXX")
cleanup_fixture() { python3 -c 'import shutil,sys; shutil.rmtree(sys.argv[1])' "$fixture"; }
trap cleanup_fixture EXIT
if ! dbus-run-session -- "$SCRIPT_DIR/portaudio_pipewire_smoke.sh" --session "$fixture"; then
  for log in "$fixture"/*.log; do [ -f "$log" ] && tail -30 "$log" >&2; done
  exit 1
fi
