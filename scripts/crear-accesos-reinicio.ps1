# Crea en el escritorio los accesos "Reiniciar Claude" y "Reiniciar Multi-IA" y deja una copia estable del script en ~\.claude\multi-ia-estable\.
#   .\crear-accesos-reinicio.ps1            crea / actualiza
#   .\crear-accesos-reinicio.ps1 -Quitar    los borra
# Los accesos funcionan sin el panel ni el plugin cargado. No piden administrador.
param([switch]$Quitar)
$ErrorActionPreference = 'Stop'
$estable = Join-Path $env:USERPROFILE '.claude\multi-ia-estable'
$escritorio = if ($env:MULTIIA_ESCRITORIO) { $env:MULTIIA_ESCRITORIO } else { [Environment]::GetFolderPath('Desktop') }
$accesos = @(
    @{ Nombre = 'Reiniciar Claude.lnk'; Args = '-Modo claude -Si -Aviso'; Desc = 'Cierra y vuelve a abrir la app Claude (con confirmacion)' },
    @{ Nombre = 'Reiniciar Multi-IA.lnk'; Args = '-Modo orquestador -Si -Aviso'; Desc = 'Reinicia solo el orquestador Multi-IA; Claude no se cierra' }
)
if ($Quitar) { foreach ($a in $accesos) { Remove-Item -LiteralPath (Join-Path $escritorio $a.Nombre) -ErrorAction SilentlyContinue }; Write-Output '[OK] accesos quitados'; exit 0 }
New-Item -ItemType Directory -Path $estable -Force | Out-Null
$destino = Join-Path $estable 'reiniciar-claude.ps1'
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'reiniciar-claude.ps1') -Destination $destino -Force
$sh = New-Object -ComObject WScript.Shell
foreach ($a in $accesos) {
    $l = $sh.CreateShortcut((Join-Path $escritorio $a.Nombre))
    $l.TargetPath = (Get-Command powershell.exe).Source
    $l.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$destino`" $($a.Args)"
    $l.WorkingDirectory = $estable; $l.Description = $a.Desc; $l.IconLocation = "$env:SystemRoot\System32\shell32.dll,238"
    $l.Save()
    Write-Output "[OK] $(Join-Path $escritorio $a.Nombre)"
}
