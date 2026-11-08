# Guarda una foto del cupo de Claude (tu plan) para que el panel la muestre.
# El cupo de Claude solo se puede leer desde adentro de una sesion de Claude (herramienta get_usage): lo copia Claude aca antes de armar el panel.
# Uso: .\claude-snapshot.ps1 -Plan Pro -CincoHoras 15 -CincoHorasReinicia 2026-11-02T11:19:59Z -Semanal 37 -SemanalReinicia 2026-11-03T23:59:59Z
param(
    [string]$Plan = 'Pro',
    [Parameter(Mandatory)][int]$CincoHoras, [string]$CincoHorasReinicia,
    [Parameter(Mandatory)][int]$Semanal, [string]$SemanalReinicia,
    [string]$Modelo, [string]$Esfuerzo   # modelo y esfuerzo de la sesion (get_session)
)
. (Join-Path $PSScriptRoot '_comun.ps1')
Initialize-Datos
[ordered]@{
    tomado = (Get-Date).ToString('s'); plan = $Plan; fuente = 'get_usage'; modelo = $Modelo; esfuerzo = $Esfuerzo
    cinco_horas = [ordered]@{ usado = $CincoHoras; reinicia = $CincoHorasReinicia }
    semanal = [ordered]@{ usado = $Semanal; reinicia = $SemanalReinicia }
} | ConvertTo-Json | ForEach-Object { Set-TextoAtomico $script:ClaudeSnapshot $_ }   # 2.3.1 (Codex #9): escritura atomica (un corte no deja el JSON a medias)
Write-Output "Snapshot de Claude guardado ($CincoHoras% en 5 h, $Semanal% semanal)."
exit 0
