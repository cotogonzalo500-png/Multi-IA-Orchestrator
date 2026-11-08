# Reinicio controlado de Claude (app de escritorio) o de los componentes del orquestador Multi-IA.
#   .\reiniciar-claude.ps1                      -> solo VERIFICA (JSON): instancia, forma de lanzamiento y trabajo pendiente. No toca nada.
#   .\reiniciar-claude.ps1 -Si                  -> reinicia Claude: un supervisor INDEPENDIENTE cierra la app y la vuelve a abrir.
#   .\reiniciar-claude.ps1 -Modo orquestador -Si -> reinicia SOLO el orquestador (panel web y procesos del plugin); Claude no se cierra.
#   -Forzar    reinicia aunque haya delegaciones a Codex/Antigravity en curso (se pierden).
#   -Aviso     muestra una ventana con el resultado (lo usa el acceso directo del escritorio).
#   -DryRun    hace todo menos cerrar/abrir procesos (pruebas).
# Es autonomo (no necesita el panel ni el plugin cargado): se copia a ~\.claude\multi-ia-estable\ para el acceso directo.
# Solo toca procesos de la app Claude instalada (paquete AppX) y sus hijos; no cierra nada ajeno. No pide administrador.
param(
    [ValidateSet('claude', 'orquestador')][string]$Modo = 'claude',
    [switch]$Si, [switch]$Forzar, [switch]$Aviso, [switch]$DryRun,
    [switch]$Supervisor, [string]$EstadoArchivo = ''   # internos: el segundo proceso que hace el trabajo
)
$ErrorActionPreference = 'Stop'
$datos = if ($env:MULTIIA_DATOS) { $env:MULTIIA_DATOS } else { Join-Path $env:USERPROFILE '.multi-ia-orquestador' }   # 2.3.1 (Codex #11): sin ruta fija de un usuario
if (-not (Test-Path -LiteralPath $datos)) { New-Item -ItemType Directory -Path $datos -Force | Out-Null }
$logArchivo = Join-Path $datos 'reinicios.jsonl'
$yo = $MyInvocation.MyCommand.Path

# Registro consultable (una linea JSON por paso). Nunca se escriben claves ni tokens: solo ids de proceso y mensajes.
function Log([string]$nivel, [string]$msg) {
    $o = [ordered]@{ fecha = (Get-Date).ToString('s'); modo = $Modo; nivel = $nivel; msg = $msg; pid = $PID }
    try { Add-Content -LiteralPath $logArchivo -Value ($o | ConvertTo-Json -Compress) -Encoding UTF8 } catch { }
    # La consola del panel muestra el resultado (misma linea que Add-Evento).
    if ($nivel -in 'fin', 'error') {
        try {
            $e = [ordered]@{ fecha = (Get-Date).ToString('s'); tipo = $(if ($nivel -eq 'error') { 'error' } else { 'fin' }); destino = 'reinicio'; detalle = "reinicio $Modo"; motivo = $msg; tarea = 'reinicio'; tok = 0; seg = 0; origen = $(if ($DryRun) { 'test' } elseif ($env:MULTIIA_ORIGEN -match '^(real|test|simulacion|benchmark|desarrollo)$') { $env:MULTIIA_ORIGEN } else { 'real' }) }
            # 2.3.1 (auditoria Codex #8): mismo candado con nombre que Add-LineaJsonl (_comun.ps1): sin el, dos escritores a la vez podian mezclar o perder lineas.
            $ev = Join-Path $datos 'eventos.jsonl'
            $mx = [System.Threading.Mutex]::new($false, 'Global\MultiIA_jsonl_eventos.jsonl'); $tom = $false
            try {
                try { $tom = $mx.WaitOne(10000) } catch [System.Threading.AbandonedMutexException] { $tom = $true }
                [IO.File]::AppendAllText($ev, ($e | ConvertTo-Json -Compress) + "`r`n", (New-Object Text.UTF8Encoding($false)))
            } finally { if ($tom) { try { $mx.ReleaseMutex() } catch { } }; $mx.Dispose() }
        } catch { }
    }
}
function Avisar([string]$titulo, [string]$texto) {
    if (-not $Aviso) { return }
    try { Add-Type -AssemblyName System.Windows.Forms; [void][Windows.Forms.MessageBox]::Show($texto, $titulo) } catch { }
}

# ---- Deteccion de la app instalada y de su arbol de procesos
function Get-AppInfo {
    $pkg = Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $pkg) { return $null }
    $app = Get-StartApps | Where-Object { $_.AppID -like "$($pkg.PackageFamilyName)!*" } | Select-Object -First 1
    [pscustomobject]@{ Raiz = $pkg.InstallLocation; Aumid = $(if ($app) { $app.AppID } else { "$($pkg.PackageFamilyName)!Claude" }); Version = [string]$pkg.Version }
}
function Get-Arbol($info) {
    $todos = @(Get-CimInstance Win32_Process)
    $porPid = @{}; foreach ($p in $todos) { $porPid[[int]$p.ProcessId] = $p }
    # raices = procesos de la app (ejecutable dentro del paquete) cuyo padre NO es otro proceso de la app
    $deApp = @($todos | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($info.Raiz, [StringComparison]::OrdinalIgnoreCase) })
    $ids = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($p in $deApp) { [void]$ids.Add([int]$p.ProcessId) }
    do {  # hijos (incluye los claude.exe de las sesiones de Claude Code que cuelgan de la app)
        $antes = $ids.Count
        foreach ($p in $todos) { if ($ids.Contains([int]$p.ParentProcessId) -and -not $ids.Contains([int]$p.ProcessId)) { [void]$ids.Add([int]$p.ProcessId) } }
    } while ($ids.Count -ne $antes)
    $ids.Remove([int]$PID) | Out-Null
    $mios = $ids | ForEach-Object { $porPid[$_] } | Where-Object { $_ }
    [pscustomobject]@{ Procesos = @($mios); Principales = @($deApp | Where-Object { $_.ParentProcessId -notin $deApp.ProcessId }); Todos = $todos }
}
function Get-Pendientes {
    # Delegaciones a otras IA en curso (cerrar Claude las dejaria huerfanas y se perderia su resultado).
    @(Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'delegar(-codex|-agy)?\.ps1' } |
        ForEach-Object { [pscustomobject]@{ pid = $_.ProcessId; cmd = ($_.CommandLine -replace '-Prompt\s+("[^"]*"|\S+)', '-Prompt …') } })
}
function Get-Vigilancia {
    # Estado a conservar para reanudar: conversacion que pidio el reinicio (si hay) y fecha.
    [ordered]@{ fecha = (Get-Date).ToString('s'); sesion = [string]$env:CLAUDE_CODE_SESSION_ID; ventana = [string]$env:CLAUDE_CODE_HOST_SESSION_ID; instancia = [string]$env:CLAUDE_PID; cwd = (Get-Location).Path }
}

# ======================= SUPERVISOR (proceso independiente) =======================
if ($Supervisor) {
    try {
        $est = Get-Content -LiteralPath $EstadoArchivo -Raw -Encoding UTF8 | ConvertFrom-Json
        Log 'info' "supervisor $PID listo: cerrar $(@($est.procesos).Count) procesos y relanzar por $($est.aumid)"
        Start-Sleep -Seconds 2   # deja que quien lo pidio termine de contestar
        $obj = @($est.procesos | ForEach-Object { $p = Get-Process -Id $_.pid -ErrorAction SilentlyContinue; if ($p -and $p.StartTime -and $p.StartTime.ToString('s') -eq $_.inicio) { $p } })   # mismo PID Y mismo inicio: no mata un proceso ajeno que reuso el PID
        # 1) cierre amable de las ventanas principales
        foreach ($p in $obj) { try { if ($p.MainWindowHandle -ne 0) { [void]$p.CloseMainWindow() } } catch { } }
        $limite = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $limite -and @($obj | Where-Object { -not $_.HasExited }).Count -gt 0) { Start-Sleep -Milliseconds 500 }
        # 2) lo que siga vivo se cierra a la fuerza (solo procesos de la app)
        $vivos = @($obj | Where-Object { -not $_.HasExited })
        if ($vivos.Count) { Log 'info' "cierre forzado de $($vivos.Count) procesos que no cerraron solos"; $vivos | ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction Stop } catch { Log 'aviso' "no se pudo cerrar $($_.Id): $($_.Exception.Message)" } } }
        $limite = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $limite -and @($obj | Where-Object { -not $_.HasExited }).Count -gt 0) { Start-Sleep -Milliseconds 500 }
        $resto = @($obj | Where-Object { -not $_.HasExited })
        if ($resto.Count) { throw "quedaron $($resto.Count) procesos sin cerrar; no se relanza para no duplicar" }
        Log 'info' 'Claude cerrado; relanzando'
        # 3) relanzar por el MISMO metodo que usa el menu Inicio para la app instalada
        Start-Process -FilePath 'explorer.exe' -ArgumentList "shell:AppsFolder\$($est.aumid)"
        $limite = (Get-Date).AddSeconds(60); $arriba = $null
        while ((Get-Date) -lt $limite -and -not $arriba) {
            Start-Sleep -Seconds 2
            $arriba = @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($est.raiz, [StringComparison]::OrdinalIgnoreCase) -and $_.Name -ieq 'Claude.exe' })
        }
        if (-not $arriba) { throw 'Claude no volvio a arrancar en 60 s' }
        Start-Sleep -Seconds 5
        $apps = @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($est.raiz, [StringComparison]::OrdinalIgnoreCase) -and $_.Name -ieq 'Claude.exe' })
        $padres = @($apps | Where-Object { $_.ParentProcessId -notin $apps.ProcessId })
        if ($padres.Count -gt 1) { Log 'aviso' "hay $($padres.Count) instancias principales de Claude (posible duplicado)" }
        # 4) el orquestador: se reconecta solo cuando Claude abre una sesion (el plugin se carga al inicio)
        $plug = ''
        try { $ip = Get-Content "$env:USERPROFILE\.claude\plugins\installed_plugins.json" -Raw | ConvertFrom-Json; $plug = ($ip.plugins.PSObject.Properties | Where-Object Name -like 'multi-ia-orquestador*' | ForEach-Object { $_.Value[0].version }) -join ',' } catch { }
        Log 'fin' "Claude reiniciado: $($padres.Count) instancia(s) principal(es), $($apps.Count) procesos; plugin Multi-IA registrado v$plug (se carga al abrir una sesion). Sesion anterior: $($est.vigilancia.sesion) (ver en la lista de chats; en CLI: claude --resume $($est.vigilancia.sesion))"
        Avisar 'Reiniciar Claude' 'Claude se reinició correctamente.'
        exit 0
    } catch {
        Log 'error' "reinicio de Claude FALLO: $($_.Exception.Message)"
        Avisar 'Reiniciar Claude' "No se pudo reiniciar Claude: $($_.Exception.Message)`nDetalle en reinicios.jsonl"
        exit 1
    }
}

# ======================= MODO ORQUESTADOR =======================
if ($Modo -eq 'orquestador') {
    $pend = @(Get-Pendientes)
    if ($pend.Count -and -not $Forzar) { Log 'error' "hay $($pend.Count) delegaciones en curso; no se reinicia (usar -Forzar)"; Write-Output "[PENDIENTE] hay $($pend.Count) delegaciones en curso. Esperá o usá -Forzar."; exit 4 }
    $web = @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'panel-servidor\.mjs' })
    $rapidos = @(Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match '(rapido|limites|claude-snapshot|panel)\.ps1' -and $_.CommandLine -match 'Multi-IA|multi-ia' })
    if (-not $Si) { [ordered]@{ modo = 'orquestador'; panel_web = $web.Count; procesos_de_lectura = $rapidos.Count; pendientes = $pend.Count; accion = 'agregar -Si para reiniciar' } | ConvertTo-Json -Compress; exit 0 }
    if ($DryRun) { Log 'fin' "DRYRUN orquestador: cerraria $($web.Count) panel web y $($rapidos.Count) lecturas"; Write-Output "[DRYRUN] cerraria $($web.Count) panel web y $($rapidos.Count) lecturas"; exit 0 }
    Log 'info' "reinicio del orquestador: panel web $($web.Count), lecturas $($rapidos.Count)"
    $scriptPanel = $null
    foreach ($p in $web) { if ($p.CommandLine -match '"?([^"]*panel-servidor\.mjs)') { $scriptPanel = $Matches[1] } }
    foreach ($p in @($web) + @($rapidos)) { try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch { Log 'aviso' "no se pudo cerrar $($p.ProcessId)" } }
    # Cache de cupos: se descarta para que el panel vuelva a leer todo desde cero (los datos reales de uso no se tocan).
    Remove-Item -LiteralPath (Join-Path $datos 'limites-cache.json') -ErrorAction SilentlyContinue
    $detalle = 'lecturas reiniciadas'
    if ($scriptPanel -and (Test-Path -LiteralPath $scriptPanel)) {
        Start-Process -FilePath 'node' -ArgumentList "`"$scriptPanel`"" -WindowStyle Hidden
        $ok = $false
        for ($i = 0; $i -lt 15 -and -not $ok; $i++) { Start-Sleep -Seconds 1; try { $ok = (Invoke-WebRequest -Uri 'http://127.0.0.1:8765/' -UseBasicParsing -TimeoutSec 3).StatusCode -eq 200 } catch { } }
        if (-not $ok) { Log 'error' 'el panel web no volvio a responder en 15 s'; Write-Output '[ERROR] el panel web no volvio a responder'; exit 1 }
        $detalle = 'panel web relanzado y respondiendo en 127.0.0.1:8765'
    }
    # Verificacion: la lectura rapida del plugin vuelve a andar
    $rap = Join-Path (Split-Path $yo -Parent) 'rapido.ps1'
    if (Test-Path -LiteralPath $rap) { $r = & powershell -NoProfile -ExecutionPolicy Bypass -File $rap 2>$null | Out-String; if (-not ($r | ConvertFrom-Json).modo) { Log 'error' 'rapido.ps1 no devolvio datos'; exit 1 }; $detalle += '; lectura rapida OK' }
    Log 'fin' "orquestador reiniciado: $detalle (Claude no se toco)"
    Write-Output "[OK] orquestador reiniciado: $detalle"
    exit 0
}

# ======================= MODO CLAUDE (preparacion) =======================
$info = Get-AppInfo
if (-not $info) { Log 'error' 'no se encontro la app Claude instalada (paquete AppX)'; Write-Output '[ERROR] no se encontro la app Claude de escritorio instalada.'; Avisar 'Reiniciar Claude' 'No se encontró la app Claude instalada.'; exit 2 }
$arbol = Get-Arbol $info
$pend = @(Get-Pendientes)
$resumen = [ordered]@{
    metodo = 'app de escritorio (paquete AppX) · relanzado con shell:AppsFolder\' + $info.Aumid
    version = $info.Version; procesos = $arbol.Procesos.Count; principales = @($arbol.Principales | ForEach-Object { $_.ProcessId })
    sesiones_claude_code = @($arbol.Procesos | Where-Object { $_.Name -ieq 'claude.exe' -and $_.ExecutablePath -notlike "$($info.Raiz)*" }).Count
    delegaciones_en_curso = $pend.Count
    advertencia = 'Se cierran TODAS las ventanas/chats de la app Claude (es una sola aplicacion). Los chats quedan guardados y se reabren desde la lista; el texto sin enviar de cada ventana se pierde.'
}
if ($arbol.Procesos.Count -eq 0) { Log 'info' 'Claude no estaba corriendo: solo se lo abre' }
if (-not $Si) { $resumen | ConvertTo-Json -Compress; exit 0 }
if ($Aviso -and -not $DryRun) {   # acceso directo del escritorio: pedir confirmacion antes de cerrar nada
    Add-Type -AssemblyName System.Windows.Forms
    $txt = "Se van a cerrar TODAS las ventanas de Claude ($($arbol.Procesos.Count) procesos) y se volverá a abrir.`nLos chats quedan guardados; el texto sin enviar se pierde.`n¿Reiniciar ahora?"
    if ([Windows.Forms.MessageBox]::Show($txt, 'Reiniciar Claude', 'YesNo', 'Warning') -ne 'Yes') { Log 'info' 'reinicio cancelado por el usuario'; exit 5 }
}
if ($pend.Count -and -not $Forzar) {
    Log 'error' "reinicio cancelado: $($pend.Count) delegaciones en curso"
    Write-Output "[PENDIENTE] hay $($pend.Count) delegaciones a otras IA en curso; cerrar Claude las perderia. Esperá que terminen o usá -Forzar."
    Avisar 'Reiniciar Claude' "Hay $($pend.Count) delegaciones en curso. Esperá a que terminen."
    exit 4
}
$est = [ordered]@{
    aumid = $info.Aumid; raiz = $info.Raiz; vigilancia = Get-Vigilancia
    procesos = @($arbol.Procesos | ForEach-Object { $pr = Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue; if ($pr -and $pr.StartTime) { [ordered]@{ pid = $pr.Id; inicio = $pr.StartTime.ToString('s'); nombre = $pr.ProcessName } } } | Where-Object { $_ })
}
$estArchivo = Join-Path $datos 'reinicio-estado.json'
$est | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $estArchivo -Encoding UTF8
Log 'info' "reinicio de Claude pedido: $(@($est.procesos).Count) procesos de la app; sesion $($est.vigilancia.sesion)"
if ($DryRun) { Log 'fin' "DRYRUN Claude: cerraria $(@($est.procesos).Count) procesos y relanzaria por $($info.Aumid)"; Write-Output "[DRYRUN] cerraria $(@($est.procesos).Count) procesos y relanzaria con shell:AppsFolder\$($info.Aumid)"; exit 0 }

# El supervisor se crea por WMI: su padre es el servicio WMI, NO Claude, asi que no muere cuando se cierra la app (aunque este script corra dentro de ella).
$ps = (Get-Command powershell.exe).Source
$cmd = "`"$ps`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$yo`" -Supervisor -Modo claude -EstadoArchivo `"$estArchivo`"" + $(if ($Aviso) { ' -Aviso' } else { '' })
$r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd }
if ($r.ReturnValue -ne 0) { Log 'error' "no se pudo crear el supervisor (codigo $($r.ReturnValue))"; Write-Output "[ERROR] no se pudo crear el supervisor ($($r.ReturnValue))"; exit 1 }
Log 'info' "supervisor independiente lanzado (pid $($r.ProcessId))"
Write-Output "[OK] reinicio programado: el supervisor $($r.ProcessId) cierra Claude y lo vuelve a abrir en unos segundos. Resultado en reinicios.jsonl."
exit 0
