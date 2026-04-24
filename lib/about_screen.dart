import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  // ── Contact info — edit these ──────────────────────────────────────────────
  static const String _email = 'bbq@barbecuez.no';
  static const String _phone = '+47 94440111';
  static const String _appVersion = '1.0.0';
  static const String _description =
      'Your go-to destination for authentic BBQ in Norway. '
      'Order online, track your meal, and enjoy the smoky goodness delivered to your door.';

  // ── Colors ────────────────────────────────────────────────────────────────
  static const Color _coal = Color(0xFF1A1210);
  static const Color _ember = Color(0xFFB83A1B);
  static const Color _ash = Color(0xFF3D2E2A);
  static const Color _smoke = Color(0xFF6B5650);
  static const Color _cream = Color(0xFFF5EDE6);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _coal,
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            // ── Hero header ────────────────────────────────────────────────
            SliverToBoxAdapter(
              child: _buildHero(),
            ),

            // ── Info cards ─────────────────────────────────────────────────
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  _buildSectionLabel('ABOUT'),
                  const SizedBox(height: 8),
                  _buildDescriptionCard(),
                  const SizedBox(height: 24),
                  _buildSectionLabel('CONTACT US'),
                  const SizedBox(height: 8),
                  _buildContactCard(
                    icon: Icons.email_outlined,
                    label: 'Email',
                    value: _email,
                    onTap: () => _launch('mailto:$_email'),
                  ),
                  const SizedBox(height: 1),
                  _buildContactCard(
                    icon: Icons.phone_outlined,
                    label: 'Phone',
                    value: _phone,
                    onTap: () => _launch('tel:${_phone.replaceAll(' ', '')}'),
                    isLast: true,
                  ),
                  const SizedBox(height: 24),
                  _buildVersionBadge(),
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Hero ───────────────────────────────────────────────────────────────────

  Widget _buildHero() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
      decoration: const BoxDecoration(
        color: _ash,
        border: Border(
          bottom: BorderSide(color: _ember, width: 2),
        ),
      ),
      child: Column(
        children: [
          // Flame icon — brand mark
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              color: _ember,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: _ember.withOpacity(0.45),
                  blurRadius: 28,
                  spreadRadius: 4,
                ),
              ],
            ),
            child: const Icon(
              Icons.local_fire_department_rounded,
              color: _cream,
              size: 48,
            ),
          ),
          const SizedBox(height: 20),

          // App name
          const Text(
            'BARBECUEZ',
            style: TextStyle(
              fontFamily: 'serif',
              fontSize: 30,
              fontWeight: FontWeight.w700,
              color: _cream,
              letterSpacing: 6,
            ),
          ),
          const SizedBox(height: 6),

          // Tagline
          const Text(
            'Smoke. Flavor. Delivered.',
            style: TextStyle(
              fontSize: 13,
              color: _smoke,
              letterSpacing: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  // ── Section label ──────────────────────────────────────────────────────────

  Widget _buildSectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 0),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: _ember,
          letterSpacing: 2,
        ),
      ),
    );
  }

  // ── Description card ───────────────────────────────────────────────────────

  Widget _buildDescriptionCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: _ash,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _smoke.withOpacity(0.25), width: 0.5),
      ),
      child: const Text(
        _description,
        style: TextStyle(
          fontSize: 14.5,
          color: _cream,
          height: 1.65,
        ),
      ),
    );
  }

  // ── Contact card ───────────────────────────────────────────────────────────

  Widget _buildContactCard({
    required IconData icon,
    required String label,
    required String value,
    required VoidCallback onTap,
    bool isLast = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        decoration: BoxDecoration(
          color: _ash,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(isLast ? 0 : 12),
            topRight: Radius.circular(isLast ? 0 : 12),
            bottomLeft: Radius.circular(isLast ? 12 : 0),
            bottomRight: Radius.circular(isLast ? 12 : 0),
          ),
          border: Border.all(color: _smoke.withOpacity(0.25), width: 0.5),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: _ember.withOpacity(0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: _ember, size: 18),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 11,
                      color: _smoke,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    style: const TextStyle(
                      fontSize: 14.5,
                      color: _cream,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: _smoke, size: 18),
          ],
        ),
      ),
    );
  }

  // ── Version badge ──────────────────────────────────────────────────────────

  Widget _buildVersionBadge() {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: _ash,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _smoke.withOpacity(0.3), width: 0.5),
        ),
        child: Text(
          'Version $_appVersion',
          style: const TextStyle(
            fontSize: 12,
            color: _smoke,
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }

  // ── Launch URL ─────────────────────────────────────────────────────────────

  Future<void> _launch(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}