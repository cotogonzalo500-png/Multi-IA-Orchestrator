# Genera el panel de uso como pagina HTML local (estilo oscuro, tarjetas por cuenta) y devuelve su ruta.
# Orden: tarjetas por cuenta (5 h y semanal, "renueva ..."), CONSUMO GENERAL (todas las ventanas, la mas ajustada, promedio, tokens por hora),
# y el DETALLE de cada IA (Claude, Codex, Antigravity) con tokens exactos y delegaciones.
# Codex y Antigravity: EN VIVO. Claude: % del plan desde la linea de estado (o foto de get_usage) + tokens exactos de disco.
# Uso: .\panel.ps1 [-Salida C:\ruta\panel.html]
param(
    [string]$Salida,
    # Foto del cupo de Claude (de get_usage/get_session) en el MISMO paso: Claude llama las dos herramientas y esto, sin un paso extra para guardar la foto.
    [string]$Plan = 'Pro', [int]$CincoHoras = -1, [string]$CincoHorasReinicia, [int]$Semanal = -1, [string]$SemanalReinicia, [string]$Modelo, [string]$Esfuerzo
)
. (Join-Path $PSScriptRoot '_comun.ps1')
if ($CincoHoras -ge 0 -and $Semanal -ge 0) {
    & (Join-Path $PSScriptRoot 'claude-snapshot.ps1') -Plan $Plan -CincoHoras $CincoHoras -CincoHorasReinicia $CincoHorasReinicia -Semanal $Semanal -SemanalReinicia $SemanalReinicia -Modelo $Modelo -Esfuerzo $Esfuerzo | Out-Null
}
Initialize-Datos
if (-not $Salida) { $Salida = Join-Path $script:DatosDir 'panel.html' }
$es = [Globalization.CultureInfo]::GetCultureInfo('es-AR')
# OJO: no llamar "H" a esta funcion: H es alias de Get-History y los alias ganan a las funciones.
function Esc($t) { [Net.WebUtility]::HtmlEncode([string]$t) }
function N($n) { '{0:N0}' -f [long]$n }
function Clase($u) { if ([int]$u -ge 85) { 'alto' } elseif ([int]$u -ge 60) { 'medio' } else { 'bajo' } }
# "lun, 09:00 p. m." en hora local, a partir de un ISO en UTC.
function Cuando($iso) {
    try { [datetime]::Parse($iso, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal).ToLocalTime().ToString('ddd, hh:mm tt', $es) } catch { $iso }
}

# Barra con etiqueta y detalle (para el detalle por IA). El texto siempre dice el numero: el color no es lo unico que informa.
function Barra($etiqueta, $usado, $detalle) {
    $u = [math]::Max(0, [math]::Min(100, [int]$usado))
    "<div class='fila'><div class='et'><span>$(Esc $etiqueta)</span><b>$u% usado</b></div><div class='riel'><div class='barra $(Clase $u)' style='width:$u%'></div></div><div class='det'>$(Esc $detalle)</div></div>"
}
# Una ventana dentro de una tarjeta de cuenta: "5 h · 24%" + "renueva lun, 09:00 p. m." y la barra.
function Ventana($nombre, $usado, $iso) {
    $u = [math]::Max(0, [math]::Min(100, [int]$usado))
    "<div class='linea'><span>$(Esc $nombre) · <b>$u%</b></span><span class='ren'>$(if ($iso) { 'renueva ' + (Esc (Cuando $iso)) } else { 'sin hora de renovación' })</span></div><div class='riel'><div class='barra $(Clase $u)' style='width:$u%'></div></div>"
}

# Cada fuente se consulta UNA vez.
$cfg = Get-Config
$cfgCorrupta = [bool]$script:ConfigCorrupta   # v1.9.2: el panel avisa si config.json esta ilegible (se usan valores por defecto)
$ag = Get-CupoAgy
$cuentas = Get-Cuentas -AgyCupo $ag
$codexCupo = [ordered]@{}   # nombre de cuenta -> cupo en vivo (puede haber mas de una cuenta de Codex)
foreach ($c in (Get-CuentasActivas $cfg 'codex')) { $codexCupo[(Get-NombreCuenta $cfg $c)] = Get-CupoCodex -CodexHome $c.home }
$msgs = Get-MensajesClaude; $uso = Get-Uso
$filas = @(Get-CupoGeneral -Codex $codexCupo -Agy $ag)
$catCodex = Get-CatalogoCodex; $catAgy = Get-CatalogoAgy
$snap = if (Test-Path -LiteralPath $script:ClaudeSnapshot) { Get-Content -LiteralPath $script:ClaudeSnapshot -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
$sesion = @{}; foreach ($c in $cuentas) { $sesion[$c.ia] = $c }
# Claude: plan + modelo + esfuerzo actuales. Modelo/esfuerzo vienen de la linea de estado o de get_session; si faltan, el modelo sale del ultimo mensaje real.
$modeloClaude = if ($snap.modelo) { $snap.modelo } else { ($msgs | Sort-Object t | Select-Object -Last 1).modelo }
$infoClaude = 'plan ' + $(if ($snap) { $snap.plan } else { '?' }) + $(if ($modeloClaude) { ' · ' + $modeloClaude } else { '' }) + $(if ($snap.esfuerzo) { ' · esfuerzo ' + $snap.esfuerzo } else { '' })

# --- Tarjetas por cuenta (como en Constela)
$tarjetas = @(@{ clave = 'Claude'; nombre = 'Claude'; sub = $infoClaude; color = '#e0805a'; ses = 'Claude' })
foreach ($c in (Get-CuentasActivas $cfg 'codex')) {
    $n = Get-NombreCuenta $cfg $c; $cp = $codexCupo[$n]
    $tarjetas += @{ clave = $n; nombre = $n; sub = $(if ($cp) { 'ChatGPT ' + $cp.plan } else { 'ChatGPT' }); color = '#10a37f'; ses = $n }
}
$t = "<div class='cuentas'>"
foreach ($k in $tarjetas) {
    $f = @($filas | Where-Object { $_.ia -eq $k.clave })
    $ses = $sesion[$k.ses]
    $t += "<div class='cuenta'><div class='cab'><i class='dot' style='background:$($k.color)'></i><b>$(Esc $k.nombre)</b></div><div class='sub'>$(Esc $k.sub) · <span class='$(if ($ses.sesion) { 'ok' } else { 'no' })'>$(if ($ses.sesion) { 'sesión iniciada' } else { 'SIN SESIÓN' })</span></div>"
    foreach ($v in '5 h', 'Semanal') { $x = $f | Where-Object { $_.ventana -eq $v } | Select-Object -First 1; if ($x) { $t += Ventana $v $x.usado $x.reinicia } }
    if (-not $f) { $t += "<div class='pie'>sin dato todavía</div>" } else { $t += "<div class='pie'>$(Esc $f[0].origen)</div>" }
    $t += "</div>"
}
# Antigravity: UNA sola cuenta de Google con varios cupos independientes; una tarjeta con un bloque por cupo.
if (@(Get-CuentasActivas $cfg 'agy').Count) {
$ses = $sesion['Antigravity']
$t += "<div class='cuenta'><div class='cab'><i class='dot' style='background:#5b8def'></i><b>Antigravity</b></div><div class='sub'>Google · <span class='$(if ($ses.sesion) { 'ok' } else { 'no' })'>$(if ($ses.sesion) { 'sesión iniciada' } else { 'SIN SESIÓN' })</span></div>"
$hayAg = $false
foreach ($b in @(@('Antigravity · Gemini', 'Gemini'), @('Antigravity · Claude/GPT', 'Claude y GPT'), @('Antigravity · Gemini 4 Argon', 'Gemini 4 Argon (límite propio)'))) {
    $f = @($filas | Where-Object { $_.ia -eq $b[0] })
    if (-not $f) { continue }
    $hayAg = $true
    $t += "<div class='grupo'>$(Esc $b[1])</div>"
    foreach ($v in '5 h', 'Semanal') { $x = $f | Where-Object { $_.ventana -eq $v } | Select-Object -First 1; if ($x) { $t += Ventana $v $x.usado $x.reinicia } }
}
$t += $(if ($hayAg) { "<div class='pie'>en vivo</div>" } else { "<div class='pie'>sin dato todavía</div>" }) + "</div>"
}
$sec = @($t + "</div>")

# --- BOTON: modo de eleccion de modelos (automatico / manual) y cuentas delegadas. Funciona cuando el panel se abre con iniciar-panel.cmd (servidor local);
# abierto como archivo se ve igual pero en solo lectura.
$datosJson = ([pscustomobject]@{ config = $cfg; codex = @($catCodex); agy = @($catAgy); max = $script:MaxCuentas } | ConvertTo-Json -Depth 6 -Compress) -replace '<', '\u003c'
$avisoCorrupta = if ($cfgCorrupta) { "<p class='nota' id='config-corrupta' role='alert' style='border:2px solid #c0392b;padding:.6em;border-radius:6px'><strong>ATENCI&Oacute;N: config.json est&aacute; corrupta.</strong> Se usan los valores por defecto (autom&aacute;tico, equilibrada, sin tope). Hay una copia del original en <code>config.json.corrupta</code>. Para repararla: <code>config.ps1 -Recuperar</code>.</p>" } else { '' }
$modoHtml = @"
<section class='modo' id='modo'>$avisoCorrupta<p><button type='button' id='onoff' class='boton'></button> <small class='nota' id='onoff-desc'></small></p><h2>Elección de modelos <small>quién decide qué motor e intensidad usa cada IA</small></h2>
<div class='alterna' role='group' aria-label='Modo de elección de modelos'><button type='button' data-modo='automatico'>Automático<small>Claude elige</small></button><button type='button' data-modo='manual'>Manual<small>elegís vos</small></button></div>
<p class='nota' id='modo-desc'></p>
<div id='calidad-bloque'><h3>Calidad <small>qué tan buenos son los motores que elige Claude en modo automático</small></h3><div class='alterna' id='calidad' role='group' aria-label='Calidad de los motores'><button type='button' data-calidad='economica'>Económica<small>lo más barato</small></button><button type='button' data-calidad='equilibrada'>Equilibrada<small>uso diario</small></button><button type='button' data-calidad='maxima'>Máxima<small>proyectos críticos</small></button></div><p class='nota' id='calidad-desc'></p></div>
<div id='manual' hidden><div class='sel'><label>Codex · modelo<select id='cx-modelo'></select></label><label>Codex · esfuerzo<select id='cx-esf'></select></label><label>Antigravity · modelo<select id='ag-modelo'></select></label></div></div>
<h3>Ahorro <small>cómo cuidar tu cupo de Claude</small></h3>
<label class='chk'><input type='checkbox' id='guardia'> Guardia de contexto: me avisa (a mí y a Claude) cuando la sesión se agranda o la caché expiró, para cerrar y empezar una sesión nueva</label>
<h3>Cuentas delegadas <small id='cuentas-n'></small></h3><div id='lista-cuentas' class='cuentas-cfg'></div>
<p class='nota'>Sumar una cuenta: <code>config.ps1 -AgregarCuenta -Id codex2 -Tipo codex -Ruta C:\carpeta</code> y después iniciar sesión con su <code>CODEX_HOME</code>. Máximo 3 activas.</p>
<p><button type='button' id='actualizar' class='boton'>Actualizar panel</button> <small class='nota'>vuelve a leer los cupos de Codex y Antigravity y los tokens de Claude (el % del plan de Claude lo trae la línea de estado o Claude)</small></p>
<p class='estado' id='estado' role='status' aria-live='polite'></p><script type='application/json' id='datos'>$datosJson</script></section>
"@
$P = @{ sistema = $modoHtml; resumen = ($sec -join ''); consumo = ''; motores = '' }

# --- Consumo general
$g = "<section class='general'><h2>Consumo general <small>todas las IAs, ventana por ventana</small></h2><div class='kpis'>"
foreach ($r in Get-ResumenGeneral $filas) {
    $g += "<div class='kpi'><span class='k'>Ventana $(Esc $r.ventana)</span><b class='$(Clase $r.max)t'>$($r.max)%</b><span class='k2'>más ajustada: $(Esc $r.maxIa)</span><span class='k2'>promedio de $($r.n) fuentes: $($r.promedio)%</span></div>"
}
$g += "</div><div class='tabla'><table><thead><tr><th>IA</th><th>Ventana</th><th class='barcol'>Usado</th><th>Reinicia</th><th>Dato</th></tr></thead><tbody>"
foreach ($f in ($filas | Sort-Object @{ e = { $_.ventana -ne '5 h' } }, @{ e = 'usado'; Descending = $true })) {
    $u = [math]::Max(0, [math]::Min(100, [int]$f.usado))
    $g += "<tr><td>$(Esc $f.ia)</td><td>$(Esc $f.ventana)</td><td class='barcol'><div class='mini'><div class='barra $(Clase $u)' style='width:$u%'></div></div><b>$u%</b></td><td>$(Esc (Format-Falta $f.reinicia))</td><td>$(Esc $f.origen)</td></tr>"
}
$g += "</tbody></table></div>"
if (-not (@($filas | Where-Object { $_.ia -eq 'Claude' }))) { $g += "<p class='nota'>Falta el % de Claude: se completa solo con la línea de estado o con una foto de get_usage.</p>" }

# Tokens por hora (24 h): columnas apiladas Claude + delegados.
$hs = @(Get-TokensPorHora $msgs $uso)
$max = [math]::Max(1, ($hs | ForEach-Object { $_.claude + $_.deleg } | Measure-Object -Maximum).Maximum)
$g += "<h3>Tokens por hora <small>últimas 24 h · Claude: entrada + caché de escritura + salida · delegados: Codex y agy</small></h3><div class='horas' role='img' aria-label='Tokens por hora de las últimas 24 horas'>"
foreach ($x in $hs) {
    $hc = [math]::Round(100 * $x.claude / $max, 1); $hd = [math]::Round(100 * $x.deleg / $max, 1)
    $g += "<div class='col' title='$('{0:HH}' -f $x.hora):00 · Claude $(N $x.claude) · delegados $(N $x.deleg)'><div class='seg d' style='height:$hd%'></div><div class='seg c' style='height:$hc%'></div></div>"
}
$ejeH = { param($i) if ($hs.Count -gt $i) { '{0:HH}:00' -f $hs[$i].hora } else { '' } }
$g += "</div><div class='ejeh'><span>$(& $ejeH 0)</span><span>$(& $ejeH 8)</span><span>$(& $ejeH 16)</span><span>ahora</span></div>"
$g += "<div class='leyenda'><i class='sw c'></i>Claude: $(N (($hs | Measure-Object claude -Sum).Sum)) <i class='sw d'></i>Delegados: $(N (($hs | Measure-Object deleg -Sum).Sum)) · hora más alta: $(N $max)</div>"
$P.consumo += $g + "</section>"

# --- Donde se va tu Claude: sesiones (cada mensaje RELEE todo el contexto de su sesion; lo que mas pesa es cuantos mensajes y que tan grande es el contexto)
$ses = @(Get-SesionesClaude $msgs)
$x = "<section class='general'><h2>Dónde se va tu Claude <small>sesiones de los últimos 7 días</small></h2>"
if ($ses) {
    $totCl = [double](($ses | Measure-Object cache_lectura -Sum).Sum); $totAll = $totCl + [double](($msgs | Where-Object { $_.t -gt (Get-Date).ToUniversalTime().AddDays(-7) } | Measure-Object entrada, cache_escritura, salida -Sum | Measure-Object Sum -Sum).Sum)
    $pctCache = if ($totAll -gt 0) { [int][math]::Round(100 * $totCl / $totAll) } else { 0 }
    $x += "<p class='nota'>El <b>$pctCache%</b> de los tokens son relecturas de caché: cada mensaje de Claude vuelve a leer TODO el contexto de su sesión. Por eso lo que más ahorra es tener sesiones cortas, más que cualquier otra cosa.</p>"
    $top = $ses[0]
    if ($top.pct -ge 50 -or $top.ctx_medio -ge [int]$cfg.ahorro.ctx_aviso) {
        $x += "<p class='alerta' role='alert'>Una sola sesión (<b>$(Esc $top.sesion)</b>) concentra el <b>$($top.pct)%</b> de las lecturas de caché, con $(N $top.msgs) mensajes y un contexto medio de $(N $top.ctx_medio) tokens. Cerrar tareas y empezar sesiones nuevas (con <code>memoria.ps1 -Handoff</code>) es lo que más baja el consumo.</p>"
    }
    $x += "<div class='tabla'><table><thead><tr><th>Sesión</th><th>Mensajes</th><th>Contexto medio</th><th>Contexto máx.</th><th>Lecturas de caché</th><th class='barcol'>% del total</th><th>Salida</th><th>Último mensaje</th></tr></thead><tbody>"
    foreach ($r in ($ses | Select-Object -First 6)) {
        $u = [math]::Max(0, [math]::Min(100, [int][math]::Round($r.pct)))
        $x += "<tr><td>$(Esc $r.sesion)$(if ($r.subagente) { ' (subagente)' })</td><td>$(N $r.msgs)</td><td>$(N $r.ctx_medio)</td><td>$(N $r.ctx_max)</td><td>$(N $r.cache_lectura)</td><td class='barcol'><div class='mini'><div class='barra $(Clase $u)' style='width:$u%'></div></div><b>$($r.pct)%</b></td><td>$(N $r.salida)</td><td>$(Esc $r.ultimo.ToString('dd/MM HH:mm'))</td></tr>"
    }
    $x += "</tbody></table></div>"
} else { $x += "<p class='nota'>Todavía no hay sesiones para medir.</p>" }
$P.consumo += $x + "</section>"

# --- Detalle: Claude
$c = "<section><h2><i class='dot' style='background:#e0805a'></i>Claude <small>detalle · $(Esc $infoClaude)</small></h2>"
if ($snap) {
    $edad = [math]::Round(((Get-Date) - [datetime]$snap.tomado).TotalMinutes)
    $c += Barra 'Ventana de 5 horas' $snap.cinco_horas.usado ("reinicia " + (Format-Falta $snap.cinco_horas.reinicia))
    $c += Barra 'Semanal (todos los modelos)' $snap.semanal.usado ("reinicia " + (Format-Falta $snap.semanal.reinicia))
    $c += "<p class='nota'>Dato de hace $edad min (fuente: $(if ($snap.fuente) { Esc $snap.fuente } else { 'foto de get_usage' })). La sesión de Claude no se puede verificar desde un script: la app guarda su login aparte.</p>"
} else { $c += "<p class='nota'>% del plan sin dato todavía.</p>" }
$c += "<h3>Tokens exactos <small>leídos de tus sesiones de Claude Code</small></h3><div class='tabla'><table><thead><tr><th>Ventana</th><th>Mensajes</th><th>Entrada</th><th>Caché escritura</th><th>Caché lectura</th><th>Salida</th></tr></thead><tbody>"
foreach ($r in Get-ResumenClaude $msgs) { $c += "<tr><td>$(Esc $r.ventana)</td><td>$(N $r.mensajes)</td><td>$(N $r.entrada)</td><td>$(N $r.cache_escritura)</td><td>$(N $r.cache_lectura)</td><td>$(N $r.salida)</td></tr>" }
$c += "</tbody></table></div>"
$sem = (Get-Date).ToUniversalTime().AddDays(-7)
$c += "<div class='tabla'><table><thead><tr><th>Modelo (7 días)</th><th>Mensajes</th><th>Entrada</th><th>Caché escritura</th><th>Salida</th></tr></thead><tbody>"
foreach ($m in ($msgs | Where-Object { $_.t -gt $sem } | Group-Object modelo | Sort-Object Count -Descending)) {
    $c += "<tr><td>$(Esc $m.Name)</td><td>$(N $m.Count)</td><td>$(N (($m.Group | Measure-Object entrada -Sum).Sum))</td><td>$(N (($m.Group | Measure-Object cache_escritura -Sum).Sum))</td><td>$(N (($m.Group | Measure-Object salida -Sum).Sum))</td></tr>"
}
$P.motores += $c + "</tbody></table></div></section>"

# Tabla de delegaciones de una IA (por modelo y esfuerzo) + ultimas llamadas.
function Delegaciones($destino, $cuentaId) {
    # Los registros viejos no tienen 'cuenta': cuentan para la cuenta base (id = destino).
    $u = @($uso | Where-Object { $_.destino -eq $destino -and ((-not $cuentaId) -or ($(if ($_.cuenta) { $_.cuenta } else { $destino }) -eq $cuentaId)) })
    if (-not $u) { return "<h3>Delegaciones de este plugin</h3><p class='nota'>Todavía no hay.</p>" }
    $hoy = (Get-Date).Date
    $h = "<h3>Delegaciones de este plugin <small>tokens exactos por llamada</small></h3><div class='tabla'><table><thead><tr><th>Modelo</th><th>Esfuerzo</th><th>Hoy</th><th>Total</th><th>Tokens</th><th>Seg/llamada</th><th>Fallas</th></tr></thead><tbody>"
    foreach ($d in ($u | Group-Object modelo, esfuerzo | Sort-Object Name)) {
        $f = @($d.Group)
        $h += "<tr><td>$(Esc $f[0].modelo)</td><td>$(if ($f[0].esfuerzo) { Esc $f[0].esfuerzo } else { '-' })</td><td>$(@($f | Where-Object { [datetime]$_.fecha -ge $hoy }).Count)</td><td>$($f.Count)</td><td>$(N (Sumar-Tok $f))</td><td>$([math]::Round(($f | Measure-Object seg -Average).Average, 1))</td><td>$(@($f | Where-Object { $_.salida -ne 0 }).Count)</td></tr>"
    }
    $h += "</tbody></table></div><h3>Últimas llamadas</h3><div class='tabla'><table><thead><tr><th>Hora</th><th>Modelo</th><th>Esfuerzo</th><th>Tokens</th><th>Seg</th><th>Resultado</th></tr></thead><tbody>"
    foreach ($x in ($u | Select-Object -Last 6 | Sort-Object fecha -Descending)) {
        $h += "<tr><td>$(Esc ([datetime]$x.fecha).ToString('dd/MM HH:mm'))</td><td>$(Esc $x.modelo)</td><td>$(if ($x.esfuerzo) { Esc $x.esfuerzo } else { '-' })</td><td>$(if ((Get-EstadoTokens $x) -eq 'informado') { N ([long]$x.tok_in + [long]$x.tok_out) } else { 's/d' })</td><td>$($x.seg)</td><td class='$(if ($x.salida -eq 0) { 'ok' } else { 'no' })'>$(if ($x.salida -eq 0) { 'ok' } else { 'falló' })</td></tr>"
    }
    $h + "</tbody></table></div>"
}

# --- Detalle: Codex (una seccion por cuenta activa)
foreach ($ctaCx in (Get-CuentasActivas $cfg 'codex')) {
    $n = Get-NombreCuenta $cfg $ctaCx; $cx = $codexCupo[$n]
    $c = "<section><h2><i class='dot' style='background:#10a37f'></i>$(Esc $n) <small>detalle · ChatGPT $(if ($cx) { Esc $cx.plan } else { '' }) · en vivo</small></h2>"
    if ($cx) { foreach ($w in $cx.ventanas) { $c += Barra $w.etiqueta $w.usado ("reinicia " + (Format-Falta $w.reinicia) + " (" + (Cuando $w.reinicia) + ")") } }
    else { $c += "<p class='nota'>No se pudo leer el cupo de esta cuenta de Codex (¿sin sesión, o Node no instalado?).</p>" }
    $P.motores += $c + (Delegaciones 'codex' $ctaCx.id) + "</section>"
}

# --- Detalle: Antigravity
$c = "<section><h2><i class='dot' style='background:#5b8def'></i>Antigravity <small>detalle · Google · en vivo</small></h2>"
if ($ag) { foreach ($q in $ag) { $c += Barra ($q.grupo + ' · ' + $q.etiqueta) (100 - $q.restante) ("quedan " + $q.restante + "% · reinicia " + (Format-Falta $q.reinicia) + " (" + (Cuando $q.reinicia) + ")") } }
else { $c += "<p class='nota'>No se pudo leer el cupo (¿agy instalado y con sesión iniciada?).</p>" }
$P.motores += $c + (Delegaciones 'agy') + "</section>"

# --- 2.0: metricas por modo de intensidad (de decisiones.jsonl, solo uso real). Nada se inventa: sin intensidad registrada = "sin dato".
$decRuta = Join-Path $script:DatosDir 'decisiones.jsonl'
$dec = @(); $decMalas = 0
if (Test-Path -LiteralPath $decRuta) {
    foreach ($l in Get-Content -LiteralPath $decRuta -Encoding UTF8) {
        if (-not $l.Trim()) { continue }
        try { $o = $l | ConvertFrom-Json; if ($o -and (Test-Productivo $o)) { $dec += $o } } catch { $decMalas++ }
    }
}
$modos = @()
foreach ($m in 'bajo', 'medio', 'alto', 'automatico') {
    $f = @($dec | Where-Object { [string]$_.intensidad -eq $m })
    $del = @($f | Where-Object { $_.destino -in 'codex', 'agy' })
    $modos += [pscustomobject]@{ modo = $m; decisiones = $f.Count; delegadas = $del.Count; directas = $f.Count - $del.Count; errores = @($f | Where-Object { $_.resultado -eq 'error' }).Count; seg_medio = $(if ($del.Count) { [math]::Round(($del | Measure-Object seg -Average).Average, 1) } else { $null }); ultima = $(if ($f.Count) { [string]($f | Sort-Object fecha | Select-Object -Last 1).fecha } else { $null }) }
}
$sinInt = @($dec | Where-Object { -not $_.intensidad }).Count
$consola = @($dec | Sort-Object fecha -Descending | Select-Object -First 25 | ForEach-Object { [pscustomobject]@{ fecha = [string]$_.fecha; destino = [string]$_.destino; resultado = [string]$_.resultado; tarea = [string]$_.tarea; modelo = [string]$_.modelo_pedido; motivo = ([string]$_.motivo); intensidad = [string]$_.intensidad; clase = [string]$_.clase } })
$extraJson = ([pscustomobject]@{ modos = $modos; sin_intensidad = $sinInt; consola = $consola; generado = (Get-Date).ToString('s') } | ConvertTo-Json -Depth 5 -Compress) -replace '<', '\u003c'

$css = @'
:root{color-scheme:dark;--bg-void:#06080d;--bg-surface:#0a0f18;--bg-glass:rgba(14,21,33,.72);--bg-elev:rgba(22,32,50,.85);--border-subtle:rgba(255,255,255,.07);--border-active:rgba(0,229,255,.28);--border-glass:rgba(255,255,255,.12);--text-primary:#e8edf5;--text-secondary:#8c9cb8;--text-tertiary:#4f5e78;--cyan:#00e5ff;--cyan-glow:rgba(0,229,255,.15);--e-claude:#e07a5f;--e-codex:#4d9fff;--e-agy:#a78bfa;--ok:#10b981;--warn:#f59e0b;--err:#ef4444;--info:#38bdf8;--font-mono:"Cascadia Code","JetBrains Mono",Consolas,monospace;
--onc1:#04222a;--bg:var(--bg-void);--card:var(--bg-glass);--card2:rgba(255,255,255,.04);--tx:var(--text-primary);--tx2:var(--text-secondary);--riel:rgba(255,255,255,.09);--bajo:var(--ok);--medio:var(--warn);--alto:var(--err);--bd:var(--border-subtle);--c1:var(--cyan);--c2:var(--e-claude)}
@media (prefers-reduced-motion:reduce){*,*::before,*::after{animation:none!important;transition:none!important}}
*{box-sizing:border-box}body{margin:0;background:radial-gradient(1200px 600px at 80% -10%,rgba(0,229,255,.06),transparent 60%),var(--bg);color:var(--tx);font:14px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif;min-height:100vh}
section{backdrop-filter:blur(12px);-webkit-backdrop-filter:blur(12px);box-shadow:0 2px 8px rgba(0,0,0,.4),inset 0 1px 0 var(--border-glass)}
.kpi b,.linea b,td,.leyenda,code{font-family:var(--font-mono)}
button:focus-visible,select:focus-visible,input:focus-visible,[role=tab]:focus-visible{outline:2px solid var(--cyan);outline-offset:2px}
.cab-app{display:flex;align-items:center;gap:14px;flex-wrap:wrap;margin-bottom:12px}.reactor{width:34px;height:34px;border-radius:50%;border:2px solid var(--cyan);box-shadow:0 0 24px rgba(0,229,255,.18),inset 0 0 12px rgba(0,229,255,.12);position:relative;flex:none}.reactor::after{content:'';position:absolute;inset:9px;border-radius:50%;background:var(--cyan);opacity:.85;animation:pulso 2.2s ease-in-out infinite}@keyframes pulso{50%{opacity:.3}}
.cab-app h1{margin:0}.cab-app .sub0{margin:0}.cab-app .acc{margin-left:auto;display:flex;gap:8px}
.tabs{display:flex;gap:6px;flex-wrap:wrap;margin:0 0 14px;padding:4px;background:var(--card2);border:1px solid var(--bd);border-radius:12px;position:sticky;top:0;z-index:5;backdrop-filter:blur(12px)}
.tabs [role=tab]{background:transparent;color:var(--tx2);border:1px solid transparent;border-radius:9px;padding:7px 14px;font:inherit;cursor:pointer;min-height:36px}
.tabs [role=tab][aria-selected=true]{background:var(--bg-elev);color:var(--tx);border-color:var(--border-active);box-shadow:0 0 12px var(--cyan-glow)}
.pane[hidden]{display:none}
.seg2{display:flex;flex-wrap:wrap;gap:0;width:fit-content;max-width:100%;border:1px solid var(--bd);border-radius:10px;overflow:hidden}.seg2 button{background:transparent;color:var(--tx);border:0;padding:7px 14px;font:inherit;cursor:pointer;min-height:36px}.seg2 button[aria-pressed=true]{background:var(--cyan);color:var(--onc1);font-weight:600}
.badge{display:inline-block;font:600 10px var(--font-mono);letter-spacing:.04em;padding:2px 6px;border-radius:9999px;margin-left:6px;vertical-align:middle}
.b-VERIFICADO{background:rgba(16,185,129,.12);color:var(--ok)}.b-OBSERVADO{background:rgba(56,189,248,.12);color:var(--info)}.b-ESTIMADO{background:rgba(245,158,11,.12);color:var(--warn)}.b-NODISPONIBLE{background:rgba(255,255,255,.06);color:var(--text-secondary)}
.mgrid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:10px;margin-top:10px}.met{background:var(--card2);border:1px solid var(--bd);border-radius:10px;padding:10px 12px}.met{display:flex;flex-direction:column;gap:4px;align-items:flex-start}.met .k{font-size:11px;color:var(--tx2);text-transform:uppercase;letter-spacing:.04em}.met .val{font:600 16px var(--font-mono);overflow-wrap:anywhere}.met .v{font:600 20px var(--font-mono)}.met .l{font-size:11px;color:var(--tx2);text-transform:uppercase;letter-spacing:.04em}.met .n{font-size:11px;color:var(--tx2);margin-top:4px}
.consola{font-family:var(--font-mono);font-size:12px;border:1px solid var(--bd);border-radius:10px;overflow:hidden}.consola .reg{display:grid;grid-template-columns:90px 1fr auto;gap:8px;padding:6px 10px;border-bottom:1px solid var(--bd);border-left:3px solid var(--text-tertiary)}.consola .reg.ok{border-left-color:var(--ok)}.consola .reg.error{border-left-color:var(--err)}.consola .reg .m{color:var(--tx2);grid-column:2/4;overflow-wrap:anywhere}
.compacto h2 small,.compacto h3 small,.compacto .det,.compacto .mgrid .n{display:none}.compacto section{padding:10px}.compacto .cuentas{gap:8px}
@media (max-width:560px){main{padding:12px 12px 36px}.cab-app .acc{margin-left:0}.consola .reg{grid-template-columns:1fr}.consola .reg .m{grid-column:1}}
main{max-width:880px;margin:0 auto;padding:24px 16px 48px}h1{font-size:22px;margin:0 0 4px}.sub0{color:var(--tx2);margin:0 0 18px;font-size:13px}
section{background:var(--card);border:1px solid var(--bd);border-radius:12px;padding:16px;margin-bottom:14px}h2{font-size:16px;margin:0 0 12px;display:flex;align-items:center;gap:8px;flex-wrap:wrap}h3{font-size:14px;margin:16px 0 4px}
h2 small,h3 small{font-weight:400;color:var(--tx2);font-size:12px}
.dot{display:inline-block;width:10px;height:10px;border-radius:50%;flex:none}
.cuentas{display:grid;grid-template-columns:repeat(auto-fit,minmax(215px,1fr));gap:12px;margin-bottom:14px}
.cuenta{background:var(--card);border:1px solid var(--bd);border-radius:12px;padding:12px 14px}.cab{display:flex;align-items:center;gap:8px}.cab b{font-size:15px}
.cuenta .sub{font-size:12px;color:var(--tx2);margin:2px 0 10px}.ok{color:var(--bajo)}.no{color:var(--alto);font-weight:600}
.linea{display:flex;justify-content:space-between;gap:8px;font-size:12.5px;margin-top:8px}.linea b{font-size:14px}.ren{color:var(--tx2);font-size:12px;text-align:right}
.pie{font-size:11px;color:var(--tx2);margin-top:8px}.grupo{font-size:11px;text-transform:uppercase;letter-spacing:.05em;color:var(--tx2);margin:14px 0 0;padding-top:8px;border-top:1px solid var(--bd)}
.general{border-color:var(--tx2)}.kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:10px;margin-bottom:10px}
.kpi{background:var(--card2);border:1px solid var(--bd);border-radius:10px;padding:10px 12px;display:flex;flex-direction:column}.kpi b{font-size:30px;line-height:1.1}.k{font-size:12px;color:var(--tx2);text-transform:uppercase;letter-spacing:.04em}.k2{font-size:12px;color:var(--tx2)}
.bajot{color:var(--bajo)}.mediot{color:var(--medio)}.altot{color:var(--alto)}
.fila{margin-bottom:12px}.et{display:flex;justify-content:space-between;gap:12px;font-size:14px}.et span{overflow-wrap:anywhere}
.riel,.mini{height:8px;background:var(--riel);border-radius:5px;overflow:hidden;margin:4px 0}.barra{height:100%;border-radius:5px}
.bajo{background:var(--bajo)}.medio{background:var(--medio)}.alto{background:var(--alto)}.det{font-size:12px;color:var(--tx2)}
.nota{font-size:13px;color:var(--tx2);margin:8px 0 0}.tabla{overflow-x:auto}table{border-collapse:collapse;width:100%;font-size:13px;margin-top:8px}
th,td{text-align:left;padding:6px 12px 6px 0;border-bottom:1px solid var(--bd);white-space:nowrap}th{color:var(--tx2);font-weight:600}
.barcol{min-width:150px}.barcol .mini{display:inline-block;width:100px;vertical-align:middle;margin:0 8px 0 0}
.horas{display:flex;align-items:flex-end;gap:3px;height:96px;margin-top:8px;border-bottom:1px solid var(--bd)}.col{flex:1;height:100%;display:flex;flex-direction:column-reverse;min-width:0}
.seg{width:100%}.seg.c{background:var(--c1)}.seg.d{background:var(--c2)}.col .seg:first-child{border-radius:3px 3px 0 0}
.ejeh{display:flex;justify-content:space-between;font-size:11px;color:var(--tx2);margin-top:2px}.leyenda{font-size:12px;color:var(--tx2);margin-top:6px}
.sw{display:inline-block;width:10px;height:10px;border-radius:2px;margin:0 4px 0 10px;vertical-align:baseline}.sw.c{background:var(--c1)}.sw.d{background:var(--c2)}.leyenda .sw:first-child{margin-left:0}
.modo{border-color:var(--c1)}.alterna{display:flex;flex-wrap:wrap;width:fit-content;border:1px solid var(--bd);border-radius:10px;overflow:hidden;max-width:100%}
.alterna button{background:transparent;color:var(--tx);border:0;padding:8px 14px;font:inherit;cursor:pointer;display:flex;flex-direction:column;align-items:center;flex:1 1 110px;min-width:0;text-align:center}
.alterna button small{font-size:11px;color:var(--tx2)}.alterna button[aria-pressed=true]{background:var(--c1);color:var(--onc1);font-weight:600}.alterna button[aria-pressed=true] small{color:var(--onc1)}
.boton svg{width:1.1em;height:1.1em;vertical-align:-.18em;margin-right:.45em}.boton{background:var(--c1);color:var(--onc1);border:0;border-radius:8px;padding:8px 16px;font:inherit;font-weight:600;cursor:pointer}.alterna button:disabled,select:disabled,input:disabled{opacity:.6;cursor:not-allowed}
.alterna button:focus-visible,select:focus-visible,input:focus-visible{outline:2px solid var(--c1);outline-offset:2px}
.sel{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:12px;margin-top:10px}.sel label{display:flex;flex-direction:column;font-size:12px;color:var(--tx2);gap:4px}
select{background:var(--card2);color:var(--tx);border:1px solid var(--bd);border-radius:8px;padding:7px 8px;font:inherit;max-width:100%}
.cuentas-cfg{display:flex;flex-direction:column;gap:6px;font-size:14px}.estado{font-size:13px;min-height:1.4em;margin:8px 0 0;color:var(--bajo)}.estado.mal{color:var(--alto)}
.chk{display:flex;gap:8px;align-items:flex-start;font-size:14px;margin:6px 0}.chk input{margin-top:4px}
.alerta{border:1px solid var(--alto);border-left-width:4px;border-radius:8px;padding:8px 12px;font-size:13px;margin:10px 0 0}
.chats{border-color:var(--c2)}.chats select{margin:4px 8px 4px 0}h3{font-size:14px;margin:14px 0 0}
code{background:var(--card2);padding:1px 5px;border-radius:4px;font-size:12px;overflow-wrap:anywhere}
'@
$js = @'
(function () {
  var D = JSON.parse(document.getElementById('datos').textContent), cfg = D.config, servido = location.protocol.indexOf('http') === 0;
  var $ = function (s) { return document.querySelector(s); };
  var ICONO_ONOFF = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 3v9"/><path d="M6.4 6.6a8 8 0 1 0 11.2 0"/></svg>';
  function opciones(sel, vals, cur) { sel.innerHTML = ''; vals.forEach(function (v) { var o = document.createElement('option'); o.value = v.value; o.textContent = v.label; sel.appendChild(o); }); sel.value = cur; }
  function esfuerzos(slug) { var m = D.codex.filter(function (x) { return x.slug === slug; })[0]; return (m && Array.isArray(m.esfuerzos) && m.esfuerzos.length) ? m.esfuerzos : ['low', 'medium', 'high', 'xhigh', 'max', 'ultra']; }
  function estado(t, mal) { var e = $('#estado'); e.textContent = t; e.className = 'estado' + (mal ? ' mal' : ''); }
  function pintar() {
    var on = cfg.activo !== false; $('#onoff').innerHTML = ICONO_ONOFF + '<span>' + (on ? 'Encendido · tocá para apagar' : 'Apagado · tocá para encender') + '</span>'; $('#onoff').setAttribute('aria-pressed', String(on));
    $('#onoff-desc').textContent = on ? 'Multi-IA delega y cuida tu cupo.' : 'Apagado: no se delega nada y los avisos automáticos se callan. Claude resuelve todo directo.';
    document.querySelectorAll('#modo > .alterna button').forEach(function (b) { b.setAttribute('aria-pressed', String(b.dataset.modo === cfg.modo)); });
    document.querySelectorAll('#calidad button').forEach(function (b) { b.setAttribute('aria-pressed', String(b.dataset.calidad === cfg.calidad)); });
    $('#calidad-bloque').hidden = cfg.modo === 'manual';
    $('#calidad-desc').textContent = ({ economica: 'Económica: lo más barato que alcance. Ojo: un motor flojo que Claude tenga que corregir termina costando más cupo de Claude.', equilibrada: 'Equilibrada: buen motor y esfuerzo medio (Codex gpt-6.1-sol, Gemini 4 Argon, Claude Opus por Google). Recomendada para el día a día.', maxima: 'Máxima: el mejor motor de cada IA con esfuerzo alto (Codex gpt-6-astra / gpt-6.1-sol xhigh, Claude Opus y Gemini 4 Argon high) y una REVISIÓN CRUZADA con otro proveedor. Para dinero, seguridad o producción (ej. un bot de arbitraje). Tarda más y gasta más cupo delegado; nunca baja de motor por falta de cupo: avisa.' })[cfg.calidad] || '';
    $('#manual').hidden = cfg.modo !== 'manual';
    $('#modo-desc').textContent = cfg.modo === 'manual'
      ? 'Manual: los delegados usan SIEMPRE lo que elegís acá, aunque Claude pida otra cosa.'
      : 'Automático: Claude elige el motor y la intensidad de cada tarea (lo más barato que alcance) y esquiva los cupos al límite, para gastar lo menos posible de tu Claude.';
    var cx = cfg.manual.codex, ag = cfg.manual.agy;
    opciones($('#cx-modelo'), [{ value: '', label: '(el de tu config de Codex)' }].concat(D.codex.map(function (m) { return { value: m.slug, label: m.slug }; })), cx.modelo || '');
    opciones($('#cx-esf'), esfuerzos(cx.modelo).map(function (e) { return { value: e, label: e }; }), cx.esfuerzo);
    opciones($('#ag-modelo'), D.agy.map(function (m) { return { value: m.slug, label: m.nombre + ' (' + m.slug + ')' }; }), ag.modelo);
    var L = $('#lista-cuentas'), n = 0; L.innerHTML = '';
    cfg.cuentas.forEach(function (c) {
      if (c.activa) n++;
      var l = document.createElement('label'), i = document.createElement('input'); i.type = 'checkbox'; i.checked = !!c.activa; i.disabled = !servido;
      i.onchange = function () { guardar({ cuentas: [{ id: c.id, activa: i.checked }] }); };
      l.appendChild(i); l.appendChild(document.createTextNode(' ' + c.etiqueta + ' · ' + c.tipo + (c.home ? ' (carpeta propia)' : ''))); L.appendChild(l);
    });
    $('#cuentas-n').textContent = n + ' activas de máximo ' + D.max;
    $('#guardia').checked = !(cfg.ahorro && cfg.ahorro.guardia_activa === false);
    document.querySelectorAll('#modo button, #modo select, #guardia').forEach(function (e) { e.disabled = !servido; });
  }
  function guardar(c) {
    if (!servido) return;
    estado('Guardando…');
    fetch('/api/config', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(c) })
      .then(function (r) { return r.json().then(function (j) { if (!r.ok) throw new Error(j.error || r.status); return j; }); })
      .then(function (j) { cfg = j; pintar(); estado('Guardado ✓ · vale desde la próxima delegación'); })
      .catch(function (e) { estado('No se pudo guardar: ' + e.message, true); pintar(); });
  }
  function manual() { return { manual: { codex: { modelo: $('#cx-modelo').value, esfuerzo: $('#cx-esf').value }, agy: { modelo: $('#ag-modelo').value } } }; }
  document.querySelectorAll('#modo > .alterna button').forEach(function (b) { b.onclick = function () { guardar({ modo: b.dataset.modo }); }; });
  document.querySelectorAll('#calidad button').forEach(function (b) { b.onclick = function () { guardar({ calidad: b.dataset.calidad }); }; });
  $('#onoff').onclick = function () { guardar({ activo: cfg.activo === false }); };
  $('#actualizar').onclick = function () {
    var bt = this; bt.disabled = true; estado('Actualizando… (puede tardar un minuto)');
    fetch('/api/regenerar', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' })
      .then(function (r) { return r.json().then(function (j) { if (!r.ok) throw new Error(j.error || r.status); return j; }); })
      .then(function () { location.reload(); })
      .catch(function (e) { bt.disabled = !servido; estado('No se pudo actualizar: ' + e.message, true); });
  };
  $('#cx-modelo').onchange = function () {   // el esfuerzo valido depende del modelo: se ajusta antes de guardar
    var ok = esfuerzos(this.value), cur = $('#cx-esf').value;
    opciones($('#cx-esf'), ok.map(function (e) { return { value: e, label: e }; }), ok.indexOf(cur) >= 0 ? cur : (ok.indexOf('medium') >= 0 ? 'medium' : ok[0]));
    guardar(manual());
  };
  $('#cx-esf').onchange = function () { guardar(manual()); };
  $('#ag-modelo').onchange = function () { guardar(manual()); };
  $('#guardia').onchange = function () { guardar({ ahorro: { guardia_activa: this.checked } }); };
  pintar();
  if (!servido) estado('Vista de solo lectura. Para usar el botón abrí iniciar-panel.cmd (servidor local).', true);
  else fetch('/api/config').then(function (r) { if (!r.ok) throw new Error(r.status); return r.json(); }).then(function (j) { cfg = j; pintar(); }).catch(function () { estado('No se pudo leer la configuración del servidor local.', true); });
})();
'@
# --- Chats (1.9.0): seccion bajo demanda. Solo funciona servido por panel-servidor.mjs (/api/chats, /api/export). No corre en cada refresco: se lee al tocar el boton.
$chatsHtml = @"
<section class='chats' id='chats'><h2>Chats <small>consumo por chat · motores activos · consola · exportar</small></h2>
<p><button type='button' class='boton' id='ch-leer'>Leer chats</button> <button type='button' class='boton' id='ch-md'>Exportar MD</button> <button type='button' class='boton' id='ch-json'>Exportar JSON</button></p>
<p class='nota' id='ch-estado'>Sin lectura todavía. Se lee al tocar el botón (puede tardar unos segundos) y se guarda 20 s en el servidor.</p>
<label class='nota'>Chat <select id='ch-sel'></select></label> <label class='nota'>Motor <select id='ch-motor'><option value=''>Todos</option><option value='codex'>Codex</option><option value='agy'>Antigravity</option></select></label> <label class='nota'>Estado <select id='ch-est'><option value=''>Cualquiera</option><option value='con error'>Con error</option><option value='terminada'>Terminadas</option></select></label>
<div id='ch-cons'></div><div class='tabla'><table id='ch-tabla'></table></div><h3>Ejecuciones recientes</h3><div class='tabla'><table id='ch-ejec'></table></div></section>
"@
$js2 = @'
(function () {
  var $ = function (s) { return document.querySelector(s); }, J = null, selInit = false;
  var servido = location.protocol.indexOf('http') === 0;
  function celda(tr, t, th) { var c = document.createElement(th ? 'th' : 'td'); c.textContent = t; tr.appendChild(c); }
  function prov(x) { return x && x.valor !== null && x.valor !== undefined ? Number(x.valor).toLocaleString('es-AR') + ' [' + x.nivel + ']' : 's/d [' + ((x && x.nivel) || 'NO DISPONIBLE') + ']'; }
  function fila(t, v, th) { var tr = document.createElement('tr'); v.forEach(function (x) { celda(tr, x, th); }); t.appendChild(tr); }
  function pintarCh() {
    if (!J) return;
    var sel = $('#ch-sel'), cur = sel.value; sel.innerHTML = '';
    var o0 = document.createElement('option'); o0.value = ''; o0.textContent = 'Todos (resumen general)'; sel.appendChild(o0);
    J.chats.forEach(function (c) { var o = document.createElement('option'); o.value = c.id_chat; o.textContent = (c.estado === 'activo confirmado' ? '● ' : '') + c.id_chat.slice(0, 8) + (c.id_chat === J.chat_actual ? ' (este)' : ''); sel.appendChild(o); });
    if (!selInit) { sel.value = J.chat_actual || ''; selInit = true; } else { sel.value = cur; }   // "Todos" ('') se respeta una vez elegido
    var t = $('#ch-tabla'); t.innerHTML = '';
    fila(t, ['Chat', 'Estado', 'Claude real', 'Codex', 'Antigravity', 'Deleg.', 'Err.'], true);
    J.chats.filter(function (c) { return !sel.value || c.id_chat === sel.value; }).forEach(function (c) { fila(t, [c.id_chat.slice(0, 8), c.estado, prov(c.consumo.claude_real), prov(c.consumo.codex), prov(c.consumo.antigravity), String(c.delegaciones), String(c.errores)]); });
    var e = $('#ch-ejec'); e.innerHTML = ''; fila(e, ['Fecha', 'Motor', 'Estado', 'Clase', 'Chat'], true);
    J.ejecuciones_recientes.filter(function (x) { return (!$('#ch-motor').value || x.motor === $('#ch-motor').value) && (!$('#ch-est').value || x.estado === $('#ch-est').value) && (!sel.value || x.id_chat === sel.value); })
      .slice(0, 40).forEach(function (x) { fila(e, [String(x.fecha).replace('T', ' ').slice(5, 19), x.motor === 'codex' ? 'Codex' : 'Antigravity', x.estado, x.clase || '', String(x.id_chat).slice(0, 8)]); });
    $('#ch-cons').textContent = 'Motores activos ahora: ' + J.ejecuciones_activas_ahora.length + ' · ' + J.resumen_general.chats + ' chats · ' + J.resumen_general.delegaciones + ' delegaciones · ' + J.resumen_general.errores + ' con error. s/d = sin dato (no es cero).';
  }
  function leer(forzar) {
    $('#ch-estado').textContent = 'Leyendo…';
    fetch('/api/chats' + (forzar ? '?refrescar=1' : '')).then(function (r) { if (!r.ok) throw new Error(r.status); return r.json(); })
      .then(function (j) { J = j; pintarCh(); $('#ch-estado').textContent = 'Leído ' + String(j.generado).replace('T', ' '); })
      .catch(function (e) { $('#ch-estado').textContent = 'No se pudo leer chats: ' + e.message; });
  }
  $('#ch-leer').onclick = function () { leer(true); };
  $('#ch-md').onclick = function () { location.href = '/api/export?formato=md'; };
  $('#ch-json').onclick = function () { location.href = '/api/export?formato=json'; };
  ['#ch-sel', '#ch-motor', '#ch-est'].forEach(function (s) { $(s).onchange = pintarCh; });
  if (!servido) { document.querySelectorAll('#chats button').forEach(function (b) { b.disabled = true; }); $('#ch-estado').textContent = 'Solo disponible abriendo el panel con iniciar-panel.cmd (servidor local).'; }
})();
'@
# --- 2.0: intensidad, ahorro, actividad, consola y estructura en pestanas (J.A.R.V.I.S. premium minimal)
$intHtml = @'
<section id='intensidad'><h2>Intensidad de delegación <small>cuánto delega Claude</small></h2>
<h3>Global</h3><div class='seg2' id='int-global' role='group' aria-label='Intensidad global'><button type='button' data-int='bajo'>Bajo</button><button type='button' data-int='medio'>Medio</button><button type='button' data-int='alto'>Alto</button><button type='button' data-int='automatico'>Automático</button></div>
<p class='nota' id='int-desc'></p>
<h3>Chat <select id='int-chat-sel' aria-label='Chat'></select></h3><div class='seg2' id='int-chat' role='group' aria-label='Intensidad del chat'><button type='button' data-int=''>Heredar global</button><button type='button' data-int='bajo'>Bajo</button><button type='button' data-int='medio'>Medio</button><button type='button' data-int='alto'>Alto</button><button type='button' data-int='automatico'>Automático</button></div>
<p class='nota' id='int-efectivo'></p><p class='estado' id='int-estado' role='status' aria-live='polite'></p></section>
'@
$ahHtml = @'
<section id='ahorro'><h2>Ahorro <small>honesto: sin dato no es cero</small></h2>
<div class='seg2' id='ah-ambito' role='group' aria-label='Ámbito del ahorro'><button type='button' data-ambito='global'>Global</button><button type='button' data-ambito='chat'>Chat seleccionado</button><button type='button' data-ambito='activos'>Chats activos</button><button type='button' data-ambito='historial'>Historial</button></div>
<p class='nota'><label>Chat <select id='ah-chat-sel' aria-label='Chat para el ahorro'></select></label> <span id='ah-estado'></span></p>
<div id='ah-out'></div>
<p class='nota'>Niveles: <span class='badge b-VERIFICADO'>VERIFICADO</span> dato del proveedor · <span class='badge b-OBSERVADO'>OBSERVADO</span> medido acá · <span class='badge b-ESTIMADO'>ESTIMADO</span> cota calculada · <span class='badge b-NODISPONIBLE'>NO DISPONIBLE</span>. Las cotas por proveedor no se suman entre sí.</p></section>
'@
$actHtml = @'
<section id='actividad'><h2>Métricas por modo <small>de decisiones.jsonl (solo ejecuciones reales)</small></h2>
<div class='tabla'><table id='act-tabla'></table></div><p class='nota' id='act-nota'></p></section>
'@
$conHtml = @'
<section id='consola'><h2>Consola <small>últimas decisiones de delegación</small></h2><div class='consola' id='con-lista' role='log' aria-label='Últimas decisiones'></div></section>
'@
$cabHtml = @'
<header class='cab-app'><div class='reactor' aria-hidden='true'></div><div class='cab-t'><h1>Multi-IA</h1><p class='sub0' id='sub-gen'></p></div><button type='button' id='vista' class='boton' aria-pressed='false'>Vista compacta</button></header>
<nav class='tabs' role='tablist' aria-label='Secciones del panel'>
<button type='button' role='tab' id='tab-resumen' data-pane='resumen' aria-controls='pane-resumen'>Resumen</button>
<button type='button' role='tab' id='tab-motores' data-pane='motores' aria-controls='pane-motores'>Motores</button>
<button type='button' role='tab' id='tab-actividad' data-pane='actividad' aria-controls='pane-actividad'>Actividad</button>
<button type='button' role='tab' id='tab-consumo' data-pane='consumo' aria-controls='pane-consumo'>Consumo</button>
<button type='button' role='tab' id='tab-chats' data-pane='chats' aria-controls='pane-chats'>Chats</button>
<button type='button' role='tab' id='tab-consola' data-pane='consola' aria-controls='pane-consola'>Consola</button>
<button type='button' role='tab' id='tab-sistema' data-pane='sistema' aria-controls='pane-sistema'>Sistema</button></nav>
'@
$js3 = @'
(function () {
  var $ = function (s) { return document.querySelector(s); }, $$ = function (s) { return [].slice.call(document.querySelectorAll(s)); };
  var servido = location.protocol.indexOf('http') === 0, EXTRA = {}, cfg = null, CH = null, AH = null, selChat = '', ambito = 'global';
  try { EXTRA = JSON.parse($('#extra').textContent); } catch (e) { EXTRA = {}; }
  try { cfg = JSON.parse($('#datos').textContent).config; } catch (e) { cfg = null; }
  var DESC = { bajo: 'Bajo: Claude conserva casi todo y delega solo lo grande o claramente de otro motor.', medio: 'Medio: equilibrio; delega lo que compensa el arranque del motor.', alto: 'Alto: delega más; puede sugerir delegaciones en paralelo; revisión cruzada automática en código, revisión y razonamiento.', automatico: 'Automático (por defecto): Claude decide caso por caso.' };
  var NOMBRE = { codex: 'Codex', antigravity: 'Antigravity' };
  function el(t, c, x) { var e = document.createElement(t); if (c) e.className = c; if (x !== undefined && x !== null) e.textContent = x; return e; }
  function fmt(n) { return Number(n).toLocaleString('es-AR'); }
  function guardarLocal(k, v) { try { localStorage.setItem(k, v); } catch (e) { } }
  function leerLocal(k) { try { return localStorage.getItem(k); } catch (e) { return null; } }

  // ---- pestanas (ARIA tablist, flechas, Inicio/Fin)
  var tabs = $$('[role=tab]');
  function ir(id, foco) {
    if (!$('#pane-' + id)) id = 'resumen';
    tabs.forEach(function (t) { var on = t.dataset.pane === id; t.setAttribute('aria-selected', String(on)); t.tabIndex = on ? 0 : -1; if (on && foco) t.focus(); });
    $$('.pane').forEach(function (p) { p.hidden = p.id !== 'pane-' + id; });
    guardarLocal('multiia-tab', id);
  }
  tabs.forEach(function (t, i) {
    t.onclick = function () { ir(t.dataset.pane, false); };
    t.onkeydown = function (ev) {
      var j = ev.key === 'ArrowRight' ? i + 1 : ev.key === 'ArrowLeft' ? i - 1 : ev.key === 'Home' ? 0 : ev.key === 'End' ? tabs.length - 1 : null;
      if (j === null) return; ev.preventDefault(); ir(tabs[(j + tabs.length) % tabs.length].dataset.pane, true);
    };
  });
  ir(leerLocal('multiia-tab') || 'resumen', false);
  $('#sub-gen').textContent = 'Generado ' + String(EXTRA.generado || '').replace('T', ' ') + ' · Multi-IA Orquestador';

  // ---- compacto / expandido
  function vista(c) { document.body.classList.toggle('compacto', c); $('#vista').setAttribute('aria-pressed', String(c)); $('#vista').textContent = c ? 'Vista expandida' : 'Vista compacta'; guardarLocal('multiia-compacto', c ? '1' : '0'); }
  $('#vista').onclick = function () { vista(!document.body.classList.contains('compacto')); };
  vista(leerLocal('multiia-compacto') === '1');

  // ---- chat seleccionado (compartido por intensidad y ahorro)
  function chatActual() {
    if (!CH) return '';
    if (CH.chat_actual) return CH.chat_actual;
    var a = CH.chats.filter(function (c) { return /^activo/.test(c.estado); }).sort(function (x, y) { return String(y.ultima).localeCompare(String(x.ultima)); });
    return a[0] ? a[0].id_chat : '';
  }
  function llenarSel(sel) {
    sel.innerHTML = '';
    var o0 = el('option', '', CH ? '(elegí un chat)' : '(chats sin leer)'); o0.value = ''; sel.appendChild(o0);
    if (CH) CH.chats.forEach(function (c) { var o = el('option', '', (/^activo/.test(c.estado) ? '● ' : '') + c.id_chat.slice(0, 8) + (c.id_chat === chatActual() ? ' (actual)' : '')); o.value = c.id_chat; sel.appendChild(o); });
    sel.value = selChat; sel.disabled = !CH;
  }
  function setChat(id) { selChat = id; pintarInt(); pintarAh(); }

  // ---- intensidad
  function intEstado(t, mal) { var e = $('#int-estado'); e.textContent = t; e.className = 'estado' + (mal ? ' mal' : ''); }
  function pintarInt() {
    llenarSel($('#int-chat-sel')); llenarSel($('#ah-chat-sel'));
    if (!cfg) { $('#int-desc').textContent = 'Sin configuración disponible.'; return; }
    var g = cfg.intensidad || 'automatico', own = (cfg.intensidad_chats || {})[selChat] || '';
    $$('#int-global button').forEach(function (b) { b.setAttribute('aria-pressed', String(b.dataset.int === g)); b.disabled = !servido; });
    $$('#int-chat button').forEach(function (b) { b.setAttribute('aria-pressed', String(b.dataset.int === own)); b.disabled = !servido || !selChat; });
    $('#int-desc').textContent = DESC[g] || '';
    $('#int-efectivo').textContent = selChat ? ('Efectivo en el chat ' + selChat.slice(0, 8) + ': ' + (own || g) + (own ? ' (propia del chat)' : ' (hereda la global)')) : 'Elegí un chat para ver o fijar su intensidad.';
  }
  function guardarInt(c) {
    if (!servido) return; intEstado('Guardando…');
    fetch('/api/config', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(c) })
      .then(function (r) { return r.json().then(function (j) { if (!r.ok) throw new Error(j.error || r.status); return j; }); })
      .then(function (j) { cfg = j; pintarInt(); intEstado('Guardado ✓ · vale desde la próxima delegación'); })
      .catch(function (e) { intEstado('No se pudo guardar: ' + e.message, true); pintarInt(); });
  }
  $$('#int-global button').forEach(function (b) { b.onclick = function () { guardarInt({ intensidad: b.dataset.int }); }; });
  $$('#int-chat button').forEach(function (b) { b.onclick = function () { if (selChat) guardarInt({ intensidad_chat: { chat: selChat, valor: b.dataset.int || null } }); }; });
  $('#int-chat-sel').onchange = function () { setChat(this.value); };
  $('#ah-chat-sel').onchange = function () { setChat(this.value); };

  // ---- ahorro (nunca suma proveedores ni mezcla ambitos; null = "No disponible")
  var CLAVES = [['tokens_proveedor', 'Tokens de proveedor'], ['claude_reportado', 'Claude (reportado)'], ['claude_estimado', 'Claude (estimado)'], ['carga_delegada', 'Carga delegada (salida)'], ['ahorro_potencial', 'Ahorro potencial'], ['costo_economico', 'Costo económico'], ['tiempo', 'Tiempo']];
  function badge(n) { var s = el('span', 'badge b-' + String(n || 'NO DISPONIBLE').replace(/\s/g, ''), n || 'NO DISPONIBLE'); return s; }
  function fila(grid, etq, m, extra) {
    var f = el('div', 'met'); f.appendChild(el('span', 'k', etq));
    var v = m && m.valor !== null && m.valor !== undefined, txt;
    if (!v) txt = (extra === 'ahorro') ? 'Ahorro no determinable' : 'No disponible';
    else if (typeof m.valor === 'object') txt = 'total ' + Number(m.valor.total).toLocaleString('es-AR') + ' s · medio ' + Number(m.valor.medio).toLocaleString('es-AR') + ' s';
    else txt = fmt(m.valor) + ' ' + (m.unidad || '') + (extra === 'ahorro' ? ' (cota mínima)' : '');
    f.appendChild(el('b', 'val', txt)); f.appendChild(badge(m && m.nivel));
    f.title = [m && m.etiqueta, m && m.fuente, m && m.metodo, m && m.fecha, m && m.parcial ? 'dato parcial' : '', m && m.nota].filter(Boolean).join(' · ');
    grid.appendChild(f);
  }
  function bloque(titulo, d) {
    var box = el('div', 'ah-bloque'); box.appendChild(el('h3', '', titulo)); var grid = el('div', 'mgrid');
    CLAVES.forEach(function (k) {
      var m = d[k[0]]; if (!m) return;
      if (m.por_proveedor) { Object.keys(m.por_proveedor).forEach(function (p) { var pm = m.por_proveedor[p]; fila(grid, k[1] + ' · ' + (NOMBRE[p] || p), pm, k[0] === 'ahorro_potencial' ? 'ahorro' : ''); }); }
      else fila(grid, k[1], m, '');
    });
    box.appendChild(grid); return box;
  }
  function tabla(cols, rows) {
    var w = el('div', 'tabla'), t = el('table'), h = el('tr'); cols.forEach(function (c) { h.appendChild(el('th', '', c)); }); t.appendChild(h);
    rows.forEach(function (r) { var tr = el('tr'); r.forEach(function (x) { tr.appendChild(el('td', '', x)); }); t.appendChild(tr); });
    w.appendChild(t); return w;
  }
  function resumenCh(c) {
    function pp(m, p) { var x = m && m.por_proveedor && m.por_proveedor[p]; return x && x.valor !== null && x.valor !== undefined ? fmt(x.valor) + ' [' + x.nivel + ']' : 'No disponible'; }
    return [c.id_chat.slice(0, 8), pp(c.carga_delegada, 'codex'), pp(c.carga_delegada, 'antigravity'), pp(c.ahorro_potencial, 'codex').replace(/^(\d)/, '≥ $1'), pp(c.ahorro_potencial, 'antigravity').replace(/^(\d)/, '≥ $1')];
  }
  function pintarAh() {
    $$('#ah-ambito button').forEach(function (b) { b.setAttribute('aria-pressed', String(b.dataset.ambito === ambito)); });
    var out = $('#ah-out'); out.innerHTML = '';
    if (!AH) { out.appendChild(el('p', 'nota', servido ? 'Leyendo ahorro… (lee los transcripts: puede tardar hasta un minuto)' : 'Ahorro disponible solo abriendo el panel con iniciar-panel.cmd (servidor local). Ahorro no determinable desde acá.')); return; }
    if (ambito === 'global') out.appendChild(bloque('Global', AH.global));
    else if (ambito === 'chat') {
      var c = AH.chats.filter(function (x) { return x.id_chat === selChat; })[0];
      out.appendChild(c ? bloque('Chat ' + selChat.slice(0, 8), c) : el('p', 'nota', selChat ? 'Ese chat no tiene datos de ahorro: ahorro no determinable.' : 'Elegí un chat arriba.'));
    } else {
      var act = {}; (CH ? CH.chats : []).forEach(function (c) { act[c.id_chat] = /^activo/.test(c.estado); });
      var lista = AH.chats.filter(function (c) { return ambito === 'historial' || act[c.id_chat]; });
      if (ambito === 'activos' && !CH) { out.appendChild(el('p', 'nota', 'Hace falta leer los chats para saber cuáles están activos.')); return; }
      out.appendChild(lista.length ? tabla(['Chat', 'Deleg. Codex (tok)', 'Deleg. Antigravity (tok)', 'Ahorro pot. Codex', 'Ahorro pot. Antigravity'], lista.map(resumenCh)) : el('p', 'nota', 'Sin chats en este ámbito.'));
    }
  }
  $$('#ah-ambito button').forEach(function (b) { b.onclick = function () { ambito = b.dataset.ambito; pintarAh(); }; });

  // ---- actividad (metricas por modo) y consola: datos embebidos al generar el panel
  function pintarAct() {
    var t = $('#act-tabla'), m = EXTRA.modos || {}, h = el('tr');
    ['Modo', 'Decisiones', 'Delegadas', 'Directas', 'Errores', 'Seg. medio', 'Última'].forEach(function (c) { h.appendChild(el('th', '', c)); }); t.appendChild(h);
    var ks = [].concat(m); ks.forEach(function (x) { var tr = el('tr'); [x.modo, x.decisiones, x.delegadas, x.directas, x.errores, x.seg_medio === null || x.seg_medio === undefined ? 'sin dato' : x.seg_medio, x.ultima || 'sin dato'].forEach(function (v) { tr.appendChild(el('td', '', String(v))); }); t.appendChild(tr); });
    $('#act-nota').textContent = ks.length ? ((EXTRA.sin_intensidad ? EXTRA.sin_intensidad + ' decisiones anteriores no registran la intensidad y no se asignan a ningún modo. ' : '') + 'sin dato = no medido, no es cero.') : 'Todavía no hay decisiones con intensidad registrada: sin dato' + (EXTRA.sin_intensidad ? ' (' + EXTRA.sin_intensidad + ' decisiones previas sin intensidad).' : '.');
  }
  function pintarCon() {
    var L = $('#con-lista'), a = EXTRA.consola || [];
    if (!a.length) { L.appendChild(el('p', 'nota', 'Sin decisiones registradas.')); return; }
    a.forEach(function (d) {
      var r = el('div', 'reg ' + (d.clase || ''));
      r.appendChild(el('span', 'k', String(d.fecha || '').replace('T', ' ').slice(5, 19)));
      r.appendChild(el('b', '', d.destino || '')); r.appendChild(el('span', '', d.resultado || ''));
      r.appendChild(el('span', '', [d.tarea, d.modelo, d.intensidad].filter(Boolean).join(' · ')));
      if (d.motivo) r.appendChild(el('span', 'k2', d.motivo));
      L.appendChild(r);
    });
  }
  pintarAct(); pintarCon(); pintarInt(); pintarAh();

  // ---- carga unica al abrir (servido): config, chats y ahorro; no se repite en cada refresco
  if (servido) {
    fetch('/api/config').then(function (r) { if (!r.ok) throw new Error(r.status); return r.json(); }).then(function (j) { cfg = j; pintarInt(); }).catch(function () { intEstado('No se pudo leer la configuración.', true); });
    fetch('/api/chats').then(function (r) { if (!r.ok) throw new Error(r.status); return r.json(); }).then(function (j) { CH = j; if (!selChat) selChat = chatActual(); pintarInt(); pintarAh(); }).catch(function (e) { $('#ah-estado').textContent = 'No se pudo leer la lista de chats: ' + e.message; });
    fetch('/api/ahorro').then(function (r) { if (!r.ok) throw new Error(r.status); return r.json(); }).then(function (j) { AH = j; pintarAh(); }).catch(function (e) { $('#ah-estado').textContent = 'No se pudo leer el ahorro: ' + e.message; });
  } else intEstado('Vista de solo lectura. Para cambiar la intensidad abrí iniciar-panel.cmd.', true);
})();
'@
$panes = [ordered]@{
    resumen   = $intHtml + $ahHtml + $P.resumen
    motores   = $P.motores
    actividad = $actHtml
    consumo   = $P.consumo
    chats     = $chatsHtml
    consola   = $conHtml
    sistema   = $P.sistema
}
$cuerpo = $cabHtml
foreach ($k in $panes.Keys) { $cuerpo += "<div class='pane' id='pane-$k' role='tabpanel' aria-labelledby='tab-$k'>$($panes[$k])</div>" }
$html = "<!doctype html><html lang='es'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>Panel de uso · Multi-IA</title><style>$css</style></head><body><main>$cuerpo</main><script type='application/json' id='extra'>$extraJson</script><script>$js</script><script>$js2</script><script>$js3</script></body></html>"
[IO.File]::WriteAllText($Salida, $html, (New-Object Text.UTF8Encoding($false)))
Write-Output $Salida
exit 0
