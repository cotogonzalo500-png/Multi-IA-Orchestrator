# Capturas fieles del panel REAL: monta hooks\arbol.test.tsx con claude-code/testing, convierte los arboles a HTML (tests\render-html.mjs) y saca PNG con Edge headless.
# Uso: capturas-ui.ps1 [-Salida carpeta] [-Casos c320-resumen,centro-consumo,...]  (por defecto las 30 combinaciones ancho x pestaÃ±a)
param([string]$Salida = (Join-Path $PSScriptRoot '..\evidencias\v2.3.0\capturas'), [string[]]$Casos)
$ErrorActionPreference = 'Stop'
$raiz = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$claude = (Get-Command claude -ErrorAction SilentlyContinue).Source
if (-not $claude) { $claude = (Get-ChildItem "$env:LOCALAPPDATA\Claude-Data" -Recurse -Filter claude.exe -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName }
$edge = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
New-Item -ItemType Directory -Force $Salida | Out-Null; $Salida = (Resolve-Path $Salida).Path
$tmp = Join-Path $env:TEMP 'multiia-capturas'; New-Item -ItemType Directory -Force "$tmp\h" | Out-Null
$salidaTxt = Join-Path $tmp 'out.txt'
$eo = "$salidaTxt.o"; $ee = "$salidaTxt.e"; Start-Process -FilePath $claude -ArgumentList @('plugin','test','.') -WorkingDirectory $raiz -NoNewWindow -Wait -RedirectStandardOutput $eo -RedirectStandardError $ee
Get-Content $eo, $ee -Encoding UTF8 | Set-Content $salidaTxt -Encoding utf8
Select-String -Path $salidaTxt -Pattern '^TREE' | ForEach-Object { $_.Line } | Set-Content "$tmp\trees.tsv" -Encoding utf8
$node = (Get-Command node -ErrorAction SilentlyContinue).Source; if (-not $node) { $node = Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe' }
& $node (Join-Path $raiz 'tests\render-html.mjs') "$tmp\trees.tsv" "$tmp\h"
$Casos = @($Casos | ForEach-Object { $_ -split "," })
$ErrorActionPreference = 'Continue'   # Edge escribe avisos a stderr
$w = @{ c320 = 320; c360 = 360; c390 = 390; c416 = 416; c480 = 480; centro = 1280 }
foreach ($h in Get-ChildItem "$tmp\h\*.html") {
  $n = $h.BaseName; if ($Casos -and $Casos -notcontains $n) { continue }
  $a = $n.Split('-')[0]; $alto = if ($a -eq 'centro') { 1000 } else { 1700 }
  & $edge --headless --disable-gpu --hide-scrollbars "--window-size=$($w[$a]),$alto" "--screenshot=$Salida\$n.png" ("file:///" + ($h.FullName.Replace('\', '/'))) 2>$null | Out-Null
}
Write-Host "Capturas en $Salida"
