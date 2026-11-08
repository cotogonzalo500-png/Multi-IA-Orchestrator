# Vuelve la version ESTABLE a una version anterior que siga en la cache de plugins (instalacion global de usuario).
# Hace copia de installed_plugins.json antes de tocar nada.  Uso:
#   powershell -File scripts\rollback-estable.ps1 -Listar
#   powershell -File scripts\rollback-estable.ps1 -Version 0.8.8 [-DryRun]
param([string]$Version, [switch]$Listar, [switch]$DryRun)
$ErrorActionPreference = "Stop"
$cache = Join-Path $env:USERPROFILE ".claude\plugins\cache\multi-ia\multi-ia-orquestador"
$ip = Join-Path $env:USERPROFILE ".claude\plugins\installed_plugins.json"
# La version se valida ANTES de leer nada: una ruta o caracteres raros se rechazan aunque el plugin no este instalado.
if ($Version -and $Version -notmatch '^\d+\.\d+\.\d+$') { throw "Version invalida '$Version': se espera X.Y.Z (sin rutas ni caracteres especiales)." }
if (-not (Test-Path -LiteralPath $ip)) { throw "No encuentro $ip (Claude Code no tiene plugins instalados en este usuario)." }
$json = Get-Content $ip -Raw | ConvertFrom-Json
$e = @($json.plugins."multi-ia-orquestador@multi-ia")[0]
if (-not $e) { throw 'El plugin multi-ia-orquestador@multi-ia no esta instalado: no hay nada que volver atras.' }
if ($Listar -or -not $Version) {
    Write-Host "Instalada: $($e.version)"
    Write-Host ("En cache: " + ((Get-ChildItem $cache -Directory | Sort-Object { [version]$_.Name } | ForEach-Object Name) -join ", "))
    exit 0
}
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Version invalida '$Version': se espera X.Y.Z (sin rutas ni caracteres especiales)." }
$dest = Join-Path $cache $Version
if (-not (Test-Path "$dest\.claude-plugin\plugin.json")) { throw "La version $Version no esta en la cache o esta incompleta ($dest)." }
Write-Host "Rollback: $($e.version) -> $Version"
if ($DryRun) { Write-Host "DRY-RUN: no se cambio nada."; exit 0 }
$resp = Join-Path $env:USERPROFILE ".claude\plugins\installed_plugins.rollback-$(Get-Date -Format 'yyyyMMdd_HHmmss_fff').json"
Copy-Item $ip $resp
$e.installPath = $dest; $e.version = $Version; $e.lastUpdated = (Get-Date).ToUniversalTime().ToString("o")
[IO.File]::WriteAllText($ip, ($json | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
Copy-Item "$dest\scripts\statusline.mjs" (Join-Path $env:USERPROFILE ".claude\multi-ia-estable\statusline.mjs") -Force
Write-Host "Listo. Copia previa: $resp. Reinicia Claude para que lo tome."
