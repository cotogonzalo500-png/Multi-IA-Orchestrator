# Benchmark reproducible: mide los scripts de UNA raiz de plugin (dev o una version de la cache). Sin porcentajes inventados: solo tiempos medidos.
#   benchmark.ps1 -Raiz <carpeta del plugin> -Etiqueta 1.7.0-dev [-N 10] [-Salida archivo.json]
# Mide (ms, mediana y p95 de N corridas, cada una en un powershell nuevo): router (elegir.ps1) codigo/texto, registro de motores, consumo con historial chico y GRANDE (1500 filas de uso),
# 4 selecciones simultaneas (tiempo total), y RAM pico / CPU de una corrida de elegir. Usa una carpeta de datos temporal: no toca la memoria real.
param([Parameter(Mandatory)][string]$Raiz, [string]$Etiqueta = '', [int]$N = 10, [string]$Salida = '')
$sc = Join-Path $Raiz 'scripts'
$tmp = Join-Path $env:TEMP ('bench-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Force $tmp | Out-Null
$env:MULTIIA_DATOS = $tmp
function Run($archivo, $args2) { $sw = [Diagnostics.Stopwatch]::StartNew(); & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $sc $archivo) @args2 | Out-Null; $sw.Stop(); [math]::Round($sw.Elapsed.TotalMilliseconds) }
function Stat($nombre, $v) { $s = @($v | Sort-Object); [ordered]@{ prueba = $nombre; n = $s.Count; min = $s[0]; mediana = $s[[int][math]::Floor(($s.Count - 1) / 2)]; p95 = $s[[int][math]::Min($s.Count - 1, [math]::Ceiling($s.Count * 0.95) - 1)]; max = $s[-1] } }
$res = @()
$null = Run 'elegir.ps1' @('-Tarea', 'codigo')   # calentamiento (cache de disco)
$res += Stat 'router elegir.ps1 -Tarea codigo' (1..$N | ForEach-Object { Run 'elegir.ps1' @('-Tarea', 'codigo') })
$res += Stat 'router elegir.ps1 -Tarea texto' (1..$N | ForEach-Object { Run 'elegir.ps1' @('-Tarea', 'texto') })
$res += Stat 'motores.ps1 (registro de motores)' (1..([math]::Max(3, [int]($N / 2))) | ForEach-Object { Run 'motores.ps1' @() })
$res += Stat 'consumo.ps1 con historial vacio' (1..$N | ForEach-Object { Run 'consumo.ps1' @() })
# historial grande: 1500 filas de uso
$f = Join-Path $tmp 'uso.jsonl'; $rows = foreach ($i in 1..1500) { (@{ fecha = (Get-Date).AddMinutes(-$i).ToString('s'); destino = @('codex', 'agy')[$i % 2]; modelo = 'm'; esfuerzo = 'medium'; chars = 500; seg = 3.5; salida = 200; memoria = $false; tok_in = 800; tok_out = 200; modo = 'auto'; cuenta = ''; origen = 'real' } | ConvertTo-Json -Compress) }
[IO.File]::WriteAllLines($f, [string[]]$rows)
$res += Stat 'consumo.ps1 con 1500 filas de uso' (1..$N | ForEach-Object { Run 'consumo.ps1' @() })
# varias a la vez
$conc = foreach ($k in 1..5) { $sw = [Diagnostics.Stopwatch]::StartNew(); $jobs = 1..4 | ForEach-Object { Start-Process powershell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + (Join-Path $sc 'elegir.ps1') + '"'), '-Tarea', 'codigo') -WindowStyle Hidden -PassThru }; $jobs | Wait-Process; $sw.Stop(); [math]::Round($sw.Elapsed.TotalMilliseconds) }
$res += Stat '4 elegir.ps1 simultaneos (tiempo total)' $conc
# RAM pico / CPU de una corrida
$p = Start-Process powershell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + (Join-Path $sc 'elegir.ps1') + '"'), '-Tarea', 'codigo') -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $tmp 'o.txt')
$pico = 0; while (-not $p.HasExited) { try { $p.Refresh(); if ($p.WorkingSet64 -gt $pico) { $pico = $p.WorkingSet64 } } catch { }; Start-Sleep -Milliseconds 20 }
$cpu = try { [math]::Round($p.TotalProcessorTime.TotalMilliseconds) } catch { $null }
$o = [ordered]@{ etiqueta = $Etiqueta; raiz = $Raiz; fecha = (Get-Date).ToString('s'); equipo = $env:COMPUTERNAME; ps = $PSVersionTable.PSVersion.ToString(); resultados = $res; ram_pico_mb_elegir = [math]::Round($pico / 1MB, 1); cpu_ms_elegir = $cpu; nota = 'RAM pico muestreada cada 20 ms (puede subestimar); CPU = TotalProcessorTime del proceso.' }
$j = $o | ConvertTo-Json -Depth 5
if ($Salida) { Set-Content -LiteralPath $Salida -Value $j -Encoding UTF8 }
$j
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
exit 0
