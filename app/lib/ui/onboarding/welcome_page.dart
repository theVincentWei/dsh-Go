import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../common/fade_in.dart';
import '../fx/metal/metal_text.dart';
import '../shell/wanqi_mark.dart';
import '../theme/theme.dart';
import 'onboarding_scaffold.dart';
import 'usage_notice_row.dart';

/// First screen on a fresh install: the brand's own circular gradient fills the
/// page, the 万器 mark (ring + star) eases in over it, then one sentence and one
/// button. Over the button, the one thing everyone is told on first run:
/// anonymous usage statistics, with their switch.
class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key, required this.onStart});

  final VoidCallback onStart;

  /// The light colorway's controls: the dark theme's periwinkle reversed.
  static const _navy = Color(0xFF22304C);

  /// The brand gradient: the icon's disc, blown up to the page and melting into
  /// it — the icon's navy lit from behind on dark themes, the same colors
  /// reversed (pale page, navy ring) on light ones.
  static const _darkBackdrop = RadialGradient(
    center: Alignment(0, -0.312),
    radius: 1.436,
    colors: [Color(0xFF2C5A93), Color(0xFF1A3F72), Color(0xFF0E2850), Color(0xFF071A38), Color(0xFF050F22)],
    stops: [0, 0.32, 0.62, 0.82, 1],
  );
  static const _lightBackdrop = RadialGradient(
    center: Alignment(0, -0.312),
    radius: 1.282,
    colors: [Color(0xFF96B1DA), Color(0xFFB7CBEA), Color(0xFFD9E5F5), Color(0xFFF2F6FD), Color(0xFFFFFFFF)],
    stops: [0, 0.32, 0.66, 0.86, 1],
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    // The light colorway is the dark one reversed: its controls are the brand
    // navy instead of the light theme's periwinkle.
    final pageTheme = dark
        ? theme
        : theme.copyWith(
            colorScheme: theme.colorScheme.copyWith(primary: _navy, onPrimary: Colors.white),
          );
    return Theme(
      data: pageTheme,
      child: OnboardingScaffold(
        backdrop: dark ? _darkBackdrop : _lightBackdrop,
        children: [
          const Spacer(flex: 5),
          const Center(child: _BrandArrival()),
          const SizedBox(height: 30),
          FadeSlideIn(
            delay: const Duration(milliseconds: 220),
            // The one metal word on this page (Libraries.dev Metal) on the dark
            // colorway; the light one keeps plain ink, as the metal reads grey on
            // a pale page.
            child: dark
                ? MetalText(
                    l10n.shellWelcomeMessage,
                    textAlign: TextAlign.center,
                    color: const Color(0xFFE8EBF2),
                    style: theme.textTheme.displaySmall?.copyWith(height: 1.35),
                  )
                : Text(
                    l10n.shellWelcomeMessage,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.displaySmall?.copyWith(height: 1.35, color: const Color(0xFF16202E)),
                  ),
          ),
          const Spacer(flex: 6),
          const FadeSlideIn(delay: Duration(milliseconds: 280), child: UsageNoticeRow()),
          const SizedBox(height: 20),
          FadeSlideIn(
            delay: const Duration(milliseconds: 320),
            child: FilledButton(onPressed: onStart, child: Text(l10n.shellGetStarted)),
          ),
        ],
      ),
    );
  }
}

/// The 万器 mark over the page's gradient, easing in (fade + a slight grow) the
/// first time the page shows. Still under reduced motion.
class _BrandArrival extends StatefulWidget {
  const _BrandArrival();

  @override
  State<_BrandArrival> createState() => _BrandArrivalState();
}

class _BrandArrivalState extends State<_BrandArrival> with SingleTickerProviderStateMixin {
  late final AnimationController _arrive = AnimationController(vsync: this, duration: AppMotion.slow);
  late final Animation<double> _curve = CurvedAnimation(parent: _arrive, curve: AppMotion.enter);

  static const _mark = 240.0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.reduced(context)) {
      _arrive.value = 1;
    } else if (_arrive.isDismissed) {
      _arrive.forward();
    }
  }

  @override
  void dispose() {
    _arrive.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _mark,
      height: _mark,
      child: AnimatedBuilder(
        animation: _curve,
        builder: (context, child) => Opacity(
          opacity: _curve.value,
          child: Transform.scale(scale: 0.92 + 0.08 * _curve.value, child: child),
        ),
        child: const WanqiMark(size: _mark),
      ),
    );
  }
}
