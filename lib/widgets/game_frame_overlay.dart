import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../models/game_frame.dart';

/// Draws a decorative Game Boy console shell around the game display.
///
/// [gameRect] is the screen-space rectangle where the game is rendered.
/// The painter fills the entire canvas and leaves a transparent "window"
/// at [gameRect] so the game shows through.
class GameFrameOverlay extends StatelessWidget {
  final GameFrameType frame;
  final Rect gameRect;

  const GameFrameOverlay({
    super.key,
    required this.frame,
    required this.gameRect,
  });

  @override
  Widget build(BuildContext context) {
    if (frame == GameFrameType.none) return const SizedBox.shrink();

    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _FramePainter(frame: frame, gameRect: gameRect),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════
//  Main painter – dispatches to per-frame drawing methods
// ═════════════════════════════════════════════════════════════════
class _FramePainter extends CustomPainter {
  final GameFrameType frame;
  final Rect gameRect;

  _FramePainter({required this.frame, required this.gameRect});

  @override
  void paint(Canvas canvas, Size size) {
    switch (frame) {
      case GameFrameType.none:
        return;
      case GameFrameType.dmg:
        _paintDMG(canvas, size);
      case GameFrameType.pocket:
        _paintPocket(canvas, size);
      case GameFrameType.color:
        _paintColor(canvas, size);
      case GameFrameType.advance:
        _paintAdvance(canvas, size);
    }
  }

  @override
  bool shouldRepaint(_FramePainter old) =>
      old.frame != frame || old.gameRect != gameRect;

  // ─────────────────────────────────────────────
  //  Helpers
  // ─────────────────────────────────────────────

  /// Compute body rect that wraps the game screen with given padding ratios.
  Rect _bodyRect({
    required double padLeft,
    required double padRight,
    required double padTop,
    required double padBottom,
  }) {
    final gw = gameRect.width;
    final gh = gameRect.height;
    return Rect.fromLTRB(
      gameRect.left - gw * padLeft,
      gameRect.top - gh * padTop,
      gameRect.right + gw * padRight,
      gameRect.bottom + gh * padBottom,
    );
  }

  /// Draw a rounded rectangle with an inner shadow bevel.
  void _drawBeveledBody(
    Canvas canvas,
    Rect rect, {
    required Color body,
    required double radius,
    Color? highlight,
    Color? shadow,
  }) {
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));

    // Body fill
    canvas.drawRRect(rrect, Paint()..color = body);

    // Top-left highlight edge
    if (highlight != null) {
      final hlPaint = Paint()
        ..color = highlight
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;
      canvas.save();
      canvas.clipRRect(rrect);
      canvas.drawRRect(
        rrect.shift(const Offset(-1, -1)),
        hlPaint,
      );
      canvas.restore();
    }

    // Bottom-right shadow edge
    if (shadow != null) {
      final shPaint = Paint()
        ..color = shadow
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5;
      canvas.save();
      canvas.clipRRect(rrect);
      canvas.drawRRect(
        rrect.shift(const Offset(1.5, 1.5)),
        shPaint,
      );
      canvas.restore();
    }
  }

  /// Paint text centered at a point.
  void _drawText(
    Canvas canvas,
    String text,
    Offset center, {
    double fontSize = 12,
    Color color = Colors.black54,
    FontWeight weight = FontWeight.bold,
    double letterSpacing = 1.5,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: weight,
          color: color,
          letterSpacing: letterSpacing,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(center.dx - tp.width / 2, center.dy - tp.height / 2));
  }

  /// Draw a simple cross-shaped d-pad.
  void _drawDPad(Canvas canvas, Offset center, double size, Color color) {
    final armW = size * 0.32;
    final armH = size;
    final paint = Paint()..color = color;
    final r = 3.0;

    // Vertical arm
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: center, width: armW, height: armH),
        Radius.circular(r),
      ),
      paint,
    );
    // Horizontal arm
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: center, width: armH, height: armW),
        Radius.circular(r),
      ),
      paint,
    );
  }

  /// Small circle button (A / B style).
  void _drawRoundButton(
    Canvas canvas,
    Offset center,
    double radius,
    Color color, {
    String? label,
    Color labelColor = Colors.white54,
    double labelSize = 9,
  }) {
    canvas.drawCircle(center, radius, Paint()..color = color);
    // Highlight
    canvas.drawCircle(
      center + Offset(-radius * 0.2, -radius * 0.2),
      radius * 0.45,
      Paint()..color = Colors.white.withAlpha(30),
    );
    if (label != null) {
      _drawText(canvas, label, center,
          fontSize: labelSize, color: labelColor, letterSpacing: 0);
    }
  }

  /// Speaker grille: horizontal lines.
  void _drawSpeakerGrille(
    Canvas canvas,
    Rect area, {
    required Color color,
    int lines = 6,
    double angle = 0.0,
  }) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;

    canvas.save();
    if (angle != 0) {
      canvas.translate(area.center.dx, area.center.dy);
      canvas.rotate(angle);
      canvas.translate(-area.center.dx, -area.center.dy);
    }
    final spacing = area.height / (lines + 1);
    for (var i = 1; i <= lines; i++) {
      final y = area.top + spacing * i;
      canvas.drawLine(
        Offset(area.left, y),
        Offset(area.right, y),
        paint,
      );
    }
    canvas.restore();
  }

  // ═══════════════════════════════════════════════════════════════
  //  DMG  — Original Game Boy (1989)
  // ═══════════════════════════════════════════════════════════════
  void _paintDMG(Canvas canvas, Size size) {
    const bodyColor = Color(0xFFC8C4BE); // warm grey
    const bodyHighlight = Color(0xFFDAD7D2);
    const bodyShadow = Color(0xFF9E9B96);
    const screenBezel = Color(0xFF4A4560); // dark purple-grey
    const screenBezelInner = Color(0xFF5C576D);
    const dpadColor = Color(0xFF2A2A2E);
    const btnColorA = Color(0xFF8C1A4A);
    const btnColorB = Color(0xFF8C1A4A);
    const textColor = Color(0xFF1A1A3A);
    const lineColor = Color(0xFF4A4A60);

    // Body — generous padding around screen
    final body = _bodyRect(
      padLeft: 0.12,
      padRight: 0.12,
      padTop: 0.50,
      padBottom: 1.60,
    );
    _drawBeveledBody(canvas, body,
        body: bodyColor,
        radius: 14,
        highlight: bodyHighlight,
        shadow: bodyShadow);

    // Screen bezel
    final bezelPad = gameRect.width * 0.06;
    final bezel = Rect.fromLTRB(
      gameRect.left - bezelPad,
      gameRect.top - bezelPad * 1.8,
      gameRect.right + bezelPad,
      gameRect.bottom + bezelPad,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(bezel, const Radius.circular(6)),
      Paint()..color = screenBezel,
    );
    // Inner bezel highlight
    final innerBezel = bezel.deflate(2);
    canvas.drawRRect(
      RRect.fromRectAndRadius(innerBezel, const Radius.circular(5)),
      Paint()
        ..color = screenBezelInner
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    // "Nintendo GAME BOY™" text above screen
    final titleY = bezel.top + (bezel.top - body.top) * 0.45 + body.top;
    _drawText(
      canvas,
      'GAME BOY',
      Offset(body.center.dx, titleY),
      fontSize: gameRect.width * 0.07,
      color: textColor,
      weight: FontWeight.w900,
      letterSpacing: 4,
    );

    // Dot / power LED indicator
    final ledCenter = Offset(bezel.left + 6, bezel.top - 8);
    canvas.drawCircle(ledCenter, 3.5, Paint()..color = const Color(0xFFCC3333));

    // Power text
    _drawText(canvas, '●BATTERY', Offset(ledCenter.dx + 30, ledCenter.dy),
        fontSize: 6, color: textColor.withAlpha(120), letterSpacing: 0.5);

    // ─── Controls below screen ───
    final controlTop = gameRect.bottom + gameRect.height * 0.25;
    final controlCenter = body.center.dx;

    // D-Pad (left side)
    final dpadCenter =
        Offset(controlCenter - gameRect.width * 0.28, controlTop);
    _drawDPad(canvas, dpadCenter, gameRect.width * 0.28, dpadColor);

    // A & B buttons (right side)
    final btnRadius = gameRect.width * 0.085;
    final abCenterX = controlCenter + gameRect.width * 0.22;
    final aCenter = Offset(abCenterX + btnRadius * 1.3, controlTop - btnRadius * 0.5);
    final bCenter = Offset(abCenterX - btnRadius * 1.3, controlTop + btnRadius * 0.5);
    _drawRoundButton(canvas, aCenter, btnRadius, btnColorA,
        label: 'A', labelSize: btnRadius * 0.7);
    _drawRoundButton(canvas, bCenter, btnRadius, btnColorB,
        label: 'B', labelSize: btnRadius * 0.7);

    // A/B labels
    _drawText(canvas, 'B', Offset(bCenter.dx, bCenter.dy + btnRadius + 8),
        fontSize: 7, color: textColor.withAlpha(100));
    _drawText(canvas, 'A', Offset(aCenter.dx, aCenter.dy + btnRadius + 8),
        fontSize: 7, color: textColor.withAlpha(100));

    // Start / Select — pill-shaped
    final ssY = controlTop + gameRect.height * 0.55;
    final ssW = gameRect.width * 0.15;
    final ssH = gameRect.width * 0.045;
    final ssPaint = Paint()..color = dpadColor.withAlpha(200);

    // Angled placement
    canvas.save();
    canvas.translate(controlCenter, ssY);
    canvas.rotate(-0.45);
    // SELECT
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(-ssW * 0.8, 0), width: ssW, height: ssH),
          Radius.circular(ssH)),
      ssPaint,
    );
    // START
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(ssW * 0.8, 0), width: ssW, height: ssH),
          Radius.circular(ssH)),
      ssPaint,
    );
    canvas.restore();

    _drawText(canvas, 'SELECT', Offset(controlCenter - ssW * 0.6, ssY + 14),
        fontSize: 5, color: textColor.withAlpha(80), letterSpacing: 1);
    _drawText(canvas, 'START', Offset(controlCenter + ssW * 0.6, ssY + 14),
        fontSize: 5, color: textColor.withAlpha(80), letterSpacing: 1);

    // Speaker grille (bottom-right)
    final grille = Rect.fromLTWH(
      body.right - gameRect.width * 0.38,
      body.bottom - gameRect.height * 0.65,
      gameRect.width * 0.24,
      gameRect.height * 0.40,
    );
    _drawSpeakerGrille(canvas, grille,
        color: lineColor.withAlpha(90), lines: 6, angle: -0.52);

    // "Nintendo" text at very top
    _drawText(
      canvas,
      'Nintendo®',
      Offset(body.center.dx, body.top + 14),
      fontSize: 8,
      color: textColor.withAlpha(80),
      weight: FontWeight.w500,
      letterSpacing: 0.5,
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  Pocket  — Game Boy Pocket (1996)
  // ═══════════════════════════════════════════════════════════════
  void _paintPocket(Canvas canvas, Size size) {
    const bodyColor = Color(0xFFD4D0CA); // silver-grey
    const bodyHighlight = Color(0xFFE6E3DE);
    const bodyShadow = Color(0xFFABA8A3);
    const screenBezel = Color(0xFF3A3A42);
    const dpadColor = Color(0xFF3A3A3E);
    const btnColor = Color(0xFF3A3A3E);
    const textColor = Color(0xFF2A2A38);

    final body = _bodyRect(
      padLeft: 0.10,
      padRight: 0.10,
      padTop: 0.40,
      padBottom: 1.45,
    );
    _drawBeveledBody(canvas, body,
        body: bodyColor,
        radius: 12,
        highlight: bodyHighlight,
        shadow: bodyShadow);

    // Screen bezel — cleaner, thinner
    final bezelPad = gameRect.width * 0.05;
    final bezel = Rect.fromLTRB(
      gameRect.left - bezelPad,
      gameRect.top - bezelPad * 1.5,
      gameRect.right + bezelPad,
      gameRect.bottom + bezelPad * 0.8,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(bezel, const Radius.circular(5)),
      Paint()..color = screenBezel,
    );

    // Title
    final titleY = bezel.top + (bezel.top - body.top) * 0.40 + body.top;
    _drawText(
      canvas,
      'GAME BOY',
      Offset(body.center.dx - gameRect.width * 0.08, titleY),
      fontSize: gameRect.width * 0.06,
      color: textColor,
      weight: FontWeight.w900,
      letterSpacing: 3,
    );
    _drawText(
      canvas,
      'pocket',
      Offset(body.center.dx + gameRect.width * 0.24, titleY + 2),
      fontSize: gameRect.width * 0.035,
      color: textColor.withAlpha(140),
      weight: FontWeight.w400,
      letterSpacing: 1,
    );

    // LED
    canvas.drawCircle(
      Offset(bezel.left + 5, bezel.top - 6),
      2.5,
      Paint()..color = const Color(0xFFDD4444),
    );

    // Controls
    final controlTop = gameRect.bottom + gameRect.height * 0.22;
    final cx = body.center.dx;

    // D-pad
    _drawDPad(canvas, Offset(cx - gameRect.width * 0.26, controlTop),
        gameRect.width * 0.25, dpadColor);

    // A / B
    final br = gameRect.width * 0.075;
    final abX = cx + gameRect.width * 0.22;
    _drawRoundButton(
        canvas, Offset(abX + br * 1.3, controlTop - br * 0.4), br, btnColor,
        label: 'A', labelSize: br * 0.65);
    _drawRoundButton(
        canvas, Offset(abX - br * 1.3, controlTop + br * 0.4), br, btnColor,
        label: 'B', labelSize: br * 0.65);

    // Start / Select
    final ssY = controlTop + gameRect.height * 0.50;
    final ssW = gameRect.width * 0.13;
    final ssH = gameRect.width * 0.04;
    final ssPaint = Paint()..color = dpadColor.withAlpha(180);
    canvas.save();
    canvas.translate(cx, ssY);
    canvas.rotate(-0.45);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(-ssW * 0.8, 0), width: ssW, height: ssH),
          Radius.circular(ssH)),
      ssPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(ssW * 0.8, 0), width: ssW, height: ssH),
          Radius.circular(ssH)),
      ssPaint,
    );
    canvas.restore();
    _drawText(canvas, 'SELECT', Offset(cx - ssW * 0.6, ssY + 12),
        fontSize: 4.5, color: textColor.withAlpha(70));
    _drawText(canvas, 'START', Offset(cx + ssW * 0.6, ssY + 12),
        fontSize: 4.5, color: textColor.withAlpha(70));

    // Speaker
    final grille = Rect.fromLTWH(
      body.right - gameRect.width * 0.35,
      body.bottom - gameRect.height * 0.55,
      gameRect.width * 0.22,
      gameRect.height * 0.35,
    );
    _drawSpeakerGrille(canvas, grille,
        color: bodyShadow.withAlpha(80), lines: 5, angle: -0.52);
  }

  // ═══════════════════════════════════════════════════════════════
  //  Color  — Game Boy Color (1998)
  // ═══════════════════════════════════════════════════════════════
  void _paintColor(Canvas canvas, Size size) {
    const bodyTop = Color(0xFF6A5ACD); // slate blue / purple
    const bodyBottom = Color(0xFF5040B0);
    const bodyHighlight = Color(0xFF8070E0);
    const bodyShadow = Color(0xFF3A3080);
    const screenBezel = Color(0xFF2A2A35);
    const dpadColor = Color(0xFF1E1E24);
    const btnColorA = Color(0xFFBB3366);
    const btnColorB = Color(0xFFBB3366);
    const textColor = Color(0xFFE8E0FF);
    const labelColor = Color(0xFF1A1A2A);

    final body = _bodyRect(
      padLeft: 0.11,
      padRight: 0.11,
      padTop: 0.45,
      padBottom: 1.50,
    );

    // Gradient body
    final bodyRRect =
        RRect.fromRectAndRadius(body, const Radius.circular(14));
    canvas.drawRRect(
      bodyRRect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [bodyTop, bodyBottom],
        ).createShader(body),
    );
    // Bevel
    canvas.save();
    canvas.clipRRect(bodyRRect);
    canvas.drawRRect(bodyRRect.shift(const Offset(-1, -1)),
        Paint()..color = bodyHighlight..style = PaintingStyle.stroke..strokeWidth = 2);
    canvas.drawRRect(bodyRRect.shift(const Offset(1.5, 1.5)),
        Paint()..color = bodyShadow..style = PaintingStyle.stroke..strokeWidth = 2.5);
    canvas.restore();

    // Screen bezel
    final bezelPad = gameRect.width * 0.06;
    final bezel = Rect.fromLTRB(
      gameRect.left - bezelPad,
      gameRect.top - bezelPad * 2.0,
      gameRect.right + bezelPad,
      gameRect.bottom + bezelPad,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(bezel, const Radius.circular(6)),
      Paint()..color = screenBezel,
    );

    // COLOR text stripe in bezel header
    final stripeH = bezelPad * 1.0;
    final stripeRect = Rect.fromLTWH(
      bezel.left + 4,
      bezel.top + 3,
      bezel.width - 8,
      stripeH,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(stripeRect, const Radius.circular(3)),
      Paint()
        ..shader = const LinearGradient(
          colors: [
            Color(0xFFFF4444),
            Color(0xFFFFAA22),
            Color(0xFF44CC44),
            Color(0xFF4488FF),
          ],
        ).createShader(stripeRect),
    );

    // Title above
    final titleY = bezel.top + (bezel.top - body.top) * 0.42 + body.top;
    _drawText(
      canvas,
      'GAME BOY',
      Offset(body.center.dx, titleY),
      fontSize: gameRect.width * 0.065,
      color: textColor,
      weight: FontWeight.w900,
      letterSpacing: 3,
    );

    // "COLOR" small
    _drawText(
      canvas,
      'COLOR',
      Offset(body.center.dx, titleY + gameRect.width * 0.06),
      fontSize: gameRect.width * 0.032,
      color: textColor.withAlpha(180),
      weight: FontWeight.w500,
      letterSpacing: 5,
    );

    // IR port indicator (top center)
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
            center: Offset(body.center.dx, body.top + 5),
            width: 14,
            height: 6),
        const Radius.circular(3),
      ),
      Paint()..color = const Color(0xFF2A0020),
    );

    // Controls
    final controlTop = gameRect.bottom + gameRect.height * 0.24;
    final cx = body.center.dx;

    _drawDPad(canvas, Offset(cx - gameRect.width * 0.27, controlTop),
        gameRect.width * 0.26, dpadColor);

    final br = gameRect.width * 0.08;
    final abX = cx + gameRect.width * 0.22;
    _drawRoundButton(
        canvas, Offset(abX + br * 1.3, controlTop - br * 0.4), br, btnColorA,
        label: 'A', labelSize: br * 0.65, labelColor: Colors.white60);
    _drawRoundButton(
        canvas, Offset(abX - br * 1.3, controlTop + br * 0.4), br, btnColorB,
        label: 'B', labelSize: br * 0.65, labelColor: Colors.white60);

    // Start / Select
    final ssY = controlTop + gameRect.height * 0.52;
    final ssW = gameRect.width * 0.13;
    final ssH = gameRect.width * 0.04;
    final ssPaint = Paint()..color = dpadColor.withAlpha(200);
    canvas.save();
    canvas.translate(cx, ssY);
    canvas.rotate(-0.45);
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromCenter(
                center: Offset(-ssW * 0.8, 0), width: ssW, height: ssH),
            Radius.circular(ssH)),
        ssPaint);
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromCenter(
                center: Offset(ssW * 0.8, 0), width: ssW, height: ssH),
            Radius.circular(ssH)),
        ssPaint);
    canvas.restore();
    _drawText(canvas, 'SELECT', Offset(cx - ssW * 0.6, ssY + 12),
        fontSize: 4.5, color: labelColor.withAlpha(100));
    _drawText(canvas, 'START', Offset(cx + ssW * 0.6, ssY + 12),
        fontSize: 4.5, color: labelColor.withAlpha(100));

    // Speaker
    final grille = Rect.fromLTWH(
      body.right - gameRect.width * 0.36,
      body.bottom - gameRect.height * 0.55,
      gameRect.width * 0.22,
      gameRect.height * 0.35,
    );
    _drawSpeakerGrille(canvas, grille,
        color: bodyShadow.withAlpha(70), lines: 5, angle: -0.52);
  }

  // ═══════════════════════════════════════════════════════════════
  //  Advance  — Game Boy Advance (2001) — wide landscape shell
  // ═══════════════════════════════════════════════════════════════
  void _paintAdvance(Canvas canvas, Size size) {
    const bodyColor = Color(0xFF504094);
    const bodyHighlight = Color(0xFF6A58B0);
    const bodyShadow = Color(0xFF302860);
    const screenBezel = Color(0xFF1A1A24);
    const dpadColor = Color(0xFF1E1E26);
    const btnColor = Color(0xFF6A4AA0);
    const textColor = Color(0xFFD0C8F0);

    // Wide body around game (landscape-appropriate)
    final body = _bodyRect(
      padLeft: 0.60,
      padRight: 0.60,
      padTop: 0.30,
      padBottom: 0.50,
    );
    // Clamp to screen bounds
    final clampedBody = Rect.fromLTRB(
      math.max(0, body.left),
      math.max(0, body.top),
      math.min(size.width, body.right),
      math.min(size.height, body.bottom),
    );

    // Rounded wide shell
    final rr = RRect.fromRectAndRadius(clampedBody, const Radius.circular(20));
    canvas.drawRRect(
      rr,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [bodyHighlight, bodyColor, bodyShadow],
          stops: const [0.0, 0.5, 1.0],
        ).createShader(clampedBody),
    );
    // Bevel
    canvas.save();
    canvas.clipRRect(rr);
    canvas.drawRRect(rr.shift(const Offset(-1, -1)),
        Paint()..color = bodyHighlight..style = PaintingStyle.stroke..strokeWidth = 1.5);
    canvas.drawRRect(rr.shift(const Offset(1.5, 1.5)),
        Paint()..color = bodyShadow..style = PaintingStyle.stroke..strokeWidth = 2);
    canvas.restore();

    // Shoulder buttons (top corners)
    final shoulderW = gameRect.width * 0.22;
    final shoulderH = gameRect.height * 0.12;
    final shoulderColor = bodyShadow;
    // L
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
            clampedBody.left + 8, clampedBody.top - shoulderH * 0.6,
            shoulderW, shoulderH),
        const Radius.circular(6),
      ),
      Paint()..color = shoulderColor,
    );
    _drawText(canvas, 'L',
        Offset(clampedBody.left + 8 + shoulderW / 2, clampedBody.top - shoulderH * 0.1),
        fontSize: 8, color: textColor.withAlpha(120));
    // R
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
            clampedBody.right - 8 - shoulderW, clampedBody.top - shoulderH * 0.6,
            shoulderW, shoulderH),
        const Radius.circular(6),
      ),
      Paint()..color = shoulderColor,
    );
    _drawText(canvas, 'R',
        Offset(clampedBody.right - 8 - shoulderW / 2, clampedBody.top - shoulderH * 0.1),
        fontSize: 8, color: textColor.withAlpha(120));

    // Screen bezel
    final bezelPad = gameRect.height * 0.08;
    final bezel = gameRect.inflate(bezelPad);
    canvas.drawRRect(
      RRect.fromRectAndRadius(bezel, const Radius.circular(4)),
      Paint()..color = screenBezel,
    );

    // Title above screen
    _drawText(
      canvas,
      'GAME BOY ADVANCE',
      Offset(gameRect.center.dx, bezel.top - gameRect.height * 0.08),
      fontSize: gameRect.height * 0.07,
      color: textColor.withAlpha(200),
      weight: FontWeight.w800,
      letterSpacing: 3,
    );

    // Controls — D-pad on left, face buttons on right
    final cy = gameRect.center.dy + gameRect.height * 0.05;

    // D-pad (left wing)
    final leftWingCx = (clampedBody.left + gameRect.left) / 2;
    _drawDPad(canvas, Offset(leftWingCx, cy),
        gameRect.height * 0.45, dpadColor);

    // A / B buttons (right wing)
    final rightWingCx = (gameRect.right + clampedBody.right) / 2;
    final abr = gameRect.height * 0.12;
    _drawRoundButton(canvas,
        Offset(rightWingCx + abr * 1.2, cy - abr * 0.4), abr, btnColor,
        label: 'A', labelSize: abr * 0.6, labelColor: textColor.withAlpha(150));
    _drawRoundButton(canvas,
        Offset(rightWingCx - abr * 1.2, cy + abr * 0.4), abr, btnColor,
        label: 'B', labelSize: abr * 0.6, labelColor: textColor.withAlpha(150));

    // Start / Select (small pills below screen)
    final ssY = bezel.bottom + gameRect.height * 0.15;
    final ssW = gameRect.width * 0.08;
    final ssH = gameRect.height * 0.06;
    final ssPaint = Paint()..color = dpadColor.withAlpha(180);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromCenter(
              center: Offset(gameRect.center.dx - ssW, ssY),
              width: ssW,
              height: ssH),
          Radius.circular(ssH)),
      ssPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromCenter(
              center: Offset(gameRect.center.dx + ssW, ssY),
              width: ssW,
              height: ssH),
          Radius.circular(ssH)),
      ssPaint,
    );
    _drawText(canvas, 'SELECT',
        Offset(gameRect.center.dx - ssW, ssY + ssH + 6),
        fontSize: 4, color: textColor.withAlpha(80));
    _drawText(canvas, 'START',
        Offset(gameRect.center.dx + ssW, ssY + ssH + 6),
        fontSize: 4, color: textColor.withAlpha(80));

    // Speaker holes (right side, grid pattern)
    final speakerCx = rightWingCx + gameRect.width * 0.12;
    final speakerCy = cy + gameRect.height * 0.35;
    final dotR = 1.5;
    final dotSpacing = 6.0;
    final dotPaint = Paint()..color = bodyShadow;
    for (var row = 0; row < 3; row++) {
      for (var col = 0; col < 4; col++) {
        canvas.drawCircle(
          Offset(
            speakerCx + (col - 1.5) * dotSpacing,
            speakerCy + (row - 1) * dotSpacing,
          ),
          dotR,
          dotPaint,
        );
      }
    }

    // Power LED
    canvas.drawCircle(
      Offset(clampedBody.left + 14, cy - gameRect.height * 0.25),
      2.5,
      Paint()..color = const Color(0xFF44CC44),
    );
  }
}
