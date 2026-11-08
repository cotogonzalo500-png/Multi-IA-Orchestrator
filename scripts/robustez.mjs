// Robustez del panel (2.0.1): candado de config.json sin bloquear el hilo y con dueño verificado, y cierre de procesos con verificación.
// Sin dependencias; lo usa panel-servidor.mjs y lo prueba tests\robustez.mjs.
import fs from 'node:fs';
import { spawn } from 'node:child_process';

const espera = (ms) => new Promise((r) => setTimeout(r, ms));

// ¿Sigue vivo el proceso? (señal 0 no mata: solo comprueba existencia; EPERM = existe pero es de otro usuario)
export function pidVivo(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; }
}

// Dueño del candado: lee el PID guardado dentro. null = ilegible o vacío (lo crea otro lenguaje o se está escribiendo).
function dueno(lockPath) {
  try { const n = parseInt(fs.readFileSync(lockPath, 'utf8').trim(), 10); return Number.isInteger(n) && n > 0 ? n : null; } catch { return null; }
}

// Un candado se considera huérfano SOLO si es viejo Y su dueño ya no existe.
// Sin PID legible (candado de PowerShell antiguo o escritura a medias) se exige un margen mayor antes de tocarlo.
export function candadoHuerfano(lockPath, { edadMs = 15000, edadSinDuenoMs = 60000, edadMaxMs = 300000, ahora = Date.now() } = {}) {
  let st; try { st = fs.statSync(lockPath); } catch { return false; }
  const edad = ahora - st.mtimeMs, pid = dueno(lockPath);
  // 2.0.1 (Codex #2): un PID reciclado haria parecer vivo para siempre a un candado muerto; el candado se sostiene milisegundos, asi que pasado un tope duro se considera huerfano igual.
  if (pid !== null) return edad > edadMs && (!pidVivo(pid) || edad > edadMaxMs);
  return edad > edadSinDuenoMs;
}

// Retira un candado huerfano (2.2.0, Codex #1). Antes se renombraba y DESPUES se revalidaba: en esa ventana otro proceso podia crear
// un candado nuevo y quedaban dos dueños. Ahora se toma un candado de RETIRO exclusivo (wx), se revalida que sea el mismo candado que
// se juzgo (ino + mtime + dueño) y que siga huerfano, y recien ahi se borra. Un candado vigente nunca se mueve: mientras exista nadie
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

// Descendientes de un PID (Windows): una foto de la tabla de procesos via CIM. [] si no se puede leer o fuera de Windows.
export function descendientes(pid, { esperaMs = 8000 } = {}) {
  if (process.platform !== 'win32' || !pid) return Promise.resolve([]);
  return new Promise((r) => {
    let out = '';
    const ps = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', 'Get-CimInstance Win32_Process | ForEach-Object { "$($_.ProcessId) $($_.ParentProcessId)" }'], { windowsHide: true, stdio: ['ignore', 'pipe', 'ignore'] });
    const t = setTimeout(() => { try { ps.kill(); } catch {} r([]); }, esperaMs);
    ps.stdout.setEncoding('utf8'); ps.stdout.on('data', (d) => { out += d; });
    ps.on('error', () => { clearTimeout(t); r([]); });
    ps.on('close', () => {
      clearTimeout(t);
      const hijos = new Map();
      for (const l of out.split(/\r?\n/)) { const [a, b] = l.trim().split(/\s+/).map(Number); if (a > 0 && b >= 0 && a !== b) { if (!hijos.has(b)) hijos.set(b, []); hijos.get(b).push(a); } }
      const res = [], pend = [pid], vistos = new Set([pid]);
      while (pend.length) for (const h of hijos.get(pend.pop()) || []) if (!vistos.has(h)) { vistos.add(h); res.push(h); pend.push(h); }
      r(res);
    });
  });
}

// Cierra un hijo y su árbol y VERIFICA que terminó (padre Y descendientes). Devuelve { terminado, intentos, vivos }.
// kill() solo manda la señal: en Windows no mata a los nietos ni garantiza la salida, por eso taskkill /T /F y espera de confirmación.
// 2.2.0 (Codex #2): antes se confirmaba solo al padre; un nieto con las tuberías heredadas podía quedar vivo y 'close' no llegaba nunca.
// Ahora se toma una foto del árbol ANTES de cortar; al final cada descendiente que siga vivo se mata por PID y, si sobrevive, va en `vivos`.
export async function matarVerificado(hijo, { esperaMs = 5000, taskkill = true } = {}) {
  const salio = () => hijo.exitCode !== null || hijo.signalCode !== null;
  if (salio()) return { terminado: true, intentos: 0, vivos: [] };
  const arbol = await descendientes(hijo.pid);
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
  if (!padre) padre = !pidVivo(hijo.pid);
  // descendientes que sobrevivieron (p. ej. huérfanos: taskkill /T ya no los alcanza por el árbol)
  for (const p of arbol) if (pidVivo(p)) { try { process.kill(p); } catch {} }
  if (arbol.some(pidVivo)) await espera(500);
  const vivos = arbol.filter(pidVivo);
  return { terminado: padre && vivos.length === 0, intentos, vivos };
}
