import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../services/waste_connection_service.dart';
import '../services/wbin_encoder.dart';

/// Custom Painter rendering a 128x64 SSD1306 monochrome bitmap on a Flutter Canvas.
class OledCanvasPainter extends CustomPainter {
  final Uint8List ssd1306Bytes;
  final bool invert;
  final Color pixelOnColor;
  final Color pixelOffColor;

  const OledCanvasPainter({
    required this.ssd1306Bytes,
    this.invert = false,
    this.pixelOnColor = const Color(0xFF64FFDA), // Bright OLED teal
    this.pixelOffColor = const Color(0xFF070B0E), // OLED background black
  });

  @override
  void paint(Canvas canvas, Size size) {
    final bgPaint = Paint()..color = invert ? pixelOnColor : pixelOffColor;
    canvas.drawRect(Offset.zero & size, bgPaint);

    final fgPaint = Paint()
      ..color = invert ? pixelOffColor : pixelOnColor
      ..isAntiAlias = false;

    final cellW = size.width / 128.0;
    final cellH = size.height / 64.0;

    for (int page = 0; page < 8; page++) {
      for (int x = 0; x < 128; x++) {
        final byte = ssd1306Bytes[page * 128 + x];
        if (byte == 0) continue;
        for (int bit = 0; bit < 8; bit++) {
          if ((byte & (1 << bit)) != 0) {
            final y = page * 8 + bit;
            canvas.drawRect(
              Rect.fromLTWH(x * cellW, y * cellH, cellW, cellH),
              fgPaint,
            );
          }
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant OledCanvasPainter oldDelegate) =>
      oldDelegate.ssd1306Bytes != ssd1306Bytes ||
      oldDelegate.invert != invert ||
      oldDelegate.pixelOnColor != pixelOnColor ||
      oldDelegate.pixelOffColor != pixelOffColor;
}

/// Modal bottom sheet for selecting, previewing, and uploading custom .wbin animations.
class AnimationUploadSheet extends StatefulWidget {
  final WasteConnectionService service;
  final WbinAnimation? initialAnimation;

  const AnimationUploadSheet({
    super.key,
    required this.service,
    this.initialAnimation,
  });

  @override
  State<AnimationUploadSheet> createState() => _AnimationUploadSheetState();
}

class _AnimationUploadSheetState extends State<AnimationUploadSheet> {
  WbinAnimation? _animation;
  int _currentFrame = 0;
  bool _isPlaying = false;
  Timer? _playbackTimer;

  bool _isConverting = false;
  bool _isUploading = false;
  double _uploadProgress = 0.0;
  String _statusMessage = 'Select an animated GIF to convert and preview';

  int _targetFps = 15;
  bool _invert = false;
  bool _hudOverlay = true;
  bool _stretch = false;
  Uint8List? _cachedGifBytes;

  @override
  void initState() {
    super.initState();
    if (widget.initialAnimation != null) {
      _animation = widget.initialAnimation;
      _targetFps = widget.initialAnimation!.targetFps;
      _invert = widget.initialAnimation!.invert;
      _hudOverlay = widget.initialAnimation!.hudOverlay;
      _statusMessage =
          'Loaded ${_animation!.numFrames} frames (${_animation!.payloadBytes + 16} bytes)';
    }
  }

  @override
  void dispose() {
    _playbackTimer?.cancel();
    super.dispose();
  }

  void _togglePlayback() {
    if (_animation == null || _animation!.frames.isEmpty) return;
    if (_isPlaying) {
      _playbackTimer?.cancel();
      setState(() => _isPlaying = false);
    } else {
      setState(() => _isPlaying = true);
      final interval = Duration(milliseconds: 1000 ~/ _targetFps);
      _playbackTimer?.cancel();
      _playbackTimer = Timer.periodic(interval, (_) {
        if (!mounted || _animation == null || _animation!.frames.isEmpty) return;
        setState(() {
          _currentFrame = (_currentFrame + 1) % _animation!.frames.length;
        });
      });
    }
  }

  Future<void> _pickGifFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['gif'],
        withData: true,
      );

      if (result == null || result.files.isEmpty) return;

      final picked = result.files.first;
      Uint8List? bytes = picked.bytes;
      if (bytes == null && picked.path != null) {
        final f = File(picked.path!);
        if (await f.exists()) {
          bytes = await f.readAsBytes();
        }
      }

      if (bytes == null || bytes.isEmpty) {
        setState(() => _statusMessage = 'Could not read bytes from selected file');
        return;
      }

      _cachedGifBytes = bytes;
      await _processGif(bytes, picked.name);
    } catch (e) {
      setState(() => _statusMessage = 'File picker error: $e');
    }
  }

  Future<void> _processGif(Uint8List gifBytes, String fileName) async {
    _playbackTimer?.cancel();
    setState(() {
      _isConverting = true;
      _isPlaying = false;
      _currentFrame = 0;
      _statusMessage = 'Converting $fileName via Atkinson dithering...';
    });

    try {
      final anim = WbinEncoder.encodeGif(
        gifBytes: gifBytes,
        targetFps: _targetFps,
        stretch: _stretch,
        invert: _invert,
        hudOverlay: _hudOverlay,
      );

      setState(() {
        _animation = anim;
        _isConverting = false;
        _statusMessage =
            '$fileName: ${anim.numFrames} frames (${anim.payloadBytes + 16} B, CRC: 0x${anim.crc32.toRadixString(16).toUpperCase()})';
      });
    } catch (e) {
      setState(() {
        _isConverting = false;
        _statusMessage = 'Conversion failed: $e';
      });
    }
  }

  void _loadDemoAnimation() {
    _playbackTimer?.cancel();
    const numFrames = 12;
    final List<WbinFrame> frames = [];

    // Synthesize an animated geometric pattern directly
    for (int f = 0; f < numFrames; f++) {
      final pageBuf = Uint8List(WbinEncoder.frameBytes);
      final centerCol = 20 + f * 7;
      final centerRow = 15 + ((f % 6) * 6);

      // Draw a box and crosshairs
      for (int dy = -8; dy <= 8; dy++) {
        for (int dx = -8; dx <= 8; dx++) {
          final x = (centerCol + dx).clamp(0, 127);
          final y = (centerRow + dy).clamp(0, 63);
          final bool isBorder = dx.abs() == 8 || dy.abs() == 8 || dx == 0 || dy == 0;
          if (isBorder) {
            final page = y ~/ 8;
            final bit = y % 8;
            pageBuf[page * 128 + x] |= (1 << bit);
          }
        }
      }
      frames.add(WbinEncoder.frameFromSsd1306Bytes(pageBuf));
    }

    final bytes = WbinEncoder.packageWbin(
      frames: frames,
      targetFps: _targetFps,
      invert: _invert,
      hudOverlay: _hudOverlay,
    );

    setState(() {
      _animation = WbinAnimation(
        frames: frames,
        targetFps: _targetFps,
        invert: _invert,
        hudOverlay: _hudOverlay,
        wbinBytes: bytes,
      );
      _currentFrame = 0;
      _statusMessage = 'Demo Animation: $numFrames frames (${bytes.length} bytes)';
    });
  }

  Future<void> _handleUpload() async {
    if (_animation == null) return;
    _playbackTimer?.cancel();
    setState(() {
      _isPlaying = false;
      _isUploading = true;
      _uploadProgress = 0.0;
    });

    final success = await widget.service.uploadCustomAnimation(
      _animation!.wbinBytes,
      onProgress: (p) {
        if (mounted) setState(() => _uploadProgress = p);
      },
    );

    if (mounted) {
      setState(() => _isUploading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success
                ? 'Animation uploaded successfully! Core 1 OLED updated.'
                : 'Upload failed: ${widget.service.statusMessage}',
          ),
          backgroundColor: success ? Colors.teal : Colors.redAccent,
        ),
      );
    }
  }

  Future<void> _handleReset() async {
    final success = await widget.service.resetCustomAnimation();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success
                ? 'Reset to compiled Dancing Cat mascot complete!'
                : 'Reset failed: ${widget.service.statusMessage}',
          ),
          backgroundColor: success ? Colors.teal : Colors.redAccent,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final mode = widget.service.transportMode;
    final canUpload = _animation != null &&
        (mode == TransportMode.lan || mode == TransportMode.ble) &&
        !_isUploading;

    final uploadSubtitle = mode == TransportMode.lan
        ? 'Route: Local LAN (POST /api/oled/upload)'
        : (mode == TransportMode.ble
            ? 'Route: BLE GATT Characteristic 0xFF07'
            : 'Offline: Connect LAN or BLE to upload');

    final currentFrameData = (_animation != null && _animation!.frames.isNotEmpty)
        ? _animation!.frames[_currentFrame]
        : null;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        left: 16,
        right: 16,
        top: 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header Bar
          Row(
            children: [
              const Icon(Icons.movie_filter_outlined, color: Colors.tealAccent),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Custom OLED Animation (.wbin)',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _statusMessage,
            style: const TextStyle(fontSize: 12, color: Colors.white70),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 12),

          // Virtual OLED Display Bezel
          Center(
            child: Container(
              width: 256,
              height: 128,
              decoration: BoxDecoration(
                color: const Color(0xFF070B0E),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: Colors.tealAccent.withOpacity(0.6),
                  width: 2.0,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.tealAccent.withOpacity(0.18),
                    blurRadius: 16,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: currentFrameData != null
                    ? CustomPaint(
                        painter: OledCanvasPainter(
                          ssd1306Bytes: currentFrameData.ssd1306Bytes,
                          invert: _invert,
                        ),
                      )
                    : const Center(
                        child: Text(
                          '128 x 64 OLED\nNo Animation Loaded',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white30,
                            fontSize: 12,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 8),

          // Playback & Frame Scrubber
          if (_animation != null && _animation!.frames.isNotEmpty) ...[
            Row(
              children: [
                IconButton(
                  icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                  color: Colors.tealAccent,
                  onPressed: _togglePlayback,
                ),
                Expanded(
                  child: Slider(
                    key: const Key('frame_scrub_slider'),
                    min: 0,
                    max: (_animation!.numFrames - 1).toDouble(),
                    value: _currentFrame.toDouble().clamp(
                          0.0,
                          (_animation!.numFrames - 1).toDouble(),
                        ),
                    onChanged: (v) {
                      setState(() {
                        _currentFrame = v.toInt();
                        if (_isPlaying) {
                          _isPlaying = false;
                          _playbackTimer?.cancel();
                        }
                      });
                    },
                  ),
                ),
                Text(
                  '${_currentFrame + 1} / ${_animation!.numFrames}',
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                ),
              ],
            ),
          ],

          // Controls & Options Row
          Wrap(
            spacing: 8,
            runSpacing: 4,
            alignment: WrapAlignment.center,
            children: [
              FilterChip(
                label: const Text('Invert B/W'),
                selected: _invert,
                onSelected: (val) {
                  setState(() => _invert = val);
                  if (_cachedGifBytes != null) {
                    _processGif(_cachedGifBytes!, 'Re-dithered');
                  }
                },
              ),
              FilterChip(
                label: const Text('Stretch 128x64'),
                selected: _stretch,
                onSelected: (val) {
                  setState(() => _stretch = val);
                  if (_cachedGifBytes != null) {
                    _processGif(_cachedGifBytes!, 'Re-dithered');
                  }
                },
              ),
              FilterChip(
                label: const Text('HUD Overlay'),
                selected: _hudOverlay,
                onSelected: (val) => setState(() => _hudOverlay = val),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // File Selection Row
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.file_open_outlined),
                  label: const Text('Pick GIF File'),
                  onPressed: _isConverting ? null : _pickGifFile,
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                icon: const Icon(Icons.auto_awesome),
                label: const Text('Demo Pattern'),
                onPressed: _isConverting ? null : _loadDemoAnimation,
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Upload Progress Bar
          if (_isUploading) ...[
            LinearProgressIndicator(value: _uploadProgress),
            const SizedBox(height: 6),
            Text(
              'Uploading: ${(_uploadProgress * 100).toInt()}%',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Colors.tealAccent),
            ),
            const SizedBox(height: 10),
          ],

          // Action Buttons: Upload & Reset
          FilledButton.icon(
            key: const Key('upload_anim_button'),
            icon: const Icon(Icons.cloud_upload_outlined),
            label: Text(
              _animation == null
                  ? 'Select GIF to Upload'
                  : 'Upload Animation (${_animation!.numFrames} frames)',
            ),
            onPressed: canUpload ? _handleUpload : null,
          ),
          const SizedBox(height: 4),
          Center(
            child: Text(
              uploadSubtitle,
              style: TextStyle(
                fontSize: 11,
                color: canUpload ? Colors.tealAccent : Colors.white38,
              ),
            ),
          ),
          const SizedBox(height: 8),

          OutlinedButton.icon(
            key: const Key('reset_anim_button'),
            icon: const Icon(Icons.restore),
            label: const Text('Reset to Mascot (Hololive Risu Cat)'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.orangeAccent,
              side: const BorderSide(color: Colors.orangeAccent),
            ),
            onPressed: _isUploading ? null : _handleReset,
          ),
        ],
      ),
    );
  }
}
