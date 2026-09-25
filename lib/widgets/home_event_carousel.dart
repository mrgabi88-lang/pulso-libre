import 'package:flutter/material.dart';

import '../models/event.dart';
import 'brand_style.dart';
import 'event_media.dart';

class HomeEventCarousel extends StatefulWidget {
  final List<PulsoEvent> events;
  final int? featuredId;
  final ValueChanged<int> onOpen;
  final String Function(int) priceLabel;
  final EventImageBuilder imageBuilder;

  const HomeEventCarousel({
    super.key,
    required this.events,
    required this.featuredId,
    required this.onOpen,
    required this.priceLabel,
    required this.imageBuilder,
  });

  @override
  State<HomeEventCarousel> createState() => _HomeEventCarouselState();
}

class _HomeEventCarouselState extends State<HomeEventCarousel> {
  final _pages = PageController(viewportFraction: .94);
  int _index = 0;

  @override
  void didUpdateWidget(covariant HomeEventCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final before = oldWidget.events.map((event) => event.id).join(',');
    final after = widget.events.map((event) => event.id).join(',');
    if (before != after) {
      _index = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pages.hasClients) _pages.jumpToPage(0);
      });
    }
  }

  void _go(int page) {
    if (!_pages.hasClients || page < 0 || page >= widget.events.length) return;
    if (MediaQuery.of(context).disableAnimations) {
      _pages.jumpToPage(page);
    } else {
      _pages.animateToPage(
        page,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Widget _navigation(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final heading = Text(
        widget.events[_index].id == widget.featuredId
            ? 'Evento destacado'
            : 'Próximos eventos',
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
      );
      final controls = <Widget>[
        Semantics(
          liveRegion: true,
          label: 'Evento ${_index + 1} de ${widget.events.length}',
          child: ExcludeSemantics(
            child: Text(
              '${_index + 1} / ${widget.events.length}',
              style: const TextStyle(color: brandMuted, fontSize: 13),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Evento anterior',
          onPressed: _index > 0 ? () => _go(_index - 1) : null,
          icon: const Icon(Icons.keyboard_arrow_up_rounded),
        ),
        IconButton(
          tooltip: 'Evento siguiente',
          onPressed: _index < widget.events.length - 1
              ? () => _go(_index + 1)
              : null,
          icon: const Icon(Icons.keyboard_arrow_down_rounded),
        ),
      ];
      if (bounds.maxWidth < 300 ||
          (bounds.maxWidth < 450 &&
              MediaQuery.textScalerOf(context).scale(15) > 18)) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            heading,
            Row(mainAxisAlignment: MainAxisAlignment.end, children: controls),
          ],
        );
      }
      return Row(
        children: [
          Expanded(child: heading),
          ...controls,
        ],
      );
    },
  );

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: _navigation(context),
      ),
      Expanded(
        child: PageView.builder(
          key: const ValueKey('home-event-carousel'),
          controller: _pages,
          scrollDirection: Axis.vertical,
          allowImplicitScrolling: true,
          itemCount: widget.events.length,
          onPageChanged: (page) => setState(() => _index = page),
          itemBuilder: (context, page) {
            final event = widget.events[page];
            return Padding(
              key: ValueKey('home-event-page-${event.id}'),
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: _EventPage(
                event: event,
                onOpen: () => widget.onOpen(event.id),
                price: widget.priceLabel(event.price),
                imageBuilder: widget.imageBuilder,
              ),
            );
          },
        ),
      ),
    ],
  );
}

class _EventPage extends StatelessWidget {
  final PulsoEvent event;
  final VoidCallback onOpen;
  final String price;
  final EventImageBuilder imageBuilder;
  const _EventPage({
    required this.event,
    required this.onOpen,
    required this.price,
    required this.imageBuilder,
  });

  String get _date {
    final date = event.date;
    if (date == null) return 'Fecha a confirmar';
    const months = [
      'ene',
      'feb',
      'mar',
      'abr',
      'may',
      'jun',
      'jul',
      'ago',
      'sep',
      'oct',
      'nov',
      'dic',
    ];
    return '${date.day} ${months[date.month - 1]} · '
        '${'${date.hour}'.padLeft(2, '0')}:${'${date.minute}'.padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) => Container(
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: const Color(0xFF090A12).withValues(alpha: .86),
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: brandPink.withValues(alpha: .24)),
    ),
    child: LayoutBuilder(
      builder: (context, bounds) {
        final sideways = bounds.maxWidth > bounds.maxHeight * 1.25;
        final poster = Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onOpen,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: SizedBox.expand(
                child: event.flyers.isEmpty
                    ? const Center(
                        child: Icon(
                          Icons.event_outlined,
                          color: brandMuted,
                          size: 64,
                        ),
                      )
                    : imageBuilder(event.flyers.first, BoxFit.contain),
              ),
            ),
          ),
        );
        final details = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              event.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 20,
                height: 1.15,
                fontWeight: FontWeight.w800,
                letterSpacing: -.3,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _date,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
            if (event.location.trim().isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(
                event.location,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: brandMuted, fontSize: 13),
              ),
            ],
          ],
        );
        final action = Row(
          children: [
            Expanded(
              child: Text(
                event.admissionLabel(price),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              key: ValueKey('buy-event-${event.id}'),
              onPressed: onOpen,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                textStyle: Theme.of(context).textTheme.labelLarge!.copyWith(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              child: const Text('Ver evento'),
            ),
          ],
        );
        if (sideways) {
          return Row(
            children: [
              Expanded(flex: 6, child: poster),
              Expanded(
                flex: 5,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 12, 14, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: SingleChildScrollView(child: details)),
                      const SizedBox(height: 8),
                      action,
                    ],
                  ),
                ),
              ),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: poster),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [details, const SizedBox(height: 10), action],
              ),
            ),
          ],
        );
      },
    ),
  );
}
