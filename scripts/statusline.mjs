// Linea de estado de Claude Code que ademas guarda para el panel: cupo de tu plan, modelo y esfuerzo actuales.
// Claude Code ejecuta este comando con el JSON de la sesion por stdin (ver settings.json > statusLine). Se guarda en claude-snapshot.json,
// el mismo archivo que lee panel.ps1. rate_limits solo viene para suscriptores Pro/Max y despues de la primera respuesta de la sesion.
// No toca credenciales ni hace pedidos de red: solo copia numeros que Claude Code ya le entrega.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const datos = /^([A-Za-z]:[\\/]|\\\\)/.test(process.env.MULTIIA_DATOS || '') ? process.env.MULTIIA_DATOS : path.join(os.homedir(), '.multi-ia-orquestador');   // 2.3.1: solo rutas absolutas
const archivo = path.join(datos, 'claude-snapshot.json');

const pad = (n) => String(n).padStart(2, '0');
const local = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
const iso = (seg) => new Date(seg * 1000).toISOString().replace(/\.\d+Z$/, 'Z');

let entrada = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (c) => (entrada += c));
process.stdin.on('end', () => {
  let j = {};
  try { j = JSON.parse(entrada.replace(/^﻿/, '')); } catch { /* sin JSON: se imprime igual una linea vacia */ }

  const rl = j.rate_limits || {};
  const cinco = rl.five_hour, sem = rl.seven_day;
  const modeloId = j.model?.id || '';
  const esfuerzo = j.effort?.level || '';
  if (cinco || sem || modeloId || esfuerzo) {
    try {
      fs.mkdirSync(datos, { recursive: true });
      let previo = {};
      try { previo = JSON.parse(fs.readFileSync(archivo, 'utf8').replace(/^﻿/, '')); } catch { /* primera vez */ }
      // Una ventana ya vencida (su reinicio paso) no se conserva: mostrarla como dato fresco seria mentir.
      const vigente = (w) => (w && w.reinicia && new Date(w.reinicia).getTime() > Date.now() ? w : undefined);
      previo.cinco_horas = vigente(previo.cinco_horas);
      previo.semanal = vigente(previo.semanal);
      const nuevo = {
        tomado: local(new Date()),
        plan: previo.plan || 'Pro',
        fuente: 'statusline',
        modelo: modeloId || previo.modelo,
        esfuerzo: esfuerzo || previo.esfuerzo,
        // Si falta una ventana (Claude Code la quita al pasar su reinicio) se conserva la anterior.
        cinco_horas: cinco ? { usado: Math.round(cinco.used_percentage), reinicia: iso(cinco.resets_at) } : previo.cinco_horas,
        semanal: sem ? { usado: Math.round(sem.used_percentage), reinicia: iso(sem.resets_at) } : previo.semanal,
      };
      // Solo se reescribe si cambio algo o si la foto tiene mas de 60 s: evita escribir en disco a cada tecla.
      const clave = (o) => JSON.stringify([o.cinco_horas, o.semanal, o.modelo, o.esfuerzo]);
      const vieja = !previo.tomado || Date.now() - new Date(previo.tomado).getTime() > 60000;
      if (clave(nuevo) !== clave(previo) || vieja) {
        // Escritura atomica: archivo temporal + renombrar, para que el panel nunca lea un JSON a medias.
        const tmp = `${archivo}.${process.pid}.tmp`;
        fs.writeFileSync(tmp, JSON.stringify(nuevo, null, 2), 'utf8');
        fs.renameSync(tmp, archivo);
      }
    } catch { /* la linea de estado nunca debe romper la sesion */ }
  }

  const partes = [];
  if (j.model?.display_name) partes.push(j.model.display_name + (esfuerzo ? ` (${esfuerzo})` : ''));
  const ctx = j.context_window?.used_percentage;
  if (ctx != null) partes.push(`ctx ${Math.round(ctx)}%`);
  if (cinco) partes.push(`5h ${Math.round(cinco.used_percentage)}%`);
  if (sem) partes.push(`7d ${Math.round(sem.used_percentage)}%`);
  console.log(partes.join(' · '));
});
