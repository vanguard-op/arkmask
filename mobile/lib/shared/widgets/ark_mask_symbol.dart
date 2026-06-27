import 'package:flutter/material.dart';

/// The ArkMask abstract mask symbol — two arcs forming eye cutouts rendered
/// with [CustomPainter]. Used on the Splash, Registration, and Login screens.
class ArkMaskSymbol extends StatelessWidget {
  const ArkMaskSymbol({super.key, required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(size, size),
      painter: _MaskPainter(color: color),
    );
  }
}

class _MaskPainter extends CustomPainter {
  _MaskPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.05
      ..strokeCap = StrokeCap.round;

    final w = size.width;
    final h = size.height;

    // Outer mask outline — rounded rectangle.
    final outerRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(w * 0.1, h * 0.15, w * 0.8, h * 0.7),
      Radius.circular(w * 0.12),
    );
    canvas.drawRRect(outerRect, paint);

    // Left eye arc.
    final leftEyePath = Path()
      ..addArc(
        Rect.fromCenter(
          center: Offset(w * 0.33, h * 0.5),
          width: w * 0.28,
          height: h * 0.28,
        ),
        3.14,
        3.14,
      );
    canvas.drawPath(leftEyePath, paint);

    // Right eye arc.
    final rightEyePath = Path()
      ..addArc(
        Rect.fromCenter(
          center: Offset(w * 0.67, h * 0.5),
          width: w * 0.28,
          height: h * 0.28,
        ),
        3.14,
        3.14,
      );
    canvas.drawPath(rightEyePath, paint);
  }

  @override
  bool shouldRepaint(_MaskPainter oldDelegate) => oldDelegate.color != color;
}
