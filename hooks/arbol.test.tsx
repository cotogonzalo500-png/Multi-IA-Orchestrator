import { expect, test } from 'claude-code/testing'
const V2 = { rango: '24h', seccion: 'resumen', ocultas: [], plegadas: [], q: '', cp: 0, filtro: 'todo', fprov: 'todo', fest: 'todo', forig: 'prod', orden: 'nuevo', sel: '', exp: '', alc: 'chat' }
const ahora = new Date()
const iso = (m: number) => new Date(ahora.getTime() - m * 60000).toISOString()
const eventos = [
  { f: iso(26), t: 'inicio', d: 'codex', x: 'gpt-5.5', m: 'Pruebas de panel', k: 'codigo', tok: 0, s: 0, i: 'ej-c1' },
  { f: iso(25), t: 'error', d: 'codex', x: 'gpt-5.5', m: '', k: 'codigo', tok: 2100, s: 12, i: 'ej-c1' },
  { f: iso(12), t: 'inicio', d: 'agy', x: 'gemini-3-pro', m: 'Resumen de auditoría', k: 'texto', tok: 0, s: 0, i: 'ej-a2' },
  { f: iso(11), t: 'fin', d: 'agy', x: 'gemini-3-pro', m: '', k: 'texto', tok: 9200, s: 28, i: 'ej-a2' },
  { f: iso(4), t: 'inicio', d: 'codex', x: 'gpt-5.5', m: 'Revisión de register.tsx', k: 'codigo', tok: 0, s: 0, i: 'ej-c3' },
  { f: iso(3), t: 'fin', d: 'codex', x: 'gpt-5.5', m: '', k: 'codigo', tok: 18400, s: 42, i: 'ej-c3' },
]
const horas = Array.from({ length: 24 }, (_, i) => ({ h: i, c: 8000 + ((i * 3731) % 9000), d: (i % 3) * 5000 + ((i * 1237) % 4000) }))
const datos = { modo: 'auto', calidad: 'auto', manual: { codex: { modelo: 'gpt-5.5', esfuerzo: 'medium' }, agy: { modelo: 'gemini-3-pro' } }, horas, deleg_total: 148000, deleg_n: 17, claude_costo: 21000, ses_deleg: 38000, ses_n: 4, ses_costo: 6000, eventos,
  glob: { ses: 31, tin: 1200000, tout: 210000, hoy: 148000, semana: 520000, mes: 1900000, codex: 72, agy: 28, errores: 2, sin_dato: 1 }, presup: { tope: 500000, hoy: 148000, aviso: 80, cache: 1, arena: 'ok' }, activas: 0, max: 2,
  tarjetas: [
    { nombre: 'Claude', ventanas: [{ v: '5 h', usado: 42, reinicia: 'en 2 h 10 m' }, { v: 'Semanal', usado: 63, reinicia: 'en 3 d' }] },
    { nombre: 'Codex', ventanas: [{ v: '5 h', usado: 18, reinicia: 'en 4 h' }, { v: 'Semanal', usado: 35, reinicia: 'en 5 d' }] },
    { nombre: 'Antigravity', ventanas: [{ v: '5 h', usado: 71, reinicia: 'en 1 h' }, { v: 'Semanal', usado: 22, reinicia: 'en 6 d' }] },
  ] }
const sh = (shape: string, value: unknown) => ({ value: { value: { shape, value }, version: 1, shape } })
const casos: [string, number, string][] = [['c320', 36, 'dock'], ['c360', 40, 'dock'], ['c390', 44, 'dock'], ['c416', 46, 'dock'], ['c480', 54, 'dock'], ['centro', 140, 'desktop']]
const SECS = ['resumen', 'motores', 'actividad', 'consumo', 'chats', 'sistema']
// Texto propio de cada sección: 'Multi-IA' sale del título y pasaba aunque el cuerpo no dibujara nada (auditoría Codex #8).
const MARCA: Record<string, string> = { resumen: 'Más métricas', motores: 'SESIÓN 5 H', actividad: 'Historial ·', consumo: 'Consumo y ahorro', chats: 'Exportar MD', sistema: 'Reiniciar Claude' }
// Precalentamiento: el primer montaje paga la carga en frío (~2 s) y dejaba a c320 al borde de los 5 s.
// Verifica algo real (la cabecera con versión) para no ser un test vacío.
test('arbol precalentamiento', async ($, on) => {
  on('state.get', (_: any, e: any) => e.key === 'vista' ? sh('vista-2', V2) : sh('datos-8', datos))
  const ui = await $.ui.mount({ plugin: 'multi-ia-orquestador', component: 'Pane', requestId: 'multi-ia-panel', surface: 'desktop', props: { title: 'Multi-IA', isFocused: false, bodyColumns: 46, placement: 'dock' } } as any) as any
  const all = await ui.findAll({}) as any[]
  expect(JSON.stringify(all[0])).toContain('Multi-IA')
  await ui.unmount()
})
// Un test por ancho × sección (1 montaje cada uno): con 6 montajes por test, c320 quedaba entre 3,4 y 5,3 s con el límite en 5 s.
for (const [nombre, cols, place] of casos) for (const s of SECS) test('arbol ' + nombre + '-' + s, async ($, on) => {
  on('state.get', (_: any, e: any) => e.key === 'vista' ? sh('vista-2', { ...V2, seccion: s }) : sh('datos-8', datos))
  const ui = await $.ui.mount({ plugin: 'multi-ia-orquestador', component: 'Pane', requestId: place === 'desktop' ? 'multi-ia-centro' : 'multi-ia-panel', surface: 'desktop', props: { title: 'Multi-IA', isFocused: false, bodyColumns: cols, placement: place } } as any) as any
  const all = await ui.findAll({}) as any[]
  console.log('TREE	' + nombre + '-' + s + '	' + JSON.stringify(all[0]))
  expect(JSON.stringify(all[0])).toContain(MARCA[s])
  await ui.unmount()
})
