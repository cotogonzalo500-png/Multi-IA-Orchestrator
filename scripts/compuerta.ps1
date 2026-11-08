# Compuerta de autoevaluacion: revisa que una copia del plugin (dev o la recien publicada en la cache) este sana ANTES de dejarla como estable.
#   .\compuerta.ps1 -Ruta <carpeta-del-plugin> [-SinValidate]
# Chequea: plugin.json y hooks.json validos, todos los .ps1 con BOM y sin errores de sintaxis, y un humo real de elegir.ps1.
# Sale 0 si todo pasa, 1 si algo falla (publicar-estable.ps1 usa esto para volver solo a la version anterior).
param([Parameter(Mandatory)][string]$Ruta, [switch]$SinValidate)
$fallas = @()
function Falla($m) { $script:fallas += $m; Write-Output "  FALLA: $m" }
foreach ($j in '.claude-plugin\plugin.json', 'hooks\hooks.json') {
    $f = Join-Path $Ruta $j
    if (-not (Test-Path -LiteralPath $f)) { Falla "falta $j"; continue }
    try { $null = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Falla "$j no es JSON valido" }
}
foreach ($s in Get-ChildItem (Join-Path $Ruta 'scripts') -Filter *.ps1 -ErrorAction SilentlyContinue) {
    $b = [IO.File]::ReadAllBytes($s.FullName)
    if ($b.Length -lt 3 -or $b[0] -ne 0xEF -or $b[1] -ne 0xBB -or $b[2] -ne 0xBF) { Falla "$($s.Name) sin BOM UTF-8 (PowerShell 5.1 rompe los acentos)" }
    $err = $null; [void][Management.Automation.Language.Parser]::ParseFile($s.FullName, [ref]$null, [ref]$err)
    if ($err) { Falla "$($s.Name) tiene error de sintaxis: $($err[0].Message)" }
}
$el = Join-Path $Ruta 'scripts\elegir.ps1'
if (Test-Path -LiteralPath $el) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("compuerta-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory $tmp | Out-Null
    $old = $env:MULTIIA_DATOS; $env:MULTIIA_DATOS = $tmp
    try {
        $o = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $el -Tarea texto 2>&1 | Out-String)
        try { $null = $o | ConvertFrom-Json } catch { Falla "elegir.ps1 no devolvio JSON: $($o.Trim().Substring(0, [math]::Min(120, $o.Trim().Length)))" }
    } finally { $env:MULTIIA_DATOS = $old; Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
} else { Falla 'falta scripts\elegir.ps1' }
if (-not $SinValidate) {
    $claude = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Claude-Data\*\claude-code\*\*\claude.exe') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($claude) { $v = (& $claude.FullName plugin validate $Ruta 2>&1 | Out-String); if ($v -notmatch 'Validation passed') { Falla 'plugin validate no paso' } }
}
if ($fallas.Count) { Write-Output "Compuerta: $($fallas.Count) falla(s)."; exit 1 }
Write-Output 'Compuerta: todo en orden.'
exit 0
