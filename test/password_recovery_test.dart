import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pulso_libre_app/main.dart';
import 'package:pulso_libre_app/services/api_service.dart';
import 'package:pulso_libre_app/services/session_store.dart';
import 'package:pulso_libre_app/widgets/brand_style.dart';
import 'package:pulso_libre_app/widgets/password_recovery.dart';
import 'helpers.dart';

http.Response accepted({int retryAfter = 60}) => response(200, {
  'ok': true,
  'message': passwordRecoveryAcceptedMessage,
  'retry_after': retryAfter,
});

Future<void> tapKey(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> showAccount(WidgetTester tester, ApiService api) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: pulsoTheme(),
      home: Scaffold(
        body: AccountScreen(
          api: api,
          onLoggedIn: () => fail('Recovery must not log in'),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> enterRecoveryEmail(WidgetTester tester, String email) async {
  await tester.enterText(
    find.byKey(const ValueKey('password-recovery-email')),
    email,
  );
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();
}

void main() {
  test(
    'request uses only email, without bearer or local session changes',
    () async {
      final vault = MemoryVault();
      final session = await signedSession(vault);
      await session.beginPurchaseIntent(101, 2);
      final before = Map<String, String>.from(vault.values);
      final api = ApiService(
        config: localConfig(),
        session: session,
        client: MockClient((request) async {
          expect(request.url.path, endsWith('/forgot_password.php'));
          expect(request.method, 'POST');
          expect(request.headers.containsKey('authorization'), isFalse);
          expect(jsonDecode(request.body), {'email': 'buyer@example.invalid'});
          return accepted();
        }),
      );
      final result = await api.requestPasswordReset(' buyer@example.invalid ');
      expect(result['ok'], isTrue);
      expect(session.authenticated, isTrue);
      expect(vault.values, before);
    },
  );

  test(
    'unauthenticated recovery error does not clear a saved session',
    () async {
      final vault = MemoryVault();
      final session = await signedSession(vault);
      final before = Map<String, String>.from(vault.values);
      final api = ApiService(
        config: localConfig(),
        session: session,
        client: MockClient(
          (_) async =>
              response(401, {'ok': false, 'error': 'Solicitud rechazada.'}),
        ),
      );
      await expectLater(
        api.requestPasswordReset('buyer@example.invalid'),
        throwsA(isA<ApiException>()),
      );
      expect(session.authenticated, isTrue);
      expect(vault.values, before);
    },
  );

  testWidgets('signed-out users can recover through the app Cuenta tab', (
    tester,
  ) async {
    var resetRequests = 0;
    final session = SessionStore(vault: MemoryVault());
    final api = ApiService(
      config: localConfig(),
      session: session,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/events.php')) {
          return response(200, {
            'ok': true,
            'items': [],
            'upcoming_events': [],
          });
        }
        expect(request.url.path, endsWith('/forgot_password.php'));
        resetRequests++;
        return accepted();
      }),
    );
    await tester.pumpWidget(PulsoLibreApp(api: api, imageBuilder: fakeImage));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('global-nav-account')));
    await tester.pumpAndSettle();
    expect(find.text('Olvidé mi contraseña'), findsOneWidget);
    await tapKey(tester, 'account-password-recovery');
    await enterRecoveryEmail(tester, 'buyer@example.invalid');
    expect(resetRequests, 1);
    expect(find.text(passwordRecoveryAcceptedMessage), findsOneWidget);
    expect(session.hasCredential, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('pending account can recover without clearing confirmation', (
    tester,
  ) async {
    final vault = MemoryVault();
    final session = SessionStore(vault: vault);
    await session.pending('pending@example.invalid');
    final before = Map<String, String>.from(vault.values);
    final api = ApiService(
      config: localConfig(),
      session: session,
      client: MockClient((request) async {
        expect(request.url.path, endsWith('/forgot_password.php'));
        expect(jsonDecode(request.body), {'email': 'pending@example.invalid'});
        return accepted();
      }),
    );
    await showAccount(tester, api);
    expect(find.text('Confirmá tu correo'), findsOneWidget);
    await tapKey(tester, 'account-password-recovery');
    final field = tester.widget<TextFormField>(
      find.byKey(const ValueKey('password-recovery-email')),
    );
    expect(field.controller!.text, 'pending@example.invalid');
    await tapKey(tester, 'password-recovery-send');
    expect(find.text(passwordRecoveryAcceptedMessage), findsOneWidget);
    expect(session.pendingEmail, 'pending@example.invalid');
    expect(vault.values, before);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'locked app recovers without exposing email or unlocking session',
    (tester) async {
      final vault = MemoryVault();
      final session = await signedSession(vault);
      await session.beginPurchaseIntent(101, 2);
      final before = Map<String, String>.from(vault.values);
      var resetRequests = 0;
      final api = ApiService(
        config: localConfig(),
        session: session,
        client: MockClient((request) async {
          if (request.url.path.endsWith('/events.php')) {
            return response(200, {
              'ok': true,
              'items': [],
              'upcoming_events': [],
            });
          }
          if (request.url.path.endsWith('/me.php')) {
            return response(200, {'ok': true, 'user': buyer});
          }
          expect(request.url.path, endsWith('/forgot_password.php'));
          expect(request.headers.containsKey('authorization'), isFalse);
          resetRequests++;
          return accepted();
        }),
      );
      await tester.pumpWidget(
        PulsoLibreApp(
          api: api,
          imageBuilder: fakeImage,
          biometric: () async => throw StateError('Recovery must not unlock'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Pulso Libre bloqueado'), findsOneWidget);
      await tapKey(tester, 'account-password-recovery');
      final field = tester.widget<TextFormField>(
        find.byKey(const ValueKey('password-recovery-email')),
      );
      expect(field.controller!.text, isEmpty);
      expect(find.text('buyer@example.invalid'), findsNothing);
      await enterRecoveryEmail(tester, 'buyer@example.invalid');
      expect(resetRequests, 1);
      expect(session.locked, isTrue);
      expect(vault.values, before);
      await tapKey(tester, 'password-recovery-close');
      expect(find.text('Pulso Libre bloqueado'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('signed-in recovery preserves credentials and purchase intents', (
    tester,
  ) async {
    final vault = MemoryVault();
    final session = await signedSession(vault);
    await session.beginPurchaseIntent(101, 2);
    final before = Map<String, String>.from(vault.values);
    final api = ApiService(
      config: localConfig(),
      session: session,
      client: MockClient((request) async {
        expect(request.headers.containsKey('authorization'), isFalse);
        return accepted();
      }),
    );
    await showAccount(tester, api);
    expect(find.text('Cambiar contraseña por correo'), findsOneWidget);
    await tapKey(tester, 'account-password-recovery');
    await tapKey(tester, 'password-recovery-send');
    expect(session.authenticated, isTrue);
    expect(vault.values, before);
    await tapKey(tester, 'password-recovery-close');
    expect(find.text('Sesión activa'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('locking the app closes recovery and hides its entered email', (
    tester,
  ) async {
    final vault = MemoryVault();
    final session = await signedSession(vault);
    final before = Map<String, String>.from(vault.values);
    final api = ApiService(
      config: localConfig(),
      session: session,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/events.php')) {
          return response(200, {
            'ok': true,
            'items': [],
            'upcoming_events': [],
          });
        }
        expect(request.url.path, endsWith('/me.php'));
        return response(200, {'ok': true, 'user': buyer});
      }),
    );
    await tester.pumpWidget(
      PulsoLibreApp(
        api: api,
        imageBuilder: fakeImage,
        biometric: () async => true,
      ),
    );
    await tester.pumpAndSettle();
    await tapKey(tester, 'unlock-device');
    await tester.tap(find.byKey(const ValueKey('global-nav-account')));
    await tester.pumpAndSettle();
    await tapKey(tester, 'account-password-recovery');
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('buyer@example.invalid'), findsWidgets);
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    expect(session.locked, isTrue);
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('buyer@example.invalid'), findsNothing);
    expect(find.text('Pulso Libre bloqueado'), findsOneWidget);
    expect(vault.values, before);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('invalid email never sends a request', (tester) async {
    final api = ApiService(
      config: localConfig(),
      session: SessionStore(vault: MemoryVault()),
      client: MockClient((_) async => throw StateError('Unexpected request')),
    );
    await showAccount(tester, api);
    await tapKey(tester, 'account-password-recovery');
    for (final email in ['', 'buyer', 'buyer@', 'a @example.com']) {
      await enterRecoveryEmail(tester, email);
      expect(
        find.text('Ingresá un correo electrónico válido.'),
        findsOneWidget,
      );
      expect(find.text(passwordRecoveryAcceptedMessage), findsNothing);
    }
  });

  for (final failure in ['network', 'server', 'rate_limit', 'malformed']) {
    testWidgets('recovery failure stays truthful: $failure', (tester) async {
      var count = 0;
      final api = ApiService(
        config: localConfig(),
        session: SessionStore(vault: MemoryVault()),
        client: MockClient((_) async {
          count++;
          if (failure == 'network') throw http.ClientException('Disconnected');
          if (failure == 'malformed') return http.Response('Not JSON', 200);
          if (failure == 'rate_limit') {
            return response(429, {
              'ok': false,
              'error': 'Esperá antes de volver a solicitar el enlace.',
              'retry_after': 3,
            });
          }
          return response(503, {
            'ok': false,
            'error': 'No se pudo solicitar el enlace. Intentá nuevamente.',
          });
        }),
      );
      await showAccount(tester, api);
      await tapKey(tester, 'account-password-recovery');
      await enterRecoveryEmail(tester, 'buyer@example.invalid');
      expect(count, 1);
      expect(find.text(passwordRecoveryAcceptedMessage), findsNothing);
      expect(
        find.byKey(const ValueKey('password-recovery-result')),
        findsOneWidget,
      );
      final send = tester.widget<FilledButton>(
        find.byKey(const ValueKey('password-recovery-send')),
      );
      expect(send.onPressed == null, failure == 'rate_limit');
      if (failure == 'rate_limit') {
        await tapKey(tester, 'password-recovery-close');
        await tapKey(tester, 'account-password-recovery');
        expect(count, 1);
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('password-recovery-send')),
              )
              .onPressed,
          isNull,
        );
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
        expect(find.text('Solicitar enlace'), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('closing during request does not permit a duplicate request', (
    tester,
  ) async {
    final result = Completer<http.Response>();
    var count = 0;
    final api = ApiService(
      config: localConfig(),
      session: SessionStore(vault: MemoryVault()),
      client: MockClient((_) {
        count++;
        return result.future;
      }),
    );
    await showAccount(tester, api);
    await tapKey(tester, 'account-password-recovery');
    await enterRecoveryEmail(tester, 'buyer@example.invalid');
    expect(find.text('Solicitando enlace…'), findsOneWidget);
    await tapKey(tester, 'password-recovery-send');
    expect(count, 1);
    await tapKey(tester, 'password-recovery-close');
    await tapKey(tester, 'account-password-recovery');
    expect(find.text('Solicitando enlace…'), findsOneWidget);
    result.complete(accepted(retryAfter: 5));
    await tester.pumpAndSettle();
    expect(find.text(passwordRecoveryAcceptedMessage), findsOneWidget);
    expect(count, 1);
    await tapKey(tester, 'password-recovery-close');
    await tapKey(tester, 'account-password-recovery');
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('password-recovery-send')),
          )
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('disposing Cuenta during a request safely ignores its response', (
    tester,
  ) async {
    final result = Completer<http.Response>();
    final vault = MemoryVault();
    final session = await signedSession(vault);
    final before = Map<String, String>.from(vault.values);
    final api = ApiService(
      config: localConfig(),
      session: session,
      client: MockClient((_) => result.future),
    );
    await showAccount(tester, api);
    await tapKey(tester, 'account-password-recovery');
    await tapKey(tester, 'password-recovery-send');
    await tester.pumpWidget(const SizedBox());
    result.complete(accepted());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(vault.values, before);
  });

  testWidgets('recovery remains scrollable at width 320 and double text size', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = ApiService(
      config: localConfig(),
      session: SessionStore(vault: MemoryVault()),
      client: MockClient((_) async => accepted()),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: pulsoTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: AccountScreen(
            api: api,
            onLoggedIn: () => fail('Unexpected login'),
          ),
        ),
      ),
    );
    await tapKey(tester, 'account-password-recovery');
    await enterRecoveryEmail(tester, 'buyer@example.invalid');
    await tester.ensureVisible(
      find.byKey(const ValueKey('password-recovery-result')),
    );
    await tester.pumpAndSettle();
    expect(find.text(passwordRecoveryAcceptedMessage), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tapKey(tester, 'password-recovery-close');
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
