// Regresion de robustez (2.0.1): candado de config sin Atomics.wait, dueño verificado, cierre de procesos verificado.
// Uso: node tests\robustez.mjs   -> sale 0 si todo pasa.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { pidVivo, candadoHuerfano, retirarHuerfano, conCandado, matarVerificado, arbolDe } from '../scripts/robustez.mjs';

const aqui = path.dirname(fileURLToPath(import.meta.url));
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'multiia-robustez-'));
let ok = 0, mal = 0;
const T = async (nombre, fn) => { try { await fn(); ok++; console.log('ok   ' + nombre); } catch (e) { mal++; console.log('FALLA ' + nombre + ' -> ' + (e && e.message)); } };
const af = (c, m) => { if (!c) throw new Error(m); };
const viejo = (f, segundos) => { const t = new Date(Date.now() - segundos * 1000); fs.utimesSync(f, t, t); };
const espera = (ms) => new Promise((r) => setTimeout(r, ms));
const nuevo = (n) => path.join(dir, n);

// pid de un proceso que ya termino (dueño muerto)
const pidMuerto = await new Promise((res) => { const h = spawn(process.execPath, ['-e', '0'], { stdio: 'ignore' }); const pid = h.pid; h.on('exit', () => res(pid)); });

await T('panel-servidor.mjs no usa Atomics.wait ni deja sleeps sincronos', () => {
  const src = fs.readFileSync(path.join(aqui, '..', 'scripts', 'panel-servidor.mjs'), 'utf8');
  const sinComentarios = src.replace(/\/\/.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '');
  af(!/Atomics\s*\.\s*wait/.test(sinComentarios), 'Atomics.wait sigue en panel-servidor.mjs');
  af(/conCandado/.test(src) && /matarVerificado/.test(src), 'panel-servidor.mjs no usa robustez.mjs');
  af(!/setTimeout\(\(\) => hijo\.kill\(\)/.test(src), 'queda un hijo.kill() sin verificar');
});

await T('panel-servidor.mjs rechaza la promesa al vencer el tiempo y limita la salida (Codex #4/#5)', () => {
  const src = fs.readFileSync(path.join(aqui, '..', 'scripts', 'panel-servidor.mjs'), 'utf8');
  af(src.includes("cortarPorTiempo(hijo, 120000, 'chats.ps1', (err, terminado) => { reject(err);") && src.includes("cortarPorTiempo(hijo, 120000, 'ahorro.ps1', (err, terminado) => { reject(err);"), '2.2.0: el vencimiento debe rechazar SIEMPRE (aunque el cierre falle), si no la peticion y enCurso quedan retenidos');
  af(src.includes('matarVerificado(hijo).catch('), 'matarVerificado(hijo).then sin .catch: un error deja la peticion colgada');
  af(/MAX_SALIDA/.test(src) && !/out \+= d/.test(src), 'la salida acumulada no tiene tope');
  af(/DESBORDE/.test(src) && /produjo una salida demasiado grande/.test(src), '2.2.0: la salida desbordada debe ser error, no resultado truncado');
});

await T('2.2.0 panel-servidor: timeout libera regenerando solo al terminar el proceso; GET / maneja 404; config con cuentas invalidas se depura', () => {
  const src = fs.readFileSync(path.join(aqui, '..', 'scripts', 'panel-servidor.mjs'), 'utf8');
  af(src.includes("cortarPorTiempo(hijo, 120000, 'panel.ps1', (err, terminado) => { if (terminado) liberar();"), 'el timeout debe liberar regenerando solo si el hijo termino');
  af(src.includes('if (regenerando === token) regenerando = null') && !/regenerando = false/.test(src), '2.2.0: regenerando debe liberarse por token (sin doble liberacion de otra corrida)');
  af(src.includes('ENOENT') && src.includes('404'), 'GET / no distingue 404 de 500');
  af(src.includes('c.cuentas = c.cuentas.filter'), 'config.json con cuentas invalidas no se depura');
});

await T('2.2.0 retirarHuerfano: con otro retiro en curso no toca el candado (exclusion)', () => {
  const f = nuevo('retiro.lock'); fs.writeFileSync(f, String(pidMuerto)); viejo(f, 100);
  fs.writeFileSync(f + '.retiro', String(process.pid));
  af(retirarHuerfano(f) === false && fs.existsSync(f), 'retiro el candado mientras otro proceso tenia el retiro');
  af(fs.existsSync(f + '.retiro'), 'borro un retiro reciente ajeno');
  viejo(f + '.retiro', 60);
  af(retirarHuerfano(f) === false && !fs.existsSync(f + '.retiro'), 'un retiro abandonado no se descarta');
  af(retirarHuerfano(f) === true && !fs.existsSync(f), 'tras descartar el retiro abandonado no se recupero el candado huerfano');
});

await T('2.2.0 retirarHuerfano: nunca mueve el candado (sin ventana de renombrado) y no deja restos', () => {
  const src = fs.readFileSync(path.join(aqui, '..', 'scripts', 'robustez.mjs'), 'utf8');
  const m = src.match(/export function retirarHuerfano[\s\S]*?\n\}/);
  af(m && !/renameSync/.test(m[0]) && /'wx'/.test(m[0]), 'retirarHuerfano sigue renombrando el candado vigente');
  const f = nuevo('restos.lock'); fs.writeFileSync(f, String(pidMuerto)); viejo(f, 100);
  af(retirarHuerfano(f) === true, 'no se retiro el huerfano');
  af(fs.readdirSync(dir).filter((x) => x.startsWith('restos.lock')).length === 0, 'quedaron archivos temporales del retiro');
});

await T('candado viejo con dueño VIVO no se considera huerfano', () => {
  const f = nuevo('vivo.lock'); fs.writeFileSync(f, String(process.pid)); viejo(f, 100);
  af(pidVivo(process.pid), 'pidVivo falla con el propio proceso');
  af(candadoHuerfano(f) === false, 'se habria borrado el candado de un proceso vivo');
});

await T('candado MUY viejo (> tope duro) se retira aunque el PID parezca vivo (PID reciclado)', () => {
  const f = nuevo('reciclado.lock'); fs.writeFileSync(f, String(process.pid)); viejo(f, 600);
  af(candadoHuerfano(f) === true, 'un PID reciclado mantendria el candado para siempre');
  af(retirarHuerfano(f) === true && !fs.existsSync(f), 'no se retiro el candado');
});

await T('retirarHuerfano no pisa un candado nuevo (carrera de recuperacion)', () => {
  const f = nuevo('carrera.lock'); fs.writeFileSync(f, String(process.pid)); // fresco y vivo
  af(retirarHuerfano(f) === false, 'retiro un candado vigente');
  af(fs.existsSync(f) && fs.readFileSync(f, 'utf8') === String(process.pid), 'el candado vigente no quedo intacto');
});

await T('candado viejo con dueño MUERTO se considera huerfano', () => {
  const f = nuevo('muerto.lock'); fs.writeFileSync(f, String(pidMuerto)); viejo(f, 600);
  af(pidVivo(pidMuerto) === false, 'el pid de prueba sigue vivo');
  af(candadoHuerfano(f) === true, 'no detecto el candado huerfano');
});

await T('candado reciente de dueño muerto espera el margen (no se roba al instante)', () => {
  const f = nuevo('reciente.lock'); fs.writeFileSync(f, String(pidMuerto)); viejo(f, 2);
  af(candadoHuerfano(f) === false, 'robo un candado de hace 2 s');
});

await T('candado sin PID legible: solo huerfano pasado el margen largo', () => {
  const f = nuevo('sinpid.lock'); fs.writeFileSync(f, ''); viejo(f, 20);
  af(candadoHuerfano(f) === false, 'robo un candado sin pid de 20 s');
  viejo(f, 120);
  af(candadoHuerfano(f) === true, 'no limpio un candado sin pid de 120 s');
});

await T('conCandado NO roba el candado viejo de un dueño vivo (falla en vez de pisarlo)', async () => {
  const f = nuevo('retenido.lock'); fs.writeFileSync(f, String(process.pid)); viejo(f, 100);
  let corrio = false, error = null;
  try { await conCandado(f, () => { corrio = true; }, { intentos: 4, pasoMs: 10 }); } catch (e) { error = e; }
  af(!corrio, 'la funcion corrio sin tener el candado');
  af(error && /ocupada/.test(error.message), 'no informo que estaba ocupada');
  af(fs.existsSync(f) && fs.readFileSync(f, 'utf8') === String(process.pid), 'el candado ajeno fue modificado');
});

await T('conCandado recupera el candado de un dueño muerto y lo libera', async () => {
  const f = nuevo('recuperable.lock'); fs.writeFileSync(f, String(pidMuerto)); viejo(f, 600);
  let corrio = false;
  await conCandado(f, () => { corrio = true; af(fs.readFileSync(f, 'utf8') === String(process.pid), 'el candado no quedo a nombre del proceso actual'); });
  af(corrio, 'no corrio la funcion');
  af(!fs.existsSync(f), 'no libero el candado');
});

await T('mientras espera el candado el event loop sigue respondiendo (sin bloqueo)', async () => {
  const f = nuevo('espera.lock'); fs.writeFileSync(f, String(process.pid));   // lo retiene "otro" (reciente y vivo)
  // Mide BLOQUEO (hueco maximo entre ticks), no rendimiento: bajo carga los timers de Windows se atrasan y el conteo bruto era fragil.
  let ticks = 0, ultimo = Date.now(), hueco = 0;
  const iv = setInterval(() => { ticks++; const n = Date.now(); hueco = Math.max(hueco, n - ultimo); ultimo = n; }, 10);
  setTimeout(() => fs.unlinkSync(f), 400);                                    // se libera a los 400 ms
  const t0 = Date.now();
  await conCandado(f, () => {}, { intentos: 100, pasoMs: 20 });
  clearInterval(iv);
  const ms = Date.now() - t0;
  af(ms >= 350, 'no espero a que se liberara (' + ms + ' ms)');
  af(ticks >= 5 && hueco < 250, 'el event loop quedo bloqueado: ' + ticks + ' ticks en ' + ms + ' ms, hueco maximo ' + hueco + ' ms');
});

await T('solo borra el candado si sigue siendo suyo', async () => {
  const f = nuevo('ajeno.lock');
  await conCandado(f, () => { fs.writeFileSync(f, String(process.pid + 99999)); });   // otro proceso lo reclamo mientras tanto
  af(fs.existsSync(f), 'borro un candado que ya era de otro');
  af(fs.readFileSync(f, 'utf8') === String(process.pid + 99999), 'cambio el contenido del candado ajeno');
});

await T('dos escrituras concurrentes se serializan (no se pisan)', async () => {
  const f = nuevo('serie.lock'); const arch = nuevo('contador.txt'); fs.writeFileSync(arch, '0');
  const incr = () => conCandado(f, async () => { const n = parseInt(fs.readFileSync(arch, 'utf8'), 10); await espera(15); fs.writeFileSync(arch, String(n + 1)); }, { intentos: 400, pasoMs: 5 });
  await Promise.all(Array.from({ length: 8 }, incr));
  af(fs.readFileSync(arch, 'utf8') === '8', 'se perdieron escrituras: contador=' + fs.readFileSync(arch, 'utf8'));
});

await T('matarVerificado cierra un proceso que no termina solo y lo confirma', async () => {
  const h = spawn(process.execPath, ['-e', 'setInterval(()=>{},1000)'], { stdio: 'ignore', windowsHide: true });
  await espera(300);
  af(pidVivo(h.pid), 'el proceso de prueba no arranco');
  const r = await matarVerificado(h, { esperaMs: 4000 });
  af(r.terminado === true, 'no confirmo la terminacion: ' + JSON.stringify(r));
  af(pidVivo(h.pid) === false, 'el proceso sigue vivo tras matarVerificado');
});

await T('matarVerificado tambien cierra a los descendientes (nietos)', async () => {
  const cod = "const {spawn}=require('child_process');const n=spawn(process.execPath,['-e','setInterval(()=>{},1000)'],{stdio:'ignore'});console.log(n.pid);setInterval(()=>{},1000)";
  const h = spawn(process.execPath, ['-e', cod], { stdio: ['ignore', 'pipe', 'ignore'], windowsHide: true });
  const nieto = await new Promise((res) => h.stdout.once('data', (d) => res(parseInt(String(d).trim(), 10))));
  af(pidVivo(nieto), 'el nieto no arranco');
  const r = await matarVerificado(h, { esperaMs: 4000 });
  await espera(500);
  const vivo = pidVivo(nieto); if (vivo) { try { process.kill(nieto); } catch {} }
  af(r.terminado === true, 'padre no terminado: ' + JSON.stringify(r));
  af(!vivo, 'el nieto quedo vivo tras matarVerificado');
});

await T('2.2.0 matarVerificado verifica a los nietos aunque taskkill no corra (foto del arbol)', async () => {
  const cod = "const {spawn}=require('child_process');const n=spawn(process.execPath,['-e','setInterval(()=>{},1000)'],{stdio:'ignore'});console.log(n.pid);setInterval(()=>{},1000)";
  const h = spawn(process.execPath, ['-e', cod], { stdio: ['ignore', 'pipe', 'ignore'], windowsHide: true });
  const nieto = await new Promise((res) => h.stdout.once('data', (d) => res(parseInt(String(d).trim(), 10))));
  af(pidVivo(nieto), 'el nieto no arranco');
  const r = await matarVerificado(h, { esperaMs: 3000, taskkill: false });
  const vivo = pidVivo(nieto); if (vivo) { try { process.kill(nieto); } catch {} }
  af(Array.isArray(r.vivos), 'matarVerificado no informa descendientes vivos');
  af(!vivo, 'sin taskkill el nieto quedo vivo: la verificacion solo miraba al padre');
  af(r.terminado === true && r.vivos.length === 0, 'resultado inconsistente: ' + JSON.stringify(r));
});

await T('3.1.0 arbolDe ignora un proceso huerfano cuyo ParentProcessId quedo viejo (PID reciclado)', () => {
  // 100 = hijo (creado en t=1000). 200 = nieto legitimo (t=1500). 300 = huerfano de OTRO proceso que tuvo el PID 100 antes (t=500 < 1000): no es descendiente.
  const tabla = new Map([[100, { ppid: 1, ticks: 1000 }], [200, { ppid: 100, ticks: 1500 }], [300, { ppid: 100, ticks: 500 }], [400, { ppid: 200, ticks: 1600 }]]);
  const a = arbolDe(tabla, 100);
  af(a.has(200) && a.has(400), 'faltan descendientes legitimos');
  af(!a.has(300), 'conto como descendiente a un proceso mas viejo que su supuesto padre (se lo habria matado por error)');
  af(arbolDe(null, 100).size === 0 && arbolDe(tabla, 999).size === 0, 'tabla nula o pid ausente deberia dar arbol vacio');
});

await T('3.1.0 matarVerificado bajo carga: 6 cierres en paralelo con nietos terminan limpios', async () => {
  const cod = "const {spawn}=require('child_process');const n=spawn(process.execPath,['-e','setInterval(()=>{},1000)'],{stdio:'ignore'});console.log(n.pid);setInterval(()=>{},1000)";
  const hs = await Promise.all(Array.from({ length: 6 }, async () => { const h = spawn(process.execPath, ['-e', cod], { stdio: ['ignore', 'pipe', 'ignore'], windowsHide: true }); const nieto = await new Promise((res) => h.stdout.once('data', (d) => res(parseInt(String(d).trim(), 10)))); return { h, nieto }; }));
  const rs = await Promise.all(hs.map(({ h }) => matarVerificado(h, { esperaMs: 4000 })));
  const vivos = hs.filter(({ nieto }) => pidVivo(nieto)); for (const { nieto } of vivos) { try { process.kill(nieto); } catch {} }
  af(vivos.length === 0, 'quedaron nietos vivos: ' + vivos.map((v) => v.nieto));
  af(rs.every((r) => r.terminado), 'algun cierre no se confirmo: ' + JSON.stringify(rs));
});
await T('Unlock-Config no borra si no puede verificar el dueño (fuente)', () => {
  const src = fs.readFileSync(path.join(aqui, '..', 'scripts', '_comun.ps1'), 'utf8');
  const m = src.match(/function Unlock-Config \{[\s\S]*?\n\}/);
  af(m && /catch \{ return \}/.test(m[0]) && /-not \$d/.test(m[0]), 'Unlock-Config sigue borrando sin verificar');
});

await T('matarVerificado sobre un proceso ya terminado no hace nada', async () => {
  const h = spawn(process.execPath, ['-e', '0'], { stdio: 'ignore' });
  await new Promise((r) => h.on('exit', r));
  const r = await matarVerificado(h);
  af(r.terminado === true && r.intentos === 0, JSON.stringify(r));
});

fs.rmSync(dir, { recursive: true, force: true });
console.log(`\nrobustez: ${ok} ok, ${mal} con falla`);
process.exit(mal ? 1 : 0);
