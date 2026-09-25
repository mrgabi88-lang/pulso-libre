import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'api_service.dart';

abstract interface class MonotonicClock {
  Duration get now;
}

class StopwatchClock implements MonotonicClock {
  final Stopwatch _watch = Stopwatch()..start();
  @override
  Duration get now => _watch.elapsed;
}

class QrController extends ChangeNotifier {
  final Future<Map<String, dynamic>> Function() fetch;
  final MonotonicClock clock;
  final int ticketId;
  String _payload = '';
  Duration? _deadline;
  Duration? _retryAt;
  Timer? _ticker;
  Timer? _expiry;
  Timer? _retry;
  bool _disposed = false;
  bool busy = false;
  String? error;
  int _generation = 0;
  QrController({
    required this.fetch,
    required this.ticketId,
    MonotonicClock? clock,
  }) : clock = clock ?? StopwatchClock();
  String get payload =>
      _deadline != null && clock.now < _deadline! ? _payload : '';
  int get remaining => _deadline == null
      ? 0
      : max(0, ((_deadline! - clock.now).inMilliseconds / 1000).ceil());
  int get retryIn => _retryAt == null
      ? 0
      : max(0, ((_retryAt! - clock.now).inMilliseconds / 1000).ceil());
  bool get canRetry => !busy && retryIn == 0;

  void _scheduleRetry(Duration delay) {
    _retry?.cancel();
    _retryAt = clock.now + delay;
    _retry = Timer(delay, () {
      if (_disposed) return;
      _retryAt = null;
      unawaited(refresh());
    });
  }

  void start() {
    _ticker ??= Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!_disposed) notifyListeners();
    });
    unawaited(refresh());
  }

  Future<void> refresh() async {
    if (_disposed || busy || retryIn > 0) return;
    _retry?.cancel();
    _retryAt = null;
    busy = true;
    error = null;
    final generation = ++_generation;
    final sentAt = clock.now;
    notifyListeners();
    try {
      final data = await fetch();
      if (_disposed || generation != _generation) return;
      final value = data['qr_payload'];
      final expiry = DateTime.tryParse('${data['expires_at']}');
      final serverNow = DateTime.tryParse('${data['server_time']}');
      final expiresIn = int.tryParse('${data['expires_in']}');
      final refreshSeconds = int.tryParse('${data['refresh_seconds']}');
      if (value is! String ||
          value.isEmpty ||
          expiry == null ||
          serverNow == null ||
          expiresIn == null ||
          expiresIn <= 0 ||
          refreshSeconds == null ||
          refreshSeconds <= 0 ||
          (data['ticket_id'] != null &&
              '${data['ticket_id']}' != '$ticketId')) {
        throw const ApiException('No se pudo comprobar la vigencia del QR.');
      }
      // A conservative monotonic deadline: server validity minus full request
      // round-trip time. Local wall clock changes never extend visible validity.
      final validityMs = min(
        expiry.difference(serverNow).inMilliseconds,
        expiresIn * 1000,
      );
      final roundTrip = clock.now - sentAt;
      final afterBoundary = roundTrip + const Duration(milliseconds: 50);
      final ttl = Duration(milliseconds: validityMs) - roundTrip;
      if (validityMs <= 0) {
        throw const ApiException(
          'El QR recibido ya venció. Volvé a solicitarlo.',
        );
      }
      if (ttl <= Duration.zero) {
        _payload = '';
        _deadline = null;
        _expiry?.cancel();
        _scheduleRetry(afterBoundary);
        return;
      }
      _payload = value;
      _deadline = clock.now + ttl;
      _expiry?.cancel();
      _expiry = Timer(ttl, () {
        if (_disposed) return;
        _payload = '';
        _deadline = null;
        notifyListeners();
        // Visibility expires conservatively before the remote boundary. Wait
        // through that boundary before asking for the next five-second slot.
        _scheduleRetry(afterBoundary);
      });
    } catch (e) {
      if (_disposed || generation != _generation) return;
      _payload = '';
      _deadline = null;
      _expiry?.cancel();
      error = e is ApiException
          ? e.message
          : 'No pudimos renovar el QR. Comprobá la conexión.';
      final seconds = e is ApiException ? max(5, e.retryAfter ?? 5) : 5;
      _scheduleRetry(Duration(seconds: seconds));
    } finally {
      if (!_disposed && generation == _generation) {
        busy = false;
        notifyListeners();
      }
    }
  }

  void conceal() {
    _generation++;
    _payload = '';
    _deadline = null;
    _expiry?.cancel();
    _retry?.cancel();
    _retryAt = null;
    busy = false;
    error = 'Volvé a solicitar el QR para mostrarlo.';
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _ticker?.cancel();
    _expiry?.cancel();
    _retry?.cancel();
    super.dispose();
  }
}
