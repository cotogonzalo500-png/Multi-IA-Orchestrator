# Reduccion de contexto: resume un archivo grande con un motor barato para que Claude lea el resumen en vez del original.
#   .\resumir.ps1 -Archivo ruta [-Foco "que te interesa"] [-MaxPalabras 300] [-Forzar]
# Con archivos chicos (menos de -Minimo caracteres) no delega: el resumen costaria mas que leerlo. Usa la cache de resultados.
# El resumen es una guia, no un reemplazo: si Claude necesita un dato exacto, debe abrir el original.
param([Parameter(Mandatory)][string]$Archivo, [string]$Foco = '', [int]$MaxPalabras = 300, [int]$Minimo = 8000, [switch]$Forzar)
if (-not (Test-Path -LiteralPath $Archivo -PathType Leaf)) { Write-Output "No existe el archivo: $Archivo"; exit 2 }
$tam = (Get-Item -LiteralPath $Archivo).Length
if ($tam -lt $Minimo -and -not $Forzar) { Write-Output "[resumir: el archivo es chico ($tam caracteres, minimo $Minimo); leelo directo, resumirlo costaria mas]"; exit 0 }
$delegador = if ($env:MULTIIA_DELEGAR) { $env:MULTIIA_DELEGAR } else { Join-Path $PSScriptRoot 'delegar.ps1' }
$p = "Resumi el archivo adjunto en no mas de $MaxPalabras palabras. Conserva nombres, cifras, fechas y decisiones exactas; indica secciones donde estan los detalles."
if ($Foco) { $p += " Foco: $Foco." }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $delegador -Tarea texto -Prompt $p -Archivo $Archivo -Calidad economica -Forzar
exit $LASTEXITCODE
