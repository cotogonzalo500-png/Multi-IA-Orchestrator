# Exporta el historial de ejecuciones (el mismo que ve el panel) a CSV o JSON, con los mismos filtros y orden que la pantalla.
# Uso: exportar-historial.ps1 [-Formato csv|json|ambos] [-Q texto] [-Proveedor todo|codex|agy|claude] [-Estado todo|fin|error|curso|sin-delegar]
#                             [-Origen prod|todo] [-Orden nuevo|antiguo|tokens|duracion] [-Salida carpeta]
# Una fila por ejecucion (eventos unidos por ID), enriquecida con modelo confirmado y tokens del ejecutor (trazabilidad.ps1) cuando existen.
# Salida: una linea "OK <filas> filas <ruta>[ ; <ruta>]". CSV en UTF-8 con BOM (Excel) y comillas RFC 4180.
param(
    [ValidateSet('csv', 'json', 'ambos')][string]$Formato = 'ambos',
    [string]$Q = '', [string]$Proveedor = 'todo', [string]$Estado = 'todo', [string]$Origen = 'prod', [string]$Orden = 'nuevo', [string]$Salida = ''
)
. (Join-Path $PSScriptRoot '_comun.ps1')
$f = Join-Path $script:DatosDir 'eventos.jsonl'
$ev = if (Test-Path -LiteralPath $f) { @(Get-Content -LiteralPath $f -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { $_ }) } else { @() }

# Agrupar por ID (los eventos sin ID van sueltos); el ultimo valor no vacio de cada campo gana.
$mapa = [ordered]@{}; $n = 0
foreach ($e in $ev) {
    $n++; $k = if ($e.id) { [string]$e.id } else { "sin-id-$n" }
    if (-not $mapa.Contains($k)) { $mapa[$k] = [ordered]@{ id = [string]$e.id; fecha = $e.fecha; fin = $e.fecha; proveedor = $e.destino; est = $e.tipo; tarea = ''; modelo_pedido = ''; motivo = ''; tokens = 0L; seg = 0; confirmacion = ''; origen = 'real' } }
    $r = $mapa[$k]; $r.est = $e.tipo; $r.fin = $e.fecha
    if ($e.tarea) { $r.tarea = $e.tarea }; if ($e.detalle) { $r.modelo_pedido = $e.detalle }; if ($e.motivo) { $r.motivo = $e.motivo }
    if ($e.tok) { $r.tokens = [long]$e.tok }; if ($e.seg) { $r.seg = $e.seg }; if ($e.conf) { $r.confirmacion = $e.conf }; if ($e.origen) { $r.origen = [string]$e.origen }
}
$tr = @{}
try {
    $j = & (Join-Path $PSScriptRoot 'trazabilidad.ps1') -Json -Todo -Ultimos 100000 | Out-String
    if ($j.Trim()) { foreach ($t in @($j | ConvertFrom-Json | ForEach-Object { $_ })) { if ($t.id) { $tr[[string]$t.id] = $t } } }
} catch { }

$filas = foreach ($r in $mapa.Values) {
    $t = if ($r.id) { $tr[$r.id] } else { $null }
    $estN = switch ($r.est) { 'fin' { 'fin' } 'error' { 'error' } 'sin-delegar' { 'sin-delegar' } default { 'curso' } }
    [pscustomobject][ordered]@{
        id = $r.id; fecha = $r.fecha; fin = $r.fin; origen = $r.origen; proveedor = $r.proveedor; estado = $estN; tarea = $r.tarea
        modelo_pedido = $r.modelo_pedido; modelo_confirmado = $(if ($t -and $t.modelo_confirmado) { $t.modelo_confirmado } else { '' }); modelo_fuente = $(if ($t -and $t.modelo_fuente) { $t.modelo_fuente } else { '' })
        tokens = $r.tokens; segundos = $r.seg; confirmacion = $r.confirmacion; tok_ejecutor = $(if ($t -and $null -ne $t.tok_ejecutor) { $t.tok_ejecutor } else { '' }); veredicto = $(if ($t) { $t.veredicto } else { '' }); motivo = $r.motivo
    }
}
$filas = @($filas)
if ($Origen -eq 'prod') { $filas = @($filas | Where-Object { Test-Productivo $_ }) }
if ($Proveedor -ne 'todo') { $filas = @($filas | Where-Object { $_.proveedor -eq $Proveedor }) }
if ($Estado -ne 'todo') { $filas = @($filas | Where-Object { $_.estado -eq $Estado }) }
if ($Q) { $q = $Q.ToLower(); $filas = @($filas | Where-Object { (($_.id, $_.proveedor, $_.estado, $_.tarea, $_.modelo_pedido, $_.modelo_confirmado, $_.motivo, $_.origen) -join ' ').ToLower().Contains($q) }) }
$filas = switch ($Orden) {
    'antiguo' { @($filas | Sort-Object fecha) }
    'tokens' { @($filas | Sort-Object { [long]$_.tokens } -Descending) }
    'duracion' { @($filas | Sort-Object { [double]$_.segundos } -Descending) }
    default { @($filas | Sort-Object fecha -Descending) }
}
$filas = @($filas)

$dir = if ($Salida) { $Salida } else { Join-Path $script:DatosDir 'exportaciones' }
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'; $utf8 = New-Object System.Text.UTF8Encoding($true); $rutas = @()
if ($Formato -in 'csv', 'ambos') {
    $cols = @('id', 'fecha', 'fin', 'origen', 'proveedor', 'estado', 'tarea', 'modelo_pedido', 'modelo_confirmado', 'modelo_fuente', 'tokens', 'segundos', 'confirmacion', 'tok_ejecutor', 'veredicto', 'motivo')
    $esc = { param($v) $s = [string]$v; if ($s -match '^[=+\-@\t]' -and $s -notmatch '^-?\d+(\.\d+)?$') { $s = "'" + $s }; if ($s -match '[",\r\n]') { '"' + $s.Replace('"', '""') + '"' } else { $s } }
    $lineas = @($cols -join ',') + @($filas | ForEach-Object { $o = $_; ($cols | ForEach-Object { & $esc $o.$_ }) -join ',' })
    $p = Join-Path $dir "historial-$ts.csv"; [IO.File]::WriteAllText($p, ($lineas -join "`r`n") + "`r`n", $utf8); $rutas += $p
}
if ($Formato -in 'json', 'ambos') {
    $p = Join-Path $dir "historial-$ts.json"
    $js = '[' + (($filas | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 4 -Compress }) -join ',') + ']'
    [IO.File]::WriteAllText($p, $js, $utf8); $rutas += $p
}
"OK $($filas.Count) filas " + ($rutas -join ' ; ')
exit 0
