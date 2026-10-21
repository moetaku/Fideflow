import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

// Process CPU includes Dart and native decoder/transport threads, excludes idle
// network waits. Used only by opt-in performance tests on macOS/Linux.
typedef _GetUsage = Int32 Function(Int32, Pointer<Void>);
final _getUsage = Platform.isMacOS || Platform.isLinux
    ? DynamicLibrary.process()
          .lookupFunction<_GetUsage, int Function(int, Pointer<Void>)>(
            'getrusage',
          )
    : null;
int processCpuMicros() {
  final getUsage = _getUsage;
  if (getUsage == null) return 0;
  final memory = calloc<Uint8>(256);
  try {
    if (getUsage(0, memory.cast()) != 0) return 0;
    final words = memory.cast<Int64>();
    // Darwin timeval has a 32-bit tv_usec plus padding; Linux uses long.
    final micros = memory.cast<Int32>();
    final user = Platform.isMacOS ? micros[2] : words[1];
    final system = Platform.isMacOS ? micros[6] : words[3];
    return words[0] * 1000000 + user + words[2] * 1000000 + system;
  } finally {
    calloc.free(memory);
  }
}
