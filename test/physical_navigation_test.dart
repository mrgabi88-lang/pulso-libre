import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../integration_test/ui_navigation.dart';

void main() {
  testWidgets(
    'navigation constructs lazy items and can return to controls above',
    (tester) async {
      final tapped = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView.builder(
              itemCount: 30,
              itemExtent: 200,
              itemBuilder: (_, i) => FilledButton(
                key: ValueKey('item-$i'),
                onPressed: () {
                  tapped.add(i);
                },
                child: Text('Item $i'),
              ),
            ),
          ),
        ),
      );
      final ui = PhysicalUi(tester);
      expect(find.byKey(const ValueKey('item-20')), findsNothing);
      await ui.tap(find.byKey(const ValueKey('item-20')));
      await ui.tap(find.byKey(const ValueKey('item-0')));
      expect(tapped, [20, 0]);
    },
  );

  testWidgets(
    'navigation reports bounded failure when a control does not exist',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ListView(children: const [Text('Only item')])),
        ),
      );
      Object? failure;
      try {
        await PhysicalUi(tester).reveal(find.text('Missing'), maxSteps: 3);
      } catch (e) {
        failure = e;
      }
      expect(failure, isA<TestFailure>());
    },
  );
}
