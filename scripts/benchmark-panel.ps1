# Benchmark reproducible del RENDER del panel (compacto/expandido, historial corto/extendido, carga inicial, render, actualizacion) + CPU y RAM del proceso que lo ejecuta.
#   benchmark-panel.ps1 [-Raiz <carpeta del plugin>] [-Etiqueta dev] [-Corridas 3] [-N 8] [-Claude <ruta a claude.exe>] [-Salida archivo.json]
# Copia el plugin a una carpeta temporal (no toca el original), le agrega bench\bench-panel.src.tsx como prueba y corre `claude plugin test`. Mide dentro del motor de pruebas de Claude Code (monta el Pane real
# con datos sembrados): sirve para comparar versiones y modos entre si, NO es el tiempo de pintado de pixeles de la app.
param([string]$Raiz = '', [string]$Etiqueta = 'dev', [int]$Corridas = 3, [int]$N = 8, [string]$Claude = '', [string]$Salida = '')
$ErrorActionPreference = 'Stop'
$aqui = Split-Path -Parent $MyInvocation.MyCommand.Path
$dev = Split-Path -Parent $aqui
if (-not $Raiz) { $Raiz = $dev }
if (-not $Claude) {
  $c = Get-Command claude -ErrorAction SilentlyContinue
  if ($c) { $Claude = $c.Source } else { $Claude = (Get-ChildItem "$env:LOCALAPPDATA\Claude-Data" -Recurse -Filter claude.exe -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName }
}
if (-not $Claude -or -not (Test-Path $Claude)) { Write-Host 'No encuentro claude.exe (usa -Claude <ruta>).'; exit 2 }
$fuente = Join-Path $dev 'bench\bench-panel.src.tsx'
$todas = @()
foreach ($k in 1..$Corridas) {
  $tmp = Join-Path $env:TEMP ('benchpanel-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Force "$tmp\hooks", "$tmp\.claude-plugin" | Out-Null
  Copy-Item (Join-Path $Raiz '.claude-plugin\plugin.json') "$tmp\.claude-plugin\" -Force
  Copy-Item (Join-Path $Raiz 'hooks\hooks.json'), (Join-Path $Raiz 'hooks\register.tsx') "$tmp\hooks\" -Force
  Copy-Item $fuente "$tmp\hooks\bench.test.tsx" -Force
  $env:BENCH_N = "$N"
  $out = Join-Path $tmp 'salida.txt'
  $psi = Start-Process -FilePath $Claude -ArgumentList @('plugin', 'test', $tmp) -WorkingDirectory $tmp -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError (Join-Path $tmp 'err.txt')
  # CPU/RAM de todo el arbol (proceso padre + hijos que ejecutan cada archivo de prueba), muestreado cada 100 ms
  $pico = 0; $cpuMax = 0; $t0 = Get-Date
  while (-not $psi.HasExited) {
    $ids = @($psi.Id) + @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($psi.Id)" -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessId })
    $ws = 0; $cpu = 0
    foreach ($id in $ids) { try { $p = Get-Process -Id $id -ErrorAction Stop; $ws += $p.WorkingSet64; $cpu += $p.TotalProcessorTime.TotalMilliseconds } catch { } }
    if ($ws -gt $pico) { $pico = $ws }; if ($cpu -gt $cpuMax) { $cpuMax = $cpu }
    Start-Sleep -Milliseconds 100
  }
  $dur = ((Get-Date) - $t0).TotalSeconds
  $txt = (Get-Content $out -Encoding UTF8 -Raw) + (Get-Content (Join-Path $tmp 'err.txt') -Encoding UTF8 -Raw)
  $casos = @([regex]::Matches($txt, 'BENCH (\{.*\})') | ForEach-Object { $_.Groups[1].Value | ConvertFrom-Json })
  $fallas = ([regex]::Matches($txt, "(fail)")).Count
  if ($fallas) { ($txt -split "`n" | Where-Object { $_ -match "(fail)|Error|timed out" } | Select-Object -First 8) | ForEach-Object { Write-Host "  ! $_" } }
  $todas += [pscustomobject]@{ corrida = $k; duracion_s = [math]::Round($dur, 1); ram_pico_arbol_mb = [math]::Round($pico / 1MB); cpu_arbol_ms = [math]::Round($cpuMax); fallas = $fallas; casos = $casos }
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
# Agregado por caso: mediana entre corridas de cada metrica (la mediana de cada corrida ya es mediana de N montajes)
$med = { param($v) $s = @($v | Sort-Object); if ($s.Count) { $s[[int][math]::Floor(($s.Count - 1) / 2)] } else { $null } }
$nombres = @($todas | ForEach-Object { $_.casos } | ForEach-Object { $_.caso } | Select-Object -Unique)
$resumen = foreach ($nom in $nombres) {
  $f = @($todas | ForEach-Object { $_.casos } | Where-Object { $_.caso -eq $nom })
  [ordered]@{ caso = $nom; corridas = $f.Count; eventos = $f[0].eventos
    carga_inicial_ms = & $med ($f.carga_inicial_ms); render_mediana_ms = & $med ($f.render_mediana_ms); render_p95_ms = & $med ($f.render_p95_ms)
    actualizacion_mediana_ms = & $med ($f.actualizacion_mediana_ms); actualizacion_p95_ms = & $med ($f.actualizacion_p95_ms) }
}
$o = [ordered]@{ etiqueta = $Etiqueta; raiz = $Raiz; claude = $Claude; fecha = (Get-Date).ToString('s'); equipo = $env:COMPUTERNAME; n_montajes_por_caso = $N; corridas = $Corridas
  ram_pico_arbol_mb = @($todas.ram_pico_arbol_mb); cpu_arbol_ms = @($todas.cpu_arbol_ms); duracion_s = @($todas.duracion_s); fallas = @($todas.fallas); resumen = @($resumen); crudo = $todas }
$j = $o | ConvertTo-Json -Depth 8
if ($Salida) { [IO.File]::WriteAllText($Salida, $j, (New-Object Text.UTF8Encoding($false))) }
$resumen | ForEach-Object { '{0,-62} carga {1,7} ms · render {2,7} ms (p95 {3,7}) · actualiz. {4,7} ms (p95 {5,7})' -f $_.caso, $_.carga_inicial_ms, $_.render_mediana_ms, $_.render_p95_ms, $_.actualizacion_mediana_ms, $_.actualizacion_p95_ms }
"RAM pico del arbol (MB) por corrida: $($todas.ram_pico_arbol_mb -join ', ') · CPU acumulada (ms): $($todas.cpu_arbol_ms -join ', ') · duracion (s): $($todas.duracion_s -join ', ') · fallas: $($todas.fallas -join ', ')"
exit 0
