import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:pulso_libre_app/services/api_config.dart';
import 'package:pulso_libre_app/services/api_service.dart';
import 'package:pulso_libre_app/services/session_store.dart';
import 'helpers.dart';

void main() {
  test(
    'late unauthorized response from buyer A never clears buyer B session',
    () async {
      final session = await signedSession();
      final pending = Completer<http.Response>();
      final started = Completer<void>();
      final api = ApiService(
        config: localConfig(),
        session: session,
        client: MockClient((req) {
          started.complete();
          return pending.future;
        }),
      );
      final oldRequest = api.fetchMyTickets();
      final expectation = expectLater(oldRequest, throwsA(isA<ApiException>()));
      await started.future;
      await session.acceptLogin({
        ...loginEnvelope,
        'access_token': 'SYNTHETIC_BUYER_B',
        'user': {...buyer, 'id': 9002, 'email': 'other@example.invalid'},
      });
      pending.complete(response(401, {'ok': false, 'code': 'UNAUTHENTICATED'}));
      await expectation;
      expect(session.authenticated, isTrue);
      expect(session.user!['id'], 9002);
      expect(session.token, 'SYNTHETIC_BUYER_B');
    },
  );

  test(
    'late me response cannot replace the newly logged in buyer profile',
    () async {
      final session = await signedSession();
      final pending = Completer<http.Response>();
      final started = Completer<void>();
      final api = ApiService(
        config: localConfig(),
        session: session,
        client: MockClient((_) {
          started.complete();
          return pending.future;
        }),
      );
      final request = api.restoreSession(unlock: true);
      final expectation = expectLater(request, throwsA(isA<ApiException>()));
      await started.future;
      await session.acceptLogin({
        ...loginEnvelope,
        'access_token': 'SYNTHETIC_BUYER_B',
        'user': {...buyer, 'id': 9002},
      });
      pending.complete(response(200, {'ok': true, 'user': buyer}));
      await expectation;
      expect(session.authenticated, isTrue);
      expect(session.user!['id'], 9002);
    },
  );
  test(
    'test guard rejects production, credentials in URL, and absent opt-in',
    () {
      for (final url in [
        'https://pllabs.com.ar/api/pulso_libre',
        'http://user:secret@127.0.0.1:18765/api',
      ]) {
        expect(
          () => ApiConfig(base: Uri.parse(url), localTest: true),
          throwsStateError,
        );
      }
      expect(
        () => ApiConfig(
          base: Uri.parse('http://127.0.0.1:18765/api'),
          localTest: false,
        ),
        throwsStateError,
      );
      expect(localConfig().base.host, '127.0.0.1');
    },
  );

  test('cached ID never restores authorization', () async {
    final vault = MemoryVault()..values['pulso_user_id'] = '9001';
    final session = SessionStore(vault: vault);
    var calls = 0;
    final api = ApiService(
      config: localConfig(),
      session: session,
      client: MockClient((_) async {
        calls++;
        return response(200, {'ok': true, 'user': buyer});
      }),
    );
    await api.restoreSession();
    expect(session.authenticated, isFalse);
    expect(calls, 0);
  });

  test(
    'token restoration validates me and remains biometrically locked until unlock',
    () async {
      final vault = MemoryVault();
      await signedSession(vault);
      expect(vault.values[SessionStore.credentialKey], isNot(contains('9001')));
      final session = SessionStore(vault: vault);
      await session.load();
      expect(session.authenticated, isFalse);
      final api = ApiService(
        config: localConfig(),
        session: session,
        client: MockClient((req) async {
          expect(req.url.path, endsWith('/me.php'));
          expect(req.headers['Authorization'], 'Bearer SYNTHETIC_TOKEN_ONLY');
          expect(req.followRedirects, isFalse);
          return response(200, {'ok': true, 'user': buyer});
        }),
      );
      await api.restoreSession();
      expect(session.locked, isTrue);
      expect(session.authenticated, isFalse);
      await api.restoreSession(unlock: true);
      expect(session.authenticated, isTrue);
    },
  );

  test('revoked token clears protected storage and profile', () async {
    final vault = MemoryVault();
    final session = await signedSession(vault);
    final api = ApiService(
      config: localConfig(),
      session: session,
      client: MockClient(
        (_) async => response(401, {
          'ok': false,
          'error': 'Sesión vencida',
          'code': 'UNAUTHENTICATED',
        }),
      ),
    );
    await expectLater(api.fetchMyTickets(), throwsA(isA<ApiException>()));
    expect(session.authenticated, isFalse);
    expect(session.user, isNull);
    expect(vault.values.containsKey(SessionStore.credentialKey), isFalse);
  });

  test('missing token or non-boolean verified flag cannot log in', () async {
    for (final data in [
      {'ok': true, 'user': buyer},
      {
        ...loginEnvelope,
        'user': {...buyer, 'email_verified': 'true'},
      },
    ]) {
      final vault = MemoryVault();
      final session = SessionStore(vault: vault);
      final api = ApiService(
        config: localConfig(),
        session: session,
        client: MockClient((_) async => response(200, data)),
      );
      await expectLater(
        api.login('buyer@example.invalid', 'SYNTHETIC'),
        throwsA(anything),
      );
      expect(session.authenticated, isFalse);
      expect(vault.values.containsKey(SessionStore.credentialKey), isFalse);
    }
  });

  test(
    'logout revokes with bearer; server failure does not claim success',
    () async {
      final session = await signedSession();
      var fail = true;
      final api = ApiService(
        config: localConfig(),
        session: session,
        client: MockClient((req) async {
          expect(req.method, 'POST');
          expect(req.url.path, endsWith('/logout.php'));
          expect(req.headers['Authorization'], 'Bearer SYNTHETIC_TOKEN_ONLY');
          return response(fail ? 503 : 200, {
            'ok': !fail,
            if (fail) 'error': 'No disponible',
          });
        }),
      );
      await expectLater(api.logout(), throwsA(isA<ApiException>()));
      expect(session.authenticated, isTrue);
      fail = false;
      await api.logout();
      expect(session.hasCredential, isFalse);
    },
  );

  test(
    'buyer endpoints send bearer, never user_id or a token in URL',
    () async {
      final session = await signedSession();
      final api = ApiService(
        config: localConfig(),
        session: session,
        client: MockClient((req) async {
          expect(req.headers['Authorization'], 'Bearer SYNTHETIC_TOKEN_ONLY');
          expect(req.url.toString(), isNot(contains('SYNTHETIC_TOKEN_ONLY')));
          expect(req.url.queryParameters.containsKey('user_id'), isFalse);
          if (req.url.path.endsWith('/my_tickets.php')) {
            return response(200, {'ok': true, 'items': []});
          }
          expect(req.url.queryParameters, {'ticket_id': '55'});
          return response(200, {'ok': true, 'qr_payload': 'SYNTHETIC'});
        }),
      );
      await api.fetchMyTickets();
      await api.fetchTicketQr(55);
    },
  );

  test(
    'timeout after server commit plus restart retries same persisted UUID and creates one order',
    () async {
      final vault = MemoryVault();
      var session = await signedSession(vault);
      final committed = <String, Map<String, dynamic>>{};
      final seen = <String>[];
      var loseResponse = true;
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/me.php')) {
          return response(200, {'ok': true, 'user': buyer});
        }
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        expect(body.containsKey('user_id'), isFalse);
        final requestId = body['request_id'] as String;
        expect(
          vault.values[SessionStore.purchaseIntentsKey],
          contains(requestId),
        );
        seen.add(requestId);
        final order = committed.putIfAbsent(
          requestId,
          () => {
            'id': 42,
            'event_id': 202,
            'ticket_qty': 3,
            'status': 'pending_receipt',
          },
        );
        if (loseResponse) {
          loseResponse = false;
          throw TimeoutException('SYNTHETIC response lost after commit');
        }
        return response(200, {'ok': true, 'order': order});
      });
      var api = ApiService(
        config: localConfig(),
        session: session,
        client: client,
      );
      await expectLater(
        api.createPurchase(202, 3),
        throwsA(isA<ApiException>()),
      );
      session = SessionStore(vault: vault);
      api = ApiService(config: localConfig(), session: session, client: client);
      await api.restoreSession(unlock: true);
      final result = await api.createPurchase(202, 3);
      expect(result['id'], 42);
      expect(committed.length, 1);
      expect(seen[0], seen[1]);
      expect(
        seen[0],
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
      expect(
        jsonDecode(vault.values[SessionStore.purchaseIntentsKey]!),
        isEmpty,
      );
    },
  );

  test(
    'receipt upload uses existing order and bearer without creating another order',
    () async {
      final dir = await Directory.systemTemp.createTemp('pulso-local-receipt-');
      final receipt = File('${dir.path}/receipt.png');
      await receipt.writeAsBytes([137, 80, 78, 71]);
      try {
        final api = ApiService(
          config: localConfig(),
          session: await signedSession(),
          client: MockClient((req) async {
            expect(req.url.path, endsWith('/purchase_upload_receipt.php'));
            expect(req.headers['Authorization'], 'Bearer SYNTHETIC_TOKEN_ONLY');
            final body = utf8.decode(req.bodyBytes, allowMalformed: true);
            expect(body, contains('name="order_id"'));
            expect(body, contains('77'));
            expect(body, isNot(contains('name="user_id"')));
            return response(200, {
              'ok': true,
              'order': {'id': 77, 'status': 'in_review'},
            });
          }),
        );
        expect(
          (await api.uploadReceipt(77, receipt.path))['order']['status'],
          'in_review',
        );
      } finally {
        await receipt.delete();
        await dir.delete();
      }
    },
  );
}
