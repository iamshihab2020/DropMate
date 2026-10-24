import 'dart:math';

import 'package:flutter/material.dart';

import '../core/crypto.dart';

/// Brand tokens (DESIGN.md).
abstract final class Brand {
  static const drop = Color(0xFF0A6CFF);
  static const lagoon = Color(0xFF00C9B1);
  static const mist = Color(0xFFEEF4FA);
  static const deepwater = Color(0xFF0A1A2F);
  static const harbor = Color(0xFF13263F);
  static const signal = Color(0xFFE5484D);
  static const gradient = LinearGradient(colors: [drop, lagoon], begin: Alignment.topLeft, end: Alignment.bottomRight);
}

const _font = 'Hind Siliguri'; // Latin and Bangla in one family, bundled for offline use

TextStyle _t(double size, double wght, {double height = 1.3, double spacing = 0}) => TextStyle(
  fontFamily: _font,
  fontSize: size,
  height: height,
  letterSpacing: spacing,
  fontWeight: FontWeight.values[((wght / 100).round() - 1).clamp(0, 8)],
);

/// Headline style.
TextStyle display(double size) => _t(size, 700, height: 1.15, spacing: -0.2);

ThemeData buildTheme(Brightness b) {
  final dark = b == Brightness.dark;
  final ink = dark ? const Color(0xFFE6EEF7) : Brand.deepwater;
  final scheme = ColorScheme.fromSeed(seedColor: Brand.drop, brightness: b).copyWith(
    primary: dark ? const Color(0xFF4C93FF) : Brand.drop,
    onPrimary: Colors.white,
    secondary: Brand.lagoon,
    onSecondary: Brand.deepwater,
    error: Brand.signal,
    surface: dark ? Brand.deepwater : Brand.mist,
    onSurface: ink,
    surfaceContainerLowest: dark ? const Color(0xFF07131F) : Colors.white,
    surfaceContainerLow: dark ? const Color(0xFF0F2036) : Colors.white,
    surfaceContainer: dark ? Brand.harbor : const Color(0xFFF6FAFD),
    surfaceContainerHigh: dark ? const Color(0xFF1A3150) : const Color(0xFFE3ECF5),
    surfaceContainerHighest: dark ? const Color(0xFF213A5C) : const Color(0xFFD8E4F0),
    onSurfaceVariant: dark ? const Color(0xFF9DB1C9) : const Color(0xFF4A6079),
    outlineVariant: dark ? const Color(0xFF233A57) : const Color(0xFFD3DEEA),
  );
  final text = TextTheme(
    displaySmall: display(34),
    headlineLarge: display(28),
    headlineMedium: display(24),
    headlineSmall: display(20),
    titleLarge: _t(20, 600),
    titleMedium: _t(16.5, 560),
    titleSmall: _t(14.5, 560),
    bodyLarge: _t(16, 400, height: 1.4),
    bodyMedium: _t(14.5, 400, height: 1.4),
    bodySmall: _t(12.5, 400, height: 1.35),
    labelLarge: _t(14.5, 580),
    labelMedium: _t(12.5, 520),
    labelSmall: _t(11, 480),
  ).apply(bodyColor: ink, displayColor: ink);
  final smallMuted = text.bodySmall!.copyWith(color: scheme.onSurfaceVariant);
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    fontFamily: _font,
    textTheme: text.copyWith(bodySmall: smallMuted),
    scaffoldBackgroundColor: scheme.surface,
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded, // 48 dp targets (PRD §9)
    splashFactory: InkSparkle.splashFactory,
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
      },
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: ink,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleLarge,
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 1, space: 1),
    listTileTheme: ListTileThemeData(
      titleTextStyle: text.titleMedium,
      subtitleTextStyle: smallMuted.copyWith(fontSize: 13.5),
      iconColor: scheme.onSurfaceVariant,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 50),
        padding: const EdgeInsets.symmetric(horizontal: 22),
        textStyle: text.labelLarge,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 50),
        textStyle: text.labelLarge,
        side: BorderSide(color: scheme.outlineVariant, width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(textStyle: text.labelLarge)),
    chipTheme: ChipThemeData(
      side: BorderSide.none,
      backgroundColor: scheme.surfaceContainerHigh,
      labelStyle: text.labelMedium,
      shape: const StadiumBorder(),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: dark ? const Color(0xFFE6EEF7) : Brand.deepwater,
      contentTextStyle: text.bodyMedium!.copyWith(color: dark ? Brand.deepwater : Colors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      titleTextStyle: text.headlineSmall,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerLow,
      hintStyle: text.bodyLarge!.copyWith(color: scheme.onSurfaceVariant),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
    ),
  );
}

bool reducedMotion(BuildContext c) => MediaQuery.maybeDisableAnimationsOf(c) ?? false;

/// Stable avatar color per person, from a palette that sits well next to Drop and Lagoon.
Color avatarColor(String id, ColorScheme s) {
  const tones = [
    Color(0xFF2F6FDB),
    Color(0xFF0E9C8C),
    Color(0xFF6A5AE0),
    Color(0xFFC0487A),
    Color(0xFFD9822B),
    Color(0xFF3E8E41),
    Color(0xFF8A6D3B),
  ];
  return tones[id.codeUnits.fold<int>(0, (a, c) => a + c) % tones.length];
}

/// A person's face: their photo or initial; online people get a Drop→Lagoon ring that breathes.
class Avatar extends StatefulWidget {
  final String id;
  final String name;
  final bool online;
  final double size;
  final String photo; // b64 PNG from the roster, '' for initials
  final bool pulse; // ripple outward while online (Here now strip)
  const Avatar({
    super.key,
    required this.id,
    required this.name,
    this.online = false,
    this.size = 44,
    this.photo = '',
    this.pulse = false,
  });

  @override
  State<Avatar> createState() => _AvatarState();
}

class _AvatarState extends State<Avatar> with SingleTickerProviderStateMixin {
  late final _ripple = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(Avatar old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final run = widget.pulse && widget.online && !reducedMotion(context);
    if (run && !_ripple.isAnimating) _ripple.repeat();
    if (!run && _ripple.isAnimating) _ripple.reset();
  }

  @override
  void dispose() {
    _ripple.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final size = widget.size;
    final ring = size * 0.06 + 1;
    final face = ClipOval(
      child: SizedBox.square(
        dimension: size - ring * 2.6,
        child: widget.photo.isNotEmpty
            ? Image.memory(unb64(widget.photo), fit: BoxFit.cover, gaplessPlayback: true)
            : ColoredBox(
                color: avatarColor(widget.id, s),
                child: Center(
                  child: Text(
                    widget.name.isEmpty ? '?' : widget.name.characters.first.toUpperCase(),
                    style: display(size * 0.42).copyWith(color: Colors.white, height: 1.1),
                  ),
                ),
              ),
      ),
    );
    return Semantics(
      label: '${widget.name}, ${widget.online ? 'online' : 'offline'}',
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _RipplePainter(_ripple, widget.online ? Brand.lagoon : null),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 400),
            padding: EdgeInsets.all(ring * 0.65),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: widget.online ? Brand.gradient : null,
              color: widget.online ? null : s.outlineVariant,
            ),
            child: Container(
              padding: EdgeInsets.all(ring * 0.65),
              decoration: BoxDecoration(shape: BoxShape.circle, color: s.surface),
              child: face,
            ),
          ),
        ),
      ),
    );
  }
}

class _RipplePainter extends CustomPainter {
  final Animation<double> t;
  final Color? color;
  _RipplePainter(this.t, this.color) : super(repaint: t);

  @override
  void paint(Canvas canvas, Size size) {
    if (color == null || t.value == 0) return;
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    for (final phase in [0.0, 0.5]) {
      final v = (t.value + phase) % 1;
      canvas.drawCircle(
        c,
        r + v * r * 0.28,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = color!.withValues(alpha: (1 - v) * 0.55),
      );
    }
  }

  @override
  bool shouldRepaint(_RipplePainter old) => old.color != color;
}

/// The signature: a card fills with Lagoon water as bytes arrive (DESIGN.md "Motion").
class LiquidFill extends StatefulWidget {
  final double? value; // 0..1, null = waiting
  final Widget child;
  final BorderRadius radius;
  final Color color;
  const LiquidFill({
    super.key,
    required this.value,
    required this.child,
    required this.radius,
    this.color = Brand.lagoon,
  });

  @override
  State<LiquidFill> createState() => _LiquidFillState();
}

class _LiquidFillState extends State<LiquidFill> with SingleTickerProviderStateMixin {
  late final _wave = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    reducedMotion(context) ? _wave.stop() : _wave.repeat();
  }

  @override
  void dispose() {
    _wave.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: widget.radius,
    child: TweenAnimationBuilder<double>(
      tween: Tween(end: widget.value ?? 0.04),
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOutCubic,
      builder: (_, level, child) => CustomPaint(
        painter: _WaterPainter(_wave, level, widget.color),
        child: child,
      ),
      child: widget.child,
    ),
  );
}

class _WaterPainter extends CustomPainter {
  final Animation<double> phase;
  final double level;
  final Color color;
  _WaterPainter(this.phase, this.level, this.color) : super(repaint: phase);

  @override
  void paint(Canvas canvas, Size size) {
    if (level <= 0.005) return;
    final top = size.height * (1 - level.clamp(0, 1));
    final amp = level >= 0.999 ? 0.0 : 4.0;
    for (final (shift, alpha) in [(0.0, 0.18), (pi, 0.26)]) {
      final path = Path()..moveTo(0, size.height);
      for (double x = 0; x <= size.width; x += 4) {
        path.lineTo(x, top + sin(x / size.width * 2 * pi + phase.value * 2 * pi + shift) * amp);
      }
      path
        ..lineTo(size.width, size.height)
        ..close();
      canvas.drawPath(path, Paint()..color = color.withValues(alpha: alpha));
    }
  }

  @override
  bool shouldRepaint(_WaterPainter old) => old.level != level || old.color != color;
}

/// Pops a child in with a short overshoot; [delay] staggers siblings.
class PopIn extends StatelessWidget {
  final Widget child;
  final Duration delay;
  const PopIn({super.key, required this.child, this.delay = Duration.zero});

  @override
  Widget build(BuildContext context) {
    if (reducedMotion(context)) return child;
    final total = delay + const Duration(milliseconds: 420);
    final start = delay.inMilliseconds / total.inMilliseconds;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: total,
      builder: (_, v, c) {
        final t = Curves.easeOutBack.transform(((v - start) / (1 - start)).clamp(0, 1));
        return Opacity(opacity: t.clamp(0, 1), child: Transform.scale(scale: 0.6 + 0.4 * t, child: c));
      },
      child: child,
    );
  }
}

/// Brand wordmark: the icon next to "DropMate" in the condensed display face.
class Wordmark extends StatelessWidget {
  final double size;
  const Wordmark({super.key, this.size = 26});

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Image.asset('assets/icon.png', width: size * 1.15, height: size * 1.15),
      SizedBox(width: size * 0.3),
      Text('DropMate', style: display(size)),
    ],
  );
}

String ago(int? ms) {
  if (ms == null) return 'never';
  final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}

String clock(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  final hm = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  if (t.year == now.year && t.month == now.month && t.day == now.day) return hm;
  return '${t.day}/${t.month} $hm';
}
