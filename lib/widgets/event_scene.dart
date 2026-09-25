import 'package:flutter/material.dart';
import '../models/event.dart';
import 'event_media.dart';

/// Event-owned imagery fills the viewport. Neutral controls adapt to any artwork.
class EventScene extends StatelessWidget {
  final PulsoEvent? event;
  final EventImageBuilder imageBuilder;
  final EventAudioControls? audioControls;
  final VoidCallback onHome;
  final VoidCallback onPurchase;
  final String purchaseLabel;
  final Widget child;
  final EdgeInsets contentPadding;
  const EventScene({
    super.key,
    required this.event,
    required this.imageBuilder,
    this.audioControls,
    required this.onHome,
    required this.onPurchase,
    required this.child,
    this.purchaseLabel = 'Comprar entradas',
    this.contentPadding = EdgeInsets.zero,
  });

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    final theme = base.copyWith(
      colorScheme: base.colorScheme.copyWith(
        primary: Colors.white,
        onPrimary: Colors.black,
        secondary: const Color(0xFFC6D7F0),
        surface: const Color(0xFF111318),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: base.filledButtonTheme.style?.copyWith(
          backgroundColor: const WidgetStatePropertyAll(Colors.white),
          foregroundColor: const WidgetStatePropertyAll(Colors.black),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: base.outlinedButtonTheme.style?.copyWith(
          backgroundColor: const WidgetStatePropertyAll(Color(0x99202228)),
          foregroundColor: const WidgetStatePropertyAll(Colors.white),
        ),
      ),
      inputDecorationTheme: base.inputDecorationTheme.copyWith(
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Colors.white, width: 1.5),
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: Colors.white,
      ),
    );
    return Theme(
      data: theme,
      child: Stack(
        key: ValueKey('event-scene-${event?.id ?? 0}'),
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Color(0xFF101116)),
          if (event?.background != null)
            Positioned.fill(
              key: ValueKey('event-background-${event!.id}'),
              child: IgnorePointer(
                child: imageBuilder(event!.background!, BoxFit.cover),
              ),
            ),
          const Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x44000000),
                      Color(0x11000000),
                      Color(0x66000000),
                    ],
                    stops: [0, .45, 1],
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: contentPadding,
              child: Column(
                children: [
                  Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1240),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                        child: LayoutBuilder(
                          builder: (context, bounds) => Row(
                            children: [
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: .65),
                                  borderRadius: BorderRadius.circular(30),
                                ),
                                child: IconButton(
                                  key: const ValueKey('event-back'),
                                  tooltip: 'Inicio',
                                  onPressed: onHome,
                                  icon: const Icon(
                                    Icons.arrow_back_rounded,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              if (bounds.maxWidth >= 500)
                                const Expanded(
                                  child: Text(
                                    'Volver',
                                    style: TextStyle(
                                      color: Colors.white,
                                      shadows: [
                                        Shadow(
                                          color: Colors.black,
                                          blurRadius: 8,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              if (bounds.maxWidth >= 500)
                                const SizedBox(width: 10),
                              Expanded(
                                flex: 2,
                                child: Align(
                                  alignment: Alignment.centerRight,
                                  child: FilledButton(
                                    key: const ValueKey('event-buy-scroll'),
                                    onPressed: onPurchase,
                                    style: FilledButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 16,
                                        vertical: 14,
                                      ),
                                    ),
                                    child: Text(
                                      purchaseLabel,
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(child: child),
                  if (audioControls != null)
                    EventAudioBar(controller: audioControls!),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class EventSurface extends StatelessWidget {
  final Widget child;
  const EventSurface({super.key, required this.child});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(22),
    decoration: BoxDecoration(
      color: const Color(0xBE080A0F),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: Colors.white.withValues(alpha: .18)),
    ),
    child: child,
  );
}

class EventFlyers extends StatelessWidget {
  final PulsoEvent event;
  final EventImageBuilder imageBuilder;
  const EventFlyers({
    super.key,
    required this.event,
    required this.imageBuilder,
  });
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (event.flyers.isEmpty) return const SizedBox.shrink();
      final height = (constraints.maxWidth / .72).clamp(
        260.0,
        MediaQuery.sizeOf(context).height * .82 > 260
            ? MediaQuery.sizeOf(context).height * .82
            : 260.0,
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: height,
            child: PageView(
              key: ValueKey('event-flyers-${event.id}'),
              children: [
                for (final uri in event.flyers)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: imageBuilder(uri, BoxFit.contain),
                  ),
              ],
            ),
          ),
          if (event.flyers.length > 1)
            Container(
              margin: const EdgeInsets.only(top: 10),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: .6),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Text(
                'Deslizá para ver los flyers',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white),
              ),
            ),
        ],
      );
    },
  );
}
