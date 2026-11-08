// Servidor LOCAL del panel: sirve panel.html y permite cambiar el modo de eleccion de modelos desde el boton.
// Escucha solo en 127.0.0.1 (nada sale de tu maquina). Endpoints: GET / (panel), GET/POST /api/config, POST /api/regenerar (vuelve a generar el panel).
// Uso: node panel-servidor.mjs   (o doble clic en iniciar-panel.cmd). Puerto: MULTIIA_PUERTO (por defecto 8765).
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { conCandado, matarVerificado } from './robustez.mjs';

const PUERTO = Number(process.env.MULTIIA_PUERTO || 8765);
const datos = /^([A-Za-z]:[\\/]|\\\\)/.test(process.env.MULTIIA_DATOS || '') ? process.env.MULTIIA_DATOS : path.join(os.homedir(), '.multi-ia-orquestador');   // 2.3.1: solo rutas absolutas
const cfgPath = path.join(datos, 'config.json');
const panelPath = path.join(datos, 'panel.html');
const MAX_CUENTAS = 3;
const CALIDADES = ['auto', 'economica', 'equilibrada', 'maxima'];
const INTENSIDADES = ['bajo', 'medio', 'alto', 'automatico'];
const panelScript = path.join(path.dirname(fileURLToPath(import.meta.url)), 'panel.ps1');   // ruta fija: el navegador nunca elige que se ejecuta
const ESFUERZOS = ['low', 'medium', 'high', 'xhigh', 'max', 'ultra'];
const SLUG = /^[A-Za-z0-9._-]{0,80}$/;

// Debe coincidir con Get-ConfigPorDefecto de _comun.ps1.
const defecto = () => ({
  version: 1, activo: true, modo: 'automatico', calidad: 'equilibrada', intensidad: 'automatico', intensidad_chats: {},
  cuentas: [
    { id: 'codex', tipo: 'codex', etiqueta: 'ChatGPT Plus', activa: true, home: null },
    { id: 'agy', tipo: 'agy', etiqueta: 'Google · Antigravity', activa: true, home: null },
  ],
  manual: { codex: { modelo: '', esfuerzo: 'medium' }, agy: { modelo: 'gemini-3.8-flash-medium' } },
  ahorro: { umbral_aviso: 60, umbral_bloqueo: 85, guardia_activa: true, ctx_aviso: 150000, ctx_alto: 300000, cache_ttl_min: 55, handoff_inicio: true },
});

function leer() {
  const d = defecto();
  let c;
  try { c = JSON.parse(fs.readFileSync(cfgPath, 'utf8').replace(/^﻿/, '')); } catch (e) { if (!(e && e.code === 'ENOENT')) { d._corrupta = true; d.activo = false; } return d; }   // 2.3.1 (Codex #5): ilegible = PAUSADO hasta repararla   // v1.9.2: ilegible = se avisa (no se oculta)
  if (!c || typeof c !== 'object' || Array.isArray(c)) { d._corrupta = true; d.activo = false; return d; }
  c.activo = c.activo !== false;
  if (!['automatico', 'manual'].includes(c.modo)) c.modo = 'automatico';
  if (!CALIDADES.includes(c.calidad)) c.calidad = 'equilibrada';
  if (!INTENSIDADES.includes(c.intensidad)) c.intensidad = 'automatico';   // 2.0: configs viejas heredan Automatico
  if (!c.intensidad_chats || typeof c.intensidad_chats !== 'object' || Array.isArray(c.intensidad_chats)) c.intensidad_chats = {};
  const obj = x => x && typeof x === 'object' && !Array.isArray(x);   // tipos invalidos en config.json no deben tirar el proceso
  if (!obj(c.manual)) c.manual = d.manual;
  if (!obj(c.manual.codex)) c.manual.codex = d.manual.codex;
  if (!obj(c.manual.agy)) c.manual.agy = d.manual.agy;
  if (!obj(c.ahorro)) c.ahorro = d.ahorro;
  if (!Array.isArray(c.cuentas)) c.cuentas = d.cuentas;
  c.cuentas = c.cuentas.filter(obj);
  for (const k of Object.keys(d.ahorro)) if (c.ahorro[k] === undefined) c.ahorro[k] = d.ahorro[k];   // campos nuevos en configs viejas
  return c;
}

// Escritura atomica: archivo temporal + renombrar.
function guardar(c) {
  fs.mkdirSync(datos, { recursive: true });
  delete c._corrupta;
  // v1.9.2: si config.json esta corrupta, antes de pisarla se guarda una copia en config.json.corrupta.
  // Si la copia falla NO se pisa: el error llega al llamador (400) y config.json corrupta queda intacta.
  if (leer()._corrupta) { try { fs.copyFileSync(cfgPath, `${cfgPath}.corrupta`); } catch (e) { throw new Error(`config.json esta corrupta y no se pudo guardar la copia (${e.code || e.message}); no se modifica nada`); } }
  const tmp = `${cfgPath}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(c, null, 2), 'utf8');
  fs.renameSync(tmp, cfgPath);
}

// Candado de config.json compartido con _comun.ps1 (Lock-Config): archivo config.json.lock creado en forma exclusiva; si tiene mas de 15 s se considera huerfano.
// 2.0.1: asincrono (sin Atomics.wait en el hilo principal) y solo se retira un candado viejo si su dueño ya no existe (ver robustez.mjs).
function conLockConfig(fn) {
  fs.mkdirSync(datos, { recursive: true });
  return conCandado(`${cfgPath}.lock`, fn);
}
// Corta un hijo por tiempo y verifica que de verdad terminó (arbol incluido); si no, lo deja en el registro.
// 2.0.1 (Codex #4): al vencer, además de cerrar el árbol, se RECHAZA la promesa pendiente (alVencer): si un nieto heredó las tuberías, 'close' no llega nunca y la petición quedaba colgada para siempre.
function cortarPorTiempo(hijo, ms, nombre, alVencer) {
  return setTimeout(() => {
    // 2.2.0 (Codex #4 / auditoría 2.1.0 #12): si el cierre falla o lanza, igual se avisa (alVencer) para no dejar la petición colgada.
    matarVerificado(hijo).catch(() => ({ terminado: false, intentos: 0, vivos: [] })).then((r) => {
      if (!r.terminado) console.error(`${nombre}: el proceso ${hijo.pid} no terminó tras ${r.intentos} intentos de cierre${r.vivos && r.vivos.length ? ' (descendientes vivos: ' + r.vivos.join(', ') + ')' : ''}`);
      if (alVencer) alVencer(new Error(`${nombre} superó el límite de ${Math.round(ms / 1000)} s y se canceló`), !!r.terminado);
    });
  }, ms);
}
// Tope de salida acumulada (Codex #5): una salida descontrolada no puede crecer sin límite en memoria.
const MAX_SALIDA = 32 * 1024 * 1024;
const DESBORDE = Symbol('desborde');   // 2.2.0: salida truncada = error, nunca un resultado "exitoso" incompleto
const acumular = (prev, d) => (prev === DESBORDE || prev.length + d.length > MAX_SALIDA ? DESBORDE : prev + d);

// Aplica un cambio parcial validado. Lanza Error con un mensaje claro si algo no es valido.
function aplicar(c, cambio) {
  if (cambio.activo !== undefined) {
    if (typeof cambio.activo !== 'boolean') throw new Error('activo debe ser true o false');
    c.activo = cambio.activo;
  }
  if (cambio.modo !== undefined) {
    if (!['automatico', 'manual'].includes(cambio.modo)) throw new Error('modo invalido');
    c.modo = cambio.modo;
  }
  if (cambio.calidad !== undefined) {
    if (!CALIDADES.includes(cambio.calidad)) throw new Error('calidad invalida');
    c.calidad = cambio.calidad;
  }
  if (cambio.intensidad !== undefined) {   // intensidad global
    if (!INTENSIDADES.includes(cambio.intensidad)) throw new Error('intensidad invalida');
    c.intensidad = cambio.intensidad;
  }
  if (cambio.intensidad_chat !== undefined) {   // { chat: '<id>', valor: 'bajo'|'medio'|'alto'|'automatico'|null (null = heredar la global) }
    const ic = cambio.intensidad_chat;
    if (!ic || typeof ic.chat !== 'string' || !/^[\w.-]{1,80}$/.test(ic.chat) || ['__proto__', 'constructor', 'prototype'].includes(ic.chat)) throw new Error('chat invalido');
    if (ic.valor === null) delete c.intensidad_chats[ic.chat];
    else if (INTENSIDADES.includes(ic.valor)) c.intensidad_chats[ic.chat] = ic.valor;
    else throw new Error('intensidad invalida');
  }
  const m = cambio.manual;
  if (m) {
    if (m.codex) {
      if (m.codex.modelo !== undefined) { if (typeof m.codex.modelo !== 'string' || !SLUG.test(m.codex.modelo)) throw new Error('modelo de Codex invalido'); c.manual.codex.modelo = m.codex.modelo; }
      if (m.codex.esfuerzo !== undefined) { if (!ESFUERZOS.includes(m.codex.esfuerzo)) throw new Error('esfuerzo de Codex invalido'); c.manual.codex.esfuerzo = m.codex.esfuerzo; }
    }
    if (m.agy && m.agy.modelo !== undefined) {
      if (typeof m.agy.modelo !== 'string' || !SLUG.test(m.agy.modelo) || !m.agy.modelo) throw new Error('modelo de Antigravity invalido');
      c.manual.agy.modelo = m.agy.modelo;
    }
  }
  if (cambio.ahorro) {   // solo interruptores booleanos conocidos (los umbrales numericos se cambian a mano en config.json)
    for (const k of ['guardia_activa', 'handoff_inicio']) {
      if (cambio.ahorro[k] !== undefined) { if (typeof cambio.ahorro[k] !== 'boolean') throw new Error(`${k} debe ser true o false`); c.ahorro[k] = cambio.ahorro[k]; }
    }
  }
  if (Array.isArray(cambio.cuentas)) {
    for (const x of cambio.cuentas) {
      const cta = c.cuentas.find((k) => k.id === x.id);
      if (!cta) throw new Error(`no existe la cuenta '${x.id}'`);
      if (typeof x.activa !== 'boolean') throw new Error('activa debe ser true o false');
      cta.activa = x.activa;
    }
    if (c.cuentas.filter((k) => k.activa).length > MAX_CUENTAS) throw new Error(`maximo ${MAX_CUENTAS} cuentas activas`);
  }
  return c;
}

const hosts = new Set([`127.0.0.1:${PUERTO}`, `localhost:${PUERTO}`]);
const cabeceras = {
  'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer',
  'Content-Security-Policy': "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'none'",
};
const responder = (res, codigo, tipo, cuerpo) => { res.writeHead(codigo, { ...cabeceras, 'Content-Type': tipo }); res.end(cuerpo); };
const json = (res, codigo, obj) => responder(res, codigo, 'application/json; charset=utf-8', JSON.stringify(obj));

// --- Chats (1.9.0): corre chats.ps1 (ruta fija) y guarda el resultado en memoria. El navegador nunca elige que se ejecuta.
// Cache por formato; ?refrescar=1 fuerza una lectura nueva; una sola corrida a la vez (las demas esperan la misma promesa).
const chatsScript = path.join(path.dirname(fileURLToPath(import.meta.url)), 'chats.ps1');
const TTL_CHATS_MS = 20000;
const cacheChats = new Map();   // formato -> { t, texto }
const enCurso = new Map();      // formato -> Promise
let cola = Promise.resolve();   // cola global: serializa las corridas
function correrChats(formato, refrescar) {
  const c = cacheChats.get(formato);
  if (!refrescar && c && Date.now() - c.t < TTL_CHATS_MS) return Promise.resolve({ ...c, cache: true });
  if (enCurso.has(formato)) return enCurso.get(formato);
  // una sola corrida de chats.ps1 a la vez entre formatos (comparten el cache de transcripts)
  const previa = cola;
  const p = previa.catch(() => {}).then(() => new Promise((resolve, reject) => {
    const hijo = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', chatsScript, '-Formato', formato], { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let out = '';
    hijo.stdout.setEncoding('utf8');
    hijo.stdout.on('data', (d) => { out = acumular(out, d); });
    hijo.stderr.resume();   // vaciar stderr para que el hijo nunca quede bloqueado
    const corte = cortarPorTiempo(hijo, 120000, 'chats.ps1', (err, terminado) => { reject(err); if (!terminado) console.error(err.message + ' (el proceso no respondió al cierre; se libera igual la petición)'); });
    hijo.on('error', (e) => { clearTimeout(corte); reject(e); });
    hijo.on('close', (cod) => {   // 'close' = ya se vaciaron los streams
      clearTimeout(corte);
      if (out === DESBORDE) return reject(new Error('chats.ps1 produjo una salida demasiado grande'));
      if (cod !== 0 || !out.trim()) return reject(new Error(`chats.ps1 terminó con código ${cod}`));
      const r = { t: Date.now(), texto: out };
      cacheChats.set(formato, r); resolve({ ...r, cache: false });
    });
  })).finally(() => enCurso.delete(formato));
  cola = p;
  enCurso.set(formato, p);
  return p;
}
const consulta = (u) => new URLSearchParams((u.split('?')[1]) || '');

// --- Ahorro (2.0): corre ahorro.ps1 (ruta fija) y guarda el resultado 120 s (un solo cálculo global). El id de chat se valida (solo [\w.-]) antes de pasarlo como argumento.
const ahorroScript = path.join(path.dirname(fileURLToPath(import.meta.url)), 'ahorro.ps1');
const TTL_AHORRO_MS = 120000;   // ahorro.ps1 lee transcripts: tarda 15-60 s, se cachea 2 min
const cacheAhorro = new Map();   // chat ('' = global) -> { t, texto }
const enCursoAhorro = new Map();
function correrAhorro(chatPedido, refrescar) {
  // Auditoría cruzada 2.0: un solo cálculo global compartido (el resultado ya trae chats[]); así no se lanzan N procesos ni crece la caché por id.
  const chat = '';
  const c = cacheAhorro.get(chat);
  if (!refrescar && c && Date.now() - c.t < TTL_AHORRO_MS) return Promise.resolve({ ...c, cache: true });
  if (enCursoAhorro.has(chat)) return enCursoAhorro.get(chat);
  const p = new Promise((resolve, reject) => {
    const args = ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ahorroScript];
    if (chat) args.push('-Chat', chat);
    const hijo = spawn('powershell.exe', args, { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let out = '';
    hijo.stdout.setEncoding('utf8');
    hijo.stdout.on('data', (d) => { out = acumular(out, d); });
    hijo.stderr.resume();
    const corte = cortarPorTiempo(hijo, 120000, 'ahorro.ps1', (err, terminado) => { reject(err); if (!terminado) console.error(err.message + ' (el proceso no respondió al cierre; se libera igual la petición)'); });
    hijo.on('error', (e) => { clearTimeout(corte); reject(e); });
    hijo.on('close', (cod) => {
      clearTimeout(corte);
      if (out === DESBORDE) return reject(new Error('ahorro.ps1 produjo una salida demasiado grande'));
      if (cod !== 0 || !out.trim()) return reject(new Error(`ahorro.ps1 terminó con código ${cod}`));
      const r = { t: Date.now(), texto: out };
      cacheAhorro.set(chat, r); resolve({ ...r, cache: false });
    });
  }).finally(() => enCursoAhorro.delete(chat));
  enCursoAhorro.set(chat, p);
  return p;
}

let regenerando = null;   // 2.2.0 (Codex #3): token de la corrida en curso; solo esa corrida lo libera (antes un exit tardío liberaba la corrida siguiente)
http.createServer((req, res) => {
  // Anti DNS-rebinding / CSRF: solo se acepta el host local exacto y, en POST, el mismo origen.
  if (!hosts.has(req.headers.host || '')) return json(res, 403, { error: 'host no permitido' });
  const url = (req.url || '/').split('?')[0];

  if (req.method === 'GET' && (url === '/' || url === '/panel')) {
    try { return responder(res, 200, 'text/html; charset=utf-8', fs.readFileSync(panelPath)); }
    catch (e) { if (e && e.code === 'ENOENT') return responder(res, 404, 'text/plain; charset=utf-8', 'Todavía no hay panel. Pedile a Claude que lo arme (panel.ps1) y recargá esta página.'); return responder(res, 500, 'text/plain; charset=utf-8', 'No se pudo leer el panel: ' + (e && e.code || 'error')); }
  }
  if (req.method === 'GET' && url === '/api/config') { try { return json(res, 200, leer()); } catch (e) { return json(res, 500, { error: 'config ilegible: ' + e.message }); } }
  if (req.method === 'GET' && (url === '/api/chats' || url === '/api/export')) {
    const q = consulta(req.url || '');
    const md = url === '/api/export' && q.get('formato') === 'md';
    correrChats(md ? 'md' : 'json', q.get('refrescar') === '1').then((r) => {
      if (url === '/api/export') {
        const ext = md ? 'md' : 'json';
        res.writeHead(200, { ...cabeceras, 'Content-Type': md ? 'text/markdown; charset=utf-8' : 'application/json; charset=utf-8', 'Content-Disposition': `attachment; filename="multi-ia-chats.${ext}"` });
        return res.end(r.texto);
      }
      res.writeHead(200, { ...cabeceras, 'Content-Type': 'application/json; charset=utf-8', 'X-Multiia-Cache': r.cache ? 'hit' : 'miss', 'X-Multiia-Generado': new Date(r.t).toISOString() });
      res.end(r.texto);
    }).catch((e) => json(res, 500, { error: e.message }));
    return;
  }
  if (req.method === 'GET' && url === '/api/ahorro') {
    const q = consulta(req.url || '');
    const chat = q.get('chat') || '';
    if (chat && (!/^[\w.-]{1,80}$/.test(chat))) return json(res, 400, { error: 'chat invalido' });
    correrAhorro(chat, q.get('refrescar') === '1').then((r) => {
      res.writeHead(200, { ...cabeceras, 'Content-Type': 'application/json; charset=utf-8', 'X-Multiia-Cache': r.cache ? 'hit' : 'miss' });
      res.end(r.texto);
    }).catch((e) => json(res, 500, { error: e.message }));
    return;
  }
  if (req.method === 'POST' && url === '/api/config') {
    const origen = req.headers.origin;
    if (origen && origen !== `http://${req.headers.host}`) return json(res, 403, { error: 'origen no permitido' });
    if (!String(req.headers['content-type'] || '').startsWith('application/json')) return json(res, 415, { error: 'se espera application/json' });
    let cuerpo = '';
    req.on('data', (d) => { cuerpo += d; if (cuerpo.length > 10000) req.destroy(); });
    req.on('end', async () => {
      try {
        const cambio = JSON.parse(cuerpo || '{}');
        const c = await conLockConfig(() => { const x = aplicar(leer(), cambio); guardar(x); return x; });   // leer-modificar-guardar dentro del mismo candado que usa config.ps1
        json(res, 200, c);
      } catch (e) { json(res, 400, { error: e.message }); }
    });
    return;
  }
  if (req.method === 'POST' && url === '/api/regenerar') {
    const origen = req.headers.origin;
    if (origen && origen !== `http://${req.headers.host}`) return json(res, 403, { error: 'origen no permitido' });
    if (!String(req.headers['content-type'] || '').startsWith('application/json')) return json(res, 415, { error: 'se espera application/json' });
    if (regenerando) return json(res, 409, { error: 'ya se está actualizando' });
    const token = {}; regenerando = token;
    const liberar = () => { if (regenerando === token) regenerando = null; };
    // Vuelve a correr panel.ps1 (ruta fija) saltando la politica de ejecucion SOLO para ese proceso; no cambia ninguna politica del sistema.
    const hijo = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', panelScript], { windowsHide: true, stdio: 'ignore' });
    let respondido = false;
    const fin = (cod, txt) => { if (respondido) return; respondido = true; if (cod === 200) json(res, 200, { ok: true }); else json(res, cod, { error: txt }); };
    const corte = cortarPorTiempo(hijo, 120000, 'panel.ps1', (err, terminado) => { if (terminado) liberar(); fin(500, err.message); });
    hijo.on('error', (e) => { clearTimeout(corte); liberar(); fin(500, e.message); });
    hijo.on('exit', (cod) => { clearTimeout(corte); liberar(); if (cod === 0) fin(200); else fin(500, `panel.ps1 terminó con código ${cod}`); });
    return;
  }
  json(res, 404, { error: 'no encontrado' });
}).on('error', (e) => {
  console.error(e.code === 'EADDRINUSE' ? `El puerto ${PUERTO} ya está en uso: probablemente el panel ya está abierto en http://127.0.0.1:${PUERTO}/` : e.message);
  process.exit(1);
}).listen(PUERTO, '127.0.0.1', () => console.log(`Panel en http://127.0.0.1:${PUERTO}/  (Ctrl+C para cerrar)`));
