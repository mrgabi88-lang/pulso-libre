import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pulso_libre_app/main.dart';
import 'package:pulso_libre_app/models/event.dart';
import 'package:pulso_libre_app/services/api_service.dart';
import 'package:pulso_libre_app/services/session_store.dart';
import 'package:pulso_libre_app/widgets/embedded_track_player.dart';
import 'package:pulso_libre_app/widgets/event_media.dart';

import 'helpers.dart';

class _Audio implements AudioPlayback {
  final String name;
  final List<String> trace;
  final Completer<void>? loadGate;
  final Completer<void>? disposeGate;
  final bool failLoad;
  final _playing = StreamController<bool>(onCancel: () async {});
  final _errors = StreamController<Object>(onCancel: () async {});
  final loaded = <Uri>[];
  final volumes = <double>[];
  int plays = 0;
  int pauses = 0;
  bool disposed = false;

  _Audio(
    this.name,
    this.trace, {
    this.loadGate,
    this.disposeGate,
    this.failLoad = false,
  }) {
    unawaited(_playing.done);
    unawaited(_errors.done);
  }

  @override
  Stream<bool> get playing => _playing.stream;
  @override
  Stream<Object> get errors => _errors.stream;
  @override
  Future<void> load(Uri uri) async {
    loaded.add(uri);
    trace.add('$name.load');
    await loadGate?.future;
    if (failLoad) throw StateError('Synthetic unavailable audio');
  }

  @override
  Future<void> play() async {
    if (disposed) throw StateError('Playing disposed synthetic engine');
    plays++;
    trace.add('$name.play');
    _playing.add(true);
  }

  @override
  Future<void> pause() async {
    pauses++;
    trace.add('$name.pause');
    if (!_playing.isClosed) _playing.add(false);
  }

  @override
  Future<void> setVolume(double value) async => volumes.add(value);

  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    trace.add('$name.disposing');
    await disposeGate?.future;
    await _playing.close();
    await _errors.close();
    trace.add('$name.disposed');
  }
}

class _Embedded extends EmbeddedTrackController {
  final List<String> trace;
  final volumes = <double>[];
  bool disposed = false;
  _Embedded(this.trace);
  @override
  Future<void> play() async => trace.add('embedded.play');
  @override
  Future<void> pause() async => trace.add('embedded.pause');
  @override
  Future<void> setVolume(double value) async => volumes.add(value);
  @override
  Future<void> dispose() async {
    disposed = true;
    trace.add('embedded.disposed');
  }
}

EventTrack _upload(String id, {String? title}) => EventTrack(
  id: id,
  title: title ?? 'Tema $id',
  kind: 'upload',
  url: Uri.parse('http://127.0.0.1:18765/$id.wav'),
);
EventTrack _external(String id, String url) => EventTrack(
  id: id,
  title: 'Enlace $id',
  kind: 'external',
  url: Uri.parse(url),
);

Widget _screen(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump();
  }
}

Future<void> _remove(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await _flush(tester);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}

Future<void> _tap(WidgetTester tester, String id) async {
  final target = find.byKey(ValueKey('track-$id'));
  await tester.ensureVisible(target);
  await tester.tap(target);
  await _flush(tester);
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized()
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets(
    'fixed bar shares playback and keeps mute across replaced event State',
    (tester) async {
      final controls = EventAudioControls();
      controls.setVolume(.3);
      final first = _Audio('first', []);
      final second = _Audio('second', []);
      Widget screen(String id, AudioPlayback player) => _screen(
        Column(
          children: [
            EventTracks(
              key: ValueKey(id),
              tracks: [_upload(id)],
              autoplay: true,
              audioControls: controls,
              audioFactory: () => player,
            ),
            EventAudioBar(controller: controls),
          ],
        ),
      );
      await tester.pumpWidget(screen('one', first));
      await _flush(tester);
      expect(find.byKey(const ValueKey('event-audio-mute')), findsOneWidget);
      expect(controls.playing, isTrue);
      expect(first.volumes.last, .3);
      await tester.tap(find.byKey(const ValueKey('event-audio-toggle')));
      await _flush(tester);
      expect(controls.playing, isFalse);
      await tester.tap(find.byKey(const ValueKey('event-audio-toggle')));
      await _flush(tester);
      expect(first.plays, 2);
      await tester.tap(find.byKey(const ValueKey('event-audio-mute')));
      await _flush(tester);
      expect(controls.muted, isTrue);
      expect(first.volumes.last, 0);
      await tester.pumpWidget(screen('two', second));
      await _flush(tester);
      expect(first.disposed, isTrue);
      expect(second.plays, 1);
      expect(second.volumes.last, 0);
      expect(controls.muted, isTrue);
      await tester.tap(find.byKey(const ValueKey('event-audio-mute')));
      await _flush(tester);
      expect(second.volumes.last, .3);
      // Screen-owned controllers may dispose before their child does.
      controls.dispose();
      await _remove(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'fixed bar stays hidden for first incompatible link until compatible manual choice',
    (tester) async {
      final controls = EventAudioControls();
      final audio = _Audio('one', []);
      await tester.pumpWidget(
        _screen(
          Column(
            children: [
              EventTracks(
                tracks: [
                  _external('link', 'https://soundcloud.com/'),
                  _upload('one'),
                ],
                autoplay: true,
                audioControls: controls,
                audioFactory: () => audio,
              ),
              EventAudioBar(controller: controls),
            ],
          ),
        ),
      );
      await _flush(tester);
      expect(controls.available, isFalse);
      expect(find.byKey(const ValueKey('event-audio-toggle')), findsNothing);
      expect(audio.loaded, isEmpty);
      await _tap(tester, 'one');
      expect(controls.available, isTrue);
      expect(find.byKey(const ValueKey('event-audio-toggle')), findsOneWidget);
      await _remove(tester);
      controls.dispose();
    },
  );

  testWidgets('autoplay is opt in and flyer split keeps track controls', (
    tester,
  ) async {
    var created = 0;
    final media = PulsoEvent.fromJson({
      ...event(1, 'Synthetic event'),
      'flyer_urls': ['/one.png'],
      'tracks': [
        {'id': 'one', 'title': 'Uno', 'kind': 'upload', 'url': '/one.wav'},
      ],
    }, localConfig());
    await tester.pumpWidget(
      _screen(
        EventMedia(
          event: media,
          showFlyers: false,
          imageBuilder: fakeImage,
          audioFactory: () {
            created++;
            return _Audio('one', []);
          },
        ),
      ),
    );
    await _flush(tester);
    expect(created, 0);
    expect(find.byType(PageView), findsNothing);
    expect(find.byKey(const ValueKey('track-one')), findsOneWidget);
    await _remove(tester);
  });

  testWidgets('first upload autoplays once and redraw preserves playback', (
    tester,
  ) async {
    final trace = <String>[];
    final audio = _Audio('one', trace);
    var created = 0;
    Widget media({String? title}) => _screen(
      EventTracks(
        tracks: [
          _upload('one', title: title),
          _upload('two'),
          _upload('three'),
          _upload('four'),
        ],
        autoplay: true,
        audioFactory: () {
          created++;
          return audio;
        },
      ),
    );
    await tester.pumpWidget(media());
    await _flush(tester);
    expect(audio.loaded.map((uri) => uri.path), ['/one.wav']);
    expect(audio.plays, 1);
    expect(audio.volumes, [.8]);
    expect(find.byKey(const ValueKey('track-four')), findsNothing);
    await tester.pumpWidget(media(title: 'Título renovado'));
    await _flush(tester);
    expect(created, 1);
    expect(audio.plays, 1);
    expect(find.text('Título renovado'), findsOneWidget);
    await _remove(tester);
    expect(audio.disposed, isTrue);
  });

  testWidgets(
    'incompatible first link never opens or skips to another track automatically',
    (tester) async {
      final audio = _Audio('two', []);
      var created = 0;
      final opened = <Uri>[];
      await tester.pumpWidget(
        _screen(
          EventTracks(
            tracks: [
              _external('one', 'https://soundcloud.com/'),
              _upload('two'),
            ],
            autoplay: true,
            audioFactory: () {
              created++;
              return audio;
            },
            externalLauncher: (uri) async {
              opened.add(uri);
              return true;
            },
          ),
        ),
      );
      await _flush(tester);
      expect(created, 0);
      expect(opened, isEmpty);
      expect(find.textContaining('El primer audio'), findsOneWidget);
      await _tap(tester, 'two');
      expect(audio.plays, 1);
      await _tap(tester, 'one');
      expect(audio.disposed, isTrue);
      expect(opened.single.host, 'soundcloud.com');
      await _remove(tester);
    },
  );

  testWidgets(
    'pause resume mute and volume retain the loaded track and chosen level',
    (tester) async {
      final audio = _Audio('one', []);
      await tester.pumpWidget(
        _screen(
          EventTracks(
            tracks: [_upload('one')],
            autoplay: true,
            audioFactory: () => audio,
          ),
        ),
      );
      await _flush(tester);
      await _tap(tester, 'one');
      expect(audio.plays, 1);
      expect(find.text('Reproduciendo · Pausar'), findsNothing);
      await _tap(tester, 'one');
      expect(audio.plays, 2);
      expect(audio.loaded, hasLength(1));
      tester
          .widget<Slider>(find.byKey(const ValueKey('event-audio-volume')))
          .onChanged!(.25);
      await _flush(tester);
      await tester.tap(find.byKey(const ValueKey('event-audio-mute')));
      await _flush(tester);
      expect(audio.volumes.last, 0);
      expect(find.byTooltip('Activar sonido'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('event-audio-mute')));
      await _flush(tester);
      expect(audio.volumes.last, .25);
      expect(find.text('25%'), findsOneWidget);
      await _remove(tester);
    },
  );

  testWidgets('changing event waits for complete old native disposal', (
    tester,
  ) async {
    final trace = <String>[];
    final barrier = Completer<void>();
    final first = _Audio('first', trace, disposeGate: barrier);
    final second = _Audio('second', trace);
    Widget media(EventTrack track, AudioPlayback player) => _screen(
      EventTracks(
        key: const ValueKey('same-mounted-slot'),
        tracks: [track],
        autoplay: true,
        audioFactory: () => player,
      ),
    );
    await tester.pumpWidget(media(_upload('first'), first));
    await _flush(tester);
    await tester.pumpWidget(media(_upload('second'), second));
    await _flush(tester);
    expect(first.disposed, isTrue);
    expect(second.loaded, isEmpty);
    barrier.complete();
    await _flush(tester);
    expect(second.plays, 1);
    expect(
      trace.indexOf('first.disposed'),
      lessThan(trace.indexOf('second.play')),
    );
    await _remove(tester);
  });

  testWidgets(
    'background during load releases player and late completion cannot play',
    (tester) async {
      final gate = Completer<void>();
      final first = _Audio('first', [], loadGate: gate);
      final second = _Audio('second', []);
      var created = 0;
      await tester.pumpWidget(
        _screen(
          EventTracks(
            tracks: [_upload('one')],
            autoplay: true,
            audioFactory: () => created++ == 0 ? first : second,
          ),
        ),
      );
      await _flush(tester);
      expect(first.loaded, hasLength(1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await _flush(tester);
      expect(first.disposed, isTrue);
      gate.complete();
      await _flush(tester);
      expect(first.plays, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _flush(tester);
      expect(created, 1);
      await _tap(tester, 'one');
      expect(second.plays, 1);
      await _remove(tester);
    },
  );

  testWidgets(
    'failed autoplay releases resources and only explicit retry starts anew',
    (tester) async {
      final first = _Audio('bad', [], failLoad: true);
      final second = _Audio('good', []);
      var created = 0;
      await tester.pumpWidget(
        _screen(
          EventTracks(
            tracks: [_upload('one')],
            autoplay: true,
            audioFactory: () => created++ == 0 ? first : second,
          ),
        ),
      );
      await _flush(tester);
      expect(first.disposed, isTrue);
      expect(find.textContaining('No se pudo reproducir'), findsOneWidget);
      await _flush(tester);
      expect(created, 1);
      await _tap(tester, 'one');
      expect(second.plays, 1);
      await _remove(tester);
    },
  );

  testWidgets('two mounted media sections share a single active engine', (
    tester,
  ) async {
    final trace = <String>[];
    final first = _Audio('first', trace);
    final second = _Audio('second', trace);
    await tester.pumpWidget(
      _screen(
        Column(
          children: [
            EventTracks(
              key: const ValueKey('first'),
              tracks: [_upload('one')],
              autoplay: true,
              audioFactory: () => first,
            ),
            EventTracks(
              key: const ValueKey('second'),
              tracks: [_upload('two')],
              audioFactory: () => second,
            ),
          ],
        ),
      ),
    );
    await _flush(tester);
    expect(first.plays, 1);
    await _tap(tester, 'two');
    expect(second.plays, 1);
    expect(
      trace.indexOf('first.disposed'),
      lessThan(trace.indexOf('second.play')),
    );
    await _remove(tester);
  });

  testWidgets(
    'SoundCloud uses actual PLAY callback and closes before native switch or background',
    (tester) async {
      final trace = <String>[];
      final audio = _Audio('native', trace);
      final controllers = <_Embedded>[];
      late ValueChanged<bool> playing;
      late ValueChanged<String> error;
      var opened = 0;
      Widget media() => _screen(
        EventTracks(
          tracks: [
            _external('sc', 'https://soundcloud.com/synthetic/track'),
            _upload('one'),
          ],
          autoplay: true,
          audioFactory: () => audio,
          externalLauncher: (_) async {
            opened++;
            return true;
          },
          embeddedFactory: () {
            final controller = _Embedded(trace);
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
              }) {
                expect(autoplay, isTrue);
                playing = onPlaying;
                error = onError;
                return const SizedBox(
                  key: ValueKey('synthetic-embedded'),
                  height: 60,
                );
              },
        ),
      );
      await tester.pumpWidget(media());
      await _flush(tester);
      expect(controllers, hasLength(1));
      expect(controllers.single.volumes, [.8]);
      expect(audio.loaded, isEmpty);
      expect(opened, 0);
      expect(find.text('Reproduciendo · Pausar'), findsNothing);
      error('Synthetic provider timeout');
      await _flush(tester);
      expect(find.byKey(const ValueKey('synthetic-embedded')), findsOneWidget);
      expect(controllers.single.disposed, isFalse);
      playing(true);
      await _flush(tester);
      expect(find.text('Reproduciendo · Pausar'), findsOneWidget);
      await tester.pumpWidget(media());
      await _flush(tester);
      expect(controllers, hasLength(1));
      await _tap(tester, 'sc');
      expect(trace, contains('embedded.pause'));
      final oldPlaying = playing;
      await _tap(tester, 'one');
      expect(
        trace.indexOf('embedded.disposed'),
        lessThan(trace.indexOf('native.play')),
      );
      oldPlaying(true);
      await _flush(tester);
      await _tap(tester, 'sc');
      expect(audio.disposed, isTrue);
      expect(controllers, hasLength(2));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await _flush(tester);
      expect(controllers.last.disposed, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _flush(tester);
      // Paused lifecycle disables frames; resource release is checked above,
      // and the removed child is painted only after frames resume.
      expect(find.byKey(const ValueKey('synthetic-embedded')), findsNothing);
      expect(controllers, hasLength(2));
      expect(opened, 0);
      await _remove(tester);
      oldPlaying(true);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'signed session unlock after background does not restart event autoplay',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final vault = MemoryVault();
      await signedSession(vault);
      final session = SessionStore(vault: vault);
      final item = {
        ...event(202, 'Synthetic audio event'),
        'tracks': [
          {'id': 'one', 'title': 'Uno', 'kind': 'upload', 'url': '/one.wav'},
        ],
      };
      var biometric = 0;
      final players = <_Audio>[];
      final api = ApiService(
        config: localConfig(),
        session: session,
        client: MockClient((request) async {
          expect(request.method, 'GET');
          if (request.url.path.endsWith('/events.php')) {
            return response(200, {
              'ok': true,
              'items': [item],
              'upcoming_events': [item],
              'featured_event_id': 202,
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
          biometric: () async {
            biometric++;
            return true;
          },
          audioFactory: () {
            final audio = _Audio('fixture', []);
            players.add(audio);
            return audio;
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('unlock-device')));
      await tester.pumpAndSettle();
      final buy = find.byKey(const ValueKey('buy-event-202'));
      await tester.ensureVisible(buy);
      await tester.tap(buy);
      await tester.pumpAndSettle();
      expect(players, hasLength(1));
      expect(players.single.plays, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      expect(players.single.disposed, isTrue);
      expect(session.authenticated, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('unlock-device')));
      await tester.pumpAndSettle();
      expect(biometric, 2);
      expect(session.authenticated, isTrue);
      expect(
        find.byKey(const ValueKey('purchase-event-title')),
        findsOneWidget,
      );
      expect(players, hasLength(1));
      expect(players.single.plays, 1);
      await _remove(tester);
    },
  );
}
