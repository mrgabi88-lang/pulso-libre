import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pulso_libre_app/main.dart';
import 'package:pulso_libre_app/models/event.dart';
import 'package:pulso_libre_app/services/api_service.dart';
import 'package:pulso_libre_app/services/session_store.dart';
import 'package:pulso_libre_app/widgets/event_media.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../integration_test/ui_navigation.dart';
import 'helpers.dart';
import 'qr_test.dart' show qr;

Map<String, dynamic> _event(String mode, {int stock = 12}) => {
  ...event(202, 'TALLER DE CERÁMICA'),
  'sale_mode': mode,
  'price_from': mode == 'receipt_manual' ? 100 : 0,
  'stock_available': stock,
  'description': 'Un encuentro para aprender y crear.',
  'background_url': '/taller-fondo.png',
  'flyer_urls': ['/taller-flyer.png'],
  'tracks': <Map<String, dynamic>>[],
};

Map<String, dynamic> _catalog(Map<String, dynamic> item) => {
  'ok': true,
  'items': [item],
  'upcoming_events': [item],
  'featured_event_id': 202,
};

Map<String, dynamic> _freeOrder(
  int qty, {
  String status = 'pending_approval',
}) => {
  'id': 77,
  'event_id': 202,
  'ticket_qty': qty,
  'status': status,
  'sale_mode': 'free',
  'price_unit': 0,
  'amount_total': 0,
  'requires_receipt': false,
  'receipt_url': null,
  'current_receipt_id': null,
};

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

class _Navigation extends PhysicalUi {
  const _Navigation(super.tester);
  @override
  Future<void> tap(Finder target) async {
    await super.tap(target);
    await tester.pumpAndSettle();
  }
}

void main() {
  test('admission requires explicit valid mode and declared price', () {
    PulsoEvent parsed(Map<String, dynamic> data) =>
        PulsoEvent.fromJson(data, localConfig());
    final free = parsed(_event('free'));
    final open = parsed(_event('open'));
    final paid = parsed(_event('receipt_manual'));
    final promotion = parsed(_event('none'));
    expect(free.isFreeReservation, isTrue);
    expect(free.admissionLabel('0'), 'Gratis');
    expect(free.canReserve, isTrue);
    expect(open.isOpenEntry, isTrue);
    expect(open.admissionLabel('0'), 'Entrada libre');
    expect(open.canReserve, isFalse);
    expect(paid.isPaid, isTrue);
    expect(paid.admissionLabel('100'), 'Desde \$100');
    expect(promotion.admissionLabel('0'), 'Difusión');
    expect(promotion.canReserve, isFalse);
    for (final data in [
      {..._event('free')}..remove('sale_mode'),
      {..._event('free')}..remove('price_from'),
      {..._event('free'), 'price_from': null},
      {..._event('free'), 'price_from': 'no disponible'},
      {..._event('free'), 'price_from': 10},
      {..._event('open'), 'price_from': -1},
      {..._event('receipt_manual'), 'price_from': 0},
      {..._event('unknown')},
    ]) {
      final invalid = parsed(data);
      expect(invalid.isFreeReservation, isFalse, reason: '$data');
      expect(invalid.isOpenEntry, isFalse, reason: '$data');
      expect(invalid.canReserve, isFalse, reason: '$data');
      expect(invalid.admissionLabel('0'), 'Consultar acceso');
    }
    expect(free.tracks, isEmpty);
  });

  test('free approval is not itself a QR and never requests a receipt', () {
    final order = AccessItem({
      ..._freeOrder(2, status: 'approved'),
      'item_type': 'order',
    });
    expect(order.label, 'Reserva confirmada');
    expect(order.qrEnabled, isFalse);
    expect(order.canUpload, isFalse);
    final pending = AccessItem({...order.data, 'status': 'pending_receipt'});
    expect(pending.label, 'Pendiente de aprobación');
    expect(pending.canUpload, isFalse);
    final ticket = AccessItem({
      ...order.data,
      'item_type': 'ticket',
      'ticket_id': 55,
      'status': 'active',
      'qr_enabled': true,
    });
    expect(ticket.qrEnabled, isTrue);
    expect(AccessItem({...ticket.data, 'status': 'used'}).qrEnabled, isFalse);
    expect(
      AccessItem({...ticket.data, 'status': 'transferred'}).qrEnabled,
      isFalse,
    );
  });

  test(
    'pending and rejected free requests ignore contradictory ticket capabilities',
    () {
      for (final status in ['pending_approval', 'rejected']) {
        final request = AccessItem({
          ..._freeOrder(1, status: status),
          'item_type': 'order',
          'ticket_id': 55,
          'qr_enabled': true,
          'can_transfer': true,
          'can_upload_receipt': true,
          'requires_receipt': true,
        });
        expect(request.qrEnabled, isFalse);
        expect(request.canTransfer, isFalse);
        expect(request.canUpload, isFalse);
        expect(
          request.label,
          status == 'rejected'
              ? 'Solicitud rechazada'
              : 'Pendiente de aprobación',
        );
        expect(request.explanation, isNot(contains('enviá uno nuevo')));
      }
    },
  );

  test(
    'purchase reload accepts pending approval and still rejects unknown status',
    () async {
      final session = await signedSession();
      var status = 'pending_approval';
      final api = ApiService(
        config: localConfig(),
        session: session,
        client: MockClient((request) async {
          expect(request.url.path, endsWith('/purchase_get.php'));
          expect(request.url.queryParameters['order_id'], '77');
          return response(200, {
            'ok': true,
            'order': _freeOrder(1, status: status),
          });
        }),
      );
      for (final known in ['pending_approval', 'rejected', 'approved']) {
        status = known;
        expect((await api.getPurchase(77))['status'], known);
      }
      status = 'unrecognized';
      await expectLater(api.getPurchase(77), throwsA(isA<ApiException>()));
      session.dispose();
    },
  );

  for (final finalStatus in ['pending_approval', 'rejected']) {
    testWidgets(
      'free $finalStatus survives session restart without QR or receipt actions',
      (tester) async {
        _phone(tester);
        final vault = MemoryVault();
        var session = await signedSession(vault);
        var status = 'pending_approval';
        var ticketReads = 0;
        final calls = <String>[];
        final client = MockClient((request) async {
          final endpoint = request.url.path.split('/').last;
          calls.add(endpoint);
          switch (endpoint) {
            case 'me.php':
              return response(200, {'ok': true, 'user': buyer});
            case 'my_tickets.php':
              ticketReads++;
              return response(200, {
                'ok': true,
                'items': [
                  {
                    ..._freeOrder(2, status: status),
                    'item_type': 'order',
                    'order_id': 77,
                    'event_title': 'TALLER DE CERÁMICA',
                    'review_notes': status == 'rejected'
                        ? 'Inscripción cerrada.'
                        : '',
                    'qr_enabled': false,
                    'can_transfer': false,
                    'can_upload_receipt': false,
                  },
                ],
              });
            case 'ticket_transfers.php':
              return response(200, {
                'ok': true,
                'incoming': [],
                'outgoing': [],
              });
            default:
              fail(
                'Free request must not call QR/upload/transfer mutations: $endpoint',
              );
          }
        });
        ApiService apiFor(SessionStore value) =>
            ApiService(config: localConfig(), session: value, client: client);
        Future<void> mount(ApiService api) async {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: TicketsScreen(
                  api: api,
                  onAccount: () =>
                      fail('Authenticated request unexpectedly lost session'),
                  onResume: (_) =>
                      fail('Free request cannot resume receipt upload'),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
        }

        void expectLocked(String expected) {
          expect(find.text(expected), findsOneWidget);
          expect(find.text('Mostrar QR'), findsNothing);
          expect(find.byType(QrImageView), findsNothing);
          expect(find.text('Transferir entrada'), findsNothing);
          expect(find.byKey(const ValueKey('resume-order-77')), findsNothing);
          expect(find.text('Enviar nuevo comprobante'), findsNothing);
          expect(find.byType(PaymentInfo), findsNothing);
          expect(tester.takeException(), isNull);
        }

        await mount(apiFor(session));
        expectLocked('Pendiente de aprobación');
        status = finalStatus;
        if (status == 'rejected') {
          await _Navigation(tester).tap(find.byTooltip('Actualizar entradas'));
          expectLocked('Solicitud rechazada');
          expect(
            find.textContaining('Motivo: Inscripción cerrada.'),
            findsOneWidget,
          );
        }
        await tester.pumpWidget(const SizedBox());
        session.dispose();
        session = SessionStore(vault: vault);
        final restored = apiFor(session);
        await restored.restoreSession(unlock: true);
        expect(session.authenticated, isTrue);
        await mount(restored);
        expectLocked(
          status == 'rejected'
              ? 'Solicitud rechazada'
              : 'Pendiente de aprobación',
        );
        expect(ticketReads, greaterThanOrEqualTo(2));
        expect(calls.toSet(), {
          'me.php',
          'my_tickets.php',
          'ticket_transfers.php',
        });
        await tester.pumpWidget(const SizedBox());
        session.dispose();
        client.close();
      },
    );
  }

  testWidgets(
    'free request retains event through login and shows QR only after organizer approval',
    (tester) async {
      _phone(tester);
      final nav = _Navigation(tester);
      final session = SessionStore(vault: MemoryVault());
      var creates = 0;
      var picks = 0;
      var approved = false;
      final qrRequests = <int>[];
      final api = ApiService(
        config: localConfig(),
        session: session,
        client: MockClient((req) async {
          switch (req.url.path.split('/').last) {
            case 'events.php':
              return response(200, _catalog(_event('free')));
            case 'login.php':
              return response(200, loginEnvelope);
            case 'purchase_create.php':
              final body = jsonDecode(req.body) as Map<String, dynamic>;
              expect(
                body.keys,
                unorderedEquals(['event_id', 'ticket_qty', 'request_id']),
              );
              expect(body['event_id'], 202);
              expect(body['ticket_qty'], 2);
              creates++;
              return response(200, {'ok': true, 'order': _freeOrder(2)});
            case 'my_tickets.php':
              return response(200, {
                'ok': true,
                'items': [
                  if (!approved)
                    {
                      ..._freeOrder(2),
                      'item_type': 'order',
                      'order_id': 77,
                      'event_title': 'TALLER DE CERÁMICA',
                      'can_upload_receipt': false,
                      'can_transfer': false,
                      'qr_enabled': false,
                    },
                  if (approved)
                    for (final id in [55, 56])
                      {
                        'item_type': 'ticket',
                        'id': id,
                        'ticket_id': id,
                        'order_id': 77,
                        'event_id': 202,
                        'event_title': 'TALLER DE CERÁMICA',
                        'status': 'active',
                        'sale_mode': 'free',
                        'requires_receipt': false,
                        'ticket_index': id - 54,
                        'ticket_count': 2,
                        'qr_enabled': true,
                        'can_transfer': true,
                      },
                ],
              });
            case 'ticket_transfers.php':
              return response(200, {
                'ok': true,
                'incoming': [],
                'outgoing': [],
              });
            case 'ticket_qr.php':
              final id = int.parse(req.url.queryParameters['ticket_id']!);
              qrRequests.add(id);
              return response(200, {
                ...qr('SYNTHETIC-FREE-$id'),
                'ticket_id': id,
              });
            default:
              fail('Unexpected API request: ${req.url.path}');
          }
        }),
      );
      await tester.pumpWidget(
        PulsoLibreApp(
          api: api,
          imageBuilder: fakeImage,
          receiptPicker: () async {
            picks++;
            return null;
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Gratis'), findsOneWidget);
      expect(find.text('Desde \$0'), findsNothing);
      await nav.tap(find.byKey(const ValueKey('buy-event-202')));
      expect(find.text('Solicitar entrada gratis'), findsOneWidget);
      expect(find.byType(EventTracks), findsNothing);
      expect(find.byKey(const ValueKey('event-audio-toggle')), findsNothing);
      expect(find.text('image:/taller-fondo.png'), findsOneWidget);
      await nav.tap(find.text('Ingresar o crear cuenta'));
      await nav.enterText(
        find.byKey(const ValueKey('account-email')),
        'buyer@example.invalid',
      );
      await nav.enterText(
        find.byKey(const ValueKey('account-password')),
        'SYNTHETIC',
      );
      await nav.tap(find.widgetWithText(FilledButton, 'Entrar'));
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('purchase-event-title')))
            .data,
        'TALLER DE CERÁMICA',
      );
      await nav.tap(find.byKey(const ValueKey('purchase-quantity')));
      await nav.tap(find.text('2').last);
      await nav.tap(find.byKey(const ValueKey('create-order')));
      expect(creates, 1);
      expect(find.text('Pendiente de aprobación'), findsOneWidget);
      expect(
        find.text('2 entradas · Gratis · Sin pago ni comprobante'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('upload-receipt')), findsNothing);
      expect(find.byType(PaymentInfo), findsNothing);
      await nav.tap(find.text('Ver mis entradas'));
      expect(find.text('Pendiente de aprobación'), findsOneWidget);
      expect(find.byType(QrImageView), findsNothing);
      expect(find.text('Mostrar QR'), findsNothing);
      expect(find.text('Transferir entrada'), findsNothing);
      expect(find.byKey(const ValueKey('resume-order-77')), findsNothing);
      expect(qrRequests, isEmpty);
      expect(picks, 0);
      approved = true;
      await nav.tap(find.byTooltip('Actualizar entradas'));
      expect(find.byKey(const ValueKey('ticket-qr-55')), findsOneWidget);
      expect(find.byKey(const ValueKey('ticket-qr-56')), findsOneWidget);
      await nav.tap(
        find.descendant(
          of: find.byKey(const ValueKey('ticket-qr-55')),
          matching: find.text('Mostrar QR'),
        ),
      );
      expect(qrRequests, [55]);
      expect(find.byType(QrImageView), findsOneWidget);
      expect(picks, 0);
      expect(find.byKey(const ValueKey('global-navigation')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );

  for (final mode in ['open', 'none']) {
    testWidgets('$mode preserves public identity without login, order or QR', (
      tester,
    ) async {
      _phone(tester);
      final session = SessionStore(vault: MemoryVault());
      final api = ApiService(
        config: localConfig(),
        session: session,
        client: MockClient((req) async {
          expect(req.url.path, endsWith('/events.php'));
          return response(200, _catalog(_event(mode)));
        }),
      );
      await tester.pumpWidget(PulsoLibreApp(api: api, imageBuilder: fakeImage));
      await tester.pumpAndSettle();
      expect(
        find.text(mode == 'open' ? 'Entrada libre' : 'Difusión'),
        findsOneWidget,
      );
      await _Navigation(
        tester,
      ).tap(find.byKey(const ValueKey('buy-event-202')));
      expect(find.byKey(const ValueKey('purchase-quantity')), findsNothing);
      expect(find.byKey(const ValueKey('create-order')), findsNothing);
      expect(find.text('Ingresar o crear cuenta'), findsNothing);
      expect(find.text('image:/taller-fondo.png'), findsOneWidget);
      expect(
        find.text(
          mode == 'open'
              ? 'Entrada libre. No necesitás reservar, pagar ni generar un QR desde la app.'
              : 'Este evento es de difusión. No ofrece entradas desde la app.',
        ),
        findsOneWidget,
      );
      expect(find.byType(QrImageView), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    });
  }

  for (final mode in ['free', 'receipt_manual']) {
    testWidgets('$mode sold out prevents submitting any order', (tester) async {
      _phone(tester);
      final session = await signedSession();
      final api = ApiService(
        config: localConfig(),
        session: session,
        client: MockClient((req) async {
          expect(req.url.path, endsWith('/events.php'));
          return response(200, _catalog(_event(mode, stock: 0)));
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BuyScreen(
              api: api,
              catalog: EventCatalog.fromJson(
                _catalog(_event(mode, stock: 0)),
                localConfig(),
              ),
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
      await tester.pumpAndSettle();
      final nav = _Navigation(tester);
      await nav.reveal(find.byKey(const ValueKey('create-order')));
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('create-order')))
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    });
  }

  test(
    'free reservation retry after timeout and restart reuses persisted intent',
    () async {
      final vault = MemoryVault();
      var session = await signedSession(vault);
      final seen = <String>[];
      var loseResponse = true;
      final committed = <String, Map<String, dynamic>>{};
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/me.php')) {
          return response(200, {'ok': true, 'user': buyer});
        }
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final requestId = body['request_id'] as String;
        seen.add(requestId);
        final order = committed.putIfAbsent(requestId, () => _freeOrder(2));
        if (loseResponse) {
          loseResponse = false;
          throw TimeoutException('Synthetic response lost');
        }
        return response(200, {'ok': true, 'order': order});
      });
      var api = ApiService(
        config: localConfig(),
        session: session,
        client: client,
      );
      await expectLater(
        api.createPurchase(202, 2),
        throwsA(isA<ApiException>()),
      );
      session.dispose();
      session = SessionStore(vault: vault);
      api = ApiService(config: localConfig(), session: session, client: client);
      await api.restoreSession(unlock: true);
      final restored = await api.createPurchase(202, 2);
      expect(restored['status'], 'pending_approval');
      expect(restored['requires_receipt'], isFalse);
      expect(seen[0], seen[1]);
      expect(committed, hasLength(1));
      session.dispose();
      client.close();
    },
  );
}
