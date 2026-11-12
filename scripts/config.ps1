# Configuracion del plugin: modo de eleccion de modelos y cuentas delegadas (hasta 3 activas).
#   .\config.ps1 -Ver
#   .\config.ps1 -Apagar | -Encender      (interruptor general: apagado, nadie delega y los avisos automaticos se callan)
#   .\config.ps1 -Modo automatico|manual
#   .\config.ps1 -Calidad economica|equilibrada|maxima    (motores que elige el modo automatico; maxima = lo mejor de cada IA + revision cruzada)
#   .\config.ps1 -Manual codex.modelo=gpt-6-luna,codex.esfuerzo=high,agy.modelo=gemini-4-argon-high
#   .\config.ps1 -Tope 500000 [-AvisoPct 80]    (tope diario de tokens delegados: alerta al llegar al aviso y al superarlo; 0 = sin tope)
#   .\config.ps1 -CacheHoras 24                  (reusar respuestas iguales por N horas sin gastar cupo; 0 = sin cache)
#   .\config.ps1 -AgregarCuenta -Id codex2 -Tipo codex -Ruta C:\ruta\codex2 -Etiqueta "Segunda ChatGPT"   (despues: CODEX_HOME=<ruta> codex login)
#   .\config.ps1 -Recuperar                     (config.json corrupta: la copia queda en config.json.corrupta y se repone con los valores por defecto)
#   .\config.ps1 -Activar codex2 | -Desactivar codex2 | -QuitarCuenta codex2
# El modo y las elecciones manuales tambien se cambian con el boton del panel (iniciar-panel.cmd).
param(
    [switch]$Ver, [switch]$Encender, [switch]$Apagar,
    [ValidateSet('automatico', 'manual')][string]$Modo,
    [ValidateSet('auto', 'economica', 'equilibrada', 'maxima')][string]$Calidad,
    [ValidateSet('maxima', 'normal')][string]$Politica,
    [string]$Manual, [Nullable[long]]$Tope, [Nullable[int]]$AvisoPct, [Nullable[int]]$CacheHoras,
    [switch]$AgregarCuenta, [string]$Id, [string]$Tipo, [string]$Ruta, [string]$Etiqueta,
    [string]$Activar, [string]$Desactivar, [string]$QuitarCuenta, [switch]$Recuperar
)
. (Join-Path $PSScriptRoot '_comun.ps1')
$esEscritura = $Encender -or $Apagar -or $Modo -or $Calidad -or $Politica -or $Manual -or ($null -ne $Tope) -or ($null -ne $AvisoPct) -or ($null -ne $CacheHoras) -or $AgregarCuenta -or $Activar -or $Desactivar -or $QuitarCuenta -or $Recuperar
$bloqueada = $false
if ($esEscritura) { $bloqueada = Lock-Config; if (-not $bloqueada) { Write-Error 'config.json esta ocupada por otro proceso; reintenta'; exit 2 } }   # leer-modificar-guardar bajo candado
$cfg = Get-Config
$cambio = $false
$estabaCorrupta = [bool]$script:ConfigCorrupta
if ($estabaCorrupta -and -not $Recuperar) { Write-Warning "config.json esta CORRUPTA ($script:ConfigArchivo): se usan los valores por defecto. Copia del original: $script:ConfigArchivo.corrupta . Para repararla: config.ps1 -Recuperar" }
if ($Recuperar) {
    if ($estabaCorrupta) { $cfg = Get-ConfigPorDefecto; $cambio = $true; $mensajeFinal = "config.json recuperada con los valores por defecto. El original quedo en $script:ConfigArchivo.corrupta (revisalo si tenias cuentas o topes propios)." }
    else { $mensajeFinal = 'config.json esta sana: no hizo falta recuperar nada.' }
}
function Falla($m) { if ($bloqueada) { Unlock-Config }; Write-Error $m; exit 2 }

if ($Encender -and $Apagar) { Falla "-Encender y -Apagar a la vez no tiene sentido" }
if ($Encender) { $cfg.activo = $true; $cambio = $true }
if ($Apagar) { $cfg.activo = $false; $cambio = $true }
if ($Modo) { $cfg.modo = $Modo; $cambio = $true }
if ($Calidad) { $cfg.calidad = $Calidad; $cambio = $true }
if ($Politica) { $cfg | Add-Member -NotePropertyName calidad_politica -NotePropertyValue $Politica -Force; $cambio = $true }   # 3.3.0: Calidad Maxima (mejores modelos + maximo esfuerzo) o normal

if ($null -ne $Tope) { $cfg.ahorro.tope_diario_tok = [long]$Tope; $cambio = $true }
if ($null -ne $AvisoPct) { $cfg.ahorro.aviso_pct = [int]$AvisoPct; $cambio = $true }
if ($null -ne $CacheHoras) { $cfg.ahorro.cache_resultados_h = [int]$CacheHoras; $cambio = $true }

if ($Manual) {
    foreach ($par in ($Manual -split ',')) {
        $k, $v = $par -split '=', 2
        switch ($k.Trim()) {
            'codex.modelo' { $cfg.manual.codex.modelo = $v.Trim() }
            'codex.esfuerzo' { if ($v.Trim() -notin 'low', 'medium', 'high', 'xhigh', 'max', 'ultra') { Falla "codex.esfuerzo invalido: $v" }; $cfg.manual.codex.esfuerzo = $v.Trim() }
            'agy.modelo' { $cfg.manual.agy.modelo = $v.Trim() }
            default { Falla "Clave manual desconocida: '$k' (usar codex.modelo, codex.esfuerzo, agy.modelo)" }
        }
    }
    $cambio = $true
}

if ($AgregarCuenta) {
    if (-not $Id -or -not $Tipo) { Falla "Faltan -Id y -Tipo" }
    if ($Id -notmatch '^[a-z0-9_-]{2,24}$') { Falla "Id invalido: solo minusculas, numeros, - y _ (2 a 24)" }
    if (@($cfg.cuentas | Where-Object { $_.id -eq $Id })) { Falla "Ya existe una cuenta con id '$Id'" }
    switch ($Tipo) {
        'codex' { if (-not $Ruta) { Falla "Una segunda cuenta de Codex necesita -Ruta (carpeta propia, ej. C:\Users\<usuario>\.codex2). Despues iniciá sesión con: `$env:CODEX_HOME='<carpeta>'; codex login" } }
        'agy' { Falla "Antigravity admite una sola cuenta: no hay una forma verificada de separar su sesión. (Probar a futuro con la variable AGY_ACCOUNT, que aparece en el binario pero no está documentada.)" }
        'claude' { Falla "Una segunda cuenta de Claude como delegada queda RESERVADA: usar varias cuentas para esquivar límites puede ir contra los términos de Anthropic y no está verificada. Si el usuario lo decide, se implementa aparte con CLAUDE_CONFIG_DIR." }
        default { Falla "Tipo '$Tipo' no soportado (codex)." }
    }
    if ($Ruta) { New-Item -ItemType Directory -Force $Ruta | Out-Null }
    $cfg.cuentas = @($cfg.cuentas) + [pscustomobject]@{ id = $Id; tipo = $Tipo; etiqueta = $(if ($Etiqueta) { $Etiqueta } else { $Id }); activa = $false; home = $Ruta }
    $cambio = $true
    $mensajeFinal = "Cuenta '$Id' agregada INACTIVA. Iniciá sesión: `$env:CODEX_HOME='$Ruta'; codex login   y después: config.ps1 -Activar $Id"
}

if ($Activar) {
    $c = @($cfg.cuentas | Where-Object { $_.id -eq $Activar })[0]
    if (-not $c) { Falla "No existe la cuenta '$Activar'" }
    if (-not $c.activa -and @(Get-CuentasActivas $cfg).Count -ge $script:MaxCuentas) { Falla "Ya hay $($script:MaxCuentas) cuentas activas (el máximo). Desactivá una primero." }
    $c.activa = $true; $cambio = $true
}
if ($Desactivar) {
    $c = @($cfg.cuentas | Where-Object { $_.id -eq $Desactivar })[0]
    if (-not $c) { Falla "No existe la cuenta '$Desactivar'" }
    if ($c.tipo -eq 'agy' -and @(Get-CuentasActivas $cfg 'agy').Count -le 1 -and $false) { }
    $c.activa = $false; $cambio = $true
}
if ($QuitarCuenta) {
    if ($QuitarCuenta -in 'codex', 'agy') { Falla "'$QuitarCuenta' es una cuenta base: desactivala en vez de quitarla." }
    $cfg.cuentas = @($cfg.cuentas | Where-Object { $_.id -ne $QuitarCuenta }); $cambio = $true
}

if ($cambio) { Save-Config $cfg }
if ($bloqueada) { Unlock-Config }   # primero se guarda y recien despues se imprime: si quien llama corta la salida, el cambio ya quedo
if ($mensajeFinal) { Write-Output $mensajeFinal }
if ($Ver -or -not $cambio) {
    if ($estabaCorrupta) { "ATENCION: config.json CORRUPTA (se usan valores por defecto). Reparar: config.ps1 -Recuperar" }
    "Plugin: {0}" -f $(if ($cfg.activo -eq $false) { 'APAGADO (no delega nada)' } else { 'ENCENDIDO' })
    "Modo: {0}   Calidad (modo automático): {1}   Política de calidad: {2}" -f $cfg.modo, $cfg.calidad, $(if ($cfg.calidad_politica -eq 'normal') { 'normal' } else { 'MÁXIMA' })
    "Cuentas delegadas ({0} activas de máximo {1}):" -f @(Get-CuentasActivas $cfg).Count, $script:MaxCuentas
    foreach ($c in $cfg.cuentas) { "  {0,-10} {1,-6} {2,-8} {3}{4}" -f $c.id, $c.tipo, $(if ($c.activa) { 'ACTIVA' } else { 'inactiva' }), $c.etiqueta, $(if ($c.home) { "  (home: $($c.home))" } else { '' }) }
    "Elecciones manuales (se aplican SOLO en modo manual):"
    "  codex: modelo={0} esfuerzo={1}" -f $(if ($cfg.manual.codex.modelo) { $cfg.manual.codex.modelo } else { '(el de tu config de Codex)' }), $cfg.manual.codex.esfuerzo
    "  agy:   modelo={0}" -f $cfg.manual.agy.modelo
}
exit 0
