# Cupo y gasto de todas las IAs, lo mas exacto que se puede leer, en texto:
#   Cuentas: si cada IA tiene la sesion iniciada (cada una se loguea por separado).
#   General: todas las ventanas (5 h y semanal) lado a lado, la mas ajustada y el promedio.
#   Codex y Antigravity: EN VIVO. Claude: % del plan desde la linea de estado (o foto de get_usage) + tokens EXACTOS de tus transcripts.
param([switch]$Corto, [switch]$Json, [switch]$Forzar)   # -Corto: una linea por IA (lo que Claude debe usar: cada linea que entra a su contexto se relee en cada mensaje)
. (Join-Path $PSScriptRoot '_comun.ps1')

# Cache de -Json: consultar Codex y Antigravity tarda ~11 s, asi que se reusa hasta 45 s (o hasta que se pase alguna hora de reinicio).
$cacheArchivo = Join-Path $script:DatosDir 'limites-cache.json'
# Devuelve la cache tal cual con su edad en segundos (cache_seg) para que el panel no la tome por recien leida.
function Salida-Cache {
    $edad = [int][math]::Max(0, ((Get-Date) - (Get-Item -LiteralPath $cacheArchivo).LastWriteTime).TotalSeconds)
    $t = (Get-Content -LiteralPath $cacheArchivo -Raw -Encoding UTF8).Trim()
    if ($t.StartsWith('{')) { '{"cache_seg":' + $edad + ',' + $t.Substring(1) } else { $t }
}
function Cache-Vigente {
    param([int]$MaxSeg)
    if (-not (Test-Path -LiteralPath $cacheArchivo)) { return $false }
    if (((Get-Date) - (Get-Item -LiteralPath $cacheArchivo).LastWriteTime).TotalSeconds -ge $MaxSeg) { return $false }
    try {
        foreach ($t in ((Get-Content -LiteralPath $cacheArchivo -Raw -Encoding UTF8) | ConvertFrom-Json).tarjetas) { foreach ($w in $t.ventanas) { if ($w.reinicia -and ([datetime]$w.reinicia).ToUniversalTime() -lt (Get-Date).ToUniversalTime()) { return $false } } }
    } catch { return $false }
    $true
}
if ($Json -and -not $Forzar -and (Cache-Vigente 45)) { Salida-Cache; exit 0 }

# 3.4.0 (HooksError «aborted: still running»): el panel le da 45 s a este script, pero agy podia esperar 45 s (+ cierre forzado) y Codex 40 s,
# en serie: el motor mataba a PowerShell y se perdia TODA la lectura. En -Json las consultas en vivo comparten un presupuesto de 28 s
# (agy hasta 18 s, cada cuenta de Codex hasta 12 s) y un solo proceso a la vez consulta en vivo (candado entre sesiones de Claude).
$mutex = $null; $tengoCandado = $false
if ($Json) {
    $mutex = New-Object Threading.Mutex($false, ('Local\MultiIA-limites-' + ($script:DatosDir.ToLowerInvariant() -replace '[^a-z0-9]', '_')))
    $tomar = { param([int]$ms) try { $mutex.WaitOne($ms) } catch { $ex = $_.Exception; while ($ex -and -not ($ex -is [Threading.AbandonedMutexException])) { $ex = $ex.InnerException }; [bool]$ex } }
    $tengoCandado = & $tomar 0
    if (-not $tengoCandado) {
        # Otra lectura en vivo en curso: no se duplica la consulta; se espera a que termine (dura menos de 38 s) y se usa lo que escribio.
        $esperaDesde = Get-Date
        $tengoCandado = & $tomar 38000
        $nueva = (Test-Path -LiteralPath $cacheArchivo) -and ((Get-Item -LiteralPath $cacheArchivo).LastWriteTime -ge $esperaDesde.AddSeconds(-1))
        if ($nueva -or (-not $tengoCandado -and (Test-Path -LiteralPath $cacheArchivo))) {
            if ($tengoCandado) { $mutex.ReleaseMutex() }
            Salida-Cache; exit 0
        }
    }
}

$cfg = Get-Config
$inicioLectura = Get-Date
$restan = { [int](28 - ((Get-Date) - $inicioLectura).TotalSeconds) }
$ag = if ($Json) { Get-CupoAgy -Segundos 18 } else { Get-CupoAgy }
$motivoAgy = $script:MotivoCupoAgy
$codexCupo = [ordered]@{}   # nombre de cuenta -> cupo en vivo (puede haber mas de una cuenta de Codex)
$motivoCodex = @{}
foreach ($c in (Get-CuentasActivas $cfg 'codex')) {
    $nc = Get-NombreCuenta $cfg $c
    if (-not $Json) { $codexCupo[$nc] = Get-CupoCodex -CodexHome $c.home; continue }
    $r = & $restan
    if ($r -lt 4) { $codexCupo[$nc] = $null; $motivoCodex[$nc] = 'sin tiempo en este ciclo'; continue }
    $codexCupo[$nc] = Get-CupoCodex -CodexHome $c.home -Segundos ([math]::Min(12, $r))
    if (-not $codexCupo[$nc]) { $motivoCodex[$nc] = $(if (Find-CodexExe) { 'no respondió' } else { 'no instalado' }) }
}
$msgs = Get-MensajesClaude; $uso = Get-Uso
$filas = @(Get-CupoGeneral -Codex $codexCupo -Agy $ag)

if ($Json) {
    # Para el panel dentro de Claude: una tarjeta por IA/cuenta con sus ventanas (usado %, reinicio ISO UTC).
    $tarjetas = @(foreach ($g in ($filas | Group-Object ia)) {
        [ordered]@{ nombre = $g.Name; ventanas = @(@($g.Group) | Sort-Object { if ($_.ventana -eq '5 h') { 0 } else { 1 } } | ForEach-Object { [ordered]@{ v = $_.ventana; usado = [int]$_.usado; reinicia = $_.reinicia; origen = $_.origen } }) }
    })
    # 3.4.0: cada ventana leida en vivo lleva la hora de lectura (leido, UTC). Si un proveedor no respondio, se muestra su ULTIMA
    # lectura buena con la edad a la vista (nunca como «en vivo»), solo si su ventana sigue vigente y tiene menos de 6 h. Sin eso, no se muestra.
    $ahora = (Get-Date).ToUniversalTime()
    foreach ($tj in $tarjetas) { foreach ($w in $tj.ventanas) { if ($w.origen -eq 'en vivo') { $w.leido = $ahora.ToString('o') } } }
    $previa = $null
    if (Test-Path -LiteralPath $cacheArchivo) { try { $previa = (Get-Content -LiteralPath $cacheArchivo -Raw -Encoding UTF8) | ConvertFrom-Json; $mtimePrevia = (Get-Item -LiteralPath $cacheArchivo).LastWriteTime.ToUniversalTime() } catch { $previa = $null } }
    $respaldo = {
        param([scriptblock]$EsDelProveedor, [string]$Motivo)
        foreach ($pt in @($previa.tarjetas | Where-Object { $_ -and (& $EsDelProveedor $_.nombre) })) {
            $vs = @(foreach ($w in @($pt.ventanas)) {
                $leido = if ($w.leido) { ([datetime]$w.leido).ToUniversalTime() } else { $mtimePrevia }
                $edadMin = ($ahora - $leido).TotalMinutes
                $vigente = -not $w.reinicia -or ([datetime]$w.reinicia).ToUniversalTime() -gt $ahora
                if ($vigente -and $edadMin -lt 360) {
                    $txtEdad = if ($edadMin -lt 1) { 'menos de 1 min' } elseif ($edadMin -lt 60) { '{0} min' -f [int]$edadMin } else { '{0:N1} h' -f ($edadMin / 60) }
                    [ordered]@{ v = $w.v; usado = [int]$w.usado; reinicia = $w.reinicia; origen = "última lectura hace $txtEdad · $Motivo"; leido = $leido.ToString('o') }
                }
            })
            if ($vs.Count) { [ordered]@{ nombre = $pt.nombre; ventanas = $vs } }
        }
    }
    if ($previa) {
        if (-not @($tarjetas | Where-Object { $_.nombre -like 'Antigravity*' }) -and $motivoAgy -and $motivoAgy -ne 'no instalado') {
            $tarjetas += @(& $respaldo { param($n) $n -like 'Antigravity*' } "agy: $motivoAgy")
        }
        foreach ($nc in @($motivoCodex.Keys)) {
            if ($motivoCodex[$nc] -ne 'no instalado' -and -not @($tarjetas | Where-Object { $_.nombre -eq $nc })) {
                $tarjetas += @(& $respaldo ([scriptblock]::Create("param(`$n) `$n -eq '$($nc -replace "'", "''")'")) "Codex: $($motivoCodex[$nc])")
            }
        }
    }
    foreach ($tj in @($tarjetas | Where-Object { $_.nombre -eq 'Claude' })) {   # sin ventana de 5 h activa (inactivo desde hace horas) = 0 %
        if (-not @($tj.ventanas | Where-Object { $_.v -eq '5 h' })) { $tj.ventanas = @([ordered]@{ v = '5 h'; usado = 0; reinicia = $null; origen = 'sin ventana activa' }) + @($tj.ventanas) }
    }
    $top = @(Get-SesionesClaude $msgs) | Select-Object -First 1
    $salidaJson = [ordered]@{
        calidad = $cfg.calidad; manual = $cfg.manual; claude_costo = [long](Get-CostoClaude)
        modo = $cfg.modo; activas = @(Get-CuentasActivas $cfg).Count; max = $script:MaxCuentas; tarjetas = $tarjetas
        horas = @(Get-TokensPorHora $msgs $uso | ForEach-Object { [ordered]@{ h = $_.hora.Hour; c = [long]$_.claude; d = [long]$_.deleg; cx = [long]$_.codex; ag = [long]$_.agy } })
        deleg_total = [long](Sumar-Tok $uso); deleg_n = @($uso).Count
        pesada = $(if ($top) { [ordered]@{ msgs = $top.msgs; ctx = [int]$top.ctx_medio } } else { $null })
    } | ConvertTo-Json -Depth 6 -Compress
    try { Set-Content -LiteralPath $cacheArchivo -Value $salidaJson -Encoding UTF8 } catch { }
    if ($tengoCandado) { try { $mutex.ReleaseMutex() } catch { } }
    $salidaJson
    exit 0
}
if ($Corto) {
    "modo: {0} · cuentas delegadas activas: {1}/{2}" -f $cfg.modo, @(Get-CuentasActivas $cfg).Count, $script:MaxCuentas
    foreach ($g in ($filas | Group-Object ia)) { "{0}: {1}" -f $g.Name, ((@($g.Group) | ForEach-Object { "{0} {1}%" -f $_.ventana, $_.usado }) -join ' · ') }
    $top = @(Get-SesionesClaude $msgs) | Select-Object -First 1
    if ($top) { "sesión más pesada (7 d): {0} msgs, contexto medio {1:N0} tokens" -f $top.msgs, $top.ctx_medio }
    exit 0
}

"== Cuentas (cada IA debe tener su sesión iniciada)"
"  modo de elección de modelos: {0}   (cuentas delegadas activas: {1} de máximo {2})" -f $cfg.modo, @(Get-CuentasActivas $cfg).Count, $script:MaxCuentas
foreach ($c in Get-Cuentas -AgyCupo $ag) { "  {0,-12} {1}   {2}" -f $c.ia, $(if ($c.sesion) { 'SESIÓN OK ' } else { 'SIN SESIÓN' }), ($c.detalle ) }

"== CONSUMO GENERAL (todas las ventanas)"
foreach ($v in '5 h', 'Semanal') {
    "  --- ventana {0}" -f $v
    foreach ($f in ($filas | Where-Object { $_.ventana -eq $v })) { "  {0,-26} {1,3}% usado   reinicia {2,-14} ({3})" -f $f.ia, $f.usado, (Format-Falta $f.reinicia), $f.origen }
}
foreach ($r in Get-ResumenGeneral $filas) { "  >> {0}: más ajustada = {1}% ({2});  promedio entre {3} fuentes = {4}%" -f $r.ventana, $r.max, $r.maxIa, $r.n, $r.promedio }
if (-not (@($filas | Where-Object { $_.ia -eq 'Claude' }))) { "  (falta el % de Claude: se completa solo con la línea de estado o con una foto de get_usage)" }

"== Tokens por hora (últimas 24 h; Claude = entrada + caché escritura + salida; delegados = Codex + agy)"
$h = @(Get-TokensPorHora $msgs $uso)
foreach ($x in ($h | Select-Object -Last 8)) { "  {0:HH}:00   Claude {1,10:N0}   delegados {2,8:N0}" -f $x.hora, $x.claude, $x.deleg }
"  24 h: Claude {0:N0}   delegados {1:N0}" -f ($h | Measure-Object claude -Sum).Sum, ($h | Measure-Object deleg -Sum).Sum

"== Claude, tokens exactos (todas tus sesiones de Claude Code)"
foreach ($r in Get-ResumenClaude $msgs) {
    "  {0,-16} {1,5} msgs   entrada {2,9:N0}   caché escr. {3,11:N0}   caché lect. {4,13:N0}   salida {5,10:N0}" -f $r.ventana, $r.mensajes, $r.entrada, $r.cache_escritura, $r.cache_lectura, $r.salida
}
"== Delegaciones del plugin (tokens exactos por llamada)"
"  total: {0}   tokens: {1:N0}" -f @($uso).Count, (Sumar-Tok $uso)
exit 0
