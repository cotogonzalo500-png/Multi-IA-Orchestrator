# Consultá el ahorro como estimacion: delegar tokens no prueba que los hayas ahorrado.
param([string]$Chat = '', [switch]$Texto)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_comun.ps1')

function Nueva-Metrica($Valor, [string]$Unidad, [string]$Nivel, [string]$Fuente, [string]$Metodo, $Fecha) {
    [ordered]@{ valor = $Valor; unidad = $Unidad; nivel = $Nivel; fuente = $Fuente; metodo = $Metodo; fecha = $Fecha }
}
function Ultima-Fecha($Filas) {
    $f = @($Filas | ForEach-Object { $_.fecha } | Where-Object { $_ } | Sort-Object)
    if ($f.Count) { return [string]$f[-1] }
    return $null
}
function Id-Chat($Fila) { if ($Fila.sesion) { [string]$Fila.sesion } else { 'sin-sesion' } }
function Es-Exito($Fila) { return ((Es-Numero $Fila.salida) -and [int]$Fila.salida -eq 0) }
function Es-Numero($Valor) {
    $n = 0.0
    return ($null -ne $Valor -and [string]$Valor -ne '' -and
        [double]::TryParse([string]$Valor, [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$n) -and
        -not [double]::IsNaN($n) -and -not [double]::IsInfinity($n) -and $n -ge 0)
}
function Leer-Costo {
    $ruta = Join-Path $script:DatosDir 'costo-claude.jsonl'
    if (Test-Path -LiteralPath $ruta) {
        $vistas = @{}   # 2.3.0 (auditoria Codex): una fila de costo repetida tal cual se cuenta una vez
        foreach ($linea in Get-Content -LiteralPath $ruta -Encoding UTF8) {
            if (-not (Test-LineaNueva $vistas $linea)) { continue }
            # No ocultes una fila rota: podria faltar costo y exagerar el ahorro.
            $fila = $linea | ConvertFrom-Json
            if ($fila -and (Test-Productivo $fila)) { $fila }
        }
    }
}

$uso = @(Get-Uso | Where-Object { Test-Productivo $_ })
$costo = @(Leer-Costo)
# 2.0.1: lectura INCREMENTAL con cache (antes -SinCache releia ~600 MB: ~27 s de los ~38 s). El cache vive bajo DatosDir (respeta MULTIIA_DATOS)
# y aplica la ventana real de 8 dias tambien a cada mensaje, como dice la nota de claude_reportado.
$mensajes = @(Get-MensajesClaude | Where-Object { Test-Productivo $_ })
$config = $null
$configRuta = Join-Path $script:DatosDir 'config.json'
if (Test-Path -LiteralPath $configRuta) {
    try { $config = Get-Content -LiteralPath $configRuta -Encoding UTF8 -Raw | ConvertFrom-Json }
    catch { Write-Warning 'config.json ilegible: costo economico no disponible' }
}
if ($Chat -eq 'actual') {
    $Chat = [string]$env:CLAUDE_CODE_SESSION_ID
    if (-not $Chat) { throw 'No hay CLAUDE_CODE_SESSION_ID para resolver -Chat actual.' }
}

function Resumen-Ahorro($Filas, $Costos, $Msgs) {
    $Filas = @($Filas); $Costos = @($Costos); $Msgs = @($Msgs)
    # 2.2.0 (Codex #5): correlacion por id de ejecucion (campo ej que pone delegar.ps1).
    #  - Una linea repetida identica (misma fecha/destino/chat/tokens/ej) se cuenta una vez.
    #  - '<id>-r' (recuperacion por cambio de motor) y '<id>-rev' (revision cruzada) son intentos de LA MISMA delegacion '<id>'.
    #  - Filas viejas sin ej: cada fila es su propia delegacion (no hay con que correlacionar).
    $vistas = @{}
    # Auditoria Codex 2.2.0: la clave incluye seg y tok_estado (dos intentos que solo difieren ahi no son la misma linea).
    $Filas = @($Filas | Where-Object { $k = "$($_.fecha)|$($_.destino)|$($_.sesion)|$($_.tok_in)|$($_.tok_out)|$($_.ej)|$($_.salida)|$($_.seg)|$($_.tok_estado)"; if ($vistas.ContainsKey($k)) { $false } else { $vistas[$k] = $true; $true } })
    $ejecuciones = @{}; $i = 0
    foreach ($f in $Filas) { $i++; $e = [string]$f.ej; $ejecuciones[$(if ($e) { $e -replace '-(r|rev)$', '' } else { "fila-$i" })] = $true }
    # Exito solo con salida 0 INFORMADA: [int]$null da 0 y contaria una salida ausente como exito.
    # Recuperadas: una por id '<id>-r' exitoso, no una por fila.
    $recuperadas = @($Filas | Where-Object { [string]$_.ej -match '-r$' -and (Es-Exito $_) } | ForEach-Object { [string]$_.ej } | Sort-Object -Unique).Count
    $fecha = Ultima-Fecha $Filas
    $cc = @($Costos | Where-Object { Es-Numero $_.tok })
    $estimado = Nueva-Metrica $null 'tokens' 'NO DISPONIBLE' 'costo-claude.jsonl' '~4 caracteres/token; subconjunto del reportado, NO se suma a el' (Ultima-Fecha $cc)
    if ($cc.Count) {
        $estimado.valor = [long](($cc | Measure-Object tok -Sum).Sum)
        $estimado.nivel = 'ESTIMADO'
    }
    # 2.2.0: parcial tambien si hay delegaciones sin fila de costo (el costo real de coordinar seria mayor y el ahorro quedaria inflado)
    $estimado.parcial = ($cc.Count -lt $Costos.Count) -or ($ejecuciones.Count -gt $Costos.Count)   # por delegacion (#5), no por intento
    # Auditoria Codex 2.2.0: desde que costo-claude.jsonl trae ej, se cruza por id (contar filas no ve una delegacion sin costo compensada por otra con dos).
    $conEj = @($cc | Where-Object { [string]$_.ej })
    if ($conEj.Count) {
        $desde = ($conEj | ForEach-Object { [string]$_.fecha } | Sort-Object | Select-Object -First 1)
        $conCosto = @{}; foreach ($c in $conEj) { $conCosto[([string]$c.ej -replace '-(r|rev)$', '')] = $true }
        $sinCosto = @($Filas | Where-Object { [string]$_.ej -and [string]$_.fecha -ge $desde -and -not $conCosto.ContainsKey(([string]$_.ej -replace '-(r|rev)$', '')) })
        if ($sinCosto.Count) { $estimado.parcial = $true }
    }
    $estimado.nota = 'costo-claude.jsonl no tiene filtro temporal (el reportado de Claude cubre 8 dias); delegaciones sin fila de costo vuelven parcial la estimacion y anulan el ahorro.'
    $real = Nueva-Metrica $null 'tokens' 'NO DISPONIBLE' 'transcripts locales de Claude Code, ultimos 8 dias' 'entrada + cache_escritura + cache_lectura + salida; deduplicado por id de mensaje' $null
    if ($Msgs.Count) {
        $suma = 0L
        foreach ($m in $Msgs) { $suma += $m.entrada + $m.cache_escritura + $m.cache_lectura + $m.salida }
        $real.valor = $suma; $real.nivel = 'VERIFICADO'
        $real.fecha = ($Msgs | Sort-Object t | Select-Object -Last 1).t.ToLocalTime().ToString('s')
    }
    $real.parcial = ($script:DiagTranscripts.descartadas -gt 0)
    if ($real.parcial -and $real.nivel -eq 'VERIFICADO') { $real.nivel = 'OBSERVADO' }   # 2.2.0: un dato parcial no es VERIFICADO (confiabilidad.ps1)
    $real.nota = 'Ventana de 8 dias; chats viejos o lineas descartadas pueden dejar el reportado incompleto.'

    $proveedor = [ordered]@{}; $salidas = [ordered]@{}; $ahorros = [ordered]@{}; $dinero = [ordered]@{}
    $valTokens = [ordered]@{}; $valSalida = [ordered]@{}; $valAhorro = [ordered]@{}; $valDinero = [ordered]@{}
    foreach ($p in 'codex', 'antigravity') {
        $u = @($Filas | Where-Object { $_.destino -eq $p -or ($p -eq 'antigravity' -and $_.destino -eq 'agy') })
        # Exigí ambos campos para un total CLI: no conviertas null en cero.
        $validas = @($u | Where-Object { (Get-EstadoTokens $_) -eq 'informado' -and (Es-Numero $_.tok_in) -and (Es-Numero $_.tok_out) })
        $t = Nueva-Metrica $null 'tokens' 'NO DISPONIBLE' 'uso.jsonl; CLI del proveedor' 'tok_in + tok_out informados; sin total entre proveedores' (Ultima-Fecha $validas)
        if ($validas.Count) {
            $t.valor = [long](($validas | Measure-Object tok_in -Sum).Sum) + [long](($validas | Measure-Object tok_out -Sum).Sum)
            $t.nivel = 'VERIFICADO'
        }
        $t.parcial = ($validas.Count -lt $u.Count); $t.filas = $u.Count; $t.filas_con_dato = $validas.Count
        $proveedor[$p] = $t; $valTokens[$p] = $t.valor
        # Salida util = solo intentos que terminaron bien (salida 0). Un intento fallido que luego se recupero gasto tokens (siguen en tokens_proveedor) pero no es trabajo entregado.
        $out = @($u | Where-Object { (Get-EstadoTokens $_) -eq 'informado' -and (Es-Numero $_.tok_out) -and (Es-Exito $_) })
        $s = Nueva-Metrica $null 'tokens' 'NO DISPONIBLE' 'uso.jsonl; tok_out informado de intentos exitosos' 'salida delegada observada por proveedor (sin intentos fallidos)' (Ultima-Fecha $out)
        if ($out.Count) { $s.valor = [long](($out | Measure-Object tok_out -Sum).Sum); $s.nivel = 'OBSERVADO' }
        $s.parcial = ($out.Count -lt $u.Count); $salidas[$p] = $s; $valSalida[$p] = $s.valor
        $a = Nueva-Metrica $null 'tokens' 'NO DISPONIBLE' 'uso.jsonl y costo-claude.jsonl' 'estimacion de ahorro potencial (no es cota ni garantia): salida delegada observada - costo de coordinacion estimado' (Ultima-Fecha (@($out) + @($cc)))
        $a.etiqueta = 'Ahorro no determinable'
        if ($null -ne $s.valor -and $null -ne $estimado.valor -and -not $estimado.parcial) {
            $a.valor = $s.valor - $estimado.valor; $a.nivel = 'ESTIMADO'
            $a.etiqueta = if ($a.valor -lt 0) { 'sin ahorro neto estimado' } else { 'ahorro potencial estimado' }
        }
        $a.parcial = $s.parcial
        $a.nota = 'Se descuenta TODO el costo del ambito a cada proveedor: no hay atribucion por proveedor en costo-claude.jsonl. No sumes estas estimaciones. No demuestra utilidad ni equivalencia entre tokenizadores.'
        $ahorros[$p] = $a; $valAhorro[$p] = $a.valor
        $d = Nueva-Metrica $null 'moneda configurada' 'NO DISPONIBLE' 'config.json; ahorro.precio_por_mtok del proveedor' 'Las suscripciones no exponen precio por token; sin precio configurado no se calcula' $t.fecha
        $precio = $config.ahorro.("precio_por_mtok_$p")
        $moneda = [string]$config.ahorro.precio_moneda
        if ((Es-Numero $precio) -and -not $moneda) { $d.nota = 'Hay precio configurado pero falta ahorro.precio_moneda (moneda): no se calcula costo sin moneda.' }
        elseif ((Es-Numero $precio) -and $null -ne $t.valor) {
            $d.moneda = $moneda; $d.precio_fuente = [string]$config.ahorro.precio_fuente; $d.precio_vigencia = [string]$config.ahorro.precio_vigencia
            $d.valor = [math]::Round($t.valor * [double]$precio / 1000000, 8); $d.nivel = 'ESTIMADO'
            $d.metodo = 'costo delegado = tokens CLI del proveedor / 1000000 * precio configurado; no es ahorro monetario'
        }
        $d.parcial = $t.parcial; $dinero[$p] = $d; $valDinero[$p] = $d.valor
    }
    function Paquete($Valores, $Detalle, $Unidad, $Nivel, $Fuente, $Metodo) {
        $hay = @($Valores.Values | Where-Object { $null -ne $_ }).Count -gt 0
        $v = if ($hay) { $Valores } else { $null }
        $n = if ($hay) { $Nivel } else { 'NO DISPONIBLE' }
        $r = Nueva-Metrica $v $Unidad $n $Fuente $Metodo $fecha
        $r.por_proveedor = $Detalle
        $r
    }
    $tok = Paquete $valTokens $proveedor 'tokens por proveedor' 'VERIFICADO' 'uso.jsonl' 'Suma solo dentro de cada proveedor; consulta parcial y filas_con_dato'
    $tok.parcial = @($proveedor.Values | Where-Object { $_.parcial }).Count -gt 0
    $pot = Paquete $valAhorro $ahorros 'tokens por proveedor' 'ESTIMADO' 'uso.jsonl y costo-claude.jsonl' 'estimacion de ahorro potencial (no es cota ni garantia): salida delegada observada - costo de coordinacion estimado'
    $pot.etiqueta = if ($null -eq $pot.valor) { 'Ahorro no determinable' } elseif (@($valAhorro.Values | Where-Object { $null -ne $_ -and $_ -lt 0 }).Count) { 'sin ahorro neto estimado' } else { 'ahorro potencial estimado' }
    $pot.parcial = @($ahorros.Values | Where-Object { $_.parcial }).Count -gt 0 -or $estimado.parcial   # auditoria Codex 2.2.0: -Texto mostraba el global sin PARCIAL
    $cargaValor = if ($Filas.Count) { [ordered]@{ delegaciones = $ejecuciones.Count; intentos = $Filas.Count; recuperadas = $recuperadas; tok_out = $valSalida } } else { $null }
    $carga = Nueva-Metrica $cargaValor 'delegaciones y tokens por proveedor' $(if ($Filas.Count) { 'OBSERVADO' } else { 'NO DISPONIBLE' }) 'uso.jsonl; solo Test-Productivo' 'una delegacion por id de ejecucion (los intentos -r/-rev cuentan dentro de su delegacion; filas sin id, una cada una); trabajo delegado NO es ahorro' $fecha
    $carga.nota = 'Trabajo delegado no equivale a ahorro: el ahorro esta en ahorro_potencial y es una estimacion.'
    $carga.por_proveedor = $salidas
    $seg = @($Filas | Where-Object { Es-Numero $_.seg })
    $tiempoValor = if ($seg.Count) { [ordered]@{ total = [math]::Round(($seg | Measure-Object seg -Sum).Sum, 3); medio = [math]::Round(($seg | Measure-Object seg -Average).Average, 3) } } else { $null }
    $tiempo = Nueva-Metrica $tiempoValor 'segundos' $(if ($seg.Count) { 'OBSERVADO' } else { 'NO DISPONIBLE' }) 'uso.jsonl; seg' 'suma de duraciones y media de filas con dato; no es tiempo ahorrado ni tiempo de reloj si hubo paralelismo' (Ultima-Fecha $seg)
    $tiempo.parcial = ($seg.Count -lt $Filas.Count)
    [ordered]@{
        tokens_proveedor = $tok; claude_reportado = $real; claude_estimado = $estimado
        carga_delegada = $carga; ahorro_potencial = $pot
        costo_economico = $(
            $ce = Paquete $valDinero $dinero 'moneda configurada por proveedor' 'ESTIMADO' 'config.json y uso.jsonl' 'costo delegado a precio configurado; no ahorro monetario; no se suman proveedores'
            $ce.parcial = @($dinero.Values | Where-Object { $_.parcial }).Count -gt 0   # 2.3.0 (auditoria Codex): -Texto perdia el PARCIAL del costo
            $ce)
        tiempo = $tiempo
    }
}

# 2.0.1: agrupar UNA vez por chat (antes cada chat releia todas las listas: O(chats x mensajes)).
function Agrupar-Por($Items, [scriptblock]$Clave) {
    $h = @{}
    foreach ($i in $Items) {
        $k = [string](& $Clave $i)
        if (-not $h.ContainsKey($k)) { $h[$k] = New-Object Collections.Generic.List[object] }
        $h[$k].Add($i)
    }
    $h
}
$usoPorChat = Agrupar-Por $uso { param($x) Id-Chat $x }
$costoPorChat = Agrupar-Por $costo { param($x) Id-Chat $x }
$msgPorChat = Agrupar-Por ($mensajes | Where-Object { $_.sesion_completa }) { param($x) $x.sesion_completa }
$vacio = @()
$ids = @{}
foreach ($k in $usoPorChat.Keys) { $ids[$k] = $true }
foreach ($k in $costoPorChat.Keys) { $ids[$k] = $true }
foreach ($k in $msgPorChat.Keys) { $ids[$k] = $true }
if ($Chat) { $ids = @{ $Chat = $true } }
$chats = @(foreach ($id in ($ids.Keys | Sort-Object)) {
    # Variables intermedias: pasar un $(if ...) vacio entregaria $null (y @($null) cuenta 1).
    $gu = $vacio; if ($usoPorChat.ContainsKey($id)) { $gu = $usoPorChat[$id].ToArray() }
    $gc = $vacio; if ($costoPorChat.ContainsKey($id)) { $gc = $costoPorChat[$id].ToArray() }
    $gm = $vacio; if ($msgPorChat.ContainsKey($id)) { $gm = $msgPorChat[$id].ToArray() }
    $r = Resumen-Ahorro $gu $gc $gm
    $r.id_chat = $id
    $r
})
$resultado = [ordered]@{
    generado = (Get-Date).ToString('s')
    metodologia = 'Delegar no equivale a ahorrar. Estimacion de ahorro potencial por proveedor (no es una cota): salida informada menos todo el costo de coordinacion estimado del ambito; el tokenizador de cada proveedor y el de Claude no son equivalentes. No se suman proveedores ni Claude reportado y estimado.'
    global = (Resumen-Ahorro $uso $costo $mensajes)
    chats = $chats
    diagnostico_transcripts = $script:DiagTranscripts
}
if ($Texto) {
    $resultado.metodologia
    $ambitos = @([pscustomobject]@{ id = 'global'; datos = $resultado.global })
    $ambitos += @($chats | ForEach-Object { [pscustomobject]@{ id = $_.id_chat; datos = $_ } })
    foreach ($ambito in $ambitos) {
        "Ambito: $($ambito.id)"
        foreach ($nombre in $resultado.global.Keys) {
            $metrica = $ambito.datos[$nombre]
            $valor = if ($null -eq $metrica.valor) { 'NO DISPONIBLE' } else { $metrica.valor | ConvertTo-Json -Depth 6 -Compress }
            "  ${nombre}: $valor [$($metrica.nivel)] $($metrica.etiqueta)$(if ($metrica.parcial) { ' · PARCIAL' }) · fuente: $($metrica.fuente) · metodo: $($metrica.metodo)$(if ($metrica.nota) { ' · nota: ' + $metrica.nota })"
        }
    }
} else { $resultado | ConvertTo-Json -Depth 12 -Compress }
