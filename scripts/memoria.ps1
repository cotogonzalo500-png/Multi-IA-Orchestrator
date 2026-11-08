# Memoria compartida entre IAs: un archivo MEMORIA.md que Claude actualiza y que los delegados reciben con -ConMemoria.
# Ver:      .\memoria.ps1 -Ver
# Agregar:  .\memoria.ps1 -Agregar "nota corta" [-Fuente Claude|Codex|Gemini|el usuario]
# Por proyecto: .\memoria.ps1 -Proyecto miproyecto -Agregar "nota"   |   .\memoria.ps1 -Proyecto miproyecto -Ver
# Regla: nada de claves, tokens ni datos personales de clientes. Solo decisiones, hechos del proyecto y preferencias.
param(
    [string]$Agregar,
    [string]$Fuente = 'Claude',
    [switch]$Handoff,   # nota de relevo para la PROXIMA sesion: el hook SessionStart la inyecta (maximo 1000 caracteres)
    [string]$Proyecto,  # nota solo de este proyecto (MEMORIA-<proyecto>.md); los delegados la reciben cuando trabajan en esa carpeta o con MULTIIA_PROYECTO
    [switch]$Ver
)
. (Join-Path $PSScriptRoot '_comun.ps1')
Initialize-Datos
$archivo = if ($Proyecto) { Get-MemoriaProyectoArchivo $Proyecto } else { $script:MemoriaArchivo }

if ($Agregar) {
    # Busca formas de secreto real ("password: xxx", claves sk-/AIza, cadenas largas), no palabras sueltas como "secretos".
    $pareceSecreto = '(?i)((api[_-]?key|token|password|passwd|contrase\S*|secret\S*)\s*(es|:|=)\s*\S+|sk-[a-z0-9_-]{16,}|AIza[0-9A-Za-z_-]{20,}|\b[A-Za-z0-9+/_-]{40,}\b)'
    if ($Agregar -match $pareceSecreto) {
        Write-Error "La nota parece tener un secreto. No se guardó."; exit 2
    }
    if (-not (Test-Path -LiteralPath $archivo)) { Set-Content -LiteralPath $archivo "# Memoria compartida`n" -Encoding UTF8 }
    if ($Handoff -and $Agregar.Length -gt 1000) { Write-Error "El handoff tiene $($Agregar.Length) caracteres: maximo 1000 (se inyecta en cada sesion nueva)."; exit 2 }
    # 2.3.1 (auditoria Codex #4): el handoff guarda la carpeta del proyecto; el hook solo lo inyecta en sesiones de esa carpeta.
    $carpetaHo = if ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR } else { (Get-Location).Path }
    $linea = if ($Handoff) { "- [{0}] ({1}) [handoff] {{carpeta:{3}}} {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm'), $Fuente, ($Agregar -replace '\s*[\r\n]+\s*', ' '), ($carpetaHo -replace '[{}]', '') }
             else { "- [{0}] ({1}) {2}" -f (Get-Date -Format 'yyyy-MM-dd'), $Fuente, $Agregar }
    Add-Content -LiteralPath $archivo $linea -Encoding UTF8
    Write-Output "Guardado en $archivo"
}
if ($Ver -or -not $Agregar) {
    if (Test-Path -LiteralPath $archivo) { Get-Content -LiteralPath $archivo -Encoding UTF8 } else { "(memoria vacía)" }
}
exit 0
