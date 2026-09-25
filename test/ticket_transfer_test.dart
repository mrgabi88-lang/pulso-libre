import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pulso_libre_app/main.dart';
import 'package:pulso_libre_app/models/event.dart';
import 'package:pulso_libre_app/services/api_service.dart';
import 'package:pulso_libre_app/services/session_store.dart';
import 'package:pulso_libre_app/services/ticket_transfer_intents.dart';
import 'package:pulso_libre_app/widgets/brand_style.dart';
import 'helpers.dart';

Map<String, dynamic> transfer({
  int id = 91,
  int ticketId = 51,
  bool incoming = false,
  String status = 'pending',
  String requestId = '',
  String email = 'recipient@example.invalid',
}) => {
  'id': id,
  'ticket_id': ticketId,
  'event_id': 101,
  'event_title': 'RECITAL DE EJEMPLO',
  'ticket_index': 1,
  'ticket_count': 2,
  'status': status,
  'created_at': '2030-06-08T18:00:00+00:00',
  'expires_at': '2030-06-10T18:00:00+00:00',
  'can_accept': incoming && status == 'pending',
  'can_reject': incoming && status == 'pending',
  'can_cancel': !incoming && status == 'pending',
  if (!incoming) 'recipient_email': email,
  if (!incoming) 'request_id': requestId,
};
Map<String, dynamic> ticket({
  int id = 51,
  bool canTransfer = true,
  bool received = false,
  String status = 'active',
  int? pending,
}) => {
  'item_type': 'ticket',
  'id': id,
  'ticket_id': id,
  'order_id': 77,
  'event_id': 101,
  'event_title': 'RECITAL DE EJEMPLO',
  'ticket_index': 1,
  'ticket_count': 2,
  'status': status,
  'can_transfer': canTransfer,
  'pending_transfer_id': pending,
  'received_transfer': received,
  'qr_version': received ? 2 : 1,
};

class TransferFixture {
  final MemoryVault vault;
  final SessionStore session;
  late final ApiService api;
  List<Map<String, dynamic>> items = [ticket()];
  List<Map<String, dynamic>> incoming = [];
  List<Map<String, dynamic>> outgoing = [];
  final requests = <http.Request>[];
  final committed = <String, Map<String, dynamic>>{};
  bool loseCreateReply = false;
  bool unavailable = false;
  bool malformedList = false;
  Completer<void>? holdCreate;
  int qrCalls = 0;
  TransferFixture(this.vault, this.session) {
    api = ApiService(
      config: localConfig(),
      session: session,
      client: MockClient(handle),
    );
  }
  static Future<TransferFixture> create() async {
    final vault = MemoryVault();
    return TransferFixture(vault, await signedSession(vault));
  }

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    final endpoint = request.url.path.split('/').last;
    if (endpoint == 'events.php') {
      return response(200, {'ok': true, 'items': [], 'upcoming_events': []});
    }
    if (endpoint == 'me.php') return response(200, {'ok': true, 'user': buyer});
    expect(request.headers['Authorization'], 'Bearer SYNTHETIC_TOKEN_ONLY');
    if (endpoint == 'my_tickets.php') {
      return response(200, {'ok': true, 'items': items});
    }
    if (endpoint == 'ticket_transfers.php') {
      if (unavailable) {
        return response(404, {
          'ok': false,
          'error': 'Transferencias no disponibles.',
        });
      }
      if (malformedList) {
        return response(200, {'ok': true, 'incoming': null, 'outgoing': []});
      }
      return response(200, {
        'ok': true,
        'incoming': incoming,
        'outgoing': outgoing,
      });
    }
    if (endpoint == 'ticket_qr.php') {
      qrCalls++;
      return response(503, {'ok': false});
    }
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    if (endpoint == 'ticket_transfer_create.php') {
      if (holdCreate != null) await holdCreate!.future;
      final id = body['request_id'] as String;
      final result = committed.putIfAbsent(
        id,
        () => transfer(
          ticketId: body['ticket_id'],
          requestId: id,
          email: body['recipient_email'],
        ),
      );
      outgoing = [result];
      items = [ticket(canTransfer: false, pending: 91)];
      if (loseCreateReply) {
        loseCreateReply = false;
        throw http.ClientException('Synthetic lost reply');
      }
      return response(200, {
        'ok': true,
        'transfer': result,
        'already_processed': false,
      });
    }
    if (endpoint == 'ticket_transfer_action.php') {
      final action = body['action'];
      final status = {
        'accept': 'accepted',
        'reject': 'rejected',
        'cancel': 'cancelled',
      }[action]!;
      final isIncoming = action != 'cancel';
      final old = (isIncoming ? incoming : outgoing).firstWhere(
        (item) => item['id'] == body['transfer_id'],
      );
      final result = transfer(
        id: old['id'],
        ticketId: old['ticket_id'],
        incoming: isIncoming,
        status: status,
        requestId: old['request_id'] ?? '',
        email: old['recipient_email'] ?? 'recipient@example.invalid',
      );
      if (isIncoming) {
        incoming = [];
      } else {
        outgoing = [result];
        items = [ticket()];
      }
      if (action == 'accept') {
        items = [ticket(id: old['ticket_id'], received: true)];
      }
      return response(200, {
        'ok': true,
        'transfer': result,
        'already_processed': false,
      });
    }
    throw StateError('Unexpected endpoint $endpoint');
  }

  List<http.Request> calls(String endpoint) => requests
      .where((request) => request.url.path.endsWith('/$endpoint'))
      .toList();
}

Future<void> tap(WidgetTester tester, String key) async {
  await tester.pumpAndSettle();
  final target = find.byKey(ValueKey(key));
  if (target.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      target,
      180,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> showTickets(
  WidgetTester tester,
  TransferFixture fixture, {
  double scale = 1,
}) async {
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: pulsoTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: TicketsScreen(
          api: fixture.api,
          onAccount: () {},
          onResume: (_) =>
              fail('Transferred recipient must not open another buyer receipt'),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> reviewTransfer(
  WidgetTester tester, {
  String email = 'recipient@example.invalid',
}) async {
  await tap(tester, 'transfer-ticket-51');
  await tester.enterText(
    find.byKey(const ValueKey('transfer-recipient-email')),
    email,
  );
  await tap(tester, 'transfer-review');
}

class DelayedTransferVault extends MemoryVault {
  final began = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> write(String key, String value) async {
    if (key == SessionStore.transferIntentsKey && !began.isCompleted) {
      began.complete();
      await release.future;
    }
    return super.write(key, value);
  }
}

void main() {
  test(
    'API transfer sends bearer and persisted UUID but no actor ID or URL email',
    () async {
      final fixture = await TransferFixture.create();
      final intent = await fixture.api.transferIntents.begin(
        51,
        'recipient@example.invalid',
      );
      expect(
        fixture.vault.values[SessionStore.transferIntentsKey],
        contains(intent.requestId),
      );
      final result = await fixture.api.createTicketTransfer(
        51,
        ' RECIPIENT@example.invalid ',
        existingIntent: intent,
      );
      final request = fixture.calls('ticket_transfer_create.php').single;
      expect(jsonDecode(request.body), {
        'ticket_id': 51,
        'recipient_email': 'recipient@example.invalid',
        'request_id': intent.requestId,
      });
      expect(request.url.query, isEmpty);
      expect(result.status, 'pending');
      expect(fixture.session.authenticated, isTrue);
    },
  );

  test(
    'ambiguous send survives restart and retries the same persisted request',
    () async {
      final fixture = await TransferFixture.create();
      fixture.loseCreateReply = true;
      await expectLater(
        fixture.api.createTicketTransfer(51, 'recipient@example.invalid'),
        throwsA(isA<ApiException>()),
      );
      final first = jsonDecode(
        fixture.calls('ticket_transfer_create.php').single.body,
      )['request_id'];
      final session = SessionStore(vault: fixture.vault);
      await session.load();
      session.acceptValidatedUser(buyer, unlock: true);
      final api = ApiService(
        config: localConfig(),
        session: session,
        client: MockClient(fixture.handle),
      );
      final result = await api.createTicketTransfer(
        51,
        'recipient@example.invalid',
      );
      final second = jsonDecode(
        fixture.calls('ticket_transfer_create.php').last.body,
      )['request_id'];
      expect(first, second);
      expect(result.id, 91);
      expect(fixture.committed.length, 1);
      expect(await api.transferIntents.pending(51), isNull);
    },
  );

  test(
    'logout clears recipient intents after an in-flight secure write',
    () async {
      final vault = DelayedTransferVault();
      final session = await signedSession(vault);
      await session.beginPurchaseIntent(101, 1);
      final originalPurchase = vault.values[SessionStore.purchaseIntentsKey];
      final store = TicketTransferIntents(session);
      final pending = store.begin(51, 'recipient@example.invalid');
      final failed = expectLater(pending, throwsA(isA<StateError>()));
      await vault.began.future;
      final clearing = session.clear();
      vault.release.complete();
      await failed;
      await clearing;
      expect(
        vault.values.containsKey(SessionStore.transferIntentsKey),
        isFalse,
      );
      expect(vault.values[SessionStore.purchaseIntentsKey], originalPurchase);
    },
  );

  test(
    'another account or vault cannot recover an earlier recipient intent',
    () async {
      final fixture = await TransferFixture.create();
      await fixture.api.transferIntents.begin(51, 'recipient@example.invalid');
      final other = SessionStore(vault: fixture.vault);
      await other.acceptLogin({
        ...loginEnvelope,
        'user': {...buyer, 'id': 9002, 'email': 'other@example.invalid'},
        'access_token': 'OTHER_SYNTHETIC_TOKEN',
      });
      expect(await TicketTransferIntents(other).pending(51), isNull);
      final separate = await signedSession(MemoryVault());
      expect(await TicketTransferIntents(separate).pending(51), isNull);
    },
  );

  test(
    'malformed transfer catalog is an error rather than an empty inbox',
    () async {
      final fixture = await TransferFixture.create();
      fixture.malformedList = true;
      await expectLater(
        fixture.api.fetchTicketTransfers(),
        throwsA(isA<ApiException>()),
      );
    },
  );

  test(
    'transferred and received ticket capabilities protect QR and receipts',
    () {
      final sent = AccessItem(
        ticket(status: 'transferred', canTransfer: false),
      );
      expect(sent.qrEnabled, isFalse);
      expect(sent.canTransfer, isFalse);
      expect(sent.label, 'Entrada transferida');
      final received = AccessItem({
        ...ticket(received: true),
        'item_type': 'order',
        'status': 'rejected',
      });
      expect(received.canUpload, isFalse);
    },
  );

  testWidgets(
    'transfer requires reviewed ticket and recipient before POST; sender keeps QR pending',
    (tester) async {
      final fixture = await TransferFixture.create();
      await showTickets(tester, fixture);
      await reviewTransfer(tester);
      expect(
        find.byKey(const ValueKey('transfer-reviewed-email')),
        findsOneWidget,
      );
      expect(find.text('Para: recipient@example.invalid'), findsOneWidget);
      expect(fixture.calls('ticket_transfer_create.php'), isEmpty);
      await tap(tester, 'transfer-confirm-send');
      expect(fixture.calls('ticket_transfer_create.php').length, 1);
      expect(find.byKey(const ValueKey('transfer-cancel-91')), findsOneWidget);
      expect(find.byKey(const ValueKey('ticket-qr-51')), findsOneWidget);
      expect(find.byKey(const ValueKey('transfer-ticket-51')), findsNothing);
      expect(
        find.textContaining('La otra persona la verá en Entradas'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'invalid and own recipient stay local; closing review sends nothing',
    (tester) async {
      final fixture = await TransferFixture.create();
      await showTickets(tester, fixture);
      await tap(tester, 'transfer-ticket-51');
      await tester.enterText(
        find.byKey(const ValueKey('transfer-recipient-email')),
        'wrong',
      );
      await tap(tester, 'transfer-review');
      expect(find.text('Ingresá un correo válido.'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('transfer-recipient-email')),
        'buyer@example.invalid',
      );
      await tap(tester, 'transfer-review');
      expect(find.text('Ingresá el correo de otra persona.'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('transfer-recipient-email')),
        'recipient@example.invalid',
      );
      await tap(tester, 'transfer-review');
      await tap(tester, 'transfer-dialog-close');
      expect(fixture.calls('ticket_transfer_create.php'), isEmpty);
    },
  );

  testWidgets('server eligibility is required to offer Transferir', (
    tester,
  ) async {
    final fixture = await TransferFixture.create();
    fixture.items = [ticket(canTransfer: false)];
    await showTickets(tester, fixture);
    expect(find.byKey(const ValueKey('transfer-ticket-51')), findsNothing);
    expect(find.byKey(const ValueKey('ticket-qr-51')), findsOneWidget);
  });

  for (final action in ['accept', 'reject', 'cancel']) {
    testWidgets('$action requires confirmation and refreshes ownership', (
      tester,
    ) async {
      final fixture = await TransferFixture.create();
      if (action == 'cancel') {
        fixture.items = [ticket(canTransfer: false, pending: 91)];
        fixture.outgoing = [transfer()];
      } else {
        fixture.items = [];
        fixture.incoming = [transfer(incoming: true)];
      }
      await showTickets(tester, fixture);
      await tap(tester, 'transfer-$action-91');
      expect(fixture.calls('ticket_transfer_action.php'), isEmpty);
      await tap(tester, 'transfer-action-confirm');
      final request = fixture.calls('ticket_transfer_action.php').single;
      expect(jsonDecode(request.body), {'transfer_id': 91, 'action': action});
      if (action == 'accept') {
        expect(find.byKey(const ValueKey('ticket-qr-51')), findsOneWidget);
        expect(
          find.textContaining('Recibiste esta entrada y sos su titular.'),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('resume-order-77')), findsNothing);
      } else if (action == 'reject') {
        expect(find.byKey(const ValueKey('ticket-qr-51')), findsNothing);
      } else {
        expect(find.byKey(const ValueKey('ticket-qr-51')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('transfer-ticket-51')),
          findsOneWidget,
        );
      }
    });
  }

  testWidgets(
    'lost reply reconciles status and retries same ID without another invitation',
    (tester) async {
      final fixture = await TransferFixture.create();
      fixture.loseCreateReply = true;
      await showTickets(tester, fixture);
      await reviewTransfer(tester);
      await tap(tester, 'transfer-confirm-send');
      expect(find.textContaining('reintentá este mismo envío'), findsOneWidget);
      expect(fixture.committed.length, 1);
      await tap(tester, 'transfer-confirm-send');
      final ids = fixture
          .calls('ticket_transfer_create.php')
          .map((request) => jsonDecode(request.body)['request_id'])
          .toList();
      expect(ids.length, 2);
      expect(ids.toSet().length, 1);
      expect(fixture.committed.length, 1);
    },
  );

  testWidgets(
    'closing an in-flight transfer does not allow duplicate taps or lose reconciliation',
    (tester) async {
      final fixture = await TransferFixture.create();
      fixture.holdCreate = Completer<void>();
      await showTickets(tester, fixture);
      await reviewTransfer(tester);
      await tap(tester, 'transfer-confirm-send');
      await tap(tester, 'transfer-confirm-send');
      expect(fixture.calls('ticket_transfer_create.php').length, 1);
      await tap(tester, 'transfer-dialog-close');
      fixture.holdCreate!.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('transfer-cancel-91')), findsOneWidget);
      expect(fixture.committed.length, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unsupported transfer server leaves existing tickets usable and shows an error',
    (tester) async {
      final fixture = await TransferFixture.create();
      fixture.unavailable = true;
      await showTickets(tester, fixture);
      expect(
        find.textContaining('No pudimos consultar las transferencias'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('ticket-qr-51')), findsOneWidget);
      expect(find.byKey(const ValueKey('transfer-ticket-51')), findsNothing);
      expect(find.text('Todavía no tenés órdenes ni entradas.'), findsNothing);
    },
  );

  testWidgets(
    'accepted outgoing result conceals sender QR even when concurrent ticket list is older',
    (tester) async {
      final fixture = await TransferFixture.create();
      fixture.items = [ticket(canTransfer: false, pending: 91)];
      fixture.outgoing = [transfer()];
      await showTickets(tester, fixture);
      expect(find.byKey(const ValueKey('ticket-qr-51')), findsOneWidget);
      fixture.outgoing = [transfer(status: 'accepted')];
      await tester.tap(find.byTooltip('Actualizar entradas'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ticket-qr-51')), findsNothing);
      fixture.unavailable = true;
      await tester.tap(find.byTooltip('Actualizar entradas'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('ticket-qr-51')),
        findsNothing,
        reason:
            'A failed catalog refresh must not restore a QR already transferred.',
      );
      fixture.unavailable = false;
      fixture.items = [ticket(status: 'transferred', canTransfer: false)];
      await tester.tap(find.byTooltip('Actualizar entradas'));
      await tester.pumpAndSettle();
      expect(find.text('Entrada transferida'), findsOneWidget);
      expect(find.byKey(const ValueKey('ticket-qr-51')), findsNothing);
    },
  );

  testWidgets('lock closes transfer dialog and hides recipient and inbox', (
    tester,
  ) async {
    final fixture = await TransferFixture.create();
    await showTickets(tester, fixture);
    await reviewTransfer(tester);
    fixture.session.lock();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.textContaining('recipient@example.invalid'), findsNothing);
    expect(find.text('Cuenta requerida'), findsOneWidget);
    expect(fixture.calls('ticket_transfer_create.php'), isEmpty);
  });

  testWidgets(
    'replacement API and vault with the same credentials discard the old dialog and late result',
    (tester) async {
      final original = await TransferFixture.create();
      original.holdCreate = Completer<void>();
      await showTickets(tester, original);
      await reviewTransfer(tester);
      await tap(tester, 'transfer-confirm-send');
      final replacement = await TransferFixture.create();
      await showTickets(tester, replacement);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.textContaining('recipient@example.invalid'), findsNothing);
      original.holdCreate!.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('transfer-cancel-91')), findsNothing);
      expect(find.byKey(const ValueKey('transfer-ticket-51')), findsOneWidget);
      expect(replacement.calls('ticket_transfer_create.php'), isEmpty);
      expect(replacement.vault.values[SessionStore.transferIntentsKey], isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'inbox and transfer confirmation fit width320 with doubled text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = await TransferFixture.create();
      fixture.incoming = [transfer(id: 92, ticketId: 52, incoming: true)];
      await showTickets(tester, fixture, scale: 2);
      await tap(tester, 'transfer-accept-92');
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Volver'));
      await tester.pumpAndSettle();
      await reviewTransfer(tester);
      expect(
        find.byKey(const ValueKey('transfer-reviewed-email')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tap(tester, 'transfer-dialog-close');
    },
  );

}
