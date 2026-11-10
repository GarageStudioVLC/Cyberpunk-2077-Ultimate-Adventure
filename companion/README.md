# CP2077 Companion · telemetría en vivo al móvil

Prueba de concepto: Cyberpunk 2077 (PC) → servidor en la PC → app Flutter en el móvil, por la Wi‑Fi de casa.

```
Mod CET (init.lua) ──POST /telemetry ó telemetry.json──► server.js :3000 ──WebSocket──► app Flutter
```

| Pieza | Ruta | Qué hace |
|---|---|---|
| Mod CET | `mod/cp2077_companion/init.lua` | Lee el juego 5 veces por segundo y escucha llamadas, SMS y misiones |
| Servidor | `server/server.js` | Recibe el JSON, quita eventos duplicados y lo retransmite por WebSocket |
| App | `app/lib/main.dart` | HUD neón: salud, eurodólares, X/Y/Z + radar, NCPD, misión, vehículo, notificaciones |

## Puesta en marcha (10 minutos)

### 1. Servidor (PC)
```bash
cd companion/server
npm install
npm run demo        # datos simulados: prueba la app sin abrir el juego
```
Al arrancar imprime la IP que hay que poner en el móvil (`En la app pon: 192.168.x.x`).

Si Windows pregunta por el firewall, permite Node.js en **redes privadas** (o abre el puerto TCP 3000).

### 2. App (móvil)
```bash
flutter create --platforms=android,ios cp2077_companion
cp companion/app/pubspec.yaml cp2077_companion/
cp companion/app/lib/main.dart cp2077_companion/lib/
cd cp2077_companion
flutter pub get
flutter run --dart-define=PC_IP=192.168.1.50   # o edita kDefaultPcIp en main.dart
```
La IP también se cambia dentro de la app con el icono de red de la cabecera.

- **Android**: en `android/app/src/main/AndroidManifest.xml` añade `<uses-permission android:name="android.permission.INTERNET"/>` (para builds release) y `android:usesCleartextTraffic="true"` en `<application>` (es `ws://` sin TLS dentro de tu LAN).
- **iOS**: en `ios/Runner/Info.plist` añade `NSLocalNetworkUsageDescription` (texto libre) y `NSAppTransportSecurity → NSAllowsLocalNetworking = true`. La primera vez iOS pide permiso de "red local": acéptalo.

### 3. Mod (juego)
1. Instala [Cyber Engine Tweaks](https://www.nexusmods.com/cyberpunk2077/mods/107).
2. Copia la carpeta `mod/cp2077_companion` en `<Cyberpunk 2077>\bin\x64\plugins\cyber_engine_tweaks\mods\`.
3. Elige transporte:
   - **Sin plugins (recomendado para la PoC)**: el mod escribe `telemetry.json` en su carpeta. Arranca el servidor apuntando a ese archivo:
     ```bash
     node server.js --bridge "C:\...\mods\cp2077_companion\telemetry.json"
     ```
   - **HTTP POST real**: instala [RedHttpClient](https://github.com/rayshader/cp2077-red-httpclient) (+ RED4ext) y lanza el juego con `-no-tls`. El mod lo detecta solo y hace `POST http://localhost:3000/telemetry`. Si el POST falla 5 veces seguidas, vuelve al archivo automáticamente.
4. En el juego, abre el overlay de CET: la ventana **CP2077 Companion** muestra transporte, envíos, errores y si los hooks del teléfono se registraron.
5. En CET → Bindings tienes dos atajos de prueba: *simular llamada de Judy* y *colgar*. Disparan la alerta en el móvil sin esperar a una misión.

## Esquema JSON (v1)

Un snapshot completo por envío (5 Hz). Cualquier campo puede ser `null` si la API del juego no responde; la app lo tolera.

```json
{
  "v": 1, "type": "telemetry", "source": "cet",
  "sessionId": "1794273605", "seq": 1532, "ts": 1794273605,
  "player":   { "health": { "current": 312.4, "max": 420 }, "money": 12345, "level": 27 },
  "location": { "x": -1376.12, "y": 1270.46, "z": 32.5, "yaw": 91.3 },
  "vehicle":  { "name": "Quadra Type-66", "recordId": "Vehicle.v_sport1_quadra_turbo_player", "speedKmh": 84 },
  "wanted":   { "level": 2, "chasing": true },
  "quest":    { "id": "sq030_judy_romance", "title": "Todo es posible", "objective": "Habla con Judy" },
  "inventory":{ "equippedWeapon": { "name": "Malorian Arms 3516", "recordId": "Items.Preset_Silverhand_3516" } },
  "world":    { "hour": 22, "minute": 7, "inMenu": false },
  "phone":    { "activeCall": { "contactId": "judy", "contact": "Judy Álvarez", "phase": "incoming", "outgoing": false, "mode": "Audio" } },
  "events": [
    { "id": "1794273605-1", "kind": "phone_call",   "ts": 1794273605, "data": { "contactId": "judy", "contact": "Judy Álvarez", "phase": "incoming", "outgoing": false } },
    { "id": "1794273605-2", "kind": "text_message", "ts": 1794273605, "data": { "contactId": "panam", "contact": "Panam Palmer", "text": "¿Quedamos?", "fromPlayer": false } },
    { "id": "1794273605-3", "kind": "quest_update", "ts": 1794273605, "data": { "entryType": "objective", "id": "…", "title": "…" } }
  ]
}
```

- **Estado** (`player`, `location`, `vehicle`, `wanted`, `quest`, `inventory`, `world`, `phone`) se manda completo cada vez: si se pierde un paquete, el siguiente lo corrige.
- **Eventos** (`events`) llevan `id` único y el mod los repite durante 10 s; el servidor los entrega **una sola vez** a cada móvil. Para añadir un evento nuevo basta con `pushEvent("mi_evento", {...})` en el mod: el servidor lo reenvía sin cambios y la app lo muestra como genérico.
- **Versionado**: `v` sube solo si se rompe la compatibilidad. Añadir campos no la rompe.

### Mensajes del WebSocket (servidor → app)
| `type` | Cuándo | Contenido |
|---|---|---|
| `hello` | al conectar | `latest` (último snapshot) y `recentEvents` (últimos 30) |
| `telemetry` | cada snapshot | `data` = snapshot + solo los eventos nuevos |
| `status` | el juego aparece o desaparece (3 s sin datos) | `gameOnline` |
| `pong` | respuesta al `{"type":"ping"}` de la app | — |

### HTTP
- `POST /telemetry`: acepta el JSON con cualquier `Content-Type`. Responde `200 {ok, newEvents}`, `400` si el JSON es inválido y `422` si el esquema no es v1.
- `GET /state`: último snapshot y eventos recientes (útil para depurar desde el navegador).
- `GET /health`: contadores y estado.
- CORS abierto (`*`) y `Access-Control-Allow-Private-Network` para clientes web en la LAN.

## Qué hay que verificar en el juego

El servidor y la app están probados de punta a punta (modo demo y con el mod ejecutado contra APIs simuladas). Lo que solo se puede confirmar dentro del juego, y que el mod protege con `pcall` para que nunca rompa la partida:

| Dato | API usada | Confianza |
|---|---|---|
| Posición, salud, dinero, nivel | `GetWorldPosition`, `StatPoolsSystem`, `TransactionSystem` + `MarketSystem.Money()` | Alta (patrones habituales de CET) |
| Vehículo, búsqueda, hora | `GetMountedVehicle`, `PreventionSystem:GetHeatStageAsInt()`, `TimeSystem` | Media-alta |
| Llamadas de NPCs | `Observe("PhoneSystem", "OnTriggerCall")` → `caller`, `addressee`, `callPhase` | Media: el overlay de CET indica si el hook se registró |
| SMS nuevos y misiones | `Observe("JournalNotificationQueue", "OnJournalUpdate")` + `JournalManager` | Media: nombres de contacto y textos pueden necesitar ajuste |
| Arma equipada | `GetItemInSlot("AttachmentSlots.WeaponRight")` | Media |

Si algún dato sale `null` en `GET /state`, esa es la línea concreta del mod a ajustar.

## Siguientes pasos naturales
- **Mapa de Night City**: `RadarPainter` ya convierte coordenadas del juego a pantalla centradas en V; solo falta pintar una imagen del mapa con la misma escala.
- **Notificaciones nativas** con la app en segundo plano: añadir `flutter_local_notifications` y lanzarla desde `TelemetryService.alerts`.
- **Canal de vuelta** (móvil → juego): el WebSocket ya acepta mensajes; el mod puede leer órdenes de un archivo, igual que hace con la telemetría.
