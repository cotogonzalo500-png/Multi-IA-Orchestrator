# Anota en la consola del panel POR QUE Claude resolvio algo el mismo en vez de delegarlo (una linea, casi sin costo).
# Uso: decidir.ps1 -Motivo "tarea chica y depende de la charla" [-Tarea codigo]
param([Parameter(Mandatory)][string]$Motivo, [string]$Tarea = '')
. (Join-Path $PSScriptRoot '_comun.ps1')
$idEj = 'ej-' + (Get-Date).ToString('HHmmss') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 4))
Add-Evento -Tipo 'sin-delegar' -Destino 'claude' -Motivo $Motivo -Tarea $Tarea -Id $idEj
Write-Output "[anotado en la consola · id $idEj] Claude lo resuelve el mismo: $Motivo"
exit 0