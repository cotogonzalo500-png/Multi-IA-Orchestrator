# Benchmark Arena: el MISMO pedido a distintas calidades/motores, lado a lado, con medidas reales (segundos, tokens que informo la CLI, largo de la respuesta).
#   .\arena.ps1 -Tarea razonar -Prompt "..." [-Calidades economica,maxima] [-Archivo ruta1,ruta2] [-Carpeta ruta]
#   .\arena.ps1 -Ganador maxima [-Nota "por que"]      (anota TU veredicto sobre la ultima corrida: la unica "calidad" que se registra es la que juzga una persona)
#   .\arena.ps1 -Historial                             (corridas anteriores y cuantas veces gano cada calidad)
# No juzga la calidad de la respuesta por su cuenta: mide y muestra. Cada corrida queda en arena.jsonl. No usa cache (si no, no compararia nada).
param(
    [ValidateSet('texto', 'trivial', 'razonar', 'opinion', 'revision', 'contenido')][string]$Tarea, [string]$Prompt,
    [string[]]$Calidades = @('economica', 'maxima'), [string[]]$Archivo, [string]$Carpeta,
    [string]$Ganador, [string]$Nota = '', [switch]$Historial
)
. (Join-Path $PSScriptRoot '_comun.ps1')
Initialize-Datos
$arch = Join-Path $script:DatosDir 'arena.jsonl'
function Get-Corridas { if (Test-Path -LiteralPath $arch) { @(Get-Content -LiteralPath $arch -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() } }

if ($Historial) {
    $c = Get-Corridas
    if (-not $c) { Write-Output '(sin corridas todavia)'; exit 0 }
    foreach ($x in $c | Select-Object -Last 10) { Write-Output ("{0} · {1} · {2} · ganador: {3}" -f $x.fecha, $x.tarea, (($x.resultados | ForEach-Object { "$($_.calidad) $($_.seg)s" }) -join ' vs '), $(if ($x.ganador) { $x.ganador } else { '(sin veredicto)' })) }
    $c | Where-Object { $_.ganador } | Group-Object ganador | ForEach-Object { Write-Output ("{0}: gano {1} vez/veces" -f $_.Name, $_.Count) }
    exit 0
}
if ($Ganador) {
    $c = Get-Corridas
    if (-not $c) { Write-Output 'No hay corrida a la que ponerle veredicto.'; exit 2 }
    $u = $c[-1]
    if ($Ganador -notin @($u.resultados | ForEach-Object { $_.calidad })) { Write-Output "'$Ganador' no participo de la ultima corrida ($((@($u.resultados | ForEach-Object { $_.calidad })) -join ', '))."; exit 2 }
    $u | Add-Member -NotePropertyName ganador -NotePropertyValue $Ganador -Force
    $u | Add-Member -NotePropertyName nota -NotePropertyValue $Nota -Force
    $todas = @($c[0..($c.Count - 2)]) + $u
    $todas = @($todas | Where-Object { $_ })
    Set-Content -LiteralPath $arch -Value (($todas | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 }) -join "`n") -Encoding UTF8
    Write-Output "Veredicto anotado: gano '$Ganador'."
    exit 0
}
if (-not $Tarea -or -not $Prompt) { Write-Output 'Faltan -Tarea y -Prompt.'; exit 2 }

$delegador = if ($env:MULTIIA_DELEGAR) { $env:MULTIIA_DELEGAR } else { Join-Path $PSScriptRoot 'delegar.ps1' }
$Calidades = @($Calidades | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
$malas = @($Calidades | Where-Object { $_ -notin 'economica', 'equilibrada', 'maxima' })
if ($malas) { Write-Output "Calidad invalida: $($malas -join ', ')"; exit 2 }
$res = @()
foreach ($q in $Calidades) {
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $delegador, '-Tarea', $Tarea, '-Prompt', $Prompt, '-Calidad', $q, '-Forzar', '-SinCache')
    if ($Archivo) { $argv += @('-Archivo', ((@($Archivo | ForEach-Object { $_ -split ',' } | Where-Object { $_ } | ForEach-Object { $_.Trim() })) -join ',')) }
    if ($Carpeta) { $argv += @('-Carpeta', $Carpeta) }
    $antes = @(Get-Uso).Count
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-ConTimeout 'powershell.exe' $argv 900
    $sw.Stop()
    $nuevas = @(Get-Uso | Select-Object -Skip $antes)
    $cab = if ($r) { ($r.salida -split "`r?`n" | Select-Object -First 1) } else { '' }
    $cuerpo = if ($r) { ($r.salida -split "`r?`n" | Where-Object { $_ -notmatch '^\[(delegado|aviso|cache|alerta)' }) -join "`n" } else { '' }
    $res += [pscustomobject]@{ calidad = $q; ok = [bool]($r -and $r.codigo -eq 0); seg = [math]::Round($sw.Elapsed.TotalSeconds, 1); tokens = [long](Sumar-Tok $nuevas); chars = $cuerpo.Length; motor = $cab; respuesta = $cuerpo }
}
foreach ($x in $res) {
    Write-Output ("=== {0} · {1} · {2} s · {3} tokens informados{4} · {5} caracteres ===" -f $x.calidad.ToUpper(), $(if ($x.ok) { 'ok' } else { 'FALLO' }), $x.seg, $x.tokens, $(if ($x.tokens -eq 0) { ' (0 = la CLI no informo)' } else { '' }), $x.chars)
    if ($x.motor) { Write-Output $x.motor }
    Write-Output $x.respuesta
}
$reg = [pscustomobject]@{ fecha = (Get-Date).ToString('s'); tarea = $Tarea; prompt = (Hide-Secretos $Prompt.Substring(0, [math]::Min(200, $Prompt.Length)));   <#2.3.1 (Codex #10): sin secretos ni emails en el registro#> resultados = @($res | Select-Object calidad, ok, seg, tokens, chars, motor) }
Add-Content -LiteralPath $arch -Value ($reg | ConvertTo-Json -Compress -Depth 6) -Encoding UTF8
Write-Output "[arena: comparacion guardada. Cuando decidas cual respuesta fue mejor: arena.ps1 -Ganador <calidad>]"
if (@($res | Where-Object { -not $_.ok }).Count -gt 0) { exit 1 }
exit 0
