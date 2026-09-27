import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/event.dart';
import '../models/ticket_transfer.dart';
import 'api_config.dart';
import 'session_store.dart';
import 'ticket_transfer_intents.dart';

class ApiException implements Exception {
  final String message;
  final String? code;
  final bool verificationRequired;
  final int? retryAfter;
  final int statusCode;
  const ApiException(
    this.message, {
    this.code,
    this.verificationRequired = false,
    this.retryAfter,
    this.statusCode = 0,
  });
  @override
  String toString() => message;
}

class ApiService {
  final ApiConfig config;
  final SessionStore session;
  final http.Client client;
  late final transferIntents = TicketTransferIntents(session);
  ApiService({required this.config, required this.session, http.Client? client})
    : client = client ?? http.Client();

  Future<Map<String, String>> _headers(bool auth) async {
    final headers = <String, String>{
      'Accept': 'application/json',
      'Cache-Control': 'no-cache',
    };
    if (auth) {
      if (session.token == null) {
        throw const ApiException(
          'Ingresá para continuar.',
          code: 'UNAUTHENTICATED',
          statusCode: 401,
        );
      }
      headers['Authorization'] = 'Bearer ${session.token}';
    }
    return headers;
  }

  Future<Map<String, dynamic>> _decode(
    http.Response response,
    bool auth,
    String? requestToken,
  ) async {
    if (auth && session.token != requestToken) {
      throw const ApiException('La sesión cambió. Volvé a intentar.');
    }
    Map<String, dynamic> data;
    try {
      final value = jsonDecode(response.body);
      if (value is! Map) throw const FormatException();
      data = Map<String, dynamic>.from(value);
    } catch (_) {
      if (auth && response.statusCode == 401) await session.clear();
      throw ApiException(
        'El servidor no respondió correctamente. Intentá nuevamente.',
        statusCode: response.statusCode,
      );
    }
    if (auth && response.statusCode == 401) await session.clear();
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        data['ok'] != true) {
      final retry = integer(
        data['retry_after'] ?? response.headers['retry-after'],
      );
      throw ApiException(
        string(
          data['error'] ?? data['message'],
          'No se pudo completar la operación.',
        ),
        statusCode: response.statusCode,
        code: data['code']?.toString(),
        verificationRequired: data['verification_required'] == true,
        retryAfter: retry > 0 ? retry : null,
      );
    }
    return data;
  }

  Future<Map<String, dynamic>> request(
    String endpoint, {
    bool auth = false,
    String method = 'GET',
    Map<String, String>? query,
    Map<String, dynamic>? body,
  }) async {
    final req = http.Request(method, config.endpoint(endpoint, query))
      ..followRedirects = false;
    req.headers.addAll(await _headers(auth));
    final requestToken = auth
        ? req.headers['Authorization']?.substring(7)
        : null;
    if (body != null) {
      req.headers['Content-Type'] = 'application/json; charset=utf-8';
      req.body = jsonEncode(body);
    }
    try {
      final streamed = await client
          .send(req)
          .timeout(const Duration(seconds: 15));
      final response = await http.Response.fromStream(
        streamed,
      ).timeout(const Duration(seconds: 15));
      return await _decode(response, auth, requestToken);
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw const ApiException(
        'La conexión tardó demasiado. Intentá nuevamente.',
      );
    } on http.ClientException {
      throw const ApiException('No pudimos conectar con el servidor.');
    }
  }

  Future<void> restoreSession({bool unlock = false}) async {
    await session.load();
    if (!session.hasCredential) return;
    final validatingToken = session.token;
    final result = await request('me.php', auth: true);
    if (session.token != validatingToken) return;
    final user = result['user'];
    if (user is! Map) {
      await session.clear();
      throw const ApiException('No se pudo validar tu sesión.');
    }
    try {
      session.acceptValidatedUser(
        Map<String, dynamic>.from(user),
        unlock: unlock,
      );
    } catch (_) {
      await session.clear();
      rethrow;
    }
  }

  Future<void> login(String email, String password) async {
    final result = await request(
      'login.php',
      method: 'POST',
      body: {'email': email, 'password': password},
    );
    final user = result['user'];
    if (user is Map && user['email_verified'] != true) {
      throw const ApiException(
        'Confirmá tu correo antes de ingresar.',
        verificationRequired: true,
        code: 'EMAIL_VERIFICATION_REQUIRED',
      );
    }
    await session.acceptLogin(result);
  }

  Future<void> logout() async {
    final revokingToken = session.token;
    if (!session.hasCredential) {
      await session.clear();
      return;
    }
    try {
      await request('logout.php', auth: true, method: 'POST', body: {});
    } on ApiException catch (e) {
      if (e.statusCode != 401) rethrow;
    }
    if (session.token == revokingToken) await session.clear();
  }

  Future<Map<String, dynamic>> register(
    String name,
    String email,
    String password,
  ) => request(
    'register.php',
    method: 'POST',
    body: {'name': name, 'email': email, 'password': password},
  );
  Future<Map<String, dynamic>> resend(String email) => request(
    'resend_verification.php',
    method: 'POST',
    body: {'email': email, 'kind': 'buyer'},
  );
  Future<Map<String, dynamic>> requestPasswordReset(String email) => request(
    'forgot_password.php',
    method: 'POST',
    body: {'email': email.trim()},
  );
  Future<EventCatalog> fetchEvents() async =>
      EventCatalog.fromJson(await request('events.php'), config);
  Future<Map<String, dynamic>> createPurchase(int eventId, int qty) async {
    final buyerToken = session.token;
    final requestId = await session.beginPurchaseIntent(eventId, qty);
    if (session.token != buyerToken) {
      throw const ApiException('La sesión cambió. Volvé a intentar.');
    }
    final response = await request(
      'purchase_create.php',
      auth: true,
      method: 'POST',
      body: {'event_id': eventId, 'ticket_qty': qty, 'request_id': requestId},
    );
    if (response['order'] is! Map) {
      throw const ApiException('La orden recibida no es válida.');
    }
    final order = Map<String, dynamic>.from(response['order']);
    if (integer(order['id']) <= 0 ||
        integer(order['event_id']) != eventId ||
        integer(order['ticket_qty']) != qty) {
      throw const ApiException(
        'No se pudo comprobar la orden. Podés reintentar el mismo intento.',
      );
    }
    await session.completePurchaseIntent(eventId, qty, requestId);
    return order;
  }

  Map<String, dynamic> _orderFromResponse(Map<String, dynamic> result, int id) {
    final raw = result['order'];
    if (raw is! Map ||
        integer(raw['id']) != id ||
        !{
          'pending_approval',
          'pending_receipt',
          'in_review',
          'rejected',
          'approved',
          'cancelled',
          'pending_payment',
          'payment_rejected',
          'payment_cancelled',
          'payment_expired',
          'payment_review',
          'refunded',
          'charged_back',
          'partially_refunded',
        }.contains(raw['status'])) {
      throw const ApiException('No se pudo comprobar el estado de la orden.');
    }
    return Map<String, dynamic>.from(raw);
  }

  Future<Map<String, dynamic>> getPurchase(int orderId) async =>
      _orderFromResponse(
        await request(
          'purchase_get.php',
          auth: true,
          query: {'order_id': '$orderId'},
        ),
        orderId,
      );

  Future<Map<String, dynamic>> uploadReceipt(
    int orderId,
    String filePath,
  ) async {
    final req = http.MultipartRequest(
      'POST',
      config.endpoint('purchase_upload_receipt.php'),
    )..followRedirects = false;
    req.headers.addAll(await _headers(true));
    final requestToken = req.headers['Authorization']?.substring(7);
    req.fields['order_id'] = '$orderId';
    req.files.add(await http.MultipartFile.fromPath('receipt', filePath));
    try {
      final response = await http.Response.fromStream(
        await client.send(req).timeout(const Duration(seconds: 30)),
      ).timeout(const Duration(seconds: 30));
      final result = await _decode(response, true, requestToken);
      _orderFromResponse(result, orderId);
      return result;
    } on TimeoutException {
      throw const ApiException(
        'La carga tardó demasiado. Podés reintentar esta misma orden.',
      );
    } on http.ClientException {
      throw const ApiException(
        'No pudimos subir el comprobante. Podés reintentar esta misma orden.',
      );
    }
  }

  Future<List<AccessItem>> fetchMyTickets() async {
    final response = await request('my_tickets.php', auth: true);
    if (response['items'] is! List) {
      throw const ApiException('No se pudieron leer tus entradas.');
    }
    return (response['items'] as List)
        .whereType<Map>()
        .map((e) => AccessItem(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<Map<String, dynamic>> fetchTicketQr(int ticketId) =>
      request('ticket_qr.php', auth: true, query: {'ticket_id': '$ticketId'});

  Future<TicketTransferCatalog> fetchTicketTransfers() async {
    if (!session.authenticated) {
      throw const ApiException('Ingresá para continuar.');
    }
    final account = transferIntents.owner;
    final token = session.token;
    final result = await request('ticket_transfers.php', auth: true);
    try {
      final catalog = TicketTransferCatalog.fromJson(result);
      await transferIntents.reconcile(account, catalog.outgoing);
      if (!session.authenticated || session.token != token) {
        throw const ApiException('La sesión cambió. Volvé a intentar.');
      }
      return catalog;
    } on FormatException catch (error) {
      throw ApiException(error.message);
    }
  }

  Future<TicketTransfer> createTicketTransfer(
    int ticketId,
    String email, {
    TicketTransferIntent? existingIntent,
  }) async {
    final token = session.token;
    final normalized = email.trim().toLowerCase();
    TicketTransferIntent intent;
    try {
      intent =
          existingIntent ?? await transferIntents.begin(ticketId, normalized);
    } on FormatException catch (error) {
      throw ApiException(error.message);
    } on StateError catch (error) {
      throw ApiException(error.message);
    }
    if (!session.authenticated ||
        session.token != token ||
        intent.owner != transferIntents.owner ||
        intent.ticketId != ticketId ||
        intent.recipientEmail != normalized) {
      throw const ApiException(
        'La sesión cambió o el intento no coincide. Volvé a intentar.',
      );
    }
    try {
      final result = await request(
        'ticket_transfer_create.php',
        auth: true,
        method: 'POST',
        body: {
          'ticket_id': ticketId,
          'recipient_email': normalized,
          'request_id': intent.requestId,
        },
      );
      final raw = result['transfer'];
      if (raw is! Map) {
        throw const ApiException(
          'No se pudo confirmar la transferencia. Actualizá las solicitudes y reintentá el mismo intento.',
        );
      }
      final transfer = TicketTransfer.fromJson(Map<String, dynamic>.from(raw));
      if (transfer.ticketId != ticketId ||
          transfer.requestId != intent.requestId ||
          transfer.recipientEmail != normalized) {
        throw const ApiException(
          'No se pudo confirmar la transferencia. Actualizá las solicitudes y reintentá el mismo intento.',
        );
      }
      await transferIntents.complete(intent);
      return transfer;
    } on ApiException catch (error) {
      if (error.statusCode >= 400 &&
          error.statusCode < 500 &&
          error.statusCode != 409) {
        await transferIntents.complete(intent);
      }
      rethrow;
    } on FormatException catch (error) {
      throw ApiException(error.message);
    }
  }

  Future<TicketTransfer> actOnTicketTransfer(
    int transferId,
    String action,
  ) async {
    if (!session.authenticated) {
      throw const ApiException('Ingresá para continuar.');
    }
    if (!{'accept', 'reject', 'cancel'}.contains(action)) {
      throw const ApiException('La acción no está disponible.');
    }
    final result = await request(
      'ticket_transfer_action.php',
      auth: true,
      method: 'POST',
      body: {'transfer_id': transferId, 'action': action},
    );
    try {
      final raw = result['transfer'];
      if (raw is! Map) {
        throw const FormatException(
          'No se pudo comprobar el resultado. Actualizá las solicitudes.',
        );
      }
      final transfer = TicketTransfer.fromJson(Map<String, dynamic>.from(raw));
      if (transfer.id != transferId) {
        throw const FormatException(
          'No se pudo comprobar el resultado. Actualizá las solicitudes.',
        );
      }
      final expectedStatus = {
        'accept': 'accepted',
        'reject': 'rejected',
        'cancel': 'cancelled',
      }[action];
      if (transfer.status != expectedStatus) {
        throw const FormatException(
          'La solicitud cambió de estado. Actualizá tus entradas para comprobar el resultado.',
        );
      }
      return transfer;
    } on FormatException catch (error) {
      throw ApiException(error.message);
    }
  }
}
