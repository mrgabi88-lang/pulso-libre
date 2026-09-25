import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pulso_libre_app/main.dart';
import 'package:pulso_libre_app/models/event.dart';
import 'package:pulso_libre_app/services/api_service.dart';
import 'package:pulso_libre_app/services/session_store.dart';
import 'package:pulso_libre_app/widgets/dynamic_qr.dart';
import 'helpers.dart';

Future<void> largeScreen(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1000, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> fillLogin(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const ValueKey('account-email')),
    'buyer@example.invalid',
  );
  await tester.enterText(
    find.byKey(const ValueKey('account-password')),
    'SYNTHETIC',
  );
  await tap(tester, find.widgetWithText(FilledButton, 'Entrar'));
}

void main() {
  testWidgets(
    'second public event CTA and dropdown selection survive account login',
    (tester) async {
      await largeScreen(tester);
      final session = SessionStore(vault: MemoryVault());
      final api = ApiService(
        config: localConfig(),
        session: session,
        client: MockClient((req) async {
          if (req.url.path.endsWith('/events.php')) {
            return response(200, catalog());
          }
          expect(req.url.path, endsWith('/login.php'));
          return response(200, loginEnvelope);
        }),
      );
      await tester.pumpWidget(PulsoLibreApp(api: api, imageBuilder: fakeImage));
      await tester.pumpAndSettle();
      final carousel = find.byKey(const ValueKey('home-event-carousel'));
      final pages = tester.widget<PageView>(carousel);
      expect(pages.scrollDirection, Axis.vertical);
      expect(pages.controller!.page, closeTo(0, .001));
      expect(
        find.byKey(const ValueKey('buy-event-202')).hitTestable(),
        findsOneWidget,
      );
      await tester.drag(
        carousel,
        Offset(0, -tester.getSize(carousel).height * .8),
      );
      await tester.pumpAndSettle();
      expect(pages.controller!.page, closeTo(1, .001));
      expect(
        find.byKey(const ValueKey('buy-event-101')).hitTestable(),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('buy-event-101')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('purchase-event-title')))
            .data,
        'ROJO',
      );
      await tap(tester, find.text('Ingresar o crear cuenta'));
      await fillLogin(tester);
      expect(session.authenticated, isTrue);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('purchase-event-title')))
            .data,
        'ROJO',
        reason:
            'Opening the second carousel page must retain that event through login.',
      );
      await tap(tester, find.byKey(const ValueKey('selected-event')));
      await tap(tester, find.text('AZUL').last);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('purchase-event-title')))
            .data,
        'AZUL',
      );
      expect(find.byKey(const ValueKey('create-order')), findsOneWidget);
    },
  );

  testWidgets(
    'legacy registration never starts session; resend and confirmed return to login',
    (tester) async {
      await largeScreen(tester);
      final session = SessionStore(vault: MemoryVault());
      var resend = 0;
      var logged = 0;
      final api = ApiService(
        config: localConfig(),
        session: session,
        client: MockClient((req) async {
          if (req.url.path.endsWith('/register.php')) {
            return response(200, {'ok': true, 'user': buyer});
          }
          expect(req.url.path, endsWith('/resend_verification.php'));
          expect(jsonDecode(req.body)['kind'], 'buyer');
          resend++;
          return response(200, {
            'ok': true,
            'message': 'Mensaje genérico de prueba',
          });
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AccountScreen(
              api: api,
              onLoggedIn: () {
                logged++;
              },
            ),
          ),
        ),
      );
      await tap(tester, find.text('Crear una cuenta'));
      await tester.enterText(
        find.byKey(const ValueKey('account-name')),
        'Prueba',
      );
      await tester.enterText(
        find.byKey(const ValueKey('account-email')),
        'buyer@example.invalid',
      );
      await tester.enterText(
        find.byKey(const ValueKey('account-password')),
        'SYNTHETIC',
      );
      await tap(tester, find.widgetWithText(FilledButton, 'Crear cuenta'));
      expect(session.authenticated, isFalse);
      expect(logged, 0);
      expect(find.text('Confirmá tu correo'), findsOneWidget);
      await tap(tester, find.text('Reenviar confirmación'));
      expect(resend, 1);
      expect(find.text('Reenviar en 60s'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Reenviar en 60s'),
            )
            .onPressed,
        isNull,
      );
      await tap(tester, find.text('Ya confirmé: ir a ingresar'));
      expect(find.byKey(const ValueKey('account-password')), findsOneWidget);
      expect(session.authenticated, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'stored token requires device unlock then fresh me before protected UI',
    (tester) async {
      await largeScreen(tester);
      final vault = MemoryVault();
      await signedSession(vault);
      final session = SessionStore(vault: vault);
      var me = 0;
      var biometric = 0;
      final api = ApiService(
        config: localConfig(),
        session: session,
        client: MockClient((req) async {
          if (req.url.path.endsWith('/events.php')) {
            return response(200, catalog());
          }
          expect(req.url.path, endsWith('/me.php'));
          me++;
          return response(200, {'ok': true, 'user': buyer});
        }),
      );
      await tester.pumpWidget(
        PulsoLibreApp(
          api: api,
          imageBuilder: fakeImage,
          biometric: () async {
            biometric++;
            return true;
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(session.authenticated, isFalse);
      expect(me, 1);
      expect(find.text('Pulso Libre bloqueado'), findsOneWidget);
      await tap(tester, find.byKey(const ValueKey('unlock-device')));
      expect(biometric, 1);
      expect(me, 2);
      expect(session.authenticated, isTrue);
    },
  );

  testWidgets(
    'device credentials work without biometrics and server revalidation follows successful unlock only',
    (tester) async {
      await largeScreen(tester);
      final vault = MemoryVault();
      await signedSession(vault);
      final session = SessionStore(vault: vault);
      var me = 0;
      var authenticateCalls = 0;
      var biometricChecks = 0;
      Completer<bool>? authentication;
      final revalidation = Completer<void>();
      // In widget tests local_auth uses DefaultLocalAuthPlatform, whose
      // method channel carries the actual options from LocalAuthentication.
      // This mocks the plugin boundary, never an operating-system prompt.
      const channel = MethodChannel('plugins.flutter.io/local_auth');
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'isDeviceSupported':
            return true;
          case 'getAvailableBiometrics':
            biometricChecks++;
            return <String>[];
          case 'authenticate':
            authenticateCalls++;
            final arguments = call.arguments as Map;
            expect(arguments['biometricOnly'], isFalse);
            expect(arguments['stickyAuth'], isTrue);
            authentication = Completer<bool>();
            return authentication!.future;
          default:
            throw TestFailure('Unexpected local_auth method: ${call.method}');
        }
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final api = ApiService(
        config: localConfig(),
        session: session,
        client: MockClient((req) async {
          expect(req.method, 'GET');
          if (req.url.path.endsWith('/events.php')) {
            return response(200, catalog());
          }
          expect(req.url.path, endsWith('/me.php'));
          me++;
          if (me > 1) await revalidation.future;
          return response(200, {'ok': true, 'user': buyer});
        }),
      );
      await tester.pumpWidget(PulsoLibreApp(api: api, imageBuilder: fakeImage));
      await tester.pumpAndSettle();
      expect(
        me,
        1,
        reason: 'Boot validates the stored credential but stays locked.',
      );
      expect(session.authenticated, isFalse);

      expect(find.text('Desbloquear'), findsOneWidget);
      expect(
        find.text(
          'Usá el patrón, PIN, contraseña o biometría configurados en tu dispositivo.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('unlock-device')));
      await tester.pump();
      expect(authenticateCalls, 1);
      expect(
        biometricChecks,
        0,
        reason: 'Device pattern or PIN does not require biometric enrollment.',
      );
      expect(me, 1);
      authentication!.complete(false);
      await tester.pumpAndSettle();
      expect(session.authenticated, isFalse);
      expect(
        me,
        1,
        reason:
            'Cancelled device authentication must not unlock or revalidate.',
      );
      expect(find.text('Ingresar con correo y contraseña'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('unlock-device')));
      await tester.pump();
      expect(authenticateCalls, 2);
      expect(me, 1);
      authentication!.complete(true);
      await tester.pump();
      await tester.pump();
      expect(me, 2);
      expect(
        session.authenticated,
        isFalse,
        reason: 'Local success alone does not open the session.',
      );
      revalidation.complete();
      await tester.pumpAndSettle();
      expect(session.authenticated, isTrue);
      expect(biometricChecks, 0);
      expect(find.text('Pulso Libre bloqueado'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );

  testWidgets(
    'unlimited stock allows creating order for exact selected event with media',
    (tester) async {
      await largeScreen(tester);
      final session = await signedSession();
      var creates = 0;
      final c = EventCatalog.fromJson({
        'items': [
          {
            ...event(202, 'AZUL'),
            'stock_available': null,
            'background_url': '/bg.png',
            'flyer_urls': ['/flyer.png'],
          },
        ],
      }, localConfig());
      final api = ApiService(
        config: localConfig(),
        session: session,
        client: MockClient((req) async {
          expect(req.url.path, endsWith('/purchase_create.php'));
          final body = jsonDecode(req.body);
          expect(body['event_id'], 202);
          expect(body['ticket_qty'], 1);
          creates++;
          return response(200, {
            'ok': true,
            'order': {
              'id': 77,
              'event_id': 202,
              'ticket_qty': 1,
              'status': 'pending_receipt',
            },
          });
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BuyScreen(
              api: api,
              catalog: c,
              selectedEventId: 202,
              onSelectedEvent: (_) {},
              onOrderChanged: (_) {},
              onAccount: () {},
              onTickets: () {},
              receiptPicker: () async => null,
              imageBuilder: fakeImage,
            ),
          ),
        ),
      );
      expect(find.text('image:/bg.png'), findsOneWidget);
      expect(find.text('image:/flyer.png'), findsOneWidget);
      await tap(tester, find.byKey(const ValueKey('create-order')));
      expect(creates, 1);
      expect(find.text('Falta el comprobante'), findsOneWidget);
      expect(find.byType(DynamicTicketQrPanel), findsNothing);
    },
  );

  testWidgets(
    'resume existing order and ambiguous upload reconcile server state without another purchase',
    (tester) async {
      await largeScreen(tester);
      final dir = await tester.runAsync(
        () => Directory.systemTemp.createTemp('pulso-widget-'),
      );
      final file = File('${dir!.path}/receipt.png');
      await tester.runAsync(() => file.writeAsBytes([1, 2, 3]));
      var status = 'pending_receipt';
      var uploads = 0;
      var reads = 0;
      Map<String, dynamic>? saved;
      Map<String, dynamic> order() => {
        'id': 77,
        'order_id': 77,
        'event_id': 202,
        'ticket_qty': 3,
        'status': status,
      };
      final api = ApiService(
        config: localConfig(),
        session: await signedSession(),
        client: MockClient((req) async {
          if (req.url.path.endsWith('/purchase_get.php')) {
            reads++;
            return response(200, {'ok': true, 'order': order()});
          }
          expect(req.url.path, endsWith('/purchase_upload_receipt.php'));
          uploads++;
          status = 'in_review';
          throw TimeoutException('SYNTHETIC upload response lost after commit');
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BuyScreen(
              api: api,
              catalog: EventCatalog.fromJson(catalog(), localConfig()),
              resumeOrder: AccessItem({
                ...order(),
                'item_type': 'order',
                'event_title': 'AZUL',
              }),
              onSelectedEvent: (_) {},
              onOrderChanged: (o) {
                saved = o;
              },
              onAccount: () {},
              onTickets: () {},
              receiptPicker: () async => file.path,
              imageBuilder: fakeImage,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(reads, 1);
      expect(find.text('Falta el comprobante'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('upload-receipt')));
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('upload-receipt')));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();
      expect(uploads, 1);
      expect(reads, 2);
      expect(saved!['status'], 'in_review');
      expect(find.text('Comprobante en revisión'), findsOneWidget);
      expect(find.byKey(const ValueKey('upload-receipt')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await file.delete();
        await dir.delete();
      });
    },
  );

  testWidgets(
    'pending and rejected states are distinct; three approved units have separate QR controls',
    (tester) async {
      await largeScreen(tester);
      var qrCalls = 0;
      final items = [
        for (final (id, status) in [
          (11, 'pending_receipt'),
          (12, 'in_review'),
          (13, 'rejected'),
        ])
          {
            'item_type': 'order',
            'id': id,
            'order_id': id,
            'event_id': 202,
            'event_title': 'AZUL',
            'status': status,
          },
        for (var i = 1; i <= 3; i++)
          {
            'item_type': 'ticket',
            'id': 50 + i,
            'ticket_id': 50 + i,
            'order_id': 77,
            'event_id': 202,
            'event_title': 'AZUL',
            'status': 'active',
            'ticket_index': i,
            'ticket_count': 3,
          },
      ];
      final api = ApiService(
        config: localConfig(),
        session: await signedSession(),
        client: MockClient((req) async {
          if (req.url.path.endsWith('/my_tickets.php')) {
            return response(200, {'ok': true, 'items': items});
          }
          if (req.url.path.endsWith('/ticket_transfers.php')) {
            return response(200, {'ok': true, 'incoming': [], 'outgoing': []});
          }
          qrCalls++;
          return response(503, {'ok': false});
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TicketsScreen(api: api, onAccount: () {}, onResume: (_) {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final label in [
        'Falta el comprobante',
        'Comprobante en revisión',
        'Comprobante rechazado',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      for (var id = 51; id <= 53; id++) {
        expect(find.byKey(ValueKey('ticket-qr-$id')), findsOneWidget);
      }
      expect(find.byKey(const ValueKey('ticket-qr-11')), findsNothing);
      expect(qrCalls, 0);
    },
  );
}
