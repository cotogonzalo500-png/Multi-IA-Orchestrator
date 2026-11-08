# Arranque automatico del panel al iniciar sesion en Windows (sin abrir ninguna ventana ni ningun chat).
#   .\inicio-automatico.ps1 -Activar     crea un acceso en la carpeta Inicio de Windows
#   .\inicio-automatico.ps1 -Quitar      lo borra
#   .\inicio-automatico.ps1 -Estado      dice si esta activo (por defecto)
# El panel queda en http://127.0.0.1:8765/ (solo tu maquina). No cambia ninguna politica del sistema ni pide administrador.
param([switch]$Activar, [switch]$Quitar, [switch]$Estado)
$ErrorActionPreference = 'Stop'
if ($Activar -and $Quitar) { Write-Error '-Activar y -Quitar a la vez no tiene sentido'; exit 2 }
$carpeta = [Environment]::GetFolderPath('Startup')
if ($env:MULTIIA_INICIO) { $carpeta = $env:MULTIIA_INICIO }   # solo para pruebas
$lnk = Join-Path $carpeta 'Multi-IA panel.lnk'

if ($Activar) {
    $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
    $node = if ($nodeCmd) { $nodeCmd.Source } else { Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe' }
    if (-not (Test-Path $node)) { Write-Error 'No encontre node.exe (hace falta Node.js para el panel)'; exit 1 }
    $servidor = Join-Path $PSScriptRoot 'panel-servidor.mjs'
    New-Item -ItemType Directory -Force $carpeta | Out-Null
    $sh = New-Object -ComObject WScript.Shell
    $a = $sh.CreateShortcut($lnk)
    $a.TargetPath = (Get-Command powershell.exe).Source
    # Start-Process -WindowStyle Hidden: el servidor corre sin ventana. Si el puerto ya esta en uso, sale solo.
    # 2.3.1 (auditoria Codex #2): el comando va CODIFICADO (-EncodedCommand, UTF-16 base64) con las rutas como literales escapados:
    # antes se armaba con comillas a mano y una ruta con ' o " rompia el acceso (o permitia inyectar otro comando).
    $lit = { param($s) "'" + ($s -replace "'", "''") + "'" }
    $cmd = "Start-Process -WindowStyle Hidden -FilePath $(& $lit $node) -ArgumentList $(& $lit ('"' + $servidor + '"'))"
    $a.Arguments = '-NoProfile -WindowStyle Hidden -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    if ($a.Arguments.Length -gt 1000) { Write-Error 'Las rutas de node o del plugin son demasiado largas para un acceso directo de Windows.'; exit 1 }
    $a.WindowStyle = 7
    $a.Description = 'Multi-IA: panel de consumo y ahorro'
    $a.Save()
    Write-Output "Arranque automatico ACTIVADO: el panel se enciende solo al iniciar sesion en Windows (http://127.0.0.1:8765/)."
    exit 0
}
if ($Quitar) {
    if (Test-Path $lnk) { Remove-Item $lnk -Force }
    Write-Output 'Arranque automatico DESACTIVADO.'
    exit 0
}
if (Test-Path $lnk) { Write-Output 'Arranque automatico: ACTIVADO' } else { Write-Output 'Arranque automatico: desactivado' }
