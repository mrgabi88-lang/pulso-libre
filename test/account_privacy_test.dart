import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pulso_libre_app/main.dart';
import 'package:pulso_libre_app/services/api_service.dart';
import 'package:pulso_libre_app/services/session_store.dart';
import 'package:pulso_libre_app/widgets/account_privacy_links.dart';
import 'package:pulso_libre_app/widgets/brand_style.dart';
import 'helpers.dart';

Future<void> openLink(WidgetTester tester, String key) async {
  final link = find.byKey(ValueKey(key));
  await tester.scrollUntilVisible(
    link,
    150,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.ensureVisible(link);
  await tester.pumpAndSettle();
  await tester.tap(link);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'public account links are reachable through the app without login',
    (tester) async {
      final urls = <Uri>[];
      final session = SessionStore(vault: MemoryVault());
      final api = ApiService(
        config: localConfig(),
        session: session,
        client: MockClient((request) async {
          expect(request.url.path, endsWith('/events.php'));
          return response(200, {
            'ok': true,
            'items': [],
            'upcoming_events': [],
          });
        }),
      );
      await tester.pumpWidget(
        PulsoLibreApp(
          api: api,
          imageBuilder: fakeImage,
          externalLauncher: (uri) async {
            urls.add(uri);
            return true;
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('global-nav-account')),
      );
      await tester.tap(find.byKey(const ValueKey('global-nav-account')));
      await tester.pumpAndSettle();
      await openLink(tester, 'account-privacy');
      await openLink(tester, 'account-deletion');
      expect(urls.map((uri) => uri.toString()), [
        'https://pllabs.com.ar/pulso-libre/privacidad/',
        'https://pllabs.com.ar/pulso-libre/eliminar-cuenta/',
      ]);
      expect(session.hasCredential, isFalse);
      expect(find.textContaining('Abrir el enlace no borra'), findsOneWidget);
    },
  );

  testWidgets(
    'deletion request does not change session or contact the account API',
    (tester) async {
      final vault = MemoryVault();
      final session = await signedSession(vault);
      final before = Map<String, String>.from(vault.values);
      final urls = <Uri>[];
      final api = ApiService(
        config: localConfig(),
        session: session,
        client: MockClient(
          (_) async => throw StateError('Unexpected account request'),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: pulsoTheme(),
          home: Scaffold(
            body: AccountScreen(
              api: api,
              onLoggedIn: () => fail('Opening privacy must not trigger login'),
              externalLauncher: (uri) async {
                urls.add(uri);
                return true;
              },
            ),
          ),
        ),
      );
      await openLink(tester, 'account-deletion');
      expect(session.authenticated, isTrue);
      expect(vault.values, before);
      expect(
        urls.single.toString(),
        'https://pllabs.com.ar/pulso-libre/eliminar-cuenta/',
      );
      expect(urls.single.hasQuery, isFalse);
      expect(find.text('Sesión activa'), findsOneWidget);
    },
  );

  for (final throws in [false, true]) {
    testWidgets(
      'browser failure remains usable at large text; throws=$throws',
      (tester) async {
        tester.view.physicalSize = const Size(320, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
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
              body: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  AccountPrivacyLinks(
                    externalLauncher: (_) async {
                      if (throws) throw StateError('No browser');
                      return false;
                    },
                  ),
                ],
              ),
            ),
          ),
        );
        await openLink(tester, 'account-deletion');
        expect(find.text('No se pudo abrir la página'), findsOneWidget);
        expect(
          find.widgetWithText(
            SelectableText,
            'https://pllabs.com.ar/pulso-libre/eliminar-cuenta/',
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Entendido'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
      },
    );
  }
}
