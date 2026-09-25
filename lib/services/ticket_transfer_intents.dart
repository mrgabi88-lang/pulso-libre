import 'dart:convert';
import 'dart:math';
import '../models/ticket_transfer.dart';
import 'session_store.dart';

class TicketTransferIntent {
  final String owner;
  final int ticketId;
  final String recipientEmail;
  final String requestId;
  const TicketTransferIntent({
    required this.owner,
    required this.ticketId,
    required this.recipientEmail,
    required this.requestId,
  });
  Map<String, dynamic> toJson() => {
    'owner': owner,
    'ticket_id': ticketId,
    'recipient_email': recipientEmail,
    'request_id': requestId,
  };
}

/// Durable ambiguous attempts live in the existing encrypted vault, separate
/// from purchase intents. Closing a dialog or locking never discards an ID.
class TicketTransferIntents {
  static const storageKey = SessionStore.transferIntentsKey;
  final SessionStore session;
  TicketTransferIntents(this.session);

  String get owner {
    if (!session.authenticated) {
      throw StateError('Ingresá para transferir una entrada.');
    }
    return '${session.user!['id']}:${session.email.trim().toLowerCase()}';
  }

  Future<T> _serial<T>(Future<T> Function() operation) =>
      session.withTransferIntents(operation);

  Future<Map<String, dynamic>> _read() async {
    final raw = await session.vault.read(storageKey);
    if (raw == null) return {};
    final data = jsonDecode(raw);
    if (data is! Map) {
      throw const FormatException(
        'No se pudo recuperar el intento de transferencia.',
      );
    }
    return Map<String, dynamic>.from(data);
  }

  TicketTransferIntent? _entry(
    Map<String, dynamic> data,
    String account,
    int ticketId,
  ) {
    final raw = data['$account:$ticketId'];
    if (raw == null) return null;
    if (raw is! Map ||
        raw['owner'] != account ||
        raw['ticket_id'] != ticketId ||
        raw['recipient_email'] is! String ||
        raw['request_id'] is! String ||
        !RegExp(
          r'^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$',
        ).hasMatch(raw['request_id'])) {
      throw const FormatException(
        'No se pudo recuperar el intento de transferencia.',
      );
    }
    return TicketTransferIntent(
      owner: account,
      ticketId: ticketId,
      recipientEmail: raw['recipient_email'],
      requestId: raw['request_id'],
    );
  }

  Future<TicketTransferIntent?> pending(int ticketId) {
    final account = owner;
    return _serial(() async {
      final entry = _entry(await _read(), account, ticketId);
      if (owner != account) {
        throw StateError('La cuenta cambió. Volvé a intentar.');
      }
      return entry;
    });
  }

  Future<TicketTransferIntent> begin(int ticketId, String email) {
    final account = owner;
    return _serial(() async {
      final data = await _read();
      if (owner != account) {
        throw StateError('La cuenta cambió. Volvé a intentar.');
      }
      final existing = _entry(data, account, ticketId);
      if (existing != null) {
        if (existing.recipientEmail != email) {
          throw StateError(
            'Hay un intento pendiente de confirmar para esta entrada. Actualizá las solicitudes o reintentá con el mismo correo.',
          );
        }
        return existing;
      }
      final random = Random.secure();
      final bytes = List.generate(16, (_) => random.nextInt(256));
      bytes[6] = (bytes[6] & 15) | 64;
      bytes[8] = (bytes[8] & 63) | 128;
      final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final id =
          '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
      final intent = TicketTransferIntent(
        owner: account,
        ticketId: ticketId,
        recipientEmail: email,
        requestId: id,
      );
      data['$account:$ticketId'] = intent.toJson();
      await session.vault.write(storageKey, jsonEncode(data));
      if (owner != account) {
        throw StateError('La cuenta cambió. Volvé a intentar.');
      }
      return intent;
    });
  }

  Future<void> complete(TicketTransferIntent intent) => _serial(() async {
    final data = await _read();
    final existing = _entry(data, intent.owner, intent.ticketId);
    if (existing?.requestId != intent.requestId) return;
    data.remove('${intent.owner}:${intent.ticketId}');
    await session.vault.write(storageKey, jsonEncode(data));
  });

  Future<void> reconcile(String account, List<TicketTransfer> outgoing) =>
      _serial(() async {
        final data = await _read();
        var changed = false;
        for (final transfer in outgoing) {
          final existing = _entry(data, account, transfer.ticketId);
          if (existing != null &&
              existing.requestId == transfer.requestId &&
              existing.recipientEmail == transfer.recipientEmail) {
            data.remove('$account:${transfer.ticketId}');
            changed = true;
          }
        }
        if (changed) await session.vault.write(storageKey, jsonEncode(data));
      });
}
