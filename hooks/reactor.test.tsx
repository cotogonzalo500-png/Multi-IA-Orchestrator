import { expect, test } from 'claude-code/testing'

// Regresión V3: la secuencia real del reactor, con el evento `prompt.submit` emitido por el motor de pruebas ($.prompt.submit),
// que recorre la misma cadena de hooks que un pedido real del usuario (el hook del plugin arma el turno "Analizando").
const PANE = {
  plugin: 'multi-ia-orquestador', component: 'Pane', requestId: 'multi-ia-panel',
  props: { title: 'Multi-IA', isFocused: false, bodyColumns: 40, placement: 'dock', scroll: { offset: 0, bodyRows: 20 }, view: {} },
} as const
const V2 = { rango: '24h', seccion: 'resumen', ocultas: [], plegadas: [], q: '', cp: 0, filtro: 'todo', fprov: 'todo', fest: 'todo', forig: 'prod', orden: 'nuevo', sel: '', exp: '' }

test('reactor: Disponible → Analizando → Seleccionando → Delegando → Ejecutando → Completado', async ($, on) => {
  let eventos: any[] = []
  on('prompt.submit', (_, e) => ({ text: e.text }))
  on('state.get', (_, e) => e.key === 'vista'
    ? { value: { value: { shape: 'vista-2', value: V2 }, version: 1, shape: 'vista-2' } }
    : { value: { value: { shape: 'datos-8', value: { modo: 'automatico', calidad: 'equilibrada', tarjetas: [], eventos } }, version: 1, shape: 'datos-8' } })

  const reactor = async () => {
    const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
    const r: any = ((await ui.findAll({ type: 'Svg' })) as any[]).find(n => /^Reactor: /.test(String(n.props?.alt ?? '')))
    await ui.unmount()
    return String(r?.props?.alt ?? '')
  }
  const ev = (t: string, extra: object = {}) => ({ f: new Date().toISOString(), t, d: 'codex', x: 'gpt-6.1-sol', m: '', k: 'codigo', tok: 0, s: 0, i: 'ej-test-1', ...extra })

  // 1. Sin pedidos ni ejecuciones
  expect(await reactor()).toContain('Disponible')

  // 2. Llega un pedido del usuario: el hook prompt.submit del plugin marca el turno → Analizando
  await $.prompt.submit({ text: 'revisá este código y arreglá las fallas del archivo principal' } as any)
  expect(await reactor()).toContain('Analizando')

  // 3. El router eligió motor (evento seleccionado, todavía sin lanzar)
  eventos = [ev('seleccionado')]
  expect(await reactor()).toContain('Seleccionando')

  // 4. Claude llama a delegar.ps1 (el hook tool.call cierra el turno de "Analizando") y se lanza; la CLI aún no confirmó
  await $.tool.call({ tool: 'Bash', command: 'powershell -File delegar.ps1 -Tarea x -Archivo a' } as any).catch(() => {})
  eventos = [ev('seleccionado'), ev('inicio')]
  expect(await reactor()).toContain('Delegando')

  // 5. La CLI confirmó
  eventos = [ev('seleccionado'), ev('inicio'), ev('confirmado')]
  expect(await reactor()).toContain('Ejecutando')

  // 6. Terminó bien
  eventos = [ev('seleccionado'), ev('inicio'), ev('confirmado'), ev('recibido'), ev('fin', { tok: 1200, s: 30 })]
  expect(await reactor()).toContain('Completado, sin verificar')   // 2.3.0

  // 7. Y un error posterior se ve como Error
  eventos = [ev('inicio', { i: 'ej-test-2' }), ev('error', { i: 'ej-test-2' })]
  expect(await reactor()).toContain('Error')
})

test('reactor: un pedido vacío o un comando no dispara Analizando', async ($, on) => {
  on('prompt.submit', (_, e) => ({ text: e.text }))
  on('state.get', (_, e) => e.key === 'vista'
    ? { value: { value: { shape: 'vista-2', value: V2 }, version: 1, shape: 'vista-2' } }
    : { value: { value: { shape: 'datos-8', value: { modo: 'automatico', calidad: 'equilibrada', tarjetas: [], eventos: [] } }, version: 1, shape: 'datos-8' } })
  // Un turno anterior (del test previo) puede seguir vivo hasta 20 s: se cierra con un pedido que ya delegó (tool.call de delegar.ps1)
  await $.tool.call({ tool: 'Bash', command: 'powershell -File delegar.ps1 -Tarea x -Archivo a' } as any).catch(() => {})
  await $.prompt.submit({ text: '   ' } as any)
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  const r: any = ((await ui.findAll({ type: 'Svg' })) as any[]).find(n => /^Reactor: /.test(String(n.props?.alt ?? '')))
  await ui.unmount()
  expect(String(r?.props?.alt ?? '')).toContain('Disponible')
})
