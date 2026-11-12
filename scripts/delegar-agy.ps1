# Delegar una tarea a Antigravity CLI (cuenta Google del usuario: modelos Gemini, Claude y GPT-OSS) y devolver SOLO la respuesta.
# Uso: .\delegar-agy.ps1 -Prompt "tarea" [-Perfil texto|razonar|opus|sonnet|oss] [-Esfuerzo low|medium|high] [-Modelo <slug completo>] [-Espera 5m] [-ConMemoria]
# Perfiles (modelo base y esfuerzo por defecto): texto = gemini-3.8-flash medium (rapido, barato), razonar = gemini-4-argon high,
#   sonnet = claude-sonnet-5-5 medium, opus = claude-opus-5-5 medium, oss = gpt-oss-120b medium.
# El esfuerzo va DENTRO del slug (<base>-low|medium|high): el flag --effort de agy choca con eso, por eso no se usa.
# Los Claude de agy gastan el cupo de Google ("Claude and GPT models"), no tu Claude Pro.
# Permisos por defecto de agy en modo -p: request-review, o sea que NO puede leer ni escribir archivos ni correr comandos.
# El texto a analizar va dentro del prompt. No se usa --dangerously-skip-permissions.
param(
    [Parameter(Mandatory)][string]$Prompt,
    [ValidateSet('texto', 'razonar', 'opus', 'sonnet', 'oss')][string]$Perfil = 'razonar',
    [ValidateSet('low', 'medium', 'high')][string]$Esfuerzo,   # menos = menos tokens y mas rapido; mas = mejor resultado en problemas dificiles
    [string[]]$Archivo,   # archivos de texto que lee ESTE script y manda a agy (Claude no tiene que leerlos): max 300 KB c/u y 400 KB en total; rechaza secretos y binarios
    [string]$Cuenta = 'agy',   # id de la cuenta de Antigravity (hoy solo una; config.ps1 -Ver)
    [string]$Modelo,      # slug completo (ver `agy models`); si se da, pisa al perfil y al esfuerzo
    [string]$Espera = '5m',
    [switch]$ConMemoria,   # antepone la memoria compartida (MEMORIA.md) al pedido
    [switch]$Escribir,     # 3.3.0: agy PROGRAMA de verdad: crea/edita archivos SOLO dentro de -Carpeta (--add-dir + --mode accept-edits; nunca --dangerously-skip-permissions)
    [string]$Carpeta,      # carpeta de trabajo autorizada (obligatoria con -Escribir)
    [string]$Verificar     # comando EXACTO de prueba que agy puede correr (allow-list command(<exacto>)); sin esto no corre comandos
)
. (Join-Path $PSScriptRoot '_comun.ps1')
# PRUEBAS: MULTIIA_SIMULAR_FALLA=agy simula que Antigravity no esta disponible (falla controlada, no toca la CLI real).
if ($env:MULTIIA_SIMULAR_FALLA -match '\bagy\b') { Set-CausaActual -Texto '[SIMULADO] Antigravity no disponible' -Salida 7; Write-Output '[SIMULADO] Antigravity no disponible (MULTIIA_SIMULAR_FALLA)'; exit 7 }
if ($env:MULTIIA_SIMULAR_OK -match '\bagy\b') { Write-Output '[SIMULADO] respuesta ok de Antigravity (MULTIIA_SIMULAR_OK)'; exit 0 }   # PRUEBAS: exito controlado sin gastar cupo

if ($env:MULTIIA_AGY_PARTE -and $env:MULTIIA_AGY_PARTE_TXT) { $Prompt = $env:MULTIIA_AGY_PARTE_TXT }   # parte fragmentada que manda el propio script
$perfiles = @{
    texto   = @('gemini-3.8-flash', 'medium'); razonar = @('gemini-4-argon', 'high')
    opus    = @('claude-opus-5-5', 'medium');  sonnet  = @('claude-sonnet-5-5', 'medium'); oss = @('gpt-oss-120b', 'medium')
}
$cfg = Get-Config
if (-not @(Get-CuentasActivas $cfg 'agy' | Where-Object { $_.id -eq $Cuenta })) { Write-Error "No hay una cuenta de Antigravity ACTIVA con id '$Cuenta' (ver: config.ps1 -Ver)."; exit 1 }
# MODO MANUAL: manda lo que eligio el usuario, aunque quien llama pida otro perfil/modelo. Asi el boton del panel siempre se respeta.
if ($cfg.modo -eq 'manual' -and $cfg.manual.agy.modelo) { $Modelo = $cfg.manual.agy.modelo }
if (-not $Modelo) {
    $nivel = if ($Esfuerzo) { $Esfuerzo } else { $perfiles[$Perfil][1] }
    $Modelo = $perfiles[$Perfil][0] + '-' + $nivel   # siempre se pasa --model: sin el, agy fallo una vez con "plan model not specified"
}

$agy = Find-AgyExe   # 2.3.1 (Codex #13): deteccion unica (MULTIIA_AGY_EXE > LOCALAPPDATA > PATH)
if (-not $agy) { $global:MIA_Causa = Get-ClaseError -Texto 'No encontre agy.exe' -Salida 1; Write-Error "No encontre agy.exe. Instalalo con la guia oficial (PowerShell: irm https://antigravity.google/cli/install.ps1 | iex), abri agy una vez para iniciar sesion y corre /configurar."; exit 1 }

if ($Archivo) {
    # Regla 2 (nunca secretos): se rechazan por nombre, por contenido y los binarios. Se informa que archivos salieron.
    $nombreSecreto = '(?i)(^|[\\/])(\.env.*|.*\.(pem|key|pfx|p12|kdbx)|id_rsa.*|.*credential.*|.*secret.*|.*password.*|.*cookie.*|auth\.json|.*token.*|.*session.*\.json|\.netrc|\.npmrc)$'
    $bloques = @(); $nombres = @(); $total = 0; $leidos = @()
    foreach ($ruta in $Archivo) {
        $r = Resolve-Path -LiteralPath $ruta -ErrorAction SilentlyContinue
        if (-not $r) { Write-Error "No existe: $ruta"; exit 1 }
        $f = Get-Item -LiteralPath $r.Path
        if ($f.PSIsContainer) { Write-Error "'$ruta' es una carpeta: pasar archivos."; exit 1 }
        if ($f.FullName -match $nombreSecreto) { Write-Error "'$($f.Name)' tiene nombre de archivo secreto: no se envía."; exit 2 }
        if ($f.Length -gt 300KB) { Write-Error "'$($f.Name)' pesa más de 300 KB: pasar un recorte."; exit 1 }
        $bytes = [IO.File]::ReadAllBytes($f.FullName)
        if ($bytes.Length -gt 0 -and ($bytes[0..([math]::Min(8000, $bytes.Length - 1))] -contains 0)) { Write-Error "'$($f.Name)' parece binario: no se envía."; exit 1 }
        $c = [Text.Encoding]::UTF8.GetString($bytes)
        if (Test-Secreto $c) { Write-Error "'$($f.Name)' parece contener un secreto: no se envía."; exit 2 }
        $total += $c.Length; $bloques += "--- ARCHIVO: $($f.Name) ---`n$c"; $nombres += $f.Name; $leidos += [pscustomobject]@{ n = $f.Name; c = $c }
    }
    if ($total -gt 400000) { Write-Error "Los archivos suman $total caracteres: máximo 400000."; exit 1 }
    Write-Output "[archivos enviados a agy: $($nombres -join ', ') · $total caracteres]"
    # v2.2.0: causa demostrada de los fallos con entradas grandes: pasado el umbral el prompt iba a un archivo temporal y agy (modo request-review) intentaba
    # leerlo con RunCommand, que se deniega -> respuesta vacia. Ahora el material se FRAGMENTA por lineas (cada parte entra inline) conservando nombre y numeros de linea.
    $maxParte = 14000
    if ($Escribir -and ($Prompt.Length + ($bloques -join "`n`n").Length) -gt 18000 -and -not $env:MULTIIA_AGY_PARTE) { Write-Error 'Con -Escribir el material no se fragmenta (las partes saldrian sin permiso de escritura y devolverian un falso exito): reduci -Archivo o deja que agy lea la carpeta autorizada.'; exit 1 }   # 3.3.0 (auditoria cruzada)
    if (($Prompt.Length + ($bloques -join "`n`n").Length) -gt 18000 -and -not $env:MULTIIA_AGY_PARTE) {
        $partes = @()
        # 2.3.1 (auditoria Codex #3): se fragmenta el MISMO contenido ya revisado (antes se releia el archivo: si cambiaba en el medio salia sin revisar).
        foreach ($l0 in $leidos) {
            $f = [pscustomobject]@{ Name = $l0.n }
            $lineas = @($l0.c -split "\r?\n"); if ($lineas.Count -gt 1 -and $lineas[-1] -eq '') { $lineas = $lineas[0..($lineas.Count - 2)] }; $acum = New-Object Text.StringBuilder; $ini = 1
            for ($i = 0; $i -lt $lineas.Count; $i++) {
                $reg = '{0}: {1}' -f ($i + 1), $lineas[$i]
                if ($acum.Length -gt 0 -and ($acum.Length + $reg.Length) -gt $maxParte) { $partes += [pscustomobject]@{ n = $f.Name; a = $ini; b = $i; t = $acum.ToString() }; [void]$acum.Clear(); $ini = $i + 1 }
                [void]$acum.AppendLine($reg)
            }
            if ($acum.Length -gt 0) { $partes += [pscustomobject]@{ n = $f.Name; a = $ini; b = $lineas.Count; t = $acum.ToString() } }
        }
        $env:MULTIIA_AGY_PARTE = '1'; $peor = 0; $k = 0
        if ($global:MIA_IdEj) { $env:MULTIIA_ID_EJ = [string]$global:MIA_IdEj }   # 2.3.10 (Codex): el global no cruza al proceso hijo; sin esto los tokens de cada parte quedaban sin atribuir (Get-TokEj = 0)
        try {
            foreach ($p in $partes) {
                $k++
                $sub = "$Prompt`n`n[PARTE $k de $($partes.Count) · archivo $($p.n) · lineas $($p.a)-$($p.b) · cada linea lleva su numero real 'N: ']. Revisa SOLO esta parte, cita los numeros de linea reales NO uses herramientas ni comandos: todo el material esta en este mensaje; responde solo con texto.`n--- ARCHIVO: $($p.n) (lineas $($p.a)-$($p.b)) ---`n$($p.t)"
                $pa = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Prompt', 'parte', '-Perfil', $Perfil, '-Espera', $Espera, '-Cuenta', $Cuenta)
                if ($Esfuerzo) { $pa += @('-Esfuerzo', $Esfuerzo) }; if ($Modelo) { $pa += @('-Modelo', $Modelo) }; if ($ConMemoria) { $pa += '-ConMemoria' }
                $env:MULTIIA_AGY_PARTE_TXT = $sub   # por variable de entorno: como argumento de linea de comandos el texto con saltos de linea y comillas se rompia (salida 5 sin llegar a agy)
                Write-Output "=== PARTE $k/$($partes.Count) · $($p.n) lineas $($p.a)-$($p.b) ==="
                & powershell @pa; if ($LASTEXITCODE -ne 0) { $peor = $LASTEXITCODE; Write-Output "[PARTE $k FALLO: salida $LASTEXITCODE; no se reintenta a ciegas]" }
            }
        } finally { Remove-Item Env:\MULTIIA_AGY_PARTE, Env:\MULTIIA_AGY_PARTE_TXT, Env:\MULTIIA_ID_EJ -ErrorAction SilentlyContinue }
        exit $peor
    }
    $Prompt = $Prompt + "`n`n" + ($bloques -join "`n`n")
}
if ($ConMemoria) { $Prompt = Add-Memoria $Prompt }
# 2.3.1 (auditoria Codex #3): se revisa el pedido FINAL (prompt + memoria + archivos) antes de mandarlo: antes solo se miraban los archivos.
if (Test-Secreto $Prompt) { Write-Error 'El pedido (prompt o memoria) parece contener un secreto: no se envía.'; exit 2 }
$sw = [Diagnostics.Stopwatch]::StartNew()
# PowerShell 5.1 pierde las comillas dobles al pasar args a un .exe: se escapan a mano.
# 2.3.1 (auditoria Codex #15): limite de Windows ~32K caracteres en la linea de comandos. Antes, pasado el umbral, el prompt iba a un archivo temporal
# con --add-dir y agy (request-review) no podia leerlo -> respuesta vacia. Ahora se RECHAZA claro, antes de gastar cupo: el material grande va por -Archivo (se fragmenta).
$tmpDir = $null; $charsPrompt = $Prompt.Length; $extraDir = @()
if ($Prompt.Length -gt 28000) { Write-Error "El pedido tiene $($Prompt.Length) caracteres (maximo 28000 por la linea de comandos de Windows). Pasa el material con -Archivo (se fragmenta solo) o recortalo."; exit 1 }
$global:MIA_Conf = $null; $global:MIA_Modelo = $null; $global:MIA_Causa = $null; $global:MIA_Timeout = $false; $global:MIA_Cambios = $null; $global:MIA_Checkpoint = $null   # auditoria 1.8.0 (A-06): no arrastrar la senal/modelo de una corrida anterior del mismo proceso
# v1.9.0: el stderr de agy se CAPTURA (antes se descartaba con 2>$null): ahi viene el bloque AGY_ERROR con la causa real (timeout, modelo invalido, etc.).
$errArch = Join-Path $env:TEMP ('agy-err-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
# ---- 3.3.0 ESCRITURA REAL: mismas protecciones que Codex (carpeta autorizada, candado, checkpoint, registro de cambios, verificacion)
$antes = $null; $candado = $null; $cfgTmp = $null; $carpetaOk = $null; $vacioDenegado = $false
if ($Verificar -and -not $Escribir) { Write-Error '-Verificar solo tiene sentido con -Escribir.'; exit 1 }
if ($Escribir) {
    if (-not $Carpeta) { Write-Error 'Escribir con agy exige -Carpeta (la carpeta autorizada).'; exit 1 }
    $rc = Resolve-Path -LiteralPath $Carpeta -ErrorAction SilentlyContinue
    if (-not $rc -or -not (Test-Path -LiteralPath $rc.Path -PathType Container)) { Write-Error "La carpeta '$Carpeta' no existe."; exit 1 }
    $carpetaOk = $rc.ProviderPath.TrimEnd('\')
    $motivo = Test-CarpetaEscribible $carpetaOk
    if ($motivo) { Write-Error $motivo; exit 1 }
    if ($Verificar -and (Test-Secreto $Verificar)) { Write-Error 'El comando de verificacion parece contener un secreto.'; exit 2 }
    if ($Verificar -match '[;&|<>`\r\n]') { Write-Error 'El comando de verificacion debe ser UN solo comando simple (sin ; & | < > ni saltos de linea).'; exit 1 }
    $candado = Lock-Carpeta $carpetaOk 'agy'
    if (-not $candado.ok) { Write-Error "La carpeta '$carpetaOk' esta siendo modificada por $($candado.dueno): espera a que termine (Codex y agy no escriben a la vez en la misma carpeta)."; Set-CausaActual -Texto "carpeta ocupada por $($candado.dueno)" -Salida 6; exit 6 }
    $antes = Get-InstantaneaCarpeta $carpetaOk
    $global:MIA_Checkpoint = New-Checkpoint $carpetaOk ('agy-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 6)))
    $extraDir = @('--add-dir', $carpetaOk, '--mode', 'accept-edits')
    if ($Verificar) {
        $cfgTmp = Join-Path $env:TEMP ('agy-set-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
        [IO.File]::WriteAllText($cfgTmp, (@{ permissions = @{ allow = @("command($Verificar)") } } | ConvertTo-Json -Depth 4 -Compress), (New-Object Text.UTF8Encoding($false)))
        $extraDir += @('--settings', $cfgTmp)
    }
}
try {
    # v1.9.1: timeout DURO de proceso (--print-timeout + 90 s de gracia). Si agy se cuelga, se mata todo el arbol (sin huerfanos) y se clasifica como timeout.
    $segEspera = if ($Espera -match '^(\d+)\s*(s|m|h)?$') { [int]$Matches[1] * @{ s = 1; m = 60; h = 3600 }[$(if ($Matches[2]) { $Matches[2] } else { 's' })] } else { 300 }
    # 2.3.11: agy en modo -p no puede correr comandos (permiso denegado -> respuesta vacia, p.ej. "numeros del 1 al 400"). Se le pide siempre responder directo en texto.
    $cola = if ($Escribir) {
        "`n`n(Carpeta de trabajo autorizada: $carpetaOk . Crea y edita archivos SOLO ahi, con ruta completa dentro de esa carpeta." + $(if ($Verificar) { " Despues de escribir, corre exactamente: $Verificar ; si falla, corregi y repeti." } else { ' No corras comandos.' }) + " Al terminar, resumi en pocas lineas que archivos tocaste y el resultado.)"
    } else { "`n`n(Responde directamente en texto; no uses herramientas ni comandos.)" }
    $argsAgy = @('-p', ($Prompt + $cola)) + $extraDir + @('--model', $Modelo, '--print-timeout', $Espera, '--output-format', 'json')
    # 3.3.0: la allow-list command(...) de agy solo coincide si agy ARRANCA en la carpeta autorizada (reproducido: desde otro directorio el comando era denegado y la respuesta salia vacia).
    $cwdPrev = [Environment]::CurrentDirectory
    if ($Escribir) { [Environment]::CurrentDirectory = $carpetaOk }
    try { $res = Invoke-ConTimeout $agy $argsAgy ($segEspera + 90) -Duro } finally { [Environment]::CurrentDirectory = $cwdPrev }
    if ($res.arranque -eq $false) { $msgA = "agy no arranca ($agy): $($res.error). Reinstalalo o corregi MULTIIA_AGY_EXE."; Set-CausaActual -Texto $msgA -Salida 126; Write-Error $msgA; exit 126 }
    $crudo = @($res.salida -split "\r?\n" | Where-Object { $_ -ne '' })
    $salida = [int]$res.codigo
    $global:MIA_Timeout = [bool]$res.timeout
    if ($res.error) { [IO.File]::WriteAllText($errArch, $res.error, (New-Object Text.UTF8Encoding($false))) }
    if ($res.timeout) { Write-Error "agy: timeout duro de proceso tras $($segEspera + 90) s (print_timeout $Espera); proceso y subprocesos terminados."; $salida = 124 }
} finally {
    # auditoria 1.8.0 (A-04): el temporal con el prompt se borra aunque se interrumpa (Ctrl+C / error)
    if ($tmpDir -and (Test-Path $tmpDir)) { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    if ($cfgTmp -and (Test-Path -LiteralPath $cfgTmp)) { Remove-Item -LiteralPath $cfgTmp -Force -ErrorAction SilentlyContinue }
    if ($candado -and $candado.ok) { Unlock-Carpeta $carpetaOk }   # el candado se libera siempre (tambien con timeout o Ctrl+C)
}

$errTxt = ''
if (Test-Path -LiteralPath $errArch) { $errTxt = (Get-Content -LiteralPath $errArch -Raw -Encoding UTF8 -ErrorAction SilentlyContinue); Remove-Item -LiteralPath $errArch -Force -ErrorAction SilentlyContinue }
$r = try { ($crudo -join "`n") | ConvertFrom-Json } catch { $null }
if ($global:MIA_Timeout) { Set-CausaActual -Texto "timeout duro de proceso (print_timeout $Espera) $errTxt" -Salida 124; $r = $null }
$tokIn = $null; $tokOut = $null
if ($r) {
    if ($r.conversation_id) { $global:MIA_Conf = 'conversation_id' }   # senal REAL: agy abrio una conversacion (la lee delegar.ps1)
    if ($r.usage -and ($null -ne $r.usage.input_tokens -or $null -ne $r.usage.output_tokens)) { $tokIn = [long]$r.usage.input_tokens; $tokOut = [long]$r.usage.output_tokens }   # sin campos de tokens = ausente (no 0)
    if ($r.status -eq 'SUCCESS' -and -not "$($r.response)".Trim()) {
        # v1.8.0: SUCCESS con respuesta vacia (p.ej. agy intento usar una herramienta denegada) NO es exito: se marca falla para que delegar.ps1 recupere.
        $den = if ($r.denied_actions) { ' acciones denegadas: ' + ((@($r.denied_actions) | % { $_.display_name }) -join ',') } else { '' }
        $msg = "agy devolvio una respuesta vacia (modelo: $Modelo).$den"; Write-Error $msg; $salida = 1; Set-CausaActual -Texto "$msg $errTxt" -Salida $salida; $vacioDenegado = [bool]$r.denied_actions
    }
    elseif ($r.status -eq 'SUCCESS' -and (Test-AgyTruncado $r)) {
        # v1.9.2: finished_reason estructurado indica corte por largo: NO es exito (el texto llegaria incompleto).
        $msg = "agy devolvio una respuesta truncada (finished_reason=$($r.finished_reason), modelo: $Modelo)."; Write-Error $msg; $salida = 1; Set-CausaActual -Texto (Get-TextoFalloAgy $r $errTxt) -Salida $salida
    }
    elseif ($r.status -eq 'SUCCESS') { "$($r.response)".TrimEnd() }
    else {
        $d = ($crudo -join ' '); $pista = if ($d -match '(?i)auth|login|credential|unauthenticated|sign.?in') { ' PISTA: agy no tiene sesión, abrilo y logueate con Google.' } else { '' }
        $msg = "agy: " + $r.status + " " + $d.Substring(0, [math]::Min(300, $d.Length)) + " (modelo: $Modelo)." + $pista
        Write-Error (Hide-Secretos $msg); if ($salida -eq 0) { $salida = 1 }; Set-CausaActual -Texto "$(Get-TextoFalloAgy $r $errTxt) $msg" -Salida $salida
    }
} elseif (-not $global:MIA_Timeout) {
    $msg = "agy no devolvió JSON: " + (($crudo | Select-Object -First 3) -join ' ')
    Write-Error (Hide-Secretos $msg); if ($salida -eq 0) { $salida = 1 }; Set-CausaActual -Texto "$errTxt $msg" -Salida $salida
}
if ($Escribir -and $antes) {
    # Registro de cambios (lo que realmente cambio en disco, no lo que agy dice) + deteccion de tarea incompleta.
    $desp = Get-InstantaneaCarpeta $carpetaOk
    if ($desp) {
        $nuevos = @($desp.Keys | Where-Object { -not $antes.ContainsKey($_) }); $borrados = @($antes.Keys | Where-Object { -not $desp.ContainsKey($_) })
        $mod = @($desp.Keys | Where-Object { $antes.ContainsKey($_) -and $antes[$_] -ne $desp[$_] })
        $global:MIA_Cambios = [ordered]@{ creados = $nuevos; modificados = $mod; borrados = $borrados; carpeta = $carpetaOk; checkpoint = $global:MIA_Checkpoint }
        Write-Output ("[cambios de agy en {0}: {1} creados, {2} modificados, {3} borrados{4}]" -f $carpetaOk, $nuevos.Count, $mod.Count, $borrados.Count, $(if ($global:MIA_Checkpoint) { " · checkpoint: $global:MIA_Checkpoint" } else { ' · sin checkpoint (carpeta muy grande)' }))
        foreach ($x in ($nuevos + $mod)) { Write-Output "  + $x" }; foreach ($x in $borrados) { Write-Output "  - $x (borrado)" }
        if ($salida -eq 0 -and ($nuevos.Count + $mod.Count + $borrados.Count) -eq 0) { $m = 'agy termino sin tocar ningun archivo: la tarea de escritura NO se cumplio.'; Write-Error $m; $salida = 1; Set-CausaActual -Texto $m -Salida 1 }
        if ($salida -eq 0 -and $r -and $r.denied_actions) { Write-Warning ('agy tuvo acciones DENEGADAS (verifica que quedo completo): ' + ((@($r.denied_actions) | % { $_.display_name }) -join ', ')) }
        # VERIFICACION propia: no se confia en lo que agy dice. El orquestador corre el comando de pruebas (UN comando simple, ya validado) en la carpeta autorizada.
        # Si agy escribio pero un comando suyo fue denegado (respuesta vacia) y las pruebas pasan, la tarea se da por cumplida CON aviso (no se reintenta con otro motor sobre cambios ya hechos).
        if ($Verificar -and ($nuevos.Count + $mod.Count) -gt 0 -and $salida -in 0, 1 -and -not $global:MIA_Timeout) {
            $partes = @($Verificar -split '\s+' | Where-Object { $_ })
            $cwdAnt = [Environment]::CurrentDirectory
            try {
                [Environment]::CurrentDirectory = $carpetaOk
                $v = Invoke-ConTimeout $partes[0] @($partes | Select-Object -Skip 1) 300 -Duro
            } finally { [Environment]::CurrentDirectory = $cwdAnt }
            $vok = ($v.arranque -ne $false) -and (-not $v.timeout) -and ([int]$v.codigo -eq 0)
            $vtxt = (Hide-Secretos ((@($v.salida -split "\r?\n") + @($v.error -split "\r?\n")) | Where-Object { $_ } | Select-Object -Last 8) -join ' | ')
            Write-Output ("[verificacion propia: {0} · {1}]" -f $(if ($vok) { 'OK' } else { "FALLO (codigo $($v.codigo))" }), $Verificar)
            if ($vtxt) { Write-Output "  $vtxt" }
            if (-not $vok -and $salida -eq 0) { $m = "las pruebas ($Verificar) FALLARON tras la escritura de agy."; Write-Error $m; $salida = 1; Set-CausaActual -Texto $m -Salida 1 }
            elseif ($vok -and $salida -eq 1 -and $vacioDenegado) { Write-Warning 'agy no devolvio texto (un comando suyo fue denegado) pero escribio y las pruebas propias pasan: se da por cumplida.'; $salida = 0; $global:MIA_Causa = $null }
        }
    }
}
$convId = if ($r -and $r.conversation_id) { [string]$r.conversation_id } else { '' }
$ma =Get-ModeloAgy -ConversationId $convId
$global:MIA_Modelo = [ordered]@{ confirmado = $(if ($ma) { $ma.modelo } else { '' }); fuente = $(if ($ma) { $ma.fuente } else { '' }); ejecutor_id = $convId }
Add-Uso -Destino 'agy' -Modelo $Modelo -Esfuerzo '' -Chars $charsPrompt -Segundos $sw.Elapsed.TotalSeconds -Salida $salida -ConMemoria ([bool]$ConMemoria) -TokIn $tokIn -TokOut $tokOut -Modo $cfg.modo -Cuenta $Cuenta -ModeloConf $global:MIA_Modelo.confirmado -ModeloFuente $global:MIA_Modelo.fuente
exit $salida
