import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulso_libre_app/models/event.dart';
import 'package:pulso_libre_app/widgets/embedded_track_player.dart';
import 'package:pulso_libre_app/widgets/event_media.dart';

class _ImmediateEmbeddedController extends EmbeddedTrackController {
  int pauses = 0;
  int plays = 0;
  int disposals = 0;
  @override
  Future<void> play() async {
    plays++;
  }

  @override
  Future<void> pause() async {
    pauses++;
  }

  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> dispose() async {
    disposals++;
  }
}

class _EmbeddedProbe extends StatefulWidget {
  final ValueChanged<bool> onPlaying;
  final ValueChanged<String> onError;
  const _EmbeddedProbe({required this.onPlaying, required this.onError});
  @override
  State<_EmbeddedProbe> createState() => _EmbeddedProbeState();
}

class _EmbeddedProbeState extends State<_EmbeddedProbe> {
  @override
  Widget build(BuildContext context) => const SizedBox(height: 40);
}

Widget _tracksUnderTest(List<_ImmediateEmbeddedController> controllers) {
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: EventTracks(
          tracks: [
            EventTrack(
              id: 'a',
              title: 'Primera',
              kind: 'external',
              url: Uri.parse('https://soundcloud.com/forss/flickermood'),
            ),
            EventTrack(
              id: 'b',
              title: 'Segunda',
              kind: 'external',
              url: Uri.parse('https://soundcloud.com/forss/second-track'),
            ),
          ],
          autoplay: true,
          embeddedFactory: () {
            final controller = _ImmediateEmbeddedController();
            controllers.add(controller);
            return controller;
          },
          embeddedBuilder:
              ({
                required url,
                required controller,
                required autoplay,
                required muted,
                required onPlaying,
                required onError,
              }) => _EmbeddedProbe(onPlaying: onPlaying, onError: onError),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'switching embedded tracks creates fresh State after quick shutdown',
    (tester) async {
      final controllers = <_ImmediateEmbeddedController>[];
      await tester.pumpWidget(_tracksUnderTest(controllers));
      await tester.pumpAndSettle();
      final firstState = tester.state(find.byType(_EmbeddedProbe));
      expect(controllers, hasLength(1));
      await tester.tap(find.byKey(const ValueKey('track-b')));
      await tester.pumpAndSettle();
      expect(controllers, hasLength(2));
      expect(controllers.first.disposals, 1);
      expect(
        identical(firstState, tester.state(find.byType(_EmbeddedProbe))),
        isFalse,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('provider notice preserves real playing state and pause action', (
    tester,
  ) async {
    final controllers = <_ImmediateEmbeddedController>[];
    await tester.pumpWidget(_tracksUnderTest(controllers));
    await tester.pumpAndSettle();
    tester.widget<_EmbeddedProbe>(find.byType(_EmbeddedProbe)).onPlaying(true);
    await tester.pump();
    tester
        .widget<_EmbeddedProbe>(find.byType(_EmbeddedProbe))
        .onError('Usá los controles del reproductor.');
    await tester.pump();
    expect(find.text('Reproduciendo · Pausar'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('track-a')));
    await tester.pumpAndSettle();
    expect(controllers.single.pauses, 1);
    expect(controllers.single.plays, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  test(
    'embeds public track and playlist permalinks, strips tracking later',
    () {
      for (final url in [
        'https://soundcloud.com/forss/flickermood',
        'https://www.soundcloud.com/organizador/sesion-2026/?utm_source=share',
        'https://m.soundcloud.com/artista/sets/noche-libre',
      ]) {
        expect(canEmbedTrack(Uri.parse(url)), isTrue, reason: url);
      }
    },
  );

  test(
    'rejects homepage, profiles, platform pages, private and ambiguous links',
    () {
      for (final url in [
        'https://soundcloud.com/',
        'https://soundcloud.com/artista',
        'https://soundcloud.com/artista/sets',
        'https://soundcloud.com/artista/likes',
        'https://soundcloud.com/discover/sets',
        'https://soundcloud.com/you/likes',
        'https://soundcloud.com/artista/tema/s-secret',
        'https://soundcloud.com/artista/tema?secret_token=s-private',
        'https://on.soundcloud.com/ShortCode',
        'https://youtube.com/watch?v=track',
      ]) {
        expect(canEmbedTrack(Uri.parse(url)), isFalse, reason: url);
      }
    },
  );

  test(
    'rejects untrusted hosts, schemes, credentials, ports and encoded paths',
    () {
      for (final url in [
        'https://soundcloud.com.evil.invalid/artist/track',
        'https://evil.soundcloud.com/artist/track',
        'https://user:password@soundcloud.com/artist/track',
        'http://soundcloud.com/artist/track',
        'javascript:alert(1)',
        'https://soundcloud.com:8443/artist/track',
        'https://soundcloud.com/artist/%3Cscript%3E',
        'https://soundcloud.com/artist/a%2Fb',
      ]) {
        expect(canEmbedTrack(Uri.parse(url)), isFalse, reason: url);
      }
    },
  );

  test(
    'wrapper uses official iframe with artwork, controls and no query injection',
    () {
      final html = buildSoundCloudPlayerHtml(
        Uri.parse(
          'https://soundcloud.com/forss/flickermood?utm_content=%3C/script%3E',
        ),
        autoplay: true,
        volume: .8,
      );
      expect(html, contains('https://w.soundcloud.com/player/api.js'));
      expect(html, contains('auto_play=false'));
      expect(html, contains('wanted=true'));
      final ready = html.substring(
        html.indexOf('player.bind(SC.Widget.Events.READY'),
      );
      expect(ready, contains('player.setVolume(volume)'));
      expect(ready, contains('if(wanted)player.play()'));
      expect(
        ready.indexOf('player.setVolume(volume)'),
        lessThan(ready.indexOf('if(wanted)player.play()')),
      );
      expect(html, contains('allow="autoplay"'));
      expect(html, contains('show_artwork=true'));
      expect(html, contains('show_user=true'));
      expect(html, isNot(contains('utm_content')));
      expect(html, isNot(contains('client_id')));
      expect(html, contains('SC.Widget.Events.PLAY'));
      expect(
        html,
        contains("document.getElementById('soundcloud').src='about:blank'"),
      );
    },
  );

  test('invalid URLs never become iframe HTML', () {
    expect(
      () => buildSoundCloudPlayerHtml(
        Uri.parse('https://soundcloud.com/'),
        autoplay: true,
        volume: 1,
      ),
      throwsArgumentError,
    );
  });

  test(
    'controller accepts pre-mount commands and terminal dispose safely',
    () async {
      final controller = EmbeddedTrackController();
      await controller.play();
      await controller.setVolume(0);
      await controller.pause();
      await controller.dispose();
      await controller.play();
      await controller.setVolume(double.nan);
      await controller.dispose();
    },
  );
}
