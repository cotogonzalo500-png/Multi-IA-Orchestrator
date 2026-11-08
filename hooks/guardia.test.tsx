import { expect, test } from 'claude-code/testing'

// Guardia previa de delegación (hook tool.call de Bash en register.tsx):
// frena una delegación CHICA de delegar.ps1, pero NO debe frenar un comando que solo LEE el script (soloLee),
// ni una delegación con archivo/-Forzar, ni actuar con el plugin apagado o con el cupo de Claude apretado.
const DATOS = (extra: object = {}) => ({ modo: 'automatico', calidad: 'equilibrada', tarjetas: [], eventos: [], ...extra })
const sembrar = (on: any, datos: object) => {
  on('state.get', (_: unknown, e: any) => ({ value: { value: { shape: e.key === 'vista' ? 'vista-2' : 'datos-8', value: datos }, version: 1, shape: e.key === 'vista' ? 'vista-2' : 'datos-8' } }))
  const corridas: any[] = []
  on('process.run' as any, (_: unknown, e: any) => { corridas.push(e.argv ?? []); return { value: { exitCode: 0, stdout: '', stderr: '' } } as any })
  return corridas
}
const llamar = async ($: any, command: string) => {
  try { return { r: await $.tool.call({ tool: 'Bash', command } as any), err: null as any } }
  catch (err) { return { r: null as any, err } }
}
const negado = (x: { r: any; err: any }) => /delegación es chica/i.test(JSON.stringify(x.r ?? '') + String(x.err?.message ?? x.err ?? ''))

test('guardia: frena la delegación chica y anota el motivo con decidir.ps1', async ($, on) => {
  const corridas = sembrar(on, DATOS())
  const x = await llamar($, 'powershell -File scripts/delegar.ps1 -Tarea "hola"')
  expect(negado(x)).toBe(true)
  expect(corridas.some(a => a.some((s: string) => /decidir\.ps1/i.test(String(s))))).toBe(true)
})

test('guardia soloLee: leer delegar.ps1 (cat/grep/sed/Get-Content/…) NO se frena', async ($, on) => {
  sembrar(on, DATOS())
  for (const c of [
    'cat scripts/delegar.ps1',
    'grep -n Forzar scripts/delegar.ps1',
    'sed -n 1,40p scripts/delegar.ps1',
    'head -20 scripts/delegar.ps1',
    '  tail scripts/delegar.ps1',
    'wc -l scripts/delegar.ps1',
    'rg Tamano scripts/delegar.ps1',
    'Get-Content scripts\\delegar.ps1',
    'Select-String -Path scripts\\delegar.ps1 -Pattern x',
  ]) expect([c, negado(await llamar($, c))]).toEqual([c, false])
})

test('guardia soloLee: solo cuenta si el comando EMPIEZA leyendo (un cat en el medio no exime)', async ($, on) => {
  sembrar(on, DATOS())
  expect(negado(await llamar($, 'powershell -File delegar.ps1 -Tarea "cat"'))).toBe(true)
  expect(negado(await llamar($, 'echo x; powershell -File delegar.ps1 -Tarea y'))).toBe(true)
})

test('guardia: con -Archivo, -Forzar o pedido largo (>= 450) no frena', async ($, on) => {
  sembrar(on, DATOS())
  expect(negado(await llamar($, 'powershell -File delegar.ps1 -Tarea x -Archivo a.ps1'))).toBe(false)
  expect(negado(await llamar($, 'powershell -File delegar.ps1 -Tarea x -Forzar'))).toBe(false)
  expect(negado(await llamar($, 'powershell -File delegar.ps1 -Tarea "' + 'x'.repeat(460) + '"'))).toBe(false)
})

test('guardia: plugin apagado no interviene', async ($, on) => {
  sembrar(on, DATOS({ activo: false }))
  expect(negado(await llamar($, 'powershell -File delegar.ps1 -Tarea x'))).toBe(false)
})

test('guardia: cupo de Claude apretado (>= 75 %) deja delegar aunque sea chica', async ($, on) => {
  sembrar(on, DATOS({ tarjetas: [{ nombre: 'Claude', ventanas: [{ v: '5 h', usado: 80 }] }] }))
  expect(negado(await llamar($, 'powershell -File delegar.ps1 -Tarea x'))).toBe(false)
})
