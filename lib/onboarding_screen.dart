import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'main_screen.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with TickerProviderStateMixin {

  // ─── Page Data ─────────────────────────────────────────────────────────────
  static const _pages = [
    _OnboardingPage(
      emoji: '🔥',
      title: 'FIRE-\nCRAFTED',
      subtitle: 'Every dish kissed\nby real flame.',
      accent: Color(0xFFFF4500),
      tag: 'AUTHENTIC BBQ',
    ),
    _OnboardingPage(
      emoji: '🥩',
      title: 'PRIME\nCUTS',
      subtitle: 'Hand-selected meats,\naged to perfection.',
      accent: Color(0xFFDC2626),
      tag: 'PREMIUM QUALITY',
    ),
    _OnboardingPage(
      emoji: '🚀',
      title: 'ORDER\nIN SECONDS',
      subtitle: 'Hot food, cold drinks,\ndelivered fast.',
      accent: Color(0xFFEA580C),
      tag: 'LIGHTNING FAST',
    ),
  ];

  int _current = 0;
  bool _animating = false;

  // ─── Single entry controller (created once, reset/forward on each page) ───
  late final AnimationController _entryCtrl;
  late final Animation<double>   _emojiScale;
  late final Animation<double>   _emojiOpacity;
  late final Animation<Offset>   _titleSlide;
  late final Animation<double>   _titleOpacity;
  late final Animation<Offset>   _subtitleSlide;
  late final Animation<double>   _subtitleOpacity;
  late final Animation<double>   _tagOpacity;

  // ─── Ember particles ───────────────────────────────────────────────────────
  late final AnimationController _emberCtrl;
  final List<_Ember> _embers = [];
  final _rng = math.Random();

  // ─── CTA press ─────────────────────────────────────────────────────────────
  late final AnimationController _btnCtrl;
  late final Animation<double>   _btnScale;

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);

    // Entry controller — ONE instance, reused every page
    _entryCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 850),
    );

    _emojiScale = Tween<double>(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(
        parent: _entryCtrl,
        curve: const Interval(0.0, 0.55, curve: Curves.elasticOut),
      ),
    );
    _emojiOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _entryCtrl,
        curve: const Interval(0.0, 0.35, curve: Curves.easeIn),
      ),
    );
    _titleSlide = Tween<Offset>(
      begin: const Offset(0, 0.45),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _entryCtrl,
      curve: const Interval(0.25, 0.70, curve: Curves.easeOut),
    ));
    _titleOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _entryCtrl,
        curve: const Interval(0.25, 0.60, curve: Curves.easeIn),
      ),
    );
    _subtitleSlide = Tween<Offset>(
      begin: const Offset(0, 0.4),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _entryCtrl,
      curve: const Interval(0.45, 0.85, curve: Curves.easeOut),
    ));
    _subtitleOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _entryCtrl,
        curve: const Interval(0.45, 0.80, curve: Curves.easeIn),
      ),
    );
    _tagOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _entryCtrl,
        curve: const Interval(0.60, 1.0, curve: Curves.easeIn),
      ),
    );

    // Embers
    _emberCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..addListener(_updateEmbers)..repeat();
    _spawnEmbers();

    // Button press feedback
    _btnCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
    );
    _btnScale = Tween<double>(begin: 1.0, end: 0.94).animate(
      CurvedAnimation(parent: _btnCtrl, curve: Curves.easeInOut),
    );

    // Start first page
    _entryCtrl.forward();
  }

  @override
  void dispose() {
    _entryCtrl.dispose();
    _emberCtrl.dispose();
    _btnCtrl.dispose();
    super.dispose();
  }

  // ─── Embers ────────────────────────────────────────────────────────────────
  void _spawnEmbers() {
    _embers.clear();
    for (int i = 0; i < 18; i++) {
      _embers.add(_Ember(
        x:       _rng.nextDouble(),
        y:       0.6 + _rng.nextDouble() * 0.4,
        size:    2.0 + _rng.nextDouble() * 4,
        speed:   0.006 + _rng.nextDouble() * 0.012,
        drift:   (_rng.nextDouble() - 0.5) * 0.003,
        phase:   _rng.nextDouble(),
        opacity: 0.4 + _rng.nextDouble() * 0.6,
      ));
    }
  }

  void _updateEmbers() {
    for (final e in _embers) {
      e.phase += e.speed;
      e.x     += e.drift;
      if (e.phase >= 1.0) {
        e.phase = 0;
        e.x     = _rng.nextDouble();
        e.drift = (_rng.nextDouble() - 0.5) * 0.003;
      }
      e.y = 0.85 - e.phase * 0.9;
    }
    if (mounted) setState(() {});
  }

  // ─── Navigation ────────────────────────────────────────────────────────────
  Future<void> _goToPage(int index) async {
    if (_animating || index == _current) return;
    _animating = true;

    // Animate content out
    await _entryCtrl.reverse();
    if (!mounted) return;

    // Swap page
    setState(() => _current = index);

    // Animate content in
    _entryCtrl.reset();
    await _entryCtrl.forward();

    _animating = false;
  }

  Future<void> _onNext() async {
    _btnCtrl.forward().then((_) => _btnCtrl.reverse());
    if (_current < _pages.length - 1) {
      await _goToPage(_current + 1);
    } else {
      await _finishOnboarding();
    }
  }

  Future<void> _finishOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('onboarding_done', true);

    // ← NEW: نشوف لو فيه pending deep link
    final pendingUrl = prefs.getString('pending_deep_link');
    if (pendingUrl != null) {
      await prefs.remove('pending_deep_link');
    }

    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 600),
        pageBuilder: (_, __, ___) => MainScreen(initialUrl: pendingUrl), // ← NEW
        transitionsBuilder: (_, anim, __, child) => FadeTransition(
          opacity: CurvedAnimation(parent: anim, curve: Curves.easeIn),
          child: child,
        ),
      ),
    );
  }

  // ─── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final page = _pages[_current];
    final size = MediaQuery.of(context).size;

    return Scaffold(
      backgroundColor: const Color(0xFF080808),
      body: Stack(
        children: [
          // Background radial glow — animates color on page change
          AnimatedContainer(
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeInOut,
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.center,
                radius: 1.0,
                colors: [
                  page.accent.withOpacity(0.20),
                  const Color(0xFF080808),
                ],
              ),
            ),
          ),

          // Ember particles
          CustomPaint(
            size: size,
            painter: _EmberPainter(embers: _embers, color: page.accent),
          ),

          // Content
          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Skip ──────────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.only(top: 8, right: 20),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: _current < _pages.length - 1
                        ? TextButton(
                      onPressed: _finishOnboarding,
                      child: Text(
                        'SKIP',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.35),
                          fontSize: 12,
                          letterSpacing: 2.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    )
                        : const SizedBox(height: 44),
                  ),
                ),

                // ── Tag pill ──────────────────────────────────────────
                const SizedBox(height: 8),
                AnimatedBuilder(
                  animation: _tagOpacity,
                  builder: (_, __) => Opacity(
                    opacity: _tagOpacity.value,
                    child: Center(
                      child: _TagPill(label: page.tag, color: page.accent),
                    ),
                  ),
                ),

                // ── Emoji ─────────────────────────────────────────────
                Expanded(
                  flex: 5,
                  child: Center(
                    child: AnimatedBuilder(
                      animation: _entryCtrl,
                      builder: (_, __) => Opacity(
                        opacity: _emojiOpacity.value,
                        child: Transform.scale(
                          scale: _emojiScale.value,
                          child: _EmojiDisplay(
                            emoji: page.emoji,
                            accent: page.accent,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                // ── Title ─────────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: AnimatedBuilder(
                    animation: _entryCtrl,
                    builder: (_, __) => Opacity(
                      opacity: _titleOpacity.value,
                      child: SlideTransition(
                        position: _titleSlide,
                        child: ShaderMask(
                          shaderCallback: (bounds) => LinearGradient(
                            colors: [
                              Colors.white,
                              page.accent.withOpacity(0.85),
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ).createShader(bounds),
                          child: Text(
                            page.title,
                            textAlign: TextAlign.left,
                            style: const TextStyle(
                              fontSize: 58,
                              fontWeight: FontWeight.w900,
                              color: Colors.white,
                              height: 0.92,
                              letterSpacing: -1.5,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                // ── Subtitle ──────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: AnimatedBuilder(
                    animation: _entryCtrl,
                    builder: (_, __) => Opacity(
                      opacity: _subtitleOpacity.value,
                      child: SlideTransition(
                        position: _subtitleSlide,
                        child: Text(
                          page.subtitle,
                          textAlign: TextAlign.left,
                          style: TextStyle(
                            fontSize: 17,
                            color: Colors.white.withOpacity(0.55),
                            height: 1.55,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 36),

                // ── Dots ──────────────────────────────────────────────
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(
                    _pages.length,
                        (i) => _DotIndicator(
                      active: i == _current,
                      color: page.accent,
                      onTap: () => _goToPage(i),
                    ),
                  ),
                ),

                const SizedBox(height: 28),

                // ── CTA ───────────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: AnimatedBuilder(
                    animation: _btnScale,
                    builder: (_, child) =>
                        Transform.scale(scale: _btnScale.value, child: child),
                    child: _CTAButton(
                      label: _current == _pages.length - 1
                          ? "LET'S EAT 🔥"
                          : 'NEXT',
                      accent: page.accent,
                      isLast: _current == _pages.length - 1,
                      onTap: _onNext,
                    ),
                  ),
                ),

                const SizedBox(height: 36),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Data Model ──────────────────────────────────────────────────────────────

class _OnboardingPage {
  final String emoji;
  final String title;
  final String subtitle;
  final Color  accent;
  final String tag;
  const _OnboardingPage({
    required this.emoji,
    required this.title,
    required this.subtitle,
    required this.accent,
    required this.tag,
  });
}

// ─── Ember ───────────────────────────────────────────────────────────────────

class _Ember {
  double x, y, size, speed, drift, phase, opacity;
  _Ember({
    required this.x, required this.y, required this.size,
    required this.speed, required this.drift,
    required this.phase, required this.opacity,
  });
}

class _EmberPainter extends CustomPainter {
  final List<_Ember> embers;
  final Color color;
  _EmberPainter({required this.embers, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    for (final e in embers) {
      final p     = e.phase.clamp(0.0, 1.0);
      final alpha = (e.opacity * (1.0 - p) * 255).toInt().clamp(0, 255);
      canvas.drawCircle(
        Offset(e.x * size.width, e.y * size.height),
        e.size * (1.0 - p * 0.5),
        Paint()
          ..color      = color.withAlpha(alpha)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, e.size * 0.8),
      );
    }
  }

  @override
  bool shouldRepaint(_EmberPainter old) => true;
}

// ─── Emoji Display ───────────────────────────────────────────────────────────

class _EmojiDisplay extends StatelessWidget {
  final String emoji;
  final Color  accent;
  const _EmojiDisplay({required this.emoji, required this.accent});

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Container(
          width: 220, height: 220,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: accent.withOpacity(0.18),
                blurRadius: 80, spreadRadius: 20,
              ),
            ],
          ),
        ),
        CustomPaint(
          size: const Size(170, 170),
          painter: _RingPainter(color: accent),
        ),
        Container(
          width: 130, height: 130,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFF0F0F0F),
            border: Border.all(color: accent.withOpacity(0.35), width: 1.5),
            boxShadow: [
              BoxShadow(
                color: accent.withOpacity(0.28),
                blurRadius: 30, spreadRadius: 2,
              ),
            ],
          ),
        ),
        Text(emoji, style: const TextStyle(fontSize: 68)),
      ],
    );
  }
}

class _RingPainter extends CustomPainter {
  final Color color;
  _RingPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;
    const sides  = 8;

    final path = Path();
    for (int i = 0; i <= sides; i++) {
      final angle = (i * 2 * math.pi / sides) - math.pi / 2;
      final pt = Offset(
        center.dx + radius * math.cos(angle),
        center.dy + radius * math.sin(angle),
      );
      i == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color       = color.withOpacity(0.22)
        ..style       = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );

    canvas.drawCircle(
      center, radius + 14,
      Paint()
        ..color       = color.withOpacity(0.10)
        ..style       = PaintingStyle.stroke
        ..strokeWidth = 0.8,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.color != color;
}

// ─── Tag Pill ────────────────────────────────────────────────────────────────

class _TagPill extends StatelessWidget {
  final String label;
  final Color  color;
  const _TagPill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: color.withOpacity(0.12),
        border: Border.all(color: color.withOpacity(0.40), width: 1),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          letterSpacing: 3,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

// ─── Dot Indicator ───────────────────────────────────────────────────────────

class _DotIndicator extends StatelessWidget {
  final bool         active;
  final Color        color;
  final VoidCallback onTap;
  const _DotIndicator({
    required this.active,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        width:  active ? 28 : 7,
        height: 7,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          color: active ? color : Colors.white.withOpacity(0.20),
          boxShadow: active
              ? [BoxShadow(color: color.withOpacity(0.55), blurRadius: 8)]
              : [],
        ),
      ),
    );
  }
}

// ─── CTA Button ──────────────────────────────────────────────────────────────

class _CTAButton extends StatelessWidget {
  final String       label;
  final Color        accent;
  final bool         isLast;
  final VoidCallback onTap;
  const _CTAButton({
    required this.label,
    required this.accent,
    required this.isLast,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        height: 58,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            colors: [accent, Color.lerp(accent, Colors.white, 0.15)!],
            begin: Alignment.centerLeft,
            end:   Alignment.centerRight,
          ),
          boxShadow: [
            BoxShadow(
              color:      accent.withOpacity(0.45),
              blurRadius: 24,
              offset:     const Offset(0, 8),
            ),
          ],
        ),
        child: Center(
          child: Text(
            label,
            style: const TextStyle(
              color:         Colors.white,
              fontSize:      15,
              fontWeight:    FontWeight.w800,
              letterSpacing: 3,
            ),
          ),
        ),
      ),
    );
  }
}