# Monitor de conexiones de los motores (1.9.0): diagnostico MANUAL y de BAJO COSTO. No corre solo ni gasta cupo salvo que pidas -Probar.
#   .\conexiones.ps1                 estado con cache (instalacion, version, autenticacion, ultimo exito/error, latencia observada)
#   .\conexiones.ps1 -Forzar         ignora la cache de version/autenticacion y vuelve a consultar (sin gastar cupo)
#   .\conexiones.ps1 -Probar codex   tarea minima real ("Responde solo OK") al motor indicado (codex|agy|todos): GASTA un poco de cupo; es el unico modo que lo hace
#   .\conexiones.ps1 -Texto          salida legible en vez de JSON
# Estados: Conectado y verificado | Disponible sin prueba reciente | Autenticacion requerida | Limitado | Error | No instalado | Desconocido
# Cada campo lleva nivel de confiabilidad y fuente. Si no hay forma segura de saber algo (p. ej. login de agy sin gastar cupo) dice NO DISPONIBLE, no inventa.
param([switch]$Forzar, [ValidateSet('', 'codex', 'agy', 'todos')][string]$Probar = '', [switch]$Texto)
. (Join-Path $PSScriptRoot '_comun.ps1')
Initialize-Datos
$cacheArch = Join-Path $script:DatosDir 'conexiones.json'
$cache = @{}
if (Test-Path -LiteralPath $cacheArch) { try { $o = Get-Content -LiteralPath $cacheArch -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($p in $o.PSObject.Properties) { $cache[$p.Name] = $p.Value } } catch { $cache = @{} } }
$ahora = Get-Date
function Vigente($reg, [int]$ttlSeg) { [bool]($reg -and $reg.fecha -and (($ahora - [datetime]$reg.fecha).TotalSeconds -le $ttlSeg) -and -not $Forzar) }

function Get-ExeMotor([string]$id) {
    if ($id -eq 'codex') { return (Find-CodexExe) }
    return (Find-AgyExe)   # 2.3.1 (Codex #13): deteccion unica
}
# Ultimo exito / ultimo error REAL de un motor segun uso.jsonl (solo origen real; el diagnostico propio queda en la cache).
$uso = @(Get-Uso | Where-Object { $_.fecha })
function Get-Ultimos([string]$id) {
    $f = @($uso | Where-Object { $_.destino -eq $id })
    $ok = @($f | Where-Object { $_.salida -eq 0 } | Select-Object -Last 1)
    $er = @($f | Where-Object { $_.salida -ne 0 } | Select-Object -Last 1)
    $lat = @($f | Where-Object { $_.salida -eq 0 -and [double]$_.seg -gt 0 } | Select-Object -Last 5)
    [pscustomobject]@{ ok = $(if ($ok) { $ok[0] } else { $null }); err = $(if ($er) { $er[0] } else { $null }); lat = $lat }
}

# Sondeo minimo (solo con -Probar): usa los mismos adaptadores que una delegacion real, marcado origen=diagnostico (no entra en las estadisticas productivas).
function Invoke-Sondeo([string]$id) {
    $arg = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot "delegar-$id.ps1"), '-Prompt', 'Responde solo la palabra OK', '-Esfuerzo', 'low')
    if ($id -eq 'agy') { $arg += @('-Perfil', 'texto') }
    $prev = $env:MULTIIA_ORIGEN; $env:MULTIIA_ORIGEN = 'diagnostico'
    $t0 = Get-Date
    try { $r = Invoke-ConTimeout (Get-Command powershell.exe).Source $arg 150 } finally { $env:MULTIIA_ORIGEN = $prev }
    $seg = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
    if (-not $r) { return [ordered]@{ fecha = $ahora.ToString('s'); ok = $false; seg = $seg; valida = $false; clase = 'timeout'; causa = 'el sondeo supero 150 s' } }
    $txt = ([string]$r.salida + ' ' + [string]$r.error)
    $valida = ($r.codigo -eq 0 -and ([string]$r.salida) -match '(?i)\bOK\b')
    $c = if ($r.codigo -ne 0) { Get-ClaseError -Texto $txt -Salida $r.codigo } else { $null }
    [ordered]@{ fecha = (Get-Date).ToString('s'); ok = ($r.codigo -eq 0); seg = $seg; valida = $valida; clase = $(if ($c) { $c.clase } elseif (-not $valida) { 'respuesta-vacia' } else { '' }); causa = $(if ($c) { $c.causa } elseif (-not $valida) { 'respondio pero sin la palabra OK' } else { '' }) }
}

$motores = @()
foreach ($id in 'codex', 'agy') {
    $nombre = if ($id -eq 'codex') { 'Codex' } else { 'Antigravity' }
    $reg = if ($cache.ContainsKey($id) -and $cache[$id]) { $cache[$id] } else { [pscustomobject]@{} }
    $exe = Get-ExeMotor $id
    $nuevo = [ordered]@{}
    foreach ($p in $reg.PSObject.Properties) { $nuevo[$p.Name] = $p.Value }
    $ver = $null; $aut = $null
    if ($exe) {
        # Version: barata (--version, sin red ni cupo), cache 24 h.
        if (Vigente $reg.version 86400) { $ver = $reg.version } else {
            $r = Invoke-ConTimeout $exe @('--version') 20
            $ver = [ordered]@{ fecha = $ahora.ToString('s'); valor = $(if ($r -and $r.codigo -eq 0) { ([string]$r.salida).Trim() } else { $null }); error = $(if (-not $r) { 'timeout' } elseif ($r.codigo -ne 0) { 'salida ' + $r.codigo } else { '' }) }
            $nuevo.version = $ver
        }
        # Autenticacion: solo Codex tiene un comando local y gratuito (`codex login status`). agy no: no se inventa, se infiere de errores reales.
        if ($id -eq 'codex') {
            if (Vigente $reg.auth 3600) { $aut = $reg.auth } else {
                $r = Invoke-ConTimeout $exe @('login', 'status') 20
                $txt = if ($r) { (([string]$r.salida) + ' ' + ([string]$r.error)).Trim() } else { '' }
                $aut = [ordered]@{ fecha = $ahora.ToString('s'); valor = $(if (-not $r) { $null } elseif ($r.codigo -eq 0 -and $txt -match '(?i)logged in') { 'sesion iniciada' } elseif ($txt -match '(?i)not logged') { 'sin sesion' } else { $null }); texto = $(Hide-Secretos $(if ($txt.Length -gt 120) { $txt.Substring(0, 120) } else { $txt })) }
                $nuevo.auth = $aut
            }
        }
    }
    if ($Probar -in @($id, 'todos') -and $exe) { $nuevo.sondeo = Invoke-Sondeo $id }
    $sond = $nuevo.sondeo
    $u = Get-Ultimos $id

    # Ultimo exito/error: el mas reciente entre los reales (uso.jsonl) y el sondeo propio.
    $okF = @(); if ($u.ok) { $okF += [string]$u.ok.fecha }; if ($sond -and $sond.ok -and $sond.valida) { $okF += [string]$sond.fecha }
    $erF = @(); if ($u.err) { $erF += [string]$u.err.fecha }; if ($sond -and -not ($sond.ok -and $sond.valida)) { $erF += [string]$sond.fecha }
    $ultOk = if ($okF) { ($okF | Sort-Object { [datetime]$_ } | Select-Object -Last 1) } else { '' }
    $ultEr = if ($erF) { ($erF | Sort-Object { [datetime]$_ } | Select-Object -Last 1) } else { '' }
    $errClase = ''; $errCausa = ''
    if ($ultEr) { if ($sond -and [string]$sond.fecha -eq $ultEr) { $errClase = [string]$sond.clase; $errCausa = [string]$sond.causa } elseif ($u.err) { $errClase = [string]$u.err.clase; $errCausa = [string]$u.err.causa } }
    $errReciente = [bool]($ultEr -and ((-not $ultOk) -or ([datetime]$ultEr -gt [datetime]$ultOk)))
    $fr = Get-Frescura -Fecha $ultOk -Fuente 'sondeo'

    # Latencia: sondeo propio (medida, VERIFICADO) o media de los ultimos exitos reales (OBSERVADO: incluye arranque de la CLI y cola).
    $lat = if ($sond -and $sond.ok) { New-Dato -Valor $sond.seg -Unidad 's' -Nivel 'VERIFICADO' -Fuente 'sondeo minimo de conexiones.ps1' -Motor $id -Fecha ([string]$sond.fecha) -Metodo 'tiempo de pared de la tarea minima' }
           elseif ($u.lat.Count) { New-Dato -Valor ([math]::Round((($u.lat | Measure-Object seg -Average).Average), 1)) -Unidad 's' -Nivel 'OBSERVADO' -Fuente 'uso.jsonl (ultimas ejecuciones exitosas)' -Motor $id -Fecha ([string]$u.lat[-1].fecha) -Metodo 'media de seg de hasta 5 ejecuciones reales' }
           else { New-Dato -Valor $null -Unidad 's' -Motor $id -Fuente 'sin ejecuciones exitosas' }

    $estado = 'Desconocido'; $porque = ''
    if (-not $exe) { $estado = 'No instalado'; $porque = "no se encontro el ejecutable de $nombre" }
    elseif ($id -eq 'codex' -and $aut -and $aut.valor -eq 'sin sesion') { $estado = 'Autenticacion requerida'; $porque = 'codex login status: sin sesion' }
    elseif ($errReciente -and $errClase -eq 'autenticacion') { $estado = 'Autenticacion requerida'; $porque = "ultimo fallo real: $errCausa" }
    elseif ($errReciente -and $errClase -eq 'cuota') { $estado = 'Limitado'; $porque = "ultimo fallo real: $errCausa" }
    elseif ($errReciente) { $estado = 'Error'; $porque = "ultimo intento real fallo ($(if ($errClase) { $errClase } else { 'clase no registrada' })): $(if ($errCausa) { $errCausa } else { 'causa no registrada (registro anterior a 1.9.0)' })"; if ($ultEr) { $porque += " [$ultEr]" } }
    elseif ($ultOk -and $fr.estado -eq 'activo confirmado') { $estado = 'Conectado y verificado'; $porque = "exito real/sondeo hace $([math]::Round($fr.edad_seg / 60, 1)) min" }
    elseif ($ver -and $ver.valor) { $estado = 'Disponible sin prueba reciente'; $porque = $(if ($ultOk) { "ultimo exito hace $([math]::Round($fr.edad_seg / 3600, 1)) h" } else { 'instalado; nunca hubo una ejecucion exitosa registrada' }) }
    else { $porque = 'instalado pero --version no respondio' }

    $cache[$id] = [pscustomobject]$nuevo
    $motores += [ordered]@{
        id = $id; nombre = $nombre; estado = $estado; porque = $porque
        instalacion = New-Dato -Valor $exe -Nivel 'VERIFICADO' -Fuente 'busqueda del ejecutable en disco' -Motor $id -Fecha $ahora.ToString('s') -Metodo 'Test-Path'
        version = New-Dato -Valor $(if ($ver) { $ver.valor } else { $null }) -Nivel 'VERIFICADO' -Fuente "$id --version" -Motor $id -Fecha $(if ($ver) { [string]$ver.fecha } else { '' }) -Metodo 'comando local, sin cupo'
        autenticacion = $(if ($id -eq 'codex') { New-Dato -Valor $(if ($aut) { $aut.valor } else { $null }) -Nivel 'VERIFICADO' -Fuente 'codex login status' -Motor $id -Fecha $(if ($aut) { [string]$aut.fecha } else { '' }) -Metodo 'comando local, sin cupo' }
                          else { New-Dato -Valor $null -Fuente 'agy no tiene un comando de login gratuito; se infiere solo de errores reales' -Motor $id })
        latencia = $lat
        ultimo_exito = New-Dato -Valor $ultOk -Nivel 'VERIFICADO' -Fuente $(if ($sond -and [string]$sond.fecha -eq $ultOk) { 'sondeo minimo' } else { 'uso.jsonl (salida 0)' }) -Motor $id -Fecha $ultOk -Metodo 'registro de ejecucion'
        ultimo_error = [ordered]@{ fecha = $ultEr; clase = $errClase; causa = $errCausa; reciente = $errReciente }
        sondeo = $(if ($sond) { [ordered]@{ fecha = $sond.fecha; ok = $sond.ok; respuesta_valida = $sond.valida; seg = $sond.seg; clase = $sond.clase; causa = $sond.causa } } else { $null })
        frescura = $fr
    }
}
# Claude: sin CLI propia que consultar; solo la foto que guarda la sesion.
$snap = if (Test-Path -LiteralPath $script:ClaudeSnapshot) { try { Get-Content -LiteralPath $script:ClaudeSnapshot -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null } } else { $null }
$frC = Get-Frescura -Fecha $(if ($snap) { [string]$snap.tomado } else { '' }) -Fuente 'snapshot'
$motores = @([ordered]@{ id = 'claude'; nombre = 'Claude'
    estado = $(if (-not $snap) { 'Desconocido' } elseif ($frC.estado -eq 'activo confirmado') { 'Conectado y verificado' } else { 'Disponible sin prueba reciente' })
    porque = $(if ($snap) { "foto de la sesion (get_session) tomada $($snap.tomado)" } else { 'no hay foto de la sesion' })
    modelo = New-Dato -Valor $(if ($snap) { $snap.modelo } else { $null }) -Nivel 'VERIFICADO' -Fuente 'get_session' -Motor 'claude' -Fecha $(if ($snap) { [string]$snap.tomado } else { '' }) -Metodo 'foto de la sesion'
    frescura = $frC }) + $motores

try { Set-TextoAtomico $cacheArch ($cache | ConvertTo-Json -Depth 6) } catch { }   # 2.3.1 (Codex #9): atomica
$res = [ordered]@{ generado = $ahora.ToString('s'); nota = 'Diagnostico manual. Sin sondeo (-Probar) no se gasta cupo; lo que no se pudo comprobar figura NO DISPONIBLE.'; motores = $motores }
if ($Texto) {
    foreach ($m in $motores) {
        "{0,-12} {1,-32} {2}" -f $m.nombre, $m.estado, $m.porque
        if ($m.id -ne 'claude') { "{0,-12}   version {1} · auth {2} · latencia {3} {4} [{5}]" -f '', $(if ($m.version.valor) { $m.version.valor } else { 'NO DISPONIBLE' }), $(if ($m.autenticacion.valor) { $m.autenticacion.valor } else { 'NO DISPONIBLE' }), $(if ($null -ne $m.latencia.valor) { $m.latencia.valor } else { '-' }), $m.latencia.unidad, $m.latencia.nivel }
    }
} else { $res | ConvertTo-Json -Depth 8 }
exit 0
