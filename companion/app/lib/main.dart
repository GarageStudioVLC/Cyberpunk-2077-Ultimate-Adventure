// =============================================================================
//  CP2077 Companion · App móvil (Flutter)
//
//  Se conecta por WebSocket a server.js (PC de juego) y pinta en tiempo real:
//  salud, eurodólares, coordenadas + radar de trayectoria, búsqueda policial,
//  vehículo, misión y el panel "Notificaciones de Night City" (llamadas/SMS).
//
//  Cambia kDefaultPcIp por la IP de tu PC (server.js la imprime al arrancar).
//  También se puede cambiar desde la app con el icono de red de la cabecera.
// =============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// ---------------------------------------------------------------------------
//  Configuración
// ---------------------------------------------------------------------------
const String kDefaultPcIp = String.fromEnvironment('PC_IP', defaultValue: '192.168.1.100');
const int kServerPort = 3000;
const int kSchemaVersion = 1;
const int kMaxEvents = 50;
const int kTrailLength = 150;

// Paleta HUD
const Color kBg = Color(0xFF07070D);
const Color kPanel = Color(0xFF0F1019);
const Color kYellow = Color(0xFFFCEE0A);
const Color kCyan = Color(0xFF00F0FF);
const Color kRed = Color(0xFFFF003C);
const Color kMagenta = Color(0xFFFF2BD6);
const Color kGreen = Color(0xFF39FF88);
const Color kDim = Color(0xFF6B6F86);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
  runApp(const CompanionApp());
}

// =============================================================================
//  MODELOS (schema v1) · lectura defensiva: un campo ausente nunca rompe la UI
// =============================================================================
double? _asDouble(Object? v) => v is num ? v.toDouble() : null;
int? _asInt(Object? v) => v is num ? v.toInt() : null;
String? _asString(Object? v) => v is String && v.isNotEmpty ? v : null;
bool _asBool(Object? v) => v == true;
Map<String, dynamic>? _asMap(Object? v) => v is Map ? v.cast<String, dynamic>() : null;

class HealthData {
  const HealthData({this.current, this.max});
  final double? current;
  final double? max;

  double get ratio {
    final c = current;
    final m = max;
    if (c == null || m == null || m <= 0) return 0;
    return (c / m).clamp(0.0, 1.0);
  }

  factory HealthData.fromJson(Map<String, dynamic>? j) =>
      HealthData(current: _asDouble(j?['current']), max: _asDouble(j?['max']));
}

class LocationData {
  const LocationData({required this.x, required this.y, this.z, this.yaw});
  final double x;
  final double y;
  final double? z;
  final double? yaw;

  static LocationData? fromJson(Map<String, dynamic>? j) {
    final x = _asDouble(j?['x']);
    final y = _asDouble(j?['y']);
    if (x == null || y == null) return null;
    return LocationData(x: x, y: y, z: _asDouble(j?['z']), yaw: _asDouble(j?['yaw']));
  }
}

class VehicleData {
  const VehicleData({required this.name, this.speedKmh, this.recordId});
  final String name;
  final double? speedKmh;
  final String? recordId;

  static VehicleData? fromJson(Map<String, dynamic>? j) {
    if (j == null) return null;
    return VehicleData(
      name: _asString(j['name']) ?? 'Vehículo',
      speedKmh: _asDouble(j['speedKmh']),
      recordId: _asString(j['recordId']),
    );
  }
}

class QuestData {
  const QuestData({this.id, this.title, this.objective});
  final String? id;
  final String? title;
  final String? objective;

  static QuestData? fromJson(Map<String, dynamic>? j) {
    if (j == null) return null;
    final q = QuestData(
      id: _asString(j['id']),
      title: _asString(j['title']),
      objective: _asString(j['objective']),
    );
    return (q.title == null && q.objective == null) ? null : q;
  }
}

class PhoneCall {
  const PhoneCall({
    required this.contact,
    required this.phase,
    this.contactId,
    this.outgoing = false,
  });
  final String contact;
  final String phase; // incoming | active | ended | unknown
  final String? contactId;
  final bool outgoing;

  bool get isIncoming => phase == 'incoming';

  static PhoneCall? fromJson(Map<String, dynamic>? j) {
    if (j == null) return null;
    return PhoneCall(
      contact: _asString(j['contact']) ?? 'Desconocido',
      phase: _asString(j['phase']) ?? 'unknown',
      contactId: _asString(j['contactId']),
      outgoing: _asBool(j['outgoing']),
    );
  }
}

enum GameEventKind { phoneCall, textMessage, questUpdate, other }

class GameEvent {
  GameEvent({
    required this.id,
    required this.kind,
    required this.rawKind,
    required this.data,
    required this.receivedAt,
  });

  final String id;
  final GameEventKind kind;
  final String rawKind;
  final Map<String, dynamic> data;
  final DateTime receivedAt;

  static GameEvent? fromJson(Object? raw) {
    final j = _asMap(raw);
    if (j == null) return null;
    final id = _asString(j['id']);
    final kindStr = _asString(j['kind']);
    if (id == null || kindStr == null) return null;
    final kind = switch (kindStr) {
      'phone_call' => GameEventKind.phoneCall,
      'text_message' => GameEventKind.textMessage,
      'quest_update' => GameEventKind.questUpdate,
      _ => GameEventKind.other,
    };
    return GameEvent(
      id: id,
      kind: kind,
      rawKind: kindStr,
      data: _asMap(j['data']) ?? const <String, dynamic>{},
      receivedAt: DateTime.now(),
    );
  }

  String get contact => _asString(data['contact']) ?? 'Desconocido';
  String get phase => _asString(data['phase']) ?? '';
  bool get fromPlayer => _asBool(data['fromPlayer']);

  /// Merece alerta (parpadeo + vibración): llamada entrante o SMS de un NPC.
  bool get isAlert =>
      (kind == GameEventKind.phoneCall && phase == 'incoming') ||
      (kind == GameEventKind.textMessage && !fromPlayer);

  String get title => switch (kind) {
        GameEventKind.phoneCall => switch (phase) {
            'incoming' => 'Llamada entrante · $contact',
            'active' => _asBool(data['outgoing']) ? 'Llamando a $contact' : 'En llamada · $contact',
            'ended' => 'Llamada finalizada · $contact',
            _ => 'Llamada · $contact',
          },
        GameEventKind.textMessage => fromPlayer ? 'V → $contact' : 'Mensaje de $contact',
        GameEventKind.questUpdate => 'Diario actualizado',
        GameEventKind.other => rawKind,
      };

  String get body => switch (kind) {
        GameEventKind.textMessage => _asString(data['text']) ?? '',
        GameEventKind.questUpdate => _asString(data['title']) ?? _asString(data['id']) ?? '',
        GameEventKind.phoneCall => '',
        GameEventKind.other => jsonEncode(data),
      };

  IconData get icon => switch (kind) {
        GameEventKind.phoneCall => phase == 'ended' ? Icons.call_end : Icons.phone_in_talk,
        GameEventKind.textMessage => Icons.sms,
        GameEventKind.questUpdate => Icons.map,
        GameEventKind.other => Icons.bolt,
      };

  Color get color => switch (kind) {
        GameEventKind.phoneCall => phase == 'ended' ? kDim : kMagenta,
        GameEventKind.textMessage => kCyan,
        GameEventKind.questUpdate => kYellow,
        GameEventKind.other => kGreen,
      };
}

class Telemetry {
  const Telemetry({
    required this.health,
    this.money,
    this.level,
    this.location,
    this.vehicle,
    this.wantedLevel = 0,
    this.chasing = false,
    this.quest,
    this.weaponName,
    this.gameHour,
    this.gameMinute,
    this.activeCall,
  });

  final HealthData health;
  final int? money;
  final int? level;
  final LocationData? location;
  final VehicleData? vehicle;
  final int wantedLevel;
  final bool chasing;
  final QuestData? quest;
  final String? weaponName;
  final int? gameHour;
  final int? gameMinute;
  final PhoneCall? activeCall;

  factory Telemetry.fromJson(Map<String, dynamic> j) {
    final player = _asMap(j['player']);
    final wanted = _asMap(j['wanted']);
    final world = _asMap(j['world']);
    final inventory = _asMap(j['inventory']);
    final phone = _asMap(j['phone']);
    return Telemetry(
      health: HealthData.fromJson(_asMap(player?['health'])),
      money: _asInt(player?['money']),
      level: _asInt(player?['level']),
      location: LocationData.fromJson(_asMap(j['location'])),
      vehicle: VehicleData.fromJson(_asMap(j['vehicle'])),
      wantedLevel: (_asInt(wanted?['level']) ?? 0).clamp(0, 5),
      chasing: _asBool(wanted?['chasing']),
      quest: QuestData.fromJson(_asMap(j['quest'])),
      weaponName: _asString(_asMap(inventory?['equippedWeapon'])?['name']),
      gameHour: _asInt(world?['hour']),
      gameMinute: _asInt(world?['minute']),
      activeCall: PhoneCall.fromJson(_asMap(phone?['activeCall'])),
    );
  }
}

// =============================================================================
//  SERVICIO DE TELEMETRÍA (WebSocket + reconexión + estado reactivo)
// =============================================================================
enum LinkStatus { connecting, connected, disconnected }

class TelemetryService extends ChangeNotifier {
  TelemetryService(this._host);

  String _host;
  String get host => _host;
  Uri get uri => Uri.parse('ws://$_host:$kServerPort');

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _reconnectTimer;
  Timer? _watchdog;
  int _attempt = 0;
  int _generation = 0; // invalida callbacks de conexiones antiguas
  bool _disposed = false;
  DateTime _lastMessageAt = DateTime.fromMillisecondsSinceEpoch(0);

  LinkStatus status = LinkStatus.disconnected;
  String? lastError;
  bool gameOnline = false;
  Telemetry? telemetry;
  final List<GameEvent> events = [];
  final List<Offset> trail = [];
  final Set<String> _seenIds = {};

  final StreamController<GameEvent> _alerts = StreamController<GameEvent>.broadcast();

  /// Eventos que merecen alerta (llamada entrante, SMS de NPC).
  Stream<GameEvent> get alerts => _alerts.stream;

  void start() {
    _watchdog ??= Timer.periodic(const Duration(seconds: 5), (_) => _checkAlive());
    _connect();
  }

  void changeHost(String newHost) {
    final cleaned = newHost.trim().replaceAll(RegExp(r'^wss?://'), '').split(':').first;
    if (cleaned.isEmpty) return;
    _host = cleaned;
    telemetry = null;
    trail.clear();
    _attempt = 0;
    _connect();
  }

  Future<void> _connect() async {
    _reconnectTimer?.cancel();
    final gen = ++_generation;
    await _closeChannel();
    if (gen != _generation || _disposed) return;
    status = LinkStatus.connecting;
    lastError = null;
    _notify();
    try {
      final channel = WebSocketChannel.connect(uri);
      _channel = channel;
      await channel.ready.timeout(const Duration(seconds: 5));
      if (gen != _generation || _disposed) return;
      _attempt = 0;
      status = LinkStatus.connected;
      _lastMessageAt = DateTime.now();
      _notify();
      _sub = channel.stream.listen(
        (msg) => _onMessage(msg, gen),
        onError: (Object e) => _onClosed(gen, e.toString()),
        onDone: () => _onClosed(gen, null),
        cancelOnError: true,
      );
    } catch (e) {
      _onClosed(gen, e.toString());
    }
  }

  void _onClosed(int gen, String? error) {
    if (gen != _generation || _disposed) return;
    _generation++; // ignora cualquier callback tardío de esta conexión
    status = LinkStatus.disconnected;
    gameOnline = false;
    lastError = error;
    _notify();
    _closeChannel();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    final seconds = math.min(10, 1 << math.min(_attempt, 4)); // 1, 2, 4, 8, 10…
    _attempt++;
    _reconnectTimer = Timer(Duration(seconds: seconds), _connect);
  }

  void _checkAlive() {
    if (status != LinkStatus.connected) return;
    final gen = _generation;
    try {
      _channel?.sink.add(jsonEncode({'type': 'ping'}));
    } catch (_) {
      _onClosed(gen, 'ping fallido');
      return;
    }
    if (DateTime.now().difference(_lastMessageAt) > const Duration(seconds: 12)) {
      _onClosed(gen, 'sin respuesta del servidor');
    }
  }

  void _onMessage(dynamic raw, int gen) {
    if (gen != _generation) return;
    _lastMessageAt = DateTime.now();
    final Map<String, dynamic> msg;
    try {
      final decoded = jsonDecode(raw is String ? raw : utf8.decode(raw as List<int>));
      if (decoded is! Map) return;
      msg = decoded.cast<String, dynamic>();
    } catch (_) {
      return;
    }

    switch (msg['type']) {
      case 'hello':
        gameOnline = _asBool(msg['gameOnline']);
        final latest = _asMap(msg['latest']);
        if (latest != null) _applySnapshot(latest);
        final recent = msg['recentEvents'];
        if (recent is List) {
          // El historial llega del más antiguo al más nuevo; se insertan arriba en orden.
          for (final e in recent) {
            _addEvent(GameEvent.fromJson(e), alert: false);
          }
        }
      case 'status':
        gameOnline = _asBool(msg['gameOnline']);
      case 'telemetry':
        final data = _asMap(msg['data']);
        if (data == null) return;
        if (_asInt(data['v']) != kSchemaVersion) {
          lastError = 'Versión de esquema ${data['v']} no soportada';
        }
        gameOnline = true;
        _applySnapshot(data);
        final evs = data['events'];
        if (evs is List) {
          for (final e in evs) {
            _addEvent(GameEvent.fromJson(e), alert: true);
          }
        }
      default:
        return; // 'pong' y tipos futuros: solo cuentan como señal de vida
    }
    _notify();
  }

  void _applySnapshot(Map<String, dynamic> data) {
    final t = Telemetry.fromJson(data);
    telemetry = t;
    final loc = t.location;
    if (loc != null) {
      final p = Offset(loc.x, loc.y);
      if (trail.isEmpty || (trail.last - p).distance > 0.5) {
        trail.add(p);
        if (trail.length > kTrailLength) trail.removeAt(0);
      }
    }
  }

  void _addEvent(GameEvent? e, {required bool alert}) {
    if (e == null || !_seenIds.add(e.id)) return;
    events.insert(0, e);
    if (events.length > kMaxEvents) events.removeRange(kMaxEvents, events.length);
    if (_seenIds.length > kMaxEvents * 10) {
      _seenIds
        ..clear()
        ..addAll(events.map((x) => x.id));
    }
    if (alert && e.isAlert && !_alerts.isClosed) _alerts.add(e);
  }

  void clearEvents() {
    events.clear();
    _notify();
  }

  Future<void> _closeChannel() async {
    final sub = _sub;
    final ch = _channel;
    _sub = null;
    _channel = null;
    await sub?.cancel();
    if (ch != null) {
      try {
        await ch.sink.close();
      } catch (_) {
        // el socket ya estaba cerrado
      }
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _reconnectTimer?.cancel();
    _watchdog?.cancel();
    _closeChannel();
    _alerts.close();
    super.dispose();
  }
}

// =============================================================================
//  APP
// =============================================================================
class CompanionApp extends StatelessWidget {
  const CompanionApp({super.key});

  @override
  Widget build(BuildContext context) {
    final base = ThemeData.dark(useMaterial3: true);
    return MaterialApp(
      title: 'CP2077 Companion',
      debugShowCheckedModeBanner: false,
      theme: base.copyWith(
        scaffoldBackgroundColor: kBg,
        colorScheme: base.colorScheme.copyWith(primary: kYellow, secondary: kCyan, surface: kPanel),
        textTheme: base.textTheme.apply(
          bodyColor: Colors.white,
          displayColor: kYellow,
          fontFamily: 'monospace',
        ),
      ),
      home: const HudScreen(),
    );
  }
}

class HudScreen extends StatefulWidget {
  const HudScreen({super.key});

  @override
  State<HudScreen> createState() => _HudScreenState();
}

class _HudScreenState extends State<HudScreen> with TickerProviderStateMixin {
  late final TelemetryService _service;
  late final AnimationController _flash;
  StreamSubscription<GameEvent>? _alertSub;
  GameEvent? _banner;
  Timer? _bannerTimer;

  @override
  void initState() {
    super.initState();
    _flash = AnimationController(vsync: this, duration: const Duration(milliseconds: 260));
    _service = TelemetryService(kDefaultPcIp)..start();
    _alertSub = _service.alerts.listen(_onAlert);
  }

  Future<void> _onAlert(GameEvent e) async {
    _vibrateFor(e);
    setState(() => _banner = e);
    _bannerTimer?.cancel();
    _bannerTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) setState(() => _banner = null);
    });
    // Parpadeo del panel de notificaciones: 4 destellos.
    _flash
      ..stop()
      ..value = 0;
    for (var i = 0; i < 4; i++) {
      if (!mounted) return;
      try {
        await _flash.forward().orCancel;
        await _flash.reverse().orCancel;
      } on TickerCanceled {
        return; // llegó otra alerta y reinició la animación
      }
    }
  }

  void _vibrateFor(GameEvent e) {
    if (e.kind == GameEventKind.phoneCall) {
      HapticFeedback.heavyImpact();
      Future<void>.delayed(const Duration(milliseconds: 180), HapticFeedback.heavyImpact);
      Future<void>.delayed(const Duration(milliseconds: 360), HapticFeedback.heavyImpact);
    } else {
      HapticFeedback.mediumImpact();
    }
  }

  Future<void> _editHost() async {
    final controller = TextEditingController(text: _service.host);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kPanel,
        shape: const BeveledRectangleBorder(
          side: BorderSide(color: kYellow),
          borderRadius: BorderRadius.only(topRight: Radius.circular(14)),
        ),
        title: const Text('IP DE LA PC', style: TextStyle(color: kYellow, letterSpacing: 2)),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: const TextStyle(color: kCyan),
          decoration: const InputDecoration(
            hintText: '192.168.1.100',
            helperText: 'server.js muestra la IP al arrancar',
            enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: kDim)),
            focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: kCyan)),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('CANCELAR')),
          TextButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('CONECTAR')),
        ],
      ),
    );
    controller.dispose();
    if (result != null && result.trim().isNotEmpty) _service.changeHost(result);
  }

  @override
  void dispose() {
    _alertSub?.cancel();
    _bannerTimer?.cancel();
    _flash.dispose();
    _service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: _service,
          builder: (context, _) {
            final t = _service.telemetry;
            final call = t?.activeCall;
            final banner = _banner;
            return Stack(
              children: [
                const Positioned.fill(child: CustomPaint(painter: ScanlinePainter())),
                ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  children: [
                    _Header(service: _service, onEditHost: _editHost),
                    const SizedBox(height: 14),
                    if (call != null && call.phase != 'ended')
                      Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: ActiveCallCard(call: call),
                      ),
                    HealthPanel(health: t?.health ?? const HealthData()),
                    const SizedBox(height: 12),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: EddiesPanel(money: t?.money)),
                        const SizedBox(width: 12),
                        Expanded(child: WantedPanel(level: t?.wantedLevel ?? 0, chasing: t?.chasing ?? false)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    LocationPanel(location: t?.location, trail: List<Offset>.of(_service.trail)),
                    const SizedBox(height: 12),
                    StatusPanel(telemetry: t),
                    const SizedBox(height: 12),
                    NotificationsPanel(
                      events: _service.events,
                      flash: _flash,
                      onClear: _service.clearEvents,
                    ),
                  ],
                ),
                if (banner != null)
                  Positioned(
                    left: 12,
                    right: 12,
                    top: 8,
                    child: AlertBanner(
                      key: ValueKey(banner.id),
                      event: banner,
                      onTap: () => setState(() => _banner = null),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

// =============================================================================
//  WIDGETS HUD
// =============================================================================
class HudPanel extends StatelessWidget {
  const HudPanel({
    super.key,
    required this.label,
    required this.child,
    this.accent = kYellow,
    this.trailing,
    this.glow = 0,
  });

  final String label;
  final Widget child;
  final Color accent;
  final Widget? trailing;
  final double glow; // 0..1, para parpadeos

  @override
  Widget build(BuildContext context) {
    final trailingWidget = trailing;
    return Container(
      decoration: ShapeDecoration(
        color: Color.lerp(kPanel, accent.withValues(alpha: 0.18), glow),
        shape: BeveledRectangleBorder(
          side: BorderSide(color: Color.lerp(accent.withValues(alpha: 0.55), accent, glow)!, width: 1 + glow),
          borderRadius: const BorderRadius.only(topRight: Radius.circular(14), bottomLeft: Radius.circular(8)),
        ),
        shadows: [BoxShadow(color: accent.withValues(alpha: 0.10 + 0.45 * glow), blurRadius: 12 + 18 * glow)],
      ),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(width: 6, height: 6, color: accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label.toUpperCase(),
                  style: TextStyle(color: accent, fontSize: 11, letterSpacing: 2.5, fontWeight: FontWeight.w700),
                ),
              ),
              if (trailingWidget != null) trailingWidget,
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.service, required this.onEditHost});
  final TelemetryService service;
  final VoidCallback onEditHost;

  @override
  Widget build(BuildContext context) {
    final (linkColor, linkText) = switch (service.status) {
      LinkStatus.connected => (kGreen, 'ENLACE OK'),
      LinkStatus.connecting => (kYellow, 'CONECTANDO'),
      LinkStatus.disconnected => (kRed, 'SIN ENLACE'),
    };
    final gameText = service.status != LinkStatus.connected
        ? 'JUEGO —'
        : service.gameOnline
            ? 'JUEGO EN VIVO'
            : 'ESPERANDO AL JUEGO';
    final error = service.lastError;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'NIGHT CITY // LINK',
                style: TextStyle(
                  color: kYellow,
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 3,
                  shadows: [Shadow(color: kYellow, blurRadius: 12)],
                ),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  _Chip(text: linkText, color: linkColor),
                  _Chip(text: gameText, color: service.gameOnline ? kCyan : kDim),
                  _Chip(text: '${service.host}:$kServerPort', color: kDim),
                ],
              ),
              if (service.status == LinkStatus.disconnected && error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    error,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: kRed, fontSize: 10),
                  ),
                ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Cambiar IP de la PC',
          onPressed: onEditHost,
          icon: const Icon(Icons.settings_ethernet, color: kCyan),
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(border: Border.all(color: color.withValues(alpha: 0.7))),
      child: Text(text, style: TextStyle(color: color, fontSize: 10, letterSpacing: 1.5)),
    );
  }
}

class HealthPanel extends StatelessWidget {
  const HealthPanel({super.key, required this.health});
  final HealthData health;

  @override
  Widget build(BuildContext context) {
    final ratio = health.ratio;
    final color = ratio > 0.5 ? kCyan : (ratio > 0.25 ? kYellow : kRed);
    final current = health.current;
    final max = health.max;
    return HudPanel(
      label: 'Salud',
      accent: color,
      trailing: Text(
        current == null ? '— / —' : '${current.round()} / ${max?.round() ?? '—'}',
        style: TextStyle(color: color, fontSize: 14, fontWeight: FontWeight.w700),
      ),
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(end: ratio),
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
        builder: (context, value, _) => SizedBox(
          height: 22,
          width: double.infinity,
          child: CustomPaint(painter: SegmentedBarPainter(value: value, color: color)),
        ),
      ),
    );
  }
}

class SegmentedBarPainter extends CustomPainter {
  SegmentedBarPainter({required this.value, required this.color});
  final double value;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const segments = 24;
    const gap = 3.0;
    final segW = (size.width - gap * (segments - 1)) / segments;
    final filled = value * segments;
    final empty = Paint()..color = color.withValues(alpha: 0.10);
    final full = Paint()
      ..color = color
      ..maskFilter = const MaskFilter.blur(BlurStyle.solid, 2);
    for (var i = 0; i < segments; i++) {
      final left = i * (segW + gap);
      canvas.drawRect(Rect.fromLTWH(left, 0, segW, size.height), empty);
      final amount = (filled - i).clamp(0.0, 1.0);
      if (amount > 0) {
        canvas.drawRect(Rect.fromLTWH(left, 0, segW * amount, size.height), full);
      }
    }
  }

  @override
  bool shouldRepaint(SegmentedBarPainter oldDelegate) =>
      oldDelegate.value != value || oldDelegate.color != color;
}

class EddiesPanel extends StatelessWidget {
  const EddiesPanel({super.key, required this.money});
  final int? money;

  static String format(int n) {
    final s = n.abs().toString();
    final buf = StringBuffer(n < 0 ? '-' : '');
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write('.');
      buf.write(s[i]);
    }
    return buf.toString();
  }

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
      color: kYellow,
      fontSize: 26,
      fontWeight: FontWeight.w800,
      shadows: [Shadow(color: kYellow, blurRadius: 10)],
    );
    final amount = money;
    return HudPanel(
      label: 'Eurodólares',
      child: amount == null
          ? const Text('€\$ —', style: style)
          : TweenAnimationBuilder<double>(
              tween: Tween<double>(end: amount.toDouble()),
              duration: const Duration(milliseconds: 600),
              curve: Curves.easeOut,
              builder: (context, v, _) => FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text('€\$ ${format(v.round())}', style: style),
              ),
            ),
    );
  }
}

class WantedPanel extends StatelessWidget {
  const WantedPanel({super.key, required this.level, required this.chasing});
  final int level;
  final bool chasing;

  @override
  Widget build(BuildContext context) {
    final color = level > 0 ? kRed : kDim;
    return HudPanel(
      label: 'NCPD',
      accent: color,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              children: List.generate(
                5,
                (i) => Icon(i < level ? Icons.star : Icons.star_border, color: i < level ? kRed : kDim, size: 22),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            level == 0 ? 'SIN BÚSQUEDA' : (chasing ? 'PERSECUCIÓN ACTIVA' : 'NIVEL $level'),
            style: TextStyle(color: color, fontSize: 10, letterSpacing: 1.5),
          ),
        ],
      ),
    );
  }
}

class LocationPanel extends StatelessWidget {
  const LocationPanel({super.key, required this.location, required this.trail});
  final LocationData? location;
  final List<Offset> trail;

  @override
  Widget build(BuildContext context) {
    final loc = location;
    String f(double? v) => v == null ? '—' : v.toStringAsFixed(1);
    final yaw = loc?.yaw;
    return HudPanel(
      label: 'Posición de V',
      accent: kCyan,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Coord(axis: 'X', value: f(loc?.x)),
                _Coord(axis: 'Y', value: f(loc?.y)),
                _Coord(axis: 'Z', value: f(loc?.z), dim: true),
                const SizedBox(height: 4),
                Text(
                  yaw == null ? 'RUMBO —' : 'RUMBO ${yaw.round()}°',
                  style: const TextStyle(color: kDim, fontSize: 11, letterSpacing: 1.5),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 140,
            height: 140,
            child: CustomPaint(painter: RadarPainter(trail: trail, yaw: yaw)),
          ),
        ],
      ),
    );
  }
}

class _Coord extends StatelessWidget {
  const _Coord({required this.axis, required this.value, this.dim = false});
  final String axis;
  final String value;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(width: 22, child: Text(axis, style: const TextStyle(color: kCyan, fontWeight: FontWeight.w900))),
          Expanded(
            child: Text(
              value,
              overflow: TextOverflow.fade,
              softWrap: false,
              style: TextStyle(
                color: dim ? kDim : Colors.white,
                fontSize: dim ? 16 : 22,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Mini-radar centrado en V que dibuja su trayectoria reciente. Es la base del
/// futuro mapa: basta con pintar un tile de Night City bajo la misma transformación.
class RadarPainter extends CustomPainter {
  RadarPainter({required this.trail, required this.yaw});
  final List<Offset> trail;
  final double? yaw;

  static const double rangeMeters = 400; // radio visible del radar

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final grid = Paint()
      ..color = kCyan.withValues(alpha: 0.18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawCircle(c, r - 0.5, grid);
    canvas.drawCircle(c, r * 0.66, grid);
    canvas.drawCircle(c, r * 0.33, grid);
    canvas.drawLine(Offset(c.dx - r, c.dy), Offset(c.dx + r, c.dy), grid);
    canvas.drawLine(Offset(c.dx, c.dy - r), Offset(c.dx, c.dy + r), grid);

    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: r)));
    if (trail.length > 1) {
      final me = trail.last;
      final scale = r / rangeMeters;
      // En el juego +Y es norte; en pantalla +Y es hacia abajo.
      Offset toScreen(Offset p) => Offset(c.dx + (p.dx - me.dx) * scale, c.dy - (p.dy - me.dy) * scale);
      for (var i = 1; i < trail.length; i++) {
        final t = i / trail.length;
        canvas.drawLine(
          toScreen(trail[i - 1]),
          toScreen(trail[i]),
          Paint()
            ..color = kYellow.withValues(alpha: 0.15 + 0.85 * t)
            ..strokeWidth = 2
            ..strokeCap = StrokeCap.round,
        );
      }
    }
    canvas.restore();

    // V en el centro, orientada según el rumbo (yaw 0 = norte, positivo = giro a la izquierda).
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(-(yaw ?? 0) * math.pi / 180);
    final arrow = Path()
      ..moveTo(0, -9)
      ..lineTo(6, 7)
      ..lineTo(0, 3)
      ..lineTo(-6, 7)
      ..close();
    canvas.drawPath(
      arrow,
      Paint()
        ..color = kRed
        ..maskFilter = const MaskFilter.blur(BlurStyle.outer, 4),
    );
    canvas.drawPath(arrow, Paint()..color = kRed);
    canvas.restore();

    final tp = TextPainter(
      text: const TextSpan(text: 'N', style: TextStyle(color: kCyan, fontSize: 10, fontWeight: FontWeight.w700)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(c.dx - tp.width / 2, c.dy - r + 2));
  }

  @override
  bool shouldRepaint(RadarPainter oldDelegate) =>
      oldDelegate.yaw != yaw ||
      oldDelegate.trail.length != trail.length ||
      (trail.isNotEmpty && oldDelegate.trail.isNotEmpty && oldDelegate.trail.last != trail.last);
}

class StatusPanel extends StatelessWidget {
  const StatusPanel({super.key, required this.telemetry});
  final Telemetry? telemetry;

  @override
  Widget build(BuildContext context) {
    final t = telemetry;
    final speed = t?.vehicle?.speedKmh;
    final hour = t?.gameHour;
    final minute = t?.gameMinute;
    final level = t?.level;
    final clock = (hour == null || minute == null)
        ? null
        : '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
    final info = [if (level != null) 'NV $level', if (clock != null) clock].join('  ·  ');
    return HudPanel(
      label: 'Estado',
      trailing: Text(info, style: const TextStyle(color: kDim, fontSize: 11, letterSpacing: 1.5)),
      child: Column(
        children: [
          _StatusRow(
            icon: Icons.flag,
            label: 'MISIÓN',
            value: t?.quest?.title ?? 'Sin misión seguida',
            sub: t?.quest?.objective,
            color: kYellow,
          ),
          _StatusRow(
            icon: Icons.directions_car,
            label: 'VEHÍCULO',
            value: t?.vehicle?.name ?? 'A pie',
            sub: speed == null ? null : '${speed.round()} km/h',
            color: kCyan,
          ),
          _StatusRow(
            icon: Icons.gps_fixed,
            label: 'ARMA',
            value: t?.weaponName ?? '—',
            color: kMagenta,
          ),
        ],
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.icon, required this.label, required this.value, required this.color, this.sub});
  final IconData icon;
  final String label;
  final String value;
  final String? sub;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final subText = sub;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          SizedBox(
            width: 74,
            child: Text(label, style: TextStyle(color: color, fontSize: 10, letterSpacing: 1.5)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(value, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
                if (subText != null && subText.isNotEmpty)
                  Text(subText, style: const TextStyle(color: kDim, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Llamada en curso: tarjeta que late mientras el NPC está llamando.
class ActiveCallCard extends StatefulWidget {
  const ActiveCallCard({super.key, required this.call});
  final PhoneCall call;

  @override
  State<ActiveCallCard> createState() => _ActiveCallCardState();
}

class _ActiveCallCardState extends State<ActiveCallCard> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 700))..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final call = widget.call;
    final title = call.isIncoming
        ? 'LLAMADA ENTRANTE'
        : call.outgoing
            ? 'LLAMANDO…'
            : 'EN LLAMADA';
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) => HudPanel(
        label: title,
        accent: kMagenta,
        glow: call.isIncoming ? _pulse.value : 0.25,
        child: Row(
          children: [
            Transform.scale(
              scale: call.isIncoming ? 1 + 0.12 * _pulse.value : 1,
              child: const Icon(Icons.phone_in_talk, color: kMagenta, size: 34),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                call.contact,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  shadows: [Shadow(color: kMagenta, blurRadius: 10)],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class NotificationsPanel extends StatelessWidget {
  const NotificationsPanel({super.key, required this.events, required this.flash, required this.onClear});
  final List<GameEvent> events;
  final Animation<double> flash;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final content = events.isEmpty
        ? const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'Sin mensajes. Cuando un NPC llame o escriba a V, aparecerá aquí.',
              style: TextStyle(color: kDim, fontSize: 12),
            ),
          )
        : Column(children: [for (final e in events.take(20)) _EventTile(key: ValueKey(e.id), event: e)]);
    return AnimatedBuilder(
      animation: flash,
      builder: (context, child) => HudPanel(
        label: 'Notificaciones de Night City',
        accent: kMagenta,
        glow: flash.value,
        trailing: events.isEmpty
            ? null
            : GestureDetector(
                onTap: onClear,
                child: const Text('LIMPIAR', style: TextStyle(color: kDim, fontSize: 10, letterSpacing: 1.5)),
              ),
        child: child ?? const SizedBox.shrink(),
      ),
      child: content,
    );
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({super.key, required this.event});
  final GameEvent event;

  @override
  Widget build(BuildContext context) {
    final time = event.receivedAt;
    final hhmm = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    final body = event.body;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: event.color.withValues(alpha: 0.06),
        border: Border(left: BorderSide(color: event.color, width: 3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(event.icon, color: event.color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(event.title, style: TextStyle(color: event.color, fontWeight: FontWeight.w700, fontSize: 13)),
                if (body.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(body, style: const TextStyle(color: Colors.white, fontSize: 13)),
                  ),
              ],
            ),
          ),
          Text(hhmm, style: const TextStyle(color: kDim, fontSize: 10)),
        ],
      ),
    );
  }
}

/// Banner superior que entra con un "glitch" cuando llega una alerta.
class AlertBanner extends StatefulWidget {
  const AlertBanner({super.key, required this.event, required this.onTap});
  final GameEvent event;
  final VoidCallback onTap;

  @override
  State<AlertBanner> createState() => _AlertBannerState();
}

class _AlertBannerState extends State<AlertBanner> with SingleTickerProviderStateMixin {
  late final AnimationController _in;

  @override
  void initState() {
    super.initState();
    _in = AnimationController(vsync: this, duration: const Duration(milliseconds: 420))..forward();
  }

  @override
  void dispose() {
    _in.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.event;
    return AnimatedBuilder(
      animation: _in,
      builder: (context, child) {
        final p = _in.value;
        final v = Curves.easeOutBack.transform(p);
        final jitter = p < 0.6 ? math.sin(p * 60) * 4 * (1 - p) : 0.0;
        return Transform.translate(
          offset: Offset(jitter, -80 * (1 - v)),
          child: Opacity(opacity: p, child: child),
        );
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: ShapeDecoration(
            color: const Color(0xF2120712),
            shape: BeveledRectangleBorder(
              side: BorderSide(color: e.color, width: 1.5),
              borderRadius: const BorderRadius.only(topLeft: Radius.circular(12), bottomRight: Radius.circular(12)),
            ),
            shadows: [BoxShadow(color: e.color.withValues(alpha: 0.55), blurRadius: 24)],
          ),
          child: Row(
            children: [
              Icon(e.icon, color: e.color, size: 30),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      e.title.toUpperCase(),
                      style: TextStyle(color: e.color, fontWeight: FontWeight.w900, letterSpacing: 1.5),
                    ),
                    if (e.body.isNotEmpty)
                      Text(
                        e.body,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Líneas de escaneo sutiles de fondo (estética CRT/HUD).
class ScanlinePainter extends CustomPainter {
  const ScanlinePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = Colors.white.withValues(alpha: 0.025);
    for (double y = 0; y < size.height; y += 4) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1), p);
    }
  }

  @override
  bool shouldRepaint(ScanlinePainter oldDelegate) => false;
}
