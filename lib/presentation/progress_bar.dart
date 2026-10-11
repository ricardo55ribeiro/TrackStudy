import 'package:flutter/material.dart';
import '../domain/models.dart';

class WeeklyProgressBar extends StatelessWidget {
  final WeeklyProgress progress;
  const WeeklyProgressBar({super.key, required this.progress});
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final status = switch (progress.state) {
      ProgressState.belowFloor => 'Below weekly minimum',
      ProgressState.floorProtected => 'Minimum protected',
      ProgressState.targetReached => 'Planned target reached',
      ProgressState.exceeded => 'Planned target exceeded',
    };
    final description =
        '${progress.config.name}: ${progress.value}. Minimum ${Amount.format(progress.config.floor)}. $status';
    return Tooltip(
      message: description,
      child: Semantics(
        label: description,
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: progress.fraction),
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          builder: (context, fraction, child) => CustomPaint(
            painter: FloorProgressPainter(
              fraction,
              progress.floorFraction,
              dark,
            ),
            size: const Size(double.infinity, 30),
          ),
        ),
      ),
    );
  }
}

class FloorProgressPainter extends CustomPainter {
  final double fraction, floor;
  final bool dark;
  FloorProgressPainter(this.fraction, this.floor, this.dark);
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final round = RRect.fromRectAndRadius(rect, const Radius.circular(7));
    canvas.save();
    canvas.clipRRect(round);
    canvas.drawRect(
      rect,
      Paint()..color = dark ? const Color(0xff232c38) : const Color(0xffe9edf3),
    );
    final floorX = size.width * floor;
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, floorX, size.height));
    final hatch = Paint()
      ..color = (dark ? Colors.white : const Color(0xff506681)).withValues(
        alpha: 0.14,
      )
      ..strokeWidth = 1;
    for (double x = -size.height; x < floorX + size.height; x += 9) {
      canvas.drawLine(
        Offset(x, size.height),
        Offset(x + size.height, 0),
        hatch,
      );
    }
    canvas.restore();
    if (fraction > 0) {
      canvas.drawRect(
        Rect.fromLTWH(0, 0, size.width * fraction, size.height),
        Paint()
          ..shader = const LinearGradient(
            colors: [Color(0xff347de1), Color(0xff4c94f5)],
          ).createShader(rect),
      );
      canvas.save();
      canvas.clipRect(
        Rect.fromLTWH(
          0,
          0,
          floorX.clamp(0, size.width * fraction),
          size.height,
        ),
      );
      for (double x = -size.height; x < floorX + size.height; x += 9) {
        canvas.drawLine(
          Offset(x, size.height),
          Offset(x + size.height, 0),
          Paint()
            ..color = Colors.white.withValues(alpha: 0.075)
            ..strokeWidth = 1,
        );
      }
      canvas.restore();
    }
    final markerX = floorX.clamp(1.0, size.width - 1);
    for (double y = 3; y < size.height - 2; y += 6) {
      canvas.drawLine(
        Offset(markerX, y),
        Offset(markerX, y + 3),
        Paint()
          ..color = (dark ? Colors.white : const Color(0xff102c50)).withValues(
            alpha: 0.85,
          )
          ..strokeWidth = 1.3,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(FloorProgressPainter old) =>
      old.fraction != fraction || old.floor != floor || old.dark != dark;
}
