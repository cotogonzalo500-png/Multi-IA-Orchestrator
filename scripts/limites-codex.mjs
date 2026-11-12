// Pide a Codex el cupo real de tu plan de ChatGPT hablando con `codex app-server` por stdio (JSON por linea).
// Solo lectura: no envia prompts ni toca credenciales; solo initialize + account/rateLimits/read.
// Uso: node limites-codex.mjs <ruta\a\codex.exe>   Salida: la linea JSON cruda de la respuesta. Codigo 1 si falla o no responde en 40 s.
import { spawn } from 'node:child_process';
import readline from 'node:readline';

const exe = process.argv[2];
if (!exe) { console.error('falta la ruta a codex.exe'); process.exit(1); }
// 3.4.0: limite opcional en segundos (argv[3], 1..40). limites.ps1 -Json pasa uno menor para terminar antes que el timeout del panel.
const seg = Math.min(40, Math.max(1, Number(process.argv[3]) || 40));

const p = spawn(exe, ['app-server'], { stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
const envia = (o) => p.stdin.write(JSON.stringify(o) + '\n');
const fin = (codigo) => { try { p.kill(); } catch {} process.exit(codigo); };
setTimeout(() => { console.error('Codex no respondio a tiempo'); fin(1); }, seg * 1000);

// Cualquier error del proceso o de su entrada (p. ej. EPIPE si Codex se cierra) debe terminar limpio y matar al hijo.
p.on('error', (e) => { console.error('No se pudo ejecutar Codex: ' + e.message); fin(1); });
p.stdin.on('error', () => fin(1));
p.stderr.on('data', (d) => { const t = String(d).trim(); if (t) console.error('[codex stderr] ' + t.slice(0, 300)); });
p.on('exit', () => { console.error('Codex termino antes de responder'); process.exit(1); });

readline.createInterface({ input: p.stdout }).on('line', (linea) => {
  let m; try { m = JSON.parse(linea); } catch { return; }
  if (m.id === 1) {              // initialize respondido: ahora si se puede pedir lo demas
    envia({ method: 'initialized' });
    envia({ method: 'account/rateLimits/read', id: 2 });
  } else if (m.id === 2) {
    console.log(linea);
    fin(m.error ? 1 : 0);
  }
});

envia({ method: 'initialize', id: 1, params: { clientInfo: { name: 'multi-ia-orquestador', version: '0.3.0' } } });
