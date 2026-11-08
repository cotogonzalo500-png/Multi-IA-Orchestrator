# Asistente de configuracion (primer uso o diagnostico): detecta requisitos y motores, guia la instalacion y el login
# OFICIALES de cada motor (no copia ni lee sesiones/tokens de nadie), deja la config por defecto (intensidad Automatico)
# e inicializa la carpeta de datos. Codex y Antigravity son OPCIONALES: sin ninguno, Claude trabaja solo.
#   .\configurar.ps1            diagnostico y guia (no gasta cupo de ninguna IA)
#   .\configurar.ps1 -Probar    ademas hace UNA tarea minima real a cada motor instalado (gasta un poco de cupo)
#   .\configurar.ps1 -Json      salida en JSON (para pruebas o para el panel)
# Codigo de salida: 0 = listo para usar (requisitos minimos ok), 2 = falta un requisito minimo (ver "pasos").
param([switch]$Probar, [switch]$Json)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '_comun.ps1')

$req = [ordered]@{}; $pasos = New-Object Collections.Generic.List[string]; $limites = New-Object Collections.Generic.List[string]
function Req($id, [bool]$ok, $detalle, $paso = '') { $req[$id] = [ordered]@{ ok = $ok; detalle = $detalle }; if (-not $ok -and $paso) { $pasos.Add($paso) } }

# 1) Requisitos minimos
$esWin = [Environment]::OSVersion.Platform -eq 'Win32NT'
Req 'windows' $esWin ([Environment]::OSVersion.VersionString) 'Este plugin hoy solo funciona en Windows 10/11 (usa Windows PowerShell 5.1). macOS/Linux no estan soportados todavia.'
$psv = $PSVersionTable.PSVersion
Req 'powershell' ($psv -ge [version]'5.1') "PowerShell $psv" 'Hace falta Windows PowerShell 5.1 (viene con Windows 10/11).'
$node = (Get-Command node -ErrorAction SilentlyContinue).Source
$nodeV = if ($node) { (& $node --version 2>$null | Out-String).Trim() } else { '' }
$nodeOk = $false; if ($nodeV -match '^v(\d+)') { $nodeOk = [int]$Matches[1] -ge 18 }
Req 'node' $nodeOk $(if ($node) { "$nodeV ($node)" } else { 'no encontrado en el PATH' }) 'Instala Node.js 18 o superior desde https://nodejs.org (lo usan los hooks, la linea de estado y el panel). Despues reinicia Claude Code.'

# 2) Carpeta de datos (fuera del plugin; se puede cambiar con la variable MULTIIA_DATOS)
$datosOk = $false; $datosDet = $script:DatosDir
try {
    Initialize-Datos
    $p = Join-Path $script:DatosDir ".prueba-escritura-$PID"
    [IO.File]::WriteAllText($p, 'ok'); Remove-Item -LiteralPath $p -Force; $datosOk = $true
} catch { $datosDet = "$($script:DatosDir) (sin permiso de escritura: $($_.Exception.Message))" }
if ($script:AvisoDatos) { $datosDet = "$datosDet (aviso: $($script:AvisoDatos))" }
Req 'datos' $datosOk $datosDet "No se puede escribir en $($script:DatosDir). Elegi otra carpeta con la variable de entorno MULTIIA_DATOS."

# 3) Preferencias: si no hay config, se crea la de por defecto (modo e intensidad Automatico). Si existe, no se toca.
$cfgCreada = $false
if ($datosOk -and -not (Test-Path -LiteralPath $script:ConfigArchivo)) { Save-Config (Get-ConfigPorDefecto); $cfgCreada = $true }
$cfg = Get-Config
$pref = [ordered]@{ archivo = $script:ConfigArchivo; creada_ahora = $cfgCreada; corrupta = [bool]$script:ConfigCorrupta; modo = $cfg.modo; intensidad = $cfg.intensidad; calidad = $cfg.calidad }
if ($script:ConfigCorrupta) { $pasos.Add("La configuracion esta corrupta (se usa la de por defecto). Repararla: powershell -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $PSScriptRoot 'config.ps1')`" -Recuperar") }

# 4) Metricas: el registro de uso se crea vacio si no existe (no se inventan datos).
if ($datosOk -and -not (Test-Path -LiteralPath $script:UsoArchivo)) { [IO.File]::WriteAllText($script:UsoArchivo, '', (New-Object Text.UTF8Encoding($false))) }

# 5) Motores (opcionales). conexiones.ps1 no gasta cupo salvo -Probar.
$argsCx = @('-Forzar'); if ($Probar) { $argsCx += @('-Probar', 'todos') }
$cx = $null; $cxError = ''
# Revision Antigravity 2.3.1: si el diagnostico falla NO se informa "no instalado" (falso negativo): se avisa del fallo y de como verlo.
try { $cx = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'conexiones.ps1') @argsCx | Out-String) | ConvertFrom-Json } catch { $cxError = $_.Exception.Message }
if (-not $cx -or -not $cx.motores) { $pasos.Add("No se pudo diagnosticar los motores$(if ($cxError) { " ($cxError)" }). Para ver el error: powershell -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $PSScriptRoot 'conexiones.ps1')`" -Forzar") }
$guias = @{
    codex = @(
        'Codex (OpenAI, opcional): instala el CLI oficial con  npm install -g @openai/codex  (o la app de escritorio de Codex).',
        'Inicia sesion con TU cuenta:  codex login  (abre el navegador; el login lo guarda Codex, este plugin nunca lo lee ni lo copia).',
        'Verifica con  codex login status  y despues volve a correr /configurar.')
    agy = @(
        'Antigravity (Google, opcional): instala el CLI oficial siguiendo las instrucciones de Google Antigravity (comando agy).',
        'Abri agy una vez en una terminal e inicia sesion con TU cuenta de Google cuando lo pida.',
        'agy no tiene un comando para consultar el login sin gastar cupo: para verificarlo de verdad pedile a Claude /configurar con prueba real (corre configurar.ps1 -Probar; gasta un poco de cupo).')
}
$motores = @()
foreach ($id in 'codex', 'agy') {
    $m = if ($cx) { @($cx.motores | Where-Object { $_.id -eq $id })[0] } else { $null }
    $inst = [bool]($m -and $m.instalacion -and $m.instalacion.valor)
    $estado = if ($m) { [string]$m.estado } else { 'Desconocido (fallo el diagnostico)' }
    $auth = if ($m -and $m.autenticacion) { [string]$m.autenticacion.nivel } else { '' }
    $o = [ordered]@{ id = $id; instalado = $inst; version = $(if ($m -and $m.version) { [string]$m.version.valor } else { '' }); estado = $estado; autenticacion = $auth; porque = $(if ($m) { [string]$m.porque } else { '' }) }
    $motores += $o
    if (-not $m) { }   # diagnostico fallido: ya hay un paso que lo explica; no se dan guias de instalacion a ciegas
    elseif (-not $inst) { foreach ($g in $guias[$id]) { $pasos.Add($g) } }
    elseif ($estado -match 'Autenticacion requerida') { $pasos.Add($guias[$id][1]) }
}
$hayMotor = @($motores | Where-Object { $_.instalado }).Count -gt 0
if (-not $hayMotor) { $limites.Add('Sin Codex ni Antigravity el plugin no puede delegar: Claude hace todo el trabajo (no se ahorra cupo, pero nada se rompe).') }

# 6) Limitaciones conocidas (siempre visibles, sin maquillar)
$limites.Add('Solo Windows 10/11 con Windows PowerShell 5.1; macOS y Linux no estan probados ni soportados.')
$limites.Add('Cada motor usa la cuenta y el cupo de quien lo instala; los limites de cada proveedor siguen vigentes.')
$limites.Add('El ahorro que muestra el panel es una estimacion a partir de lo registrado; sin datos dice "sin dato", no cero.')
$limites.Add('El login de Antigravity solo se puede confirmar con una tarea real (-Probar).')

$listo = [bool]($req.windows.ok -and $req.powershell.ok -and $req.node.ok -and $req.datos.ok)
$res = [ordered]@{ generado = (Get-Date).ToString('s'); listo = $listo; requisitos = $req; preferencias = $pref; datos = $script:DatosDir; motores = $motores; pasos = @($pasos); limitaciones = @($limites); probado = [bool]$Probar }

if ($Json) { $res | ConvertTo-Json -Depth 6 }
else {
    Write-Output '== Multi-IA Orquestador: configuracion'
    foreach ($k in $req.Keys) { Write-Output ("  [{0}] {1,-11} {2}" -f $(if ($req[$k].ok) { 'ok' } else { '!!' }), $k, $req[$k].detalle) }
    Write-Output ("  Preferencias: modo {0}, intensidad {1}, calidad {2}{3}" -f $pref.modo, $pref.intensidad, $pref.calidad, $(if ($cfgCreada) { ' (recien creadas)' } else { '' }))
    Write-Output '== Motores (opcionales)'
    foreach ($m in $motores) { Write-Output ("  {0,-6} {1}{2}" -f $m.id, $m.estado, $(if ($m.version) { " · " + $(if ($m.version -match '^\d') { 'v' } else { '' }) + $m.version } else { '' })) }
    if ($pasos.Count) { Write-Output '== Pasos sugeridos'; $i = 0; foreach ($p in $pasos) { $i++; Write-Output "  $i. $p" } }
    Write-Output '== Limitaciones'; foreach ($l in $limites) { Write-Output "  - $l" }
    Write-Output $(if ($listo) { 'Listo para usar.' + $(if ($pasos.Count) { ' Quedan pasos sugeridos arriba.' } else { '' }) + $(if (-not $hayMotor) { ' (Sin motores delegados todavia.)' } else { '' }) } else { 'Falta un requisito minimo: segui los pasos de arriba.' })
}
exit $(if ($listo) { 0 } else { 2 })
