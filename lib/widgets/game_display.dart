import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../services/emulator_service.dart';
import '../utils/theme.dart';

/// Widget for displaying the emulator game screen
class GameDisplay extends StatefulWidget {
  final EmulatorService emulator;
  final bool maintainAspectRatio;
  final bool enableFiltering;

  const GameDisplay({
    super.key,
    required this.emulator,
    this.maintainAspectRatio = true,
    this.enableFiltering = true,
  });

  @override
  State<GameDisplay> createState() => _GameDisplayState();
}

class _GameDisplayState extends State<GameDisplay> {
  ui.Image? _frameImage;
  bool _isDisposed = false;

  @override
  void initState() {
    super.initState();
    _registerCallback();
  }

  @override
  void didUpdateWidget(GameDisplay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Always re-register callback to handle orientation changes
    _registerCallback();
  }
  
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Re-register after orientation change
    _registerCallback();
  }
  
  void _registerCallback() {
    // Ensure our callback is always registered
    widget.emulator.onFrame = _onFrame;
  }

  @override
  void dispose() {
    _isDisposed = true;
    // Only clear if we're the current callback
    if (widget.emulator.onFrame == _onFrame) {
      widget.emulator.onFrame = null;
    }
    _frameImage?.dispose();
    super.dispose();
  }

  Uint8List? _pendingPixels;
  int _pendingWidth = 0;
  int _pendingHeight = 0;
  bool _decoding = false;

  // ── Double-buffer pool to avoid per-frame Uint8List allocations ──
  Uint8List? _bufferA;
  Uint8List? _bufferB;
  bool _useBufferA = true;

  /// Return a pre-allocated buffer of the given [size], creating or resizing
  /// only when necessary.  Alternates between two buffers so the one handed
  /// to `decodeImageFromPixels` is never overwritten while still in use.
  Uint8List _acquireBuffer(int size) {
    if (_useBufferA) {
      if (_bufferA == null || _bufferA!.length != size) {
        _bufferA = Uint8List(size);
      }
      _useBufferA = false;
      return _bufferA!;
    } else {
      if (_bufferB == null || _bufferB!.length != size) {
        _bufferB = Uint8List(size);
      }
      _useBufferA = true;
      return _bufferB!;
    }
  }

  void _onFrame(Uint8List pixels, int width, int height) {
    if (_isDisposed) return;

    // Store latest frame data (skip if already decoding to prevent backup)
    _pendingPixels = pixels;
    _pendingWidth = width;
    _pendingHeight = height;
    
    if (!_decoding) {
      _decodeFrame();
    }
  }
  
  void _decodeFrame() async {
    if (_isDisposed || _pendingPixels == null) return;
    
    _decoding = true;
    final pixels = _pendingPixels!;
    final width = _pendingWidth;
    final height = _pendingHeight;
    _pendingPixels = null;

    // Copy into a pre-allocated buffer (avoids GC pressure from per-frame
    // Uint8List.fromList allocations at 60 fps).
    final pixelsCopy = _acquireBuffer(pixels.length);
    pixelsCopy.setAll(0, pixels);

    // Create image from pixel data
    // Use targetWidth/targetHeight to let the GPU pre-scale to a larger
    // resolution — this produces much sharper results than scaling a tiny
    // 240×160 image in the paint phase. We use 3x which covers most
    // phone screens (720p–1080p) without excessive memory.
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixelsCopy,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
      targetWidth: width * 3,
      targetHeight: height * 3,
    );

    final newImage = await completer.future;
    
    if (_isDisposed) {
      newImage.dispose();
      _decoding = false;
      return;
    }

    final oldImage = _frameImage;
    if (mounted) {
      setState(() {
        _frameImage = newImage;
      });
    }
    oldImage?.dispose();
    
    _decoding = false;
    
    // If another frame came in while decoding, process it
    if (_pendingPixels != null) {
      _decodeFrame();
    }
  }

  @override
  Widget build(BuildContext context) {
    // No borders or padding - maximize game display area
    return Container(
      color: YageColors.backgroundDark,
      child: widget.maintainAspectRatio
          ? AspectRatio(
              aspectRatio: widget.emulator.screenWidth / 
                           widget.emulator.screenHeight,
              child: _buildDisplay(),
            )
          : _buildDisplay(),
    );
  }

  Widget _buildDisplay() {
    if (_frameImage == null) {
      return _buildPlaceholder();
    }

    return CustomPaint(
      painter: _GamePainter(
        image: _frameImage!,
        enableFiltering: widget.enableFiltering,
      ),
      size: Size.infinite,
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      color: YageColors.backgroundDark,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.videogame_asset,
              size: 64,
              color: YageColors.primary.withAlpha(128),
            ),
            const SizedBox(height: 16),
            Text(
              'NO SIGNAL',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: YageColors.textMuted.withAlpha(128),
                letterSpacing: 4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GamePainter extends CustomPainter {
  final ui.Image image;
  final bool enableFiltering;

  _GamePainter({
    required this.image,
    required this.enableFiltering,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final srcRect = Rect.fromLTWH(
      0, 0,
      image.width.toDouble(),
      image.height.toDouble(),
    );

    if (enableFiltering) {
      // Smooth bilinear/cubic scaling — good for large screens
      final paint = Paint()
        ..filterQuality = FilterQuality.medium
        ..isAntiAlias = true;
      final destRect = Rect.fromLTWH(0, 0, size.width, size.height);
      canvas.drawImageRect(image, srcRect, destRect, paint);
    } else {
      // Pixel-perfect: snap to nearest integer scale so every pixel
      // has exactly the same size — eliminates shimmer/uneven pixels
      final paint = Paint()
        ..filterQuality = FilterQuality.none
        ..isAntiAlias = false;

      final imgW = image.width.toDouble();
      final imgH = image.height.toDouble();

      // Find largest integer scale that fits
      final scaleX = (size.width / imgW).floor();
      final scaleY = (size.height / imgH).floor();
      final scale = scaleX < scaleY ? scaleX : scaleY;

      if (scale >= 1) {
        // Integer-scaled: centered with uniform pixel size
        final destW = imgW * scale;
        final destH = imgH * scale;
        final offsetX = (size.width - destW) / 2;
        final offsetY = (size.height - destH) / 2;
        
        // Fill the letterbox bars with black
        if (offsetX > 0 || offsetY > 0) {
          canvas.drawRect(
            Rect.fromLTWH(0, 0, size.width, size.height),
            Paint()..color = const Color(0xFF000000),
          );
        }
        
        final destRect = Rect.fromLTWH(offsetX, offsetY, destW, destH);
        canvas.drawImageRect(image, srcRect, destRect, paint);
      } else {
        // Screen too small for even 1x — just fill
        final destRect = Rect.fromLTWH(0, 0, size.width, size.height);
        canvas.drawImageRect(image, srcRect, destRect, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_GamePainter oldDelegate) {
    return oldDelegate.image != image ||
           oldDelegate.enableFiltering != enableFiltering;
  }
}

/// FPS counter overlay
class FpsOverlay extends StatelessWidget {
  final double fps;

  const FpsOverlay({super.key, required this.fps});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: YageColors.backgroundDark.withAlpha(204),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: fps >= 55 
              ? YageColors.success 
              : fps >= 30 
                  ? YageColors.warning 
                  : YageColors.error,
          width: 1,
        ),
      ),
      child: Text(
        '${fps.toStringAsFixed(1)} FPS',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: YageColors.textPrimary,
        ),
      ),
    );
  }
}

