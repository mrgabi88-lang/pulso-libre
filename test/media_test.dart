import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulso_libre_app/main.dart';
import 'package:pulso_libre_app/models/event.dart';
import 'package:pulso_libre_app/widgets/event_media.dart';
import 'helpers.dart';

class FakeAudio implements AudioPlayback {
  // Each synthetic engine has one listener. Give cancellation its own Future
  // in the test zone: broadcast's cached null Future can belong to runAsync
  // after screenshots, which a FakeAsync pump cannot drain.
  final state = StreamController<bool>(onCancel: () async {});
  final failure = StreamController<Object>(onCancel: () async {});
  final List<Uri> loaded = [];
  int plays = 0;
  int pauses = 0;
  bool disposed = false;
  FakeAudio() {
    // Allocate completion in this test's zone before cancellation. Otherwise
    // close() after cancel can reuse the SDK's cached root-zone null Future.
    unawaited(state.done);
    unawaited(failure.done);
  }
  @override
  Stream<bool> get playing => state.stream;
  @override
  Stream<Object> get errors => failure.stream;
  @override
  Future<void> load(Uri uri) async {
    loaded.add(uri);
  }

  @override
  Future<void> play() async {
    plays++;
    state.add(true);
  }

  @override
  Future<void> pause() async {
    pauses++;
    state.add(false);
  }

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    await state.close();
    await failure.close();
  }
}

void main() {
  test(
    'event civil time preserves published offset and null stock means unlimited',
    () {
      final e = PulsoEvent.fromJson({
        ...event(1, 'Noche'),
        'date_event': '2030-06-10T21:00:00-03:00',
        'stock_available': null,
      }, localConfig());
      expect(dateLabel(e.date), '10/06 · 21:00');
      expect(e.stock, isNull);
      expect(
        PulsoEvent.fromJson({
          ...event(2, 'Agotado'),
          'stock_available': 0,
        }, localConfig()).stock,
        0,
      );
    },
  );
  test(
    'server upcoming ranking controls feature and excludes past from home',
    () {
      final c = EventCatalog.fromJson({
        ...catalog(),
        'items': [event(303, 'PASADO'), ...catalog()['items'] as List],
      }, localConfig());
      expect(c.featured!.id, 202);
      expect(c.upcoming.map((e) => e.id), [202, 101]);
      expect(
        EventCatalog.fromJson({
          'items': [event(1, 'UNO')],
        }, localConfig()).upcoming,
        isEmpty,
      );
    },
  );
  test(
    'media permits uploaded URL and external HTTPS, limits three and rejects unsafe schemes',
    () {
      final e = PulsoEvent.fromJson({
        ...event(1, 'UNO'),
        'background_url': '/bg.png',
        'flyer_urls': ['/flyer.png'],
        'tracks': [
          {
            'id': 1,
            'title': 'Audio',
            'kind': 'upload',
            'url': 'http://127.0.0.1:18765/audio.wav',
          },
          {
            'id': 2,
            'title': 'SoundCloud',
            'kind': 'external',
            'url': 'https://soundcloud.com/example/test',
          },
          {'id': 3, 'kind': 'external', 'url': 'javascript:alert(1)'},
          {'id': 4, 'kind': 'upload', 'url': '/fourth.wav'},
        ],
      }, localConfig());
      expect(e.background!.path, '/bg.png');
      expect(e.flyers.single.path, '/flyer.png');
      expect(e.tracks.map((t) => t.kind), ['upload', 'external']);
      for (final value in [
        'file:///private',
        'data:audio/wav;base64,xxx',
        'https://user:pass@host/x',
        'http://remote.invalid/x',
      ]) {
        expect(localConfig().mediaUri(value), isNull);
      }
    },
  );
  testWidgets(
    'mixed tracks require explicit play/open and stop when screen is removed',
    (tester) async {
      final audio = FakeAudio();
      var created = 0;
      final external = <Uri>[];
      final e = PulsoEvent.fromJson({
        ...event(1, 'UNO'),
        'flyer_urls': ['/one.png', '/two.png'],
        'tracks': [
          {
            'id': 'a',
            'title': 'Archivo',
            'kind': 'upload',
            'url': '/audio.wav',
          },
          {
            'id': 'b',
            'title': 'Enlace',
            'kind': 'external',
            'url': 'https://soundcloud.com/',
          },
        ],
      }, localConfig());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EventMedia(
              event: e,
              imageBuilder: fakeImage,
              audioFactory: () {
                created++;
                return audio;
              },
              externalLauncher: (uri) async {
                external.add(uri);
                return true;
              },
            ),
          ),
        ),
      );
      expect(created, 0);
      expect(external, isEmpty);
      expect(find.text('image:/one.png'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('track-a')));
      await tester.pump();
      await tester.pump();
      expect(created, 1);
      expect(audio.loaded.single.path, '/audio.wav');
      expect(audio.plays, 1);
      await tester.tap(find.byKey(const ValueKey('track-b')));
      await tester.pump();
      expect(external.single.host, 'soundcloud.com');
      expect(audio.pauses, greaterThanOrEqualTo(2));
      expect(audio.disposed, isTrue);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(audio.disposed, isTrue);
    },
  );
}
