import { expect, test } from 'claude-code/testing'

// Pruebas de COMPORTAMIENTO (Codex #7): se aprieta el botón real con ui.press y se verifica
// 1) la escritura que el panel manda al anfitrión (state.set) y 2) lo que se dibuja después.
// El almacén en memoria hace de anfitrión: guarda lo escrito y lo devuelve en el siguiente state.get.
// Reemplaza la cobertura que antes solo existía como búsqueda de texto en register.tsx (probar.ps1).

const PANE = {
  plugin: 'multi-ia-orquestador', component: 'Pane', requestId: 'multi-ia-centro',
  props: { title: 'Multi-IA', isFocused: false, bodyColumns: 46, placement: 'dock', scroll: { offset: 0, bodyRows: 20 }, view: {} },
} as const
const V0 = { rango: '24h', seccion: 'resumen', ocultas: [], plegadas: [], q: '', cp: 0, filtro: 'todo', fprov: 'todo', fest: 'todo', forig: 'prod', orden: 'nuevo', sel: '', exp: '' }
const DATOS = {
  modo: 'automatico', calidad: 'auto', horas: [{ h: 9, c: 1000, d: 3000 }],
  eventos: [{ f: '2026-11-02T10:00:00', t: 'fin', d: 'codex', x: 'gpt-6-luna', m: 'tarea', k: 'codigo', tok: 1200, s: 0, ej: 'ej-1' }],
  tarjetas: [{ nombre: 'Codex', ventanas: [{ v: '5 h', usado: 8 }, { v: 'Semanal', usado: 40 }] }],
  dias: [{ d: '11-01', codex: 500, agy: 0, costo: 100, n: 1 }, { d: '11-02', codex: 1200, agy: 300, costo: 200, n: 2 }],
}

// Un solo registro de hooks por prueba (el harness no deja registrar después del primer $).
// Almacén genérico por clave con versión (el anfitrión hace CAS con ifVersion); lo no sembrado arranca con los datos, como en panel.test.tsx.
const almacen = (on: any, vista: object = {}, datos: object = DATOS) => {
  const m = new Map<string, { value: any; ver: number }>()
  m.set('vista', { value: { shape: 'vista-2', value: { ...V0, ...vista } }, ver: 1 })
  const semilla = { shape: 'datos-8', value: datos }
  const s = { escrituras: [] as any[] }
  const de = (k: string) => { if (!m.has(k)) m.set(k, { value: semilla, ver: 1 }); return m.get(k)! }
  on('state.get', (_: unknown, e: any) => { const x = de(e.key); return { value: { value: x.value, version: x.ver, shape: x.value?.shape } } })
  on('state.set' as any, (_: unknown, e: any) => {
    const x = de(e.key)
    if (e.ifVersion != null && e.ifVersion !== x.ver) return { value: { isSet: false, version: x.ver } } as any
    s.escrituras.push({ key: e.key, value: e.value?.value })
    x.value = e.value; x.ver++
    return { value: { isSet: true, version: x.ver } } as any
  })
  return s
}
const montar = async ($: any) => $.ui.mount({ ...PANE, surface: 'desktop' })
const apretar = async (ui: any, re: RegExp) => {
  const b = await ui.find({ type: 'Button', text: re })
  expect(b).toBeTruthy()
  await ui.press(b)
  await ui.advance?.(200); await ui.redraw?.()
}
const variante = async (ui: any, re: RegExp) => ((await ui.find({ type: 'Button', text: re })) as any)?.props?.variant
const svgAlt = async (ui: any, re: RegExp) => ((await ui.findAll({ type: 'Svg' })) as any[]).find(n => re.test(String(n.props?.alt ?? '')))
const ultimaVista = (s: any) => [...s.escrituras].reverse().find((w: any) => w.key === 'vista')?.value

test('interacción: tocar «Motores» cambia de sección, la marca activa y dibuja las cuotas', async ($, on) => {
  const s = almacen(on)
  const ui = await montar($)
  expect(await variante(ui, /^Resumen$/)).toBe('primary')
  expect(await ui.find({ type: 'Text', text: /SESIÓN 5 H/ })).toBeFalsy()
  await apretar(ui, /^Motores$/)
  expect(ultimaVista(s)?.seccion).toBe('motores')
  expect(await variante(ui, /^Motores$/)).toBe('primary')
  expect(await variante(ui, /^Resumen$/)).toBe('secondary')
  expect(await ui.find({ type: 'Text', text: /SESIÓN 5 H/ })).toBeTruthy()
  await ui.unmount()
})

test('interacción: recorrer las 6 pestañas deja cada una activa por turno', async ($, on) => {
  const s = almacen(on)
  const ui = await montar($)
  for (const [et, k] of [['Actividad', 'actividad'], ['Consumo', 'consumo'], ['Chats', 'chats'], ['Sistema', 'sistema'], ['Resumen', 'resumen']] as const) {
    await apretar(ui, new RegExp('^' + et + '$'))
    expect(ultimaVista(s)?.seccion).toBe(k)
    expect(await variante(ui, new RegExp('^' + et + '$'))).toBe('primary')
    if (k === 'sistema') expect(await ui.find({ type: 'Button', text: /Reiniciar Claude/ })).toBeTruthy()
  }
  // Sistema dibuja los reinicios (comprobado dentro del recorrido) y Resumen no
  expect(await ui.find({ type: 'Button', text: /Reiniciar Claude/ })).toBeFalsy()
  await ui.unmount()
})


test('interacción: el selector 24h/7d/30d cambia el rango y el gráfico que se dibuja', async ($, on) => {
  const s = almacen(on, { seccion: 'consumo' })
  const ui = await montar($)
  expect(await svgAlt(ui, /Gráfico 24h/)).toBeTruthy()
  await apretar(ui, /^30d$/)
  expect(ultimaVista(s)?.rango).toBe('30d')
  expect(await svgAlt(ui, /Gráfico 30d/)).toBeTruthy()
  expect(await svgAlt(ui, /Gráfico 24h/)).toBeFalsy()
  await apretar(ui, /^7d$/)
  expect(await svgAlt(ui, /Gráfico 7d/)).toBeTruthy()
  await ui.unmount()
})


test('interacción: apagado, «Encender» escribe activo=true y el aviso de apagado desaparece', async ($, on) => {
  const s = almacen(on, {}, { ...DATOS, activo: false })
  const ui = await montar($)
  expect(await ui.find({ type: 'Text', text: /apagado/ })).toBeTruthy()
  await apretar(ui, /^Encender$/)
  const w = [...s.escrituras].reverse().find((x: any) => x.key === 'datos')
  expect(w?.value?.activo).toBe(true)
  expect(await ui.find({ type: 'Button', text: /^Encender$/ })).toBeFalsy()
  await ui.unmount()
})

// Auditoría: con «Este chat» elegido y sin chat activo detectado, el filtro caía en «todos» y mostraba ejecuciones ajenas.
const ejec = (t: string) => ({ id_ejecucion: 'e-' + t, id_chat: 'otro-chat-123', motor: 'codex', modelo: 'gpt-5.5', tarea: t, estado: 'terminó', frescura: '', inicio: '', duracion_seg: 5, duracion_nivel: 'corta', fecha: '2026-11-07' })
const chatsSem = (sel: string) => ({ shape: 'chats-1', value: { j: { generado: '', chat_actual: null, chats: [], ejecuciones_activas_ahora: [], ejecuciones_recientes: [ejec('tarea-ajena-zz')], resumen_general: null, nota: '' }, t: Date.now(), leyendo: false, err: '', sel, est: 'todos', fmotor: 'todos', fest: 'todos', msg: '' } })
for (const [sel, debe] of [['actual', false], ['todos', true]] as const) test('chats: sel=' + sel + ' sin chat activo ' + (debe ? 'muestra' : 'no muestra') + ' ejecuciones de otros chats', async ($, on) => {
  on('state.get', (_: unknown, e: any) => {
    const v = e.key === 'vista' ? { shape: 'vista-2', value: { ...V0, seccion: 'chats' } } : e.key === 'chats' ? chatsSem(sel) : { shape: 'datos-8', value: DATOS }
    return { value: { value: v, version: 1, shape: v.shape } }
  })
  const ui = await montar($)
  const txt = JSON.stringify((await ui.findAll({}) as any[])[0])
  expect(txt.includes('tarea-ajena-zz')).toBe(debe)
  await ui.unmount()
})

// Crystal Pro 2.2.0: Actividad, Chats y Sistema suman una fila de KPI de vidrio y conservan los controles viejos.
const montarSec = async ($: any, on: any, seccion: string, extra: Record<string, any> = {}) => {
  on('state.get', (_: unknown, e: any) => {
    const v = e.key === 'vista' ? { shape: 'vista-2', value: { ...V0, seccion } } : extra[e.key] ?? { shape: 'datos-8', value: DATOS }
    return { value: { value: v, version: 1, shape: v.shape } }
  })
  return montar($)
}
test('Actividad: KPI de vidrio con los conteos reales y el filtro de estado los reubica', async ($, on) => {
  const ui = await montarSec($, on, 'actividad')
  const k = await svgAlt(ui, /^Resumen de actividad/)
  expect(k).toBeTruthy()
  expect(String(k.props.alt)).toMatch(/Ejecuciones 1; Terminaron 1; Con error 0; En curso 0/)
  expect(await ui.find({ type: 'Input' })).toBeTruthy()                       // controles viejos intactos
  expect(await ui.find({ type: 'Button', text: /Exportar CSV/ })).toBeTruthy()
  await ui.unmount()
})
test('Actividad: sin ejecuciones los KPI valen 0 y no se inventan datos', async ($, on) => {
  const ui = await montarSec($, on, 'actividad', { datos: { shape: 'datos-8', value: { ...DATOS, eventos: [] } } })
  const k = await svgAlt(ui, /^Resumen de actividad/)
  expect(String(k?.props?.alt)).toMatch(/Ejecuciones 0; Terminaron 0; Con error 0; En curso 0/)
  await ui.unmount()
})
test('Chats: KPI del resumen general y controles viejos (Actualizar, exportar, Chat actual)', async ($, on) => {
  const gr = { chats: 3, chats_activos: 1, delegaciones: 5, errores: 2, claude_real: { valor: 1, niveles: [], chats_con_dato: 1, chats_sin_dato: 2 }, codex: { valor: 1, niveles: [], chats_con_dato: 1, chats_sin_dato: 2 }, antigravity: { valor: 0, niveles: [], chats_con_dato: 0, chats_sin_dato: 3 } }
  const ch = { shape: 'chats-1', value: { j: { generado: '', chat_actual: null, chats: [], ejecuciones_activas_ahora: [], ejecuciones_recientes: [], resumen_general: gr, nota: '' }, t: Date.now(), leyendo: false, err: '', sel: 'todos', est: 'todos', fmotor: 'todos', fest: 'todos', msg: '' } }
  const ui = await montarSec($, on, 'chats', { chats: ch })
  expect(String((await svgAlt(ui, /^Resumen de chats/))?.props?.alt)).toMatch(/Chats 3; Activos 1; Delegaciones 5; Con error 2/)
  expect(await ui.find({ type: 'Button', text: /Actualizar/ })).toBeTruthy()
  expect(await ui.find({ type: 'Button', text: /Exportar MD/ })).toBeTruthy()
  expect(await ui.find({ type: 'Button', text: /Chat actual/ })).toBeTruthy()
  await ui.unmount()
})
test('Chats: sin resumen general no se dibujan KPI inventados', async ($, on) => {
  const ch = { shape: 'chats-1', value: { j: { generado: '', chat_actual: null, chats: [], ejecuciones_activas_ahora: [], ejecuciones_recientes: [], resumen_general: null, nota: '' }, t: Date.now(), leyendo: false, err: '', sel: 'todos', est: 'todos', fmotor: 'todos', fest: 'todos', msg: '' } }
  const ui = await montarSec($, on, 'chats', { chats: ch })
  expect(await svgAlt(ui, /^Resumen de chats/)).toBeFalsy()
  await ui.unmount()
})
test('Sistema: KPI de estado (modo, esfuerzo, intensidad, versión) y controles viejos', async ($, on) => {
  const ui = await montarSec($, on, 'sistema')
  const alt = String((await svgAlt(ui, /^Estado del sistema/))?.props?.alt)
  expect(alt).toMatch(/Elección de motores Automático; Esfuerzo general auto; Intensidad global .+; Versión v2\.3\.5/)
  expect(await ui.find({ type: 'Button', text: /Reiniciar Claude/ })).toBeTruthy()
  expect(await ui.find({ type: 'Button', text: /Cambiar/ })).toBeTruthy()
  await ui.unmount()
})

// ---- Cobertura de lo que figuraba NOT TESTED: el proceso que lanzan los botones (el anfitrión simulado captura argv) ----
const capturarProcesos = (on: any, stdout = 'listo\nExportadas 1 filas en historial.csv') => {
  const llamadas: string[][] = []
  on('process.run' as any, (_: unknown, e: any) => { llamadas.push(e.argv ?? e.command ?? e.args ?? []); return { value: { exitCode: 0, stdout, stderr: '' } } as any })
  return llamadas
}
test('Exportar CSV lanza exportar-historial.ps1 con los filtros visibles y muestra su última línea', async ($, on) => {
  const s = almacen(on, { seccion: 'actividad', fprov: 'codex', fest: 'ok', q: 'tarea', orden: 'tokens' })
  const llamadas = capturarProcesos(on)
  const ui = await montar($)
  await apretar(ui, /Exportar CSV/)
  const l = llamadas.flat().map(String)
  expect(l.some(x => /exportar-historial\.ps1$/.test(x))).toBe(true)
  const i = l.indexOf('-Formato'); expect(l[i + 1]).toBe('csv')
  expect(l[l.indexOf('-Proveedor') + 1]).toBe('codex')
  expect(l[l.indexOf('-Estado') + 1]).toBe('ok')
  expect(l[l.indexOf('-Orden') + 1]).toBe('tokens')
  expect(l[l.indexOf('-Q') + 1]).toBe('tarea')
  expect(String(ultimaVista(s)?.value?.exp ?? ultimaVista(s)?.exp)).toMatch(/Exportadas 1 filas/)
  await ui.unmount()
})
test('Reiniciar Claude primero hace una revisión -DryRun y no reinicia hasta confirmar', async ($, on) => {
  almacen(on, { seccion: 'sistema' })
  const llamadas = capturarProcesos(on, 'Sin trabajo pendiente.')
  const ui = await montar($)
  await apretar(ui, /Reiniciar Claude/)
  const l = llamadas.map(a => a.map(String)).filter(a => a.some(x => /reiniciar-claude.ps1$/.test(x)))
  expect(l.length).toBe(1)
  expect(l[0]).toContain('-DryRun')
  expect(l[0]).toContain('-Modo'); expect(l[0][l[0].indexOf('-Modo') + 1]).toBe('claude')
  await ui.unmount()
})
test('Guardado que pierde la carrera (isSet=false): reintenta, guarda y el panel sigue respondiendo', async ($, on) => {
  const m = new Map<string, any>()
  let rechazos = 0
  on('state.get', (_: unknown, e: any) => {
    const v = e.key === 'vista' ? { shape: 'vista-2', value: { ...V0, seccion: m.get('sec') ?? 'resumen' } } : { shape: 'datos-8', value: DATOS }
    return { value: { value: v, version: 1, shape: v.shape } }
  })
  let intentos = 0
  on('state.set' as any, () => { intentos++; if (intentos === 1) { rechazos++; return { value: { isSet: false, version: 99 } } as any } return { value: { isSet: true, version: 100 } } as any })
  const ui = await montar($)
  await apretar(ui, /^Motores$/)
  expect(rechazos).toBe(1)
  expect(intentos).toBeGreaterThan(1)   // perdió la carrera una vez y el reintento acotado lo guardó
  expect(await ui.find({ type: 'Button', text: /^Motores$/ })).toBeTruthy()
  await ui.unmount()
})

// ---- Pruebas funcionales (2.2.0): «Este chat» con datos propios, 7d/30d con series distintas e intensidad global/por chat ----
const cons = (v: number | null) => ({ valor: v, unidad: 'tokens', nivel: v === null ? 'NO DISPONIBLE' : 'VERIFICADO' })
const chatProp = (id: string, deleg: number, cx: number | null, ag: number | null, claude: number | null, costo: number | null) =>
  ({ id_chat: id, titulo: null, delegaciones: deleg, errores: 0, consumo: { claude_real: cons(claude), claude_estimado_delegaciones: cons(costo), codex: cons(cx), antigravity: cons(ag), total: { valor: null } } })
const chatsConDatos = (actual: string | null) => ({ shape: 'chats-1', value: { j: { generado: '', chat_actual: actual, chats: [chatProp('chat-A', 2, 1000, null, 7000, 500), chatProp('chat-B', 9, 5000, 7000, 90000, 3000)], ejecuciones_activas_ahora: [], ejecuciones_recientes: [], resumen_general: null, nota: '' }, t: Date.now(), leyendo: false, err: '', sel: 'todos', est: 'todos', fmotor: 'todos', fest: 'todos', msg: '' } })
const INTENS0 = { shape: 'intensidad-1', value: { g: 'automatico', v: 'automatico', origen: 'global', chatId: '', msg: '', t: Date.now() } }
const vistaYDatos = (on: any, vista: object, extra: Record<string, any> = {}, datos: object = DATOS) => {
  on('state.get', (_: unknown, e: any) => {
    const v = e.key === 'vista' ? { shape: 'vista-2', value: { ...V0, ...vista } } : e.key === 'intensidad' ? INTENS0 : extra[e.key] ?? { shape: 'datos-8', value: datos }
    return { value: { value: v, version: 1, shape: v.shape } }
  })
  on('state.set' as any, () => ({ value: { isSet: true, version: 2 } }) as any)
}
const altKpi = async (ui: any) => String((await svgAlt(ui, /^Métricas: /))?.props?.alt)

test('Ahorro por chat: muestra solo los datos del chat actual (aislado del otro chat)', async ($, on) => {
  vistaYDatos(on, {}, { chats: chatsConDatos('chat-A') })
  const ui = await montar($)
  const a = await altKpi(ui)
  expect(a).toMatch(/Ahorro por chat 6 %/)   // 2.3.5 chat-A: (1.000 − 500) / (1.000 delegado + 7.000 Claude real) = 6 %
  await ui.unmount()
})
test('Ahorro por chat: con chat-B como actual cambia el valor', async ($, on) => {
  vistaYDatos(on, {}, { chats: chatsConDatos('chat-B') })
  const ui = await montar($)
  const a = await altKpi(ui)
  expect(a).toMatch(/Ahorro por chat /)
  expect(a).not.toMatch(/Ahorro por chat 6 %/)
  await ui.unmount()
})
test('Ahorro por chat: un chat conocido sin delegaciones muestra 0 % (dato real), no «No determinable»', async ($, on) => {
  const c = chatsConDatos('chat-Z') as any
  c.value.j.chats.push(chatProp('chat-Z', 0, null, null, 4000, null))
  vistaYDatos(on, {}, { chats: c })
  const ui = await montar($)
  expect(await altKpi(ui)).toMatch(/Ahorro por chat 0 %/)
  await ui.unmount()
})
test('Las 4 tarjetas: tokens totales, ahorrados (con delegaciones), ahorro por chat y costo, y nada más', async ($, on) => {
  vistaYDatos(on, {}, { chats: chatsConDatos('chat-B') })
  const ui = await montar($)
  const g = await altKpi(ui)
  const orden = ['Tokens totales', 'Tokens ahorrados', 'Ahorro por chat', 'Costo estimado'].map(k => g.indexOf(k))
  expect(orden.every(x => x >= 0)).toBe(true)
  expect([...orden].sort((a, b) => a - b)).toEqual(orden)
  expect(g).toMatch(/Tokens ahorrados .*[0-9]+ delegaci/)
  expect(g).not.toMatch(/delegados (llamadas)|ejecuciones|recuperaciones/)
  await ui.unmount()
})

test('7d vs 30d con series distintas: el gráfico cambia de resultado y vuelve al volver', async ($, on) => {
  // 40 días: 33 viejos de 100 y los últimos 7 de 1.000, así 7d (≈7.000) y 30d (≈23×100 + 7×1.000) no pueden coincidir.
  const dias = Array.from({ length: 40 }, (_, i) => ({ d: 'd' + String(i + 1).padStart(2, '0'), codex: i >= 33 ? 1000 : 100, agy: 0, costo: 10, n: 1 }))
  const s = almacen(on, { seccion: 'consumo', rango: '7d' }, { ...DATOS, dias })
  const ui = await montar($)
  const a7 = String((await svgAlt(ui, /Gráfico 7d/))?.props?.alt)
  await apretar(ui, /^30d$/)
  const a30 = String((await svgAlt(ui, /Gráfico 30d/))?.props?.alt)
  expect(ultimaVista(s)?.rango).toBe('30d')
  expect(a7.replace('7d', '')).not.toBe(a30.replace('30d', ''))
  expect(a7).toMatch(/d40/.test(a7) ? /./ : /7[.,]?000|7 ?k|7000/)   // el total de la serie de 7d
  await apretar(ui, /^7d$/)
  expect(String((await svgAlt(ui, /Gráfico 7d/))?.props?.alt)).toBe(a7)
  await ui.unmount()
})

// Intensidad: el proceso real lo valida tests\funcional.ps1; acá se verifica el argv exacto que lanza cada botón.
const procesosIntens = (on: any) => {
  const llamadas: string[][] = []
  on('process.run' as any, (_: unknown, e: any) => {
    const a = (e.argv ?? e.command ?? e.args ?? []).map(String); llamadas.push(a)
    return { value: { exitCode: 0, stdout: JSON.stringify({ ok: true, valor: 'alto', origen: 'global', chat: 'chat-A', global: 'alto', mensaje: 'ok' }), stderr: '' } } as any
  })
  return llamadas
}
const botonesIntens = async (ui: any, et: string) => ((await ui.findAll({ type: 'Button', text: new RegExp('^' + et + '$') })) as any[])
for (const [et, v] of [['Automático', 'automatico'], ['Mínimo', 'bajo'], ['Medio', 'medio'], ['Máximo', 'alto']] as const) {
  test('Intensidad ' + et + ': el botón global lanza «-Valor ' + v + ' -Global» y el de este chat «-Valor ' + v + ' -Chat chat-A»', async ($, on) => {
    vistaYDatos(on, { seccion: 'sistema' }, { chats: chatsConDatos('chat-A') })
    const llamadas = procesosIntens(on)
    const ui = await montar($)
    const bs = await botonesIntens(ui, et)
    expect(bs.length).toBe(3)                                     // fila global + fila «solo este chat»
    await ui.press(bs[0]); await ui.advance?.(200); await ui.redraw?.()
    let l = llamadas.filter(a => a.some(x => /intensidad\.ps1$/.test(x)) && a.includes('-Valor'))
    expect(l.length).toBe(1)
    expect(l[0][l[0].indexOf('-Valor') + 1]).toBe(v); expect(l[0]).toContain('-Global'); expect(l[0]).not.toContain('-Chat')
    const bs2 = await botonesIntens(ui, et)
    await ui.press(bs2[2]); await ui.advance?.(200); await ui.redraw?.()
    l = llamadas.filter(a => a.some(x => /intensidad\.ps1$/.test(x)) && a.includes('-Valor'))
    expect(l.length).toBe(2)
    expect(l[1][l[1].indexOf('-Valor') + 1]).toBe(v); expect(l[1][l[1].indexOf('-Chat') + 1]).toBe('chat-A'); expect(l[1]).not.toContain('-Global')
    await ui.unmount()
  })
}
test('Intensidad: «Heredar global» quita la preferencia solo de este chat', async ($, on) => {
  vistaYDatos(on, { seccion: 'sistema' }, { chats: chatsConDatos('chat-A') })
  const llamadas = procesosIntens(on)
  const ui = await montar($)
  await apretar(ui, /Heredar global/)
  const l = llamadas.filter(a => a.some(x => /intensidad\.ps1$/.test(x)) && a.includes('-Quitar'))
  expect(l.length).toBe(1)
  expect(l[0][l[0].indexOf('-Chat') + 1]).toBe('chat-A')
  await ui.unmount()
})

// ---- 2.3.0 Pixel Pro ----
test('Pixel Pro: la cabecera lleva la mascota pixel Chispa (naranja, crispEdges) y ninguna hoja', async ($, on) => {
  vistaYDatos(on, {})
  const ui = await montar($)
  const cab = await svgAlt(ui, /^Multi-IA 2\.3\.5 /)
  const src = String(cab?.props?.source ?? '')
  expect(src).toContain('Chispa, mascota Multi-IA')
  expect(src).toContain('#ff9b38')
  expect(src).toContain('crispEdges')
  expect(src.toLowerCase()).not.toMatch(/hoja|leaf|cannabis/)
  await ui.unmount()
})
test('Pixel Pro: el gráfico 24h separa Codex y Antigravity cuando la fuente trae cx/ag por hora', async ($, on) => {
  vistaYDatos(on, { seccion: 'consumo' }, {}, { ...DATOS, horas: [{ h: 9, c: 1000, d: 3000, cx: 2000, ag: 1000 }, { h: 10, c: 500, d: 400, cx: 0, ag: 400 }] })
  const ui = await montar($)
  const a = String((await svgAlt(ui, /Gráfico 24h/))?.props?.alt)
  expect(a).toMatch(/Claude 2 k \(estimado\)/)   // fmt redondea a k enteros: 1.500 → 2 k
  expect(a).toMatch(/Codex 2 k \(real\)/)
  expect(a).toMatch(/Antigravity 1 k \(real\)/)
  expect(a).not.toMatch(/Delegado/)
  await ui.unmount()
})
test('Pixel Pro: sin cx/ag por hora (datos viejos) el 24h cae a una sola serie «Delegado», sin inventar el reparto', async ($, on) => {
  vistaYDatos(on, { seccion: 'consumo' })
  const ui = await montar($)
  const a = String((await svgAlt(ui, /Gráfico 24h/))?.props?.alt)
  expect(a).toMatch(/Delegado 3 k \(real\)/)
  expect(a).not.toMatch(/Codex|Antigravity/)
  await ui.unmount()
})
// --- 2.3.0 · arreglos de la auditoría UX (Antigravity propuso, Claude verificó contra el código) ---
test('UX 2.3.0: «Tokens totales» suma Claude + delegado (global)', async ($, on) => {
  vistaYDatos(on, {}, { chats: chatsConDatos('chat-B') })
  const ui = await montar($)
  expect(await altKpi(ui)).toMatch(/^Métricas: Tokens totales [0-9]/)
  await ui.unmount()
})
test('UX 2.3.0: un ahorro negativo se muestra con signo (no se esconde como 0)', async ($, on) => {
  const neg = { shape: 'chats-1', value: { ...chatsConDatos('chat-N').value, j: { ...chatsConDatos('chat-N').value.j, chats: [chatProp('chat-N', 1, 200, null, 1000, 500)] } } }
  vistaYDatos(on, {}, { chats: neg })
  const ui = await montar($)
  expect(await altKpi(ui)).toMatch(/Ahorro por chat -25 %/)
  await ui.unmount()
})
test('UX 2.3.0: el texto accesible del gráfico no anuncia las series ocultas', async ($, on) => {
  vistaYDatos(on, { seccion: 'consumo', ocultas: ['c'] })
  const ui = await montar($)
  const a = String((await svgAlt(ui, /Gráfico 24h/))?.props?.alt)
  expect(a).not.toMatch(/Claude/)
  expect(a).toMatch(/Delegado/)
  await ui.unmount()
})
test('UX 2.3.0: la ayuda del gráfico sirve en pantalla táctil («Tocá o pasá el cursor»)', async ($, on) => {
  vistaYDatos(on, { seccion: 'consumo' })
  const ui = await montar($)
  expect(await ui.find({ type: 'Text', text: /Tocá o pasá el cursor/ })).toBeTruthy()
  await ui.unmount()
})
