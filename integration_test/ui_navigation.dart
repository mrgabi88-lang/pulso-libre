import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulso_libre_app/widgets/global_navigation.dart';

/// Navigation for the app's lazy lists, paged Home and dropdown overlays.
/// Only scrolls widgets in the test app; never changes device orientation.
class PhysicalUi {
  final WidgetTester tester;
  const PhysicalUi(this.tester);

  Finder get _homeCarousel => find.byKey(const ValueKey('home-event-carousel'));

  PageController? get _homeController => _homeCarousel.evaluate().isEmpty
      ? null
      : tester.widget<PageView>(_homeCarousel).controller;

  Future<bool> _revealHomePage(Finder target) async {
    final controller = _homeController;
    if (controller == null || !controller.hasClients) return false;
    Element? page;
    final innerScrollables = <ScrollableState>[];
    tester.element(target).visitAncestorElements((ancestor) {
      final key = ancestor.widget.key;
      if (key is ValueKey<String> && key.value.startsWith('home-event-page-')) {
        page = ancestor;
        return false;
      }
      if (ancestor is StatefulElement && ancestor.state is ScrollableState) {
        innerScrollables.add(ancestor.state as ScrollableState);
      }
      return true;
    });
    if (page == null) return false;
    // Reveal the whole page, not a button near its edge; then restore an
    // exact page boundary so a screenshot or tap cannot land between events.
    await Scrollable.ensureVisible(page!, alignment: .5);
    controller.jumpToPage(controller.page!.round());
    await tester.pumpAndSettle();
    // Short screens may scroll inside an event page. Move only those inner
    // positions after snapping; do not offset the outer carousel again.
    for (final scrollable in innerScrollables) {
      await scrollable.position.ensureVisible(
        tester.element(target).renderObject!,
        alignment: .5,
      );
    }
    await tester.pumpAndSettle();
    return true;
  }

  Finder get _verticalScrollables => find.byElementPredicate((element) {
    final widget = element.widget;
    if (widget is! Scrollable ||
        (widget.axisDirection != AxisDirection.down &&
            widget.axisDirection != AxisDirection.up)) {
      return false;
    }
    // The floating rail has its own short-viewport scroll fallback. A lazy
    // form control must be revealed by scrolling its page, never that rail.
    var isNavigation = false;
    element.visitAncestorElements((ancestor) {
      isNavigation = ancestor.widget is GlobalNavigation;
      return !isNavigation;
    });
    return !isNavigation;
  });

  Future<void> reveal(Finder target, {int maxSteps = 80}) async {
    var movedToStart = false;
    for (var step = 0; step < maxSteps; step++) {
      if (target.evaluate().isNotEmpty) {
        if (await _revealHomePage(target)) return;
        await Scrollable.ensureVisible(
          tester.element(target),
          alignment: .5,
          duration: Duration.zero,
        );
        await tester.pump(const Duration(milliseconds: 100));
        return;
      }
      final pages = _homeController;
      if (pages != null &&
          pages.hasClients &&
          pages.position.hasContentDimensions) {
        if (!movedToStart) {
          pages.jumpToPage(0);
          movedToStart = true;
        } else {
          final lastPage =
              (pages.position.maxScrollExtent /
                      (pages.position.viewportDimension *
                          pages.viewportFraction))
                  .round();
          pages.jumpToPage((pages.page!.round() + 1).clamp(0, lastPage));
        }
        await tester.pumpAndSettle();
        continue;
      }
      final scrollables = _verticalScrollables;
      if (scrollables.evaluate().isNotEmpty) {
        // Dropdown menus appear after the page's scrollable in the tree.
        // Horizontal flyer PageViews are excluded.
        final state = tester.state<ScrollableState>(scrollables.last);
        final position = state.position;
        if (position.hasContentDimensions) {
          if (!movedToStart) {
            position.jumpTo(position.minScrollExtent);
            movedToStart = true;
          } else {
            final next = (position.pixels + position.viewportDimension * .65)
                .clamp(position.minScrollExtent, position.maxScrollExtent);
            position.jumpTo(next);
          }
        }
      }
      await tester.pump(const Duration(milliseconds: 200));
    }
    throw TestFailure(
      'Control not found after $maxSteps bounded scroll/pump steps: $target',
    );
  }

  Future<void> tap(Finder target) async {
    for (var attempt = 0; attempt < 6; attempt++) {
      await _dismissKeyboardAndWait();
      await reveal(target);
      if (target.hitTestable().evaluate().length == 1) {
        await tester.tap(target);
        await tester.pump(const Duration(milliseconds: 300));
        return;
      }
      // IME resize or a dropdown transition may finish after reveal's layout.
      // Retry actual visibility; never dispatch a tap behind another surface.
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(
      target.hitTestable(),
      findsOneWidget,
      reason:
          'The control must be visible and tappable after keyboard/viewport stabilization.',
    );
  }

  Future<void> _dismissKeyboardAndWait() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    var previousInset = tester.view.viewInsets.bottom;
    var previousSize = tester.view.physicalSize;
    var stableFrames = 0;
    for (var frame = 0; frame < 30; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
      final inset = tester.view.viewInsets.bottom;
      final size = tester.view.physicalSize;
      stableFrames = inset == previousInset && size == previousSize
          ? stableFrames + 1
          : 0;
      previousInset = inset;
      previousSize = size;
      // A minimum six frames also catches an IME opening message already
      // queued when unfocus was requested, before its first inset update.
      if (frame >= 5 && inset == 0 && stableFrames >= 4) return;
    }
  }

  Future<void> enterText(Finder target, String text) async {
    await reveal(target);
    await tester.enterText(target, text);
    await tester.pump(const Duration(milliseconds: 100));
  }
}
