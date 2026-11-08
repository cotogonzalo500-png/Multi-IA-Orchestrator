# Registro dinamico de motores: disponibilidad real, cuentas, modelo pedido y modelo verificado ("Modelo no verificable" si la CLI no lo informa).
#   .\motores.ps1            JSON
#   .\motores.ps1 -Catalogo  agrega los modelos que cada CLI dice tener (`agy models`); puede tardar unos segundos
param([switch]$Catalogo)
. (Join-Path $PSScriptRoot '_comun.ps1')
$m = @(Get-Motores)
if ($Catalogo) {
    $agyExe = Find-AgyExe   # 2.3.1 (Codex #13)
    if ($agyExe) { $r = Invoke-ConTimeout $agyExe @('models') 30; $m | Where-Object { $_.id -eq 'agy' } | ForEach-Object { $_.catalogo = @(($r.salida -split "`r?`n") | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() }) } }
}
ConvertTo-Json -InputObject $m -Depth 4
exit 0
