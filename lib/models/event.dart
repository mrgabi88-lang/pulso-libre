import '../services/api_config.dart';

int integer(dynamic value, [int fallback = 0]) =>
    int.tryParse('$value') ?? fallback;
String string(dynamic value, [String fallback = '']) =>
    value?.toString() ?? fallback;

class EventTrack {
  final String id;
  final String title;
  final String kind;
  final Uri url;
  const EventTrack({
    required this.id,
    required this.title,
    required this.kind,
    required this.url,
  });
}

class PulsoEvent {
  final Map<String, dynamic> data;
  final Uri? background;
  final List<Uri> flyers;
  final List<EventTrack> tracks;
  const PulsoEvent._(this.data, this.background, this.flyers, this.tracks);
  int get id => integer(data['id']);
  String get title => string(data['title'], 'Evento');
  String get description => string(data['description']);
  String get location => string(data['location']);
  // Presentation uses the event's declared civil time, independent of the
  // tablet timezone. Eligibility and chronological ordering belong to server.
  DateTime? get date => DateTime.tryParse(
    string(
      data['date_event'],
    ).replaceFirst(' ', 'T').replaceFirst(RegExp(r'(Z|[+-]\d{2}:?\d{2})$'), ''),
  );
  int? get _declaredPrice {
    final value = num.tryParse(string(data['price_from']));
    return value != null && value.isFinite && value >= 0 && value % 1 == 0
        ? value.toInt()
        : null;
  }

  int get price => _declaredPrice ?? 0;
  // An absent/invalid price or mode must never turn an event into a free one.
  String? get saleMode =>
      {'receipt_manual', 'free', 'open', 'none'}.contains(data['sale_mode'])
      ? data['sale_mode'] as String
      : null;
  bool get isFreeReservation => saleMode == 'free' && _declaredPrice == 0;
  bool get isOpenEntry => saleMode == 'open' && _declaredPrice == 0;
  bool get isPaid => saleMode == 'receipt_manual' && (_declaredPrice ?? 0) > 0;
  bool get canReserve => isFreeReservation || isPaid;
  String admissionLabel(String formattedPrice) => isFreeReservation
      ? 'Gratis'
      : isOpenEntry
      ? 'Entrada libre'
      : isPaid
      ? 'Desde \$$formattedPrice'
      : saleMode == 'none'
      ? 'Difusión'
      : 'Consultar acceso';
  String get bookingLabel => isFreeReservation
      ? 'Solicitar entrada gratis'
      : isPaid
      ? 'Comprar entradas'
      : 'Ver detalles';
  String get accessDescription => isOpenEntry
      ? 'Entrada libre. No necesitás reservar, pagar ni generar un QR desde la app.'
      : saleMode == 'none'
      ? 'Este evento es de difusión. No ofrece entradas desde la app.'
      : 'La modalidad de acceso no está disponible. Consultá al organizador.';
  int? get stock =>
      data.containsKey('stock_available') && data['stock_available'] == null
      ? null
      : integer(data['stock_available']);
  int get maxPerUser => integer(data['max_per_user'], 4).clamp(1, 100);

  factory PulsoEvent.fromJson(Map<String, dynamic> json, ApiConfig config) {
    final images = <Uri>[];
    final rawFlyers = json['flyer_urls'];
    if (rawFlyers is List) {
      for (final raw in rawFlyers.take(10)) {
        final uri = config.mediaUri(raw is String ? raw : null);
        if (uri != null && !images.contains(uri)) images.add(uri);
      }
    }
    if (images.isEmpty) {
      final image = config.mediaUri(string(json['image_url']));
      if (image != null) images.add(image);
    }
    final tracks = <EventTrack>[];
    if (json['tracks'] is List) {
      for (final raw in (json['tracks'] as List).take(3)) {
        if (raw is! Map) continue;
        final kind = string(raw['kind']);
        if (!{'upload', 'external'}.contains(kind)) continue;
        final uri = config.mediaUri(
          string(raw['url']),
          external: kind == 'external',
        );
        if (uri == null) continue;
        tracks.add(
          EventTrack(
            id: string(raw['id'], '${tracks.length}'),
            title: string(raw['title'], 'Audio ${tracks.length + 1}'),
            kind: kind,
            url: uri,
          ),
        );
      }
    }
    return PulsoEvent._(
      Map.unmodifiable(json),
      config.mediaUri(string(json['background_url'])),
      List.unmodifiable(images),
      List.unmodifiable(tracks),
    );
  }
}

class EventCatalog {
  final List<PulsoEvent> events;
  final List<PulsoEvent> upcoming;
  final int? featuredId;
  const EventCatalog({
    required this.events,
    required this.upcoming,
    this.featuredId,
  });
  PulsoEvent? get featured {
    for (final event in upcoming) {
      if (event.id == featuredId) return event;
    }
    return upcoming.isEmpty ? null : upcoming.first;
  }

  PulsoEvent? byId(int id) {
    for (final event in events) {
      if (event.id == id) return event;
    }
    return null;
  }

  factory EventCatalog.fromJson(Map<String, dynamic> json, ApiConfig config) {
    List<PulsoEvent> parse(dynamic raw) => raw is! List
        ? []
        : raw
              .whereType<Map>()
              .where((e) => e['status'] == 'active')
              .map(
                (e) =>
                    PulsoEvent.fromJson(Map<String, dynamic>.from(e), config),
              )
              .where((e) => e.id > 0)
              .toList();
    // The server owns eligibility/ranking. Never substitute all active events
    // for the explicit upcoming list or rank by the device clock.
    return EventCatalog(
      events: parse(json['items']),
      upcoming: parse(json['upcoming_events']),
      featuredId: int.tryParse('${json['featured_event_id']}'),
    );
  }
}

class AccessItem {
  final Map<String, dynamic> data;
  const AccessItem(this.data);
  int get orderId => integer(data['order_id'] ?? data['id']);
  int get eventId => integer(data['event_id']);
  int get ticketId => integer(data['ticket_id']);
  int get qty => integer(data['ticket_qty'], 1);
  String get title => string(data['event_title'], 'Entrada');
  String get status => string(data['status'], 'unknown');
  bool get receivedTransfer => data['received_transfer'] == true;
  bool get isFreeReservation => data['sale_mode'] == 'free';
  bool get awaitingFreeApproval =>
      isFreeReservation &&
      {'pending_approval', 'pending_receipt', 'in_review'}.contains(status);
  int get qrVersion => integer(data['qr_version']);
  int? get pendingTransferId => integer(data['pending_transfer_id']) > 0
      ? integer(data['pending_transfer_id'])
      : null;
  bool get canTransfer => data['can_transfer'] == true && qrEnabled;
  bool get used => status == 'used' || string(data['used_at']).isNotEmpty;
  bool get qrEnabled =>
      ticketId > 0 &&
      data['qr_enabled'] != false &&
      !used &&
      {'active', 'approved', 'valid', 'habilitado'}.contains(status);
  bool get canUpload =>
      data['item_type'] == 'order' &&
      !receivedTransfer &&
      !isFreeReservation &&
      data['can_upload_receipt'] != false &&
      {null, '', 'transfer_receipt'}.contains(data['payment_method']) &&
      data['requires_receipt'] != false &&
      !{'open', 'none'}.contains(data['sale_mode']) &&
      orderId > 0 &&
      {'pending_receipt', 'rejected'}.contains(status);
  String get label => used
      ? 'Acceso utilizado'
      : isFreeReservation &&
            data['item_type'] == 'order' &&
            status == 'approved'
      ? 'Reserva confirmada'
      : awaitingFreeApproval
      ? 'Pendiente de aprobación'
      : isFreeReservation && status == 'rejected'
      ? 'Solicitud rechazada'
      : switch (status) {
          'pending_receipt' => 'Falta el comprobante',
          'in_review' => 'Comprobante en revisión',
          'rejected' => 'Comprobante rechazado',
          'pending_payment' => 'Pago pendiente',
          'payment_rejected' => 'Pago rechazado',
          'payment_cancelled' => 'Pago cancelado',
          'payment_expired' => 'Pago vencido',
          'payment_review' => 'Pago en revisión',
          'refunded' => 'Pago devuelto',
          'charged_back' => 'Pago con contracargo',
          'partially_refunded' => 'Devolución parcial en revisión',
          'active' ||
          'approved' ||
          'valid' ||
          'habilitado' => 'Entrada habilitada',
          'revoked' || 'cancelled' => 'Entrada cancelada',
          'transferred' => 'Entrada transferida',
          _ => 'Estado por confirmar',
        };
  String get explanation =>
      isFreeReservation &&
          !used &&
          !receivedTransfer &&
          status == 'approved' &&
          data['item_type'] == 'order'
      ? 'Tus entradas ya están disponibles. Abrí Mis entradas para mostrar el QR vigente al ingresar.'
      : awaitingFreeApproval
      ? 'El organizador debe aprobar tu solicitud. El QR se habilitará cuando la apruebe. No requiere pago ni comprobante.'
      : isFreeReservation && status == 'rejected'
      ? 'El organizador rechazó tu solicitud. No se generó una entrada ni un QR.${string(data['review_notes']).trim().isEmpty ? '' : ' Motivo: ${string(data['review_notes']).trim()}'}'
      : switch (status) {
          'pending_payment' =>
            'Esta orden anterior sigue pendiente. Consultá al organizador para resolverla; no vuelvas a pagar sin confirmar su estado.',
          'payment_rejected' =>
            'El intento de pago anterior fue rechazado. Consultá al organizador para resolver esta orden.',
          'payment_cancelled' =>
            'El pago fue cancelado. Esta orden no habilita una entrada.',
          'payment_expired' =>
            'Venció el plazo del pago. Esta orden no habilita una entrada.',
          'payment_review' =>
            'El pago necesita revisión. El QR seguirá bloqueado hasta que se resuelva. Consultá al organizador.',
          'refunded' || 'charged_back' || 'partially_refunded' =>
            'Esta entrada no está habilitada. Consultá al organizador por el estado del pago.',
          'transferred' =>
            'Esta entrada ya tiene otro titular. Su historial se conserva, pero su QR dejó de estar disponible para vos.',
          'pending_receipt' =>
            'Tu orden está creada. Subí el comprobante para enviarla a revisión.',
          'in_review' =>
            'El organizador recibió tu comprobante y está revisando el pago.',
          'rejected' => string(
            data['review_notes'],
            'Revisá el comprobante y enviá uno nuevo.',
          ),
          _ =>
            used
                ? 'Esta entrada ya fue validada en puerta.'
                : receivedTransfer
                ? 'Recibiste esta entrada y sos su titular. Si hubo una compra, el comprobante sigue con el comprador original.'
                : '',
        };
}
