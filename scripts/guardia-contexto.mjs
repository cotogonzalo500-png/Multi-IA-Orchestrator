// Hook UserPromptSubmit del plugin: la "guardia de contexto". Ataca el gasto real de Claude: cada mensaje RELEE todo el contexto de la sesion
// (en los datos medidos, 98,8 % de los tokens son lecturas de cache y una sola sesion larga explica el 69 %).
// Lee el uso del ULTIMO mensaje de Claude en el transcript y, cuando corresponde, le agrega a Claude una linea corta de contexto para que le
// recomiende al usuario cerrar la tarea y seguir en una sesion nueva. NUNCA bloquea el mensaje del usuario. Sin red, sin credenciales.
// Se apaga con config.json > ahorro.guardia_activa = false (boton del panel). Umbrales: ahorro.ctx_aviso / ctx_alto / cache_ttl_min.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const datos = /^([A-Za-z]:[\\/]|\\\\)/.test(process.env.MULTIIA_DATOS || '') ? process.env.MULTIIA_DATOS : path.join(os.homedir(), '.multi-ia-orquestador');   // 2.3.1: solo rutas absolutas
const estadoPath = path.join(datos, 'guardia-estado.json');
const quitaBom = (t) => t.replace(/^﻿/, '');

let entrada = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (c) => (entrada += c));
process.stdin.on('end', () => {
  try { main(JSON.parse(quitaBom(entrada))); } catch { /* un hook de ahorro nunca debe romper la sesion */ }
});

function main(j) {
  let a = {};
  try { const c = JSON.parse(quitaBom(fs.readFileSync(path.join(datos, 'config.json'), 'utf8'))); if (c.activo === false) return; a = c.ahorro || {}; } catch { /* sin config: valores por defecto */ }
  if (a.guardia_activa === false) return;
  const aviso = a.ctx_aviso || 150000, alto = a.ctx_alto || 300000, ttl = a.cache_ttl_min || 55;
  const tp = j.transcript_path, sid = String(j.session_id || 'x');
  if (!tp || !fs.existsSync(tp)) return;

  // Solo se lee la cola del transcript (los archivos llegan a cientos de MB).
  const st = fs.statSync(tp), len = Math.min(st.size, 600000), buf = Buffer.alloc(len), fd = fs.openSync(tp, 'r');
  fs.readSync(fd, buf, 0, len, st.size - len); fs.closeSync(fd);
  const lineas = buf.toString('utf8').split('\n');
  let ctx = null, ts = null;
  for (let i = lineas.length - 1; i >= 0; i--) {
    if (!lineas[i].includes('"usage":{"input_tokens"')) continue;
    const u = /"usage":\{"input_tokens":(\d+),"cache_creation_input_tokens":(\d+),"cache_read_input_tokens":(\d+)/.exec(lineas[i]);
    if (!u) continue;
    const t = /"timestamp":"([^"]+)"/.exec(lineas[i]);
    ctx = Number(u[1]) + Number(u[2]) + Number(u[3]); ts = t ? new Date(t[1]).getTime() : null; break;
  }
  if (ctx == null) return;

  let est = {};
  try { est = JSON.parse(quitaBom(fs.readFileSync(estadoPath, 'utf8'))); } catch { /* primera vez */ }
  const e = (est[sid] ||= { nivel: 0, n: 0, nAviso: 0, tsCache: 0 });
  e.n += 1;
  const nivel = ctx >= alto ? 2 : ctx >= aviso ? 1 : 0;
  const minutos = ts ? (Date.now() - ts) / 60000 : 0;
  const k = Math.round(ctx / 1000);
  let msg = null;

  if (ctx >= 100000 && minutos >= ttl && Date.now() - e.tsCache > ttl * 60000) {
    // Pasada la vida de la cache, el proximo mensaje REESCRIBE todo el contexto (mas caro que releerlo).
    msg = `[Multi-IA · ahorro] Pasaron ~${Math.round(minutos)} min sin actividad: la caché expiró y este mensaje reescribe ~${k}k tokens de contexto. Si el tema cambió, recomendale al usuario en una línea empezar una sesión nueva (con memoria.ps1 -Handoff para no perder el hilo) en vez de seguir acá.`;
    e.tsCache = Date.now();
  } else if (nivel > e.nivel) {
    msg = nivel === 2
      ? `[Multi-IA · ahorro] ALERTA: el contexto es de ~${k}k tokens y cada mensaje lo relee entero. En tu próxima respuesta recomendale al usuario, en una línea, guardar un handoff (memoria.ps1 -Handoff "...") y seguir en una sesión nueva o con /compact. Evitá leer archivos grandes completos y delegá las lecturas largas a agy con -Archivo.`
      : `[Multi-IA · ahorro] El contexto ya es de ~${k}k tokens y se relee completo en cada mensaje. Si la tarea termina pronto, avisale al usuario en UNA línea que conviene cerrar con un resumen (memoria.ps1 -Handoff) y seguir en una sesión nueva. No interrumpas lo que está haciendo.`;
    e.nAviso = e.n;
  } else if (nivel === 2 && e.n - e.nAviso >= 12) {
    msg = `[Multi-IA · ahorro] Sigue el contexto alto (~${k}k tokens). Recordale al usuario, brevemente, que conviene cerrar esta sesión.`;
    e.nAviso = e.n;
  }
  e.nivel = nivel;

  // Estado atomico y acotado a las 30 sesiones mas recientes.
  const claves = Object.keys(est); if (claves.length > 30) for (const c of claves.slice(0, claves.length - 30)) delete est[c];
  fs.mkdirSync(datos, { recursive: true });
  const tmp = `${estadoPath}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(est), 'utf8'); fs.renameSync(tmp, estadoPath);

  if (msg) console.log(JSON.stringify({ hookSpecificOutput: { hookEventName: 'UserPromptSubmit', additionalContext: msg } }));
}
