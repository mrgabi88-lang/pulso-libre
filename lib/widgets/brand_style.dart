import 'package:flutter/material.dart';

const brandPink = Color(0xFFF044EF);
const brandBlue = Color(0xFF5579FF);
const brandMuted = Color(0xFFB9BACB);
const brandSurface = Color(0xFF0C0D16);

ThemeData pulsoTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: const Color(0xFF05060B),
    colorScheme: const ColorScheme.dark(
      primary: brandPink,
      onPrimary: Color(0xFF100314),
      secondary: brandBlue,
      onSecondary: Colors.white,
      surface: brandSurface,
      onSurface: Color(0xFFF7F4FB),
      outline: Color(0xFF414353),
    ),
    textTheme: base.textTheme.copyWith(
      headlineLarge: const TextStyle(
        fontSize: 32,
        height: 1.15,
        fontWeight: FontWeight.w900,
        letterSpacing: -.8,
      ),
      headlineSmall: const TextStyle(
        fontSize: 26,
        height: 1.2,
        fontWeight: FontWeight.w800,
        letterSpacing: -.4,
      ),
      titleLarge: const TextStyle(
        fontSize: 21,
        height: 1.25,
        fontWeight: FontWeight.w800,
      ),
      bodyLarge: const TextStyle(fontSize: 16, height: 1.45),
      bodyMedium: const TextStyle(fontSize: 15, height: 1.4),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFF080910),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
      labelStyle: const TextStyle(color: brandMuted),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0xFF414353)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: brandPink, width: 1.5),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 52),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        backgroundColor: const Color(0xFFAB12C7),
        foregroundColor: Colors.white,
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 50),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        foregroundColor: const Color(0xFFF7F4FB),
        side: const BorderSide(color: Color(0xFF414353)),
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
    ),
    dividerTheme: const DividerThemeData(color: Color(0xFF2C2D3C), space: 28),
    expansionTileTheme: const ExpansionTileThemeData(
      iconColor: brandPink,
      textColor: brandPink,
      collapsedIconColor: brandPink,
      tilePadding: EdgeInsets.zero,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: brandPink),
  );
}

/// The approved artwork is bundled unchanged; this window displays its wordmark.
class BrandSignature extends StatelessWidget {
  final double width;
  const BrandSignature({super.key, this.width = 116});
  @override
  Widget build(BuildContext context) => Semantics(
    label: 'PLLABS',
    image: true,
    child: ExcludeSemantics(
      child: Image.asset(
        'assets/branding/pllabs_identity.png',
        width: width,
        height: width * .15,
        fit: BoxFit.cover,
        alignment: const Alignment(0, -.44),
        filterQuality: FilterQuality.high,
      ),
    ),
  );
}

class BrandBackdrop extends StatelessWidget {
  final Widget child;
  const BrandBackdrop({super.key, required this.child});
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(color: Color(0xFF05060B)),
    child: Stack(
      fit: StackFit.expand,
      children: [
        // Show the complete isolated emblem at the largest uncropped size.
        // Decorative layers must never intercept a tap or be read as content.
        Positioned.fill(
          child: IgnorePointer(
            child: ExcludeSemantics(
              child: Image.asset(
                'assets/branding/pllabs_logo.png',
                fit: BoxFit.contain,
                alignment: Alignment.center,
                opacity: AlwaysStoppedAnimation(
                  MediaQuery.sizeOf(context).width < 600 ? .26 : .30,
                ),
                filterQuality: FilterQuality.high,
              ),
            ),
          ),
        ),
        child,
      ],
    ),
  );
}

class BrandHeader extends StatelessWidget {
  final String section;
  final VoidCallback? onHome;
  final bool compact;
  const BrandHeader({
    super.key,
    required this.section,
    this.onHome,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) => compact
      ? const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Center(child: BrandSignature(width: 160)),
        )
      : Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
              child: LayoutBuilder(
                builder: (context, constraints) => Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: BrandSignature(
                        width: (constraints.maxWidth * .76).clamp(0.0, 360.0),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text.rich(
                                TextSpan(
                                  children: [
                                    TextSpan(
                                      text: 'PULSO ',
                                      style: TextStyle(color: brandPink),
                                    ),
                                    TextSpan(text: 'LIBRE'),
                                  ],
                                ),
                                style: TextStyle(
                                  fontSize: 24,
                                  height: 1.15,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: -.8,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                section,
                                style: const TextStyle(
                                  color: brandMuted,
                                  fontSize: 12,
                                  letterSpacing: .5,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (onHome != null)
                          IconButton(
                            onPressed: onHome,
                            tooltip: 'Inicio',
                            icon: const Icon(Icons.home_outlined),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
}

class SectionEyebrow extends StatelessWidget {
  final String text;
  const SectionEyebrow(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      color: brandPink,
      fontSize: 11,
      height: 1.4,
      letterSpacing: 1.7,
      fontWeight: FontWeight.w800,
    ),
  );
}
