import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

const PANE = 'multi-ia-panel'
const PANE_CC = 'multi-ia-centro'
const TITULO_CC = 'Multi-IA · Centro de control'
const PS = ['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File']
// Los scripts viajan con el plugin: la ruta sale de $.plugin.root (nada fijo a una PC).
const script = ($: any, nombre: string) => String($.plugin.root).replace(/[\\/]+$/, '') + '\\scripts\\' + nombre

type Ventana = { v: string; usado: number; reinicia?: string; origen?: string }
type Tarjeta = { nombre: string; ventanas: Ventana[] }
type Hora = { h: number; c: number; d: number; cx?: number; ag?: number }   // 2.3.0: cx/ag = delegado por motor (ausentes en datos viejos)
type Evento = { f: string; t: string; d: string; x: string; m: string; k: string; tok: number; s: number; i?: string; c?: string; o?: string }
// Una ejecución del historial = todos los eventos de un mismo ID unidos (el último estado manda; los campos vacíos no pisan a los llenos).
type Ejec = { i: string; f: string; fin: string; t: string; d: string; x: string; m: string; k: string; tok: number; s: number; c: string; o: string }

// Exporta el historial con los MISMOS filtros que se ven en pantalla; el resultado (filas y ruta) queda en vista.exp.
async function exportarHist($: any, formato: 'csv' | 'json', v: Vista) {
  await update($, vistaA, x => ({ ...x, exp: 'Exportando…' }))
  try {
    const args = ['-Formato', formato, '-Proveedor', v.fprov, '-Estado', v.fest, '-Origen', v.forig, '-Orden', v.orden, ...(v.q ? ['-Q', v.q] : [])]
    const r = await $.process.run([...PS, script($, 'exportar-historial.ps1'), ...args], { timeoutMs: 30000 })
    await update($, vistaA, x => ({ ...x, exp: ultimaLinea(r.stdout) || 'Sin salida del exportador.' }))
  } catch (err) {
    await update($, vistaA, x => ({ ...x, exp: 'Falló la exportación: ' + String(err).slice(0, 100) }))
  }
}
type Motor = { id: string; nombre: string; disponible: boolean; estado: string; modelo: string; modelo_pedido?: string | null; modelo_verificado?: string | null; fuente?: string }
type Datos = {
  eventos?: Evento[]
  motores?: Motor[]
  horas?: Hora[]; deleg_total?: number; deleg_n?: number; claude_costo?: number
  ses_deleg?: number; ses_n?: number; ses_costo?: number
  glob?: { ses: number; tin: number; tout: number; hoy: number; semana: number; mes: number; codex: number; agy: number; errores: number; sin_dato: number }
  presup?: { tope: number; hoy: number; aviso: number; cache: number; arena: string }
  ef?: { dias: number; exitosas: number; exitosas_con_tokens: number; directas_justificadas: number; oportunidades_perdidas: number; fallidas: number; fallas_recuperadas: number; tokens_delegados: number; ahorro_neto_estimado: number; elegibles: number; tasa_delegacion_util: number | null; recomendaciones: string[]; metodologia: string }
  activo?: boolean; modo?: string; calidad?: string; manual?: { codex: { modelo: string; esfuerzo: string }; agy: { modelo: string } }
  dias?: { d: string; codex: number; agy: number; costo: number; n: number }[]
  activas?: number; max?: number; tarjetas: Tarjeta[]; pesada?: { msgs: number; ctx: number } | null
}

const datos = atom({ plugin: 'multi-ia-orquestador', key: 'datos' } as const, { tarjetas: [] } as Datos, {
  shape: 'datos-8',
})
const actualizado = atom({ plugin: 'multi-ia-orquestador', key: 'actualizado' } as const, '', {
  shape: 'actualizado-1',
})
const abierto = atom({ plugin: 'multi-ia-orquestador', key: 'abierto' } as const, false, {
  shape: 'abierto-1',
})

// Latido: cuando se leyo por ultima vez cada cosa (ms), si hay una lectura de cupos en curso y el ultimo error.
// movs: cambios de cupo detectados en esta sesion (para que la consola muestre vida aunque no se delegue nada).
type Mov = { f: string; t: string }
type Latido = { rap: number; cupos: number; leyendo: boolean; err: string; movs: Mov[] }
const latido = atom({ plugin: 'multi-ia-orquestador', key: 'latido' } as const, { rap: 0, cupos: 0, leyendo: false, err: '', movs: [] } as Latido, {
  shape: 'latido-3',
})
const ahoraIso = () => new Date(Date.now() - new Date().getTimezoneOffset() * 60000).toISOString().slice(0, 19)

// Compara los % de la lectura anterior con la nueva y devuelve una linea por cada ventana que cambio.
function cambiosDeCupo(antes: Tarjeta[], ahora: Tarjeta[]): string[] {
  const out: string[] = []
  for (const t of ahora) {
    const previa = antes.find(x => x.nombre === t.nombre)
    if (!previa) continue
    for (const w of t.ventanas) {
      const p = previa.ventanas.find(x => x.v === w.v)
      if (p && p.usado !== w.usado) out.push(t.nombre + ' · ' + (w.v === '5 h' ? 'sesión 5 h' : w.v === 'Semanal' ? 'semanal' : w.v) + ': ' + p.usado + '% → ' + w.usado + '%')
    }
  }
  return out
}

const filtroCons = atom({ plugin: 'multi-ia-orquestador', key: 'filtro' } as const, 'todo', {
  shape: 'filtro-1',
})
const ctrlAbierto = atom({ plugin: 'multi-ia-orquestador', key: 'ctrl' } as const, false, {
  shape: 'ctrl-1',
})

// Reinicio: paso 'confirmar' muestra el chequeo previo y pide un segundo toque; 'corriendo' bloquea los botones.
type Reinicio = { paso: 'idle' | 'revisando' | 'confirmar' | 'corriendo'; modo: 'claude' | 'orquestador'; msg: string }
const reinicio = atom({ plugin: 'multi-ia-orquestador', key: 'reinicio' } as const, { paso: 'idle', modo: 'claude', msg: '' } as Reinicio, {
  shape: 'reinicio-1',
})
// ---------- Chats (1.9.0): consumo por conversacion. Se lee BAJO DEMANDA (al abrir la seccion o con "Actualizar"), nunca en el ciclo de 4 s:
// chats.ps1 usa el cache incremental de transcripts (~10 s) y el resultado se reutiliza 60 s.
type NivelDato = { valor: number | null; nivel: string; fuente?: string; aclaracion?: string; mensajes?: number; filas?: number; parcial?: boolean; cache_lectura?: number }
type ChatInfo = { id_chat: string; estado: string; primera: string; ultima: string; ejecuciones_activas_confirmadas: number; delegaciones: number; errores: number; frescura?: { edad_seg?: number }; consumo: { claude_real: NivelDato; claude_estimado_delegaciones: NivelDato; codex: NivelDato; antigravity: NivelDato }; no_real?: { filas: number } }
type EjecInfo = { id_ejecucion: string; id_chat: string; motor: string; modelo: string; tarea: string; estado: string; frescura: string; inicio: string; duracion_seg: number; duracion_nivel: string; clase?: string; causa?: string; fecha: string }
type ChatsJson = { generado: string; chat_actual: string | null; chats: ChatInfo[]; ejecuciones_activas_ahora: EjecInfo[]; ejecuciones_recientes: EjecInfo[]; resumen_general: any; nota: string }
type ChatsEstado = { j: ChatsJson | null; t: number; leyendo: boolean; err: string; sel: string; est: string; fmotor: string; fest: string; msg: string }
const chatsA = atom({ plugin: 'multi-ia-orquestador', key: 'chats' } as const,
  { j: null, t: 0, leyendo: false, err: '', sel: 'actual', est: 'todos', fmotor: 'todos', fest: 'todos', msg: '' } as ChatsEstado, { shape: 'chats-1' })
let leyendoChats = false
async function cargarChats($: any, forzar = false) {
  if (leyendoChats) return
  // El candado se toma ANTES del primer await: si no, dos llamadas casi simultáneas pasan las dos y lanzan chats.ps1 dos veces.
  leyendoChats = true
  let c: ChatsEstado
  try { c = await read($, chatsA) } catch { leyendoChats = false; return }
  if (!forzar && c.j && Date.now() - c.t < 60000) { leyendoChats = false; return }
  // Un guardado que pierde la carrera contra otro (update agota sus reintentos) no debe dejar el candado puesto ni
  // escapar como rechazo sin manejar: se reintenta en el próximo ciclo de dibujo.
  const guardar = async (f: (x: ChatsEstado) => ChatsEstado) => { try { await update($, chatsA, f) } catch { /* se reintenta solo */ } }
  try {
    await guardar(x => ({ ...x, leyendo: true, err: '' }))
    const r = await $.process.run([...PS, script($, 'chats.ps1')], { timeoutMs: 90000 })
    const j = JSON.parse(String(r.stdout || '').replace(/^﻿/, '').trim()) as ChatsJson
    await guardar(x => ({ ...x, j, t: Date.now(), leyendo: false, err: '' }))
  } catch (err) {
    await guardar(x => ({ ...x, leyendo: false, err: 'No se pudo leer chats: ' + String(err).slice(0, 100) }))
  } finally { leyendoChats = false }
}
async function exportarChats($: any, formato: 'json' | 'md') {
  await update($, chatsA, x => ({ ...x, msg: 'Exportando…' }))
  try {
    const r = await $.process.run([...PS, script($, 'chats.ps1'), '-Formato', formato, '-Guardar'], { timeoutMs: 90000 })
    await update($, chatsA, x => ({ ...x, msg: ultimaLinea(r.stdout) || 'Sin salida del exportador.' }))
  } catch (err) {
    await update($, chatsA, x => ({ ...x, msg: 'Falló la exportación: ' + String(err).slice(0, 100) }))
  }
}
const ultimaLinea = (s: unknown) => String(s || '').split(/\r?\n/).map(x => x.trim()).filter(Boolean).pop() || ''

async function pedirReinicio($: any, modo: 'claude' | 'orquestador') {
  await update($, reinicio, () => ({ paso: 'revisando', modo, msg: 'Revisando trabajo pendiente…' }))
  try {
    const r = await $.process.run([...PS, script($, 'reiniciar-claude.ps1'), '-Modo', modo, '-Si', '-DryRun'], { timeoutMs: 30000 })
    await update($, reinicio, () => ({ paso: 'confirmar', modo, msg: ultimaLinea(r.stdout) || 'Listo para reiniciar.' }))
  } catch (err) {
    await update($, reinicio, () => ({ paso: 'idle', modo, msg: 'No se pudo revisar: ' + String(err).slice(0, 80) }))
  }
}

// En modo claude el script lanza un supervisor externo y la app se cierra: esta llamada puede no volver.
async function ejecutarReinicio($: any, modo: 'claude' | 'orquestador') {
  await update($, reinicio, () => ({ paso: 'corriendo', modo, msg: modo === 'claude' ? 'Reiniciando Claude… la ventana se va a cerrar y a volver sola.' : 'Reiniciando el orquestador…' }))
  try {
    const r = await $.process.run([...PS, script($, 'reiniciar-claude.ps1'), '-Modo', modo, '-Si'], { timeoutMs: 120000 })
    await update($, reinicio, () => ({ paso: 'idle', modo, msg: ultimaLinea(r.stdout) || 'Listo.' }))
  } catch (err) {
    await update($, reinicio, () => ({ paso: 'idle', modo, msg: 'Falló el reinicio: ' + String(err).slice(0, 100) + ' (detalle en la consola / reinicios.jsonl)' }))
  }
}

// Paleta: azul marino oscuro, tarjetas teñidas por IA y un acento por nivel de uso.
// 2.3.0 PIXEL PRO · Matte Violet: violeta mate plano, glow mínimo; pixel art solo en íconos y mascota. Claude #ff9b38 · Codex #32d8f2 · Antigravity #b67aff.
const FONDO = '#21102f'
const PANEL = '#2c173e'
const BORDE = '#4a2d63'
// Un color fijo por proveedor (coral Claude, cian Codex, violeta Antigravity) en todas las secciones.
const colorIa = (n: string) => (n.startsWith('Claude') ? '#ff9b38' : n.startsWith('Codex') ? '#32d8f2' : '#b67aff')   // 2.3.0 Pixel Pro: Claude naranja, Codex cian, Antigravity violeta
const tinte = (n: string) => (n.startsWith('Claude') ? '#33192a' : n.startsWith('Codex') ? '#14263a' : '#2a1a40')
const colorUso = (p: number) => (p >= 80 ? '#ff6b81' : p >= 50 ? '#ffc857' : '#43e889')
const fmt = (n: number): string => (n < 0 ? '-' + fmt(-n) : n >= 1e6 ? (n / 1e6).toFixed(1) + ' M' : n >= 1e3 ? Math.round(n / 1e3) + ' k' : String(Math.round(n)))

const DIAS = ['dom.', 'lun.', 'mar.', 'mié.', 'jue.', 'vie.', 'sáb.']
const cuando = (iso?: string) => {
  if (!iso) return ''
  const d = new Date(iso)
  if (isNaN(d.getTime())) return ''
  const h = d.getHours()
  const m = String(d.getMinutes()).padStart(2, '0')
  return 'renueva ' + DIAS[d.getDay()] + ' ' + (h % 12 || 12) + ':' + m + (h >= 12 ? ' p. m.' : ' a. m.')
}

// Barra fina: una linea continua, llena en el color del nivel y el resto en gris azulado.
const ANCHO = 22   // 34 se partia en dos renglones en el panel lateral angosto
const trazo = (p: number, ancho = ANCHO) => {
  const n = Math.max(p > 0 ? 1 : 0, Math.min(ancho, Math.round((ancho * p) / 100)))
  return [n, ancho - n] as const
}

// ---------- Sistema de diseño (tokens) ----------
const T = {
  fondo: '#21102f', panel: '#2c173e', vidrio: '#352047', borde: '#4a2d63', cian: '#32d8f2', texto: '#f5f0fa', tenue: '#b8a8c8',
  ok: '#43e889', aviso: '#ffc857', error: '#ff6b81', info: '#32d8f2',
  // Crystal Pro: violeta = consumo, magenta = acento de marca, cian = delegación/telemetría, verde = trabajo delegado/disponible, ámbar = costos, coral = eventos/errores.
  violeta: '#ba75f5', magenta: '#d58cff', coral: '#ff6b81', ambar: '#ffc857', okSuave: '#43e889', errorSuave: '#ff6b81', ahorro: '#43e889', desconectado: '#8e7ba3',
  // Superficies tintadas (todas derivadas de la paleta; nada de hex sueltos en las vistas).
  sCoral: '#3a1c2a', sCian: '#16283a', sVidrio: '#331e45', sHondo: '#1c0d28', sActivo: '#3d2456',
  // 2.2.0 Crystal Pro: capas L0 fondo · L1 pieza (sVidrio→sHondo) · L2 baldosa elevada (sActivo) · hundido = pistas y bandejas.
  hundido: '#180b23', lila: '#d6b8ff', brillo: '#efe4ff',
  fs: { mini: 9.5, chico: 10.5, base: 12, sub: 14, tit: 17, kpi: 22 },   // escala tipográfica única
  rad: { s: 10, m: 14, l: 18 },                                          // escala de radios
  r: 14, sombra: '0 0 12px rgba(167,139,250,.18)', fuente: 'system-ui,Segoe UI,sans-serif',
  anchoCompacto: 440, altoConsolaMax: 150,
  util: 416,       // ancho MÁXIMO de un SVG en compacto; los SVG son fluidos (width 100 % + viewBox) y encogen hasta ~296 px en un panel de 320 px
  utilExp: 1010,   // ancho de la columna de contenido del Centro de control: 80 % de (1280 − 2×8 de padding) ≈ 1011 (2.3.1: antes 960 y no llenaba la columna)
  anchoCabExp: 1246, // cabecera del Centro: menú 18 % + gap 8 + contenido 80 % de 1264 (2.3.1: alinea la cabecera con el borde derecho del contenido)
}

// Vista compartida por los dos paneles (compacto y Centro de control): misma fuente, estados de interfaz aparte.
// V3: seccion = resumen | motores | actividad | consumo | sistema. Historial: busqueda (q), proveedor, estado, origen, orden, fila elegida (sel) y resultado de la ultima exportacion (exp).
type Vista = { rango: '24h' | '7d' | '30d'; seccion: string; ocultas: string[]; plegadas: string[]; q: string; cp: number; filtro: string; fprov: string; fest: string; forig: string; orden: string; sel: string; exp: string; alc?: 'chat' | 'global' }
const vistaA = atom({ plugin: 'multi-ia-orquestador', key: 'vista' } as const,
  { rango: '24h', seccion: 'resumen', ocultas: [], plegadas: [], q: '', cp: 0, filtro: 'todo', fprov: 'todo', fest: 'todo', forig: 'prod', orden: 'nuevo', sel: '', exp: '', alc: 'global' } as Vista, { shape: 'vista-2' })   // alc es opcional (ausente = global): sin cambio de forma

// Estados del reactor, atados a eventos REALES del ciclo de vida (seleccionado > inicio > confirmado > recibido > fin|error):
//  Desconectado (apagado o panel sin señal) · Analizando (llegó un pedido y nadie decidió todavía) · Seleccionando (motor elegido, sin lanzar)
//  Delegando (lanzado, la CLI aún no confirmó) · Esperando (lanzado hace > 20 s sin confirmación) · Ejecutando (la CLI confirmó) · Completado · Error · Disponible.
type EstadoReactor = { t: string; c: string }
function estadoReactor(ev: Evento[], ahora: number, encendido: boolean, sinSenal: boolean, analizando: boolean): EstadoReactor {
  const ms = (f: string) => new Date(f).getTime()
  const cerrados = new Set(ev.filter(v => (v.t === 'fin' || v.t === 'error') && v.i).map(v => v.i as string))
  const lanzados = new Set(ev.filter(v => v.t === 'inicio' && v.i).map(v => v.i as string))
  const activos = ev.filter((v, n) => v.t === 'inicio' && ahora - ms(v.f) < 30 * 60000 && (v.i ? !cerrados.has(v.i) : n === ev.length - 1))
  const sel = ev.filter(v => v.t === 'seleccionado' && v.i && !lanzados.has(v.i) && !cerrados.has(v.i) && ahora - ms(v.f) < 60000)
  const ultimoCierre = [...ev].reverse().find(v => v.t === 'fin' || v.t === 'error')
  const edad = ultimoCierre ? ahora - ms(ultimoCierre.f) : Infinity
  if (!encendido || sinSenal) return { t: 'Desconectado', c: T.desconectado }
  if (activos.length > 0) {
    const sufijo = activos.length > 1 ? ' · ' + activos.length + ' motores a la vez' : ''
    const confirmado = (v: Evento) => ev.some(e => e.i && e.i === v.i && (e.t === 'confirmado' || e.t === 'recibido'))
    if (activos.some(confirmado)) return { t: 'Ejecutando' + sufijo, c: T.ambar }
    if (activos.some(v => ahora - ms(v.f) > 20000)) return { t: 'Esperando' + sufijo, c: T.ambar }
    return { t: 'Delegando' + sufijo, c: T.cian }
  }
  if (sel.length > 0) return { t: 'Seleccionando', c: T.lila }
  if (analizando) return { t: 'Analizando', c: T.lila }
  if (ultimoCierre && ultimoCierre.t === 'error' && edad < 120000) return { t: 'Error', c: T.error }
  if (ultimoCierre && edad < 60000) return { t: 'Completado, sin verificar', c: T.ok }   // 2.3.0: exit 0 no es evaluación
  return { t: 'Disponible', c: T.cian }
}

const esc = (s: unknown) => String(s ?? '').replace(/[&<>"]/g, c => (c === '&' ? '&amp;' : c === '<' ? '&lt;' : c === '>' ? '&gt;' : '&quot;'))
const corta = (s: string, n: number) => { const x = String(s ?? ''), m = Math.max(2, n); return x.length > m ? x.slice(0, m - 1) + '…' : x }
const RM = '@media (prefers-reduced-motion: reduce){.p,.q{animation:none!important}}'

// Reactor: anillos con luz cian discreta; solo late si hay una ejecución real (y nunca con movimiento reducido).
const VERSION = '2.3.12'
// ---------- Vidrio premium 2.0.1: grafito + vidrio gris azulado, acentos cian / violeta / coral / ámbar ----------
// Fluido: el SVG ocupa el ancho disponible (hasta W) y escala su alto por el viewBox, así no desborda en 320–480 px.
const SVG0 = (W: number, H: number, inner: string) => '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ' + W + ' ' + H + '" width="100%" preserveAspectRatio="xMinYMin meet" style="max-width:' + W + 'px;height:auto;display:block" font-family="system-ui,Segoe UI,sans-serif">' + inner + '</svg>'
// 2.2.0 Crystal Pro: una pieza = relleno vertical sobrio (L1), borde que toma el acento arriba y se apaga abajo,
// UNA sombra y UN filete de luz superior. Sin resplandores borrosos ni capas radiales apiladas.
const vDefs = (id: string, ac: string) => '<defs>'
  + '<linearGradient id="' + id + 'f" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="' + T.sVidrio + '" stop-opacity=".96"/><stop offset="1" stop-color="' + T.sHondo + '" stop-opacity=".97"/></linearGradient>'
  + '<linearGradient id="' + id + 'b" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="' + ac + '" stop-opacity=".45"/><stop offset="1" stop-color="' + T.borde + '" stop-opacity=".55"/></linearGradient>'
  + '<filter id="' + id + 's" x="-10%" y="-20%" width="120%" height="160%"><feDropShadow dx="0" dy="2" stdDeviation="3" flood-color="#000" flood-opacity=".45"/></filter></defs>'
const vPieza = (id: string, x: number, y: number, w: number, h: number, r: number, sombra = true) =>
  '<rect x="' + (x + .5) + '" y="' + (y + .5) + '" width="' + (w - 1) + '" height="' + (h - 1) + '" rx="' + r + '" fill="url(#' + id + 'f)" stroke="url(#' + id + 'b)"' + (sombra ? ' filter="url(#' + id + 's)"' : '') + '/>'
  + '<rect x="' + (x + r) + '" y="' + (y + 1) + '" width="' + Math.max(0, w - 2 * r) + '" height="1" fill="#fff" fill-opacity=".12"/>'
// Bandeja hundida (L-1): pistas de barras y zonas de contenido dentro de una pieza.
const vHundido = (x: number, y: number, w: number, h: number, r: number) =>
  '<rect x="' + x + '" y="' + y + '" width="' + w + '" height="' + h + '" rx="' + r + '" fill="' + T.hundido + '" fill-opacity=".72" stroke="#fff" stroke-opacity=".06"/>'
// Pastilla con glow: el acento se usa solo en lo importante.
const vPildora = (x: number, y: number, txt: string, col: string, fuerte = false) => {
  const w = Math.round(txt.length * 5.7 + 18)
  return { w, s: '<rect x="' + x + '" y="' + y + '" width="' + w + '" height="17" rx="8.5" fill="' + col + '" fill-opacity="' + (fuerte ? '.26' : '.12') + '" stroke="' + col + '" stroke-opacity="' + (fuerte ? '.85' : '.4') + '" stroke-width=".9"/>'
    + '<text x="' + (x + w / 2) + '" y="' + (y + 12) + '" font-size="10" font-weight="' + (fuerte ? 700 : 500) + '" text-anchor="middle" fill="' + (fuerte ? '#fff' : col) + '">' + esc(txt) + '</text>' }
}
// 2.2.0: ids únicos por dibujo. Varios SVG en la misma página no deben compartir gradientes ni filtros (antes 'k0', 'm', 't'… chocaban).
let nid = 0
const uid = (p: string) => p + (++nid)
// 2.3.0 Pixel Pro: mascota original «Chispa» en pixel art (10×10 celdas): robot-chip naranja con antena. Sin hojas ni marcas ajenas.
// o = cuerpo (naranja Claude), s = sombra, e = ojos, w = brillo, a = antena (violeta primario).
const MASCOTA = ['....a.....', '....a.....', '..oooooo..', '.owoooooo.', '.ooeooeoo.', '.ooeooeoo.', 'soooooooos', '.ooossooo.', '..oooooo..', '..s....s..']
const MASC_COLOR: Record<string, string> = { o: '#ff9b38', s: '#c76a1e', e: '#21102f', w: '#ffd6a8', a: '#ba75f5' }
function svgMascota(x0: number, y0: number, px: number): string {
  let r = '<g shape-rendering="crispEdges" aria-label="Chispa, mascota Multi-IA">'
  MASCOTA.forEach((fila, y) => { for (let x = 0; x < fila.length; x++) { const c = MASC_COLOR[fila[x]]; if (c) r += '<rect x="' + (x0 + x * px) + '" y="' + (y0 + y * px) + '" width="' + px + '" height="' + px + '" fill="' + c + '"/>' } })
  return r + '</g>'
}
// Cabecera Crystal Pro (2.2.0): ancho completo, una sola pieza: logo, Multi-IA, versión, subtítulo y píldora de estado.
// Ya no carga las píldoras de intensidad/modo: el modo vive en la tarjeta Reactor y la intensidad en Sistema.
// Píldora de estado del sistema (no del reactor): Encendido · Apagado · Sin señal.
function svgCabecera(W: number, encendido: boolean, sinSenal: boolean): string {
  const H = 58, id = uid('h'), im = id + 'm'
  const eTxt = !encendido ? 'Apagado' : sinSenal ? 'Sin señal' : 'Encendido'
  const ce = !encendido ? T.desconectado : sinSenal ? T.aviso : T.ok, ew = Math.round(eTxt.length * 6.2 + 30)
  const vx = 124, vw = String(VERSION).length * 6 + 14
  const ex = W - ew - 12, ey = 12
  const sub = Math.floor((ex - 56) / 5.2)
  const logo = svgMascota(13, 9, 3)
  return SVG0(W, H, vDefs(id, T.violeta)
    + '<defs><linearGradient id="' + im + '" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#ffffff"/><stop offset="1" stop-color="' + T.brillo + '"/></linearGradient></defs>'
    + vPieza(id, 1, 1, W - 2, H - 2, T.rad.l)
    + logo
    + '<text x="52" y="27" font-size="' + T.fs.tit + '" font-weight="800" letter-spacing=".3" fill="url(#' + im + ')">Multi-IA</text>'
    + (vx + vw < ex - 4 ? '<rect x="' + vx + '" y="14" width="' + vw + '" height="15" rx="7.5" fill="' + T.violeta + '" fill-opacity=".14" stroke="' + T.violeta + '" stroke-opacity=".5" stroke-width=".7"/>'
      + '<text x="' + (vx + vw / 2) + '" y="25" font-size="' + T.fs.mini + '" text-anchor="middle" fill="' + T.brillo + '">v' + esc(VERSION) + '</text>' : '')
    + '<text x="52" y="43" font-size="' + T.fs.chico + '" fill="' + T.tenue + '">' + esc(corta('Orquestador multi-motor inteligente', sub)) + '</text>'
    + '<rect x="' + ex + '" y="' + ey + '" width="' + ew + '" height="20" rx="10" fill="' + ce + '" fill-opacity=".14" stroke="' + ce + '" stroke-opacity=".55"/>'
    + '<circle cx="' + (ex + 11) + '" cy="' + (ey + 10) + '" r="5.5" fill="' + ce + '" fill-opacity=".18"/><circle cx="' + (ex + 11) + '" cy="' + (ey + 10) + '" r="3" fill="' + ce + '"/>'
    + '<text x="' + (ex + 20) + '" y="' + (ey + 14) + '" font-size="' + T.fs.chico + '" font-weight="700" fill="' + T.texto + '">' + esc(eTxt) + '</text>')
}
// Tabla de motores (2.2.0, referencia Crystal Pro): una sola pieza con «N activos», píldora de estado y barras Sesión 5 h / Semanal 7 d con %.
type FilaMotor = { nombre: string; ok: boolean; color: string; u5: number | null; u7: number | null }
const hTablaMotores = (n: number) => 40 + Math.max(1, n) * 46 + 6
function svgTablaMotores(W: number, filas: FilaMotor[]): string {
  const id = uid('tm'), H = hTablaMotores(filas.length), activos = filas.filter(f => f.ok).length
  const cn = Math.max(96, Math.round(W * 0.36)), bw = (W - cn - 14 - 12) / 2 - 8
  const barra = (x: number, y: number, u: number | null) => {
    const ok = u != null && isFinite(u), cc = ok ? colorUso(u as number) : T.desconectado, w = ok ? ((u as number) > 0 ? Math.max(2, Math.round(bw * Math.min(100, u as number) / 100)) : 0) : 0
    return '<text x="' + (x + bw) + '" y="' + (y + 9) + '" font-size="10" font-weight="800" text-anchor="end" fill="' + cc + '">' + (ok ? u + '%' : '—') + '</text>'
      + '<rect x="' + x + '" y="' + (y + 14) + '" width="' + bw + '" height="6" rx="3" fill="' + T.hundido + '" fill-opacity=".85" stroke="#fff" stroke-opacity=".08"/>'
      + (w ? '<rect x="' + x + '" y="' + (y + 14) + '" width="' + w + '" height="6" rx="3" fill="' + cc + '" fill-opacity=".92"/>' : '')
  }
  const x5 = cn + 14, x7 = x5 + bw + 16
  let o = vDefs(id, T.violeta) + vPieza(id, 1, 1, W - 2, H - 2, 16, false)
    + '<text x="14" y="23" font-size="14" font-weight="700" fill="' + T.texto + '">⌘ Motores</text>'
    + '<text x="' + (W - 14) + '" y="23" font-size="10.5" font-weight="700" text-anchor="end" fill="' + T.ok + '">' + activos + ' ' + (activos === 1 ? 'activo' : 'activos') + '</text>'
    + '<text x="' + x5 + '" y="38" font-size="9" font-weight="700" fill="' + T.tenue + '">SESIÓN 5 H</text>'
    + '<text x="' + x7 + '" y="38" font-size="9" font-weight="700" fill="' + T.tenue + '">SEMANAL 7 D</text>'
  filas.forEach((f, i) => {
    const y = 42 + i * 46, col = f.ok ? f.color : T.errorSuave, esAgy = !f.nombre.startsWith('Claude') && !f.nombre.startsWith('Codex')
    const est = f.ok ? '● Activo' : '● Inactivo', pw = Math.round(est.length * 5.4 + 12)
    o += '<line x1="12" y1="' + y + '" x2="' + (W - 12) + '" y2="' + y + '" stroke="#fff" stroke-opacity=".07"/>'
      + '<g transform="translate(0 ' + y + ')"><circle cx="24" cy="23" r="12" fill="#21102f" fill-opacity=".7" stroke="' + col + '" stroke-opacity=".8"/>'
      + (esAgy ? iconoAgy(col) : '<text x="24" y="28" font-size="13" text-anchor="middle" fill="' + col + '">' + (f.nombre.startsWith('Claude') ? '✺' : '⌘') + '</text>') + '</g>'
      + '<text x="44" y="' + (y + 19) + '" font-size="12" font-weight="700" fill="' + T.texto + '">' + esc(corta(f.nombre, Math.floor((cn - 40) / 6.6))) + '</text>'
      + '<rect x="44" y="' + (y + 25) + '" width="' + pw + '" height="14" rx="7" fill="' + col + '" fill-opacity=".16" stroke="' + col + '" stroke-opacity=".6" stroke-width=".8"/>'
      + '<text x="' + (44 + pw / 2) + '" y="' + (y + 35) + '" font-size="8.5" font-weight="700" text-anchor="middle" fill="' + col + '">' + est + '</text>'
      + barra(x5, y + 12, f.u5) + barra(x7, y + 12, f.u7)
  })
  return SVG0(W, H, o)
}
// Tamaño del valor del KPI: 21 px si entra; si no, se achica (mínimo 11) para que nunca se pise.
const tamValor = (v: string, ancho: number) => Math.max(11, Math.min(21, Math.floor(ancho / Math.max(1, String(v).length * 0.62))))
// KPIs Crystal Pro: baldosa L1 con punto de acento, rótulo, valor grande y una línea de delta/contexto (d) si hay dato real.
// Sin resplandores: el color vive en el punto y en el filete inferior.
const H_KPI = 72, GAP_KPI = 10
// Iconos pixel-art 7×7 propios (no son logos de terceros): '#' = píxel encendido.
const pix = (g: string[], x: number, y: number, p: number, col: string) => g.map((r, j) => Array.from(r).map((c, i) => c === '#' ? '<rect x="' + (x + i * p) + '" y="' + (y + j * p) + '" width="' + p + '" height="' + p + '" fill="' + col + '"/>' : '').join('')).join('')
const PIX: Record<string, string[]> = {
  claude: ['...#...', '#..#..#', '.#.#.#.', '..###..', '.#.#.#.', '#..#..#', '...#...'],
  codex: ['##.....', '.##....', '..##...', '.##....', '##.....', '.......', '....###'],
  agy: ['...#...', '..#.#..', '..#.#..', '.#...#.', '.#####.', '#.....#', '#.....#'],
  chip: ['.#.#.#.', '#######', '#.....#', '#.###.#', '#.....#', '#######', '.#.#.#.'],
  rayo: ['....##.', '...##..', '..##...', '.#####.', '...##..', '..##...', '.##....'],
  moneda: ['..###..', '.#...#.', '#..#..#', '#.###.#', '#..#..#', '.#...#.', '..###..'],
  monedas: ['.#####.', '#.....#', '.#####.', '#.....#', '.#####.', '#.....#', '.#####.'],
}
const pixMotor = (ia: string) => PIX[ia.startsWith('Claude') ? 'claude' : ia.startsWith('Codex') ? 'codex' : 'agy']
const hKpis = (n: number, cols: number) => { const rows = Math.max(1, Math.ceil(n / cols)); return rows * H_KPI + (rows - 1) * GAP_KPI }
function svgKpis(W: number, cols: number, items: { v: string; r: string; c: string; d?: string; dc?: string; ic?: string }[]): string {
  const gap = GAP_KPI, h = H_KPI, tw = (W - gap * (cols - 1)) / cols, H = hKpis(items.length, cols)
  const tiles = items.map((it, i) => {
    const x = (i % cols) * (tw + gap), y = Math.floor(i / cols) * (h + gap), id = uid('k')
    return vDefs(id, it.c) + vPieza(id, x, y, tw, h, T.rad.m, false)
      + '<circle cx="' + (x + 17) + '" cy="' + (y + 18) + '" r="3.4" fill="' + it.c + '"/>'
      + '<text x="' + (x + 27) + '" y="' + (y + 21.5) + '" font-size="' + T.fs.chico + '" fill="' + T.tenue + '">' + esc(corta(it.r, Math.floor((tw - (it.ic ? 62 : 36)) / 5.6))) + '</text>'
      + (it.ic ? pix(PIX[it.ic], x + tw - 26, y + 9, 2.4, it.c) : '')
      + '<text x="' + (x + 13) + '" y="' + (y + 47) + '" font-size="' + tamValor(it.v, tw - 26) + '" font-weight="800" fill="#ffffff">' + esc(it.v) + '</text>'
      + (it.d ? '<text x="' + (x + 13) + '" y="' + (y + 62) + '" font-size="' + T.fs.mini + '" font-weight="600" fill="' + (it.dc || T.tenue) + '">' + esc(corta(it.d, Math.floor((tw - 26) / 5.2))) + '</text>' : '')
      + '<rect x="' + (x + T.rad.m) + '" y="' + (y + h - 2.5) + '" width="' + Math.max(0, tw - 2 * T.rad.m) + '" height="1.5" rx=".75" fill="' + it.c + '" fill-opacity=".5"/>'
  }).join('')
  return SVG0(W, H, tiles)
}
// Fila de motor: vidrio con el color propio del motor, medallón con glifo, nombre y estado.
// Icono ORIGINAL de Antigravity: una «A» con órbita elíptica y satélite (no es el logo de Google ni de terceros).
const iconoAgy = (col: string) => '<ellipse cx="24" cy="23" rx="11.5" ry="4.6" transform="rotate(-32 24 23)" fill="none" stroke="' + col + '" stroke-width="1.2" stroke-opacity=".85"/>'
  + '<path d="M18.6 30 L24 15.8 L29.4 30 M20.7 25.2 H27.3" fill="none" stroke="' + col + '" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/>'
  + '<circle cx="33.2" cy="17.6" r="1.7" fill="' + T.magenta + '"/>'
type CuotaM = { r: string; u: number | null; nota: string }
const hMotor = (n: number) => 46 + (n ? 46 : 0)
function svgMotor(W: number, nombre: string, ok: boolean, modelo: string | null | undefined, color: string, cuotas: CuotaM[] = []): string {
  const H = hMotor(cuotas.length), col = ok ? color : T.errorSuave, mi = uid('m')
  const esAgy = !nombre.startsWith('Claude') && !nombre.startsWith('Codex')
  const gl = nombre.startsWith('Claude') ? '✺' : '⌘'
  const est = ok ? '● Activo' : '● No disponible', pw = Math.round(est.length * 5.8 + 14)
  // Columnas lado a lado (Sesión 5 h | Semanal 7 d), como en la referencia visual.
  const n = Math.max(1, cuotas.length), cw = (W - 28 - 14 * (n - 1)) / n
  const barras = cuotas.map((q, i) => {
    const x = 14 + i * (cw + 14), cc = q.u == null || !isFinite(q.u) ? T.desconectado : colorUso(q.u), w = q.u == null || !isFinite(q.u) ? 0 : (q.u > 0 ? Math.max(2, Math.round(cw * Math.min(100, q.u) / 100)) : 0)
    const rot = q.r === '5 h' ? 'Sesión (5 h)' : q.r === '7 d' ? 'Semanal (7 d)' : q.r
    return '<text x="' + x + '" y="60" font-size="9.5" font-weight="700" fill="' + T.tenue + '">' + esc(corta(rot, Math.floor(cw / 5.4))) + '</text>'
      + '<text x="' + (x + cw) + '" y="60" font-size="10" font-weight="800" text-anchor="end" fill="' + cc + '">' + (q.u == null || !isFinite(q.u) ? '—' : q.u + '%') + '</text>'
      + '<rect x="' + x + '" y="66" width="' + cw + '" height="7" rx="3.5" fill="#fff" fill-opacity=".08"/>'
      + (w ? '<rect x="' + x + '" y="66" width="' + w + '" height="7" rx="3.5" fill="' + cc + '" fill-opacity=".92"/>' : '')
      + '<text x="' + x + '" y="85" font-size="8.5" fill="' + T.tenue + '">' + esc(corta(q.nota, Math.floor(cw / 4.4))) + '</text>'
  }).join('')
  return SVG0(W, H, vDefs(mi, col) + vPieza(mi, 1, 1, W - 2, H - 2, 15, false)
    + '<circle cx="24" cy="23" r="13" fill="' + T.fondo + '" fill-opacity=".7" stroke="' + col + '" stroke-opacity=".8"/>'
    + (esAgy ? iconoAgy(col) : '<text x="24" y="28" font-size="14" text-anchor="middle" fill="' + col + '">' + gl + '</text>')
    + barras
    + '<text x="46" y="21" font-size="13.5" font-weight="700" fill="' + T.texto + '">' + esc(nombre) + '</text>'
    + '<text x="46" y="35" font-size="10.5" fill="' + T.tenue + '">' + esc(corta(modelo || 'modelo sin verificar', Math.floor((W - 160) / 5))) + '</text>'
    + '<rect x="' + (W - pw - 12) + '" y="14" width="' + pw + '" height="18" rx="9" fill="' + col + '" fill-opacity=".16" stroke="' + col + '" stroke-opacity=".6"/>'
    + '<text x="' + (W - 12 - pw / 2) + '" y="26.5" font-size="10" font-weight="700" text-anchor="middle" fill="' + col + '">' + est + '</text>')
}
function svgReactor(color: string, vivo: boolean, px: number): string {
  const ri = uid('r')
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="${px}" height="${px}"><style>@keyframes g{0%,100%{opacity:.45}50%{opacity:1}}@keyframes r{to{transform:rotate(360deg)}}.p{${vivo ? 'animation:g 1.6s ease-in-out infinite' : ''}}.q{transform-origin:32px 32px;${vivo ? 'animation:r 6s linear infinite' : ''}}${RM}</style>`
    + `<defs><radialGradient id="${ri}f" cx=".5" cy=".4" r=".7"><stop offset="0" stop-color="#4a2d63"/><stop offset="1" stop-color="#21102f"/></radialGradient><linearGradient id="${ri}b" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".4"/><stop offset=".5" stop-color="#fff" stop-opacity=".05"/><stop offset="1" stop-color="${color}" stop-opacity=".7"/></linearGradient><filter id="${ri}g" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="3"/></filter></defs>`
    + `<circle cx="32" cy="32" r="30" fill="${color}" fill-opacity=".38" filter="url(#${ri}g)"/><circle cx="32" cy="32" r="30.5" fill="none" stroke="${color}" stroke-width="2" stroke-opacity=".55" filter="url(#${ri}g)"/>`
    + `<circle cx="32" cy="32" r="29" fill="url(#${ri}f)" stroke="url(#${ri}b)" stroke-width="2"/>`
    + `<circle cx="32" cy="32" r="24" fill="none" stroke="${T.violeta}" stroke-width="2.4" opacity=".8"/>`
    + `<circle class="q" cx="32" cy="32" r="24" fill="none" stroke="${T.cian}" stroke-width="1.8" stroke-dasharray="14 137" stroke-linecap="round" opacity=".9"/>`
    + `<circle class="p" cx="32" cy="32" r="16" fill="none" stroke="${color}" stroke-width="2.5"/>`
    + `<circle class="p" cx="32" cy="32" r="11" fill="${color}" fill-opacity=".35" filter="url(#${ri}g)"/>`
    + `<circle class="p" cx="32" cy="32" r="7" fill="${color}"/><circle cx="30" cy="29.5" r="2.2" fill="#fff" fill-opacity=".55"/></svg>`
}

// Tarjeta de gráfico: barras agrupadas con escala "bonita", tooltips <title>, series ocultables y estado sin datos.
type Serie = { k: string; l: string; c: string; t: 'real' | 'calculado' | 'estimado'; v: number[] }
const bonito = (m: number) => { if (m <= 0) return 1; const e = Math.pow(10, Math.floor(Math.log10(m))); const f = m / e; return (f <= 1 ? 1 : f <= 2 ? 2 : f <= 5 ? 5 : 10) * e }
function svgGrafico(etq: string[], series: Serie[], ocultas: string[], W: number, H: number, fmtv: (n: number) => string): string {
  const vis = series.filter(s => !ocultas.includes(s.k))
  const L = 42, B = 18, Tp = 8, gi0 = uid('gr')
  let o = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${W} ${H}" width="100%" preserveAspectRatio="xMinYMin meet" style="max-width:${W}px;height:auto;display:block" font-family="${T.fuente}">` + vDefs(gi0, T.violeta) + vPieza(gi0, 1, 1, W - 2, H - 2, 16, false)
    + '<defs>' + series.map((s, i) => `<linearGradient id="${gi0}s${i}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${s.c}"/><stop offset="1" stop-color="${s.c}" stop-opacity=".35"/></linearGradient>`).join('') + '</defs>'
  const tiene = series.some(s => s.v.some(x => x > 0))
  if (!etq.length || !tiene) return o + `<text x="${W / 2}" y="${H / 2}" font-size="12" fill="${T.tenue}" text-anchor="middle">Sin datos registrados en este período</text></svg>`
  const max = bonito(Math.max(1, ...vis.flatMap(s => s.v)))
  const ph = H - Tp - B, pw = W - L - 8
  for (const f of [0, 0.5, 1]) {
    const y = Tp + ph - ph * f
    o += `<line x1="${L}" y1="${y}" x2="${W - 8}" y2="${y}" stroke="#fff" stroke-opacity=".12" stroke-dasharray="${f ? '2 3' : ''}"/><text x="${L - 4}" y="${y + 3.5}" font-size="10" fill="${T.tenue}" text-anchor="end">${fmtv(max * f)}</text>`
  }
  const n = etq.length, cw = pw / n, bw = Math.max(1, (cw * 0.78) / Math.max(1, vis.length))
  const paso = Math.ceil(n / 8)
  etq.forEach((e, i) => {
    const x0 = L + i * cw
    const tip = e + ' — ' + series.map(s => s.l + ': ' + fmtv(s.v[i] || 0) + ' (' + s.t + ')').join(' · ')
    o += `<g><title>${esc(tip)}</title><rect x="${x0}" y="${Tp}" width="${cw}" height="${ph}" fill="#fff" opacity="0"/>`
    vis.forEach((s, k) => {
      const v = s.v[i] || 0
      if (v <= 0) return
      const h = Math.max(1, (ph * v) / max)
      const bx = x0 + cw * 0.11 + k * bw, bww = Math.max(1, bw - 1.5), by = Tp + ph - h, gi = series.indexOf(s)
      o += `<rect x="${bx}" y="${by}" width="${bww}" height="${h}" rx="${Math.min(4, bww / 2)}" fill="url(#${gi0}s${gi})" ${s.t === 'real' ? '' : 'fill-opacity=".72"'}/><rect x="${bx + 1}" y="${by + 1}" width="${Math.max(0, bww - 2)}" height="${Math.min(3, h)}" rx="1" fill="#fff" fill-opacity=".3"/>`
    })
    o += '</g>'
    if (i % paso === 0) o += `<text x="${x0 + cw / 2}" y="${H - 5}" font-size="10" fill="${T.tenue}" text-anchor="middle">${esc(e)}</text>`
  })
  return o + '</svg>'
}

// ---------- Vidrio premium: piezas compartidas por Consumo, Consola, Chats, Sistema ----------
const SVG_AB = (W: number, H: number, extra = '') => '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ' + W + ' ' + H + '" width="100%" preserveAspectRatio="xMinYMin meet" style="max-width:' + W + 'px;height:auto;display:block" font-family="system-ui,Segoe UI,sans-serif">' + extra
// Cinta de título de sección: vidrio con luz del acento, medallón con glifo y dato a la derecha.
function svgTitulo(W: number, glifo: string, titulo: string, color: string, der = ''): string {
  const H = 38, ti = uid('t')
  return SVG_AB(W, H, vDefs(ti, color) + vPieza(ti, 1, 1, W - 2, H - 2, 14, false)
    + '<circle cx="22" cy="19" r="11" fill="' + color + '" fill-opacity=".12" stroke="' + color + '" stroke-opacity=".7"/>'
    + '<text x="22" y="23.5" font-size="' + T.fs.base + '" text-anchor="middle" fill="' + color + '">' + esc(glifo) + '</text>'
    + '<text x="42" y="23.5" font-size="' + T.fs.sub + '" font-weight="700" fill="' + T.texto + '">' + esc(titulo) + '</text>'
    + (der ? '<text x="' + (W - 14) + '" y="23" font-size="' + T.fs.chico + '" text-anchor="end" fill="' + color + '">' + esc(corta(der, Math.floor((W - 170) / 5.4))) + '</text>' : '') + '</svg>')
}
// Ícono de pestaña (navegación 3×2): trazo fino sobre una pastilla hundida; el activo lleva el acento violeta.
const ICONOS: Record<string, string> = {
  resumen: '<rect x="1" y="1" width="7" height="7" rx="2"/><rect x="12" y="1" width="7" height="7" rx="2"/><rect x="1" y="12" width="7" height="7" rx="2"/><rect x="12" y="12" width="7" height="7" rx="2"/>',
  motores: '<path d="M10 1 L18 5.5 L18 14.5 L10 19 L2 14.5 L2 5.5 Z"/><circle cx="10" cy="10" r="3"/>',
  actividad: '<path d="M1 10 H5 L7.5 3 L12 17 L14.5 10 H19"/>',
  consumo: '<path d="M2 19 H18"/><rect x="3" y="10" width="3" height="7" rx="1"/><rect x="8.5" y="5" width="3" height="12" rx="1"/><rect x="14" y="2" width="3" height="15" rx="1"/>',
  chats: '<path d="M3 3 H17 a2 2 0 0 1 2 2 V12 a2 2 0 0 1 -2 2 H9 L5 18 V14 H3 a2 2 0 0 1 -2 -2 V5 a2 2 0 0 1 2 -2 Z"/>',
  sistema: '<path d="M2 5 H18 M2 10 H18 M2 15 H18"/><circle cx="6" cy="5" r="2" fill="' + FONDO + '"/><circle cx="13" cy="10" r="2" fill="' + FONDO + '"/><circle cx="8" cy="15" r="2" fill="' + FONDO + '"/>',
}
const H_ICONO = 30
function svgIcono(W: number, sec: string, activo: boolean): string {
  const c = activo ? T.lila : T.tenue, x = Math.round(W / 2 - 10)
  return SVG_AB(W, H_ICONO, (activo ? '<rect x="' + (W / 2 - 22) + '" y="1" width="44" height="' + (H_ICONO - 2) + '" rx="' + T.rad.s + '" fill="' + T.violeta + '" fill-opacity=".16" stroke="' + T.violeta + '" stroke-opacity=".5"/>' : '')
    + '<g transform="translate(' + x + ' 5)" fill="none" stroke="' + c + '" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">' + (ICONOS[sec] || '') + '</g></svg>')
}
// Barras horizontales de vidrio con pista hundida, degradado del acento y brillo.
type BarraH = { l: string; txt: string; p: number; c: string; sub?: string }
function svgBarrasH(W: number, items: BarraH[]): string {
  const rh = 42, H = Math.max(1, items.length) * rh + 10, bx = 16, bw = W - 32
  const bi = uid('bh')
  let o = SVG_AB(W, H, vDefs(bi, T.violeta) + vPieza(bi, 1, 1, W - 2, H - 2, 16, false))
  items.forEach((it, i) => {
    const y = 10 + i * rh, w = Math.max(it.p > 0 ? 8 : 0, Math.min(bw, bw * it.p / 100)), id = bi + 'i' + i
    o += '<defs><linearGradient id="' + id + '" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="' + it.c + '" stop-opacity=".5"/><stop offset="1" stop-color="' + it.c + '"/></linearGradient></defs>'
      + '<circle cx="' + (bx + 4) + '" cy="' + (y + 8) + '" r="3.5" fill="' + it.c + '"/>'
      + '<text x="' + (bx + 14) + '" y="' + (y + 12) + '" font-size="11.5" font-weight="600" fill="' + T.texto + '">' + esc(corta(it.l, Math.floor(bw / 8))) + '</text>'
      + '<text x="' + (W - 16) + '" y="' + (y + 12) + '" font-size="11.5" font-weight="700" text-anchor="end" fill="' + it.c + '">' + esc(it.txt) + '</text>'
      + vHundido(bx, y + 19, bw, 9, 4.5)
      + (w > 0 ? '<rect x="' + bx + '" y="' + (y + 19) + '" width="' + w + '" height="9" rx="4.5" fill="url(#' + id + ')"/><rect x="' + (bx + 3) + '" y="' + (y + 20.5) + '" width="' + Math.max(0, w - 6) + '" height="2.2" rx="1.1" fill="#fff" fill-opacity=".28"/>' : '')
      + (it.sub ? '<text x="' + bx + '" y="' + (y + 40) + '" font-size="10.5" fill="' + T.tenue + '">' + esc(corta(it.sub, Math.floor(bw / 5))) + '</text>' : '')
  })
  return o + '</svg>'
}
// Línea del reactor: vidrio con el estado real, motores activos (pulso), delegaciones de 24 h y modo efectivo.
// Tarjeta Reactor (2.2.0, referencia Crystal Pro): anillo + «Reactor · estado», modo efectivo y delegaciones de 24 h en UNA pieza.
// El selector de modo es un Button real debajo (no se dibuja un botón falso dentro del SVG).
// Crystal Pro: el reactor es el protagonista: tarjeta de ~124 px con anillo de 100 px; el único resplandor del panel vive acá.
const H_REACTOR = 124, PX_ANILLO = 100
function svgTarjetaReactor(W: number, estado: string, color: string, encendido: boolean, vivo: boolean, motores: string[], n24: number, modo: string): string {
  const H = H_REACTOR, ce = encendido ? color : T.desconectado, li = uid('lr')
  const est = corta(encendido ? estado : 'Desconectado', 16), ax = 12, ay = (H - PX_ANILLO) / 2, tx = ax + PX_ANILLO + 14
  const mot = motores.length ? 'Activos: ' + motores.join(' · ') : (encendido ? 'Listo para delegar' : 'Multi-IA apagado')
  const act = n24 + ' ' + (n24 === 1 ? 'delegación' : 'delegaciones') + ' (24 h)'
  const cap = Math.max(10, Math.floor((W - tx - 12) / 5.6)), pw = Math.round(est.length * 6 + 26)
  // Si la píldora no entra al lado del título (320 px), baja a su propia línea.
  const pAl = tx + 70 + pw <= W - 12, px = pAl ? tx + 70 : tx, py = pAl ? 25 : 44
  const y0 = pAl ? 0 : 10
  const anillo = svgReactor(ce, vivo && encendido, PX_ANILLO).replace('<svg ', '<svg x="' + ax + '" y="' + ay + '" ')
  return SVG0(W, H, '<style>.pl{animation:pl 1.6s ease-in-out infinite}@keyframes pl{50%{opacity:.3}}@media (prefers-reduced-motion: reduce){.pl{animation:none!important}}</style>'
    + vDefs(li, ce) + vPieza(li, 1, 1, W - 2, H - 2, T.rad.l) + anillo
    + '<text x="' + tx + '" y="38" font-size="' + T.fs.tit + '" font-weight="800" fill="' + T.texto + '">Reactor</text>'
    + '<rect x="' + px + '" y="' + py + '" width="' + pw + '" height="18" rx="9" fill="' + ce + '" fill-opacity=".14" stroke="' + ce + '" stroke-opacity=".55"/>'
    + '<circle class="' + (motores.length ? 'pl' : '') + '" cx="' + (px + 10) + '" cy="' + (py + 9) + '" r="3.2" fill="' + ce + '"/>'
    + '<text x="' + (px + 18) + '" y="' + (py + 13) + '" font-size="' + T.fs.chico + '" font-weight="700" fill="' + T.texto + '">' + esc(est) + '</text>'
    + '<text x="' + tx + '" y="' + (64 + y0) + '" font-size="' + T.fs.base + '" fill="' + T.texto + '">' + esc(corta('Modo efectivo: ' + modo, cap)) + '</text>'
    + '<line x1="' + tx + '" y1="' + (76 + y0) + '" x2="' + (W - 14) + '" y2="' + (76 + y0) + '" stroke="#fff" stroke-opacity=".08"/>'
    + '<text x="' + tx + '" y="' + (94 + y0) + '" font-size="' + T.fs.chico + '" fill="' + (motores.length ? T.ambar : T.lila) + '">' + esc(corta(mot, cap)) + '</text>'
    + '<text x="' + tx + '" y="' + (108 + y0) + '" font-size="' + T.fs.chico + '" fill="' + T.tenue + '">' + esc(corta(act, cap)) + '</text>')
}
// Barra fina de cupo con pista hundida y brillo.
let contBarra = 0   // ids unicos por barra: dos barras en la misma pagina no deben compartir gradiente ni filtro
function svgBarraCupo(W: number, p: number, color: string): string {
  const k = 'q' + (++contBarra)
  const w = Math.max(p > 0 ? 6 : 0, Math.min(W - 2, (W - 2) * p / 100))
  return SVG_AB(W, 12, '<defs><linearGradient id="' + k + '" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="' + color + '" stop-opacity=".45"/><stop offset="1" stop-color="' + color + '"/></linearGradient></defs>'
    + vHundido(1, 2, W - 2, 8, 4)
    + (w > 0 ? '<rect x="1" y="2" width="' + w + '" height="8" rx="4" fill="url(#' + k + ')"/><rect x="3" y="3.2" width="' + Math.max(0, w - 4) + '" height="2" rx="1" fill="#fff" fill-opacity=".3"/>' : '') + '</svg>')
}
// Terminal de vidrio: motor (color + glifo) · hora · evento · estado (pastilla) · detalle.
type FilaT = { hora: string; c: string; a: string; tag: string; b?: string; ia?: string }
function svgTerminal(W: number, titulo: string, filas: FilaT[], activos: string[], total: number, vacio: string): string {
  const rh = 42, top = 60, n = Math.max(1, filas.length), H = top + n * rh + 10, cap = Math.floor((W - 190) / 5.8), ci = uid('c')
  let o = SVG_AB(W, H, '<style>.pl{animation:pl 1.6s ease-in-out infinite}@keyframes pl{50%{opacity:.3}}@media (prefers-reduced-motion: reduce){.pl{animation:none!important}}</style>'
    + vDefs(ci, '#32d8f2') + vPieza(ci, 1, 1, W - 2, H - 2, 18, false)
    + '<text x="16" y="22" font-size="14" font-weight="700" fill="' + T.texto + '">' + esc((titulo === 'Consola' ? '>_ Consola de Orquestación' : titulo)) + '</text>'
    + '<text x="' + (W - 16) + '" y="22" font-size="10" text-anchor="end" fill="' + T.tenue + '">' + total + ' registros</text>'
    + '<line x1="14" y1="31" x2="' + (W - 14) + '" y2="31" stroke="#fff" stroke-opacity=".09"/>')
  o += activos.length
    ? '<circle cx="20" cy="45" r="7" fill="' + T.ambar + '" fill-opacity=".16"/><circle class="pl" cx="20" cy="45" r="3.5" fill="#ffc857"/><text x="34" y="49" font-size="11" font-weight="600" fill="#ffc857">' + esc(corta('Activos: ' + activos.join(' · '), Math.floor((W - 50) / 5.8))) + '</text>'
    : '<circle cx="20" cy="45" r="3.5" fill="none" stroke="' + T.desconectado + '"/><text x="34" y="49" font-size="11" fill="' + T.tenue + '">Sin ejecuciones activas</text>'
  if (!filas.length) o += '<text x="18" y="' + (top + 26) + '" font-size="11.5" fill="' + T.tenue + '">' + esc(corta(vacio, Math.floor((W - 36) / 5.8))) + '</text>'
  filas.forEach((f, i) => {
    const y = top + i * rh, tw = f.tag.length * 6.2 + 16, x0 = W > 500 ? 104 : 96, capF = Math.max(6, Math.floor((W - 14 - tw - 8 - x0) / 6.6))   // 2.3.0: el título cede lugar a la pastilla («Completado, sin verificar» es larga)
    o += '<rect x="10" y="' + (y + 2) + '" width="' + (W - 20) + '" height="' + (rh - 5) + '" rx="10" fill="' + f.c + '" fill-opacity="' + (i % 2 ? '.05' : '.09') + '" stroke="' + f.c + '" stroke-opacity=".16" stroke-width=".7"/>'
      + (f.ia ? pix(pixMotor(f.ia), 14, y + 8, 1.7, colorIa(f.ia)) : '<rect x="14" y="' + (y + 8) + '" width="3.5" height="' + (rh - 17) + '" rx="1.75" fill="' + f.c + '"/>')
      + '<text x="32" y="' + (y + 18) + '" font-size="10.5" font-family="Consolas,ui-monospace,monospace" fill="' + T.tenue + '">' + esc(f.hora) + '</text>'
      + '<text x="' + x0 + '" y="' + (y + 18) + '" font-size="12" font-weight="600" fill="' + T.texto + '">' + esc(corta(f.a, Math.min(cap, capF))) + '</text>'
      + '<rect x="' + (W - 14 - tw) + '" y="' + (y + 7) + '" width="' + tw + '" height="16" rx="8" fill="' + f.c + '" fill-opacity=".2" stroke="' + f.c + '" stroke-opacity=".7" stroke-width=".9"/>'
      + '<text x="' + (W - 14 - tw / 2) + '" y="' + (y + 18.5) + '" font-size="10" font-weight="700" text-anchor="middle" fill="' + f.c + '">' + esc(f.tag) + '</text>'
      + (f.b ? '<text x="32" y="' + (y + 33) + '" font-size="10.5" fill="' + T.tenue + '">' + esc(corta(f.b, Math.floor((W - 56) / 5.4))) + '</text>' : '')
  })
  return o + '</svg>'
}
// Los botones responden al instante (se pinta lo elegido), config.ps1 guarda en segundo plano y la lectura
// periodica no pisa lo recien elegido durante unos segundos.
let ultimoCambio = 0
let guardando = 0

async function leerLimites($: any): Promise<Datos> {
  const r = await $.process.run([...PS, script($, 'limites.ps1'), '-Json'], { timeoutMs: 45000 })
  return JSON.parse(String(r.stdout || '').replace(/^﻿/, '').trim()) as Datos
}

// Desde este % de cupo de Claude (5 h o semanal) se activa el modo ahorro fuerte: delega con mas fuerza.
const PRESION = 75
function presionClaude(d: Datos | null | undefined): number {
  const t = d?.tarjetas?.find(x => x.nombre === 'Claude')
  return t ? Math.max(0, ...(t.ventanas ?? []).map(v => v.usado || 0)) : 0
}

// Guardas de "en curso": un ciclo lento no se pisa con el siguiente (antes se acumulaban procesos PowerShell y el leyendo:false del primero tapaba al segundo).
let temporizadores = false
let refrescando = false
let leyendoRapido = false
async function refrescar($: any) {
  if (refrescando) return
  refrescando = true
  try { await refrescarUna($) } finally { refrescando = false }
}
async function refrescarUna($: any) {
  await update($, latido, l => ({ ...l, leyendo: true }))
  try {
    // El cupo de Claude se lee de la sesion misma (la linea de estado no corre en la app de escritorio).
    // Sin ventana de 5 h activa (inactivo hace horas) se guarda 0 %.
    let claude: Tarjeta | null = null
    try {
      const u = await $.session.usage()
      const c = u.rateLimits.find((x: any) => x.kind === 'five_hour')
      const s7 = u.rateLimits.find((x: any) => x.kind === 'seven_day')
      if (s7) {
        claude = {
          nombre: 'Claude',
          ventanas: [
            { v: '5 h', usado: c ? Math.round(c.percentUsed) : 0, reinicia: c?.resetsAt || undefined },
            { v: 'Semanal', usado: Math.round(s7.percentUsed), reinicia: s7.resetsAt || undefined },
          ],
        }
        await $.process.run(
          [...PS, script($, 'claude-snapshot.ps1'), '-CincoHoras', String(c ? Math.round(c.percentUsed) : 0), '-CincoHorasReinicia', c?.resetsAt || '',
            '-Semanal', String(Math.round(s7.percentUsed)), '-SemanalReinicia', s7.resetsAt || ''],
          { timeoutMs: 20000 },
        )
      }
    } catch { /* sin datos de Claude: se muestra lo ultimo guardado */ }
    const j = await leerLimites($)
    // Eficiencia de orquestacion: calculada por eficiencia.ps1 con los eventos reales (si falla, se muestra lo ultimo).
    try {
      const re = await $.process.run([...PS, script($, 'eficiencia.ps1'), '-Json'], { timeoutMs: 15000 })
      j.ef = JSON.parse(String(re.stdout || '').replace(/^﻿/, '').trim())
    } catch { /* sin eficiencia nueva */ }
    // El % de Claude viene fresco de la sesion aunque la lectura de Codex/Antigravity venga de la cache.
    if (claude) j.tarjetas = j.tarjetas.map(t => (t.nombre === 'Claude' ? claude as Tarjeta : t))
    const reciente = guardando > 0 || Date.now() - ultimoCambio < 8000
    let cambios: string[] = []
    await update($, datos, d => {
      cambios = cambiosDeCupo(d.tarjetas, j.tarjetas)
      const ef = j.ef ?? d.ef
      return reciente ? { ...j, ef, activo: d.activo, modo: d.modo, calidad: d.calidad, manual: d.manual, eventos: d.eventos } : { ...j, ef, eventos: d.eventos }
    })
    await update($, actualizado, () => new Date().toLocaleTimeString('es-AR'))
    const f = ahoraIso()
    await update($, latido, l => ({ ...l, cupos: Date.now(), leyendo: false, err: '', movs: [...l.movs, ...cambios.map(t => ({ f, t }))].slice(-6) }))
  } catch (err) {
    await update($, actualizado, () => 'error: ' + String(err).slice(0, 80))
    await update($, latido, l => ({ ...l, leyendo: false, err: String(err).slice(0, 80) }))
  }
}

// Inicio de esta sesion (hora local ISO): lo delegado desde aca se muestra aparte del total historico.
const inicioSesion = new Date(Date.now() - new Date().getTimezoneOffset() * 60000).toISOString().slice(0, 19)

// primera=true: ademas trae la ultima lectura de cupos guardada para pintar el panel al instante (la lectura en vivo tarda).
async function rapido($: any, primera = false) {
  if (leyendoRapido) return
  leyendoRapido = true
  try { await rapidoUna($, primera) } finally { leyendoRapido = false }
}
async function rapidoUna($: any, primera = false) {
  try {
    const r = await $.process.run([...PS, script($, 'rapido.ps1'), '-Desde', inicioSesion, ...(primera ? ['-ConCache'] : [])], { timeoutMs: 15000 })
    const j = JSON.parse(String(r.stdout || '').replace(/^﻿/, '').trim()) as Datos & { cache_seg?: number }
    const reciente = guardando > 0 || Date.now() - ultimoCambio < 8000
    if (primera && j.tarjetas?.length) {
      await update($, datos, d => (d.tarjetas.length ? d : { ...d, tarjetas: j.tarjetas, horas: j.horas, pesada: j.pesada }))
      const edad = (j.cache_seg ?? 0) * 1000
      await update($, latido, l => (l.cupos ? l : { ...l, cupos: Date.now() - edad }))
    }
    await update($, latido, l => ({ ...l, rap: Date.now() }))
    await update($, datos, d => (reciente
      ? { ...d, eventos: j.eventos, deleg_total: j.deleg_total, deleg_n: j.deleg_n, claude_costo: j.claude_costo, ses_deleg: j.ses_deleg, ses_n: j.ses_n, ses_costo: j.ses_costo, glob: j.glob, presup: j.presup, motores: j.motores, dias: j.dias }
      : { ...d, eventos: j.eventos, deleg_total: j.deleg_total, deleg_n: j.deleg_n, claude_costo: j.claude_costo, ses_deleg: j.ses_deleg, ses_n: j.ses_n, ses_costo: j.ses_costo, glob: j.glob, presup: j.presup, motores: j.motores, dias: j.dias, activo: j.activo, modo: j.modo, calidad: j.calidad, manual: j.manual }))
  } catch { /* se reintenta en el proximo ciclo */ }
}

async function cambiar($: any, patch: (d: Datos) => Datos, args: string[]) {
  ultimoCambio = Date.now()
  guardando++
  await update($, datos, patch)
  try {
    await $.process.run([...PS, script($, 'config.ps1'), ...args], { timeoutMs: 20000 })
  } catch (err) {
    await update($, actualizado, () => 'error: ' + String(err).slice(0, 80))
  }
  guardando--
  ultimoCambio = Date.now()
}

let turno: { texto: string; t: number; hecho: boolean } | null = null

// Si el pedido anterior no pasó por delegar.ps1 ni decidir.ps1, anota que lo resolvió Claude y por qué (motivo estimado).
function cerrarTurno($: any, esperaMs: number) {
  if (!turno || turno.hecho || Date.now() - turno.t < esperaMs) return
  const t = turno
  turno.hecho = true
  const txt = t.texto.trim()
  const grande = txt.length > 400 || /\b(program|código|codigo|script|app|aplicaci|revis|analiz|resum|traduc|redact|escrib|document|archivo|carpeta)/i.test(txt)
  const motivo = grande
    ? 'lo resolvió Claude sin delegar (estimado: necesita el contexto de la charla o el equipo del usuario)'
    : 'pregunta o charla corta: delegarla cuesta más que contestarla'
  void $.process.run([...PS, script($, 'decidir.ps1'), '-Motivo', motivo, '-Tarea', grande ? 'texto' : 'trivial'], { timeoutMs: 8000 }).catch(() => {})
}

// ---------- Intensidad de delegación (Automático por defecto | Bajo | Medio | Alto), global y por chat; la escribe intensidad.ps1 y la lee el router.
type Intens = { g: string; v: string; origen: string; chatId: string; msg: string; t: number }
const intensA = atom({ plugin: 'multi-ia-orquestador', key: 'intensidad' } as const,
  { g: 'automatico', v: 'automatico', origen: 'global', chatId: '', msg: '', t: 0 } as Intens, { shape: 'intensidad-1' })
let leyendoIntens = false
async function cargarIntens($: any, chatId: string) {
  if (leyendoIntens) return
  leyendoIntens = true
  try {
    const r = await $.process.run([...PS, script($, 'intensidad.ps1'), '-Ver', '-Json', ...(chatId ? ['-Chat', chatId] : [])], { timeoutMs: 15000 })
    const j = JSON.parse(ultimaLinea(r.stdout) || '{}')
    if (j.valor) await update($, intensA, x => ({ ...x, g: j.global || x.g, v: j.valor, origen: j.origen || 'global', chatId, t: Date.now() }))
  } catch { /* se reintenta al reabrir Sistema */ }
  leyendoIntens = false
}
async function cambiarIntens($: any, valor: string | null, ambito: 'global' | 'chat', chatId: string) {
  const args = valor === null ? ['-Quitar', '-Chat', chatId] : ['-Valor', valor, ...(ambito === 'global' ? ['-Global'] : ['-Chat', chatId])]
  await update($, intensA, x => ({ ...x, msg: 'Guardando…' }))
  try {
    const r = await $.process.run([...PS, script($, 'intensidad.ps1'), ...args, '-Json'], { timeoutMs: 20000 })
    const j = JSON.parse(ultimaLinea(r.stdout) || '{}')
    await update($, intensA, x => ({ ...x, msg: j.mensaje || 'Guardado' }))
  } catch (err) {
    await update($, intensA, x => ({ ...x, msg: 'No se pudo guardar: ' + String(err).slice(0, 80) }))
  }
  await cargarIntens($, chatId)
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'panel-ia',
      description: 'Abrir el panel de consumo Multi-IA',
    })
    await $.command.register({
      name: 'multi-ia',
      description: 'Encender o apagar Multi-IA: /multi-ia on | off',
    })
    void $.ui.open({ id: PANE, title: 'Multi-IA · consumo' })
    void rapido($, true)
    void refrescar($)
    if (!temporizadores) {   // un solo juego de temporizadores aunque session.start se dispare de nuevo (reanudar/limpiar)
      temporizadores = true
      $.clock.every(60000, () => {
        void refrescar($)
      })
      $.clock.every(4000, () => {
        void rapido($)
        cerrarTurno($, 25000)
      })
    }
    return next(e)
  })

  // Regla de oro dentro del prompt del sistema: no depende de que Claude cargue la skill.
  on('prompt.compose', async ($, e, next) => {
    const r = await next(e)
    const d0 = await read($, datos)
    if (d0 && d0.activo === false) return r   // Multi-IA apagado: no se inyecta la regla de delegar
    const p = presionClaude(d0)
    const fuerte = p >= PRESION
      ? ` MODO AHORRO FUERTE: el cupo de Claude está al ${p}%. Delegá TODO lo que no dependa de la charla, incluso tareas medianas (con -Forzar si la guardia las frena), con -Calidad economica salvo que sea crítico; hacé vos solo lo mínimo e indispensable, con respuestas cortas, y avisale al usuario en una línea que estás en ahorro fuerte.`
      : ''
    return {
      sections: [
        ...r.sections,
        {
          id: 'multi-ia-orquestador:regla',
          scope: 'session' as const,
          text: fuerte + ' Multi-IA (ahorro de tokens de Claude): ante cada pedido real decidí vos si delegás. Trabajo grande, con archivos o con partes independientes (programar, revisar código, textos largos, resumir/analizar documentos) → delegalo con `scripts/delegar.ps1` del plugin multi-ia-orquestador (Codex para código, Antigravity/Gemini para texto y análisis) y decile al usuario en una línea qué motor y por qué. Lo chico o que depende de la charla lo hacés vos. La consola del panel anota sola cada decisión; si querés dar un motivo más preciso al no delegar, corré `scripts/decidir.ps1 -Motivo "..."`.',
        },
      ],
    }
  })

  // Cada pedido del usuario queda anotado en la consola: si nadie delegó ni explicó, se anota "lo resolvió Claude" con el motivo estimado.
  on('prompt.submit', ($, e, next) => {
    if (!e.command && !e.isMeta && String(e.text || '').trim()) {
      cerrarTurno($, 0)
      turno = { texto: String(e.text), t: Date.now(), hecho: false }
    }
    return next(e)
  })

  // Guardia previa: una delegacion chica (pedido corto, sin archivos ni carpeta) cuesta mas de lo que ahorra.
  // Se frena ANTES de gastar; para delegar igual se agrega -Forzar.
  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const c = String(e.command || '')
    if (turno && /(delegar|decidir)\.ps1/i.test(c)) turno.hecho = true
    const d1 = await read($, datos)
    if (d1 && d1.activo === false) return next(e)   // apagado: la guardia no interviene
    const apretado = presionClaude(d1) >= PRESION // con el cupo de Claude al limite, delegar siempre conviene
    const soloLee = /^\s*(sed|cat|head|tail|grep|rg|less|more|type|wc|ls|awk|Get-Content|Select-String)\b/i.test(c)   // leer el script no es delegar
    const chica = !apretado && !soloLee && /delegar\.ps1/i.test(c) && c.length < 450 && !/-(Archivo|Carpeta|Critico|Cruzar|Dificil|Forzar)\b/i.test(c)
    if (chica) void $.process.run([...PS, script($, 'decidir.ps1'), '-Motivo', 'delegación chica: cuesta más delegarla que hacerla'], { timeoutMs: 8000 }).catch(() => {})
    return chica
      ? { deny: 'Multi-IA: esta delegación es chica; delegarla cuesta más cupo (cada llamada gasta tokens fijos de arranque y vos releés la respuesta). Resolvela directo. Si de verdad conviene delegar, repetí el comando con -Forzar.' }
      : next(e)
  })

  on('command.run', { command: 'multi-ia' }, async ($, e) => {
    const a = String(e.args || '').trim().toLowerCase()
    const apagar = /^(off|apagar|apagado|no)$/.test(a)
    const encender = /^(on|encender|encendido|si|sí)$/.test(a)
    if (apagar || encender) {
      await cambiar($, dd => ({ ...dd, activo: encender }), [encender ? '-Encender' : '-Apagar'])
      return { text: encender ? 'Multi-IA ENCENDIDO: Claude vuelve a delegar a Codex y Antigravity.' : 'Multi-IA APAGADO: Claude trabaja solo y no delega. Para volver: /multi-ia on' }
    }
    await $.ui.open({ id: PANE, title: 'Multi-IA · consumo' })
    return { text: 'Uso: /multi-ia on | /multi-ia off. Panel abierto (ahí también está el botón de encendido).' }
  })

  on('command.run', { command: 'panel-ia' }, async $ => {
    await $.ui.open({ id: PANE, title: 'Multi-IA · consumo' })
    return { text: 'Panel Multi-IA abierto (el panel se refresca cada 4 s y los cupos cada 60 s; arriba ves si está en vivo).' }
  })

  for (const ID of [PANE, PANE_CC]) on('ui.render', { component: 'Pane', requestId: ID }, async ($, e) => {
    const { Box, Text, Button, Svg, Input } = $.ui.resolve(e)
    const centro = ID === PANE_CC
    const anchoU = centro ? T.utilExp : T.util
    const vista = await read($, vistaA)
    const d = await read($, datos)
    const hora = await read($, actualizado)
    const desplegado = await read($, abierto)
    const ctrlOn = await read($, ctrlAbierto)
    const filtro = await read($, filtroCons)
    const rei = await read($, reinicio)
    const lat = await read($, latido)
    const ch = await read($, chatsA)
    const itn = await read($, intensA)
    const encendido = d.activo !== false
    const manual = d.modo === 'manual'
    const eventos = d.eventos ?? []
    // Ejecuciones activas = 'inicio' sin su 'fin'/'error' (se unen por ID de ejecución). Sin ID (eventos viejos) solo cuenta el último.
    // Un inicio de hace más de 30 min se considera colgado y no se muestra como activo.
    const msEv = (f: string) => new Date(f).getTime()
    const cerrados = new Set(eventos.filter(v => (v.t === 'fin' || v.t === 'error') && v.i).map(v => v.i as string))
    const activos = eventos.filter((v, n) => v.t === 'inicio' && Date.now() - msEv(v.f) < 30 * 60000 && (v.i ? !cerrados.has(v.i) : n === eventos.length - 1))
    const trabajando = activos.length > 0
    // Estado REAL del reactor: solo los que hay señal verificable (no se inventan Analizando / Seleccionando).

    // ---------- indicador de actualización: "en vivo" si el panel late (cada 4 s), con la edad de los cupos
    const ahora = Date.now()
    const edadRap = lat.rap ? Math.round((ahora - lat.rap) / 1000) : -1
    const edadCupos = lat.cupos ? Math.max(0, Math.round((ahora - lat.cupos) / 1000)) : -1
    const hace = (s: number) => (s < 60 ? s + ' s' : Math.floor(s / 60) + ' min')
    const enVivo = edadRap >= 0 && edadRap <= 15
    const cuposViejos = edadCupos < 0 || edadCupos > 150
    const estado = lat.err ? { c: T.errorSuave, t: '● error al leer cupos · reintenta solo' }
      : !enVivo ? { c: T.ambar, t: edadRap < 0 ? '● enlace del panel: conectando…' : '● sin señal hace ' + hace(edadRap) }
      : lat.leyendo ? { c: T.info, t: '● actualizando cupos…' }
      : { c: cuposViejos ? T.ambar : T.okSuave, t: '● en vivo' }
    // Reactor: sin señal = el panel dejó de latir hace más de 60 s (había latido antes).
    const reactor = estadoReactor(eventos, ahora, encendido, edadRap > 60, !!turno && !turno.hecho && ahora - turno.t < 20000)

    // ---------- piezas chicas
    // Tiempo que falta para que se renueve la ventana (calculado de la hora de reinicio real; sin hora no se inventa).
    const faltaPara = (iso?: string) => {
      if (!iso) return ''
      const ms = new Date(iso).getTime() - ahora
      if (isNaN(ms)) return ''
      if (ms <= 0) return 'renovando…'
      const min = Math.round(ms / 60000)
      if (min < 60) return 'faltan ' + min + ' min'
      if (min < 2880) return 'faltan ' + Math.floor(min / 60) + ' h ' + (min % 60) + ' min'
      return 'faltan ' + Math.floor(min / 1440) + ' d ' + Math.floor((min % 1440) / 60) + ' h'
    }
    // Una ventana (sesión 5 h o semanal): % usado, % disponible, barra propia, renovación, tiempo restante y de dónde sale el dato.
    // Si la ventana no se puede leer se dice "No disponible" (nunca un número inventado).
    const fila = (w: Ventana | undefined, v: string = w ? w.v : '5 h') => {
      const sesion = v === '5 h'
      const rotulo = sesion ? '⏱ SESIÓN 5 H' : '▦ SEMANAL 7 DÍAS'
      const colorR = sesion ? T.info : T.violeta
      if (!w) {
        return (
          <Box key={v} flexDirection="column">
            <Text size="caption" bold color={colorR}>{rotulo}</Text>
            <Text size="caption" dimColor>No disponible — esta IA no informa esa ventana</Text>
          </Box>
        )
      }
      const [lleno, vacio] = trazo(w.usado)
      const libre = Math.max(0, 100 - w.usado)
      const reno = [cuando(w.reinicia), faltaPara(w.reinicia)].filter(Boolean).join(' · ')
      return (
        <Box key={v} flexDirection="column">
          <Box flexDirection="row" justifyContent="space-between" alignItems="center">
            <Text size="caption" bold color={colorR}>{rotulo}</Text>
            <Box flexDirection="row" gap="xs" alignItems="center">
              <Text bold size="heading" color={colorUso(w.usado)}>{w.usado + '% usado'}</Text>
              <Text size="caption" color={T.okSuave}>{libre + '% libre'}</Text>
            </Box>
          </Box>
          {Svg
            ? <Svg source={svgBarraCupo(anchoU, w.usado, colorUso(w.usado))} alt={rotulo + ': ' + w.usado + '% usado, ' + libre + '% libre'} width={anchoU} height={10} />
            : <Text color={colorUso(w.usado)}>{'━'.repeat(lleno)}<Text color={BORDE}>{'━'.repeat(vacio)}</Text></Text>}
          <Text size="caption" dimColor>{(reno || 'sin hora de renovación informada') + (w.origen ? ' · ' + w.origen : '')}</Text>
        </Box>
      )
    }
    const ventana = (t: Tarjeta, v: string) => t.ventanas.find(w => w.v === v)
    const peor = (t: Tarjeta) => t.ventanas.reduce((m, w) => Math.max(m, w.usado), 0)

    // ---------- contadores (mosaico 2x2)
    const horas = d.horas ?? []
    const sumC = horas.reduce((a, x) => a + x.c, 0)
    const sumD = horas.reduce((a, x) => a + x.d, 0)
    const deleg = d.deleg_total ?? 0
    const costo = d.claude_costo ?? 0
    const neto = Math.max(0, deleg - costo)

    // Medida útil única: compacto T.util, Centro de control T.utilExp. isInteractive solo en el gráfico con tooltips.
    const svg = (source: string, alt: string, ancho: number, alto: number, interactivo = false) => (Svg
      ? <Svg source={source} alt={alt} width={ancho} height={alto} isInteractive={interactivo} />
      : <Text size="caption" dimColor>{alt}</Text>)
    // ahorro = lo que hicieron otras IA menos lo que le costó a Claude coordinarlo (estimado, nunca negativo)
    const netoSes = Math.max(0, (d.ses_deleg ?? 0) - (d.ses_costo ?? 0))
    const ahorroW = (anchoU: number) => (
      <Box flexDirection="column" gap="xs" width="100%">
        {svg(svgTitulo(anchoU, '✦', 'Ahorro estimado', T.ahorro, 'delegado − coordinación'), 'Ahorro estimado', anchoU, 38)}
      <Box flexDirection="row" justifyContent="space-between" gap="xs" width="100%">
        <Box flexDirection="column" paddingX="sm" borderStyle="round" borderColor={T.ahorro} backgroundColor={PANEL} width="49%">
          <Text bold color={T.ahorro}>{'✦ ≈ ' + fmt(netoSes) + ' tokens'}</Text>
          <Text size="caption" dimColor>{'ahorrados en esta sesión · ' + (d.ses_n ?? 0) + (d.ses_n === 1 ? ' delegación' : ' delegaciones')}</Text>
        </Box>
        <Box flexDirection="column" paddingX="sm" borderStyle="round" borderColor={T.ahorro} backgroundColor={PANEL} width="49%">
          <Text bold color={T.ahorro}>{'✦ ≈ ' + fmt(neto) + ' tokens'}</Text>
          <Text size="caption" dimColor>{'ahorrados en total · ' + (d.deleg_n ?? 0) + ' delegaciones'}</Text>
        </Box>
      </Box>
      </Box>
    )
    const ahorro = ahorroW(anchoU)
    const g = d.glob
    const consumoGlobal = g && (
      <Box flexDirection="column" gap="xs" width="100%">
        {svg(svgTitulo(anchoU, 'Σ', 'Consumo global', T.violeta, g.ses + ' sesiones'), 'Consumo global de ' + g.ses + ' sesiones', anchoU, 38)}
        {svg(svgBarrasH(anchoU, [
          { l: 'Codex', txt: fmt(g.codex) + ' tok', p: g.tin + g.tout > 0 ? (100 * g.codex) / (g.tin + g.tout) : 0, c: colorIa('Codex') },
          { l: 'Antigravity', txt: fmt(g.agy) + ' tok', p: g.tin + g.tout > 0 ? (100 * g.agy) / (g.tin + g.tout) : 0, c: colorIa('Antigravity') },
          { l: 'Hoy / 7 días / 30 días', txt: fmt(g.hoy) + ' · ' + fmt(g.semana) + ' · ' + fmt(g.mes), p: g.mes > 0 ? (100 * g.hoy) / g.mes : 0, c: T.cian },
        ]), 'Consumo delegado: Codex ' + fmt(g.codex) + ', Antigravity ' + fmt(g.agy) + '; hoy ' + fmt(g.hoy) + ', 7 días ' + fmt(g.semana) + ', 30 días ' + fmt(g.mes), anchoU, 3 * 42 + 10)}
      <Box flexDirection="column" paddingX="sm" borderStyle="round" borderColor={T.violeta} backgroundColor={PANEL}>
        <Text size="caption" color={g.errores ? T.errorSuave : undefined} dimColor={!g.errores}>{'entrada ' + fmt(g.tin) + ' · salida ' + fmt(g.tout) + ' · errores ' + g.errores}</Text>
        {d.presup && (
          <Text size="caption" bold color={d.presup.tope > 0 && (100 * d.presup.hoy) / d.presup.tope >= d.presup.aviso ? T.errorSuave : T.tenue}>
            {(d.presup.tope > 0 ? 'Presupuesto de hoy: ' + fmt(d.presup.hoy) + ' de ' + fmt(d.presup.tope) + ' (' + Math.round((100 * d.presup.hoy) / d.presup.tope) + '%)' : 'Sin tope diario') + ' · ' + d.presup.cache + ' respuestas en caché' + (d.presup.arena ? ' · Arena: ' + d.presup.arena : '')}
          </Text>
        )}
        <Text size="caption" dimColor>{'Tokens informados por cada CLI' + (g.sin_dato ? ' (' + g.sin_dato + ' llamadas sin dato de tokens)' : '') + '. «Costó coordinar a Claude» es estimación local.'}</Text>
      </Box>
      </Box>
    )
    const ef = d.ef
    const efW = (anchoU: number, cols: number) => ef && (
      <Box flexDirection="column" gap="xs" width="100%">
      {svg(svgTitulo(anchoU, '◎', 'Eficiencia', T.cian, 'últimos ' + ef.dias + ' días'), 'Eficiencia, últimos ' + ef.dias + ' días', anchoU, 38)}
      <Box flexDirection="column" gap="xs" paddingX="sm" borderStyle="round" borderColor={T.cian} backgroundColor={PANEL}>
        {svg(svgKpis(anchoU, cols, [
          { v: String(ef.exitosas), r: 'exitosas', c: T.okSuave },
          { v: String(ef.oportunidades_perdidas), r: 'oportunidades perdidas', c: T.ambar },
          { v: String(ef.fallidas), r: 'fallidas', c: T.errorSuave },
          { v: ef.tasa_delegacion_util === null ? '—' : ef.tasa_delegacion_util + '%', r: 'tasa de delegación útil', c: T.cian },
        ]), 'Eficiencia: ' + ef.exitosas + ' exitosas, ' + ef.oportunidades_perdidas + ' oportunidades perdidas, ' + ef.fallidas + ' fallidas, tasa de delegación útil ' + (ef.tasa_delegacion_util === null ? 'sin datos' : ef.tasa_delegacion_util + '%'), anchoU - 24, centro ? 64 : 138)}
        <Text size="caption" dimColor>{ef.directas_justificadas + ' respuestas directas justificadas · ' + ef.fallas_recuperadas + ' fallas recuperadas por cambio de motor · ' + ef.exitosas_con_tokens + ' de ' + ef.elegibles + ' tareas evaluadas'}</Text>
        <Text size="caption" color={T.ahorro}>{'Ahorro neto ≈ ' + fmt(Math.max(0, ef.ahorro_neto_estimado)) + ' tokens (estimado) · delegados ' + fmt(ef.tokens_delegados)}</Text>
        {(ef.recomendaciones ?? []).map((r, n) => <Text key={'rc-' + n} size="caption" dimColor>{'• ' + r}</Text>)}
        <Text size="caption" dimColor>{ef.metodologia}</Text>
      </Box>
      </Box>
    )
    const eficiencia = efW(anchoU, centro ? 4 : 2)

    // ---------- tarjetas por IA (Antigravity agrupado en una sola, desplegable)
    const claudeCodex = (d.tarjetas || []).filter(t => t.nombre.startsWith('Claude') || t.nombre.startsWith('Codex'))
    const agy = (d.tarjetas || []).filter(t => !t.nombre.startsWith('Claude') && !t.nombre.startsWith('Codex'))

    const tarjeta = (t: Tarjeta, glifo: string) => (
      <Box key={t.nombre} flexDirection="column" paddingX="sm" borderStyle="round" borderColor={colorIa(t.nombre)} backgroundColor={tinte(t.nombre)}>
        <Box flexDirection="row" justifyContent="space-between" alignItems="center">
          <Text bold color={colorIa(t.nombre)}>{glifo + ' ' + t.nombre}</Text>
          <Box flexDirection="row" gap="xs" alignItems="center">
            {lat.err && <Text size="caption" bold color={T.ambar}>{'⚠ sin sincronizar'}</Text>}
            <Text size="caption" bold color={colorUso(peor(t))}>{'peor ' + peor(t) + '%'}</Text>
          </Box>
        </Box>
        {fila(ventana(t, '5 h'), '5 h')}
        {fila(ventana(t, 'Semanal'), 'Semanal')}
        <Text size="caption" dimColor>{'Última lectura exitosa: ' + (edadCupos < 0 ? 'todavía no' : 'hace ' + hace(edadCupos)) + (cuposViejos && edadCupos >= 0 ? ' (datos viejos)' : '')}</Text>
      </Box>
    )

    const grupoAgy = agy.length > 0 && (() => {
      // Cerrado: una linea por modelo con sus % (asi se ve el modelo que se esta usando, no solo el peor);
      // abierto: cada modelo con sus barras.
      const p = Math.max(0, ...agy.map(peor))
      const pct = (t: Tarjeta, v: string) => t.ventanas.find(w => w.v === v)?.usado
      // Modelos con la MISMA cuota (mismos % en 5 h y Semanal, como informa agy para un grupo) se muestran en una sola linea con sus nombres.
      const gruposCuota: { t: Tarjeta; nombres: string[] }[] = []
      for (const t of agy) {
        const corto = (t.nombre || '').replace(/^Antigravity[\s·]*/, '').trim() || 'Antigravity'
        const g = gruposCuota.find(x => pct(x.t, '5 h') === pct(t, '5 h') && pct(x.t, 'Semanal') === pct(t, 'Semanal'))
        if (g) g.nombres.push(corto); else gruposCuota.push({ t, nombres: [corto] })
      }
      return (
        <Box flexDirection="column" paddingX="sm" borderStyle="round" borderColor={T.violeta} backgroundColor={T.sVidrio}>
          <Box flexDirection="row" justifyContent="space-between" alignItems="center">
            <Text bold color={T.violeta}>{'✦ Antigravity · ' + agy.length + ' modelos'}</Text>
            <Text size="caption" bold color={colorUso(p)}>{p + '% usado'}</Text>
          </Box>
          {!desplegado && gruposCuota.map(g => g.t).map((t, gi) => (
            <Box key={t.nombre} flexDirection="column">
              <Text size="caption" bold color={T.violeta}>{'● ' + gruposCuota[gi].nombres.join(' · ')}</Text>
              <Box flexDirection="row" justifyContent="space-between">
                <Text size="caption"><Text size="caption" bold color={T.info}>{'⏱ Sesión 5 h  '}</Text><Text size="caption" bold color={colorUso(pct(t, '5 h') ?? 0)}>{pct(t, '5 h') === undefined ? 'No disponible' : pct(t, '5 h') + '%'}</Text></Text>
                <Text size="caption"><Text size="caption" bold color={T.violeta}>{'▦ Semanal 7 d  '}</Text><Text size="caption" bold color={colorUso(pct(t, 'Semanal') ?? 0)}>{pct(t, 'Semanal') === undefined ? 'No disponible' : pct(t, 'Semanal') + '%'}</Text></Text>
              </Box>
            </Box>
          ))}
          {desplegado && agy.map(t => (
            <Box key={t.nombre} flexDirection="column" gap="xs" padding="xs" borderStyle="round" borderColor={BORDE} backgroundColor={FONDO}>
              <Text size="caption" bold color={T.violeta}>{'● ' + t.nombre}</Text>
              {fila(ventana(t, '5 h'), '5 h')}
              {fila(ventana(t, 'Semanal'), 'Semanal')}
            </Box>
          ))}
          <Text size="caption" dimColor>Cuota agrupada tal como la informa agy: los modelos de un mismo grupo la comparten (no se suman).</Text>
          <Box flexDirection="row" justifyContent="center">
            <Button variant="secondary" onPress={() => void update($, abierto, v => !v)}>
              {desplegado ? '▴ Ocultar barras' : '▾ Ver barras de cada modelo'}
            </Button>
          </Box>
        </Box>
      )
    })()

    // ---------- consola estilo log
    const icono = (t: string) => (t === 'inicio' ? '▶' : t === 'fin' ? '✔' : t === 'error' ? '✖' : '◌')
    // frase clara de cada evento: a quién, qué pasó
    // categorías: directo / delegación / prueba (origen no real) / reintento recuperado / reinicio / error / fin; tipo desconocido muestra su nombre
    const prueba = (v: Evento) => (v.o && v.o !== 'real' ? '[PRUEBA ' + v.o + '] ' : '')
    const frase = (v: Evento) => prueba(v) + (v.t === 'sin-delegar'
      ? (v.d === 'claude' ? 'Claude lo resolvió solo (no delegó)' : v.d === 'pendiente' ? 'Quedó pendiente: nadie pudo tomarlo' : 'No se delegó')
      : v.t === 'reinicio' ? 'Reinicio del panel o de Claude'
      : v.t === 'inicio' || v.t === 'fin' || v.t === 'error'
        ? nombreIa(v.d) + ' ' + (v.t === 'inicio' ? 'está trabajando (delegado)' : v.t === 'fin' ? (/-r$/.test(v.i || '') ? 'terminó (recuperado tras una falla)' : 'terminó') : 'tuvo un problema')
        : 'Evento: ' + v.t)
    const colorEv = (t: string) => (t === 'inicio' ? T.ambar : t === 'fin' ? T.okSuave : t === 'error' ? T.errorSuave : T.tenue)
    const nombreIa = (x: string) => (x === 'codex' ? 'Codex' : x === 'agy' ? 'Antigravity' : 'Claude')
    const tarea = (k: string) => (({ codigo: 'código', revision: 'revisión', texto: 'texto', trivial: 'tarea simple', razonar: 'razonamiento', opinion: 'segunda opinión', contenido: 'contenido', imagen: 'imagen o video' } as Record<string, string>)[k] ?? k)
    // hora de hoy como HH:MM; de otro día, DD/MM HH:MM (24 h para todo)
    const horaEv = (f: string) => {
      const s = f || ''
      return s.slice(0, 10) === ahoraIso().slice(0, 10) ? s.slice(11, 16) : s.slice(8, 10) + '/' + s.slice(5, 7) + ' ' + s.slice(11, 16)
    }
    // una sola línea de tiempo: eventos y cambios de cupo juntos, lo más nuevo ARRIBA
    const linea = [
      ...eventos.map(v => ({ f: v.f || '', ev: v as Evento | null, mov: '' })),
      ...(lat.movs ?? []).map(m => ({ f: m.f || '', ev: null as Evento | null, mov: m.t })),
    ].filter(x => !x.ev || !['seleccionado', 'confirmado', 'recibido'].includes(x.ev.t)).filter(x => filtro === 'todo' || (x.ev && (filtro === 'errores' ? x.ev.t === 'error' : x.ev.d === filtro))).filter(x => !vista.q || (x.ev ? nombreIa(x.ev.d) + ' ' + x.ev.t + ' ' + (x.ev.k || '') + ' ' + (x.ev.m || '') + ' ' + (x.ev.x || '') : x.mov).toLowerCase().includes(vista.q.toLowerCase())).sort((a, b) => (a.f < b.f ? 1 : a.f > b.f ? -1 : 0)).slice(0, centro ? 45 : 7)
    const consola = (
      <Box flexDirection="column" paddingX="sm" borderStyle="round" borderColor={trabajando ? T.ambar : BORDE} backgroundColor={T.sHondo}>
        <Box flexDirection="row" justifyContent="space-between" alignItems="center">
          <Text bold color={trabajando ? T.ambar : undefined}>{(trabajando ? '⚡ Trabajando ahora' : '☰ Actividad reciente')}</Text>
          <Text size="caption" dimColor>{eventos.length + ' registros'}</Text>
        </Box>
        <Box flexDirection="row" gap="xs" flexWrap="wrap">
          {([['todo', 'Todo'], ['errores', 'Errores'], ['codex', 'Codex'], ['agy', 'Antigravity']] as [string, string][]).map(([v, e]) => (
            <Button key={'f-' + v} variant={filtro === v ? 'primary' : 'secondary'} onPress={() => void update($, filtroCons, () => v)}>{(filtro === v ? '● ' : '') + e}</Button>
          ))}
        </Box>
        <Text size="caption" color={estado.c}>{'◉ Vigilando · último chequeo de cupos ' + (edadCupos < 0 ? 'pendiente' : 'hace ' + hace(edadCupos))}</Text>
        {(d.motores ?? []).length > 0 && (
          <Text size="caption" dimColor>
            {'Motores: ' + (d.motores ?? []).map(m => m.nombre + (m.disponible ? '' : ' (no disponible)') + ' · ' + (m.modelo_verificado ? m.modelo_verificado : 'Modelo no verificable')).join('  |  ')}
          </Text>
        )}
        {activos.map(v => {
          // Estado REAL de la ejecución = el último evento con su ID: solicitud enviada → confirmado (señal de la CLI) → respuesta recibida.
          const suyos = eventos.filter(e => e.i && e.i === v.i)
          const st = suyos.some(e => e.t === 'recibido') ? 'respuesta recibida' : suyos.some(e => e.t === 'confirmado') ? 'confirmado por la CLI (' + (suyos.find(e => e.t === 'confirmado')?.c ?? '') + ')' : 'solicitud enviada, esperando a la CLI'
          return (
            <Text key={'a-' + (v.i || v.f)} size="caption" bold color={T.ambar}>
              {'⚡ ' + (v.i ? v.i + ' · ' : '') + nombreIa(v.d) + ' · ' + (v.x ? 'pedido: ' + v.x + ' (modelo no verificable)' : 'modelo no verificable') + (v.k ? ' · ' + tarea(v.k) : '') + ' · ' + st + ' · hace ' + hace(Math.max(0, Math.round((Date.now() - msEv(v.f)) / 1000)))}
            </Text>
          )
        })}
        {linea.length === 0 && <Text size="caption" dimColor>Sin actividad todavía: acá ves a quién delega Claude y por qué, o por qué decide hacerlo solo. Los cambios de cupo también aparecen acá.</Text>}
        {linea.map((x, i) => {
          const v = x.ev
          if (!v) return <Text key={String(i)} size="caption" color={T.info}>{horaEv(x.f) + '  ⇅ ' + x.mov}</Text>
          return (
            <Box key={String(i)} flexDirection="column">
              <Text size="caption" color={colorEv(v.t)}>
                {horaEv(v.f) + '  ' + icono(v.t) + ' ' + frase(v) + (v.k ? ' · ' + tarea(v.k) : '')}
              </Text>
              {(v.x || v.tok > 0 || v.s > 0) && <Text size="caption" dimColor>{'     ' + [v.x, v.tok ? fmt(v.tok) + ' tokens' : '', v.s ? v.s + ' s' : ''].filter(Boolean).join(' · ')}</Text>}
              {v.m && v.t !== 'fin' && <Text size="caption" dimColor>{(v.t === 'sin-delegar' ? '     Por qué no: ' : '     Por qué: ') + v.m}</Text>}
            </Box>
          )
        })}
      </Box>
    )

    // ---------- controles: cada fila es un "segmentado" (bandeja oscura); la opcion activa va en primary y con punto
    const opciones = (titulo: string, items: [string, string][], actual: string | undefined, args: (v: string) => string[], patch: (d: Datos, v: string) => Datos) => (
      <Box flexDirection="column" gap="xs">
        <Text size="caption" bold color={T.tenue}>{titulo}</Text>
        <Box flexDirection="row" gap="xs" flexWrap="wrap" padding="xs" borderStyle="round" borderColor={BORDE} backgroundColor={FONDO}>
          {items.map(([v, etiqueta]) => (
            <Button key={v} variant={actual === v ? 'primary' : 'secondary'} onPress={() => void cambiar($, dd => patch(dd, v), args(v))}>
              {(actual === v ? '● ' : '') + etiqueta}
            </Button>
          ))}
        </Box>
      </Box>
    )
    const man = (dd: Datos) => dd.manual ?? { codex: { modelo: '', esfuerzo: 'medium' }, agy: { modelo: '' } }

    const chatIdAct = ch.j?.chat_actual || ''
    const INT_OPC: [string, string][] = [['automatico', 'Automático'], ['alto', 'Máximo'], ['medio', 'Medio'], ['bajo', 'Mínimo']]   // 2.3.0: etiquetas Pixel Pro; el valor que llega al router (intensidad.ps1 / elegir.ps1) no cambia
    const INT_DESC: Record<string, string> = { automatico: 'El router decide según la tarea (recomendado)', bajo: 'Delega solo lo claramente grande', medio: 'Delega lo mediano y grande', alto: 'Delega casi todo lo que pueda' }
    // Botón envuelto en vidrio: borde y fondo del acento cuando está activo (los Button nativos solo admiten primary/secondary).
    const vidrioBtn = (activo: boolean, color: string, hijo: any, k: string) => (
      <Box key={k} borderStyle="round" borderColor={activo ? color : BORDE} backgroundColor={activo ? T.sActivo : PANEL}>{hijo}</Box>
    )
    const intensidadUI = (
      <Box flexDirection="column" gap="xs" paddingX="sm" paddingY="xs" borderStyle="round" borderColor={T.magenta} backgroundColor={T.vidrio}>
        <Text bold color={T.magenta}>◎ Intensidad de delegación</Text>
        <Text size="caption" dimColor>{'Global: ' + (INT_OPC.find(o => o[0] === itn.g)?.[1] || itn.g) + ' · este chat: ' + (INT_OPC.find(o => o[0] === itn.v)?.[1] || itn.v) + (itn.origen === 'chat' ? ' (propia)' : ' (hereda la global)')}</Text>
        <Text size="caption" dimColor>Global (chats sin preferencia propia)</Text>
        <Box flexDirection="row" gap="xs" flexWrap="wrap">
          {INT_OPC.map(([v, n]) => vidrioBtn(itn.g === v, T.magenta, <Button key={'ig-b-' + v} variant={itn.g === v ? 'primary' : 'secondary'} onPress={() => void cambiarIntens($, v, 'global', chatIdAct)}>{n}</Button>, 'ig-' + v))}
        </Box>
        <Text size="caption" dimColor>{chatIdAct ? 'Solo este chat (' + chatIdAct.slice(0, 8) + ')' : 'Este chat: se detecta al abrir la sección Chats'}</Text>
        {chatIdAct !== '' && (
          <Box flexDirection="row" gap="xs" flexWrap="wrap">
            {INT_OPC.map(([v, n]) => vidrioBtn(itn.origen === 'chat' && itn.v === v, T.violeta, <Button key={'ic-b-' + v} variant={itn.origen === 'chat' && itn.v === v ? 'primary' : 'secondary'} onPress={() => void cambiarIntens($, v, 'chat', chatIdAct)}>{n}</Button>, 'ic-' + v))}
            <Button variant="secondary" onPress={() => void cambiarIntens($, null, 'chat', chatIdAct)}>↺ Heredar global</Button>
          </Box>
        )}
        <Text size="caption" dimColor>{(INT_DESC[itn.v] || '') + (itn.msg ? ' · ' + itn.msg : '')}</Text>
      </Box>
    )
    const control = (
      <Box flexDirection="column" gap="xs" paddingX="sm" borderStyle="round" borderColor={T.violeta} backgroundColor={T.vidrio}>
        <Box flexDirection="row" justifyContent="space-between" alignItems="center">
          <Text bold color={T.violeta}>{'⚙ Control · ' + (manual ? 'manual' : 'automático') + ' · ' + (d.calidad || 'auto')}</Text>
          <Button variant="secondary" onPress={() => void update($, ctrlAbierto, v => !v)}>
            {ctrlOn ? '▴ Cerrar' : '▾ Cambiar'}
          </Button>
        </Box>
        {ctrlOn && opciones('Quién elige los motores', [['automatico', 'Automático'], ['manual', 'Manual']], d.modo, v => ['-Modo', v], (dd, v) => ({ ...dd, modo: v }))}
        {ctrlOn && opciones(
          'Esfuerzo general (Auto = decide Claude según la tarea)',
          [['auto', 'Auto'], ['economica', 'Económica'], ['equilibrada', 'Equilibrada'], ['maxima', 'Máxima']],
          d.calidad,
          v => ['-Calidad', v],
          (dd, v) => ({ ...dd, calidad: v }),
        )}
        {ctrlOn && manual && opciones(
          'Codex · esfuerzo',
          [['low', 'low'], ['medium', 'medium'], ['high', 'high'], ['xhigh', 'xhigh']],
          d.manual?.codex.esfuerzo,
          v => ['-Manual', 'codex.esfuerzo=' + v],
          (dd, v) => ({ ...dd, manual: { ...man(dd), codex: { ...man(dd).codex, esfuerzo: v } } }),
        )}
        {ctrlOn && manual && opciones(
          'Codex · modelo',
          [['gpt-6-luna', 'luna'], ['gpt-6.1-sol', 'sol'], ['gpt-6-astra', 'astra']],
          d.manual?.codex.modelo,
          v => ['-Manual', 'codex.modelo=' + v],
          (dd, v) => ({ ...dd, manual: { ...man(dd), codex: { ...man(dd).codex, modelo: v } } }),
        )}
        {ctrlOn && manual && opciones(
          'Antigravity · modelo',
          [['gemini-3.8-flash-low', 'Flash low'], ['gemini-3.8-flash-medium', 'Flash med'], ['gemini-3.8-flash-high', 'Flash high'],
            ['gemini-4-argon-low', 'Argon low'], ['gemini-4-argon-medium', 'Argon med'], ['gemini-4-argon-high', 'Argon high'],
            ['claude-sonnet-5-5-low', 'Sonnet low'], ['claude-sonnet-5-5-medium', 'Sonnet med'], ['claude-sonnet-5-5-high', 'Sonnet high'],
            ['claude-opus-5-5-low', 'Opus low'], ['claude-opus-5-5-medium', 'Opus med'], ['claude-opus-5-5-high', 'Opus high'],
            ['gpt-oss-120b-medium', 'GPT-OSS 120B']],
          d.manual?.agy.modelo,
          v => ['-Manual', 'agy.modelo=' + v],
          (dd, v) => ({ ...dd, manual: { ...man(dd), agy: { modelo: v } } }),
        )}
        {ctrlOn && <Text size="caption" dimColor>
          {manual ? 'Manual: los delegados usan siempre lo que elegiste acá.' : 'Automático: Claude elige motor y esfuerzo de cada tarea para gastar lo mínimo.'}
        </Text>}
      </Box>
    )

    const nombreRei = rei.modo === 'claude' ? 'Claude' : 'Multi-IA'
    const reiniciar = (
      <Box flexDirection="column" gap="sm" paddingX="sm" borderStyle="round" borderColor={BORDE} backgroundColor={PANEL}>
        {rei.paso === 'idle' || rei.paso === 'revisando' ? (
          <Box flexDirection="row" gap="sm" flexWrap="wrap">
            <Button variant="secondary" isDisabled={rei.paso !== 'idle'} onPress={() => { if (rei.paso === 'idle') void pedirReinicio($, 'claude') }}>🔄 Reiniciar Claude</Button>
            <Button variant="secondary" isDisabled={rei.paso !== 'idle'} onPress={() => { if (rei.paso === 'idle') void pedirReinicio($, 'orquestador') }}>↻ Reiniciar Multi-IA</Button>
          </Box>
        ) : null}
        {rei.paso === 'confirmar' && (
          <Box flexDirection="column" gap="sm">
            <Text bold color={T.ambar}>{'¿Reiniciar ' + nombreRei + '?'}</Text>
            <Box flexDirection="row" gap="sm" flexWrap="wrap">
              <Button variant="primary" onPress={() => void ejecutarReinicio($, rei.modo)}>{'Sí, reiniciar ' + nombreRei}</Button>
              <Button variant="secondary" onPress={() => void update($, reinicio, () => ({ paso: 'idle', modo: rei.modo, msg: 'Cancelado.' }))}>Cancelar</Button>
            </Box>
          </Box>
        )}
        {rei.msg && <Text size="caption" dimColor={rei.paso !== 'corriendo'} color={rei.paso === 'corriendo' ? T.ambar : undefined}>{rei.msg}</Text>}
      </Box>
    )

    const detalleLat = 'Panel cada 4 s · cupos ' + (edadCupos < 0 ? 'sin leer todavía' : 'hace ' + hace(edadCupos)) + ' (se renuevan cada 60 s)'

    // ---------- vista nueva: componentes reutilizables (compacto y Centro de control comparten todo)
    const nombreProv = (x: string) => (x === 'codex' ? 'Codex' : x === 'agy' ? 'Antigravity' : 'Claude Code')
    // 2.3.0: un 'fin' es exit 0 de la CLI, no una evaluación del resultado: nunca se muestra como verificado.
    const modeloDe = (x: string) => (d.motores ?? []).find(m => m.id === x)?.modelo_verificado || 'Modelo no verificable'
    const ESTADOS: Record<string, [string, string]> = {
      seleccionado: ['Seleccionado', T.info], inicio: ['Ejecutando', T.aviso], confirmado: ['Confirmado', T.info], recibido: ['Recibido', T.info],
      fin: ['Completado, sin verificar', T.okSuave], error: ['Error', T.errorSuave], 'sin-delegar': ['No delegó', T.tenue],
    }
    // Una fila por ejecución (se unen por ID); la más nueva primero. Los pasos intermedios solo se ven si son el último estado.
    const grupos: { v: Evento; m: string }[] = []
    const idxId = new Map<string, number>()
    for (const v of eventos) {
      const k = v.i ? idxId.get(v.i) : undefined
      if (k !== undefined) { grupos[k].v = v; grupos[k].m = grupos[k].m || v.m || '' } else { if (v.i) idxId.set(v.i, grupos.length); grupos.push({ v, m: v.m || '' }) }
    }
    const filasCons: { hora: string; ia: string; modelo: string; estado: string; color: string; motivo: string }[] = grupos.reverse().map(({ v, m }) => {
      const [est, col] = ESTADOS[v.t] ?? [v.t, T.tenue]
      return { hora: horaEv(v.f), ia: nombreProv(v.d), modelo: modeloDe(v.d), estado: est, color: col, motivo: m || (v.k ? tarea(v.k) : '') }
    })
    const nombresActivos = activos.map(v => nombreProv(v.d))
    const vistaSet = (patch: Partial<Vista>) => void update($, vistaA, v => ({ ...v, ...patch }))
    // ---------- KPI Crystal Pro: ESTE CHAT / GLOBAL. Sin valores demo; el trabajo delegado NO se presenta como ahorro.
    const alc = vista.alc === 'chat' ? 'chat' : 'global'
    if (((!ch.j && !ch.err) || (ch.j && Date.now() - ch.t > 90000)) && !ch.leyendo && !leyendoChats) void cargarChats($)   // 2.3.1: el KPI «Ahorro por chat» siempre necesita el chat actual
    const chAct = (ch.j?.chats ?? []).find(c => c.id_chat === ch.j?.chat_actual) ?? null
    const kpiDe = (alc: 'chat' | 'global') => {
      const nd = 'No determinable'
      if (alc === 'chat') {
        const c = chAct
        const tok = c?.consumo.claude_real.valor ?? null, cx = c?.consumo.codex.valor ?? null, ag = c?.consumo.antigravity.valor ?? null
        const trab = cx === null && ag === null ? null : (cx ?? 0) + (ag ?? 0)
        const cache = c?.consumo.claude_real.cache_lectura ?? 0
        const tokPond = tok === null ? 0 : tok - cache + Math.round(cache * 0.1)   // 2.3.6: las lecturas de caché cuentan al 10 % (supuesto, no medido)
        const cos = c?.consumo.claude_estimado_delegaciones.valor ?? null
        // 2.3.3: un chat conocido SIN delegaciones no ahorró nada (0, dato real), no «No determinable». Con delegaciones pero sin costo, sigue sin determinarse.
        const sinDeleg = !!c && c.delegaciones === 0
        const aho = sinDeleg ? 0 : trab !== null && cos !== null ? trab - cos : null   // 2.3.0 UX: sin recortar a 0; un balance negativo se muestra tal cual
        const ejN = (ch.j?.ejecuciones_recientes ?? []).filter(e => e.id_chat === c?.id_chat).length
        return [
          { v: tok === null && trab === null ? 's/d' : fmt((tok ?? 0) + (trab ?? 0)), r: 'tokens totales', c: T.violeta },   // 2.3.0 UX: Claude + delegado, igual que Global
          { v: c ? String(c.delegaciones) : 's/d', r: 'delegados (llamadas)', c: T.cian },
          { v: trab === null ? 's/d' : fmt(trab), r: 'trabajo delegado', c: T.brillo },
          { v: cos === null ? 's/d' : fmt(cos), r: 'costo estimado', c: T.ambar },
          { v: aho === null ? nd : '≈ ' + fmt(aho), r: 'ahorro estimado', c: (aho ?? 0) < 0 ? T.aviso : T.okSuave },
          { v: c ? String(ejN) : 's/d', r: 'ejecuciones', c: T.cian },
          { v: sinDeleg ? '0 %' : aho === null || !trab || tok === null ? nd : Math.round(aho * 100 / (trab + tokPond)) + ' %', r: 'ahorro por chat', c: T.ahorro },   // 2.3.6: sobre el tráfico PONDERADO del chat (Claude con la caché al 10 % + delegado), no solo sobre lo delegado
          { v: 's/d', r: 'recuperaciones', c: T.magenta },
        ]
      }
      const conCosto = d.claude_costo !== undefined && d.claude_costo !== null
      const netoK = deleg - costo   // 2.3.0 UX: balance sin recortar (puede ser negativo), igual que en «Este chat»
      return [
        { v: fmt(sumC + deleg), r: 'tokens totales', c: T.violeta },
        { v: String(d.deleg_n ?? 0), r: 'delegados (llamadas)', c: T.cian },
        { v: fmt(deleg), r: 'trabajo delegado', c: T.brillo },
        { v: conCosto ? fmt(costo) : 's/d', r: 'costo estimado', c: T.ambar },
        { v: conCosto ? '≈ ' + fmt(netoK) : nd, r: 'ahorro estimado', c: conCosto && netoK < 0 ? T.aviso : T.okSuave },
        { v: ef ? String(ef.exitosas + ef.fallidas) : 's/d', r: 'ejecuciones', c: T.cian },
        { v: conCosto && deleg > 0 && sumC + deleg > 0 ? Math.round(netoK * 100 / (sumC + deleg)) + ' %' : nd, r: 'ahorro por chat (agregado)', c: T.ahorro },
        { v: ef ? String(ef.fallas_recuperadas) : 's/d', r: 'recuperaciones', c: T.magenta },
      ]
    }
    const kG = kpiDe('global'), kC = kpiDe('chat')
    // 2.3.1: cuatro tarjetas fijas (2×2). Global = registro del plugin; «Ahorro por chat» = solo la conversación actual. Delegado ≠ ahorro: el ahorro es delegado − costo de coordinar (estimado).
    const sinD = (v: string) => v === 's/d' || v === '—'
    const nDel = d.deleg_n ?? 0
    const kpiCuatro = [
      { v: sinD(kG[0].v) ? 'Sin datos' : kG[0].v, r: 'Tokens totales', c: T.violeta, ic: 'chip', d: 'Claude + delegado (global)' },
      { v: sinD(kG[4].v) ? 'Sin datos' : kG[4].v, r: 'Tokens ahorrados', c: T.okSuave, ic: 'rayo', d: nDel + (nDel === 1 ? ' delegación' : ' delegaciones') },
      { v: sinD(kC[6].v) ? 'Sin datos' : kC[6].v, r: 'Ahorro por chat', c: T.ahorro, ic: 'moneda', d: 'estimación, no cuota · caché de Claude al 10 %' },   // 2.3.12: cuenta tokens de la CLI (con su contexto fijo de entrada), no solo lo entregado
      { v: sinD(kG[3].v) ? 'Sin datos' : kG[3].v, r: 'Costo estimado', c: T.ambar, ic: 'monedas', d: 'tokens de Claude (coordinar)' },
    ]
    const kpiCols = 2, mitad = centro ? Math.floor(anchoU * 0.49) : anchoU
    const nDeleg24 = eventos.filter(v => v.t === 'fin' && Date.now() - msEv(v.f) < 86400000).length
    const motoresVivos = Array.from(new Set(nombresActivos))
    const resumen = svg(svgKpis(mitad, kpiCols, kpiCuatro), 'Métricas: ' + kpiCuatro.map(k => k.r + ' ' + k.v + (k.d ? ' (' + k.d + ')' : '')).join('; '), mitad, hKpis(4, kpiCols))
    const abrirCentro = (sec?: string) => { if (sec) vistaSet({ seccion: sec }); void $.ui.open({ id: PANE_CC, title: TITULO_CC }) }

    // Gráfico: 24 h por hora (Claude estimado / delegado real) y 7 d / 30 d con la serie diaria REAL de uso.jsonl (nada inventado).
    const dias = d.dias ?? []
    // 2.3.0 Pixel Pro: tres motores con su color (Claude naranja, Codex cian, Antigravity violeta). Si una fila vieja no trae cx/ag, se muestra «Delegado» sin partir.
    const porMotor = horas.length > 0 && horas.every(x => typeof x.cx === 'number' && typeof x.ag === 'number')
    const series24: Serie[] = [{ k: 'c', l: 'Claude', c: colorIa('Claude'), t: 'estimado', v: horas.map(x => x.c) },
      ...(porMotor ? [{ k: 'codex', l: 'Codex', c: colorIa('Codex'), t: 'real' as const, v: horas.map(x => x.cx as number) }, { k: 'agy', l: 'Antigravity', c: colorIa('Antigravity'), t: 'real' as const, v: horas.map(x => x.ag as number) }]
        // 2.3.0 UX: «Delegado» sin el cian de Codex (suma Codex + Antigravity)
        : [{ k: 'd', l: 'Delegado', c: T.brillo, t: 'real' as const, v: horas.map(x => x.d) }])]
    const rangoDias = vista.rango === '7d' ? 7 : 30
    const etqG = vista.rango === '24h' ? horas.map(x => x.h + ' h') : dias.slice(-rangoDias).map(x => x.d)
    const sG: Serie[] = vista.rango === '24h'
      ? series24
      : [
        { k: 'codex', l: 'Codex', c: colorIa('Codex'), t: 'real', v: dias.slice(-rangoDias).map(x => x.codex) },
        { k: 'agy', l: 'Antigravity', c: colorIa('Antigravity'), t: 'real', v: dias.slice(-rangoDias).map(x => x.agy) },
        { k: 'costo', l: 'Claude (costo de coordinar)', c: colorIa('Claude'), t: 'estimado', v: dias.slice(-rangoDias).map(x => x.costo) },
        { k: 'ahorro', l: 'Ahorro', c: T.ahorro, t: 'calculado', v: dias.slice(-rangoDias).map(x => Math.max(0, x.codex + x.agy - x.costo)) },
      ]
    const graficoNuevo = (ancho: number, alto: number) => (
      <Box flexDirection="column" gap="xs">
        <Box flexDirection="row" justifyContent="space-between" alignItems="center" flexWrap="wrap" gap="xs">
          <Text bold>▂▅ Consumo y ahorro</Text>
          <Box flexDirection="row" gap="xs">
            {(['24h', '7d', '30d'] as const).map(r => <Button key={'r-' + r} variant={vista.rango === r ? 'primary' : 'secondary'} onPress={() => vistaSet({ rango: r })}>{r}</Button>)}
          </Box>
        </Box>
        {svg(svgGrafico(etqG, sG, vista.ocultas, ancho, alto, fmt), 'Gráfico ' + vista.rango + ': ' + sG.filter(s => !vista.ocultas.includes(s.k)).map(s => s.l + ' ' + fmt(s.v.reduce((a, b) => a + b, 0)) + ' (' + s.t + ')').join(' · '), ancho, alto, true)}
        <Box flexDirection="row" gap="xs" flexWrap="wrap">
          {sG.map(s => <Button key={'l-' + s.k} variant="secondary" onPress={() => vistaSet({ ocultas: vista.ocultas.includes(s.k) ? vista.ocultas.filter(x => x !== s.k) : [...vista.ocultas, s.k] })}>{(vista.ocultas.includes(s.k) ? '○ ' : '■ ') + s.l + ' · ' + s.t}</Button>)}
        </Box>
        <Text size="caption" dimColor>{vista.rango === '24h' ? 'Real = delegado (uso.jsonl) · estimado = lo que gastó Claude. ' : 'Serie diaria real de uso.jsonl; ahorro = calculado (delegado − costo de coordinar, estimado). Días sin registros = 0. '}Tocá o pasá el cursor por una columna para ver el detalle.</Text>
      </Box>
    )
    const alertas = presionClaude(d) >= PRESION && <Text size="caption" bold color={T.errorSuave}>{'⚠ Cupo de Claude al ' + presionClaude(d) + '%: modo ahorro fuerte, delega todo lo que pueda'}</Text>
    const apagado = !encendido && (
      <Box flexDirection="column" paddingX="sm" borderStyle="round" borderColor={T.coral} backgroundColor={T.sCoral}>
        <Text bold color={T.coral}>⏻ Multi-IA está apagado</Text>
        <Text size="caption" dimColor>Claude trabaja solo, sin delegar a Codex ni Antigravity, y los avisos automáticos están callados. Los cupos se siguen mostrando.</Text>
        <Box flexDirection="row"><Button variant="primary" onPress={() => void cambiar($, dd => ({ ...dd, activo: true }), ['-Encender'])}>Encender</Button></Box>
      </Box>
    )
    const interruptor = (
      <Box borderStyle="round" borderColor={encendido ? T.cian : T.coral} backgroundColor={encendido ? T.sCian : T.sCoral}>
        <Button variant={encendido ? 'primary' : 'secondary'} onPress={() => void cambiar($, dd => ({ ...dd, activo: !encendido }), [encendido ? '-Apagar' : '-Encender'])}>
          {encendido ? 'Encendido · tocá para apagar' : 'Apagado · tocá para encender'}
        </Button>
      </Box>
    )
    // Cabecera de ancho completo y tarjeta Reactor (anillo + modo efectivo + delegaciones) con el selector de modo como Button real.
    const modoNombre = manual ? 'Manual' : 'Automático'
    const intensNombre = String(INT_OPC.find(o => o[0] === itn.v)?.[1] || itn.v).toLowerCase()
    const sinSenal = edadRap > 60
    const anchoCab = centro ? T.anchoCabExp : anchoU
    const cabecera = svg(svgCabecera(anchoCab, encendido, sinSenal),
      'Multi-IA ' + VERSION + ' · Orquestador multi-motor inteligente · ' + (!encendido ? 'Apagado' : sinSenal ? 'Sin señal' : 'Encendido') + ' · ' + estado.t.replace(/^● /, '') + (chatIdAct ? ' · chat ' + chatIdAct.slice(0, 8) : ''), anchoCab, 58)
    const elegirInt = async (v: string) => {
      await update($, intensA, x => ({ ...x, g: v, v: x.origen === 'chat' ? x.v : v }))
      await cambiarIntens($, v, 'global', chatIdAct)
      if (itn.origen === 'chat' && chatIdAct) await cambiarIntens($, v, 'chat', chatIdAct)
    }
    const tarjetaReactor = (
      <Box flexDirection="column" gap="xs">
        {svg(svgTarjetaReactor(mitad, reactor.t, reactor.c, encendido, trabajando, motoresVivos, nDeleg24, modoNombre + ' · intensidad ' + intensNombre),
          'Reactor: ' + reactor.t + ' · Reactor central · modo efectivo ' + modoNombre.toLowerCase() + ' · intensidad ' + intensNombre + ' · ' + (motoresVivos.length ? 'activos: ' + motoresVivos.join(', ') : 'listo para delegar') + ' · ' + nDeleg24 + ' delegaciones (24 h)', mitad, H_REACTOR)}
        {/* 2.3.1: selector de intensidad dentro de la tarjeta (sin bordes extra). Resalta la intensidad EFECTIVA; al elegir guarda la global y, si este chat tenía una propia, también la del chat. */}
        <Box flexDirection="row" gap="xs" flexWrap="wrap" alignItems="center">
          {INT_OPC.map(([v, n]) => <Button key={'int-' + v} variant={itn.v === v ? 'primary' : 'secondary'} onPress={() => void elegirInt(v)}>{n}</Button>)}
          {centro && <Button variant="secondary" onPress={() => void $.ui.close({ id: PANE_CC })}>⤡ Volver a compacto</Button>}
        </Box>
      </Box>
    )
    // Pie: señal de vida del enlace (● en vivo / conectando / sin señal) y última lectura de cupos.
    const pie = (
      <Box flexDirection="row" gap="xs" alignItems="center" flexWrap="wrap">
        <Text size="caption" dimColor wrap="wrap">{estado.t + (hora ? ' · cupos: ' + hora : '')}</Text>
        {!centro && <Button variant="secondary" onPress={() => abrirCentro('sistema')}>⚙ Ajustes</Button>}
      </Box>
    )


    // ---------- V3: cinco secciones (pestañas en el compacto, menú lateral en el Centro). Los MISMOS constructores sirven a los dos paneles.
    const SECS: [string, string][] = [['resumen', 'Resumen'], ['motores', 'Motores'], ['actividad', 'Actividad'], ['consumo', 'Consumo'], ['chats', 'Chats'], ['sistema', 'Sistema']]
    // Etiquetas del mismo largo (espacios de ancho fijo a los lados): el Button no se estira, así las pestañas quedan parejas.
    const sec = SECS.some(([k]) => k === vista.seccion) ? vista.seccion : 'resumen'
    if (sec === 'chats' && !ch.j && !ch.leyendo && !ch.err && !leyendoChats) void cargarChats($)   // primera vez: se lee al abrir la seccion
    if (Date.now() - itn.t > (sec === 'sistema' ? 15000 : 60000) && !leyendoIntens) void cargarIntens($, chatIdAct)
    const anchoG = anchoU
    const cardMotor = (m: NonNullable<Datos['motores']>[number]) => {
      // Cuotas reales de la tarjeta del motor (5 h y 7 d): % USADO, hora de renovación y origen (confianza). Sin dato → «No disponible».
      const tj = d.tarjetas.find(t => m.nombre.startsWith('Claude') ? t.nombre.startsWith('Claude') : m.nombre.startsWith('Codex') ? t.nombre.startsWith('Codex') : !t.nombre.startsWith('Claude') && !t.nombre.startsWith('Codex'))
      const cuota = (rot: string, v: string): CuotaM => {
        const w = tj ? ventana(tj, v) : undefined
        return w ? { r: rot, u: w.usado, nota: ([cuando(w.reinicia), w.origen].filter(Boolean).join(' · ')) || 'sin hora de renovación' } : { r: rot, u: null, nota: 'esta IA no informa esa ventana' }
      }
      const cuotas = [cuota('5 h', '5 h'), cuota('7 d', 'Semanal')]
      const ancho = centro ? 240 : T.util
      return (
        <Box key={'mo-' + m.id} flexDirection="column" width={centro ? '32%' : '100%'}>
          {svg(svgMotor(ancho, m.nombre, m.disponible, m.modelo_verificado, colorIa(m.nombre), cuotas),
            m.nombre + ': ' + (m.disponible ? 'disponible' : 'no disponible') + '; ' + cuotas.map(q => q.r + ' ' + (q.u === null ? 'no disponible' : q.u + '% usado')).join('; '), ancho, hMotor(cuotas.length))}
          <Text size="caption" color={m.modelo_verificado ? T.ok : T.aviso}>{'Modelo: ' + (m.modelo_verificado || 'Modelo no verificable')}</Text>
        </Box>
      )
    }
    const proveedores = centro ? (
      <Box flexDirection="column" gap="sm">
        {(d.motores ?? []).length > 0 && <Box flexDirection="row" gap="sm" flexWrap="wrap">{(d.motores ?? []).map(cardMotor)}</Box>}
        <Box flexDirection="row" gap="sm" flexWrap="wrap" alignItems="flex-start">
          <Box flexDirection="column" gap="sm" width="48%">{claudeCodex.map(t => tarjeta(t, t.nombre.startsWith('Claude') ? '✺' : '⌘'))}</Box>
          <Box flexDirection="column" gap="sm" width="48%">{grupoAgy}</Box>
        </Box>
      </Box>
    ) : (
      <Box flexDirection="column" gap="sm">
        {(d.motores ?? []).map(cardMotor)}
        {claudeCodex.map(t => tarjeta(t, t.nombre.startsWith('Claude') ? '✺' : '⌘'))}
        {grupoAgy}
      </Box>
    )

    // ---------- Historial V3: una fila por ejecución (eventos unidos por ID) con búsqueda, filtros, orden, detalle y exportación
    const ejecs: Ejec[] = []
    const idxE = new Map<string, number>()
    for (const v of eventos) {
      const k = v.i ? idxE.get(v.i) : undefined
      if (k !== undefined) {
        const e = ejecs[k]
        e.t = v.t; e.fin = v.f; e.d = e.d || v.d; e.x = v.x || e.x; e.m = v.m || e.m; e.k = v.k || e.k; e.tok = v.tok || e.tok; e.s = v.s || e.s; e.c = v.c || e.c; e.o = v.o || e.o
      } else {
        if (v.i) idxE.set(v.i, ejecs.length)
        ejecs.push({ i: v.i || '', f: v.f, fin: v.f, t: v.t, d: v.d, x: v.x || '', m: v.m || '', k: v.k || '', tok: v.tok || 0, s: v.s || 0, c: v.c || '', o: v.o || 'real' })
      }
    }
    const estE = (e: Ejec) => (e.t === 'fin' ? 'fin' : e.t === 'error' ? 'error' : e.t === 'sin-delegar' ? 'sin-delegar' : 'curso')
    const etqEst: Record<string, string> = { fin: 'Completado, sin verificar', error: 'Error', 'sin-delegar': 'No delegó', curso: 'En curso' }
    const clave = (e: Ejec) => e.i || e.f + '|' + e.d
    const hq = vista.q.toLowerCase()
    const hist = ejecs
      .filter(e => vista.forig === 'todo' || e.o === 'real')
      .filter(e => vista.fprov === 'todo' || e.d === vista.fprov)
      .filter(e => vista.fest === 'todo' || estE(e) === vista.fest)
      .filter(e => !hq || [e.i, nombreProv(e.d), e.d, etqEst[estE(e)], tarea(e.k), e.k, e.x, modeloDe(e.d), e.m, e.o].join(' ').toLowerCase().includes(hq))
      .sort((a, b) => (vista.orden === 'antiguo' ? (a.f < b.f ? -1 : a.f > b.f ? 1 : 0)
        : vista.orden === 'tokens' ? b.tok - a.tok
        : vista.orden === 'duracion' ? b.s - a.s
        : (a.f < b.f ? 1 : a.f > b.f ? -1 : 0)))
    const selE = ejecs.find(e => clave(e) === vista.sel)
    const grupoFiltro = (titulo: string, actual: string, items: [string, string][], campo: 'fprov' | 'fest' | 'forig' | 'orden') => (
      <Box key={'gf-' + campo} flexDirection="row" gap="xs" flexWrap="wrap" alignItems="center">
        {items.map(([v, et]) => vidrioBtn(actual === v, T.violeta, <Button variant={actual === v ? 'primary' : 'secondary'} onPress={() => vistaSet({ [campo]: v } as Partial<Vista>)}>{(actual === v ? '● ' : '') + titulo + ': ' + et}</Button>, campo + '-' + v))}
      </Box>
    )
    const buscador = (
      <Input key="q" label="Buscar en historial y consola" placeholder="id, motor, modelo, tarea, estado o motivo" value={vista.q} onInput={val => vistaSet({ q: val })} onSubmit={val => vistaSet({ q: val })} />
    )
    const historial = (
      <Box flexDirection="column" gap="xs" paddingX="sm" paddingY="xs" borderStyle="round" borderColor={T.violeta} backgroundColor={T.vidrio}>
        <Text bold color={T.violeta}>{'⇄ Historial · ' + hist.length + ' de ' + ejecs.length + ' ejecuciones'}</Text>
        {grupoFiltro('Motor', vista.fprov, [['todo', 'todos'], ['codex', 'Codex'], ['agy', 'Antigravity'], ['claude', 'Claude']], 'fprov')}
        {grupoFiltro('Estado', vista.fest, [['todo', 'todos'], ['fin', 'terminó'], ['error', 'error'], ['curso', 'en curso'], ['sin-delegar', 'no delegó']], 'fest')}
        {grupoFiltro('Origen', vista.forig, [['prod', 'reales'], ['todo', 'con pruebas']], 'forig')}
        {grupoFiltro('Orden', vista.orden, [['nuevo', 'nuevo'], ['antiguo', 'antiguo'], ['tokens', 'tokens'], ['duracion', 'duración']], 'orden')}
        {hist.length === 0 && <Text size="caption" dimColor>Ninguna ejecución coincide con la búsqueda y los filtros.</Text>}
        {hist.slice(0, centro ? 14 : 6).map(e => {
          const [, col] = ESTADOS[e.t] ?? [e.t, T.tenue]
          return (
            vidrioBtn(vista.sel === clave(e), col, <Button variant={vista.sel === clave(e) ? 'primary' : 'secondary'} onPress={() => vistaSet({ sel: vista.sel === clave(e) ? '' : clave(e) })}>
              {horaEv(e.f) + '  ' + (e.t === 'fin' ? '✔ ' : e.t === 'error' ? '✖ ' : e.t === 'sin-delegar' ? '○ ' : '⚡ ') + nombreProv(e.d) + ' · ' + etqEst[estE(e)] + (e.k ? ' · ' + tarea(e.k) : '') + (e.tok ? ' · ' + fmt(e.tok) + ' tokens' : '') + (e.s ? ' · ' + e.s + ' s' : '') + (e.o !== 'real' ? ' · ' + e.o : '')}
            </Button>, 'h-' + clave(e))
          )
        })}
        {hist.length > (centro ? 14 : 6) && <Text size="caption" dimColor>{'… y ' + (hist.length - (centro ? 14 : 6)) + ' más: afiná la búsqueda o exportá todo.'}</Text>}
        {selE && (
          <Box flexDirection="column" paddingX="sm" borderStyle="round" borderColor={T.cian} backgroundColor={FONDO}>
            <Text bold color={T.cian}>{'Detalle · ' + (selE.i || 'sin ID')}</Text>
            <Text size="caption">{'Fecha: ' + selE.f + ' · origen: ' + selE.o}</Text>
            <Text size="caption">{'Motor: ' + nombreProv(selE.d) + ' · estado: ' + etqEst[estE(selE)]}</Text>
            <Text size="caption">{'Modelo pedido: ' + (selE.x || 'ninguno (el motor usó el suyo)')}</Text>
            <Text size="caption" color={modeloDe(selE.d) === 'Modelo no verificable' ? T.aviso : T.ok}>{'Modelo del motor: ' + modeloDe(selE.d)}</Text>
            <Text size="caption">{'Confirmación de la CLI: ' + (selE.c || 'sin señal') + ' · tokens: ' + (selE.tok ? fmt(selE.tok) : 'sin dato') + ' · duración: ' + (selE.s ? selE.s + ' s' : 'sin dato')}</Text>
            <Text size="caption" dimColor>{'Tarea: ' + (selE.k ? tarea(selE.k) : '—') + ' · motivo: ' + (selE.m || '—')}</Text>
          </Box>
        )}
        <Box flexDirection="row" gap="xs" flexWrap="wrap" alignItems="center">
          <Button variant="secondary" onPress={() => void exportarHist($, 'csv', vista)}>⭳ Exportar CSV</Button>
          <Button variant="secondary" onPress={() => void exportarHist($, 'json', vista)}>⭳ Exportar JSON</Button>
        </Box>
        {vista.exp && <Text size="caption" color={vista.exp.startsWith('OK') ? T.okSuave : /^(Exportando|Generando|Preparando)/i.test(vista.exp) ? T.info : T.errorSuave}>{(vista.exp.startsWith('OK') || /^(Exportando|Generando|Preparando)/i.test(vista.exp) ? '' : '⚠ ') + vista.exp}</Text>}
        <Text size="caption" dimColor>La exportación respeta la búsqueda y los filtros de arriba y suma el modelo confirmado y los tokens del registro del ejecutor.</Text>
      </Box>
    )

    // ---------- contenido de cada sección
    const CP = centro ? 3 : 2
    const desde = Math.min(vista.cp, Math.max(0, filasCons.length - CP))
    const ventanaCons = filasCons.slice(desde, desde + CP)
    const anchoT = centro ? mitad : anchoU
    const filasAlt = centro ? filasCons.slice(0, 3) : ventanaCons
    const miniConsola = (
      <Box flexDirection="column" gap="xs">
        {svg(svgTerminal(anchoT, 'Consola', filasAlt.map(f => ({ ia: f.ia, hora: f.hora, c: f.color, a: f.modelo === 'Modelo no verificable' ? f.ia : f.ia + ' · ' + f.modelo, tag: f.estado, b: (f.motivo || 'sin motivo registrado') + (f.modelo === 'Modelo no verificable' ? ' · modelo no verificable' : '') })), nombresActivos, grupos.length, 'Sin actividad todavía'), (centro ? 'Consola resumida' : 'Mini consola') + ' · ' + (nombresActivos.length ? 'activos: ' + nombresActivos.join(', ') + ' · ' : '') + (filasAlt.length ? filasAlt.map(f => f.hora + ' ' + f.ia + ' (' + f.modelo + ') ' + f.estado + ': ' + f.motivo).join(' | ') : 'sin actividad todavía'), anchoT, 60 + Math.max(1, filasAlt.length) * 42 + 10)}
        <Box flexDirection="row" gap="xs" alignItems="center">
          {!centro && <Button variant="secondary" isDisabled={desde <= 0} onPress={() => vistaSet({ cp: Math.max(0, desde - 1) })}>▲ Subir</Button>}
          {!centro && <Button variant="secondary" isDisabled={desde >= Math.max(0, filasCons.length - CP)} onPress={() => vistaSet({ cp: Math.min(Math.max(0, filasCons.length - CP), desde + 1) })}>▼ Bajar</Button>}
          {centro
            ? <Button variant="secondary" onPress={() => vistaSet({ seccion: 'actividad' })}>☰ Historial completo</Button>
            : <Button variant="secondary" onPress={() => abrirCentro('actividad')}>☰ Historial completo</Button>}
        </Box>
      </Box>
    )
    // Tabla de motores del Resumen: estado real de cada motor y el PEOR % usado de sus cuentas en 5 h y 7 d (sin dato → «—»).
    const familia = (n: string) => (n.startsWith('Claude') ? 'c' : n.startsWith('Codex') ? 'x' : 'a')
    const peorU = (ts: Tarjeta[], v: string) => { const us = ts.map(t => ventana(t, v)?.usado).filter((u): u is number => typeof u === 'number'); return us.length ? Math.max(...us) : null }
    const filasMotor: FilaMotor[] = ((d.motores ?? []).length
      ? (d.motores ?? []).map(m => ({ nombre: m.nombre, ok: m.disponible }))
      : Array.from(new Set(d.tarjetas.map(t => familia(t.nombre)))).map(f => ({ nombre: f === 'c' ? 'Claude' : f === 'x' ? 'Codex' : 'Antigravity', ok: true })))
      .map(({ nombre, ok }) => { const ts = d.tarjetas.filter(t => familia(t.nombre) === familia(nombre)); return { nombre, ok, color: colorIa(nombre), u5: peorU(ts, "5 h"), u7: peorU(ts, "Semanal") } })
    const anchoTM = centro ? mitad : anchoU
    const tablaMotores = filasMotor.length === 0 ? <Text dimColor>Leyendo cupos… (la primera lectura tarda hasta ~30 s)</Text>
      : svg(svgTablaMotores(anchoTM, filasMotor), 'Motores · ' + filasMotor.filter(f => f.ok).length + ' activos · ' + filasMotor.map(f => f.nombre + ' ' + (f.ok ? 'activo' : 'inactivo') + ', sesión 5 h ' + (f.u5 === null ? 'sin dato' : f.u5 + '%') + ', semanal 7 d ' + (f.u7 === null ? 'sin dato' : f.u7 + '%')).join('; '), anchoTM, hTablaMotores(filasMotor.length))
    // ---------- Chats: selector, consumo por chat con nivel de confianza, motores activos ahora, consola filtrable, resumen y exportacion
    const colorNivel = (n: string) => (n === 'VERIFICADO' ? T.ok : n === 'OBSERVADO' ? T.info : n === 'ESTIMADO' ? T.aviso : T.tenue)
    const nTok = (x?: NivelDato) => (x && x.valor !== null && x.valor !== undefined ? fmt(x.valor) : 's/d')
    const cortoId = (id: string) => (id === 'sin-sesion' ? 'sin sesión' : id.slice(0, 8))
    const filaProv = (et: string, x: NivelDato | undefined, color: string) => (
      <Box key={'cp-' + et} flexDirection="column" paddingX="sm" borderStyle="round" borderColor={color} backgroundColor={FONDO}>
        <Box flexDirection="row" gap="sm" flexWrap="wrap">
          <Text bold color={color}>{et}</Text>
          <Text bold>{nTok(x)}</Text>
          <Text size="caption" bold color={colorNivel(x?.nivel ?? 'NO DISPONIBLE')}>{x?.nivel ?? 'NO DISPONIBLE'}</Text>
        </Box>
        <Text size="caption" dimColor wrap="wrap">{(x?.fuente ?? 'sin fuente') + (x?.parcial ? ' · PARCIAL: hay filas sin dato' : '')}</Text>
      </Box>
    )
    const cj = ch.j
    const listaChats = cj?.chats ?? []
    const elegido = ch.sel === 'actual' ? (listaChats.find(c => c.id_chat === cj?.chat_actual) ?? null) : ch.sel === 'todos' ? null : (listaChats.find(c => c.id_chat === ch.sel) ?? null)
    // «Este chat» sin chat activo detectado no debe caer en «todos»: no se muestra ninguna ejecución.
    const sinChatActual = ch.sel === 'actual' && !elegido
    const visibles = listaChats.filter(c => ch.est === 'todos' || (ch.est === 'activos' ? c.estado === 'activo confirmado' : c.estado !== 'activo confirmado'))
    const chSet = (patch: Partial<ChatsEstado>) => void update($, chatsA, x => ({ ...x, ...patch }))
    const ejs = (cj?.ejecuciones_recientes ?? []).filter(e => (ch.fmotor === 'todos' || e.motor === ch.fmotor || (ch.fmotor === 'agy' && e.motor === 'antigravity')) && (ch.fest === 'todos' || (ch.fest === 'error' ? e.estado === 'con error' : e.estado === ch.fest)) && !sinChatActual && (!elegido || e.id_chat === elegido.id_chat))
    const activasAhora = (cj?.ejecuciones_activas_ahora ?? []).filter(e => !sinChatActual && (!elegido || e.id_chat === elegido.id_chat))
    const dur = (s0?: number) => { const s = Number.isFinite(s0) ? Math.max(0, s0 as number) : 0; return s < 60 ? Math.round(s) + ' s' : Math.floor(s / 60) + ' min ' + Math.round(s % 60) + ' s' }
    const gr = cj?.resumen_general
    const chatsVista = (
      <Box flexDirection="column" gap="sm">
        <Box flexDirection="row" gap="sm" flexWrap="wrap" alignItems="center">
          <Button variant="secondary" isDisabled={ch.leyendo} onPress={() => void cargarChats($, true)}>{ch.leyendo ? '… leyendo' : '↻ Actualizar'}</Button>
          <Button variant="secondary" isDisabled={!cj || ch.leyendo} onPress={() => void exportarChats($, 'md')}>⤓ Exportar MD</Button>
          <Button variant="secondary" isDisabled={!cj || ch.leyendo} onPress={() => void exportarChats($, 'json')}>⤓ Exportar JSON</Button>
        </Box>
        <Text size="caption" dimColor={!ch.err} color={ch.err ? T.errorSuave : undefined} wrap="wrap">{(ch.err ? '⚠ ' + ch.err : '') || ch.msg || (cj ? 'Leído ' + String(cj.generado ?? '').replace('T', ' ') + (ch.t ? ' · hace ' + hace(Math.max(0, Math.round((ahora - ch.t) / 1000))) : '') + ' · se actualiza solo al tocar ↻ (no corre en cada refresco)' : ch.leyendo ? 'Leyendo transcripts y registros… (unos segundos)' : 'Sin lectura todavía.')}</Text>
        {cj && (
          <Box flexDirection="column" gap="sm">
            <Box flexDirection="row" gap="sm" flexWrap="wrap">
              {[['actual', 'Chat actual'], ['todos', 'Resumen general']].map(([k, et]) => vidrioBtn(ch.sel === k, T.magenta, <Button variant={ch.sel === k ? 'primary' : 'secondary'} onPress={() => chSet({ sel: k })}>{et}</Button>, 'cs-' + k))}
              {[['todos', 'Todos'], ['activos', 'Activos'], ['anteriores', 'Anteriores']].map(([k, et]) => vidrioBtn(ch.est === k, T.violeta, <Button variant={ch.est === k ? 'primary' : 'secondary'} onPress={() => chSet({ est: k })}>{et}</Button>, 'ce-' + k))}
            </Box>
            <Box flexDirection="row" gap="sm" flexWrap="wrap">
              {visibles.slice(0, centro ? 14 : 8).map(c => (
                vidrioBtn(elegido?.id_chat === c.id_chat, c.estado === 'activo confirmado' ? T.cian : T.tenue, <Button variant={elegido?.id_chat === c.id_chat ? 'primary' : 'secondary'} onPress={() => chSet({ sel: c.id_chat })}>{(c.estado === 'activo confirmado' ? '● ' : '') + cortoId(c.id_chat) + (c.id_chat === cj.chat_actual ? ' (este)' : '')}</Button>, 'cc-' + c.id_chat)
              ))}
            </Box>
            {visibles.length > (centro ? 14 : 8) && <Text size="caption" dimColor>{'… y ' + (visibles.length - (centro ? 14 : 8)) + ' chats más (usá el filtro Activos/Anteriores o exportá todo).'}</Text>}
            {elegido ? (
              <Box flexDirection="column" gap="sm">
                <Text bold wrap="wrap">{'Chat ' + elegido.id_chat}</Text>
                <Text size="caption" dimColor wrap="wrap">{elegido.estado + ' · última señal ' + String(elegido.ultima || 's/d').replace('T', ' ') + ' · ' + elegido.delegaciones + ' delegaciones reales · ' + elegido.errores + ' con error'}</Text>
                {filaProv('Claude real', elegido.consumo?.claude_real, colorIa('Claude'))}
                {filaProv('Claude estimado (delegaciones, parte del real)', elegido.consumo?.claude_estimado_delegaciones, colorIa('Claude'))}
                {filaProv('Codex', elegido.consumo?.codex, colorIa('Codex'))}
                {filaProv('Antigravity', elegido.consumo?.antigravity, colorIa('Antigravity'))}
                <Text size="caption" dimColor wrap="wrap">No hay total único: cada proveedor tiene su cuenta y unidad de cupo. s/d = sin dato (no es cero).{elegido.no_real && elegido.no_real.filas ? ' Pruebas/simulaciones excluidas: ' + elegido.no_real.filas + ' filas.' : ''}</Text>
              </Box>
            ) : ch.sel === 'actual' ? (
              <Text size="caption" color={T.aviso} wrap="wrap">Este chat todavía no tiene datos registrados. Elegí otro o mirá el resumen general.</Text>
            ) : !gr || !gr.claude_real || !gr.codex || !gr.antigravity ? (
              <Text size="caption" color={T.aviso} wrap="wrap">Resumen general no disponible todavía. Tocá ↻ Actualizar.</Text>
            ) : (
              <Box flexDirection="column" gap="sm">
                <Text bold wrap="wrap">{gr.chats + ' chats · ' + gr.chats_activos + ' activos · ' + gr.delegaciones + ' delegaciones · ' + gr.errores + ' con error'}</Text>
                {filaProv('Claude real (8 días)', { valor: gr.claude_real.valor, nivel: (gr.claude_real.niveles ?? []).join('/') || 'NO DISPONIBLE', fuente: gr.claude_real.chats_con_dato + ' chats con dato · ' + gr.claude_real.chats_sin_dato + ' sin dato' }, colorIa('Claude'))}
                {filaProv('Codex', { valor: gr.codex.valor, nivel: (gr.codex.niveles ?? []).join('/') || 'NO DISPONIBLE', fuente: gr.codex.chats_con_dato + ' chats con dato · ' + gr.codex.chats_sin_dato + ' sin dato' }, colorIa('Codex'))}
                {filaProv('Antigravity', { valor: gr.antigravity.valor, nivel: (gr.antigravity.niveles ?? []).join('/') || 'NO DISPONIBLE', fuente: gr.antigravity.chats_con_dato + ' chats con dato · ' + gr.antigravity.chats_sin_dato + ' sin dato' }, colorIa('Antigravity'))}
                <Text size="caption" dimColor wrap="wrap">{gr.nota}</Text>
              </Box>
            )}
            <Text bold color={T.cian}>{'Motores activos ahora (' + activasAhora.length + ')'}</Text>
            {activasAhora.length === 0 && <Text size="caption" dimColor wrap="wrap">Ninguno con señal en los últimos 120 s. Sin señal no se afirma “inactivo”: solo que no hay confirmación.</Text>}
            {activasAhora.map(e => (
              <Box key={'ac-' + e.id_ejecucion} flexDirection="column" paddingX="sm" borderStyle="round" borderColor={colorIa(e.motor === 'codex' ? 'Codex' : 'Antigravity')} backgroundColor={FONDO}>
                <Text bold wrap="wrap">{(e.motor === 'codex' ? 'Codex' : 'Antigravity') + ' · ' + (e.modelo || 'modelo s/d') + ' · ' + e.estado}</Text>
                <Text size="caption" dimColor wrap="wrap">{'chat ' + cortoId(e.id_chat) + ' · ejec ' + String(e.id_ejecucion || 's/d').slice(0, 8) + ' · ' + dur(e.duracion_seg) + ' (' + e.duracion_nivel + ') · ' + (e.tarea || 'tarea s/d')}</Text>
              </Box>
            ))}
            <Text bold color={T.cian}>Consola de ejecuciones</Text>
            <Box flexDirection="row" gap="sm" flexWrap="wrap">
              {[['todos', 'Todos'], ['codex', 'Codex'], ['agy', 'Antigravity']].map(([k, et]) => vidrioBtn(ch.fmotor === k, k === 'todos' ? T.violeta : colorIa(et), <Button variant={ch.fmotor === k ? 'primary' : 'secondary'} onPress={() => chSet({ fmotor: k })}>{et}</Button>, 'fm-' + k))}
              {[['todos', 'Cualquier estado'], ['error', 'Con error'], ['terminada', 'Terminadas']].map(([k, et]) => vidrioBtn(ch.fest === k, T.violeta, <Button variant={ch.fest === k ? 'primary' : 'secondary'} onPress={() => chSet({ fest: k })}>{et}</Button>, 'fs-' + k))}
            </Box>
            {ejs.length === 0 && <Text size="caption" dimColor>Sin ejecuciones con ese filtro.</Text>}
            {ejs.slice(0, centro ? 14 : 6).map(e => (
              <Box key={'ej-' + e.id_ejecucion} flexDirection="column" paddingX="sm">
                <Text size="caption" color={e.estado === 'con error' ? T.error : e.estado === 'terminada' ? T.ok : T.aviso} wrap="wrap">{String(e.fecha ?? '').replace('T', ' ').slice(5, 19) + ' · ' + (e.motor === 'codex' ? 'Codex' : 'Antigravity') + ' · ' + e.estado + (e.clase ? ' · ' + e.clase : '') + ' · chat ' + cortoId(e.id_chat)}</Text>
                {(e.causa || e.tarea) && <Text size="caption" dimColor wrap="wrap">{(e.causa ? 'causa: ' + e.causa + ' · ' : '') + (e.tarea || '')}</Text>}
              </Box>
            ))}
          </Box>
        )}
      </Box>
    )
    // Resumen compacto: gráfico chico de 24 h (sin leyenda ni rangos) y acceso al gráfico completo de Consumo.
    const s24: Serie[] = series24
    const miniGrafico = (
      <Box flexDirection="column" gap="xs">
        {svg(svgTitulo(anchoU, '▮', 'Consumo 24 h', T.cian, 'Claude estimado · delegado real'), 'Consumo de las últimas 24 h', anchoU, 38)}
        {svg(svgGrafico(horas.map(x => x.h + ' h'), s24, [], anchoU, 110, fmt), 'Gráfico 24 h: ' + s24.map(s => s.l + ' ' + fmt(s.v.reduce((a, b) => a + b, 0)) + ' (' + s.t + ')').join(' · '), anchoU, 110)}
        <Box flexDirection="row"><Button variant="secondary" onPress={() => vistaSet({ seccion: 'consumo' })}>Ver consumo</Button></Box>
      </Box>
    )
    // Crystal Pro de Actividad, Chats y Sistema: fila de KPI de vidrio arriba (los controles de abajo no cambian).
    const kpiFila = (items: { v: string; r: string; c: string; d?: string }[], etq: string) => svg(svgKpis(anchoU, 2, items), etq + ': ' + items.map(k => k.r + ' ' + k.v).join('; '), anchoU, hKpis(items.length, 2))
    const nFin = ejecs.filter(e => estE(e) === 'fin').length, nErr = ejecs.filter(e => estE(e) === 'error').length
    const kpisAct = kpiFila([
      { v: String(ejecs.length), r: 'Ejecuciones', c: T.violeta, d: hist.length < ejecs.length ? hist.length + ' con el filtro' : 'sin filtro' },
      { v: String(nFin), r: 'Terminaron', c: T.ok },
      { v: String(nErr), r: 'Con error', c: nErr ? T.error : T.tenue },
      { v: String(ejecs.filter(e => estE(e) === 'curso').length), r: 'En curso', c: T.cian },
    ], 'Resumen de actividad')
    const kpisChats = gr ? kpiFila([
      { v: String(gr.chats), r: 'Chats', c: T.cian },
      { v: String(gr.chats_activos), r: 'Activos', c: T.ok },
      { v: String(gr.delegaciones), r: 'Delegaciones', c: T.violeta },
      { v: String(gr.errores), r: 'Con error', c: gr.errores ? T.error : T.tenue },
    ], 'Resumen de chats') : null
    const kpisSis = kpiFila([
      { v: modoNombre, r: 'Elección de motores', c: T.magenta },
      { v: String(d.calidad || 'auto'), r: 'Esfuerzo general', c: T.violeta },
      { v: INT_OPC.find(o => o[0] === itn.g)?.[1] || itn.g, r: 'Intensidad global', c: T.cian },
      { v: 'v' + VERSION, r: 'Versión', c: T.tenue },
    ], 'Estado del sistema')
    let contenido
    if (sec === 'chats') contenido = <Box flexDirection="column" gap="sm">{svg(svgTitulo(anchoU, '❏', 'Chats', T.cian, ch.j ? (ch.j.chats ?? []).length + ' chats' : ''), 'Chats registrados', anchoU, 38)}{kpisChats}{chatsVista}</Box>
    else if (sec === 'motores') contenido = <Box flexDirection="column" gap="sm">{tablaMotores}{proveedores}</Box>
    else if (sec === 'actividad') contenido = <Box flexDirection="column" gap="sm">{svg(svgTitulo(anchoU, '☰', 'Actividad', T.violeta, ejecs.length + ' ejecuciones'), 'Actividad · ' + ejecs.length + ' ejecuciones', anchoU, 38)}{kpisAct}{buscador}{historial}{consola}</Box>
    else if (sec === 'consumo') contenido = <Box flexDirection="column" gap="sm">{graficoNuevo(anchoG, centro ? 260 : 150)}{ahorro}{consumoGlobal}{eficiencia}{!g && !ef && <Text size="caption" dimColor>Sin datos de consumo todavía</Text>}</Box>
    else if (sec === 'sistema') {
      contenido = (
        <Box flexDirection="column" gap="sm">
          {svg(svgTitulo(anchoU, '⚙', 'Sistema', T.violeta, 'v' + VERSION), 'Sistema · encendido, intensidad, modo y reinicio', anchoU, 38)}
          {kpisSis}
          {!centro && interruptor}
          {intensidadUI}
          {control}
          {reiniciar}
          <Text size="caption" dimColor>{detalleLat}</Text>
          {d?.pesada && <Text size="caption" dimColor>{'Sesión más pesada (7 d): ' + (d.pesada.msgs ?? 0) + ' msgs · contexto medio ' + Math.round((d.pesada.ctx ?? 0) / 1000) + 'k'}</Text>}
        </Box>
      )
    } else if (centro) {
      // Centro (J): reactor + KPI 2×2 · motores + consola · gráfico completo.
      contenido = (
        <Box flexDirection="column" gap="sm">
          <Box flexDirection="row" gap="sm" alignItems="flex-start">
            <Box flexDirection="column" width="49%">{tarjetaReactor}</Box>
            <Box flexDirection="column" width="49%">{resumen}</Box>
          </Box>
          <Box flexDirection="row" gap="sm" alignItems="flex-start">
            <Box flexDirection="column" width="49%">{tablaMotores}</Box>
            <Box flexDirection="column" width="49%">{miniConsola}</Box>
          </Box>
          {graficoNuevo(anchoU, 220)}
        </Box>
      )
    } else {
      contenido = (
        <Box flexDirection="column" gap="sm">
          {resumen}
          {tablaMotores}
          {miniConsola}
          {miniGrafico}
        </Box>
      )
    }

    if (!centro) {
      // ---------- PANEL COMPACTO (2.3.0 Pixel Pro): encabezado · reactor · navegación discreta · una sección a la vez (el interruptor vive en Sistema)
      return (
        <Box flexDirection="column" gap="sm" padding="sm" flexGrow={1} minHeight="100%" backgroundColor={FONDO}>
          {cabecera}
          {apagado}
          {alertas}
          {tarjetaReactor}
          {resumen}
          {tablaMotores}
          {miniConsola}
          {pie}
        </Box>
      )
    }

    // ---------- CENTRO DE CONTROL (expandido, pensado para 1280×800): cabecera + menú lateral con el interruptor + contenido multicolumna
    return (
      <Box flexDirection="column" gap="sm" padding="sm" flexGrow={1} minHeight="100%" backgroundColor={FONDO}>
        {cabecera}
        {apagado}
        {alertas}
        <Box flexDirection="row" gap="sm" alignItems="flex-start">
          <Box flexDirection="column" gap="xs" width="18%" paddingX="xs" borderStyle="round" borderColor={BORDE} backgroundColor={PANEL}>
            {SECS.map(([k, et]) => vidrioBtn(sec === k, T.magenta, <Button variant={sec === k ? 'primary' : 'secondary'} onPress={() => vistaSet({ seccion: k })}>{et}</Button>, 'n-' + k))}
            {interruptor}
          </Box>
          <Box flexDirection="column" gap="sm" width="80%">{sec !== 'resumen' && tarjetaReactor}{contenido}</Box>
        </Box>
        {pie}
      </Box>
    )
  })
}
