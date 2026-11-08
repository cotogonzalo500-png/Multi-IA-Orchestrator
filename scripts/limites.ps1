# Cupo y gasto de todas las IAs, lo mas exacto que se puede leer, en texto:
#   Cuentas: si cada IA tiene la sesion iniciada (cada una se loguea por separado).
#   General: todas las ventanas (5 h y semanal) lado a lado, la mas ajustada y el promedio.
#   Codex y Antigravity: EN VIVO. Claude: % del plan desde la linea de estado (o foto de get_usage) + tokens EXACTOS de tus transcripts.
param([switch]$Corto, [switch]$Json, [switch]$Forzar)   # -Corto: una linea por IA (lo que Claude debe usar: cada linea que entra a su contexto se relee en cada mensaje)
. (Join-Path $PSScriptRoot '_comun.ps1')

# Cache de -Json: consultar Codex y Antigravity tarda ~11 s, asi que se reusa hasta 45 s (o hasta que se pase alguna hora de reinicio).
$cacheArchivo = Join-Path $script:DatosDir 'limites-cache.json'
if ($Json -and -not $Forzar -and (Test-Path -LiteralPath $cacheArchivo)) {
    $cf = Get-Item -LiteralPath $cacheArchivo
    if (((Get-Date) - $cf.LastWriteTime).TotalSeconds -lt 45) {
        $txt = Get-Content -LiteralPath $cacheArchivo -Raw -Encoding UTF8
        $vencida = $false
        try {
            foreach ($t in ($txt | ConvertFrom-Json).tarjetas) { foreach ($w in $t.ventanas) { if ($w.reinicia -and ([datetime]$w.reinicia).ToUniversalTime() -lt (Get-Date).ToUniversalTime()) { $vencida = $true } } }
        } catch { $vencida = $true }
        if (-not $vencida) { $txt.Trim(); exit 0 }
    }
}

$cfg = Get-Config
$ag = Get-CupoAgy
$codexCupo = [ordered]@{}   # nombre de cuenta -> cupo en vivo (puede haber mas de una cuenta de Codex)
foreach ($c in (Get-CuentasActivas $cfg 'codex')) { $codexCupo[(Get-NombreCuenta $cfg $c)] = Get-CupoCodex -CodexHome $c.home }
$msgs = Get-MensajesClaude; $uso = Get-Uso
$filas = @(Get-CupoGeneral -Codex $codexCupo -Agy $ag)

if ($Json) {
    # Para el panel dentro de Claude: una tarjeta por IA/cuenta con sus ventanas (usado %, reinicio ISO UTC).
    $tarjetas = @(foreach ($g in ($filas | Group-Object ia)) {
        [ordered]@{ nombre = $g.Name; ventanas = @(@($g.Group) | Sort-Object { if ($_.ventana -eq '5 h') { 0 } else { 1 } } | ForEach-Object { [ordered]@{ v = $_.ventana; usado = [int]$_.usado; reinicia = $_.reinicia; origen = $_.origen } }) }
    })
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
