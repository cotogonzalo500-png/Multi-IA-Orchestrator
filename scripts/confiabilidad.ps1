# Confiabilidad de datos (1.9.0). Biblioteca: se carga con dot-source desde _comun.ps1. Regla: Multi-IA no muestra mas certeza de la que tiene.
# Niveles: VERIFICADO (lo informa el proveedor o un registro local ENLAZADO por id) / OBSERVADO (visto en un registro local sin enlace garantizado)
#          / ESTIMADO (calculo local, p. ej. ~4 caracteres por token) / NO DISPONIBLE (no hay dato; NUNCA se muestra como 0).
$script:Niveles = @('VERIFICADO', 'OBSERVADO', 'ESTIMADO', 'NO DISPONIBLE')
$script:RangoNivel = @{ 'VERIFICADO' = 3; 'OBSERVADO' = 2; 'ESTIMADO' = 1; 'NO DISPONIBLE' = 0 }

# Dato con procedencia. Sin valor => NO DISPONIBLE (valor $null), aunque quien llame pida otro nivel: un faltante no puede pasar por dato.
function New-Dato {
    param($Valor = $null, [string]$Unidad = '', [string]$Nivel = 'NO DISPONIBLE', [string]$Fuente = '', [string]$Motor = '', [string]$Modelo = '', [string]$IdChat = '', [string]$IdEjecucion = '', [string]$Fecha = '', [string]$Metodo = '')
    if ($script:Niveles -notcontains $Nivel) { throw "Nivel invalido '$Nivel'" }
    $falta = ($null -eq $Valor) -or (($Valor -is [string]) -and -not $Valor.Trim())
    if ($falta) { $Valor = $null; $Nivel = 'NO DISPONIBLE' }
    [ordered]@{ valor = $Valor; unidad = $Unidad; nivel = $Nivel; fuente = $Fuente; motor = $Motor; modelo = $Modelo; id_chat = $IdChat; id_ejecucion = $IdEjecucion; fecha = $Fecha; metodo = $Metodo; ultima_actualizacion = (Get-Date).ToString('s') }
}

# Nivel de una combinacion de datos: el MAS DEBIL de los que aportan; si falta alguno, es parcial y jamas VERIFICADO.
# Devuelve @{ nivel; parcial; completos; faltantes; mezcla }.
function Get-NivelAgregado {
    param([string[]]$Niveles)
    $n = @($Niveles | Where-Object { $_ })
    if (-not $n.Count) { return [ordered]@{ nivel = 'NO DISPONIBLE'; parcial = $false; completos = 0; faltantes = 0; mezcla = @() } }
    $falt = @($n | Where-Object { $_ -eq 'NO DISPONIBLE' }).Count
    $con = @($n | Where-Object { $_ -ne 'NO DISPONIBLE' })
    $niv = 'NO DISPONIBLE'
    if ($con.Count) { $niv = ($con | Sort-Object { $script:RangoNivel[$_] } | Select-Object -First 1) }
    $parcial = ($falt -gt 0)
    if ($parcial -and $niv -eq 'VERIFICADO') { $niv = 'OBSERVADO' }   # suma parcial: nunca se presenta como verificada
    [ordered]@{ nivel = $niv; parcial = $parcial; completos = $con.Count; faltantes = $falt; mezcla = @($n | Group-Object | ForEach-Object { "$($_.Name)=$($_.Count)" }) }
}
# El nivel solo puede BAJAR al combinar con otra evidencia; elevar OBSERVADO a VERIFICADO no esta permitido sin enlace por id (lo decide quien crea el dato, no una suma).
function Test-ElevacionPermitida { param([string]$De, [string]$A) return ($script:RangoNivel[$A] -le $script:RangoNivel[$De]) }

# Suma tokens de filas de uso SIN mezclar niveles: tokens que la CLI informo (VERIFICADO) vs filas sin dato (NO DISPONIBLE, no cuentan como 0 sino como faltante).
function Get-TokensConNivel {
    param($Filas)
    $f = @($Filas); $v = 0L; $sin = 0; $ver = 0
    # 1.9.1: cuenta como dato la fila 'informado' (incluido un cero VERIFICADO que informo la CLI); ausente/desconocido/fuente-no-disponible = faltante, jamas 0.
    foreach ($x in $f) { if ((Get-EstadoTokens $x) -eq 'informado') { $v += [long]$x.tok_in + [long]$x.tok_out; $ver++ } else { $sin++ } }
    $niv = if ($f.Count -eq 0) { 'NO DISPONIBLE' } elseif ($ver -eq 0) { 'NO DISPONIBLE' } elseif ($sin -gt 0) { 'OBSERVADO' } else { 'VERIFICADO' }
    [ordered]@{ valor = $(if ($ver -gt 0) { $v } else { $null }); unidad = 'tokens'; nivel = $niv; filas = $f.Count; filas_con_dato = $ver; filas_sin_dato = $sin; por_estado = (Get-ConteoEstadoTokens $f); parcial = ($sin -gt 0 -and $ver -gt 0)
        fuente = 'tok_in+tok_out que informo la CLI del proveedor (uso.jsonl)'; aclaracion = $(if ($sin -gt 0) { "$sin ejecucion(es) sin dato de tokens: el total es PARCIAL, no verificado" } else { '' }) }
}

# FRESCURA por fuente. La ausencia de eventos NO es inactividad: sin fecha => 'desconocido'.
#  activo confirmado  = hubo senal real dentro de la ventana de la fuente
#  ultimo observado   = hay senal, pero mas vieja que la ventana (no se sabe si sigue activo)
#  desactualizado     = senal muy vieja (> 6 ventanas)
#  desconocido        = sin senal
$script:VentanaFuenteSeg = @{ 'evento' = 120; 'proceso' = 30; 'cupo' = 900; 'version' = 86400; 'auth' = 3600; 'sondeo' = 1800; 'snapshot' = 600 }
function Get-Frescura {
    param([string]$Fecha, [string]$Fuente = 'evento', [datetime]$Ahora = (Get-Date))
    $v = if ($script:VentanaFuenteSeg.ContainsKey($Fuente)) { $script:VentanaFuenteSeg[$Fuente] } else { 300 }
    $d = [datetime]::MinValue
    if (-not $Fecha -or -not [datetime]::TryParse($Fecha, [ref]$d)) { return [ordered]@{ estado = 'desconocido'; edad_seg = $null; ventana_seg = $v; fuente = $Fuente } }
    $e = [int][math]::Max(0, ($Ahora - $d).TotalSeconds)
    $est = if ($e -le $v) { 'activo confirmado' } elseif ($e -le ($v * 6)) { 'ultimo observado' } else { 'desactualizado' }
    [ordered]@{ estado = $est; edad_seg = $e; ventana_seg = $v; fuente = $Fuente }
}

# --- 1.9.1: cero vs ausente (tokens de las ejecuciones delegadas) -------------------------------------------------------------
# Estados de un dato de tokens:
#   informado            = la CLI lo informo (incluye el CERO VERIFICADO: la CLI dijo 0 de verdad)
#   estimado             = calculo local (incluye el cero estimado)
#   ausente              = la ejecucion termino bien pero la CLI no informo tokens
#   desconocido          = la ejecucion fallo antes de informar: no se sabe cuanto consumio
#   fuente-no-disponible = el motor/CLI no expone tokens o no esta disponible
# Regla de compatibilidad (justificada): una fila ANTERIOR a 1.9.1 sin 'tok_estado' con tok_in+tok_out == 0 se lee como 'ausente' (antes se guardaba 0 cuando la CLI no informaba), nunca como cero verificado. Con valor > 0 se lee como 'informado'.
$script:EstadosToken = @('informado', 'estimado', 'ausente', 'desconocido', 'fuente-no-disponible')
function Get-EstadoTokens {
    param($Fila)
    $e = [string]$Fila.tok_estado
    if ($e -and $script:EstadosToken -contains $e) { return $e }
    $a = $Fila.tok_in; $b = $Fila.tok_out
    if (($null -ne $a -and "$a" -ne '') -or ($null -ne $b -and "$b" -ne '')) { if (([long]$a + [long]$b) -gt 0) { return 'informado' } }
    return 'ausente'
}
# Cuenta filas por estado de tokens (para exportaciones y diagnostico).
function Get-ConteoEstadoTokens {
    param($Filas)
    $h = [ordered]@{}; foreach ($s in $script:EstadosToken) { $h[$s] = 0 }
    foreach ($f in @($Filas)) { $h[(Get-EstadoTokens $f)]++ }
    $h
}
