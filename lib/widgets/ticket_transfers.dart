import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/event.dart';
import '../models/ticket_transfer.dart';
import '../services/api_service.dart';
import '../services/ticket_transfer_intents.dart';
import 'brand_style.dart';

String transferExpiry(DateTime? expiry) => expiry == null
    ? 'El plazo lo confirma el servidor.'
    : 'Vence el ${DateFormat('dd/MM · HH:mm').format(expiry.toLocal())}';

class TicketTransferRequests extends StatelessWidget {
  final TicketTransferCatalog catalog;
  final bool busy;
  final void Function(TicketTransfer, String) onAction;
  const TicketTransferRequests({
    super.key,
    required this.catalog,
    required this.busy,
    required this.onAction,
  });

  Widget _request(
    BuildContext context,
    TicketTransfer transfer,
    bool incoming,
  ) => Padding(
    key: ValueKey('transfer-request-${incoming ? 'in' : 'out'}-${transfer.id}'),
    padding: const EdgeInsets.only(top: 12),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: brandSurface,
        border: Border.all(color: brandMuted.withValues(alpha: .3)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(transfer.title, style: Theme.of(context).textTheme.titleLarge),
            Text(transfer.unitLabel),
            Text(
              transfer.label,
              style: const TextStyle(
                color: brandPink,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (!incoming && transfer.recipientEmail.isNotEmpty)
              Text('Para: ${transfer.recipientEmail}'),
            if (transfer.pending) Text(transferExpiry(transfer.expiresAt)),
            if (incoming)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'Al aceptar, la entrada pasa a tu cuenta y se habilita tu QR. Si hubo una compra, el comprobante sigue con el comprador original.',
                ),
              ),
            if (transfer.canAccept)
              FilledButton(
                key: ValueKey('transfer-accept-${transfer.id}'),
                onPressed: busy ? null : () => onAction(transfer, 'accept'),
                child: const Text(
                  'Aceptar entrada',
                  textAlign: TextAlign.center,
                ),
              ),
            if (transfer.canReject)
              OutlinedButton(
                key: ValueKey('transfer-reject-${transfer.id}'),
                onPressed: busy ? null : () => onAction(transfer, 'reject'),
                child: const Text(
                  'Rechazar solicitud',
                  textAlign: TextAlign.center,
                ),
              ),
            if (transfer.canCancel)
              OutlinedButton(
                key: ValueKey('transfer-cancel-${transfer.id}'),
                onPressed: busy ? null : () => onAction(transfer, 'cancel'),
                child: const Text(
                  'Cancelar transferencia',
                  textAlign: TextAlign.center,
                ),
              ),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (catalog.incoming.isNotEmpty) ...[
        Text(
          'Entradas para vos',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        for (final transfer in catalog.incoming)
          _request(context, transfer, true),
        const SizedBox(height: 16),
      ],
      if (catalog.outgoing.isNotEmpty) ...[
        Text(
          'Tus transferencias',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        for (final transfer in [
          ...catalog.outgoing.where((item) => item.pending),
          ...catalog.outgoing.where((item) => !item.pending).take(10),
        ])
          _request(context, transfer, false),
        const SizedBox(height: 16),
      ],
    ],
  );
}

class TicketTransferDialog extends StatefulWidget {
  final ApiService api;
  final AccessItem item;
  final VoidCallback onPossiblyChanged;
  const TicketTransferDialog({
    super.key,
    required this.api,
    required this.item,
    required this.onPossiblyChanged,
  });
  @override
  State<TicketTransferDialog> createState() => _TicketTransferDialogState();
}

class _TicketTransferDialogState extends State<TicketTransferDialog> {
  final _email = TextEditingController();
  final _form = GlobalKey<FormState>();
  late final _token = widget.api.session.token;
  TicketTransferIntent? _intent;
  bool _loading = true;
  bool _busy = false;
  bool _confirming = false;
  bool _unavailable = false;
  String? _message;
  bool get _validSession =>
      mounted &&
      widget.api.session.authenticated &&
      widget.api.session.token == _token;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final intent = await widget.api.transferIntents.pending(
        widget.item.ticketId,
      );
      if (!_validSession) return;
      setState(() {
        _intent = intent;
        _email.text = intent?.recipientEmail ?? '';
        if (intent != null) {
          _message =
              'Hay un envío cuyo resultado falta confirmar. Podés revisar las solicitudes o reintentar el mismo envío.';
        }
      });
    } catch (_) {
      if (_validSession) {
        setState(() {
          _unavailable = true;
          _message =
              'No pudimos recuperar el intento de transferencia. Volvé a abrir Entradas antes de continuar.';
        });
      }
    } finally {
      if (_validSession) setState(() => _loading = false);
    }
  }

  void _review() {
    if (_busy || !_validSession || _form.currentState?.validate() != true) {
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _confirming = true;
      _message = null;
    });
  }

  Future<void> _send() async {
    if (_busy || !_validSession) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      _intent ??= await widget.api.transferIntents.begin(
        widget.item.ticketId,
        _email.text.trim().toLowerCase(),
      );
      if (!_validSession) return;
      final transfer = await widget.api.createTicketTransfer(
        widget.item.ticketId,
        _email.text,
        existingIntent: _intent,
      );
      if (widget.api.session.authenticated &&
          widget.api.session.token == _token) {
        widget.onPossiblyChanged();
      }
      if (!mounted || !_validSession) return;
      Navigator.of(context).pop(transfer);
    } catch (error) {
      if (widget.api.session.authenticated &&
          widget.api.session.token == _token) {
        widget.onPossiblyChanged();
      }
      if (!_validSession) return;
      final definite =
          error is ApiException &&
          error.statusCode >= 400 &&
          error.statusCode < 500 &&
          error.statusCode != 409;
      setState(() {
        if (definite) {
          _intent = null;
          _confirming = false;
        }
        _message = error is ApiException
            ? '${error.message}${definite ? '' : ' Actualizá las solicitudes o reintentá este mismo envío; no se creará otro por repetirlo.'}'
            : 'No pudimos confirmar la solicitud. Actualizá las solicitudes o reintentá este mismo envío.';
      });
    } finally {
      if (_validSession) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
    scrollable: true,
    title: Text(_confirming ? 'Revisá la transferencia' : 'Transferir entrada'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(widget.item.title, style: Theme.of(context).textTheme.titleLarge),
        Text(
          integer(widget.item.data['ticket_count']) > 1
              ? 'Entrada ${integer(widget.item.data['ticket_index'])} de ${integer(widget.item.data['ticket_count'])}'
              : 'Una entrada',
        ),
        const SizedBox(height: 12),
        if (_loading)
          const LinearProgressIndicator()
        else if (!_confirming)
          Form(
            key: _form,
            child: TextFormField(
              key: const ValueKey('transfer-recipient-email'),
              controller: _email,
              enabled: !_busy && !_unavailable && _intent == null,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.done,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Correo del destinatario',
                errorMaxLines: 4,
              ),
              validator: (value) {
                final email = value?.trim().toLowerCase() ?? '';
                if (email.length > 254 ||
                    !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email)) {
                  return 'Ingresá un correo válido.';
                }
                if (email == widget.api.session.email.trim().toLowerCase()) {
                  return 'Ingresá el correo de otra persona.';
                }
                return null;
              },
              onFieldSubmitted: (_) => _review(),
            ),
          )
        else
          Text(
            'Para: ${_email.text.trim().toLowerCase()}',
            key: const ValueKey('transfer-reviewed-email'),
          ),
        const SizedBox(height: 12),
        const Text(
          'La solicitud aparecerá en Entradas cuando ingrese con ese correo confirmado.',
        ),
        const SizedBox(height: 10),
        const Text(
          'Conservás la entrada y su QR hasta que la otra persona acepte. Mientras esté pendiente podés cancelar. Al aceptar, tu QR deja de servir y la entrada pasa a su cuenta.',
        ),
        const SizedBox(height: 10),
        const Text(
          'Sin comisión. Vence a las 48 horas o al comenzar el evento, lo que ocurra primero. El historial se conserva; si hubo una compra, también su comprobante.',
        ),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Semantics(liveRegion: true, child: Text(_message!)),
          ),
        const SizedBox(height: 14),
        if (!_loading && !_unavailable)
          FilledButton(
            key: ValueKey(
              _confirming ? 'transfer-confirm-send' : 'transfer-review',
            ),
            onPressed: _busy
                ? null
                : _confirming
                ? _send
                : _review,
            child: Text(
              _busy
                  ? 'Confirmando solicitud…'
                  : _confirming
                  ? _intent != null
                        ? 'Reintentar el mismo envío'
                        : 'Confirmar transferencia'
                  : 'Continuar',
              textAlign: TextAlign.center,
            ),
          ),
        if (_confirming && _intent == null)
          TextButton(
            onPressed: _busy ? null : () => setState(() => _confirming = false),
            child: const Text('Corregir correo'),
          ),
      ],
    ),
    actions: [
      TextButton(
        key: const ValueKey('transfer-dialog-close'),
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cerrar'),
      ),
    ],
  );
}
