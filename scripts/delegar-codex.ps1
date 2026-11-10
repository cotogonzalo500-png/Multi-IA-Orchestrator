# Delegar una tarea a Codex (cuenta ChatGPT del usuario) y devolver SOLO la respuesta (sin el ruido de la ejecucion).
# Uso: .\delegar-codex.ps1 -Prompt "tarea" [-Carpeta C:\ruta] [-Escribir] [-ConMemoria]
# Con -Escribir Codex solo puede modificar la carpeta -Carpeta (y la carpeta temporal de Windows: no uses una carpeta dentro de %TEMP%).
param(
    [Parameter(Mandatory)][string]$Prompt,
    [string]$Carpeta = (Get-Location).Path,
    [switch]$Escribir,    # sin esto, Codex solo puede leer
    [switch]$ConMemoria,  # antepone la memoria compartida (MEMORIA.md) al pedido
    [switch]$Aislar,      # trabaja en una COPIA de -Carpeta (el original no se toca) y lista los cambios: delegar IMPLEMENTACION sin riesgo para el original
    [string]$Cuenta = 'codex',   # id de la cuenta de Codex (config.ps1 -Ver); con varias cuentas activas se elige una
    [string]$Modelo,      # slug del catalogo (`codex debug models`); vacio = el de tu config
    [ValidateSet('low', 'medium', 'high', 'xhigh', 'max', 'ultra')][string]$Esfuerzo   # intensidad de razonamiento: menos = menos tokens
)
. (Join-Path $PSScriptRoot '_comun.ps1')
# PRUEBAS: MULTIIA_SIMULAR_FALLA=codex simula que Codex no esta disponible (falla controlada, no toca la CLI real).
$global:MIA_Causa = $null
if ($env:MULTIIA_SIMULAR_FALLA -match '\bcodex\b') { Set-CausaActual -Texto '[SIMULADO] Codex no disponible' -Salida 7; Write-Output '[SIMULADO] Codex no disponible (MULTIIA_SIMULAR_FALLA)'; exit 7 }
if ($env:MULTIIA_SIMULAR_OK -match '\bcodex\b') { Write-Output '[SIMULADO] respuesta ok de Codex (MULTIIA_SIMULAR_OK)'; exit 0 }   # PRUEBAS: exito controlado sin gastar cupo

# 2.3.1 (auditoria Codex #3): el pedido FINAL (prompt + memoria) se revisa ANTES de buscar Codex o tocar la sesion: antes no habia ningun filtro de secretos aca.
if ($ConMemoria) { $Prompt = Add-Memoria $Prompt }
if (Test-Secreto $Prompt) { Write-Error 'El pedido (prompt o memoria) parece contener un secreto: no se envía.'; exit 2 }

# El hash de la carpeta cambia con cada actualización de Codex: tomamos la más reciente.
$codex = Find-CodexExe
if (-not $codex) { $global:MIA_Causa = Get-ClaseError -Texto 'No encontré codex.exe' -Salida 1; Write-Error "No encontré codex.exe (ni la app de Codex ni el CLI de npm @openai/codex). Corré /configurar para ver cómo instalarlo."; exit 1 }

$cfg = Get-Config
$cta = @(Get-CuentasActivas $cfg 'codex' | Where-Object { $_.id -eq $Cuenta })[0]
if (-not $cta) { Write-Error "No hay una cuenta de Codex ACTIVA con id '$Cuenta' (ver: config.ps1 -Ver)."; exit 1 }
# MODO MANUAL: manda lo que eligio el usuario, aunque quien llama pida otra cosa. Asi el boton del panel siempre se respeta.
if ($cfg.modo -eq 'manual') {
    if ($cfg.manual.codex.modelo) { $Modelo = $cfg.manual.codex.modelo }
    if ($cfg.manual.codex.esfuerzo) { $Esfuerzo = $cfg.manual.codex.esfuerzo }
}
$homeViejo = $env:CODEX_HOME
if ($cta.home) { $env:CODEX_HOME = $cta.home }   # otra cuenta de ChatGPT = otra carpeta de sesion
# Verificacion previa: sin sesion Codex reintenta varias veces antes de fallar; asi falla al instante y con el motivo.
$estado = Invoke-ConTimeout $codex @('login', 'status') 20
if ($estado -and $estado.arranque -eq $false) { $env:CODEX_HOME = $homeViejo; $msg = "Codex no arranca ($codex): $($estado.error). Reinstalalo o corregi MULTIIA_CODEX_EXE."; Set-CausaActual -Texto $msg -Salida 126; Write-Error $msg; exit 126 }
if (-not $estado -or $estado.codigo -ne 0 -or (($estado.salida + $estado.error) -match '(?i)not logged') -or (($estado.salida + $estado.error) -notmatch '(?i)logged in')) {
    $env:CODEX_HOME = $homeViejo
    $msg = "La cuenta '$Cuenta' de Codex no tiene sesión. Abrí la app de Codex e iniciá sesión con ChatGPT$(if ($cta.home) { " (o: `$env:CODEX_HOME='$($cta.home)'; codex login)" })."
    Set-CausaActual -Texto $msg -Salida 1
    Write-Error $msg
    exit 1
}

$sandbox = if ($Escribir) { 'workspace-write' } else { 'read-only' }
$sw = [Diagnostics.Stopwatch]::StartNew()
# --json: eventos por linea (respuesta + tokens). PowerShell 5.1 pierde las comillas dobles al pasar args a un .exe: se escapan a mano.
# `--` evita que un prompt con "-" parezca opción.
$origenAislado = $null
if ($Aislar) {
    # Copia de trabajo en <carpeta de datos>\_delegado\<fecha> (2.3.7: antes ~\CLAUDE\_delegado, que ensuciaba el perfil de un usuario nuevo) (no en %TEMP%: alli Codex puede escribir fuera de la carpeta). Sin .git/node_modules/etc., max 100 MB.
    $origenAislado = (Resolve-Path -LiteralPath $Carpeta).Path.TrimEnd('\')
    $excluir = @('.git', 'node_modules', '__pycache__', '.venv', '_delegado')
    $nombreSecreto = '(?i)^(\.env.*|.*\.(pem|key|pfx|p12|kdbx)|id_rsa.*|.*credential.*|.*secret.*|.*password.*|.*cookie.*|auth\.json|.*token.*|\.netrc|\.npmrc)$'   # 2.3.7: la copia aislada no duplica credenciales
    $arch = @(Get-ChildItem -LiteralPath $origenAislado -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch $nombreSecreto } | Where-Object { $rel = $_.FullName.Substring($origenAislado.Length + 1); -not ($excluir | Where-Object { $rel -like "$_\*" -or $rel -like "*\$_\*" }) })
    # 2.3.11 (auditoria cruzada Codex #3): ademas del nombre se mira el CONTENIDO (texto <= 1 MB); lo que parezca secreto no se copia.
    $conSecreto = @($arch | Where-Object { $_.Length -gt 20MB -or (Test-Secreto ([IO.File]::ReadAllText($_.FullName))) })   # 3.1.0 (auditoria Codex): antes solo <= 1 MB; ahora se mira hasta 20 MB y lo mas grande no se copia
    if ($conSecreto.Count) { $arch = @($arch | Where-Object { $_.FullName -notin $conSecreto.FullName }); Write-Output ("[aislar: {0} archivo(s) NO copiados por contener posibles secretos: {1}]" -f $conSecreto.Count, (($conSecreto | Select-Object -First 5 | ForEach-Object { $_.Name }) -join ', ')) }
    if ((($arch | Measure-Object Length -Sum).Sum / 1MB) -gt 100) { $env:CODEX_HOME = $homeViejo; Write-Error "La carpeta pesa más de 100 MB: -Aislar no la copia."; exit 1 }
    $Carpeta = Join-Path $script:DatosDir ('_delegado\' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 4))
    foreach ($f in $arch) { $d = Join-Path $Carpeta $f.FullName.Substring($origenAislado.Length + 1); New-Item -ItemType Directory -Force (Split-Path $d) | Out-Null; Copy-Item -LiteralPath $f.FullName -Destination $d }
    $Escribir = $true; $sandbox = 'workspace-write'
}
# Sin --ephemeral (1.7.0): Codex guarda su sesion LOCAL (en tu PC, como cualquier uso de la app) y de ahi se lee el modelo realmente usado (ver Get-ModeloCodex).
$a = @('exec', '--json', '--skip-git-repo-check', '--sandbox', $sandbox, '-C', $Carpeta)
if ($Modelo) { $a += @('-m', $Modelo) }
if ($Esfuerzo) { $a += @('-c', "model_reasoning_effort=$Esfuerzo") }
$errArch = Join-Path $env:TEMP ('codex-err-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
# v1.9.1: timeout duro de proceso (30 min por defecto; MULTIIA_CODEX_TIMEOUT_MIN lo cambia). Al vencer se mata el arbol completo (sin huerfanos).
$minTope = if ($env:MULTIIA_CODEX_TIMEOUT_MIN -match '^\d+$' -and [int]$env:MULTIIA_CODEX_TIMEOUT_MIN -gt 0) { [int]$env:MULTIIA_CODEX_TIMEOUT_MIN } else { 30 }
$res = Invoke-ConTimeout $codex ($a + @('--', $Prompt)) ($minTope * 60) -Duro
$lineas = @($res.salida -split "\r?\n" | Where-Object { $_ -ne '' })
$salida = [int]$res.codigo
if ($res.error) { [IO.File]::WriteAllText($errArch, $res.error, (New-Object Text.UTF8Encoding($false))) }
if ($res.timeout) { Write-Error "codex: timeout duro de proceso tras $minTope min; proceso y subprocesos terminados."; $salida = 124 }
$errTxt = ''
if (Test-Path -LiteralPath $errArch) { $errTxt = [string](Get-Content -LiteralPath $errArch -Raw -Encoding UTF8 -ErrorAction SilentlyContinue); Remove-Item -LiteralPath $errArch -Force -ErrorAction SilentlyContinue }
$homeUsado = $env:CODEX_HOME   # el de la cuenta, para ubicar su sesion local
$env:CODEX_HOME = $homeViejo   # el script corre en la sesion de quien lo llama: se restaura

$texto = @(); $tokIn = $null; $tokOut = $null; $errores = @(); $threadId = ''
foreach ($l in $lineas) {
    $e = try { $l | ConvertFrom-Json } catch { $null }
    if (-not $e) { continue }
    if ($e.type -eq 'thread.started' -and $e.thread_id) { $threadId = [string]$e.thread_id }
    if ($e.type -in 'thread.started', 'turn.started') { $global:MIA_Conf = $e.type }   # senal REAL de que Codex arranco (la lee delegar.ps1)
    if ($e.type -eq 'item.completed' -and $e.item.type -eq 'agent_message') { $texto += $e.item.text }
    elseif ($e.type -eq 'turn.completed' -and $e.usage -and ($null -ne $e.usage.input_tokens -or $null -ne $e.usage.output_tokens)) { $tokIn = [long]$tokIn + [long]$e.usage.input_tokens; $tokOut = [long]$tokOut + [long]$e.usage.output_tokens }
    elseif ($e.type -in @('error', 'turn.failed')) { $errores += @($e.message, $e.error.message | Where-Object { $_ }) }
}
if ($texto) { $texto -join "`n" }
if ($origenAislado) {
    # Cambios de la copia respecto del original, para que Claude los revise (y recien ahi, con OK, los aplique).
    $camb = @(); $enCopia = @{}
    foreach ($f in (Get-ChildItem -LiteralPath $Carpeta -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($Carpeta.Length + 1); $enCopia[$rel] = $true; $orig = Join-Path $origenAislado $rel
        if (-not (Test-Path -LiteralPath $orig)) { $camb += "NUEVO: $rel" }
        elseif ((Get-FileHash -LiteralPath $f.FullName).Hash -ne (Get-FileHash -LiteralPath $orig).Hash) { $camb += "MODIFICADO: $rel" }
    }
    foreach ($f in (Get-ChildItem -LiteralPath $origenAislado -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($origenAislado.Length + 1)
        if ($f.Name -notmatch $nombreSecreto -and $rel -notlike '__pycache__\*' -and $rel -notlike '*\__pycache__\*' -and $rel -notlike '.venv\*' -and $rel -notlike '*\.venv\*' -and $rel -notlike '.git\*' -and $rel -notlike 'node_modules\*' -and -not $enCopia[$rel] -and ($rel -notlike '*\.git\*') -and ($rel -notlike '*\node_modules\*')) { $camb += "BORRADO: $rel" }
    }
    Write-Output "[aislado] copia de trabajo: $Carpeta"
    Write-Output $(if ($camb) { "[aislado] cambios ($($camb.Count)):`n" + ($camb -join "`n") } else { '[aislado] Codex no cambió ningún archivo.' })
    Write-Output "[aislado] el original NO se tocó. Revisar y, con tu OK, copiar los archivos deseados al original."
}
if ($res.timeout) { $errores += "timeout duro de proceso tras $minTope min" }
if ($errores -or ($salida -ne 0 -and $errTxt.Trim())) { Set-CausaActual -Texto (($errores -join '; ') + ' ' + $errTxt) -Salida $salida }
if ($errores) { $pista = if (($errores -join ' ') -match '(?i)log ?in|auth|credential|sign') { ' PISTA: esta cuenta de Codex no tiene sesión (abrí la app de Codex o corré codex login con su CODEX_HOME).' } else { '' }; Write-Error (Hide-Secretos ("Codex: " + ($errores -join '; ') + $pista)) }
if ($salida -eq 0 -and -not $texto) { Write-Error "Codex no devolvió respuesta."; $salida = 1; Set-CausaActual -Texto 'Codex no devolvió respuesta' -Salida 1 }
$mc = Get-ModeloCodex -ThreadId $threadId -CodexHome $homeUsado
$global:MIA_Modelo = [ordered]@{ confirmado = $(if ($mc) { $mc.modelo } else { '' }); fuente = $(if ($mc) { $mc.fuente } else { '' }); ejecutor_id = $threadId }
Add-Uso -Destino 'codex' -Modelo $(if ($Modelo) { $Modelo } else { 'por-defecto' }) -Esfuerzo $Esfuerzo -Chars $Prompt.Length -Segundos $sw.Elapsed.TotalSeconds -Salida $salida -ConMemoria ([bool]$ConMemoria) -TokIn $tokIn -TokOut $tokOut -Modo $cfg.modo -Cuenta $Cuenta -ModeloConf $global:MIA_Modelo.confirmado -ModeloFuente $global:MIA_Modelo.fuente
exit $salida
