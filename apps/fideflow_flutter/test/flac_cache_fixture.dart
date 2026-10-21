import 'dart:typed_data';

/// Verbatim stereo FLAC with one exact seek point per frame (no encoder needed).
const flacBlockSamples = 4096;
const flacFrameBytes = 16394;
const flacFrameCount = 40;
const flacHeaderBytes = 46 + flacFrameCount * 18;
int flacFrameOffset(int frame) => flacHeaderBytes + frame * flacFrameBytes;

Uint8List flacCacheFixture() {
  int crc(List<int> bytes, int bits, int polynomial) {
    var value = 0;
    for (final byte in bytes) {
      value ^= byte << (bits - 8);
      for (var i = 0; i < 8; i++) {
        value = (value & (1 << (bits - 1)) != 0)
            ? (value << 1) ^ polynomial
            : value << 1;
        value &= (1 << bits) - 1;
      }
    }
    return value;
  }

  final output = BytesBuilder();
  output.add([102, 76, 97, 67, 0, 0, 0, 34]);
  final stream = ByteData(34)
    ..setUint16(0, flacBlockSamples)
    ..setUint16(2, flacBlockSamples)
    ..setUint64(
      10,
      (44100 << 44) |
          (1 << 41) |
          (15 << 36) |
          (flacBlockSamples * flacFrameCount),
    );
  output.add(stream.buffer.asUint8List());
  output.add([131, 0, (flacFrameCount * 18) >> 8, (flacFrameCount * 18) & 255]);
  final seek = ByteData(flacFrameCount * 18);
  for (var frame = 0; frame < flacFrameCount; frame++) {
    seek.setUint64(frame * 18, frame * flacBlockSamples);
    seek.setUint64(frame * 18 + 8, frame * flacFrameBytes);
    seek.setUint16(frame * 18 + 16, flacBlockSamples);
  }
  output.add(seek.buffer.asUint8List());
  for (var frame = 0; frame < flacFrameCount; frame++) {
    final bytes = Uint8List(flacFrameBytes);
    bytes.setAll(0, [255, 248, 201, 24, frame]);
    bytes[5] = crc(bytes.sublist(0, 5), 8, 7);
    bytes[6] = 2;
    bytes[6 + 1 + flacBlockSamples * 2] = 2;
    final checksum = crc(bytes.sublist(0, bytes.length - 2), 16, 0x8005);
    bytes[bytes.length - 2] = checksum >> 8;
    bytes.last = checksum & 255;
    output.add(bytes);
  }
  return output.takeBytes();
}
