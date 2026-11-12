import { expect, test } from 'claude-code/testing'
const V2 = { rango: '24h', seccion: 'resumen', ocultas: [], plegadas: [], q: '', cp: 0, filtro: 'todo', fprov: 'todo', fest: 'todo', forig: 'prod', orden: 'nuevo', sel: '', exp: '' }
const SECS = ['resumen', 'motores', 'actividad', 'consumo', 'sistema']
for (const [nombre, cols, surface] of [['compacto-40', 40, 'dock'], ['compacto-60', 60, 'dock'], ['centro-120', 120, 'desktop']] as const) {
  for (const s of SECS) test(`volcado de render ${nombre} ${s}`, async ($, on) => {
    let sec = s // un montaje por prueba: con 5 seguidos pasaban de 5 s con la maquina cargada (intermitente)
    on('state.get', (_, e) => e.key === 'vista' ? { value: { value: { shape: 'vista-2', value: { ...V2, seccion: sec } }, version: 1, shape: 'vista-2' } } : ({ value: { value: { shape: 'datos-8', value: { modo: 'auto', calidad: 'auto', manual: {}, horas: [], deleg_total: 0, deleg_n: 0, eventos: [], claude_costo: 0, ses_deleg: 0, ses_n: 0, ses_costo: 0, tarjetas: [] } }, version: 1, shape: 'datos-8' } }))
    {
      const ui = await $.ui.mount({ plugin: 'multi-ia-orquestador', component: 'Pane', requestId: 'multi-ia-panel', surface: 'desktop', props: { title: 'Multi-IA', isFocused: false, bodyColumns: cols, placement: surface === 'dock' ? 'dock' : 'center', scroll: { offset: 0, bodyRows: 30 }, view: {} } } as any)
      const t = await ui.findAll({ type: 'Text' }) as any[]
      console.log(`DUMP ${nombre} ${s}: ` + JSON.stringify(t.map(x => x.text)))
      await ui.unmount()
    }
    expect(true).toBe(true)
  })
}
