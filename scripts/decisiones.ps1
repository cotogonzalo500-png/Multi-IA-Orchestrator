# Auditoria de decisiones de delegacion: "por que esta tarea fue a ese motor?". Lee decisiones.jsonl (una linea por decision, incluidas las de NO delegar).
#   .\decisiones.ps1                 ultimas 10
#   .\decisiones.ps1 -Id ej-123456-ab12
#   .\decisiones.ps1 -Destino codex -Resultado error -Ultimas 20
param([string]$Id, [string]$Destino, [string]$Resultado, [int]$Ultimas = 10)
. (Join-Path $PSScriptRoot '_comun.ps1')
$f = Join-Path $script:DatosDir 'decisiones.jsonl'
if (-not (Test-Path -LiteralPath $f)) { Write-Output '[]'; exit 0 }
$d = @(Get-Content -LiteralPath $f -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
if ($Id) { $d = @($d | Where-Object { $_.id -eq $Id }) }
if ($Destino) { $d = @($d | Where-Object { $_.destino -eq $Destino }) }
if ($Resultado) { $d = @($d | Where-Object { $_.resultado -eq $Resultado }) }
ConvertTo-Json -InputObject @($d | Select-Object -Last $Ultimas) -Depth 4
exit 0
