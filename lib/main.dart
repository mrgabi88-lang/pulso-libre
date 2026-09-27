import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:local_auth/local_auth.dart';
import 'models/event.dart';
import 'models/ticket_transfer.dart';
import 'services/api_config.dart';
import 'services/api_service.dart';
import 'services/session_store.dart';
import 'widgets/dynamic_qr.dart';
import 'widgets/event_media.dart';
import 'widgets/brand_style.dart';
import 'widgets/event_scene.dart';
import 'widgets/home_event_carousel.dart';
import 'widgets/global_navigation.dart';
import 'widgets/account_privacy_links.dart';
import 'widgets/password_recovery.dart';
import 'widgets/ticket_transfers.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    runApp(
      PulsoLibreApp(
        api: ApiService(
          config: ApiConfig.environment(),
          session: SessionStore(),
        ),
      ),
    );
  } catch (_) {
    runApp(
      const MaterialApp(
        home: Scaffold(
          body: SafeArea(
            child: Center(
              child: Text(
                'La versión de pruebas necesita la configuración local.',
              ),
            ),
          ),
        ),
      ),
    );
  }
}

const violet = brandPink;
const muted = brandMuted;
const cardColor = brandSurface;
String money(int value) => NumberFormat.decimalPattern('es_AR').format(value);
String dateLabel(DateTime? date) => date == null
    ? 'Fecha a confirmar'
    : DateFormat('dd/MM · HH:mm').format(date);

class PulsoLibreApp extends StatelessWidget {
  final ApiService api;
  final Future<String?> Function()? receiptPicker;
  final Future<bool> Function()? biometric;
  final EventImageBuilder imageBuilder;
  final AudioPlayback Function()? audioFactory;
  final Future<bool> Function(Uri)? externalLauncher;
  const PulsoLibreApp({
    super.key,
    required this.api,
    this.receiptPicker,
    this.biometric,
    this.imageBuilder = networkEventImage,
    this.audioFactory,
    this.externalLauncher,
  });
  @override
  Widget build(BuildContext context) => buildApp(context);

  MaterialApp buildApp(BuildContext context) => MaterialApp(
    title: 'Pulso Libre',
    debugShowCheckedModeBanner: false,
    theme: pulsoTheme(),
    initialRoute: '/',
    home: PulsoRoot(
      api: api,
      receiptPicker: receiptPicker,
      biometric: biometric,
      imageBuilder: imageBuilder,
      audioFactory: audioFactory,
      externalLauncher: externalLauncher,
    ),
  );
}

class Panel extends StatelessWidget {
  final Widget child;
  const Panel({super.key, required this.child});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: cardColor.withValues(
        alpha: MediaQuery.sizeOf(context).width < 600 ? .84 : .72,
      ),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: Colors.white.withValues(alpha: .12)),
    ),
    child: child,
  );
}

class PulsoRoot extends StatefulWidget {
  final ApiService api;
  final Future<String?> Function()? receiptPicker;
  final Future<bool> Function()? biometric;
  final EventImageBuilder imageBuilder;
  final AudioPlayback Function()? audioFactory;
  final Future<bool> Function(Uri)? externalLauncher;
  const PulsoRoot({
    super.key,
    required this.api,
    this.receiptPicker,
    this.biometric,
    required this.imageBuilder,
    this.audioFactory,
    this.externalLauncher,
  });
  @override
  State<PulsoRoot> createState() => _PulsoRootState();
}

class _PulsoRootState extends State<PulsoRoot> with WidgetsBindingObserver {
  final _eventAudioControls = EventAudioControls();
  int _index = 0;
  int? _eventId;
  AccessItem? _resumeOrder;
  bool _booting = true;
  bool _unlocking = false;
  bool _pickingReceipt = false;
  bool _eventAutoplay = true;
  String? _sessionError;
  DateTime? _backPressed;
  late Future<EventCatalog> _catalog;
  SessionStore get session => widget.api.session;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    session.addListener(_sessionChanged);
    _catalog = widget.api.fetchEvents();
    _boot();
  }

  Future<void> _boot() async {
    try {
      await widget.api.restoreSession();
    } catch (_) {
      _sessionError =
          'No se pudo validar la sesión guardada. Volvé a intentar o ingresá con tu correo.';
    }
    if (!mounted) return;
    setState(() {
      _booting = false;
      if (session.pendingEmail.isNotEmpty || _sessionError != null) _index = 4;
    });
  }

  void _sessionChanged() {
    if (!mounted) return;
    setState(() {
      if (session.pendingEmail.isNotEmpty) _index = 4;
      if (!session.authenticated &&
          !session.hasCredential &&
          _resumeOrder != null) {
        _resumeOrder = null;
        _index = 4;
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _eventAutoplay = false;
    if (state == AppLifecycleState.paused && !_pickingReceipt) session.lock();
  }

  void _go(int value) => setState(() {
    if (_index == 2 && value != 2) _eventAutoplay = false;
    if (_index != 2 && value == 2) _eventAutoplay = true;
    _index = value;
    if (value == 0 || value == 1) _catalog = widget.api.fetchEvents();
  });
  void _buy(int id) => setState(() {
    _eventAutoplay = true;
    _eventId = id;
    _resumeOrder = null;
    _index = 2;
  });
  void _resume(AccessItem item) => setState(() {
    _eventAutoplay = true;
    _eventId = item.eventId;
    _resumeOrder = item;
    _index = 2;
  });
  void _refreshCatalog() => setState(() {
    _catalog = widget.api.fetchEvents();
  });
  Future<String?> _pickReceipt() async {
    _pickingReceipt = true;
    try {
      if (widget.receiptPicker != null) return await widget.receiptPicker!();
      return (await ImagePicker().pickImage(
        source: ImageSource.gallery,
        imageQuality: 90,
      ))?.path;
    } finally {
      _pickingReceipt = false;
    }
  }

  Future<void> _unlock() async {
    setState(() {
      _unlocking = true;
      _sessionError = null;
    });
    try {
      bool ok;
      if (widget.biometric != null) {
        ok = await widget.biometric!();
      } else {
        final auth = LocalAuthentication();
        if (!await auth.isDeviceSupported()) {
          throw StateError(
            'No hay un desbloqueo del dispositivo disponible. Ingresá con tu correo.',
          );
        }
        ok = await auth.authenticate(
          localizedReason: 'Desbloqueá Pulso Libre para ver tus entradas.',
          biometricOnly: false,
          persistAcrossBackgrounding: true,
        );
      }
      if (!ok) {
        throw StateError('No se completó el desbloqueo del dispositivo.');
      }
      await widget.api.restoreSession(unlock: true);
      if (mounted) _refreshCatalog();
    } catch (e) {
      _sessionError = e is ApiException
          ? e.message
          : 'No se pudo desbloquear. Podés ingresar con tu correo.';
    } finally {
      if (mounted) setState(() => _unlocking = false);
    }
  }

  Future<void> _usePassword() async {
    setState(() => _unlocking = true);
    try {
      await widget.api.logout();
      if (mounted) {
        setState(() {
          _index = 4;
          _sessionError = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _sessionError =
              'No pudimos cerrar la sesión anterior. Comprobá la conexión y reintentá.',
        );
      }
    } finally {
      if (mounted) setState(() => _unlocking = false);
    }
  }

  void _back() {
    if (_index != 0 && !session.locked) {
      _go(0);
      return;
    }
    final now = DateTime.now();
    if (_backPressed != null &&
        now.difference(_backPressed!) < const Duration(seconds: 2)) {
      SystemNavigator.pop();
      return;
    }
    _backPressed = now;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Tocá atrás otra vez para salir.')),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    session.removeListener(_sessionChanged);
    _eventAudioControls.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final names = ['Inicio', 'Eventos', 'Comprar', 'Entradas', 'Cuenta'];
    Widget body;
    if (_booting) {
      body = const Center(child: CircularProgressIndicator());
    } else if (session.locked) {
      body = ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Panel(
            child: Column(
              children: [
                const Icon(Icons.lock_outline_rounded, color: violet, size: 64),
                const Text(
                  'Pulso Libre bloqueado',
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Tus entradas quedan ocultas hasta validar tu identidad y tu sesión.',
                ),
                const SizedBox(height: 12),
                const Text(
                  'Usá el patrón, PIN, contraseña o biometría configurados en tu dispositivo.',
                  textAlign: TextAlign.center,
                ),
                if (_sessionError != null)
                  Text(
                    _sessionError!,
                    style: const TextStyle(color: Colors.orangeAccent),
                  ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  key: const ValueKey('unlock-device'),
                  onPressed: _unlocking ? null : _unlock,
                  icon: const Icon(Icons.lock_open_rounded),
                  label: Text(_unlocking ? 'Validando…' : 'Desbloquear'),
                ),
                OutlinedButton(
                  onPressed: _unlocking ? null : _usePassword,
                  child: const Text('Ingresar con correo y contraseña'),
                ),
                PasswordRecoveryButton(
                  api: widget.api,
                  initialEmail: () => '',
                  enabled: !_unlocking,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Panel(
            child: AccountPrivacyLinks(
              externalLauncher: widget.externalLauncher,
            ),
          ),
        ],
      );
    } else if (_index == 4) {
      body = AccountScreen(
        api: widget.api,
        externalLauncher: widget.externalLauncher,
        sessionError: _sessionError,
        onRetrySession: () async {
          setState(() => _booting = true);
          await _boot();
        },
        onLoggedIn: () => setState(() {
          _sessionError = null;
          _index = _eventId != null ? 2 : 3;
        }),
      );
    } else if (_index == 3) {
      body = TicketsScreen(
        key: ValueKey('tickets-${session.authenticated}'),
        api: widget.api,
        onAccount: () => _go(4),
        onResume: _resume,
      );
    } else {
      Widget catalogStatus(Widget child) => _index == 2
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(right: globalNavigationInset),
                child: child,
              ),
            )
          : child;
      body = FutureBuilder<EventCatalog>(
        future: _catalog,
        builder: (_, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return catalogStatus(
              const Center(child: CircularProgressIndicator()),
            );
          }
          if (snapshot.hasError) {
            return catalogStatus(
              Center(
                child: Panel(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('No se pudieron cargar los eventos.'),
                      OutlinedButton(
                        onPressed: _refreshCatalog,
                        child: const Text('Reintentar'),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }
          final catalog = snapshot.data!;
          if (_index == 2) {
            return BuyScreen(
              key: ValueKey('buy-$_eventId-${_resumeOrder?.orderId}'),
              api: widget.api,
              catalog: catalog,
              selectedEventId: _eventId,
              onSelectedEvent: _buy,
              onOrderChanged: (order) {
                _resumeOrder = AccessItem(order);
              },
              resumeOrder: _resumeOrder,
              onAccount: () => _go(4),
              onTickets: () => _go(3),
              onHome: () => _go(0),
              autoplay: _eventAutoplay,
              audioControls: _eventAudioControls,
              receiptPicker: _pickReceipt,
              imageBuilder: widget.imageBuilder,
              audioFactory: widget.audioFactory,
              externalLauncher: widget.externalLauncher,
              navigationInset: globalNavigationInset,
            );
          }
          if (_index == 1) {
            return EventsScreen(
              catalog: catalog,
              onBuy: _buy,
              imageBuilder: widget.imageBuilder,
            );
          }
          return HomeScreen(
            catalog: catalog,
            onBuy: _buy,
            imageBuilder: widget.imageBuilder,
          );
        },
      );
    }
    final showNavigation = !_booting && !session.locked;
    final screen = _index == 2 && showNavigation
        ? body
        : BrandBackdrop(
            child: SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  right: showNavigation ? globalNavigationInset : 0,
                ),
                child: Column(
                  children: [
                    BrandHeader(
                      compact:
                          _index == 0 &&
                          MediaQuery.sizeOf(context).height < 500,
                      section: session.locked ? 'Cuenta' : names[_index],
                      onHome: _index != 0 && !session.locked
                          ? () => _go(0)
                          : null,
                    ),
                    Expanded(
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: _index == 4 || session.locked
                                ? 620
                                : _index == 3
                                ? 900
                                : 1100,
                          ),
                          child: body,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        body: Stack(
          fit: StackFit.expand,
          children: [
            screen,
            if (showNavigation)
              GlobalNavigation(selectedIndex: _index, onNavigate: _go),
          ],
        ),
      ),
    );
  }
}

class HomeScreen extends StatelessWidget {
  final EventCatalog catalog;
  final ValueChanged<int> onBuy;
  final EventImageBuilder imageBuilder;
  const HomeScreen({
    super.key,
    required this.catalog,
    required this.onBuy,
    required this.imageBuilder,
  });
  @override
  Widget build(BuildContext context) {
    final featured = catalog.featured;
    final events = [
      ?featured,
      ...catalog.upcoming.where((event) => event.id != featured?.id),
    ];
    if (events.isEmpty) {
      return ListView(
        children: const [
          Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Pronto habrá nuevas fechas. Explorá los eventos publicados.',
            ),
          ),
        ],
      );
    }
    return HomeEventCarousel(
      events: events,
      featuredId: featured?.id,
      onOpen: onBuy,
      priceLabel: money,
      imageBuilder: imageBuilder,
    );
  }
}

class EventCard extends StatelessWidget {
  final PulsoEvent event;
  final bool featured;
  final ValueChanged<int> onBuy;
  final EventImageBuilder imageBuilder;
  const EventCard({
    super.key,
    required this.event,
    this.featured = false,
    required this.onBuy,
    required this.imageBuilder,
  });
  @override
  Widget build(BuildContext context) => Panel(
    child: LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 620;
        final details = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (featured) ...[
              const SectionEyebrow('PRÓXIMO DESTACADO'),
              const SizedBox(height: 12),
            ],
            Text(
              event.title,
              style: TextStyle(
                fontSize: featured ? 30 : 23,
                height: 1.15,
                fontWeight: FontWeight.w900,
                letterSpacing: -.5,
              ),
            ),
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.schedule_outlined, color: brandBlue, size: 18),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    dateLabel(event.date),
                    style: const TextStyle(color: muted),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 7),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.place_outlined, color: brandBlue, size: 18),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    event.location,
                    style: const TextStyle(color: muted),
                  ),
                ),
              ],
            ),
            if (event.description.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Text(event.description),
              ),
            const Divider(),
            Text(
              event.admissionLabel(money(event.price)),
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 14),
            FilledButton(
              key: ValueKey('buy-event-${event.id}'),
              onPressed: () => onBuy(event.id),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      event.isPaid ? 'Ir a compra' : event.bookingLabel,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Icon(Icons.arrow_forward, size: 18),
                ],
              ),
            ),
          ],
        );
        if (event.flyers.isEmpty) return details;
        final flyer = ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: ColoredBox(
            color: const Color(0xFF05060B),
            child: SizedBox(
              height: featured ? (wide ? 340 : 280) : (wide ? 240 : 180),
              width: double.infinity,
              child: imageBuilder(event.flyers.first, BoxFit.contain),
            ),
          ),
        );
        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(flex: featured ? 5 : 3, child: flyer),
              const SizedBox(width: 30),
              Expanded(flex: 5, child: details),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [flyer, const SizedBox(height: 22), details],
        );
      },
    ),
  );
}

class EventsScreen extends StatelessWidget {
  final EventCatalog catalog;
  final ValueChanged<int> onBuy;
  final EventImageBuilder imageBuilder;
  const EventsScreen({
    super.key,
    required this.catalog,
    required this.onBuy,
    required this.imageBuilder,
  });
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Text('Eventos', style: Theme.of(context).textTheme.headlineLarge),
      const SizedBox(height: 16),
      if (catalog.events.isEmpty)
        const Panel(child: Text('No hay eventos activos por ahora.')),
      for (final event in catalog.events)
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: EventCard(
            event: event,
            onBuy: onBuy,
            imageBuilder: imageBuilder,
          ),
        ),
    ],
  );
}

class BuyScreen extends StatefulWidget {
  final ApiService api;
  final EventCatalog catalog;
  final int? selectedEventId;
  final ValueChanged<int> onSelectedEvent;
  final ValueChanged<Map<String, dynamic>> onOrderChanged;
  final AccessItem? resumeOrder;
  final VoidCallback onAccount;
  final VoidCallback onTickets;
  final VoidCallback? onHome;
  final bool autoplay;
  final EventAudioControls? audioControls;
  final double navigationInset;
  final Future<String?> Function() receiptPicker;
  final EventImageBuilder imageBuilder;
  final AudioPlayback Function()? audioFactory;
  final Future<bool> Function(Uri)? externalLauncher;
  const BuyScreen({
    super.key,
    required this.api,
    required this.catalog,
    this.selectedEventId,
    required this.onSelectedEvent,
    required this.onOrderChanged,
    this.resumeOrder,
    required this.onAccount,
    required this.onTickets,
    this.onHome,
    this.autoplay = true,
    this.audioControls,
    this.navigationInset = 0,
    required this.receiptPicker,
    required this.imageBuilder,
    this.audioFactory,
    this.externalLauncher,
  });
  @override
  State<BuyScreen> createState() => _BuyScreenState();
}

class _BuyScreenState extends State<BuyScreen> {
  final _purchaseAnchor = GlobalKey();
  late final _audioControls = widget.audioControls ?? EventAudioControls();
  int? _selectedId;
  int _qty = 1;
  Map<String, dynamic>? _order;
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    if (widget.audioControls == null) {
      _audioControls.dispose();
    }
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _selectedId =
        widget.resumeOrder?.eventId ??
        widget.selectedEventId ??
        (widget.catalog.events.isEmpty ? null : widget.catalog.events.first.id);
    if (widget.resumeOrder != null) {
      _order = Map.from(widget.resumeOrder!.data)
        ..['id'] = widget.resumeOrder!.orderId;
      _qty = widget.resumeOrder!.qty;
      unawaited(_reloadOrder());
    }
  }

  void _acceptOrder(Map<String, dynamic> order) {
    final updated = {
      ..._order ?? <String, dynamic>{},
      ...order,
      'item_type': 'order',
      'order_id': order['id'],
      'event_title':
          widget.catalog.byId(integer(order['event_id']))?.title ??
          widget.resumeOrder?.title ??
          'Entrada',
    };
    setState(() => _order = updated);
    widget.onOrderChanged(updated);
  }

  Future<void> _reloadOrder() async {
    if (_busy || _order == null || !widget.api.session.authenticated) return;
    _busy = true;
    try {
      final order = await widget.api.getPurchase(integer(_order!['id']));
      if (mounted && widget.api.session.authenticated) {
        _acceptOrder(order);
        _error = null;
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() async {
    if (_busy || _order != null || _selectedId == null) return;
    final event = widget.catalog.byId(_selectedId!);
    if (event?.canReserve != true) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final order = await widget.api.createPurchase(_selectedId!, _qty);
      if (mounted && widget.api.session.authenticated) {
        _acceptOrder(order);
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _upload() async {
    if (_busy || _order == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final path = await widget.receiptPicker();
      if (path == null || !mounted) return;
      final result = await widget.api.uploadReceipt(
        integer(_order!['order_id'] ?? _order!['id']),
        path,
      );
      if (mounted) _acceptOrder(Map<String, dynamic>.from(result['order']));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
      try {
        final current = await widget.api.getPurchase(integer(_order!['id']));
        if (mounted) {
          _acceptOrder(current);
          if (current['status'] == 'in_review' ||
              current['status'] == 'approved') {
            setState(() => _error = null);
          }
        }
      } catch (_) {
        /* Keep the original error until the server can confirm. */
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final event = _selectedId == null
        ? null
        : widget.catalog.byId(_selectedId!);
    final access = _order == null
        ? null
        : AccessItem({
            ..._order!,
            'item_type': 'order',
            'order_id': _order!['order_id'] ?? _order!['id'],
          });
    final details = event == null
        ? const SizedBox.shrink()
        : EventSurface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  event.title,
                  key: const ValueKey('purchase-event-title'),
                  style: const TextStyle(
                    fontSize: 32,
                    height: 1.15,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -.5,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.schedule_outlined,
                      size: 20,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        dateLabel(event.date),
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.place_outlined,
                      size: 20,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        event.location,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  ],
                ),
                if (event.description.isNotEmpty) ...[
                  const SizedBox(height: 22),
                  Text(
                    event.description,
                    key: const ValueKey('event-description'),
                    style: const TextStyle(
                      fontSize: 17,
                      height: 1.55,
                      color: Colors.white,
                    ),
                  ),
                ],
                const SizedBox(height: 22),
                EventMedia(
                  key: ValueKey('media-${event.id}'),
                  event: event,
                  imageBuilder: widget.imageBuilder,
                  audioFactory: widget.audioFactory,
                  externalLauncher: widget.externalLauncher,
                  showFlyers: false,
                  autoplay: widget.autoplay,
                  audioControls: _audioControls,
                ),
              ],
            ),
          );
    final purchase = EventSurface(
      key: _purchaseAnchor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            access != null
                ? access.isFreeReservation
                      ? access.awaitingFreeApproval ||
                                access.status == 'rejected'
                            ? 'Tu solicitud'
                            : 'Tu reserva'
                      : 'Tu compra'
                : event?.canReserve == true
                ? 'Tus entradas para este evento'
                : 'Cómo asistir',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 18),
          if (!widget.api.session.authenticated &&
              (event?.canReserve == true || access != null)) ...[
            Text(
              event?.isFreeReservation == true
                  ? 'Ingresá para solicitar tus entradas gratis. El QR estará disponible después de la aprobación del organizador.'
                  : 'Ingresá para comprar entradas y enviar tu comprobante.',
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: () {
                if (_selectedId != null) widget.onSelectedEvent(_selectedId!);
                widget.onAccount();
              },
              icon: const Icon(Icons.person_outline),
              label: const Text('Ingresar o crear cuenta'),
            ),
            const SizedBox(height: 18),
          ],
          if (event == null && _order == null)
            const Text(
              'El evento seleccionado ya no está disponible. Volvé a Eventos.',
            ),
          if (event != null && _order == null) ...[
            DropdownButtonFormField<int>(
              key: const ValueKey('selected-event'),
              initialValue: _selectedId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Evento seleccionado',
              ),
              items: widget.catalog.events
                  .map(
                    (e) => DropdownMenuItem(
                      value: e.id,
                      child: Text(e.title, overflow: TextOverflow.ellipsis),
                    ),
                  )
                  .toList(),
              onChanged: _busy
                  ? null
                  : (id) {
                      if (id != null) widget.onSelectedEvent(id);
                      setState(() {
                        _selectedId = id;
                        _qty = 1;
                        _error = null;
                      });
                    },
            ),
            const SizedBox(height: 16),
            Text(
              event.canReserve
                  ? '${event.stock == null ? 'Cupo sin límite' : 'Cupo disponible: ${event.stock}'} · ${event.admissionLabel(money(event.price))}'
                  : event.accessDescription,
            ),
            if (event.isFreeReservation) ...[
              const SizedBox(height: 12),
              const Text(
                'Solicitá tu entrada gratis. El organizador debe aprobarla antes de que se habilite el QR. Sin pago ni comprobante.',
              ),
            ],
            if (widget.api.session.authenticated && event.canReserve) ...[
              const SizedBox(height: 18),
              DropdownButtonFormField<int>(
                key: const ValueKey('purchase-quantity'),
                initialValue: _qty,
                decoration: const InputDecoration(
                  labelText: 'Cantidad de entradas',
                ),
                items: List.generate(
                  event.maxPerUser,
                  (i) =>
                      DropdownMenuItem(value: i + 1, child: Text('${i + 1}')),
                ),
                onChanged: _busy
                    ? null
                    : (qty) => setState(() {
                        _qty = qty ?? 1;
                      }),
              ),
              const SizedBox(height: 18),
              Text(
                event.isFreeReservation
                    ? 'Total: Gratis'
                    : 'Total: \$${money(event.price * _qty)}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              FilledButton(
                key: const ValueKey('create-order'),
                onPressed: _busy || (event.stock != null && event.stock! < _qty)
                    ? null
                    : _create,
                child: Text(
                  _busy
                      ? 'Creando…'
                      : event.isFreeReservation
                      ? 'Enviar solicitud gratuita'
                      : 'Crear compra',
                ),
              ),
            ],
          ],
          if (access != null && widget.api.session.authenticated) ...[
            Text(
              'Orden ${access.orderId}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              access.label,
              key: const ValueKey('order-status'),
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(access.explanation),
            const SizedBox(height: 12),
            Text(
              '$_qty entrada${_qty == 1 ? '' : 's'} · ${access.isFreeReservation ? 'Gratis · Sin pago ni comprobante' : 'Total: \$${money(integer(_order!['amount_total']))}'}',
            ),
            const SizedBox(height: 18),
            if (access.canUpload) ...[
              PaymentInfo(data: _order!, fallback: event?.data),
              const SizedBox(height: 14),
              const Text(
                'El organizador recibirá la imagen completa para verificar tu '
                'pago. Adjuntá solo el comprobante de esta compra.',
                style: TextStyle(color: muted),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const ValueKey('upload-receipt'),
                onPressed: _busy ? null : _upload,
                icon: const Icon(Icons.upload_file),
                label: Text(
                  _busy
                      ? 'Cargando…'
                      : access.status == 'rejected'
                      ? 'Enviar nuevo comprobante'
                      : 'Subir comprobante',
                ),
              ),
              const SizedBox(height: 12),
            ],
            OutlinedButton(
              onPressed: _busy ? null : widget.onTickets,
              child: const Text('Ver mis entradas'),
            ),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                _error!,
                style: const TextStyle(color: Colors.orangeAccent),
              ),
            ),
        ],
      ),
    );
    return EventScene(
      event: event,
      contentPadding: EdgeInsets.only(right: widget.navigationInset),
      audioControls: _audioControls,
      imageBuilder: widget.imageBuilder,
      onHome:
          widget.onHome ??
          () {
            Navigator.of(context).maybePop();
          },
      purchaseLabel: access == null
          ? event?.bookingLabel ?? 'Ver detalles'
          : access.isFreeReservation
          ? access.awaitingFreeApproval || access.status == 'rejected'
                ? 'Ver solicitud'
                : 'Ver reserva'
          : 'Ver compra',
      onPurchase: () {
        final target = _purchaseAnchor.currentContext;
        if (target != null) {
          Scrollable.ensureVisible(
            target,
            alignment: 0,
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOutCubic,
          );
        }
      },
      child: SingleChildScrollView(
        key: const ValueKey('event-content-scroll'),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 36),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1200),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (event != null) ...[
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final flyers = EventFlyers(
                        event: event,
                        imageBuilder: widget.imageBuilder,
                      );
                      if (event.flyers.isNotEmpty &&
                          constraints.maxWidth >= 840) {
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(flex: 6, child: flyers),
                            const SizedBox(width: 28),
                            Expanded(flex: 5, child: details),
                          ],
                        );
                      }
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (event.flyers.isNotEmpty) ...[
                            flyers,
                            const SizedBox(height: 24),
                          ],
                          details,
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 28),
                ],
                Align(
                  alignment: Alignment.center,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 780),
                    child: purchase,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class PaymentInfo extends StatelessWidget {
  final Map<String, dynamic> data;
  final Map<String, dynamic>? fallback;
  const PaymentInfo({super.key, required this.data, this.fallback});
  @override
  Widget build(BuildContext context) {
    String field(String key) => string(data[key] ?? fallback?[key]);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Datos de pago del organizador',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        for (final (key, label) in [
          ('payment_alias', 'Alias'),
          ('payment_cvu', 'CVU / CBU'),
        ])
          if (field(key).isNotEmpty)
            Row(
              children: [
                Expanded(child: SelectableText('$label: ${field(key)}')),
                IconButton(
                  tooltip: 'Copiar $label',
                  icon: const Icon(Icons.copy, size: 20),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: field(key)));
                  },
                ),
              ],
            ),
        if (field('payment_instructions').isNotEmpty)
          Text(field('payment_instructions')),
      ],
    );
  }
}

class AccountGate extends StatelessWidget {
  final VoidCallback onAccount;
  final String message;
  const AccountGate({
    super.key,
    required this.onAccount,
    required this.message,
  });
  @override
  Widget build(BuildContext context) => Panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Cuenta requerida',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(message),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: onAccount,
          icon: const Icon(Icons.person),
          label: const Text('Ingresar o crear cuenta'),
        ),
      ],
    ),
  );
}

class TicketsScreen extends StatefulWidget {
  final ApiService api;
  final VoidCallback onAccount;
  final ValueChanged<AccessItem> onResume;
  const TicketsScreen({
    super.key,
    required this.api,
    required this.onAccount,
    required this.onResume,
  });
  @override
  State<TicketsScreen> createState() => _TicketsScreenState();
}

class _TicketsScreenState extends State<TicketsScreen> {
  List<AccessItem>? _items;
  TicketTransferCatalog? _transfers;
  String? _itemsError;
  String? _transfersError;
  String? _message;
  Object? _scope;
  bool _refreshing = false;
  bool _busy = false;
  bool _concealQr = false;
  int _generation = 0;
  int _qrRevision = 0;
  final _hiddenQr = <int>{};
  Timer? _poll;
  Route<dynamic>? _dialog;

  Object? get _currentScope => widget.api.session.authenticated
      ? (widget.api, widget.api.session.token, widget.api.session.user!['id'])
      : null;

  @override
  void initState() {
    super.initState();
    _scope = _currentScope;
    widget.api.session.addListener(_sessionChanged);
    if (_scope != null) _refresh();
  }

  void _closeDialog() {
    final route = _dialog;
    final navigator = route?.navigator;
    if (route != null && navigator != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (navigator.mounted && route.isActive) navigator.removeRoute(route);
      });
    }
    _dialog = null;
  }

  void _sessionChanged({bool force = false}) {
    if (!mounted || (!force && _scope == _currentScope)) return;
    _generation++;
    _poll?.cancel();
    _closeDialog();
    setState(() {
      _scope = _currentScope;
      _items = null;
      _transfers = null;
      _itemsError = null;
      _transfersError = null;
      _message = null;
      _busy = false;
      _refreshing = false;
      _hiddenQr.clear();
      _qrRevision++;
    });
    if (_scope != null) _refresh();
  }

  @override
  void didUpdateWidget(covariant TicketsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api) {
      oldWidget.api.session.removeListener(_sessionChanged);
      widget.api.session.addListener(_sessionChanged);
      _sessionChanged(force: true);
    }
  }

  Future<void> _refresh({bool silent = false}) async {
    final scope = _scope;
    if (!mounted || scope == null || scope != _currentScope) return;
    if (silent && (_refreshing || _busy)) {
      _poll = Timer(const Duration(seconds: 5), () => _refresh(silent: true));
      return;
    }
    _poll?.cancel();
    final generation = ++_generation;
    setState(() {
      _refreshing = true;
      if (!silent) {
        _concealQr = true;
        _qrRevision++;
      }
    });
    List<AccessItem>? items;
    TicketTransferCatalog? transfers;
    Object? itemsError;
    Object? transfersError;
    await Future.wait([
      () async {
        try {
          items = await widget.api.fetchMyTickets();
        } catch (e) {
          itemsError = e;
        }
      }(),
      () async {
        try {
          transfers = await widget.api.fetchTicketTransfers();
        } catch (e) {
          transfersError = e;
        }
      }(),
    ]);
    if (!mounted || generation != _generation || scope != _currentScope) return;
    setState(() {
      if (items != null) {
        _items = items;
        _hiddenQr.clear();
      }
      _itemsError = itemsError == null
          ? null
          : itemsError is ApiException
          ? (itemsError as ApiException).message
          : 'No pudimos actualizar tus entradas.';
      if (transfers != null) {
        _transfers = transfers;
      }
      // A transfer list can observe acceptance just after the ticket list.
      // Keep using the last known acceptance if its next refresh fails.
      for (final item in _items ?? <AccessItem>[]) {
        if (item.pendingTransferId != null &&
            (_transfers?.outgoing.any(
                  (transfer) =>
                      transfer.id == item.pendingTransferId &&
                      transfer.status == 'accepted',
                ) ??
                false)) {
          _hiddenQr.add(item.ticketId);
        }
      }
      _transfersError = transfersError == null
          ? null
          : 'No pudimos consultar las transferencias. Tus entradas siguen disponibles; actualizá para volver a intentar.';
      _refreshing = false;
      _concealQr = false;
    });
    if ((_transfers?.hasPending ?? false) || _hiddenQr.isNotEmpty) {
      final retry = transfersError is ApiException
          ? (transfersError as ApiException).retryAfter ?? 5
          : 5;
      _poll = Timer(
        Duration(seconds: max(5, retry)),
        () => _refresh(silent: true),
      );
    }
  }

  Future<T?> _showTransferDialog<T>(Widget child) async {
    if (_dialog != null || _scope == null) return null;
    final scope = _scope;
    final route = DialogRoute<T>(
      context: context,
      builder: (_) =>
          mounted && scope == _currentScope ? child : const SizedBox.shrink(),
    );
    _dialog = route;
    try {
      return await Navigator.of(context).push(route);
    } finally {
      if (identical(_dialog, route)) _dialog = null;
    }
  }

  Future<void> _compose(AccessItem item) async {
    if (_busy || !item.canTransfer || _transfersError != null) return;
    final scope = _scope;
    setState(() {
      _busy = true;
      _message = null;
    });
    final result = await _showTransferDialog<TicketTransfer>(
      TicketTransferDialog(
        api: widget.api,
        item: item,
        onPossiblyChanged: _refresh,
      ),
    );
    if (!mounted || scope != _currentScope) return;
    setState(() {
      _busy = false;
      if (result != null) {
        _message = result.pending
            ? 'Solicitud creada. La otra persona la verá en Entradas cuando ingrese con ese correo confirmado.'
            : result.label;
      }
    });
    await _refresh();
  }

  Future<void> _act(TicketTransfer transfer, String action) async {
    if (_busy || _scope == null) return;
    final permitted = switch (action) {
      'accept' => transfer.canAccept,
      'reject' => transfer.canReject,
      'cancel' => transfer.canCancel,
      _ => false,
    };
    if (!permitted) return;
    final scope = _scope;
    final title = switch (action) {
      'accept' => 'Aceptar esta entrada',
      'reject' => 'Rechazar esta solicitud',
      _ => 'Cancelar esta transferencia',
    };
    final copy = switch (action) {
      'accept' =>
        'La entrada pasará a tu cuenta con un QR nuevo. El QR del titular anterior dejará de servir. No se cobra comisión.',
      'reject' =>
        'No recibirás esta entrada. La solicitud quedará rechazada y el titular conservará su entrada.',
      _ =>
        'Se cancela la solicitud, no la entrada. Si todavía está pendiente, conservás la entrada y su QR.',
    };
    setState(() => _busy = true);
    final confirmed = await _showTransferDialog<bool>(
      AlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        scrollable: true,
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(transfer.title),
            Text(transfer.unitLabel),
            const SizedBox(height: 12),
            Text(copy),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.of(context, rootNavigator: true).pop(false),
            child: const Text('Volver'),
          ),
          FilledButton(
            key: const ValueKey('transfer-action-confirm'),
            onPressed: () =>
                Navigator.of(context, rootNavigator: true).pop(true),
            child: const Text('Confirmar'),
          ),
        ],
      ),
    );
    if (!mounted || scope != _currentScope) return;
    if (confirmed != true) {
      setState(() => _busy = false);
      return;
    }
    setState(() {
      _hiddenQr.add(transfer.ticketId);
      _qrRevision++;
      _message = null;
    });
    try {
      final result = await widget.api.actOnTicketTransfer(transfer.id, action);
      if (!mounted || scope != _currentScope) return;
      setState(() => _message = result.label);
    } catch (error) {
      if (!mounted || scope != _currentScope) return;
      setState(
        () => _message = error is ApiException
            ? '${error.message} Actualizá las solicitudes para comprobar el estado.'
            : 'No pudimos confirmar el resultado. Actualizá las solicitudes antes de volver a intentar.',
      );
    } finally {
      if (mounted && scope == _currentScope) {
        setState(() => _busy = false);
        await _refresh();
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    _poll?.cancel();
    _closeDialog();
    widget.api.session.removeListener(_sessionChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.api.session.authenticated) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          AccountGate(
            onAccount: widget.onAccount,
            message: 'Ingresá para ver tus accesos y comprobantes.',
          ),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Entradas',
                style: Theme.of(context).textTheme.headlineLarge,
              ),
            ),
            IconButton(
              onPressed: _refreshing ? null : _refresh,
              tooltip: 'Actualizar entradas',
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Semantics(liveRegion: true, child: Text(_message!)),
          ),
        if (_refreshing) const LinearProgressIndicator(),
        if (_itemsError != null)
          Panel(
            child: Column(
              children: [
                Text(_itemsError!),
                OutlinedButton(
                  onPressed: _refresh,
                  child: const Text('Reintentar'),
                ),
              ],
            ),
          ),
        if (_transfersError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Panel(child: Text(_transfersError!)),
          ),
        if (_transfers != null)
          TicketTransferRequests(
            catalog: _transfers!,
            busy: _busy || _refreshing || _transfersError != null,
            onAction: _act,
          ),
        if (_items?.isEmpty == true)
          const Panel(child: Text('Todavía no tenés órdenes ni entradas.'))
        else if (_items != null)
          for (final item in _items!)
            Padding(
              key: ValueKey('${item.data['item_type']}-${item.data['id']}'),
              padding: const EdgeInsets.only(bottom: 14),
              child: Panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Row(
                      children: [
                        Icon(
                          Icons.confirmation_number_outlined,
                          color: brandBlue,
                          size: 22,
                        ),
                        SizedBox(width: 10),
                        Expanded(child: SectionEyebrow('TUS ACCESOS')),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      item.title,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    if (integer(item.data['ticket_count']) > 1 &&
                        item.ticketId > 0)
                      Text(
                        'Entrada ${integer(item.data['ticket_index'])} de ${integer(item.data['ticket_count'])}',
                      ),
                    Text(
                      item.label,
                      style: TextStyle(
                        color: item.status == 'rejected'
                            ? Colors.orangeAccent
                            : violet,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (item.explanation.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(item.explanation),
                      ),
                    if (item.canUpload)
                      OutlinedButton(
                        key: ValueKey('resume-order-${item.orderId}'),
                        onPressed: () => widget.onResume(item),
                        child: Text(
                          item.status == 'rejected'
                              ? 'Enviar nuevo comprobante'
                              : 'Retomar y subir comprobante',
                        ),
                      ),
                    if (item.canTransfer &&
                        _transfers != null &&
                        _transfersError == null)
                      OutlinedButton(
                        key: ValueKey('transfer-ticket-${item.ticketId}'),
                        onPressed: _busy || _refreshing
                            ? null
                            : () => _compose(item),
                        child: const Text(
                          'Transferir entrada',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    if (item.pendingTransferId != null)
                      const Text(
                        'Transferencia pendiente. Conservás el QR hasta la aceptación.',
                      ),
                    if (_hiddenQr.contains(item.ticketId))
                      const Text(
                        'Actualizá tus entradas para comprobar la titularidad antes de mostrar el QR.',
                      ),
                    if (item.qrEnabled &&
                        !_concealQr &&
                        !_hiddenQr.contains(item.ticketId))
                      ExpansionTile(
                        key: ValueKey('ticket-qr-${item.ticketId}'),
                        leading: const Icon(Icons.qr_code_2),
                        title: const Text('Mostrar QR'),
                        children: [
                          DynamicTicketQrPanel(
                            key: ValueKey(
                              '${item.ticketId}-${item.qrVersion}-$_qrRevision',
                            ),
                            api: widget.api,
                            ticketId: item.ticketId,
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
      ],
    );
  }
}

class AccountScreen extends StatefulWidget {
  final ApiService api;
  final VoidCallback onLoggedIn;
  final Future<void> Function()? onRetrySession;
  final String? sessionError;
  final Future<bool> Function(Uri)? externalLauncher;
  const AccountScreen({
    super.key,
    required this.api,
    required this.onLoggedIn,
    this.sessionError,
    this.onRetrySession,
    this.externalLauncher,
  });
  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _register = false;
  bool _busy = false;
  String? _pending;
  String? _message;
  int _cooldown = 0;
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    _email.text = widget.api.session.email;
    if (widget.api.session.pendingEmail.isNotEmpty) {
      _pending = widget.api.session.pendingEmail;
    }
  }

  void _startCooldown(int seconds) {
    _timer?.cancel();
    _cooldown = seconds;
    if (seconds == 0) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() => _cooldown = max(0, _cooldown - 1));
      if (_cooldown == 0) timer.cancel();
    });
  }

  Future<void> _showPending(String message, int cooldown) async {
    final email = _email.text.trim();
    await widget.api.session.pending(email);
    if (!mounted) return;
    setState(() {
      _pending = email;
      _message = message;
      _password.clear();
      _startCooldown(cooldown);
    });
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (!_email.text.contains('@') ||
        _password.text.isEmpty ||
        (_register && _name.text.trim().isEmpty)) {
      setState(() => _message = 'Completá los datos para continuar.');
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      if (_register) {
        final result = await widget.api.register(
          _name.text.trim(),
          _email.text.trim(),
          _password.text,
        );
        final expected = result['verification_required'] == true;
        await _showPending(
          expected
              ? string(
                  result['message'],
                  'Revisá tu correo para confirmar la cuenta.',
                )
              : 'No pudimos iniciar la confirmación. Intentá reenviarla.',
          expected ? 60 : 0,
        );
      } else {
        await widget.api.login(_email.text.trim(), _password.text);
        _password.clear();
        if (mounted) widget.onLoggedIn();
      }
    } on ApiException catch (e) {
      if (e.verificationRequired) {
        await _showPending(e.message, e.retryAfter ?? 0);
      } else if (mounted) {
        setState(() => _message = e.message);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _message = 'No se pudo validar la cuenta. Intentá nuevamente.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resend() async {
    if (_busy || _cooldown > 0 || _pending == null) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final result = await widget.api.resend(_pending!);
      if (mounted) {
        setState(() {
          _message = string(
            result['message'],
            'Si corresponde, recibirás un correo para confirmar tu cuenta.',
          );
          _startCooldown(60);
        });
      }
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _message = e.message;
          _startCooldown(max(60, e.retryAfter ?? 60));
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _message = 'No se pudo reenviar. Intentá nuevamente.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmed() async {
    await widget.api.session.clearPending();
    if (mounted) {
      setState(() {
        _pending = null;
        _register = false;
        _message = 'Ingresá para comprobar la confirmación de tu correo.';
      });
    }
  }

  Future<void> _logout() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await widget.api.logout();
    } catch (_) {
      if (mounted) {
        setState(
          () => _message =
              'No pudimos revocar la sesión. Comprobá la conexión y reintentá.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Row(
              children: [
                Icon(Icons.person_outline, color: brandBlue, size: 26),
                SizedBox(width: 12),
                Expanded(child: SectionEyebrow('TU CUENTA · PULSO LIBRE')),
              ],
            ),
            const SizedBox(height: 22),
            if (widget.api.session.authenticated) ...[
              Text(
                'Sesión activa',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              Text(widget.api.session.email),
              const Text('Correo confirmado'),
              const SizedBox(height: 14),
              OutlinedButton(
                onPressed: _busy ? null : _logout,
                child: const Text('Cerrar sesión'),
              ),
            ] else if (_pending != null) ...[
              Text(
                'Confirmá tu correo',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 10),
              Text(_pending!),
              const SizedBox(height: 10),
              const Text(
                'Cuando recibas el correo, abrí su enlace. Después volvé a ingresar para validar la cuenta.',
              ),
              const SizedBox(height: 14),
              FilledButton(
                onPressed: _busy || _cooldown > 0 ? null : _resend,
                child: Text(
                  _cooldown > 0
                      ? 'Reenviar en ${_cooldown}s'
                      : 'Reenviar confirmación',
                ),
              ),
              OutlinedButton(
                onPressed: _busy ? null : _confirmed,
                child: const Text('Ya confirmé: ir a ingresar'),
              ),
            ] else ...[
              Text(
                _register ? 'Crear cuenta' : 'Ingresar',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 16),
              if (_register) ...[
                TextField(
                  key: const ValueKey('account-name'),
                  controller: _name,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Nombre y apellido',
                  ),
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                key: const ValueKey('account-email'),
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Correo electrónico',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('account-password'),
                controller: _password,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: 'Contraseña'),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: Text(
                  _busy
                      ? 'Procesando…'
                      : _register
                      ? 'Crear cuenta'
                      : 'Entrar',
                ),
              ),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => setState(() {
                        _register = !_register;
                        _message = null;
                        _password.clear();
                      }),
                child: Text(_register ? 'Ya tengo cuenta' : 'Crear una cuenta'),
              ),
              if (widget.sessionError != null &&
                  widget.api.session.hasCredential) ...[
                Text(widget.sessionError!),
                OutlinedButton(
                  onPressed: _busy ? null : widget.onRetrySession,
                  child: const Text('Reintentar sesión guardada'),
                ),
              ],
            ],
            PasswordRecoveryButton(
              api: widget.api,
              enabled: !_busy,
              signedIn: widget.api.session.authenticated,
              initialEmail: () => widget.api.session.authenticated
                  ? widget.api.session.email
                  : _pending ?? _email.text,
            ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_message!, style: const TextStyle(color: muted)),
              ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      Panel(
        child: AccountPrivacyLinks(externalLauncher: widget.externalLauncher),
      ),
    ],
  );
}
