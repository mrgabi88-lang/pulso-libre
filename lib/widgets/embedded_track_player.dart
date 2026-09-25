import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// Public SoundCloud track/playlist links only. Profile, discovery, private and
/// shortened links need an explicit external action instead of guessed audio.
bool canEmbedTrack(Uri url) {
  if (url.scheme != 'https' ||
      url.userInfo.isNotEmpty ||
      (url.hasPort && url.port != 443) ||
      !const {
        'soundcloud.com',
        'www.soundcloud.com',
        'm.soundcloud.com',
      }.contains(url.host.toLowerCase()) ||
      url.queryParameters.containsKey('secret_token')) {
    return false;
  }
  final segments = url.pathSegments.toList();
  if (segments.isNotEmpty && segments.last.isEmpty) segments.removeLast();
  if (segments.length != 2 && segments.length != 3) return false;
  final slug = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_-]*$');
  if (segments.any((part) => !slug.hasMatch(part))) return false;
  if (const {
    'you',
    'discover',
    'search',
    'stream',
    'charts',
    'upload',
    'settings',
    'signin',
    'sign-in',
    'signout',
    'logout',
    'login',
    'pages',
    'terms-of-use',
  }.contains(segments.first.toLowerCase())) {
    return false;
  }
  if (segments.length == 3) return segments[1] == 'sets';
  return !const {
    'sets',
    'tracks',
    'albums',
    'popular-tracks',
    'reposts',
    'likes',
    'followers',
    'following',
    'comments',
  }.contains(segments[1].toLowerCase());
}

Uri _publicTrackUrl(Uri url) {
  if (!canEmbedTrack(url)) throw ArgumentError('Unsupported embedded track');
  final segments = url.pathSegments.where((part) => part.isNotEmpty).toList();
  return Uri(scheme: 'https', host: 'soundcloud.com', pathSegments: segments);
}

/// Generates only our wrapper and the official provider iframe/API. No fetched
/// HTML, account credentials, stream extraction or organizer-supplied scripts.
@visibleForTesting
String buildSoundCloudPlayerHtml(
  Uri url, {
  required bool autoplay,
  required double volume,
  int generation = 0,
}) {
  final player = Uri.https('w.soundcloud.com', '/player/', {
    'url': _publicTrackUrl(url).toString(),
    // The iframe must not start at its default volume before READY. Our Widget
    // API callback applies the selected volume, then requests playback once.
    'auto_play': 'false',
    'single_active': 'true',
    'show_artwork': 'true',
    'show_user': 'true',
    'show_playcount': 'false',
    'sharing': 'false',
    'buying': 'false',
    'download': 'false',
    'visual': 'false',
  });
  final src = const HtmlEscape(HtmlEscapeMode.attribute).convert('$player');
  final level = volume.isFinite ? (volume.clamp(0.0, 1.0) * 100).round() : 80;
  return '''<!doctype html>
<html><head><meta name="viewport" content="width=device-width,initial-scale=1">
<style>html,body{margin:0;padding:0;background:transparent;overflow:hidden}
iframe{display:block;border:0;width:100%;height:166px}</style></head><body>
<iframe id="soundcloud" title="Reproductor SoundCloud" height="166"
 scrolling="no" allow="autoplay" src="$src"></iframe>
<script src="https://w.soundcloud.com/player/api.js"></script>
<script>
(function(){
  var player=null, ready=false, wanted=$autoplay, volume=$level, disposed=false;
  function report(event){if(!disposed && window.PulsoSoundCloud) {
    window.PulsoSoundCloud.postMessage('$generation:' + event);
  }}
  window.pulsoPlayer={
    play:function(){if(disposed)return; wanted=true;if(ready)player.play();},
    pause:function(){wanted=false;if(ready)player.pause();},
    volume:function(value){volume=Math.max(0,Math.min(100,value));
      if(ready)player.setVolume(volume);},
    dispose:function(){disposed=true;wanted=false;if(ready)player.pause();
      document.getElementById('soundcloud').src='about:blank';}
  };
  if(!window.SC || !window.SC.Widget){report('ERROR');return;}
  player=SC.Widget('soundcloud');
  player.bind(SC.Widget.Events.READY,function(){
    if(disposed)return;ready=true;player.setVolume(volume);report('READY');
    if(wanted)player.play();else player.pause();
  });
  player.bind(SC.Widget.Events.PLAY,function(){
    if(disposed){player.pause();return;}report('PLAY');
  });
  player.bind(SC.Widget.Events.PAUSE,function(){report('PAUSE');});
  player.bind(SC.Widget.Events.FINISH,function(){report('FINISH');});
  player.bind(SC.Widget.Events.ERROR,function(){report('ERROR');});
})();
</script></body></html>''';
}

/// Commands may arrive before the native view is ready. Their latest intent is
/// retained; dispose prevents a delayed READY from starting a departed event.
class EmbeddedTrackController {
  _EmbeddedTrackPlayerState? _state;
  bool? _wantsPlay;
  double? _volume;
  bool _disposed = false;

  Future<void> play() async {
    if (_disposed) return;
    _wantsPlay = true;
    await _state?._play();
  }

  Future<void> pause() async {
    if (_disposed) return;
    _wantsPlay = false;
    await _state?._pause();
  }

  Future<void> setVolume(double volume) async {
    if (_disposed || !volume.isFinite) return;
    _volume = volume.clamp(0.0, 1.0);
    await _state?._setVolume(_volume!);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _wantsPlay = false;
    final state = _state;
    _state = null;
    await state?._shutdown();
  }
}

class EmbeddedTrackPlayer extends StatefulWidget {
  final Uri url;
  final EmbeddedTrackController controller;
  final bool autoplay;
  final bool muted;
  final VoidCallback? onReady;
  final ValueChanged<bool>? onPlaying;
  final ValueChanged<String>? onError;

  const EmbeddedTrackPlayer({
    super.key,
    required this.url,
    required this.controller,
    this.autoplay = false,
    this.muted = false,
    this.onReady,
    this.onPlaying,
    this.onError,
  });

  @override
  State<EmbeddedTrackPlayer> createState() => _EmbeddedTrackPlayerState();
}

class _EmbeddedTrackPlayerState extends State<EmbeddedTrackPlayer> {
  WebViewController? _web;
  Timer? _playTimeout;
  Future<void>? _shutdownFuture;
  bool _closed = false;
  bool _playing = false;
  bool _ready = false;
  bool _failed = false;
  String? _message;
  int _loadGeneration = 0;

  bool get _live => mounted && !_closed && !widget.controller._disposed;
  bool get _wantsPlay => widget.controller._wantsPlay ?? widget.autoplay;
  double get _volume => widget.muted ? 0 : (widget.controller._volume ?? .8);

  @override
  void initState() {
    super.initState();
    widget.controller._state = this;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_live) unawaited(_initialize());
    });
  }

  @override
  void didUpdateWidget(covariant EmbeddedTrackPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      if (identical(oldWidget.controller._state, this)) {
        oldWidget.controller._state = null;
      }
      widget.controller._state = this;
    }
    if (oldWidget.url != widget.url ||
        !identical(oldWidget.controller, widget.controller)) {
      unawaited(_load());
    } else if (oldWidget.muted != widget.muted) {
      unawaited(_setVolume(widget.muted ? 0 : _volume));
    }
  }

  Future<void> _initialize() async {
    if (!_live || !canEmbedTrack(widget.url)) {
      _report('Este enlace no corresponde a una pista pública de SoundCloud.');
      return;
    }
    try {
      final web = WebViewController();
      _web = web;
      await web.setJavaScriptMode(JavaScriptMode.unrestricted);
      await web.setBackgroundColor(Colors.transparent);
      await web.addJavaScriptChannel(
        'PulsoSoundCloud',
        onMessageReceived: (event) {
          _receive(event.message);
        },
      );
      await web.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            if (request.url == 'about:blank') {
              return NavigationDecision.navigate;
            }
            if (!request.isMainFrame &&
                uri != null &&
                uri.scheme == 'https' &&
                uri.host == 'w.soundcloud.com' &&
                uri.path.startsWith('/player/')) {
              return NavigationDecision.navigate;
            }
            _report(
              'Usá los controles del reproductor para escuchar la pista.',
            );
            return NavigationDecision.prevent;
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == true) {
              _report(
                'No se pudo cargar SoundCloud. Tocá Reproducir para reintentar.',
                failed: true,
              );
            }
          },
        ),
      );
      if (web.platform is AndroidWebViewController) {
        await (web.platform as AndroidWebViewController)
            .setMediaPlaybackRequiresUserGesture(false);
      }
      if (!_live) return;
      setState(() {});
      await _load();
    } catch (_) {
      _report(
        'SoundCloud no está disponible en este dispositivo.',
        failed: true,
      );
    }
  }

  Future<void> _load() async {
    final web = _web;
    if (!_live || web == null) return;
    final generation = ++_loadGeneration;
    _playTimeout?.cancel();
    try {
      // Pause before replacing the iframe so switching a URL cannot overlap.
      await web.runJavaScript('window.pulsoPlayer?.dispose();');
      if (!_live || generation != _loadGeneration) return;
      _ready = false;
      _failed = false;
      _playing = false;
      await web.loadHtmlString(
        buildSoundCloudPlayerHtml(
          widget.url,
          autoplay: _wantsPlay,
          volume: _volume,
          generation: generation,
        ),
      );
      if (!_live || generation != _loadGeneration) return;
      if (_wantsPlay) _armTimeout();
    } catch (_) {
      _report(
        'No se pudo cargar SoundCloud. Tocá Reproducir para reintentar.',
        failed: true,
      );
    }
  }

  void _receive(String event) {
    if (!_live) return;
    final parts = event.split(':');
    if (parts.length != 2 || int.tryParse(parts[0]) != _loadGeneration) return;
    switch (parts[1]) {
      case 'READY':
        setState(() => _ready = true);
        // Commands sent during document loading must retain their latest intent.
        unawaited(_setVolume(_volume));
        if (!_wantsPlay) unawaited(_pause());
        widget.onReady?.call();
      // READY only confirms readiness, never playback.
      case 'PLAY':
        _playTimeout?.cancel();
        setState(() {
          _playing = true;
          _message = null;
        });
        widget.onPlaying?.call(true);
      case 'PAUSE':
      case 'FINISH':
        if (_playing || !_wantsPlay) _playTimeout?.cancel();
        setState(() => _playing = false);
        widget.onPlaying?.call(false);
      case 'ERROR':
        _report(
          'SoundCloud no pudo reproducir esta pista. Puede estar privada, '
          'restringida o no disponible para insertar.',
          failed: true,
        );
    }
  }

  void _armTimeout() {
    _playTimeout?.cancel();
    _playTimeout = Timer(const Duration(seconds: 8), () {
      if (_live && !_playing) {
        _report(
          'SoundCloud todavía no inició. Tocá Reproducir; '
          'el proveedor puede requerir una acción manual.',
        );
      }
    });
  }

  void _report(String message, {bool failed = false}) {
    if (!_live) return;
    if (failed) _playTimeout?.cancel();
    setState(() {
      _message = message;
      _failed = failed;
      if (failed) _playing = false;
    });
    if (failed) widget.onPlaying?.call(false);
    widget.onError?.call(message);
  }

  Future<void> _command(String code) async {
    if (!_live || _web == null) return;
    try {
      await _web!.runJavaScript(code);
    } catch (_) {
      _report(
        'No se pudo controlar SoundCloud. Podés reintentar.',
        failed: true,
      );
    }
  }

  Future<void> _play() async {
    if (!_live) return;
    setState(() => _message = null);
    if (_failed) {
      await _load();
    } else {
      await _command('window.pulsoPlayer?.play();');
    }
    if (_live && !_playing) _armTimeout();
  }

  Future<void> _pause() async {
    _playTimeout?.cancel();
    await _command('window.pulsoPlayer?.pause();');
  }

  Future<void> _setVolume(double volume) =>
      _command('window.pulsoPlayer?.volume(${(volume * 100).round()});');

  Future<void> _shutdown() {
    if (_shutdownFuture != null) return _shutdownFuture!;
    _closed = true;
    _loadGeneration++;
    _playTimeout?.cancel();
    final web = _web;
    _shutdownFuture = () async {
      if (web == null) return;
      try {
        await web.runJavaScript('window.pulsoPlayer?.dispose();');
      } catch (_) {}
      // Empty the native frame even if the provider or JS API failed.
      try {
        await web.loadRequest(Uri.parse('about:blank'));
      } catch (_) {}
    }();
    return _shutdownFuture!;
  }

  @override
  void dispose() {
    if (identical(widget.controller._state, this)) {
      widget.controller._state = null;
    }
    unawaited(_shutdown());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 166,
          child: _web == null
              ? const Center(child: CircularProgressIndicator())
              : WebViewWidget(controller: _web!),
        ),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              _message!,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        Row(
          children: [
            TextButton.icon(
              key: const ValueKey('embedded-track-play'),
              onPressed: _playing
                  ? widget.controller.pause
                  : widget.controller.play,
              icon: Icon(
                _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              ),
              label: Text(_playing ? 'Pausar' : 'Reproducir'),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _playing
                    ? 'SoundCloud · Reproduciendo'
                    : _ready
                    ? 'SoundCloud'
                    : 'SoundCloud · Cargando',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
