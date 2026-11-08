# Control de integridad de la carpeta DEV (1.9.2). Detecta archivos de codigo que DESAPARECEN o cambian sin que nadie lo declare.
# Motivo: durante la regresion de 1.9.2 _comun.ps1 y config.ps1 de DEV "desaparecieron" (edicion por herramienta = borrar+crear, en carrera con una corrida de pruebas).
#
# Modos (solo lectura salvo -Crear):
#   integridad.ps1                  verifica contra el manifiesto (integridad.manifest.json) y contra la ULTIMA version estable en la cache
#   integridad.ps1 -Crear           regenera el manifiesto (hacerlo a proposito, cuando el cambio es intencional y esta probado)
#   integridad.ps1 -Json            salida maquina
#   integridad.ps1 -Ruta <carpeta>  otra carpeta (para pruebas)
# Salida: 0 = todo en orden; 1 = hay archivos modificados o nuevos respecto del manifiesto (aviso); 2 = FALTAN archivos (grave: bloquea la publicacion).
# Nunca borra ni restaura nada: informa. Restaurar lo hace una persona, comparando con la cache estable o un respaldo.
param([switch]$Crear, [switch]$Json, [string]$Ruta = '', [string]$Estable = '', [switch]$SinEstable)
$ErrorActionPreference = 'Stop'
$dev = if ($Ruta) { (Resolve-Path -LiteralPath $Ruta).Path } else { Split-Path $PSScriptRoot -Parent }
$manifiesto = Join-Path $dev 'integridad.manifest.json'
$carpetas = '.claude-plugin', 'scripts', 'tests', 'hooks', 'skills', 'agents', 'commands', 'types'
$extensiones = '.ps1', '.mjs', '.js', '.json', '.cmd', '.md', '.sh'

function Get-Sha([string]$p) {
    $sha = [Security.Cryptography.SHA256]::Create(); $fs = $null
    try { $fs = [IO.File]::Open($p, 'Open', 'Read', 'ReadWrite'); ([BitConverter]::ToString($sha.ComputeHash($fs))).Replace('-', '').ToLowerInvariant() }
    catch { 'ilegible' } finally { if ($fs) { $fs.Dispose() }; $sha.Dispose() }
}
function Get-Inventario([string]$Base) {
    $r = [ordered]@{}
    foreach ($c in $carpetas) {
        $d = Join-Path $Base $c
        if (-not (Test-Path -LiteralPath $d)) { continue }
        foreach ($f in Get-ChildItem -LiteralPath $d -Recurse -File -ErrorAction SilentlyContinue | Sort-Object FullName) {
            if ($extensiones -notcontains $f.Extension.ToLowerInvariant()) { continue }
            $rel = $f.FullName.Substring($Base.Length).TrimStart('\', '/').Replace('\', '/')
            $r[$rel] = [pscustomobject]@{ sha256 = (Get-Sha $f.FullName); bytes = $f.Length }
        }
    }
    foreach ($f in Get-ChildItem -LiteralPath $Base -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.cmd', '.sh' -or $_.Name -eq 'CLAUDE.md' }) {
        $r[$f.Name] = [pscustomobject]@{ sha256 = (Get-Sha $f.FullName); bytes = $f.Length }
    }
    $r
}

if ($Crear) {
    $inv = Get-Inventario $dev
    $obj = [ordered]@{ generado = (Get-Date).ToString('s'); version = $(try { (Get-Content -LiteralPath (Join-Path $dev '.claude-plugin\plugin.json') -Raw | ConvertFrom-Json).version } catch { '' }); archivos = $inv }
    $tmp = "$manifiesto.$PID.tmp"
    [IO.File]::WriteAllText($tmp, ($obj | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $manifiesto -Force
    if ($Json) { [pscustomobject]@{ accion = 'crear'; archivos = $inv.Count; manifiesto = $manifiesto } | ConvertTo-Json -Compress } else { Write-Host "Manifiesto creado: $($inv.Count) archivos -> $manifiesto" }
    exit 0
}

$faltan = New-Object Collections.Generic.List[string]; $modif = New-Object Collections.Generic.List[string]; $nuevos = New-Object Collections.Generic.List[string]; $faltanEstable = New-Object Collections.Generic.List[string]
$actual = Get-Inventario $dev
$estadoManifiesto = 'ausente'
if (Test-Path -LiteralPath $manifiesto) {
    try {
        $m = Get-Content -LiteralPath $manifiesto -Raw -Encoding UTF8 | ConvertFrom-Json
        $estadoManifiesto = 'ok'
        foreach ($p in $m.archivos.PSObject.Properties) {
            if (-not $actual.Contains($p.Name)) { $faltan.Add($p.Name) }
            elseif ($actual[$p.Name].sha256 -ne $p.Value.sha256) { $modif.Add($p.Name) }
        }
        foreach ($k in $actual.Keys) { if (-not $m.archivos.PSObject.Properties[$k]) { $nuevos.Add($k) } }
    } catch { $estadoManifiesto = 'corrupto' }
}
# Contra la ultima version estable: todo script que existe alli debe existir en DEV (salvo que se haya retirado a proposito y se regenere el manifiesto)
$estVer = ''
if (-not $SinEstable) {
    $base = if ($Estable) { $Estable } else { Join-Path $env:USERPROFILE '.claude\plugins\cache\multi-ia\multi-ia-orquestador' }
    if (Test-Path -LiteralPath $base) {
        $ult = Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue | Sort-Object { try { [version]$_.Name } catch { [version]'0.0.0' } } | Select-Object -Last 1
        if ($ult) {
            $estVer = $ult.Name
            foreach ($f in Get-ChildItem -LiteralPath (Join-Path $ult.FullName 'scripts') -File -Filter *.ps1 -ErrorAction SilentlyContinue) {
                if (-not (Test-Path -LiteralPath (Join-Path $dev "scripts\$($f.Name)"))) { $faltanEstable.Add("scripts/$($f.Name)") }
            }
        }
    }
}
$grave = ($faltan.Count + $faltanEstable.Count) -gt 0
$codigo = if ($grave) { 2 } elseif ($modif.Count + $nuevos.Count -gt 0 -or $estadoManifiesto -ne 'ok') { 1 } else { 0 }
$res = [pscustomobject]@{ estado = @('ok', 'avisos', 'FALTAN ARCHIVOS')[$codigo]; manifiesto = $estadoManifiesto; archivos = $actual.Count; faltan = @($faltan); faltan_vs_estable = @($faltanEstable); version_estable = $estVer; modificados = @($modif); nuevos = @($nuevos) }
if ($Json) { $res | ConvertTo-Json -Depth 4 -Compress }
else {
    Write-Host "Integridad DEV: $($res.estado) ($($actual.Count) archivos; manifiesto $estadoManifiesto; estable $estVer)"
    foreach ($x in $faltan) { Write-Host "  FALTA (estaba en el manifiesto): $x" -ForegroundColor Red }
    foreach ($x in $faltanEstable) { Write-Host "  FALTA (existe en estable $estVer): $x" -ForegroundColor Red }
    foreach ($x in $modif) { Write-Host "  modificado desde el manifiesto: $x" -ForegroundColor Yellow }
    foreach ($x in $nuevos) { Write-Host "  nuevo (no esta en el manifiesto): $x" -ForegroundColor Yellow }
    if ($estadoManifiesto -ne 'ok') { Write-Host "  manifiesto ${estadoManifiesto}: correr integridad.ps1 -Crear cuando el estado sea el correcto" -ForegroundColor Yellow }
}
exit $codigo
