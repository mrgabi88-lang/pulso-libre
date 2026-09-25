import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pulso_libre_app/main.dart';
import 'package:pulso_libre_app/models/event.dart';
import 'package:pulso_libre_app/services/api_service.dart';
import 'package:pulso_libre_app/services/session_store.dart';

import '../integration_test/ui_navigation.dart';
import 'helpers.dart';

void main() {
  test(
    'upgrade removes obsolete return hint but preserves buyer and retry ID',
    () async {
      final vault = MemoryVault();
      final prior = await signedSession(vault);
      final retryId = await prior.beginPurchaseIntent(101, 2);
      vault.values['pulso_v2_pending_checkout'] = jsonEncode({
        'owner': buyer['id'],
        'order_id': 77,
      });
      final upgraded = SessionStore(vault: vault);
      await upgraded.load();
      expect(vault.values.containsKey('pulso_v2_pending_checkout'), isFalse);
      expect(upgraded.hasCredential, isTrue);
      expect(upgraded.authenticated, isFalse);
      upgraded.acceptValidatedUser(buyer, unlock: true);
      expect(await upgraded.beginPurchaseIntent(101, 2), retryId);
    },
  );

  test(
    'historical unresolved orders cannot request a receipt or enable QR',
    () {
      for (final status in [
        'pending_payment',
        'payment_rejected',
        'payment_review',
        'payment_cancelled',
        'payment_expired',
        'refunded',
        'charged_back',
        'partially_refunded',
      ]) {
        final item = AccessItem({
          'id': 77,
          'order_id': 77,
          'item_type': 'order',
          'event_id': 101,
          'status': status,
        });
        expect(item.canUpload, isFalse, reason: status);
        expect(item.qrEnabled, isFalse, reason: status);
      }
      expect(
        AccessItem({
          'id': 77,
          'order_id': 77,
          'item_type': 'order',
          'status': 'pending_receipt',
          'payment_method': 'external_retired',
          'payment_retired': true,
        }).canUpload,
        isFalse,
      );
    },
  );

  test(
    'existing approved tickets keep QR and transfer with historical metadata',
    () {
      final ticket = AccessItem({
        'id': 55,
        'ticket_id': 55,
        'order_id': 77,
        'item_type': 'ticket',
        'status': 'active',
        'qr_enabled': true,
        'can_transfer': true,
        'payment_method': 'external_retired',
        'payment_retired': true,
      });
      expect(ticket.qrEnabled, isTrue);
      expect(ticket.canTransfer, isTrue);
      expect(ticket.canUpload, isFalse);
    },
  );

  testWidgets(
    'paid event uses receipt flow even with obsolete advertised methods',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = await signedSession();
      final calls = <String>[];
      final data = {
        ...event(101, 'RECITAL DE EJEMPLO'),
        'payment_methods': ['retired_provider'],
      };
      final api = ApiService(
        config: localConfig(),
        session: session,
        client: MockClient((request) async {
          final endpoint = request.url.path.split('/').last;
          calls.add(endpoint);
          if (endpoint == 'purchase_create.php') {
            expect(jsonDecode(request.body), containsPair('event_id', 101));
            return response(200, {
              'ok': true,
              'order': {
                'id': 77,
                'event_id': 101,
                'ticket_qty': 1,
                'amount_total': 100,
                'status': 'pending_receipt',
                'payment_method': 'transfer_receipt',
                'requires_receipt': true,
              },
            });
          }
          fail('Unexpected endpoint: $endpoint');
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BuyScreen(
              api: api,
              catalog: EventCatalog.fromJson({
                'ok': true,
                'items': [data],
              }, localConfig()),
              selectedEventId: 101,
              onSelectedEvent: (_) {},
              onOrderChanged: (_) {},
              onAccount: () {},
              onTickets: () {},
              receiptPicker: () async => null,
              imageBuilder: fakeImage,
              externalLauncher: (_) async =>
                  throw TestFailure('Payment browser opened'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final nav = PhysicalUi(tester);
      await nav.tap(find.byKey(const ValueKey('create-order')));
      await tester.pumpAndSettle();
      expect(calls, ['purchase_create.php']);
      expect(find.byKey(const ValueKey('payment-method')), findsNothing);
      expect(find.byKey(const ValueKey('upload-receipt')), findsOneWidget);
      expect(find.text('Falta el comprobante'), findsOneWidget);
      expect(find.text('Continuar pago'), findsNothing);
    },
  );
}
