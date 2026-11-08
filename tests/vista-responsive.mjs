// Vista de prueba responsive (NO es el panel real de Claude Desktop): renderiza los constructores SVG reales de hooks/register.tsx
// con datos de muestra en contenedores de 320/360/390/416/480 px. Uso: node tests/vista-responsive.mjs [salida.html]
// Requiere Node >= 22 (--experimental-strip-types). Luego abrir el HTML en un navegador y medir desbordes.
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'
const aqui = dirname(fileURLToPath(import.meta.url))
const src = readFileSync(join(aqui, '..', 'hooks', 'register.tsx'), 'utf8').split(/\r?\n/)
const ini = src.findIndex(l => l.startsWith('const FONDO')) - 1, fin = src.findIndex(l => l.startsWith('const PRESION'))
const tipos = src.filter(l => /^type (Ventana|Tarjeta|Hora|Evento|Ejec) /.test(l))
const cuerpo = src.slice(ini, fin).filter(l => !l.startsWith('const vistaA') && !l.startsWith("  { rango: '24h'"))
const dir = mkdtempSync(join(tmpdir(), 'vista-'))
writeFileSync(join(dir, 'lib.ts'), tipos.concat(cuerpo).join('\n') + '\nexport { T, svgCabecera, svgKpis, hKpis, svgMotor, svgTablaMotores, svgGrafico, svgTitulo, svgIcono, svgBarrasH, svgTarjetaReactor, svgBarraCupo, svgTerminal }\n')
const salida = process.argv[2] || join(aqui, '..', 'evidencias', 'v2.3.0', 'vista-responsive.html')
writeFileSync(join(dir, 'gen.ts'), `import * as L from './lib.ts'
import { writeFileSync } from 'node:fs'
const W = 416
const kp = [{v:'12',r:'tokens totales',c:L.T.violeta},{v:'≈ 1,2 M',r:'ahorro estimado',c:L.T.okSuave,d:'tokens ahorrados · delegado − coordinación'},{v:'62 %',r:'ahorro por chat',c:L.T.ahorro,d:'ahorro ÷ trabajo delegado (estimado)'},{v:'300',r:'costo estimado',c:L.T.ambar,d:'coordinar a Claude'}]
const ser = [{k:'a',l:'Delegado',c:'#22d3ee',t:'real' as const,v:[1,3,2,5,4,0,2,6]},{k:'b',l:'Claude est.',c:'#fb7185',t:'estimado' as const,v:[2,4,3,6,5,1,3,7]}]
const partes: [string,string][] = [
 ['cabecera', L.svgCabecera(W,true,false)],
 ['cabecera-apagado', L.svgCabecera(W,false,false)],
 ['cabecera-sin-senal', L.svgCabecera(W,true,true)],
 ['reactor', L.svgTarjetaReactor(W,'Ejecutando','#fbbf24',true,true,['Codex'],5,'Automático · intensidad equilibrada')],
 ['iconos', ['resumen','motores','actividad','consumo','chats','sistema'].map((s,i)=>L.svgIcono(Math.floor((W-16)/3),s,i===0)).join('')],
 ['kpis', L.svgKpis(W,2,kp)],
 ['motor', L.svgMotor(W,'Antigravity',true,'gemini-3','#a78bfa',[{r:'5 h',u:35,nota:'renueva 5:00 p. m.'},{r:'7 d',u:null,nota:'sin dato'}])],
 ['tablaMotores', L.svgTablaMotores(W,[{nombre:'Codex',ok:true,color:'#22d3ee',u5:35,u7:62},{nombre:'Antigravity',ok:false,color:'#a78bfa',u5:null,u7:null}])],
 ['grafico', L.svgGrafico(['1h','2h','3h','4h','5h','6h','7h','8h'],ser,[],W,150,n=>String(n))],
 ['titulo', L.svgTitulo(W,'⚙','Sistema','#ba75f5','v2.3.0')],
 ['barrasH', L.svgBarrasH(W,[{l:'Codex',txt:'40%',p:40,c:'#22d3ee',sub:'x'},{l:'Antigravity',txt:'80%',p:80,c:'#a78bfa'}])],
 ['cupo', L.svgBarraCupo(W,60,'#fbbf24')],
 ['terminal', L.svgTerminal(W,'Historial',[{hora:'10:02',c:'#22d3ee',a:'Codex · código',tag:'ok',b:'detalle'}],[],3,'vacío')],
]
const html = '<!doctype html><meta charset=utf-8><body style="margin:0;background:#0d0914;color:#fff;font:12px system-ui"><p style="margin:8px">Vista de prueba: SVG reales de register.tsx con datos de muestra. NO es el panel de Claude Desktop.</p>' + [320,360,390,416,480].map(a=>'<h3 style="margin:8px">'+a+'px</h3><div class=c style="width:'+(a-24)+'px;margin:0 12px;border:1px dashed #555">'+partes.map(([n,s])=>'<div data-n="'+n+'">'+s+'</div>').join('')+'</div>').join('')
writeFileSync(process.argv[2], html)
`)
const r = spawnSync(process.execPath, ['--experimental-strip-types', join(dir, 'gen.ts'), salida], { encoding: 'utf8' })
if (r.status !== 0) { console.error(r.stderr); process.exit(1) }
console.log('ok ' + salida)
