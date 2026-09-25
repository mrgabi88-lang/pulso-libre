import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:pulso_libre_app/services/api_service.dart';
import 'package:pulso_libre_app/services/qr_controller.dart';
import 'package:pulso_libre_app/widgets/dynamic_qr.dart';
import 'helpers.dart';

Map<String, dynamic> qr(
  String payload, {
  String server = '2030-01-01T00:00:00Z',
  String expiry = '2030-01-01T00:00:05Z',
}) => {
  'ok': true,
  'ticket_id': 55,
  'qr_payload': payload,
  'server_time': server,
  'expires_at': expiry,
  'expires_in': 5,
  'refresh_seconds': 5,
  'grace_seconds': 5,
};

void main() {
  testWidgets(
    'visible QR expires and stays hidden after renewal failure with controlled retry',
    (tester) async {
      final clock = ManualClock();
      var calls = 0;
      final api = ApiService(
        config: localConfig(),
        session: await signedSession(),
        client: MockClient((_) async {
          calls++;
          return calls == 1
              ? response(200, qr('SYNTHETIC-55-SLOT-1'))
              : response(503, {'ok': false, 'error': 'Sin conexión de prueba'});
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DynamicTicketQrPanel(api: api, ticketId: 55, clock: clock),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byType(QrImageView), findsOneWidget);
      clock.advance(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 5));
      expect(find.byType(QrImageView), findsNothing);
      expect(calls, 1);
      clock.advance(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump();
      expect(calls, 2);
      expect(find.text('Sin conexión de prueba'), findsOneWidget);
      expect(find.byType(QrImageView), findsNothing);
      clock.advance(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(calls, 2);
      expect(find.text('Reintentar en 4s'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'server boundary with RTT hides old slot then obtains next slot without five-second phase loop',
    (tester) async {
      final clock = ManualClock();
      var calls = 0;
      final controller = QrController(
        ticketId: 55,
        clock: clock,
        fetch: () async {
          calls++;
          if (calls == 1) {
            clock.advance(const Duration(milliseconds: 100));
            return qr('OLD-EDGE', server: '2030-01-01T00:00:04.950000Z');
          }
          return qr(
            'NEW-SLOT',
            server: '2030-01-01T00:00:05.200000Z',
            expiry: '2030-01-01T00:00:10Z',
          );
        },
      );
      await controller.refresh();
      expect(controller.payload, isEmpty);
      expect(controller.error, isNull);
      clock.advance(const Duration(milliseconds: 149));
      await tester.pump(const Duration(milliseconds: 149));
      expect(calls, 1);
      clock.advance(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(calls, 2);
      expect(controller.payload, 'NEW-SLOT');
      expect(controller.error, isNull);
      controller.dispose();
    },
  );

  testWidgets(
    'monotonic expiry ignores device wall clock and rejects another ticket identity',
    (tester) async {
      final clock = ManualClock();
      final controller = QrController(
        ticketId: 55,
        clock: clock,
        fetch: () async => qr('CURRENT'),
      );
      await controller.refresh();
      clock.advance(const Duration(seconds: 5));
      expect(
        controller.payload,
        isEmpty,
      ); // Even before a timer callback can paint.
      controller.dispose();
      final mismatch = QrController(
        ticketId: 55,
        clock: clock,
        fetch: () async => {...qr('OTHER'), 'ticket_id': 99},
      );
      await mismatch.refresh();
      expect(mismatch.payload, isEmpty);
      expect(mismatch.error, isNotNull);
      mismatch.dispose();
    },
  );

  testWidgets(
    'conceal invalidates an in-flight response and removes its future payload',
    (tester) async {
      final pending = Completer<Map<String, dynamic>>();
      final controller = QrController(
        ticketId: 55,
        clock: ManualClock(),
        fetch: () => pending.future,
      );
      final work = controller.refresh();
      controller.conceal();
      pending.complete(qr('LATE'));
      await work;
      expect(controller.payload, isEmpty);
      expect(controller.busy, isFalse);
      controller.dispose();
    },
  );
}
