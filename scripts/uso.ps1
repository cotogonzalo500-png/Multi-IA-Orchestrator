# Indicador de uso (texto): delegaciones por IA, modelo y esfuerzo (hoy / 7 dias / total), tokens exactos, segundos y fallas.
# Para el cupo real de cada plan: limites.ps1 (Codex y Antigravity en vivo) y panel.ps1.
. (Join-Path $PSScriptRoot '_comun.ps1')

$filas = Get-Uso
if (-not $filas) { Write-Output "Sin registros todavía."; exit 0 }
$hoy = (Get-Date).Date
$sem = $hoy.AddDays(-6)

"{0,-6} {1,-26} {2,-8} {3,5} {4,5} {5,6} {6,10} {7,7} {8,6}" -f 'IA', 'modelo', 'esfuerzo', 'hoy', '7d', 'total', 'tokens', 'seg/u', 'fallas'
foreach ($d in ($filas | Group-Object destino, modelo, esfuerzo | Sort-Object Name)) {
    $f = @($d.Group)
    "{0,-6} {1,-26} {2,-8} {3,5} {4,5} {5,6} {6,10:N0} {7,7} {8,6}" -f $f[0].destino, $f[0].modelo, $(if ($f[0].esfuerzo) { $f[0].esfuerzo } else { '-' }),
        @($f | Where-Object { [datetime]$_.fecha -ge $hoy }).Count, @($f | Where-Object { [datetime]$_.fecha -ge $sem }).Count,
        $f.Count, (Sumar-Tok $f), [math]::Round(($f | Measure-Object seg -Average).Average, 1), @($f | Where-Object { $_.salida -ne 0 }).Count
}
$ult = $filas | Select-Object -Last 1
"Último registro: $($ult.fecha) ($($ult.destino), salida $($ult.salida))"
exit 0
