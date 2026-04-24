import 'dart:async';
import 'dart:io';

import 'package:barbecuez/onboarding_screen.dart';
import 'package:flutter/material.dart';

import 'main_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  // ─── Animation Controllers ────────────────────────────────────────────────
  late final AnimationController _logoController;
  late final AnimationController _textController;
  late final AnimationController _pulseController;
  late final AnimationController _progressController;
  late final AnimationController _errorShakeController;

  // ─── Logo Animations ──────────────────────────────────────────────────────
  late final Animation<double> _logoScale;
  late final Animation<double> _logoOpacity;
  late final Animation<double> _logoRotate;

  // ─── Text Animations ──────────────────────────────────────────────────────
  late final Animation<double> _textOpacity;
  late final Animation<Offset> _textSlide;
  late final Animation<double> _taglineOpacity;

  // ─── Pulse (flame glow) ──────────────────────────────────────────────────
  late final Animation<double> _pulse;

  // ─── Progress Bar ─────────────────────────────────────────────────────────
  late final Animation<double> _progress;

  // ─── Error shake ──────────────────────────────────────────────────────────
  late final Animation<double> _shake;

  // ─── State ────────────────────────────────────────────────────────────────
  bool _hasError = false;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _setupAnimations();
    _startSplashSequence();
  }

  void _setupAnimations() {
    // Logo: scale + fade + slight rotation on entry
    _logoController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _logoScale = CurvedAnimation(
      parent: _logoController,
      curve: Curves.elasticOut,
    );
    _logoOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _logoController,
        curve: const Interval(0.0, 0.5, curve: Curves.easeIn),
      ),
    );
    _logoRotate = Tween<double>(begin: -0.08, end: 0.0).animate(
      CurvedAnimation(parent: _logoController, curve: Curves.elasticOut),
    );

    // Text: fade + slide up
    _textController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _textOpacity = CurvedAnimation(
      parent: _textController,
      curve: Curves.easeIn,
    );
    _textSlide = Tween<Offset>(
      begin: const Offset(0, 0.4),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _textController, curve: Curves.easeOut));
    _taglineOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _textController,
        curve: const Interval(0.4, 1.0, curve: Curves.easeIn),
      ),
    );

    // Pulse glow around the logo
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    _pulse = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // Progress bar
    _progressController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );
    _progress = CurvedAnimation(
      parent: _progressController,
      curve: Curves.easeInOut,
    );

    // Error shake
    _errorShakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _shake = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _errorShakeController,
        curve: Curves.elasticIn,
      ),
    );
  }

  Future<void> _startSplashSequence() async {
    // 1. Animate logo in
    await _logoController.forward();

    // 2. Animate text in
    await Future.delayed(const Duration(milliseconds: 100));
    _textController.forward();

    // 3. Start progress bar + check internet simultaneously
    await Future.delayed(const Duration(milliseconds: 300));
    _progressController.forward();

    await Future.delayed(const Duration(milliseconds: 400));
    await _checkInternetAndNavigate();
  }

  Future<void> _checkInternetAndNavigate() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _hasError = false;
    });

    final bool connected = await _isConnected();

    if (!mounted) return;

    if (!connected) {
      // Reset progress and show error
      _progressController.reset();
      setState(() {
        _hasError = true;
        _checking = false;
      });
      _errorShakeController.forward(from: 0);
      return;
    }

    // Wait for progress bar to finish naturally
    await _progressController.forward();
    await Future.delayed(const Duration(milliseconds: 200));

    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 600),
        pageBuilder: (_, __, ___) => const OnboardingScreen(),
        transitionsBuilder: (_, animation, __, child) {
          return FadeTransition(
            opacity: CurvedAnimation(
              parent: animation,
              curve: Curves.easeIn,
            ),
            child: child,
          );
        },
      ),
    );
  }

  Future<bool> _isConnected() async {
    try {
      // Reliable internet check via DNS lookup
      final result = await InternetAddress.lookup('barbecuez.no')
          .timeout(const Duration(seconds: 5));
      return result.isNotEmpty && result.first.rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<void> _retry() async {
    _progressController.reset();
    await _checkInternetAndNavigate();
  }

  @override
  void dispose() {
    _logoController.dispose();
    _textController.dispose();
    _pulseController.dispose();
    _progressController.dispose();
    _errorShakeController.dispose();
    super.dispose();
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      body: Stack(
        children: [
          // ── Background: radial warm glow ──────────────────────────────────
          _buildBackground(),

          // ── Main Content ──────────────────────────────────────────────────
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildLogo(),
                const SizedBox(height: 28),
                _buildBrandText(),
                const SizedBox(height: 56),
                _buildProgressSection(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBackground() {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (_, __) {
        return Container(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(0, -0.2),
              radius: 0.9,
              colors: [
                Color.fromRGBO(180, 20, 20, _pulse.value * 0.22),
                const Color(0xFF0D0D0D),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildLogo() {
    return AnimatedBuilder(
      animation: Listenable.merge([_logoController, _pulse]),
      builder: (_, __) {
        return Opacity(
          opacity: _logoOpacity.value,
          child: Transform.rotate(
            angle: _logoRotate.value,
            child: Transform.scale(
              scale: _logoScale.value,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Outer glow ring
                  Container(
                    width: 140,
                    height: 140,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Color.fromRGBO(220, 38, 38, _pulse.value * 0.5),
                          blurRadius: 40 * _pulse.value,
                          spreadRadius: 10 * _pulse.value,
                        ),
                      ],
                    ),
                  ),
                  // Logo container
                  Container(
                    width: 110,
                    height: 110,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const RadialGradient(
                        colors: [
                          Color(0xFF2A0A0A),
                          Color(0xFF1A0505),
                        ],
                      ),
                      border: Border.all(
                        color: Color.fromRGBO(220, 38, 38, 0.6),
                        width: 1.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.6),
                          blurRadius: 20,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: const Center(
                      child: Text(
                        '🔥',
                        style: TextStyle(fontSize: 52),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBrandText() {
    return AnimatedBuilder(
      animation: _textController,
      builder: (_, __) {
        return FadeTransition(
          opacity: _textOpacity,
          child: SlideTransition(
            position: _textSlide,
            child: Column(
              children: [
                // Brand name
                ShaderMask(
                  shaderCallback: (bounds) => const LinearGradient(
                    colors: [
                      Color(0xFFFF6B6B),
                      Color(0xFFDC2626),
                      Color(0xFFFF4500),
                    ],
                  ).createShader(bounds),
                  child: const Text(
                    'BARBECUEZ',
                    style: TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                      letterSpacing: 6,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                // Divider with flame dots
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildDividerLine(),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Text('🔥', style: TextStyle(fontSize: 14)),
                    ),
                    _buildDividerLine(),
                  ],
                ),
                const SizedBox(height: 10),
                // Tagline
                FadeTransition(
                  opacity: _taglineOpacity,
                  child: const Text(
                    'THE ULTIMATE BBQ EXPERIENCE',
                    style: TextStyle(
                      fontSize: 11,
                      color: Color(0xFF9CA3AF),
                      letterSpacing: 3.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildDividerLine() {
    return Container(
      width: 48,
      height: 1,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.transparent, Color(0xFF6B2020)],
        ),
      ),
    );
  }

  Widget _buildProgressSection() {
    if (_hasError) {
      return _buildErrorState();
    }
    return _buildProgressBar();
  }

  Widget _buildProgressBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 56),
      child: Column(
        children: [
          // Status text
          AnimatedBuilder(
            animation: _progressController,
            builder: (_, __) {
              final labels = [
                'Igniting the grill...',
                'Checking connection...',
                'Almost ready...',
                'Let\'s eat! 🍖',
              ];
              final idx =
              (_progress.value * (labels.length - 1)).round().clamp(
                0,
                labels.length - 1,
              );
              return AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: Text(
                  labels[idx],
                  key: ValueKey(idx),
                  style: const TextStyle(
                    color: Color(0xFF6B7280),
                    fontSize: 13,
                    letterSpacing: 0.5,
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 16),
          // Progress track
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              height: 3,
              child: AnimatedBuilder(
                animation: _progress,
                builder: (_, __) {
                  return LinearProgressIndicator(
                    value: _progress.value,
                    backgroundColor: const Color(0xFF1F1F1F),
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      Color(0xFFDC2626),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState() {
    return AnimatedBuilder(
      animation: _shake,
      builder: (_, child) {
        final offset = _shake.value < 0.5
            ? -12 * _shake.value * 2
            : 12 * (_shake.value - 0.5) * 2;
        return Transform.translate(
          offset: Offset(offset, 0),
          child: child,
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          children: [
            // Error icon
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF1A0505),
                border: Border.all(
                  color: const Color(0xFF7F1D1D),
                  width: 1.5,
                ),
              ),
              child: const Icon(
                Icons.wifi_off_rounded,
                color: Color(0xFFDC2626),
                size: 26,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'No Internet Connection',
              style: TextStyle(
                color: Color(0xFFF9FAFB),
                fontSize: 16,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Please check your connection\nand try again.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Color(0xFF6B7280),
                fontSize: 13,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 24),
            // Retry button
            GestureDetector(
              onTap: _retry,
              child: Container(
                padding:
                const EdgeInsets.symmetric(horizontal: 32, vertical: 13),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFFDC2626), Color(0xFFB91C1C)],
                  ),
                  borderRadius: BorderRadius.circular(30),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFDC2626).withOpacity(0.4),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.refresh_rounded, color: Colors.white, size: 18),
                    SizedBox(width: 8),
                    Text(
                      'Try Again',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}