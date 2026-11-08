// Hook SessionStart del plugin: si en la sesion anterior se guardo un "handoff" (memoria.ps1 -Handoff "..."), lo inyecta al empezar una sesion nueva
// para poder cortar sesiones largas sin perder el hilo. Solo el ULTIMO handoff, de menos de 36 h, de hasta 1000 caracteres (unos 250 tokens).
// Si no hay handoff no inyecta nada (no ensucia las sesiones de otros proyectos). Se apaga con config.json > ahorro.handoff_inicio = false.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const datos = process.env.MULTIIA_DATOS || path.join(os.homedir(), '.multi-ia-orquestador');
const quitaBom = (t) => t.replace(/^\uFEFF/, '');
let entrada = '';
process.stdin.resume(); process.stdin.on('data', (d) => { entrada += d; }); // del JSON de entrada solo se usa cwd (2.3.1)
const norm = (p) => path.resolve(String(p)).replace(/[\\/]+$/, '').toLowerCase();

process.stdin.on('end', () => {
  try {
    let a = {}; let cwd = '';
    try { cwd = JSON.parse(quitaBom(entrada) || '{}').cwd || ''; } catch { /* sin cwd */ }
    try { const c = JSON.parse(quitaBom(fs.readFileSync(path.join(datos, 'config.json'), 'utf8'))); if (c.activo === false) return; a = c.ahorro || {}; } catch { /* por defecto */ }
    if (a.handoff_inicio === false) return;
    const lineas = quitaBom(fs.readFileSync(path.join(datos, 'MEMORIA.md'), 'utf8')).split(/\r?\n/);
    for (let i = lineas.length - 1; i >= 0; i--) {
      const m = /^- \[(\d{4}-\d\d-\d\d)(?: (\d\d:\d\d))?\] .*?\[handoff\] (?:\{carpeta:([^}]*)\} )?(.+)$/.exec(lineas[i]);
      if (!m) continue;
      const cuando = new Date(`${m[1]}T${m[2] || '12:00'}:00`).getTime();
      if (Date.now() - cuando > 36 * 3600 * 1000) return;   // handoff viejo: se ignora
      if (m[3] && cwd && norm(m[3]) !== norm(cwd)) continue;   // 2.3.1: handoff de otro proyecto (los viejos sin carpeta valen para todos)
      console.log(JSON.stringify({ hookSpecificOutput: { hookEventName: 'SessionStart', additionalContext: `[Multi-IA · handoff de la sesión anterior, ${m[1]}] ${m[4].slice(0, 1000)}` } }));
      return;
    }
  } catch { /* nunca romper el inicio de sesion */ }
});
