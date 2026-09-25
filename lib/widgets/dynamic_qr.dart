import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../services/api_service.dart';
import '../services/qr_controller.dart';

class DynamicTicketQrPanel extends StatefulWidget {
  final ApiService api;
  final int ticketId;
  final MonotonicClock? clock;
  const DynamicTicketQrPanel({
    super.key,
    required this.api,
    required this.ticketId,
    this.clock,
  });
  @override
  State<DynamicTicketQrPanel> createState() => _DynamicTicketQrPanelState();
}

class _DynamicTicketQrPanelState extends State<DynamicTicketQrPanel>
    with WidgetsBindingObserver {
  late QrController controller;
  void _create() {
    final id = widget.ticketId;
    controller = QrController(
      fetch: () => widget.api.fetchTicketQr(id),
      ticketId: id,
      clock: widget.clock,
    )..start();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _create();
  }

  @override
  void didUpdateWidget(covariant DynamicTicketQrPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ticketId != widget.ticketId || oldWidget.api != widget.api) {
      controller.dispose();
      _create();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      controller.conceal();
    }
    if (state == AppLifecycleState.resumed) controller.refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (_, _) {
      final payload = controller.payload;
      return Column(
        children: [
          if (payload.isNotEmpty) ...[
            LayoutBuilder(
              builder: (context, bounds) {
                final size = (bounds.maxWidth - 24).clamp(0.0, 218.0);
                return Center(
                  child: ColoredBox(
                    color: Colors.white,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: QrImageView(
                        data: payload,
                        size: size,
                        backgroundColor: Colors.white,
                      ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 10),
            Text('Se renueva en ${controller.remaining}s'),
            const Text('Mostrá este QR actualizado al ingresar.'),
          ] else ...[
            const Icon(Icons.qr_code_2, size: 48),
            Text(
              controller.busy
                  ? 'Solicitando un QR vigente…'
                  : 'QR no disponible',
            ),
          ],
          if (controller.busy)
            const Padding(
              padding: EdgeInsets.all(10),
              child: LinearProgressIndicator(),
            ),
          if (controller.error != null)
            Text(
              controller.error!,
              style: const TextStyle(color: Colors.orangeAccent),
            ),
          OutlinedButton.icon(
            onPressed: controller.canRetry ? controller.refresh : null,
            icon: const Icon(Icons.refresh),
            label: Text(
              controller.retryIn > 0
                  ? 'Reintentar en ${controller.retryIn}s'
                  : 'Actualizar QR',
            ),
          ),
        ],
      );
    },
  );
}
