import 'dart:async';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/event.dart';
import 'embedded_track_player.dart';

typedef EmbeddedEventPlayerBuilder =
    Widget Function({
      required Uri url,
      required EmbeddedTrackController controller,
      required bool autoplay,
      required bool muted,
      required ValueChanged<bool> onPlaying,
      required ValueChanged<String> onError,
    });

typedef EventImageBuilder = Widget Function(Uri uri, BoxFit fit);
Widget networkEventImage(Uri uri, BoxFit fit) => Image.network(
  uri.toString(),
  fit: fit,
  width: double.infinity,
  errorBuilder: (_, _, _) =>
      const Center(child: Icon(Icons.image_not_supported_outlined, size: 42)),
  loadingBuilder: (_, child, progress) => progress == null
      ? child
      : const Center(child: CircularProgressIndicator()),
);

abstract interface class AudioPlayback {
  Stream<bool> get playing;
  Stream<Object> get errors;
  Future<void> load(Uri uri);
  Future<void> play();
  Future<void> pause();
  Future<void> setVolume(double volume);
  Future<void> dispose();
}

class JustAudioPlayback implements AudioPlayback {
  final AudioPlayer _player = AudioPlayer();
  final StreamController<Object> _errors = StreamController<Object>.broadcast();
  late final StreamSubscription<Object> _playerErrors;
  JustAudioPlayback() {
    _playerErrors = _player.errorStream.listen(_errors.add);
  }
  @override
  Stream<bool> get playing => _player.playerStateStream.map(
    (s) => s.playing && s.processingState != ProcessingState.completed,
  );
  @override
  Stream<Object> get errors => _errors.stream;
  @override
  Future<void> load(Uri uri) async {
    await _player.setUrl(uri.toString());
  }

  @override
  Future<void> play() async {
    if (_player.processingState == ProcessingState.completed) {
      await _player.seek(Duration.zero);
    }
    // just_audio's play future completes when playback ends, not when it starts.
    unawaited(
      _player.play().catchError((Object e) {
        if (!_errors.isClosed) _errors.add(e);
      }),
    );
  }

  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> setVolume(double volume) =>
      _player.setVolume(volume.clamp(0.0, 1.0).toDouble());
  @override
  Future<void> dispose() async {
    await _playerErrors.cancel();
    await _player.dispose();
    await _errors.close();
  }
}

Future<bool> openExternalTrack(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

/// Shared presentation state for the fixed bar and the event's single player.
/// The screen owns this controller; replacing a track does not reset volume.
class EventAudioControls extends ChangeNotifier {
  double _volume = .8;
  double _audibleVolume = .8;
  bool _playing = false;
  bool _loading = false;
  bool _available = false;
  bool _disposed = false;
  bool _notificationPending = false;
  Object? _owner;
  VoidCallback? _toggle;

  double get volume => _volume;
  bool get muted => _volume == 0;
  bool get playing => _playing;
  bool get loading => _loading;
  bool get available => _available;

  void setVolume(double value) {
    if (_disposed || !value.isFinite) return;
    final volume = value.clamp(0.0, 1.0).toDouble();
    if (_volume == volume) return;
    _volume = volume;
    if (volume > 0) _audibleVolume = volume;
    notifyListeners();
  }

  void toggleMute() => setVolume(muted ? _audibleVolume : 0);
  void togglePlayback() {
    if (!_disposed && _available && !_loading) _toggle?.call();
  }

  void _publish(
    Object owner, {
    required bool available,
    required bool playing,
    required bool loading,
    required VoidCallback toggle,
  }) {
    if (_disposed) return;
    _owner = owner;
    _toggle = toggle;
    final changed =
        _available != available || _playing != playing || _loading != loading;
    _available = available;
    _playing = playing;
    _loading = loading;
    if (changed) _notifyAfterFrame();
  }

  void _detach(Object owner) {
    if (_disposed || !identical(_owner, owner)) return;
    _owner = null;
    _toggle = null;
    _available = false;
    _playing = false;
    _loading = false;
    _notifyAfterFrame();
  }

  void _notifyAfterFrame() {
    if (_disposed || _notificationPending) return;
    _notificationPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _notificationPending = false;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _owner = null;
    _toggle = null;
    super.dispose();
  }
}

class EventAudioBar extends StatelessWidget {
  final EventAudioControls controller;
  const EventAudioBar({super.key, required this.controller});

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      if (!controller.available) return const SizedBox.shrink();
      final colors = Theme.of(context).colorScheme;
      return Material(
        color: colors.surface,
        child: SizedBox(
          height: 56,
          child: Row(
            children: [
              IconButton(
                key: const ValueKey('event-audio-toggle'),
                tooltip: controller.playing ? 'Pausar' : 'Reproducir',
                onPressed: controller.loading
                    ? null
                    : controller.togglePlayback,
                icon: Icon(
                  controller.playing
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                ),
              ),
              IconButton(
                key: const ValueKey('event-audio-mute'),
                tooltip: controller.muted ? 'Activar sonido' : 'Silenciar',
                onPressed: controller.toggleMute,
                icon: Icon(
                  controller.muted
                      ? Icons.volume_off_rounded
                      : Icons.volume_up_rounded,
                ),
              ),
              Expanded(
                child: Slider(
                  key: const ValueKey('event-audio-volume'),
                  value: controller.volume,
                  label: '${(controller.volume * 100).round()}%',
                  semanticFormatterCallback: (value) =>
                      'Volumen ${(value * 100).round()} por ciento',
                  onChanged: controller.setVolume,
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class EventMedia extends StatelessWidget {
  final PulsoEvent event;
  final EventImageBuilder imageBuilder;
  final AudioPlayback Function()? audioFactory;
  final Future<bool> Function(Uri)? externalLauncher;
  final bool showFlyers;
  final bool autoplay;
  final EventAudioControls? audioControls;
  final EmbeddedTrackController Function()? embeddedFactory;
  final EmbeddedEventPlayerBuilder? embeddedBuilder;
  const EventMedia({
    super.key,
    required this.event,
    this.imageBuilder = networkEventImage,
    this.audioFactory,
    this.externalLauncher,
    this.showFlyers = true,
    this.autoplay = false,
    this.audioControls,
    this.embeddedFactory,
    this.embeddedBuilder,
  });
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showFlyers && event.flyers.isNotEmpty) ...[
          LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.hasBoundedWidth
                  ? constraints.maxWidth
                  : MediaQuery.sizeOf(context).width;
              final heightLimit = (MediaQuery.sizeOf(context).height * .34)
                  .clamp(180.0, 440.0);
              final height = (width * .72).clamp(180.0, heightLimit).toDouble();
              return DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.surface,
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(
                    color: colors.onSurface.withValues(alpha: .12),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: SizedBox(
                    height: height,
                    child: PageView(
                      children: [
                        for (final uri in event.flyers)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: imageBuilder(uri, BoxFit.contain),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
          if (event.flyers.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.swipe_rounded, size: 18, color: colors.secondary),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      'Deslizá para ver los flyers',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.onSurface.withValues(alpha: .72),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 24),
        ],
        if (event.tracks.isNotEmpty)
          EventTracks(
            key: ValueKey('tracks-${event.id}'),
            tracks: event.tracks,
            audioFactory: audioFactory,
            externalLauncher: externalLauncher,
            autoplay: autoplay,
            audioControls: audioControls,
            embeddedFactory: embeddedFactory,
            embeddedBuilder: embeddedBuilder,
          ),
      ],
    );
  }
}

class EventTracks extends StatefulWidget {
  final List<EventTrack> tracks;
  final AudioPlayback Function()? audioFactory;
  final Future<bool> Function(Uri)? externalLauncher;
  final bool autoplay;
  final EventAudioControls? audioControls;
  final EmbeddedTrackController Function()? embeddedFactory;
  final EmbeddedEventPlayerBuilder? embeddedBuilder;
  const EventTracks({
    super.key,
    required this.tracks,
    this.audioFactory,
    this.externalLauncher,
    this.autoplay = false,
    this.audioControls,
    this.embeddedFactory,
    this.embeddedBuilder,
  });
  @override
  State<EventTracks> createState() => _EventTracksState();
}

class _EventTracksState extends State<EventTracks> with WidgetsBindingObserver {
  // A new event must wait for the previous native player to release its audio
  // resources. The lease also protects against two mounted media sections.
  static _EventTracksState? _owner;
  // Retain only pending operations, never completed Futures (or their zones).
  static Future<void>? _claimQueue;
  static Future<void>? _releaseBarrier;
  AudioPlayback? _audio;
  EmbeddedTrackController? _embedded;
  EventTrack? _embeddedTrack;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<Object>? _errorSubscription;
  String? _selected;
  bool _playing = false;
  bool _loading = false;
  String? _error;
  String? _notice;
  int _generation = 0;
  bool _foreground = true;
  bool _autoplayAttempted = false;
  String? _loadedTrack;
  double _volume = .8;
  double _audibleVolume = .8;
  Future<void> _volumeQueue = Future<void>.value();

  // The actual event model currently accepts upload and external only.
  bool _internal(EventTrack track) => track.kind == 'upload';
  String _identity(EventTrack track) =>
      '${track.id}|${track.kind}|${track.url}';
  String _playlist(List<EventTrack> tracks) =>
      tracks.take(3).map(_identity).join('\n');
  bool _current(int generation) =>
      mounted && _foreground && generation == _generation;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    final controls = widget.audioControls;
    if (controls != null) {
      _volume = controls.volume;
      controls.addListener(_controlsChanged);
    }
    _scheduleAutoplay();
  }

  @override
  void didUpdateWidget(covariant EventTracks oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.audioControls, widget.audioControls)) {
      oldWidget.audioControls?.removeListener(_controlsChanged);
      oldWidget.audioControls?._detach(this);
      final controls = widget.audioControls;
      if (controls != null) {
        controls.addListener(_controlsChanged);
        _volume = controls.volume;
      }
    }
    if (_playlist(oldWidget.tracks) != _playlist(widget.tracks)) {
      unawaited(_stopAndRelease());
      _autoplayAttempted = false;
      _error = null;
      _notice = null;
      _scheduleAutoplay();
    } else if (!oldWidget.autoplay && widget.autoplay) {
      _scheduleAutoplay();
    }
  }

  void _scheduleAutoplay() {
    if (!widget.autoplay || _autoplayAttempted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_foreground || !widget.autoplay || _autoplayAttempted) {
        return;
      }
      _autoplayAttempted = true;
      if (widget.tracks.isEmpty) return;
      final first = widget.tracks.first;
      if (_internal(first) ||
          (first.kind == 'external' && canEmbedTrack(first.url))) {
        unawaited(_activate(first));
      } else {
        setState(
          () => _notice =
              'El primer audio necesita abrir su enlace. Tocá el audio para escucharlo.',
        );
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      unawaited(_stopAndRelease());
    } else if (mounted) {
      setState(() {});
    }
    // Returning from another app never starts audio without another tap.
  }

  void _audioError(Object error) {
    unawaited(_stopAndRelease());
    if (mounted) {
      setState(() {
        _error = 'No se pudo reproducir el audio. Podés reintentar.';
        _playing = false;
        _loading = false;
      });
    }
  }

  Future<void> _stopAndRelease({
    bool notify = true,
    bool invalidate = true,
    bool retainLoading = false,
  }) {
    if (invalidate) _generation++;
    final audio = _audio;
    final embedded = _embedded;
    // Capture native shutdown before removing the child from the widget tree.
    // Its dispose otherwise detaches the controller while about:blank is still
    // loading, which would let a new engine start before the old one stops.
    final embeddedRelease = embedded?.dispose();
    final playing = _playingSubscription;
    final errors = _errorSubscription;
    _audio = null;
    _embedded = null;
    _embeddedTrack = null;
    _playingSubscription = null;
    _errorSubscription = null;
    _selected = null;
    _loadedTrack = null;
    _playing = false;
    if (!retainLoading) _loading = false;
    if (identical(_owner, this)) _owner = null;
    if (notify && mounted) setState(() {});
    final release = () async {
      // Cleanup must continue even when one platform operation fails.
      try {
        await audio?.pause();
      } catch (_) {}
      try {
        await playing?.cancel();
      } catch (_) {}
      try {
        await errors?.cancel();
      } catch (_) {}
      try {
        await audio?.dispose();
      } catch (_) {}
      try {
        await embeddedRelease;
      } catch (_) {}
    }();
    final preceding = _releaseBarrier;
    final barrier = preceding == null
        ? release
        : Future.wait<void>([preceding, release]).then((_) {});
    _releaseBarrier = barrier;
    unawaited(
      barrier.then((_) {
        if (identical(_releaseBarrier, barrier)) _releaseBarrier = null;
      }),
    );
    return release;
  }

  Future<bool> _claim(int generation) async {
    final preceding = _claimQueue;
    final completed = Completer<void>();
    _claimQueue = completed.future;
    try {
      if (preceding != null) await preceding;
      if (!_current(generation)) return false;
      final previousOwner = _owner;
      if (previousOwner != null && !identical(previousOwner, this)) {
        await previousOwner._stopAndRelease();
      }
      final release = _releaseBarrier;
      if (release != null) await release;
      if (!_current(generation)) return false;
      _owner = this;
      return true;
    } finally {
      if (identical(_claimQueue, completed.future)) _claimQueue = null;
      completed.complete();
    }
  }

  Future<AudioPlayback?> _acquire(int generation) async {
    if (!await _claim(generation)) return null;
    if (_audio == null) {
      final audio = (widget.audioFactory ?? JustAudioPlayback.new)();
      _audio = audio;
      _playingSubscription = audio.playing.listen((playing) {
        if (mounted && _foreground && identical(_audio, audio)) {
          setState(() => _playing = playing);
        }
      });
      _errorSubscription = audio.errors.listen((error) {
        if (mounted && identical(_audio, audio)) _audioError(error);
      });
    }
    return _audio;
  }

  Future<void> _applyVolume(AudioPlayback audio, int generation) {
    final volume = _volume;
    _volumeQueue = _volumeQueue.then((_) async {
      if (!_current(generation) || !identical(_audio, audio)) return;
      try {
        await audio.setVolume(volume);
      } catch (error) {
        if (_current(generation) && identical(_audio, audio)) {
          _audioError(error);
        }
      }
    });
    return _volumeQueue;
  }

  Future<void> _applyEmbeddedVolume(
    EmbeddedTrackController controller,
    int generation,
  ) {
    final volume = _volume;
    _volumeQueue = _volumeQueue.then((_) async {
      if (!_current(generation) || !identical(_embedded, controller)) return;
      try {
        await controller.setVolume(volume);
      } catch (error) {
        if (_current(generation) && identical(_embedded, controller)) {
          _audioError(error);
        }
      }
    });
    return _volumeQueue;
  }

  void _setVolume(double volume) {
    final controls = widget.audioControls;
    if (controls != null) {
      controls.setVolume(volume);
      return;
    }
    _changeVolume(volume);
  }

  void _controlsChanged() {
    final controls = widget.audioControls;
    if (mounted && controls != null && _volume != controls.volume) {
      _changeVolume(controls.volume);
    }
  }

  void _changeVolume(double volume) {
    setState(() {
      _volume = volume.clamp(0.0, 1.0).toDouble();
      if (_volume > 0) _audibleVolume = _volume;
    });
    final audio = _audio;
    if (audio != null) unawaited(_applyVolume(audio, _generation));
    final embedded = _embedded;
    if (embedded != null) {
      unawaited(_applyEmbeddedVolume(embedded, _generation));
    }
  }

  Future<void> _activate(EventTrack track) async {
    if (_loading ||
        !_foreground ||
        (!_internal(track) && track.kind != 'external')) {
      return;
    }
    _autoplayAttempted = true;
    final generation = ++_generation;
    setState(() {
      _error = null;
      _notice = null;
      _loading = true;
    });
    try {
      if (track.kind == 'external') {
        if (canEmbedTrack(track.url)) {
          if (_embedded != null &&
              _selected == track.id &&
              _embeddedTrack?.url == track.url) {
            if (_playing) {
              await _embedded!.pause();
            } else {
              await _embedded!.play();
            }
          } else {
            await _stopAndRelease(invalidate: false, retainLoading: true);
            if (!_current(generation) || !await _claim(generation)) return;
            final controller =
                (widget.embeddedFactory ?? EmbeddedTrackController.new)();
            setState(() {
              _embedded = controller;
              _embeddedTrack = track;
              _selected = track.id;
              _notice = 'Si no comienza, tocá reproducir en el reproductor.';
            });
            await _applyEmbeddedVolume(controller, generation);
            // The embedded widget performs one best-effort start when READY.
            // Only its real PLAY callback may mark the track as playing.
          }
        } else {
          await _stopAndRelease(invalidate: false, retainLoading: true);
          if (!_current(generation)) return;
          final opened = await (widget.externalLauncher ?? openExternalTrack)(
            track.url,
          );
          if (!opened) throw StateError('External application unavailable');
        }
      } else {
        if (_embedded != null) {
          await _stopAndRelease(invalidate: false, retainLoading: true);
          if (!_current(generation)) return;
        }
        final audio = await _acquire(generation);
        if (audio == null || !_current(generation)) return;
        if (_selected == track.id && _playing) {
          await audio.pause();
        } else {
          if (_loadedTrack != _identity(track)) {
            await audio.pause();
            if (!_current(generation)) return;
            await audio.load(track.url);
            if (!_current(generation)) return;
            _loadedTrack = _identity(track);
          }
          if (!_current(generation)) return;
          _selected = track.id;
          await _applyVolume(audio, generation);
          if (!_current(generation)) return;
          await audio.play();
        }
      }
    } catch (e) {
      if (_current(generation)) _audioError(e);
    } finally {
      if (_current(generation)) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.audioControls?.removeListener(_controlsChanged);
    widget.audioControls?._detach(this);
    unawaited(_stopAndRelease(notify: false));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final candidate =
        widget.tracks.where((track) => track.id == _selected).firstOrNull ??
        widget.tracks.firstOrNull;
    final available =
        candidate != null &&
        (_internal(candidate) || canEmbedTrack(candidate.url));
    widget.audioControls?._publish(
      this,
      available: available && _foreground,
      playing: _playing,
      loading: _loading,
      toggle: () {
        if (candidate != null) unawaited(_activate(candidate));
      },
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Audio del evento', style: theme.textTheme.titleLarge),
        if (widget.audioControls == null &&
            widget.tracks
                .take(3)
                .any((track) => _internal(track) || canEmbedTrack(track.url)))
          Row(
            children: [
              IconButton(
                key: const ValueKey('event-audio-mute'),
                tooltip: _volume == 0 ? 'Activar sonido' : 'Silenciar',
                onPressed: () => _setVolume(_volume == 0 ? _audibleVolume : 0),
                icon: Icon(
                  _volume == 0
                      ? Icons.volume_off_rounded
                      : Icons.volume_up_rounded,
                ),
              ),
              Expanded(
                child: Slider(
                  key: const ValueKey('event-audio-volume'),
                  value: _volume,
                  label: '${(_volume * 100).round()}%',
                  semanticFormatterCallback: (value) =>
                      'Volumen ${(value * 100).round()} por ciento',
                  onChanged: _setVolume,
                ),
              ),
              Text(
                '${(_volume * 100).round()}%',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        if (_notice != null)
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 8),
            child: Text(_notice!, style: theme.textTheme.bodySmall),
          ),
        const SizedBox(height: 12),
        for (final track in widget.tracks.take(3))
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _trackButton(context, track),
          ),
        if (_embeddedTrack != null && _embedded != null)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 12),
            child: _embeddedPlayer(),
          ),
        if (_loading)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: LinearProgressIndicator(
                minHeight: 3,
                color: colors.primary,
                backgroundColor: colors.onSurface.withValues(alpha: .08),
              ),
            ),
          ),
        if (_error != null)
          Container(
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colors.errorContainer.withValues(alpha: .22),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: colors.error.withValues(alpha: .35)),
            ),
            child: Text(
              _error!,
              style: theme.textTheme.bodyMedium?.copyWith(color: colors.error),
            ),
          ),
      ],
    );
  }

  Widget _embeddedPlayer() {
    final controller = _embedded!;
    return KeyedSubtree(
      // A released controller owns a closed native view. A new track must get
      // fresh State even when shutdown finishes before the next Flutter frame.
      key: ObjectKey(controller),
      child: (widget.embeddedBuilder ?? EmbeddedTrackPlayer.new)(
        url: _embeddedTrack!.url,
        controller: controller,
        autoplay: true,
        muted: _volume == 0,
        onPlaying: (playing) {
          if (!mounted || !_foreground || !identical(_embedded, controller)) {
            return;
          }
          setState(() {
            _playing = playing;
            if (playing) _notice = null;
          });
          if (playing) unawaited(_applyEmbeddedVolume(controller, _generation));
        },
        onError: (message) {
          if (!mounted || !identical(_embedded, controller)) return;
          setState(() {
            // Nonfatal provider notices do not change real PLAY/PAUSE state.
            // Fatal failures already send onPlaying(false) from the player.
            _notice = message;
          });
        },
      ),
    );
  }

  Widget _trackButton(BuildContext context, EventTrack track) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final external = track.kind == 'external';
    final embedded = external && canEmbedTrack(track.url);
    final playing = _selected == track.id && _playing;
    final accent = external ? colors.secondary : colors.primary;
    return OutlinedButton(
      key: ValueKey('track-${track.id}'),
      onPressed: _loading ? null : () => _activate(track),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 80),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        alignment: Alignment.centerLeft,
        foregroundColor: colors.onSurface,
        backgroundColor: playing
            ? accent.withValues(alpha: .12)
            : colors.surface,
        side: BorderSide(
          color: playing ? accent : colors.onSurface.withValues(alpha: .12),
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: playing ? .24 : .12),
              shape: BoxShape.circle,
            ),
            child: Icon(
              external && !embedded
                  ? Icons.open_in_new_rounded
                  : playing
                  ? Icons.pause_rounded
                  : Icons.play_arrow_rounded,
              color: accent,
              size: 25,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  track.title,
                  softWrap: true,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: colors.onSurface,
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  external && !embedded
                      ? 'Abrir enlace'
                      : playing
                      ? 'Reproduciendo · Pausar'
                      : 'Reproducir audio',
                  softWrap: true,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: playing
                        ? accent
                        : colors.onSurface.withValues(alpha: .66),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
