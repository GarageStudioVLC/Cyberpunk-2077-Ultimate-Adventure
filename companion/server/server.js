/**
 * CP2077 Companion · Servidor intermediario (PC de juego)
 *
 *   Mod CET ──(POST /telemetry  ó  telemetry.json)──► server.js ──(WebSocket)──► móviles en la LAN
 *
 * Un solo puerto (3000) sirve HTTP y WebSocket. Uso:
 *   node server.js                                   # espera datos por POST
 *   node server.js --bridge "<ruta>/telemetry.json"  # además vigila el archivo que escribe el mod
 *   node server.js --demo                            # genera datos falsos para probar la app sin el juego
 *
 * Variables de entorno equivalentes: PORT, HOST, CP_BRIDGE_FILE, CP_DEMO=1.
 */
'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const express = require('express');
const { WebSocketServer, WebSocket } = require('ws');

// ---------------------------------------------------------------------------
//  Configuración
// ---------------------------------------------------------------------------
function argValue(flag) {
  const i = process.argv.indexOf(flag);
  return i !== -1 && process.argv[i + 1] && !process.argv[i + 1].startsWith('--') ? process.argv[i + 1] : null;
}

const CONFIG = {
  port: Number(argValue('--port') || process.env.PORT || 3000),
  host: argValue('--host') || process.env.HOST || '0.0.0.0',
  bridgeFile: argValue('--bridge') || process.env.CP_BRIDGE_FILE || null,
  demo: process.argv.includes('--demo') || process.env.CP_DEMO === '1',
  schemaVersion: 1,
  offlineAfterMs: 3000,     // sin datos durante este tiempo → juego "offline"
  logEveryMs: 2000,         // resumen de telemetría en consola como mucho cada 2 s
  eventHistory: 30,         // eventos recientes que recibe un móvil al conectarse
  seenEventCap: 1000,       // ids de eventos recordados para deduplicar
  maxClientBuffer: 1 << 20, // si un móvil va lento (>1 MB en cola) se salta frames sin eventos
};

// ---------------------------------------------------------------------------
//  Logs de consola
// ---------------------------------------------------------------------------
const C = { reset: '\x1b[0m', dim: '\x1b[2m', cyan: '\x1b[36m', yellow: '\x1b[33m', magenta: '\x1b[35m', red: '\x1b[31m', green: '\x1b[32m' };
const time = () => new Date().toLocaleTimeString('es-ES', { hour12: false });
const log = (color, icon, msg) => console.log(`${C.dim}${time()}${C.reset} ${color}${icon} ${msg}${C.reset}`);
const fmtNum = (n) => (typeof n === 'number' ? n.toLocaleString('es-ES', { maximumFractionDigits: 1 }) : '—');
const clampStars = (n) => Math.max(0, Math.min(5, n));
const stars = (n) => (typeof n === 'number' ? '★'.repeat(clampStars(n)) + '☆'.repeat(5 - clampStars(n)) : '—');

// ---------------------------------------------------------------------------
//  Estado y procesamiento de telemetría
// ---------------------------------------------------------------------------
const state = {
  latest: null,           // último snapshot (sin eventos)
  lastReceivedAt: 0,
  gameOnline: false,
  lastLogAt: 0,
  received: 0,
  rejected: 0,
  seenEvents: new Map(),  // id → timestamp (orden de inserción = LRU sencillo)
  recentEvents: [],
};

function validateSnapshot(data) {
  if (!data || typeof data !== 'object' || Array.isArray(data)) return 'el cuerpo no es un objeto JSON';
  if (data.type !== 'telemetry') return `type inesperado: ${data.type}`;
  if (data.v !== CONFIG.schemaVersion) return `versión de esquema ${data.v} no soportada (esperada ${CONFIG.schemaVersion})`;
  return null;
}

function takeNewEvents(events) {
  if (!Array.isArray(events)) return [];
  const fresh = [];
  for (const ev of events) {
    if (!ev || typeof ev.id !== 'string' || state.seenEvents.has(ev.id)) continue;
    state.seenEvents.set(ev.id, Date.now());
    if (state.seenEvents.size > CONFIG.seenEventCap) {
      state.seenEvents.delete(state.seenEvents.keys().next().value);
    }
    fresh.push(ev);
  }
  return fresh;
}

function logEvent(ev) {
  const d = ev.data || {};
  switch (ev.kind) {
    case 'phone_call':
      if (d.phase === 'incoming') log(C.magenta, '📞', `Llamada entrante de NPC: ${d.contact}`);
      else if (d.phase === 'active') log(C.magenta, '📞', `${d.outgoing ? 'V llama a' : 'En llamada con'} ${d.contact}`);
      else if (d.phase === 'ended') log(C.dim, '📴', `Llamada terminada con ${d.contact}`);
      else log(C.magenta, '📞', `Llamada (${d.phase}) · ${d.contact}`);
      break;
    case 'text_message':
      log(C.magenta, '💬', `${d.fromPlayer ? 'V escribe a' : 'Mensaje de'} ${d.contact}: ${String(d.text || '').replace(/\s+/g, ' ').slice(0, 80)}`);
      break;
    case 'quest_update':
      log(C.yellow, '🗺️ ', `Diario actualizado (${d.entryType}): ${d.title || d.id}`);
      break;
    default:
      log(C.yellow, '✦', `Evento ${ev.kind}: ${JSON.stringify(d)}`);
  }
}

function logSnapshot(s) {
  const now = Date.now();
  if (now - state.lastLogAt < CONFIG.logEveryMs) return;
  state.lastLogAt = now;
  const loc = s.location || {};
  const hp = (s.player && s.player.health) || {};
  const parts = [
    `Datos de V recibidos · V en X=${fmtNum(loc.x)}, Y=${fmtNum(loc.y)}, Z=${fmtNum(loc.z)}`,
    `Salud ${fmtNum(hp.current)}/${fmtNum(hp.max)}`,
    `€$ ${fmtNum(s.player && s.player.money)}`,
    `Búsqueda ${stars(s.wanted && s.wanted.level)}`,
  ];
  if (s.vehicle) parts.push(`🚗 ${s.vehicle.name} ${fmtNum(s.vehicle.speedKmh)} km/h`);
  if (s.quest && s.quest.title) parts.push(`Misión: ${s.quest.title}`);
  log(C.cyan, '📍', parts.join(' · '));
}

function setOnline(online) {
  if (state.gameOnline === online) return;
  state.gameOnline = online;
  log(online ? C.green : C.red, online ? '🟢' : '🔴', online ? 'Juego conectado: llegan datos de telemetría' : 'Sin datos del juego (¿pausa, menú o juego cerrado?)');
  broadcast({ type: 'status', gameOnline: online, ts: Date.now() });
}

/** Punto único de entrada: lo usan POST /telemetry, el archivo puente y el modo demo. */
function ingest(data, origin) {
  const problem = validateSnapshot(data);
  if (problem) {
    state.rejected += 1;
    return { ok: false, error: problem };
  }
  state.received += 1;
  state.lastReceivedAt = Date.now();
  setOnline(true);

  const newEvents = takeNewEvents(data.events);
  const { events, ...snapshot } = data;
  snapshot.receivedAt = state.lastReceivedAt;
  snapshot.origin = origin;
  state.latest = snapshot;

  for (const ev of newEvents) {
    logEvent(ev);
    state.recentEvents.push(ev);
  }
  if (state.recentEvents.length > CONFIG.eventHistory) {
    state.recentEvents.splice(0, state.recentEvents.length - CONFIG.eventHistory);
  }

  logSnapshot(snapshot);
  // Cada mensaje lleva el snapshot completo; "events" solo trae los eventos nuevos.
  broadcast({ type: 'telemetry', data: { ...snapshot, events: newEvents } });
  return { ok: true, newEvents: newEvents.length };
}

// ---------------------------------------------------------------------------
//  HTTP (Express)
// ---------------------------------------------------------------------------
const app = express();
app.disable('x-powered-by');

// CORS abierto para la LAN + Private Network Access (Chrome) para clientes web.
app.use((req, res, next) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  res.setHeader('Access-Control-Allow-Private-Network', 'true');
  if (req.method === 'OPTIONS') return res.sendStatus(204);
  next();
});

// El mod puede mandar el JSON con cualquier Content-Type (o ninguno): se lee como texto.
app.use(express.text({ type: () => true, limit: '1mb' }));

app.post('/telemetry', (req, res) => {
  let data = req.body;
  if (typeof data === 'string') {
    try {
      data = JSON.parse(data);
    } catch (err) {
      state.rejected += 1;
      return res.status(400).json({ ok: false, error: `JSON inválido: ${err.message}` });
    }
  }
  const result = ingest(data, 'http');
  res.status(result.ok ? 200 : 422).json(result);
});

app.get('/state', (_req, res) => {
  res.json({ gameOnline: state.gameOnline, latest: state.latest, recentEvents: state.recentEvents });
});

app.get('/health', (_req, res) => {
  res.json({
    ok: true,
    gameOnline: state.gameOnline,
    clients: wss.clients.size,
    received: state.received,
    rejected: state.rejected,
    lastReceivedAt: state.lastReceivedAt || null,
    bridgeFile: CONFIG.bridgeFile,
    demo: CONFIG.demo,
  });
});

app.get('/', (_req, res) => {
  res.type('text').send('CP2077 Companion server: POST /telemetry · GET /state · GET /health · WebSocket en este mismo puerto');
});

const server = http.createServer(app);

// ---------------------------------------------------------------------------
//  WebSocket (mismo puerto)
// ---------------------------------------------------------------------------
const wss = new WebSocketServer({ server, perMessageDeflate: false });

function broadcast(message) {
  if (wss.clients.size === 0) return;
  const payload = JSON.stringify(message);
  const droppable = message.type === 'telemetry' && message.data.events.length === 0;
  for (const client of wss.clients) {
    if (client.readyState !== WebSocket.OPEN) continue;
    if (droppable && client.bufferedAmount > CONFIG.maxClientBuffer) continue;
    client.send(payload);
  }
}

wss.on('connection', (socket, req) => {
  const who = (req.socket.remoteAddress || '?').replace('::ffff:', '');
  socket.isAlive = true;
  socket.on('pong', () => { socket.isAlive = true; });
  socket.on('close', () => log(C.dim, '📱', `Móvil desconectado: ${who} (quedan ${wss.clients.size})`));
  socket.on('error', (err) => log(C.red, '⚠', `Error WebSocket ${who}: ${err.message}`));
  socket.on('message', (raw) => {
    // Canal de vuelta reservado para órdenes futuras desde el móvil; hoy solo responde a ping.
    let msg;
    try {
      msg = JSON.parse(raw.toString());
    } catch {
      return;
    }
    if (msg && msg.type === 'ping') socket.send(JSON.stringify({ type: 'pong', ts: Date.now() }));
  });
  log(C.green, '📱', `Móvil conectado: ${who} (total ${wss.clients.size})`);
  socket.send(JSON.stringify({
    type: 'hello',
    schemaVersion: CONFIG.schemaVersion,
    gameOnline: state.gameOnline,
    latest: state.latest,
    recentEvents: state.recentEvents,
  }));
});

const heartbeat = setInterval(() => {
  for (const client of wss.clients) {
    if (!client.isAlive) { client.terminate(); continue; }
    client.isAlive = false;
    client.ping();
  }
  if (state.gameOnline && Date.now() - state.lastReceivedAt > CONFIG.offlineAfterMs) setOnline(false);
}, 1000);

// ---------------------------------------------------------------------------
//  Archivo puente (el mod escribe telemetry.json cuando no hay RedHttpClient)
// ---------------------------------------------------------------------------
function startBridge(file) {
  const resolved = path.resolve(file);
  let lastMtime = 0;
  let warnedMissing = false;
  let busy = false;
  const read = () => {
    if (busy) return;
    busy = true;
    fs.stat(resolved, (statErr, stat) => {
      if (statErr) {
        if (!warnedMissing) {
          log(C.yellow, '…', `Esperando a que el mod cree ${resolved}`);
          warnedMissing = true;
        }
        busy = false;
        return;
      }
      warnedMissing = false;
      if (stat.mtimeMs === lastMtime) { busy = false; return; }
      fs.readFile(resolved, 'utf8', (readErr, text) => {
        busy = false;
        if (readErr || !text) return;
        let data;
        try {
          data = JSON.parse(text);
        } catch {
          return; // el mod estaba escribiendo: se relee en el siguiente ciclo
        }
        lastMtime = stat.mtimeMs;
        const result = ingest(data, 'file');
        if (!result.ok) log(C.red, '⚠', `Archivo puente rechazado: ${result.error}`);
      });
    });
  };
  const timer = setInterval(read, 100);
  log(C.cyan, '📂', `Vigilando archivo puente: ${resolved}`);
  return () => clearInterval(timer);
}

// ---------------------------------------------------------------------------
//  Modo demo: simula a V conduciendo por Night City y recibiendo llamadas
// ---------------------------------------------------------------------------
function startDemo() {
  const sessionId = `demo-${Date.now()}`;
  const contacts = [
    ['judy', 'Judy Álvarez', 'Ven a Lizzie\'s cuando puedas, tengo algo que enseñarte.'],
    ['panam', 'Panam Palmer', 'Los Aldecaldos te esperan en las Badlands.'],
    ['reed', 'Solomon Reed', 'Tenemos que hablar. En persona.'],
    ['rogue', 'Rogue', 'Tengo un trabajo para ti en el Afterlife.'],
  ];
  const quests = [
    ['Todo es posible', 'Habla con Judy'],
    ['Gatitos', 'Reúnete con Panam en el Sunset Motel'],
    ['Agente libre', 'Espera la llamada de Reed'],
  ];
  const center = { x: -1376, y: 1270 }; // alrededor del Megaedificio H10 (Watson)
  const t0 = Date.now();
  let seq = 0;
  let eventSeq = 0;
  let money = 12500;
  let wanted = 0;
  let activeCall = null;
  let pending = [];

  const pushEvent = (kind, data) => {
    eventSeq += 1;
    pending.push({ id: `${sessionId}-${eventSeq}`, kind, ts: Math.floor(Date.now() / 1000), data, sentAt: Date.now() });
  };

  const tick = setInterval(() => {
    const t = (Date.now() - t0) / 1000;
    seq += 1;
    const angle = t / 20;
    const hpMax = 420;
    const hp = Math.round(hpMax * (0.55 + 0.45 * Math.abs(Math.sin(t / 9))) * 10) / 10;
    if (seq % 25 === 0) money += Math.floor(Math.random() * 900);
    pending = pending.filter((e) => Date.now() - e.sentAt < 10000);
    const questIndex = Math.floor(t / 45) % quests.length;
    const quest = quests[questIndex];
    const driving = Math.floor(t / 30) % 2 === 0;
    ingest({
      v: 1,
      type: 'telemetry',
      source: 'demo',
      sessionId,
      seq,
      ts: Math.floor(Date.now() / 1000),
      player: { health: { current: hp, max: hpMax }, money, level: 27 },
      location: {
        x: Math.round((center.x + Math.cos(angle) * 600) * 100) / 100,
        y: Math.round((center.y + Math.sin(angle) * 600) * 100) / 100,
        z: 32.5,
        yaw: Math.round(((angle * 180) / Math.PI + 90) % 360),
      },
      vehicle: driving
        ? { name: 'Quadra Type-66 "Javelina"', recordId: 'Vehicle.v_sport1_quadra_turbo_player', speedKmh: Math.round(60 + 40 * Math.sin(t / 5)) }
        : null,
      wanted: { level: wanted, chasing: wanted > 0 },
      quest: { id: `demo_quest_${questIndex}`, title: quest[0], objective: quest[1] },
      inventory: { equippedWeapon: { name: 'Malorian Arms 3516', recordId: 'Items.Preset_Silverhand_3516' } },
      world: { hour: Math.floor(t / 10) % 24, minute: Math.floor(t * 6) % 60, inMenu: false },
      phone: { activeCall },
      events: pending.map(({ sentAt, ...e }) => e),
    }, 'demo');
  }, 200);

  // Guion de eventos: cada 20 s alguien llama o escribe, y la policía aparece de vez en cuando.
  let step = 0;
  const timeouts = new Set();
  const later = (ms, fn) => {
    const id = setTimeout(() => { timeouts.delete(id); fn(); }, ms);
    timeouts.add(id);
  };
  const script = setInterval(() => {
    const [id, name, text] = contacts[step % contacts.length];
    if (step % 2 === 0) {
      const call = { contactId: id, contact: name, phase: 'incoming', outgoing: false, mode: 'Audio' };
      activeCall = call;
      pushEvent('phone_call', call);
      later(5000, () => {
        activeCall = { ...call, phase: 'active' };
        pushEvent('phone_call', activeCall);
      });
      later(12000, () => {
        activeCall = null;
        pushEvent('phone_call', { ...call, phase: 'ended' });
      });
    } else {
      pushEvent('text_message', { contactId: id, contact: name, text, fromPlayer: false });
    }
    wanted = step % 3 === 2 ? 1 + Math.floor(Math.random() * 4) : 0;
    step += 1;
  }, 20000);

  later(3000, () => {
    pushEvent('text_message', { contactId: 'judy', contact: 'Judy Álvarez', text: 'Demo en marcha: si ves esto en el móvil, todo funciona.', fromPlayer: false });
  });

  log(C.yellow, '🎮', 'Modo demo activo: datos simulados cada 200 ms, llamada o SMS cada 20 s');
  return () => {
    clearInterval(tick);
    clearInterval(script);
    timeouts.forEach(clearTimeout);
  };
}

// ---------------------------------------------------------------------------
//  Arranque
// ---------------------------------------------------------------------------
function lanAddresses() {
  return Object.values(os.networkInterfaces())
    .flat()
    .filter((i) => i && i.family === 'IPv4' && !i.internal)
    .map((i) => i.address);
}

const stoppers = [];

server.on('error', (err) => {
  if (err.code === 'EADDRINUSE') log(C.red, '✖', `El puerto ${CONFIG.port} ya está en uso. Cierra el otro proceso o usa --port.`);
  else log(C.red, '✖', err.message);
  process.exit(1);
});

server.listen(CONFIG.port, CONFIG.host, () => {
  console.log(`\n${C.cyan}  ▓▒░ CP2077 COMPANION SERVER ░▒▓${C.reset}`);
  log(C.green, '✔', `HTTP + WebSocket escuchando en ${CONFIG.host}:${CONFIG.port}`);
  log(C.dim, '→', `Mod CET: POST http://localhost:${CONFIG.port}/telemetry`);
  const ips = lanAddresses();
  if (ips.length === 0) log(C.yellow, '⚠', 'No se detectó IP de LAN: ¿estás conectado al Wi-Fi/cable?');
  for (const ip of ips) log(C.green, '📱', `En la app pon:  ${ip}  (ws://${ip}:${CONFIG.port})`);
  if (CONFIG.bridgeFile) stoppers.push(startBridge(CONFIG.bridgeFile));
  if (CONFIG.demo) stoppers.push(startDemo());
  if (!CONFIG.bridgeFile && !CONFIG.demo) log(C.dim, '…', 'Esperando telemetría del juego (usa --bridge si el mod escribe telemetry.json)');
});

function shutdown() {
  log(C.dim, '■', 'Cerrando servidor…');
  clearInterval(heartbeat);
  stoppers.forEach((stop) => stop());
  for (const client of wss.clients) client.close(1001, 'server shutdown');
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 1500).unref();
}
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
