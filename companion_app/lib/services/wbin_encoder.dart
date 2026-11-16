import 'dart:math' as math;
import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// IEEE 802.3 CRC32 Implementation (Polynomial: 0xEDB88320)
///
/// Bitwise identical to ESP32-S3 `esp_rom_crc32_le` and tools/gif_to_oled.mjs.
class Crc32Ieee {
  static const int polynomial = 0xEDB88320;
  static final Uint32List _table = _initTable();

  static Uint32List _initTable() {
    final table = Uint32List(256);
    for (int i = 0; i < 256; i++) {
      int c = i;
      for (int k = 0; k < 8; k++) {
        if ((c & 1) != 0) {
          c = polynomial ^ (c >>> 1);
        } else {
          c = c >>> 1;
        }
      }
      table[i] = c;
    }
    return table;
  }

  /// Computes the 32-bit unsigned IEEE 802.3 CRC32 checksum over [data].
  static int compute(List<int> data) {
    int crc = 0xFFFFFFFF;
    for (int i = 0; i < data.length; i++) {
      crc = _table[(crc ^ data[i]) & 0xFF] ^ (crc >>> 8);
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }
}

/// A single 128x64 monochrome animation frame formatted for SSD1306 displays.
class WbinFrame {
  /// Exactly 1024 bytes (8 vertical pages x 128 columns).
  ///
  /// Page 0 = rows 0..7, Page 7 = rows 56..63.
  /// Bit 0 is the topmost pixel of each page, Bit 7 is the bottommost.
  final Uint8List ssd1306Bytes;

  /// RGBA byte buffer (128 * 64 * 4 bytes) for live Flutter preview rendering.
  final Uint8List previewRgba;

  /// Frame duration in milliseconds (extracted from GIF or calculated from FPS).
  final int durationMs;

  WbinFrame({
    required this.ssd1306Bytes,
    required this.previewRgba,
    this.durationMs = 66,
  }) {
    if (ssd1306Bytes.length != WbinEncoder.frameBytes) {
      throw ArgumentError(
        'ssd1306Bytes must be exactly ${WbinEncoder.frameBytes} bytes (got ${ssd1306Bytes.length})',
      );
    }
    if (previewRgba.length != WbinEncoder.oledWidth * WbinEncoder.oledHeight * 4) {
      throw ArgumentError(
        'previewRgba must be ${WbinEncoder.oledWidth * WbinEncoder.oledHeight * 4} bytes',
      );
    }
  }
}

/// Parsed metadata from a 16-byte .wbin ("WGF1") binary header.
class WbinHeader {
  final String magic;
  final int numFrames;
  final int targetFps;
  final int flags;
  final int payloadBytes;
  final int crc32;

  bool get isInverted => (flags & 0x01) != 0;
  bool get hasHudOverlay => (flags & 0x02) != 0;

  const WbinHeader({
    required this.magic,
    required this.numFrames,
    required this.targetFps,
    required this.flags,
    required this.payloadBytes,
    required this.crc32,
  });

  @override
  String toString() =>
      'WbinHeader(magic: $magic, frames: $numFrames, fps: $targetFps, '
      'flags: 0x${flags.toRadixString(16).padLeft(2, '0')}, bytes: $payloadBytes, '
      'crc32: 0x${crc32.toRadixString(16).padLeft(8, '0').toUpperCase()})';
}

/// Complete compiled .wbin animation package ready for storage or upload.
class WbinAnimation {
  final List<WbinFrame> frames;
  final int targetFps;
  final bool invert;
  final bool hudOverlay;
  final Uint8List wbinBytes;

  WbinAnimation({
    required this.frames,
    required this.targetFps,
    required this.invert,
    required this.hudOverlay,
    required this.wbinBytes,
  });

  int get numFrames => frames.length;
  int get payloadBytes => numFrames * WbinEncoder.frameBytes;
  int get crc32 => ByteData.sublistView(wbinBytes).getUint32(12, Endian.little);
}

/// In-App GIF to .wbin Converter and SSD1306 Bit-Packer.
///
/// Implements Atkinson error diffusion dithering matching tools/gif_to_oled.mjs.
class WbinEncoder {
  static const int oledWidth = 128;
  static const int oledHeight = 64;
  static const int oledPages = 8;
  static const int frameBytes = oledWidth * oledPages; // 1024 bytes
  static const int headerBytes = 16;
  static const int maxFrames = 512;
  static const int minFps = 5;
  static const int maxFps = 30;
  static const int defaultFps = 15;

  /// Creates a [WbinFrame] directly from an existing 1024-byte SSD1306 buffer,
  /// generating the corresponding 128x64x4 RGBA preview buffer.
  static WbinFrame frameFromSsd1306Bytes(Uint8List ssd1306Bytes, {int durationMs = 66}) {
    if (ssd1306Bytes.length != frameBytes) {
      throw ArgumentError('Expected $frameBytes bytes, got ${ssd1306Bytes.length}');
    }
    final preview = Uint8List(oledWidth * oledHeight * 4);
    for (int page = 0; page < oledPages; page++) {
      for (int x = 0; x < oledWidth; x++) {
        final byte = ssd1306Bytes[page * oledWidth + x];
        for (int bit = 0; bit < 8; bit++) {
          final isWhite = (byte & (1 << bit)) != 0;
          final y = page * 8 + bit;
          final pIdx = (y * oledWidth + x) * 4;
          final colorVal = isWhite ? 0xFF : 0x00;
          preview[pIdx] = colorVal;
          preview[pIdx + 1] = colorVal;
          preview[pIdx + 2] = colorVal;
          preview[pIdx + 3] = 0xFF;
        }
      }
    }
    return WbinFrame(
      ssd1306Bytes: Uint8List.fromList(ssd1306Bytes),
      previewRgba: preview,
      durationMs: durationMs,
    );
  }

  /// Converts a multi-frame GIF binary into a list of [WbinFrame]s using
  /// box-area downsampling, gamma correction, and Atkinson 1-bit dithering.
  static List<WbinFrame> convertGifFrames({
    required Uint8List gifBytes,
    bool stretch = false,
    int luminanceThreshold = 118,
    double gamma = 0.85,
    bool invert = false,
  }) {
    final image = img.decodeGif(gifBytes);
    if (image == null) {
      throw const FormatException('Failed to decode GIF image stream');
    }

    final rawFrames = image.frames.isNotEmpty ? image.frames : [image];
    if (rawFrames.isEmpty) {
      throw const FormatException('Decoded GIF contains 0 frames');
    }

    final frames = <WbinFrame>[];

    for (final frame in rawFrames) {
      final w = frame.width;
      final h = frame.height;
      if (w <= 0 || h <= 0) continue;

      final double scale = stretch
          ? 1.0
          : (oledWidth / w < oledHeight / h ? oledWidth / w : oledHeight / h);
      final int targetW =
          stretch ? oledWidth : (w * scale).round().clamp(1, oledWidth);
      final int targetH =
          stretch ? oledHeight : (h * scale).round().clamp(1, oledHeight);
      final int offsetX = (oledWidth - targetW) >> 1;
      final int offsetY = (oledHeight - targetH) >> 1;

      final gray = Float32List(oledWidth * oledHeight);
      final double scaleX = w / targetW;
      final double scaleY = h / targetH;

      for (int ty = 0; ty < targetH; ty++) {
        final int sy0 = (ty * scaleY).floor();
        final int sy1 = math.min(h, ((ty + 1) * scaleY).ceil());
        for (int tx = 0; tx < targetW; tx++) {
          final int sx0 = (tx * scaleX).floor();
          final int sx1 = math.min(w, ((tx + 1) * scaleX).ceil());
          double sum = 0.0;
          int count = 0;
          for (int sy = sy0; sy < sy1; sy++) {
            for (int sx = sx0; sx < sx1; sx++) {
              final pixel = frame.getPixel(sx, sy);
              final double a = pixel.a / 255.0;
              final double l =
                  (0.299 * pixel.r + 0.587 * pixel.g + 0.114 * pixel.b) * a;
              sum += l;
              count++;
            }
          }
          final double norm = count > 0
              ? (math.pow(sum / (count * 255.0), gamma) * 255.0).toDouble()
              : 0.0;
          gray[(offsetY + ty) * oledWidth + (offsetX + tx)] = norm;
        }
      }

      // Atkinson 1-Bit Dithering (exact match with tools/gif_to_oled.mjs)
      final bw = Uint8List(oledWidth * oledHeight);
      for (int y = offsetY; y < offsetY + targetH; y++) {
        for (int x = offsetX; x < offsetX + targetW; x++) {
          final int i = y * oledWidth + x;
          final double oldP = gray[i];
          final double newP = oldP >= luminanceThreshold ? 255.0 : 0.0;
          bw[i] = newP > 0 ? 1 : 0;
          final double err = (oldP - newP) / 8.0;

          if (x + 1 < oledWidth) gray[i + 1] += err;
          if (x + 2 < oledWidth) gray[i + 2] += err;
          if (y + 1 < oledHeight) {
            if (x - 1 >= 0) gray[i + oledWidth - 1] += err;
            gray[i + oledWidth] += err;
            if (x + 1 < oledWidth) gray[i + oledWidth + 1] += err;
          }
          if (y + 2 < oledHeight) gray[i + 2 * oledWidth] += err;
        }
      }

      // Pack into SSD1306 Page-Addressed Format (8 pages x 128 cols = 1024 bytes)
      final pageBuf = Uint8List(frameBytes);
      final previewRgba = Uint8List(oledWidth * oledHeight * 4);

      for (int page = 0; page < oledPages; page++) {
        for (int x = 0; x < oledWidth; x++) {
          int b = 0;
          for (int bit = 0; bit < 8; bit++) {
            final int y = page * 8 + bit;
            final bool isWhite = bw[y * oledWidth + x] == 1;
            final bool bitVal = invert ? !isWhite : isWhite;
            if (bitVal) b |= (1 << bit);

            final int pIdx = (y * oledWidth + x) * 4;
            final int colorVal = bitVal ? 0xFF : 0x00;
            previewRgba[pIdx] = colorVal;
            previewRgba[pIdx + 1] = colorVal;
            previewRgba[pIdx + 2] = colorVal;
            previewRgba[pIdx + 3] = 0xFF;
          }
          pageBuf[page * oledWidth + x] = b;
        }
      }

      // Frame duration in ms (default ~66 ms = 15 FPS)
      final duration = frame.frameDuration > 0
          ? frame.frameDuration
          : 66;

      frames.add(WbinFrame(
        ssd1306Bytes: pageBuf,
        previewRgba: previewRgba,
        durationMs: duration,
      ));
    }

    return frames;
  }

  /// Packages a list of raw 1024-byte frames into a 16-byte "WGF1" container
  /// followed by payload bytes, validated by IEEE 802.3 CRC32.
  static Uint8List packageRawFrames({
    required List<Uint8List> rawFrames,
    int targetFps = defaultFps,
    bool invert = false,
    bool hudOverlay = true,
  }) {
    final numFrames = rawFrames.length;
    if (numFrames < 1 || numFrames > maxFrames) {
      throw ArgumentError(
        'Frame count must be between 1 and $maxFrames (got $numFrames)',
      );
    }

    final int clampedFps = targetFps.clamp(minFps, maxFps);
    final int payloadBytes = numFrames * frameBytes;
    final int fullBytes = headerBytes + payloadBytes;
    final out = Uint8List(fullBytes);
    final bd = ByteData.sublistView(out);

    // 0x00: Magic "WGF1" (0x57, 0x47, 0x46, 0x31)
    out[0] = 0x57; // 'W'
    out[1] = 0x47; // 'G'
    out[2] = 0x46; // 'F'
    out[3] = 0x31; // '1'

    // 0x04: num_frames (uint16 little-endian)
    bd.setUint16(4, numFrames, Endian.little);

    // 0x06: target_fps (uint8)
    out[6] = clampedFps;

    // 0x07: flags (uint8: bit 0 = invert, bit 1 = hud_overlay)
    int flags = 0;
    if (invert) flags |= 0x01;
    if (hudOverlay) flags |= 0x02;
    out[7] = flags;

    // 0x08: payload_bytes (uint32 little-endian)
    bd.setUint32(8, payloadBytes, Endian.little);

    // Copy frame payloads starting at offset 0x10
    int offset = headerBytes;
    for (int i = 0; i < numFrames; i++) {
      final f = rawFrames[i];
      if (f.length != frameBytes) {
        throw ArgumentError(
          'Frame $i length is ${f.length}, expected $frameBytes',
        );
      }
      out.setRange(offset, offset + frameBytes, f);
      offset += frameBytes;
    }

    // 0x0C: IEEE 802.3 CRC32 calculated over payload bytes (0x10 to end)
    final payloadView = Uint8List.sublistView(out, headerBytes);
    final crc = Crc32Ieee.compute(payloadView);
    bd.setUint32(12, crc, Endian.little);

    return out;
  }

  /// Packages a list of [WbinFrame]s into a complete .wbin binary buffer.
  static Uint8List packageWbin({
    required List<WbinFrame> frames,
    int targetFps = defaultFps,
    bool invert = false,
    bool hudOverlay = true,
  }) {
    if (frames.isEmpty || frames.length > maxFrames) {
      throw ArgumentError(
        'Frame count must be between 1 and $maxFrames (got ${frames.length})',
      );
    }
    final rawList = frames.map((f) => f.ssd1306Bytes).toList();
    return packageRawFrames(
      rawFrames: rawList,
      targetFps: targetFps,
      invert: invert,
      hudOverlay: hudOverlay,
    );
  }

  /// High-level method: Decodes a GIF, Atkinson-dithers frames, and packages
  /// into a validated [WbinAnimation].
  static WbinAnimation encodeGif({
    required Uint8List gifBytes,
    int targetFps = defaultFps,
    bool stretch = false,
    bool invert = false,
    bool hudOverlay = true,
    int luminanceThreshold = 118,
    double gamma = 0.85,
  }) {
    final frames = convertGifFrames(
      gifBytes: gifBytes,
      stretch: stretch,
      luminanceThreshold: luminanceThreshold,
      gamma: gamma,
      invert: invert,
    );

    final wbinBytes = packageWbin(
      frames: frames,
      targetFps: targetFps,
      invert: invert,
      hudOverlay: hudOverlay,
    );

    return WbinAnimation(
      frames: frames,
      targetFps: targetFps,
      invert: invert,
      hudOverlay: hudOverlay,
      wbinBytes: wbinBytes,
    );
  }

  /// Parses and validates the 16-byte "WGF1" container header.
  static WbinHeader parseHeader(Uint8List wbinBytes) {
    if (wbinBytes.length < headerBytes) {
      throw FormatException(
        'Payload too short for WGF1 header: ${wbinBytes.length} < $headerBytes',
      );
    }
    final bd = ByteData.sublistView(wbinBytes);
    final magic = String.fromCharCodes(wbinBytes.sublist(0, 4));
    if (magic != 'WGF1') {
      throw FormatException('Invalid magic bytes: "$magic" (expected "WGF1")');
    }
    final numFrames = bd.getUint16(4, Endian.little);
    if (numFrames < 1 || numFrames > maxFrames) {
      throw FormatException(
        'Invalid num_frames: $numFrames (must be 1..$maxFrames)',
      );
    }
    final targetFps = wbinBytes[6];
    final flags = wbinBytes[7];
    final payloadBytes = bd.getUint32(8, Endian.little);
    if (payloadBytes != numFrames * frameBytes) {
      throw FormatException(
        'Payload size mismatch: $payloadBytes != $numFrames * $frameBytes',
      );
    }
    if (wbinBytes.length < headerBytes + payloadBytes) {
      throw FormatException(
        'Truncated file: length ${wbinBytes.length} < ${headerBytes + payloadBytes}',
      );
    }
    final crc32 = bd.getUint32(12, Endian.little);
    return WbinHeader(
      magic: magic,
      numFrames: numFrames,
      targetFps: targetFps,
      flags: flags,
      payloadBytes: payloadBytes,
      crc32: crc32,
    );
  }

  /// Verifies the IEEE 802.3 CRC32 checksum of a .wbin binary buffer.
  static bool verifyCrc32(Uint8List wbinBytes) {
    try {
      final header = parseHeader(wbinBytes);
      final payload = Uint8List.sublistView(
        wbinBytes,
        headerBytes,
        headerBytes + header.payloadBytes,
      );
      final computed = Crc32Ieee.compute(payload);
      return computed == header.crc32;
    } catch (_) {
      return false;
    }
  }

  /// Unpacks a .wbin byte array into a list of [WbinFrame] objects.
  static List<WbinFrame> unpackFrames(Uint8List wbinBytes) {
    final header = parseHeader(wbinBytes);
    final List<WbinFrame> list = [];
    int offset = headerBytes;
    final int delayMs = header.targetFps > 0 ? (1000 ~/ header.targetFps) : 66;

    for (int i = 0; i < header.numFrames; i++) {
      final slice = Uint8List.sublistView(wbinBytes, offset, offset + frameBytes);
      list.add(frameFromSsd1306Bytes(slice, durationMs: delayMs));
      offset += frameBytes;
    }
    return list;
  }
}
