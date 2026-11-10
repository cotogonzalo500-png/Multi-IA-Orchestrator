// Robustez del panel (2.0.1): candado de config.json sin bloquear el hilo y con dueÃ±o verificado, y cierre de procesos con verificaciÃ³n.
// Sin dependencias; lo usa panel-servidor.mjs y lo prueba tests\robustez.mjs.
import fs from 'node:fs';
import { spawn } from 'node:child_process';

const espera = (ms) => new Promise((r) => setTimeout(r, ms));

// Â¿Sigue vivo el proceso? (seÃ±al 0 no mata: solo comprueba existencia; EPERM = existe pero es de otro usuario)
export function pidVivo(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; }
}

// DueÃ±o del candado: lee el PID guardado dentro. null = ilegible o vacÃ­o (lo crea otro lenguaje o se estÃ¡ escribiendo).
function dueno(lockPath) {
  try { const n = parseInt(fs.readFileSync(lockPath, 'utf8').trim(), 10); return Number.isInteger(n) && n > 0 ? n : null; } catch { return null; }
}

// Un candado se considera huÃ©rfano SOLO si es viejo Y su dueÃ±o ya no existe.
// Sin PID legible (candado de PowerShell antiguo o escritura a medias) se exige un margen mayor antes de tocarlo.
export function candadoHuerfano(lockPath, { edadMs = 15000, edadSinDuenoMs = 60000, edadMaxMs = 300000, ahora = Date.now() } = {}) {
  let st; try { st = fs.statSync(lockPath); } catch { return false; }
  const edad = ahora - st.mtimeMs, pid = dueno(lockPath);
  // 2.0.1 (Codex #2): un PID reciclado haria parecer vivo para siempre a un candado muerto; el candado se sostiene milisegundos, asi que pasado un tope duro se considera huerfano igual.
  if (pid !== null) return edad > edadMs && (!pidVivo(pid) || edad > edadMaxMs);
  return edad > edadSinDuenoMs;
}

// Retira un candado huerfano (2.2.0, Codex #1). Antes se renombraba y DESPUES se revalidaba: en esa ventana otro proceso podia crear
// un candado nuevo y quedaban dos dueÃ±os. Ahora se toma un candado de RETIRO exclusivo (wx), se revalida que sea el mismo candado que
// se juzgo (ino + mtime + dueÃ±o) y que siga huerfano, y recien ahi se borra. Un candado vigente nunca se mueve: mientras exista nadie
// puede crear otro, y solo quien tiene el retiro puede quitarlo.
const firma = (f) => { try { const st = fs.statSync(f); return `${st.ino}:${st.mtimeMs}:${dueno(f)}`; } catch { return null; } };
export function retirarHuerfano(lockPath, opts = {}) {
  const vista = firma(lockPath);
  if (vista === null || !candadoHuerfano(lockPath, opts)) return false;
  const retiro = lockPath + '.retiro';
  let fd;
  try { fd = fs.openSync(retiro, 'wx'); }
  catch (e) {
    // retiro abandonado (proceso caido a mitad): se descarta solo si es viejo; en esta vuelta no se retira nada
    if (e.code === 'EEXIST') { try { if (Date.now() - fs.statSync(retiro).mtimeMs > (opts.edadRetiroMs ?? 10000)) fs.unlinkSync(retiro); } catch {} }
    return false;
  }
  try {
    if (firma(lockPath) !== vista || !candadoHuerfano(lockPath, opts)) return false;
    try { fs.unlinkSync(lockPath); return true; } catch { return false; }
  } finally { try { fs.closeSync(fd); } catch {} try { fs.unlinkSync(retiro); } catch {} }
}

// Toma el candado sin bloquear el event loop (antes: Atomics.wait en el hilo principal congelaba el servidor hasta 5 s).
export async function conCandado(lockPath, fn, { intentos = 100, pasoMs = 50, edadMs, edadSinDuenoMs } = {}) {
  let fd = null;
  for (let i = 0; i < intentos && fd === null; i++) {
    try { fd = fs.openSync(lockPath, 'wx'); }
    catch (e) {
      if (e.code !== 'EEXIST') throw e;
      if (candadoHuerfano(lockPath, { edadMs, edadSinDuenoMs })) { retirarHuerfano(lockPath, { edadMs, edadSinDuenoMs }); continue; }
      await espera(pasoMs);
      continue;
    }
    // 2.0.1 (auditoria Codex #8): si falla la escritura del PID (disco lleno) se cierra y se retira SOLO el archivo recien creado.
    try { fs.writeSync(fd, String(process.pid)); }
    catch (e) { try { fs.closeSync(fd); } catch {} try { fs.unlinkSync(lockPath); } catch {} fd = null; throw e; }
  }
  if (fd === null) throw new Error('config.json esta ocupada por otro proceso; reintenta');
  try { return await fn(); }
  finally {
    try { fs.closeSync(fd); } catch {}
    // Solo se borra si sigue siendo NUESTRO (otro proceso pudo reclamarlo si tardamos demasiado).
    if (dueno(lockPath) === process.pid) { try { fs.unlinkSync(lockPath); } catch {} }
  }
}

// Tabla de procesos (Windows) via CIM: Map pid -> { ppid, ticks }. ticks = hora de creacion, para distinguir identidades (los PID se reciclan).
// null si no se pudo leer (timeout con la maquina saturada, salida vacia) y fuera de Windows.
function tablaProcesos(esperaMs = 8000) {
  if (process.platform !== 'win32') return Promise.resolve(null);
  return new Promise((r) => {
    let out = '';
    const ps = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', 'Get-CimInstance Win32_Process | ForEach-Object { "$($_.ProcessId) $($_.ParentProcessId) $($_.CreationDate.Ticks)" }'], { windowsHide: true, stdio: ['ignore', 'pipe', 'ignore'] });
    const t = setTimeout(() => { try { ps.kill(); } catch {} r(null); }, esperaMs);
    ps.stdout.setEncoding('utf8'); ps.stdout.on('data', (d) => { out += d; });
    ps.on('error', () => { clearTimeout(t); r(null); });
    ps.on('close', () => {
      clearTimeout(t);
      const m = new Map();
      for (const l of out.split(/\r?\n/)) { const [a, b, c] = l.trim().split(/\s+/).map(Number); if (a > 0 && b >= 0) m.set(a, { ppid: b, ticks: c || 0 }); }
      r(m.size ? m : null);
    });
  });
}
async function tablaConReintento(esperaMs) { for (let i = 0; i < 2; i++) { const t = await tablaProcesos(esperaMs); if (t) return t; } return null; }

// Descendientes de un PID como Map pid -> ticks. 3.1.0: un hijo solo cuenta si NACIO despues que su padre; un proceso huerfano cuyo
// ParentProcessId quedo viejo y coincide con un PID reciclado NO es descendiente (antes se lo mataba por error y fallaba la verificacion).
export function arbolDe(tabla, pid) {
  const res = new Map();
  if (!tabla || !tabla.has(pid)) return res;
  const hijos = new Map();
  for (const [p, v] of tabla) { if (p !== v.ppid) { if (!hijos.has(v.ppid)) hijos.set(v.ppid, []); hijos.get(v.ppid).push(p); } }
  const pend = [pid], vistos = new Set([pid]);
  while (pend.length) { const padre = pend.pop(); for (const h of hijos.get(padre) || []) if (!vistos.has(h) && tabla.get(h).ticks >= tabla.get(padre).ticks) { vistos.add(h); res.set(h, tabla.get(h).ticks); pend.push(h); } }
  return res;
}

// Descendientes de un PID (Windows): [] si no se puede leer o fuera de Windows.
export async function descendientes(pid, { esperaMs = 8000 } = {}) {
  if (!pid) return [];
  return [...arbolDe(await tablaConReintento(esperaMs), pid).keys()];
}

// Cierra un hijo y su Ã¡rbol y VERIFICA que terminÃ³ (padre Y descendientes). Devuelve { terminado, intentos, vivos }.
// kill() solo manda la seÃ±al: en Windows no mata a los nietos ni garantiza la salida, por eso taskkill /T /F y espera de confirmaciÃ³n.
// 2.2.0 (Codex #2): antes se confirmaba solo al padre; un nieto con las tuberÃ­as heredadas podÃ­a quedar vivo y 'close' no llegaba nunca.
// Ahora se toma una foto del Ã¡rbol ANTES de cortar; al final cada descendiente que siga vivo se mata por PID y, si sobrevive, va en `vivos`.
export async function matarVerificado(hijo, { esperaMs = 5000, taskkill = true } = {}) {
  const salio = () => hijo.exitCode !== null || hijo.signalCode !== null;
  if (salio()) return { terminado: true, intentos: 0, vivos: [] };
  const arbol = arbolDe(await tablaConReintento(8000), hijo.pid); // Map pid -> ticks (identidad)
  let intentos = 0, padre = false;
  const confirmar = (ms) => new Promise((r) => { if (salio()) return r(true); const t = setTimeout(() => r(salio()), ms); hijo.once('exit', () => { clearTimeout(t); r(true); }); });
  for (; intentos < 2 && !padre; intentos++) {
    try {
      // 2.0.1 (auditoria Codex #3): se ESPERA a taskkill antes de hijo.kill(); si no, el padre desaparece antes de que taskkill recorra el arbol y los nietos quedan vivos.
      if (process.platform === 'win32' && taskkill && hijo.pid) {
        await new Promise((r) => { const tk = spawn('taskkill.exe', ['/T', '/F', '/PID', String(hijo.pid)], { windowsHide: true, stdio: 'ignore' }); const t = setTimeout(r, 4000); tk.on('error', () => { clearTimeout(t); r(); }); tk.on('exit', () => { clearTimeout(t); r(); }); });
      }
      hijo.kill();
    } catch { /* ya no existe */ }
    padre = await confirmar(esperaMs);
  }
  // 3.1.0 (estabilidad bajo carga): TerminateProcess es asincrono; con la maquina saturada el proceso puede seguir "vivo" unos segundos.
  // Antes se miraba UNA vez tras 500 ms fijos; ahora se SONDEA hasta un tope. Cada sobreviviente se confirma con una foto fresca
  // (mismo PID Y misma hora de creacion) antes de matarlo o informarlo: un PID reciclado por otro proceso no es nuestro.
  const limiteDuro = Date.now() + 25000; // con la maquina saturada la foto CIM tarda segundos: sin foto se espera hasta el tope duro, nunca se mata a ciegas
  let vivos = [];
  for (;;) {
    const cand = [...arbol.keys()].filter(pidVivo);
    if (cand.length === 0) { vivos = []; break; }
    const tabla = await tablaConReintento(8000);
    if (!tabla) { vivos = cand; if (Date.now() >= limiteDuro) break; await espera(200); continue; } // identidad no verificable: no se mata a ciegas, se informa
    vivos = cand.filter((p) => tabla.has(p) && tabla.get(p).ticks === arbol.get(p));
    if (vivos.length === 0 || Date.now() >= limiteDuro) break;
    for (const p of vivos) { try { process.kill(p); } catch {} }
    await espera(100);
  }
  if (!padre) { const f = Date.now() + 2000; while (pidVivo(hijo.pid) && Date.now() < f) { try { process.kill(hijo.pid); } catch {} await espera(100); } padre = !pidVivo(hijo.pid); }
  return { terminado: padre && vivos.length === 0, intentos, vivos };
}
