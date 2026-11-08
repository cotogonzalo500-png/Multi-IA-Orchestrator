# Trazabilidad consola <-> ejecutor (V3): une, por ID de ejecucion, lo que muestra la consola (eventos) con la decision, el consumo registrado
# y el REGISTRO LOCAL del propio ejecutor (sesion de Codex / transcript de Antigravity), y dice si coinciden.
# Uso: trazabilidad.ps1 [-Id ej-HHmmss-xxxx] [-Ultimos 20] [-Todo] [-Json]
#   -Todo = incluye filas no productivas (test/simulacion/benchmark/desarrollo); por defecto solo reales.
# Veredicto por fila: coincide (tokens y modelo iguales al registro del ejecutor) | difiere | sin-registro-ejecutor (no hay sesion local que leer; NO se inventa).
param([string]$Id = '', [int]$Ultimos = 20, [switch]$Todo, [switch]$Json)
. (Join-Path $PSScriptRoot '_comun.ps1')
function Leer($n) { $f = Join-Path $script:DatosDir $n; if (Test-Path -LiteralPath $f) { @(Get-Content -LiteralPath $f -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { $_ }) } else { @() } }
$decTodas = @(Leer 'decisiones.jsonl' | Where-Object { $_.id -and $_.destino -in 'codex', 'agy' })
$dec = $decTodas
# v1.9.2: sin duplicados (un mismo id repetido en decisiones.jsonl cuenta UNA vez: gana el ultimo) y eventos desde el historico largo
# (eventos.jsonl se recorta a 200-300 lineas: una ejecucion vieja perderia su ciclo de vida) unidos sin repetir.
$ord = 0; $dec = @($dec | Group-Object id | ForEach-Object { $_.Group[-1] | Add-Member -NotePropertyName _ord -NotePropertyValue ($ord++) -Force -PassThru } | Sort-Object @{ e = { try { [datetime]::Parse($_.fecha) } catch { [datetime]::MinValue } } }, @{ e = { $_._ord } })   # orden estable: Sort-Object de PS 5.1 no lo es
$decTodas = $dec
$vistos = @{}; $eve = @(@(Leer 'eventos-hist.jsonl') + @(Leer 'eventos.jsonl') | Where-Object { $k = "$($_.fecha)|$($_.tipo)|$($_.id)|$($_.destino)"; if ($vistos.ContainsKey($k)) { $false } else { $vistos[$k] = 1; $true } })
$uso = @(Get-Uso -Todo | Where-Object { $_.fecha -and ($null -ne ($_.fecha -as [datetime])) })   # una fila de uso sin fecha valida no debe romper todo el informe
if (-not $Todo) { $dec = @($dec | Where-Object { Test-Productivo $_ }); $uso = @($uso | Where-Object { Test-Productivo $_ }) }   # 2.3.0 (auditoria Codex): una fila de prueba no se cruza con una ejecucion real
if ($Id) { $dec = @($dec | Where-Object { $_.id -eq $Id }) } else { $dec = @($dec | Select-Object -Last $Ultimos) }
$usoUsado = @{}   # cada fila de uso se asigna a UNA sola ejecucion

# Registro del ejecutor: tokens reales que quedaron en SU sesion local.
function Registro-Codex($tid) {
    # 1.9.2: busca tambien en el CODEX_HOME de cada cuenta configurada (las ejecuciones de cuentas secundarias guardan su sesion en su propia carpeta).
    $homes = @(); if ($env:CODEX_HOME) { $homes += $env:CODEX_HOME }; $homes += (Join-Path $env:USERPROFILE '.codex')
    try { foreach ($c in @((Get-Config).cuentas | Where-Object { $_.tipo -eq 'codex' -and $_.home })) { $homes += [string]$c.home } } catch { }
    $f = $null
    foreach ($h in ($homes | Select-Object -Unique)) {
        $f = Get-ChildItem -LiteralPath (Join-Path $h 'sessions') -Recurse -File -Filter "rollout-*-$tid.jsonl" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($f) { break }
    }
    if (-not $f) { return $null }
    $ti = 0L; $to = 0L
    foreach ($l in (Get-Content -LiteralPath $f.FullName -Encoding UTF8)) { if ($l -match '"type"\s*:\s*"token_usage_record"') { try { $e = $l | ConvertFrom-Json; $ti += [long]$e.payload.usage.input_tokens; $to += [long]$e.payload.usage.output_tokens } catch { } } }
    [ordered]@{ archivo = $f.FullName; tok_in = $ti; tok_out = $to }
}
function Registro-Agy($cid) {
    $t = Join-Path $env:USERPROFILE ".gemini\antigravity-cli\brain\$cid\.system_generated\logs\transcript.jsonl"
    if (-not (Test-Path -LiteralPath $t)) { return $null }
    $txt = Get-Content -LiteralPath $t -Raw -Encoding UTF8
    $ti = 0L; $to = 0L
    foreach ($m in [regex]::Matches($txt, '"input_tokens":(\d+)')) { $ti += [long]$m.Groups[1].Value }
    foreach ($m in [regex]::Matches($txt, '"output_tokens":(\d+)')) { $to += [long]$m.Groups[1].Value }
    [ordered]@{ archivo = $t; tok_in = $ti; tok_out = $to }
}

# Asignacion de uso en DOS pasadas: primero los cruces exactos por tokens (para ninguna ejecucion le robe la fila a otra por orden de proceso), despues el resto por cercania.
function Candidatos($d) { $fd = try { [datetime]::Parse($d.fecha) } catch { $null }; if ($fd) { @($uso | Where-Object { $_.destino -eq $d.destino -and $_.sesion -eq $d.sesion -and (-not $_.ej -or $_.ej -eq $d.id) -and ([datetime]::Parse($_.fecha)) -le $fd.AddSeconds(2) -and ([datetime]::Parse($_.fecha)) -ge $fd.AddSeconds(-([double]$d.seg + 15)) }) } else { @() } }
function ClaveUso($u) { "$($u.fecha)|$($u.destino)|$($u.sesion)|$($u.tok_in)|$($u.tok_out)|$($u.ej)" }
$asig = @{}
foreach ($pasada in 1, 2) {
    foreach ($d in $dec) {
        if ($asig.ContainsKey($d.id)) { continue }
        $cand = @(Candidatos $d | Where-Object { -not $usoUsado.ContainsKey((ClaveUso $_)) })
        $u = if ($pasada -eq 1) { @($cand | Where-Object { ([long]$_.tok_in + [long]$_.tok_out) -eq [long]$d.tok })[0] } else { @($cand)[-1] }
        if ($u) { $asig[$d.id] = $u; $usoUsado[(ClaveUso $u)] = 1 }
    }
}
$filas = foreach ($d in $dec) {
    $evs = @($eve | Where-Object { $_.id -eq $d.id } | Sort-Object fecha)
    $u = $asig[$d.id]   # Uso no lleva ID: se cruzo por proveedor + sesion + ventana de tiempo (ver arriba)
    # Recuperaciones: el reintento enlazado lleva id "<id>-r" y Alternativas "reintento de <id>". motor_inicial = el que fallo; motor_ejecutor = el que produjo el resultado.
    $origId = if ($d.id -match '^(.+)-r$') { $Matches[1] } elseif ("$($d.alternativas)" -match 'reintento de (\S+)') { $Matches[1] } else { '' }
    $orig = if ($origId) { @($decTodas | Where-Object { $_.id -eq $origId })[0] } else { $null }
    $recId = "$($d.id)-r"; $rec = @($decTodas | Where-Object { $_.id -eq $recId })[0]
    $motorInicial = if ($orig) { $orig.destino } elseif ($origId) { 'desconocido' } else { $d.destino }
    $reg = if ($d.ejecutor_id) { if ($d.destino -eq 'codex') { Registro-Codex $d.ejecutor_id } else { Registro-Agy $d.ejecutor_id } } else { $null }
    $veredicto = 'sin-registro-ejecutor'; $dif = @()
    if ($reg) {
        $tokReg = $reg.tok_in + $reg.tok_out
        if ($u -and ([long]$u.tok_in + [long]$u.tok_out) -ne $tokReg) { $dif += "tokens consola/uso $([long]$u.tok_in + [long]$u.tok_out) != ejecutor $tokReg" }
        if ([long]$d.tok -gt 0 -and [long]$d.tok -ne $tokReg) { $dif += "tokens decision $([long]$d.tok) != ejecutor $tokReg" }
        if ($u -and $u.modelo_confirmado -and $d.modelo_verificado -and $u.modelo_confirmado -ne $d.modelo_verificado) { $dif += 'modelo uso != decision' }
        if (-not $u) { $dif += 'sin fila de uso para contrastar' }
        # 2.3.0 (auditoria Codex): tokens de uso desconocidos valen 0 al convertir; eso no puede dar «coincide».
        $usoSinDato = $u -and ((Get-EstadoTokens $u) -ne 'informado')
        if ($usoSinDato) { $dif += 'la fila de uso no informa tokens' }
        $veredicto = if (-not $u -or $usoSinDato) { 'incompleto' } elseif ($dif) { 'difiere' } else { 'coincide' }
    }
    [ordered]@{
        id = $d.id; recuperacion_de = $(if ($origId) { $origId } else { $null }); recuperada_por = $(if ($rec) { $recId } else { $null }); motor_inicial = $motorInicial; motor_ejecutor = $d.destino; fecha = $d.fecha; origen = $(if ($d.origen) { $d.origen } else { 'real' }); sesion = $d.sesion; ventana = $d.ventana; instancia = $d.instancia
        tarea = $d.tarea; proveedor = $d.destino; cuenta = $d.cuenta
        modelo_configurado = $d.modelo_pedido; modelo_confirmado = $d.modelo_verificado; modelo_fuente = $d.modelo_fuente
        estado = $d.resultado; error = $d.error; seg = $d.seg; tok_consola = [long]$d.tok; tok_uso = $(if ($u) { [long]$u.tok_in + [long]$u.tok_out } else { $null })
        eventos_consola = @($evs | ForEach-Object { $_.tipo }) -join ' > '
        ejecutor_id = $d.ejecutor_id; ejecutor_registro = $(if ($reg) { $reg.archivo } else { $null }); tok_ejecutor = $(if ($reg) { $reg.tok_in + $reg.tok_out } else { $null })
        veredicto = $veredicto; diferencias = $dif
    }
}
$filas = @($filas)
if ($Json) { '[' + (($filas | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 5 -Compress }) -join ',') + ']' } else {
    "TRAZABILIDAD consola <-> ejecutor ($($filas.Count) ejecuciones)"
    foreach ($f in $filas) { "{0} · {1} · {2} · {3} · conf:{4} · {5} tok · consola[{6}] · ejecutor:{7} · {8}" -f $f.id, $f.origen, $f.proveedor, $f.estado, $(if ($f.modelo_confirmado) { $f.modelo_confirmado } else { 'no verificable' }), $f.tok_consola, $f.eventos_consola, $(if ($f.ejecutor_id) { $f.ejecutor_id } else { '-' }), ($f.veredicto + $(if ($f.recuperacion_de) { " · recupera:$($f.recuperacion_de) (motor inicial $($f.motor_inicial))" } else { '' }))}
}
exit 0
