import { expect, test } from 'claude-code/testing'

const PANE = {
  plugin: 'multi-ia-orquestador', component: 'Pane', requestId: 'multi-ia-panel',
  props: { title: 'Multi-IA', isFocused: false, bodyColumns: 40, placement: 'dock', scroll: { offset: 0, bodyRows: 20 }, view: {} },
} as const

// Vista con todas las secciones desplegadas (el panel nuevo pliega por defecto lo secundario)
const V2 = { rango: '24h', seccion: 'resumen', ocultas: [], plegadas: [], q: '', cp: 0, filtro: 'todo', fprov: 'todo', fest: 'todo', forig: 'prod', orden: 'nuevo', sel: '', exp: '' }
const vistaDe = (v: object = {}) => ({ value: { value: { shape: 'vista-2', value: { ...V2, ...v } }, version: 1, shape: 'vista-2' } })
const VISTA_ABIERTA = vistaDe()

function prepararTarjetas($: any, on: any) {
  let seccionActual = 'resumen'
  on('state.get', (_, e) => e.key === 'vista' ? vistaDe({ seccion: seccionActual }) : ({
    value: {
      value: { shape: 'datos-8', value: { modo: 'manual', calidad: 'auto', manual: { codex: { modelo: 'gpt-6-luna', esfuerzo: 'medium' }, agy: { modelo: 'gemini-3.8-flash-medium' } }, horas: [{ h: 9, c: 1000, d: 3000 }, { h: 10, c: 500, d: 0 }], deleg_total: 3000, deleg_n: 2, eventos: [{ f: '2026-11-02T10:00:00', t: 'inicio', d: 'codex', x: 'gpt-6-luna', m: 'tarea grande de codigo', k: 'codigo', tok: 0, s: 0 }, { f: '2026-11-02T10:05:00', t: 'sin-delegar', d: 'claude', x: '', m: 'tarea chica', k: 'trivial', tok: 0, s: 0 }], claude_costo: 500, ses_deleg: 1200, ses_n: 1, ses_costo: 200, tarjetas: [{ nombre: 'Antigravity · Gemini', ventanas: [{ v: '5 h', usado: 12 }] }, { nombre: 'Codex', ventanas: [{ v: '5 h', usado: 8, reinicia: '2026-11-02T11:20:00Z' }, { v: 'Semanal', usado: 85 }] }] } },
      version: 1, shape: 'datos-8',
    },
  }))
  // V3: cada contenido vive en su pestaña; se recorre cada sección con una montada propia.
  const textoDe = async (sec: string, type: string, re: RegExp) => {
    seccionActual = sec
    const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
    const r = await ui.find({ type, text: re })
    // type 'Svg' (informativo, v2.0.1): se busca por su texto alternativo
    const t = type === 'Svg'
      ? (((await ui.findAll({ type: 'Svg' })) as any[]).map(n => String(n.props?.alt ?? '')).find(a => re.test(a)))
      : ((r as any)?.text ?? (r ? 'ok' : undefined))
    await ui.unmount()
    return t as string | undefined
  }
  return textoDe
}

test('el panel dibuja una tarjeta por IA con su porcentaje', async ($, on) => {
  const textoDe = prepararTarjetas($, on)
  expect(await textoDe('motores', 'Text', /Codex/)).toContain('Codex')
  expect(await textoDe('motores', 'Text', /85%/)).toContain('85%')
  expect(await textoDe('motores', 'Text', /SESIÓN 5 H/)).toContain('SESIÓN 5 H')
  expect(await textoDe('motores', 'Text', /SEMANAL 7 DÍAS/)).toContain('SEMANAL')
  expect(await textoDe('motores', 'Text', /% libre/)).toContain('libre')
  expect(await textoDe('motores', 'Text', /Antigravity/)).toContain('Antigravity')
  expect(await textoDe('motores', 'Button', /barras/)).toBeTruthy()
})

test('el panel muestra señal de vida, consumo, sistema y actividad por sección', async ($, on) => {
  const textoDe = prepararTarjetas($, on)
  // Crystal Pro: la señal de vida (● en vivo / conectando…) vive en el pie del panel, visible en todas las secciones
  expect(await textoDe('resumen', 'Text', /conectando|en vivo|actualizando|sin señal/)).toContain('●')
  expect(await textoDe('consumo', 'Text', /en esta sesión/)).toContain('1 delegación')
  expect(await textoDe('consumo', 'Text', /ahorrados en total/)).toContain('2 delegaciones')
  // el interruptor se mudó a Sistema (compacto) y al menú lateral (Centro)
  expect(await textoDe('sistema', 'Button', /Encendido/)).toBeTruthy()
  expect(await textoDe('resumen', 'Button', /Encendido/)).toBeUndefined()
  expect(await textoDe('resumen', 'Svg', /tokens totales/)).toContain('tokens totales')
  expect(await textoDe('resumen', 'Button', /Este chat/)).toBeTruthy()
  expect(await textoDe('resumen', 'Button', /Global/)).toBeTruthy()
  expect(await textoDe('motores', 'Text', /Última lectura exitosa/)).toContain('lectura')
  expect(await textoDe('actividad', 'Text', /resolvió solo/)).toContain('no delegó')
  expect(await textoDe('actividad', 'Text', /Por qué no/)).toContain('tarea chica')
  expect(await textoDe('actividad', 'Text', /Por qué:/)).toContain('tarea grande')
  expect(await textoDe('sistema', 'Button', /Cambiar/)).toBeTruthy()
})

test('el panel muestra un indicador de actualización', async ($, on) => {
  let sec = 'resumen'
  on('state.get', (_, e) => e.key === 'vista' ? vistaDe({ seccion: sec }) : ({
    value: { value: { shape: 'datos-8', value: { modo: 'automatico', calidad: 'equilibrada', tarjetas: [] } }, version: 1, shape: 'datos-8' },
  }))
  let ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect((await ui.find({ type: 'Text', text: /conectando|en vivo|actualizando/ }))?.text).toMatch(/●/)
  await ui.unmount()
  sec = 'sistema'
  ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect((await ui.find({ type: 'Text', text: /Panel cada 4 s/ }))?.text).toContain('cupos')
  await ui.unmount()
})

test('con el cupo de Claude al 80 % avisa modo ahorro fuerte', async ($, on) => {
  on('state.get', (_, e) => e.key === 'vista' ? VISTA_ABIERTA : ({
    value: { value: { shape: 'datos-8', value: { modo: 'automatico', calidad: 'auto', tarjetas: [{ nombre: 'Claude', ventanas: [{ v: '5 h', usado: 80 }] }] } }, version: 1, shape: 'datos-8' },
  }))
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect((await ui.find({ type: 'Text', text: /ahorro fuerte/ }))?.text).toContain('80%')
  await ui.unmount()
})

test('apagado: el panel lo dice y ofrece volver a encender', async ($, on) => {
  let sec = 'resumen'
  on('state.get', (_, e) => e.key === 'vista' ? vistaDe({ seccion: sec }) : ({
    value: { value: { shape: 'datos-8', value: { activo: false, modo: 'automatico', calidad: 'equilibrada', tarjetas: [] } }, version: 1, shape: 'datos-8' },
  }))
  let ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect((await ui.find({ type: 'Text', text: /apagado/ }))?.text).toContain('apagado')
  // el aviso de apagado trae su propio botón «Encender»; la cabecera dice «Apagado»
  expect(await ui.find({ type: 'Button', text: /^Encender$/ })).toBeTruthy()
  expect(((await ui.findAll({ type: 'Svg' })) as any[]).some(n => /Apagado/.test(String(n.props?.alt ?? '')))).toBe(true)
  await ui.unmount()
  // el interruptor completo vive en Sistema
  sec = 'sistema'
  ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect(await ui.find({ type: 'Button', text: /Apagado/ })).toBeTruthy()
  await ui.unmount()
})

test('el panel ofrece reiniciar Claude y Multi-IA por separado', async ($, on) => {
  on('state.get', (_, e) => e.key === 'vista' ? vistaDe({ seccion: 'sistema' }) : ({
    value: { value: { shape: 'datos-8', value: { modo: 'automatico', calidad: 'auto', tarjetas: [] } }, version: 1, shape: 'datos-8' },
  }))
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect(await ui.find({ type: 'Button', text: /Reiniciar Claude/ })).toBeTruthy()
  expect(await ui.find({ type: 'Button', text: /Reiniciar Multi-IA/ })).toBeTruthy()
  await ui.unmount()
})

test('muestra presupuesto diario, cache y arena en el consumo global', async ($, on) => {
  on('state.get', (_, e) => e.key === 'vista' ? vistaDe({ seccion: 'consumo' }) : ({
    value: { value: { shape: 'datos-8', value: { modo: 'automatico', calidad: 'auto', tarjetas: [], glob: { ses: 2, tin: 10, tout: 5, hoy: 900, semana: 900, mes: 900, codex: 600, agy: 300, errores: 0, sin_dato: 0 }, presup: { tope: 1000, hoy: 900, aviso: 80, cache: 3, arena: 'maxima 2' } } }, version: 1, shape: 'datos-8' },
  }))
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  const t = (await ui.find({ type: 'Text', text: /Presupuesto de hoy/ }))?.text ?? ''
  expect(t).toContain('90%')
  expect(t).toContain('3 respuestas en')
  expect(t).toContain('Arena: maxima 2')
  await ui.unmount()
})
test('la consola muestra los eventos y ofrece filtros', async ($, on) => {
  on('state.get', (_, e) => e.key === 'vista' ? vistaDe({ seccion: 'actividad' }) : ({
    value: { value: { shape: 'datos-8', value: { modo: 'automatico', calidad: 'auto', tarjetas: [], eventos: [
      { f: '2026-11-04T10:00:00', t: 'fin', d: 'codex', x: '', m: '', k: 'codigo', tok: 0, s: 0 },
      { f: '2026-11-04T10:01:00', t: 'error', d: 'agy', x: '', m: '', k: 'texto', tok: 0, s: 0 },
    ] } }, version: 1, shape: 'datos-8' },
  }))
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect(await ui.find({ type: 'Text', text: /Codex terminó/ })).toBeTruthy()
  expect(await ui.find({ type: 'Text', text: /Antigravity tuvo un problema/ })).toBeTruthy()
  expect(await ui.find({ type: 'Button', text: /Errores/ })).toBeTruthy()
  await ui.unmount()
})
test('la consola lista los motores con "Modelo no verificable" y el estado real de una ejecución', async ($, on) => {
  on('state.get', (_, e) => e.key === 'vista' ? vistaDe({ seccion: 'motores' }) : ({
    value: { value: { shape: 'datos-8', value: { modo: 'automatico', calidad: 'auto', tarjetas: [],
      motores: [
        { id: 'claude', nombre: 'Claude', disponible: true, modelo: 'claude-sonnet-5-5', modelo_verificado: 'claude-sonnet-5-5' },
        { id: 'codex', nombre: 'Codex', disponible: true, modelo: 'Modelo no verificable', modelo_verificado: null },
      ],
      eventos: [
        { f: new Date().toISOString(), t: 'inicio', d: 'codex', x: 'gpt-x', m: '', k: 'codigo', tok: 0, s: 0, i: 'ej-1' },
        { f: new Date().toISOString(), t: 'confirmado', d: 'codex', x: 'gpt-x', m: '', k: 'codigo', tok: 0, s: 0, i: 'ej-1', c: 'turn.started' },
      ] } }, version: 1, shape: 'datos-8' },
  }))
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect(await ui.find({ type: 'Text', text: /Modelo no verificable/ })).toBeTruthy()
  expect(await ui.find({ type: 'Text', text: /claude-sonnet-5-5/ })).toBeTruthy()
  await ui.unmount()
})

// ---------- v1.5.0: panel compacto + Centro de control ----------
const CENTRO = { ...PANE, requestId: 'multi-ia-centro' } as const
const DATOS_V2 = {
  modo: 'automatico', calidad: 'auto', horas: [{ h: 9, c: 1000, d: 3000 }],
  motores: [{ id: 'codex', nombre: 'Codex', disponible: true, modelo_verificado: '' }, { id: 'claude', nombre: 'Claude Code', disponible: true, modelo_verificado: 'claude-sonnet-5-5' }],
  eventos: [
    { f: '2026-11-02T10:00:00', t: 'inicio', d: 'codex', x: '', m: 'tarea grande de codigo', k: 'codigo', tok: 0, s: 0, i: 'a1' },
    { f: '2026-11-02T10:01:00', t: 'fin', d: 'codex', x: '', m: '', k: 'codigo', tok: 1200, s: 40, i: 'a1' },
    { f: '2026-11-02T10:05:00', t: 'sin-delegar', d: 'claude', x: '', m: 'tarea chica', k: 'trivial', tok: 0, s: 0, i: 'b2' },
  ],
  tarjetas: [{ nombre: 'Codex', ventanas: [{ v: '5 h', usado: 8 }, { v: 'Semanal', usado: 85 }] }],
  dias: [{ d: '11-01', codex: 500, agy: 0, costo: 100, n: 1 }, { d: '11-02', codex: 1200, agy: 300, costo: 200, n: 2 }],
}
const svgAlt = async (ui: any, re: RegExp) => ((await ui.findAll({ type: 'Svg' })) as any[]).find(n => re.test(String(n.props?.alt ?? '')))
// El harness solo deja registrar on('state.get') antes del primer $: se registra una vez y las siguientes llamadas cambian lo sembrado.
const SEMBRADO = new WeakMap<object, { vista: object; datos: object }>()
const sembrar = (on: any, vista: object = {}, datos: object = DATOS_V2) => {
  const ya = SEMBRADO.get(on)
  if (ya) { ya.vista = vista; ya.datos = datos; return }
  const s = { vista, datos }
  SEMBRADO.set(on, s)
  on('state.get', (_: unknown, e: any) => (e.key === 'vista'
    ? vistaDe(s.vista)
    : { value: { value: { shape: 'datos-8', value: s.datos }, version: 1, shape: 'datos-8' } }))
}

test('compacto: consola Svg de 146 px (≤160), modelo no verificable, estados y botón de historial', async ($, on) => {
  sembrar(on)
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  const c = await svgAlt(ui, /Mini consola/)
  expect(c).toBeTruthy()
  expect(Number((c as any).props?.height ?? (c as any).height)).toBeLessThanOrEqual(160)
  const alt = String((c as any).props?.alt ?? (c as any).alt)
  expect(alt).toContain('Modelo no verificable')
  expect(alt).toContain('Codex')
  expect(alt).toContain('Completado, sin verificar')   // 2.3.0: exit 0 sin evaluación no se presenta como éxito verificado
  expect(alt).not.toContain('Terminó')
  expect(await ui.find({ type: 'Button', text: /Historial completo/ })).toBeTruthy()
  expect(await ui.find({ type: 'Button', text: /Expandir/ })).toBeTruthy()
  await ui.unmount()
})

test('compacto: sin eventos la consola no crece y dice que no hay actividad', async ($, on) => {
  sembrar(on, {}, { modo: 'automatico', calidad: 'auto', tarjetas: [] })
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  const c = await svgAlt(ui, /Mini consola/)
  expect(String((c as any).props?.alt ?? (c as any).alt)).toContain('sin actividad')
  await ui.unmount()
})

test('gráfico: 24h real/estimado, 7d y 30d con la serie diaria real, y estado sin datos', async ($, on) => {
  sembrar(on, { rango: '7d', seccion: 'consumo' })   // el gráfico completo vive en Consumo, no en el Resumen
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  const g = await svgAlt(ui, /Gráfico 7d/)
  const alt = String((g as any).props?.alt ?? (g as any).alt)
  expect(alt).toContain('Codex 2 k (real)')
  expect(alt).toContain('calculado')
  expect(alt).toContain('estimado')
  expect(await ui.find({ type: 'Button', text: /^30d$/ })).toBeTruthy()
  await ui.unmount()
})

test('gráfico: sin datos registrados en 30d sigue dibujando el gráfico', async ($, on) => {
  sembrar(on, { rango: '30d', seccion: 'consumo' }, { modo: 'automatico', calidad: 'auto', tarjetas: [] })
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect(await svgAlt(ui, /Gráfico 30d/)).toBeTruthy()
  await ui.unmount()
})

test('V3 navegación: el Centro tiene sidebar con las 5 secciones y volver a compacto', async ($, on) => {
  sembrar(on)
  const ui = await $.ui.mount({ ...CENTRO, surface: 'desktop' })
  for (const n of [/Resumen/, /Motores/, /Actividad/, /Consumo/, /Sistema/, /Volver a compacto/]) expect(await ui.find({ type: 'Button', text: n })).toBeTruthy()
  expect(await svgAlt(ui, /Reactor central/)).toBeTruthy()
  await ui.unmount()
})

test('V3 navegación: el compacto tiene pestañas y no duplica el historial en el resumen', async ($, on) => {
  sembrar(on)
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  for (const n of [/Resumen/, /Motores/, /Actividad/, /Consumo/, /Sistema/]) expect(await ui.find({ type: 'Button', text: n })).toBeTruthy()
  // el resumen no trae el historial ni los motores: cada cosa vive en una sola pestaña
  expect(await ui.find({ type: 'Text', text: /Historial · / })).toBeFalsy()
  expect(await ui.find({ type: 'Button', text: /Exportar CSV/ })).toBeFalsy()
  await ui.unmount()
})

test('V3 navegación: cada pestaña muestra solo lo suyo', async ($, on) => {
  let sec = 'resumen'
  on('state.get', (_: unknown, e: any) => (e.key === 'vista' ? vistaDe({ seccion: sec }) : { value: { value: { shape: 'datos-8', value: DATOS_V2 }, version: 1, shape: 'datos-8' } }))
  const tiene = async (s: string, type: string, re: RegExp) => { sec = s; const ui = await $.ui.mount({ ...CENTRO, surface: 'desktop' }); const r = await ui.find({ type, text: re }); await ui.unmount(); return !!r }
  expect(await tiene('actividad', 'Text', /Historial · /)).toBe(true)
  expect(await tiene('motores', 'Text', /Historial · /)).toBe(false)
  expect(await tiene('consumo', 'Text', /Historial · /)).toBe(false)
  expect(await tiene('sistema', 'Button', /Reiniciar Claude/)).toBe(true)
  expect(await tiene('actividad', 'Button', /Reiniciar Claude/)).toBe(false)
  expect(await tiene('consumo', 'Text', /EFICIENCIA|Sin datos|tokens/)).toBe(true)
})

test('Centro de control: motores muestra los modelos', async ($, on) => {
  sembrar(on, { seccion: 'motores' })
  const ui = await $.ui.mount({ ...CENTRO, surface: 'desktop' })
  expect((await ui.find({ type: 'Text', text: /Modelo: Modelo no verificable/ }))?.text).toContain('no verificable')
  expect((await ui.find({ type: 'Text', text: /Modelo: claude-sonnet-5-5/ }))?.text).toContain('claude-sonnet')
  await ui.unmount()
})

test('Centro de control: sistema ofrece los reinicios', async ($, on) => {
  sembrar(on, { seccion: 'sistema' })
  const ui = await $.ui.mount({ ...CENTRO, surface: 'desktop' })
  expect(await ui.find({ type: 'Button', text: /Reiniciar Claude/ })).toBeTruthy()
  await ui.unmount()
})

test('Centro de control: consumo muestra la eficiencia de orquestación A-G', async ($, on) => {
  sembrar(on, { seccion: 'consumo' }, { ...DATOS_V2, ef: { dias: 30, exitosas: 4, exitosas_con_tokens: 4, directas_justificadas: 50, oportunidades_perdidas: 2, fallidas: 1, fallas_recuperadas: 1, tokens_delegados: 113880, sobrecosto_por_delegacion: 400, ahorro_neto_estimado: 112000, elegibles: 7, tasa_delegacion_util: 57, recomendaciones: ['Delegar mas revision de codigo'], metodologia: 'estimado' } })
  const ui = await $.ui.mount({ ...CENTRO, surface: 'desktop' })
  expect((await svgAlt(ui, /^Eficiencia: 4 exitosas, 2 oportunidades perdidas, 1 fallidas, tasa de delegación útil 57%/))).toBeTruthy()
  expect((await svgAlt(ui, /Eficiencia, últimos 30 días/))).toBeTruthy()
  expect((await ui.find({ type: 'Text', text: /50 respuestas directas justificadas/ }))?.text).toContain('7 tareas')
  await ui.unmount()
})

// ---------- V3: historial (búsqueda, filtros, orden, detalle) ----------
const DATOS_HIST = {
  ...DATOS_V2,
  eventos: [
    { f: '2026-11-02T10:00:00', t: 'inicio', d: 'codex', x: 'gpt-x', m: 'refactor grande', k: 'codigo', tok: 0, s: 0, i: 'ej-a1' },
    { f: '2026-11-02T10:01:00', t: 'fin', d: 'codex', x: 'gpt-x', m: '', k: 'codigo', tok: 1200, s: 40, i: 'ej-a1', c: 'turn.completed', o: 'real' },
    { f: '2026-11-02T10:05:00', t: 'sin-delegar', d: 'claude', x: '', m: 'tarea chica', k: 'trivial', tok: 0, s: 0, i: 'ej-b2' },
    { f: '2026-11-02T10:10:00', t: 'inicio', d: 'agy', x: '', m: 'resumir doc', k: 'texto', tok: 0, s: 0, i: 'ej-c3' },
    { f: '2026-11-02T10:12:00', t: 'error', d: 'agy', x: '', m: 'resumir doc', k: 'texto', tok: 0, s: 90, i: 'ej-c3', o: 'real' },
    { f: '2026-11-02T10:20:00', t: 'fin', d: 'codex', x: '', m: 'prueba', k: 'codigo', tok: 50, s: 5, i: 'ej-d4', o: 'test' },
  ],
}
const cuentaHist = async (ui: any) => String(((await ui.find({ type: 'Text', text: /Historial · / })) as any)?.text ?? '')

test('V3 historial: une los eventos por ID y oculta lo no productivo por defecto', async ($, on) => {
  sembrar(on, { seccion: 'actividad' }, DATOS_HIST)
  const ui = await $.ui.mount({ ...CENTRO, surface: 'desktop' })
  // 4 ejecuciones reales (a1, b2, c3) + 1 de prueba: por defecto 3 de 4
  expect(await cuentaHist(ui)).toContain('3 de 4 ejecuciones')
  await ui.unmount()
})

test('V3 historial: el origen "todos" incluye las pruebas', async ($, on) => {
  sembrar(on, { seccion: 'actividad', forig: 'todo' }, DATOS_HIST)
  const ui = await $.ui.mount({ ...CENTRO, surface: 'desktop' })
  expect(await cuentaHist(ui)).toContain('4 de 4 ejecuciones')
  await ui.unmount()
})

test('V3 historial: filtros por motor y por estado', async ($, on) => {
  sembrar(on, { seccion: 'actividad', fprov: 'codex' }, DATOS_HIST)
  let ui = await $.ui.mount({ ...CENTRO, surface: 'desktop' })
  expect(await cuentaHist(ui)).toContain('1 de 4 ejecuciones')
  await ui.unmount()
  sembrar(on, { seccion: 'actividad', fest: 'error' }, DATOS_HIST)
  ui = await $.ui.mount({ ...CENTRO, surface: 'desktop' })
  expect(await cuentaHist(ui)).toContain('1 de 4 ejecuciones')
  await ui.unmount()
  sembrar(on, { seccion: 'actividad', fest: 'sin-delegar' }, DATOS_HIST)
  ui = await $.ui.mount({ ...CENTRO, surface: 'desktop' })
  expect(await cuentaHist(ui)).toContain('1 de 4 ejecuciones')
  await ui.unmount()
})

test('V3 historial: la búsqueda filtra por id, motivo y modelo y avisa si no hay coincidencias', async ($, on) => {
  for (const [q, n] of [['ej-c3', 1], ['refactor', 1], ['gpt-x', 1], ['resumir', 1]] as const) {
    sembrar(on, { seccion: 'actividad', q }, DATOS_HIST)
    const ui = await $.ui.mount({ ...CENTRO, surface: 'desktop' })
    expect(await cuentaHist(ui)).toContain(n + ' de 4 ejecuciones')
    await ui.unmount()
  }
  sembrar(on, { seccion: 'actividad', q: 'zzzninguno' }, DATOS_HIST)
  const ui = await $.ui.mount({ ...CENTRO, surface: 'desktop' })
  expect(await cuentaHist(ui)).toContain('0 de 4 ejecuciones')
  expect(await ui.find({ type: 'Text', text: /Ninguna ejecución coincide/ })).toBeTruthy()
  await ui.unmount()
})

test('V3 historial: orden por tokens y por antigüedad (la primera fila cambia)', async ($, on) => {
  const primera = async (orden: string) => {
    sembrar(on, { seccion: 'actividad', orden }, DATOS_HIST)
    const ui = await $.ui.mount({ ...CENTRO, surface: 'desktop' })
    const bs = ((await ui.findAll({ type: 'Button', text: /·/ })) as any[]).map(b => String(b.text ?? '')).filter(t => /(Codex|Antigravity|Claude) ·/.test(t) && !/^[●\s]*(Motor|Estado|Origen|Orden):/.test(t))
    await ui.unmount()
    return bs[0] ?? ''
  }
  expect(await primera('tokens')).toContain('Codex')
  expect(await primera('nuevo')).toContain('Antigravity')
  expect(await primera('antiguo')).toContain('Codex')
})

test('V3 historial: el detalle muestra modelo pedido, modelo del motor, confirmación y motivo', async ($, on) => {
  sembrar(on, { seccion: 'actividad', sel: 'ej-a1' }, DATOS_HIST)
  const ui = await $.ui.mount({ ...CENTRO, surface: 'desktop' })
  expect((await ui.find({ type: 'Text', text: /Detalle · ej-a1/ }))?.text).toContain('ej-a1')
  expect((await ui.find({ type: 'Text', text: /Modelo pedido: gpt-x/ }))?.text).toContain('gpt-x')
  expect((await ui.find({ type: 'Text', text: /Modelo del motor: Modelo no verificable/ }))?.text).toContain('no verificable')
  expect((await ui.find({ type: 'Text', text: /Confirmación de la CLI: turn.completed/ }))?.text).toContain('1 k')
  await ui.unmount()
})

test('V3 historial: ofrece exportar CSV y JSON', async ($, on) => {
  sembrar(on, { seccion: 'actividad' }, DATOS_HIST)
  const ui = await $.ui.mount({ ...CENTRO, surface: 'desktop' })
  expect(await ui.find({ type: 'Button', text: /Exportar CSV/ })).toBeTruthy()
  expect(await ui.find({ type: 'Button', text: /Exportar JSON/ })).toBeTruthy()
  await ui.unmount()
})

test('V3 historial: el compacto lista menos filas pero conserva búsqueda, filtros y exportación', async ($, on) => {
  sembrar(on, { seccion: 'actividad' }, DATOS_HIST)
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect(await ui.find({ type: 'Input', text: /Buscar/ }) ?? await ui.find({ type: 'Text', text: /Historial · / })).toBeTruthy()
  expect(await ui.find({ type: 'Button', text: /Estado: error/ })).toBeTruthy()
  expect(await ui.find({ type: 'Button', text: /Exportar JSON/ })).toBeTruthy()
  await ui.unmount()
})

test('V3 Centro: la consola completa filtra por búsqueda', async ($, on) => {
  sembrar(on, { seccion: 'actividad', q: 'chica' })
  const ui = await $.ui.mount({ ...CENTRO, surface: 'desktop' })
  expect(await cuentaHist(ui)).toContain('1 de 2 ejecuciones')
  await ui.unmount()
})

// ---------- V3: estados del reactor, atados a eventos reales (timestamps relativos a "ahora") ----------
const haceS = (s: number) => new Date(Date.now() - s * 1000).toISOString()
const reactorCon = async ($: any, on: any, eventos: any[], extra: object = {}) => {
  sembrar(on, {}, { ...DATOS_V2, eventos, ...extra })
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  // el estado del reactor ya no se repite en texto: vive en el alt del reactor y en la píldora del header
  const s = await svgAlt(ui, /Reactor: /)
  await ui.unmount()
  const alt = String((s as any)?.props?.alt ?? (s as any)?.alt ?? '')
  return { t: alt, alt }
}
const EV = (t: string, s: number, i = 'r1', extra: object = {}) => ({ f: haceS(s), t, d: 'codex', x: '', m: '', k: 'codigo', tok: 0, s: 0, i, ...extra })

test('V3 reactor: Disponible sin actividad', async ($, on) => {
  expect((await reactorCon($, on, [])).t).toContain('Reactor: Disponible')
})
test('V3 reactor: Desconectado cuando el sistema está apagado', async ($, on) => {
  expect((await reactorCon($, on, [], { activo: false })).t).toContain('Reactor: Desconectado')
})
test('V3 reactor: Seleccionando (motor elegido, todavía sin lanzar)', async ($, on) => {
  expect((await reactorCon($, on, [EV('seleccionado', 5)])).t).toContain('Reactor: Seleccionando')
})
test('V3 reactor: Seleccionando vence a los 60 s sin lanzar', async ($, on) => {
  expect((await reactorCon($, on, [EV('seleccionado', 90)])).t).toContain('Reactor: Disponible')
})
test('V3 reactor: Delegando (lanzado hace poco, la CLI no confirmó)', async ($, on) => {
  expect((await reactorCon($, on, [EV('seleccionado', 6), EV('inicio', 4)])).t).toContain('Reactor: Delegando')
})
test('V3 reactor: Esperando (lanzado hace más de 20 s sin confirmación)', async ($, on) => {
  expect((await reactorCon($, on, [EV('seleccionado', 40), EV('inicio', 30)])).t).toContain('Reactor: Esperando')
})
test('V3 reactor: Ejecutando (la CLI confirmó)', async ($, on) => {
  expect((await reactorCon($, on, [EV('inicio', 30), EV('confirmado', 25, 'r1', { c: 'turn.started' })])).t).toContain('Reactor: Ejecutando')
})
test('V3 reactor: Completado (terminó hace poco)', async ($, on) => {
  expect((await reactorCon($, on, [EV('inicio', 30), EV('fin', 10, 'r1', { tok: 100, s: 20 })])).t).toContain('Reactor: Completado')
})
test('V3 reactor: Completado pasa a Disponible pasado el minuto', async ($, on) => {
  expect((await reactorCon($, on, [EV('inicio', 200), EV('fin', 150, 'r1', { tok: 100, s: 20 })])).t).toContain('Reactor: Disponible')
})
test('V3 reactor: Error (falló hace poco) y vuelve a Disponible a los 2 min', async ($, on) => {
  expect((await reactorCon($, on, [EV('inicio', 30), EV('error', 10)])).t).toContain('Reactor: Error')
  expect((await reactorCon($, on, [EV('inicio', 300), EV('error', 200)])).t).toContain('Reactor: Disponible')
})
test('V3 reactor: varios motores a la vez', async ($, on) => {
  const r = await reactorCon($, on, [EV('inicio', 5, 'r1'), { ...EV('inicio', 4, 'r2'), d: 'agy' }])
  expect(r.t).toContain('2 motores a la vez')
})
test('V3 reactor: el alt del Svg coincide con el texto del estado', async ($, on) => {
  const r = await reactorCon($, on, [EV('inicio', 30), EV('confirmado', 25, 'r1', { c: 'turn.started' })])
  expect(r.alt).toContain('Ejecutando')
})

// ---------- v1.8.0: categorias de la consola (se verifica el TEXTO que se muestra, no solo que renderice) ----------
const textosConsola = async ($: any, on: any, eventos: any[]) => {
  sembrar(on, { seccion: 'actividad', forig: 'todo' }, { ...DATOS_V2, eventos })
  const ui = await $.ui.mount({ ...CENTRO, surface: 'desktop' })
  const ts = ((await ui.findAll({ type: 'Text', text: /\d\d:\d\d|\d\d\/\d\d/ })) as any[]).map(n => String(n.text ?? ''))
  await ui.unmount()
  return ts
}
const E = (t: string, min: number, extra: object = {}) => ({ f: new Date(Date.now() - min * 60000).toISOString().slice(0, 19), t, d: 'codex', x: '', m: '', k: 'codigo', tok: 0, s: 0, i: 'c-' + t + min, ...extra })

test('consola: Delegación real = "está trabajando (delegado)" sin etiqueta de prueba', async ($, on) => {
  const ts = await textosConsola($, on, [E('inicio', 3)])
  const l = ts.find(t => /Codex está trabajando \(delegado\)/.test(t))
  expect(l).toBeTruthy(); expect(l).not.toContain('PRUEBA'); expect(l).toContain('▶')
})
test('consola: Ejecución completada = "terminó" con ✔, sin "recuperado" ni prueba', async ($, on) => {
  const ts = await textosConsola($, on, [E('fin', 3, { i: 'ej-1', o: 'real' })])
  const l = ts.find(t => /Codex terminó/.test(t))
  expect(l).toBeTruthy(); expect(l).toContain('✔'); expect(l).not.toContain('recuperado'); expect(l).not.toContain('PRUEBA')
})
test('consola: Error = "tuvo un problema" con ✖', async ($, on) => {
  const ts = await textosConsola($, on, [{ ...E('error', 3, { i: 'ej-2' }), d: 'agy' }])
  const l = ts.find(t => /Antigravity tuvo un problema/.test(t))
  expect(l).toBeTruthy(); expect(l).toContain('✖')
})
test('consola: Recuperado = fin con id "-r" dice "terminó (recuperado tras una falla)" y el error previo sigue visible', async ($, on) => {
  const ts = await textosConsola($, on, [E('error', 5, { i: 'ej-9' }), { ...E('fin', 3, { i: 'ej-9-r' }), d: 'agy' }])
  expect(ts.find(t => /Antigravity terminó \(recuperado tras una falla\)/.test(t))).toBeTruthy()
  expect(ts.find(t => /Codex tuvo un problema/.test(t))).toBeTruthy()
  expect(ts.find(t => /Codex terminó \(recuperado/.test(t))).toBeFalsy()
})
test('consola: Prueba = origen no real lleva [PRUEBA <origen>] y el real no', async ($, on) => {
  const ts = await textosConsola($, on, [E('fin', 3, { i: 'p1', o: 'simulacion' }), E('fin', 2, { i: 'p2', o: 'benchmark' }), E('fin', 1, { i: 'p3', o: 'real' })])
  expect(ts.find(t => /\[PRUEBA simulacion\] Codex terminó/.test(t))).toBeTruthy()
  expect(ts.find(t => /\[PRUEBA benchmark\] Codex terminó/.test(t))).toBeTruthy()
  const real = ts.filter(t => /Codex terminó/.test(t) && !t.includes('PRUEBA'))
  expect(real.length).toBe(1)
})
test('consola: Reinicio = "Reinicio del panel o de Claude"', async ($, on) => {
  const ts = await textosConsola($, on, [{ ...E('reinicio', 3), d: 'claude' }])
  expect(ts.find(t => /Reinicio del panel o de Claude/.test(t))).toBeTruthy()
})
test('consola: Tipo desconocido muestra "Evento: <tipo>" en vez de inventar una frase', async ($, on) => {
  const ts = await textosConsola($, on, [E('cambio-motor', 3), E('tipo-raro', 2)])
  expect(ts.find(t => /Evento: cambio-motor/.test(t))).toBeTruthy()
  expect(ts.find(t => /Evento: tipo-raro/.test(t))).toBeTruthy()
})
test('consola: Sin delegar distingue Claude solo y Pendiente', async ($, on) => {
  const ts = await textosConsola($, on, [{ ...E('sin-delegar', 3), d: 'claude' }, { ...E('sin-delegar', 2), d: 'pendiente' }])
  expect(ts.find(t => /Claude lo resolvió solo/.test(t))).toBeTruthy()
  expect(ts.find(t => /Quedó pendiente/.test(t))).toBeTruthy()
})
test('Chats: muestra niveles de confianza, s/d distinto de cero, motores activos y exportación', async ($, on) => {
  const nv = (valor: number | null, nivel: string, fuente = 'transcript') => ({ valor, nivel, fuente, parcial: false })
  const CHATS = {
    generado: '2026-11-05T10:00:00', chat_actual: 'aaaaaaaa-1111',
    chats: [{
      id_chat: 'aaaaaaaa-1111', estado: 'activo confirmado', primera: '2026-11-05T09:00:00', ultima: '2026-11-05T09:59:00', delegaciones: 2, errores: 1,
      consumo: { claude_real: nv(1234, 'VERIFICADO'), claude_estimado_delegaciones: nv(null, 'NO DISPONIBLE', 'sin datos'), codex: nv(500, 'OBSERVADO'), antigravity: nv(null, 'NO DISPONIBLE', 'sin datos'), total: null }, no_real: null,
    }],
    ejecuciones_recientes: [{ id_ejecucion: 'e1e1e1e1-x', id_chat: 'aaaaaaaa-1111', motor: 'codex', estado: 'con error', fecha: '2026-11-05T09:58:00', clase: 'cuota', causa: 'limite', tarea: 'revisar' }],
    ejecuciones_activas_ahora: [{ id_ejecucion: 'e2e2e2e2-x', id_chat: 'aaaaaaaa-1111', motor: 'agy', estado: 'activo confirmado', modelo: 'gemini', duracion_seg: 30, duracion_nivel: 'OBSERVADO', tarea: 'analizar' }],
    resumen_general: { chats: 1, chats_activos: 1, delegaciones: 2, errores: 1, nota: 'nota', claude_real: { valor: 1234, niveles: ['VERIFICADO'], chats_con_dato: 1, chats_sin_dato: 0 }, codex: { valor: 500, niveles: ['OBSERVADO'], chats_con_dato: 1, chats_sin_dato: 0 }, antigravity: { valor: null, niveles: [], chats_con_dato: 0, chats_sin_dato: 1 } },
  }
  on('state.get', (_: unknown, e: any) => {
    if (e.key === 'vista') return vistaDe({ seccion: 'chats' })
    if (e.key === 'chats') return { value: { value: { shape: 'chats-1', value: { j: CHATS, t: Date.now(), leyendo: false, err: '', sel: 'actual', est: 'todos', fmotor: 'todos', fest: 'todos', msg: '' } }, version: 1, shape: 'chats-1' } }
    return { value: { value: { shape: 'datos-8', value: DATOS_V2 }, version: 1, shape: 'datos-8' } }
  })
  const ui = await $.ui.mount({ ...CENTRO, surface: 'desktop' })
  expect(await ui.find({ type: 'Text', text: /VERIFICADO/ })).toBeTruthy()
  expect(await ui.find({ type: 'Text', text: /NO DISPONIBLE/ })).toBeTruthy()
  expect(await ui.find({ type: 'Text', text: /^s\/d$/ })).toBeTruthy()
  expect(await ui.find({ type: 'Text', text: /Motores activos ahora \(1\)/ })).toBeTruthy()
  for (const n of [/Actualizar/, /Exportar MD/, /Exportar JSON/]) expect(await ui.find({ type: 'Button', text: n })).toBeTruthy()
  await ui.unmount()
})
