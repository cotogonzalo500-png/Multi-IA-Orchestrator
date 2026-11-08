# Migracion 1.7.0: marca con origen='simulacion' (u otro) las ejecuciones NO productivas que ya estaban en los registros, SIN borrar nada.
# Hace respaldo de los .jsonl antes de tocar (carpeta migracion-origen-<fecha> dentro de los datos) y es idempotente (se puede correr varias veces).
# Uso: migrar-origen.ps1 [-Ids ej-111234-3d71,ej-112034-76fc] [-Origen simulacion] [-DryRun]
#   Cada id marca tambien su reintento <id>-r. Eventos y decisiones se marcan por id; resultados por id (o, si no tiene, por fecha+destino);
#   uso.jsonl no tiene id: se marca por ventana de tiempo de la cadena (inicio..ultimo evento + 2 s) y misma sesion.
param([string[]]$Ids = @('ej-111234-3d71', 'ej-112034-76fc'), [string]$Origen = 'simulacion', [switch]$DryRun)
. (Join-Path $PSScriptRoot '_comun.ps1')
Initialize-Datos
$todos = @(); foreach ($i in $Ids) { $todos += $i; $todos += "$i-r" }
function Leer($f) { if (Test-Path -LiteralPath $f) { @(Get-Content -LiteralPath $f -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { try { $_ | ConvertFrom-Json } catch { $null } } | Where-Object { $_ }) } else { @() } }
function Escribir($f, $filas) { Set-Content -LiteralPath $f -Value ($filas | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 }) -Encoding UTF8 }
function Marcar($o, $origen) { if ($o.PSObject.Properties['origen']) { $o.origen = $origen } else { $o | Add-Member -NotePropertyName origen -NotePropertyValue $origen }; $o }

$fe = Join-Path $script:DatosDir 'eventos.jsonl'; $fd = Join-Path $script:DatosDir 'decisiones.jsonl'
$fr = Join-Path $script:DatosDir 'resultados.jsonl'; $fu = $script:UsoArchivo
$ev = Leer $fe; $de = Leer $fd; $re = Leer $fr; $us = Leer $fu

$cadena = @($ev | Where-Object { $_.id -and $todos -contains $_.id })
$ventanas = @()
foreach ($i in $Ids) {
    $e = @($cadena | Where-Object { $_.id -eq $i -or $_.id -eq "$i-r" } | ForEach-Object { [datetime]$_.fecha } | Sort-Object)
    if ($e.Count) { $ventanas += [pscustomobject]@{ id = $i; desde = $e[0]; hasta = $e[-1].AddSeconds(2); sesion = [string]($cadena | Where-Object { $_.id -like "$i*" } | Select-Object -First 1).sesion } }
}
$n = [ordered]@{ eventos = 0; decisiones = 0; resultados = 0; uso = 0 }
foreach ($x in $ev) { if ($x.id -and $todos -contains $x.id -and [string]$x.origen -ne $Origen) { Marcar $x $Origen | Out-Null; $n.eventos++ } }
foreach ($x in $de) { if ($x.id -and $todos -contains $x.id -and [string]$x.origen -ne $Origen) { Marcar $x $Origen | Out-Null; $n.decisiones++ } }
foreach ($x in $re) {
    if ([string]$x.origen -eq $Origen) { continue }
    $porId = $x.id -and ($todos -contains $x.id)
    $porFecha = (-not $x.id) -and (@($ventanas | Where-Object { [datetime]$x.fecha -ge $_.desde -and [datetime]$x.fecha -le $_.hasta }).Count -gt 0)
    if ($porId -or $porFecha) { Marcar $x $Origen | Out-Null; $n.resultados++ }
}
foreach ($x in $us) {
    if ([string]$x.origen -eq $Origen) { continue }
    $f = [datetime]$x.fecha
    if (@($ventanas | Where-Object { $f -ge $_.desde -and $f -le $_.hasta -and ((-not $_.sesion) -or $x.sesion -eq $_.sesion) }).Count -gt 0) { Marcar $x $Origen | Out-Null; $n.uso++ }
}
"Cadenas simuladas: $($todos -join ', ')"
"A marcar como '$Origen': eventos $($n.eventos), decisiones $($n.decisiones), resultados $($n.resultados), uso $($n.uso)"
if ($DryRun) { 'DryRun: no se escribio nada.'; exit 0 }
if (($n.eventos + $n.decisiones + $n.resultados + $n.uso) -eq 0) { 'Nada que migrar (ya estaba hecho).'; exit 0 }
$resp = Join-Path $script:DatosDir ('migracion-origen-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force $resp | Out-Null
foreach ($f in @($fe, $fd, $fr, $fu)) { if (Test-Path -LiteralPath $f) { Copy-Item -LiteralPath $f -Destination $resp } }
"Respaldo previo: $resp"
# Guardia: si algun archivo tiene lineas ilegibles, reescribirlo las perderia -> se aborta sin tocar nada (el respaldo ya esta hecho).
foreach ($par in @(@($fe, $ev), @($fd, $de), @($fr, $re), @($fu, $us))) {
    if (Test-Path -LiteralPath $par[0]) {
        $crudas = @(Get-Content -LiteralPath $par[0] -Encoding UTF8 | Where-Object { $_.Trim() }).Count
        if ($crudas -ne @($par[1]).Count) { Write-Error "ABORTO: '$(Split-Path $par[0] -Leaf)' tiene $($crudas - @($par[1]).Count) linea(s) ilegible(s); reescribirlo las perderia. No se modifico nada."; exit 1 }
    }
}
Escribir $fe $ev; Escribir $fd $de; Escribir $fr $re; Escribir $fu $us
'Migracion hecha (sin borrar filas).'
exit 0
