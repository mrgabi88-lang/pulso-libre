import 'event.dart';

class TicketTransfer {
  final Map<String, dynamic> data;
  const TicketTransfer(this.data);

  int get id => integer(data['id']);
  int get ticketId => integer(data['ticket_id']);
  int get eventId => integer(data['event_id']);
  String get title => string(data['event_title'], 'Entrada');
  String get status => string(data['status'], 'unknown');
  String get recipientEmail => string(data['recipient_email']);
  String get requestId => string(data['request_id']);
  DateTime? get expiresAt => DateTime.tryParse(string(data['expires_at']));
  DateTime? get createdAt => DateTime.tryParse(string(data['created_at']));
  bool get pending => status == 'pending';
  bool get canAccept => pending && data['can_accept'] == true;
  bool get canReject => pending && data['can_reject'] == true;
  bool get canCancel => pending && data['can_cancel'] == true;
  String get unitLabel => integer(data['ticket_count']) > 1
      ? 'Entrada ${integer(data['ticket_index'])} de ${integer(data['ticket_count'])}'
      : 'Una entrada';
  String get label => switch (status) {
    'pending' => 'Pendiente de aceptación',
    'accepted' => 'Transferencia aceptada',
    'rejected' => 'Transferencia rechazada',
    'cancelled' => 'Transferencia cancelada',
    'expired' => 'Solicitud vencida',
    'invalidated' => 'Transferencia no disponible',
    _ => 'Estado por confirmar',
  };

  factory TicketTransfer.fromJson(Map<String, dynamic> data) {
    if (integer(data['id']) <= 0 ||
        integer(data['ticket_id']) <= 0 ||
        !{
          'pending',
          'accepted',
          'rejected',
          'cancelled',
          'expired',
          'invalidated',
        }.contains(data['status'])) {
      throw const FormatException('No se pudo comprobar la transferencia.');
    }
    return TicketTransfer(Map.unmodifiable(data));
  }
}

class TicketTransferCatalog {
  final List<TicketTransfer> incoming;
  final List<TicketTransfer> outgoing;
  const TicketTransferCatalog({required this.incoming, required this.outgoing});
  bool get hasPending =>
      incoming.any((item) => item.pending) ||
      outgoing.any((item) => item.pending);

  factory TicketTransferCatalog.fromJson(Map<String, dynamic> data) {
    List<TicketTransfer> parse(dynamic values) {
      if (values is! List || values.any((value) => value is! Map)) {
        throw const FormatException(
          'No se pudieron comprobar las solicitudes.',
        );
      }
      return List.unmodifiable(
        values.map(
          (value) => TicketTransfer.fromJson(Map<String, dynamic>.from(value)),
        ),
      );
    }

    return TicketTransferCatalog(
      incoming: parse(data['incoming']),
      outgoing: parse(data['outgoing']),
    );
  }
}
