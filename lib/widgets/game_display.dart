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
    widget.emulator.onFrame = _onFrame;
  }

  @override
  void didUpdateWidget(GameDisplay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.emulator != widget.emulator) {
      oldWidget.emulator.onFrame = null;
      widget.emulator.onFrame = _onFrame;
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    widget.emulator.onFrame = null;
    _frameImage?.dispose();
    super.dispose();
  }

  Uint8List? _pendingPixels;
  int _pendingWidth = 0;
  int _pendingHeight = 0;
  bool _decoding = false;

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

    // Create image from pixel data
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
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
    return Container(
      decoration: BoxDecoration(
        color: YageColors.backgroundDark,
        border: Border.all(
          color: YageColors.primary.withAlpha(77),
          width: 2,
        ),
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: YageColors.primary.withAlpha(51),
            blurRadius: 20,
            spreadRadius: 2,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: widget.maintainAspectRatio
            ? AspectRatio(
                aspectRatio: widget.emulator.screenWidth / 
                             widget.emulator.screenHeight,
                child: _buildDisplay(),
              )
            : _buildDisplay(),
      ),
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
    final paint = Paint()
      ..filterQuality = enableFiltering 
          ? FilterQuality.medium 
          : FilterQuality.none;

    // Calculate destination rect to fit and center
    final srcRect = Rect.fromLTWH(
      0, 0, 
      image.width.toDouble(), 
      image.height.toDouble(),
    );

    final destRect = Rect.fromLTWH(0, 0, size.width, size.height);

    canvas.drawImageRect(image, srcRect, destRect, paint);
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
    return Positioned(
      top: 8,
      right: 8,
      child: Container(
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
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: YageColors.textPrimary,
          ),
        ),
      ),
    );
  }
}

