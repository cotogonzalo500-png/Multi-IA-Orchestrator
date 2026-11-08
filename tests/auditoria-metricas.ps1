# 2.3.0 · Regresion de la auditoria Codex de metricas (evidencias\v2.3.0\auditoria-codex-metricas.md).
# Datos propios en una carpeta aislada (MULTIIA_DATOS temporal); corre los scripts reales sin mocks y no toca .multi-ia-orquestador.
$ErrorActionPreference = 'Stop'
$raiz = Split-Path $PSScriptRoot -Parent
$sc = Join-Path $raiz 'scripts'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('multiia-audit-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp | Out-Null
$real = Join-Path $env:USERPROFILE '.multi-ia-orquestador'
function Huella { $h = ''; foreach ($f in 'uso.jsonl', 'costo-claude.jsonl', 'config.json') { $p = Join-Path $real $f; if (Test-Path $p) { $h += (Get-FileHash $p).Hash } }; $h }
$antes = Huella
$envPrevio = $env:MULTIIA_DATOS
$env:MULTIIA_DATOS = $tmp
$script:ok = 0; $script:mal = 0
function Chk($nombre, [bool]$cond, $detalle = '') { if ($cond) { $script:ok++; Write-Host "OK     $nombre" } else { $script:mal++; Write-Host "FALLA  $nombre $detalle" } }
function PS1([string]$s, [string[]]$a = @()) { $ErrorActionPreference = 'Continue'; (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $sc $s) @a 2>&1 | Out-String) }
function J($h) { $h | ConvertTo-Json -Compress }
function Escribir($nombre, $lineas) { [IO.File]::WriteAllLines((Join-Path $tmp $nombre), [string[]]$lineas, (New-Object Text.UTF8Encoding($false))) }
$f1 = (Get-Date).AddHours(-2).ToString('s'); $f2 = (Get-Date).AddHours(-1).ToString('s')
try {
    # --- Hallazgo 1 y 8: fila de uso duplicada tal cual + una fila sin duracion ---
    $fila = J ([ordered]@{ fecha = $f1; destino = 'codex'; tok_in = 60; tok_out = 50; tok_estado = 'informado'; seg = 10; salida = 0; sesion = 'chat-A'; ej = 'ej-1'; origen = 'real' })
    $sinSeg = J ([ordered]@{ fecha = $f2; destino = 'codex'; tok_in = 0; tok_out = 0; tok_estado = 'ausente'; salida = 0; sesion = 'chat-A'; ej = 'ej-2'; origen = 'real' })
    Escribir 'uso.jsonl' @($fila, $fila, $sinSeg)
    $c = (PS1 'consumo.ps1') | ConvertFrom-Json
    Chk 'consumo: una fila repetida tal cual cuenta una vez (110, no 220)' ($c.global.tok_total -eq 110) "tok_total=$($c.global.tok_total)"
    Chk 'consumo: pedidos sin duplicar (2)' ($c.global.pedidos -eq 2) "pedidos=$($c.global.pedidos)"
    Chk 'consumo: una duracion ausente no baja el promedio (10, no 5)' ($c.global.seg_medio -eq 10) "seg_medio=$($c.global.seg_medio)"
    # --- Hallazgo 7: sin costo-claude.jsonl el estimado es «sin dato», no 0 ---
    Chk 'consumo: sin costo-claude.jsonl el estimado de Claude es null' ($null -eq $c.claude_estimado_tok) "valor=$($c.claude_estimado_tok)"
    Chk 'consumo -Texto: muestra «sin dato» y no 0' ((PS1 'consumo.ps1' @('-Texto')) -match 'Claude \(estimado\) sin dato')

    # --- Hallazgo 2: costo duplicado no se suma dos veces ---
    $costo = J ([ordered]@{ fecha = $f1; tok = 20; sesion = 'chat-A'; ej = 'ej-1'; origen = 'real' })
    Escribir 'costo-claude.jsonl' @($costo, $costo)
    $a = (PS1 'ahorro.ps1') | ConvertFrom-Json
    $est = @($a.global.claude_estimado, $a.claude_estimado) | Where-Object { $_ } | Select-Object -First 1
    Chk 'ahorro: costo repetido tal cual cuenta una vez (20, no 40)' ($est.valor -eq 20) "valor=$($est.valor)"
    $c2 = (PS1 'consumo.ps1') | ConvertFrom-Json
    Chk 'consumo: costo repetido cuenta una vez (20)' ($c2.claude_estimado_tok -eq 20) "valor=$($c2.claude_estimado_tok)"

    # --- Hallazgo 3: costo por chat parcial cuando una delegacion no trae tok ---
    $sinTok = J ([ordered]@{ fecha = $f2; sesion = 'chat-A'; ej = 'ej-2'; origen = 'real' })
    Escribir 'costo-claude.jsonl' @($costo, $sinTok)
    $ch = (PS1 'chats.ps1' @('-Chat', 'chat-A', '-SinClaude')) | ConvertFrom-Json
    $uno = @(@($ch.chats) + @($ch) | Where-Object { $_.id_chat -eq 'chat-A' })[0]
    $e = $uno.consumo.claude_estimado_delegaciones
    Chk 'chats: costo con una fila sin tok queda PARCIAL' ($e.parcial -eq $true) "parcial=$($e.parcial)"
    Chk 'chats: el valor parcial suma solo lo conocido (20)' ($e.valor -eq 20) "valor=$($e.valor)"
    Escribir 'costo-claude.jsonl' @($sinTok)
    $ch = (PS1 'chats.ps1' @('-Chat', 'chat-A', '-SinClaude')) | ConvertFrom-Json
    $uno = @(@($ch.chats) + @($ch) | Where-Object { $_.id_chat -eq 'chat-A' })[0]
    Chk 'chats: sin ningun tok el costo es «sin dato» (null, no 0)' ($null -eq $uno.consumo.claude_estimado_delegaciones.valor) "valor=$($uno.consumo.claude_estimado_delegaciones.valor)"

    # --- Hallazgo 4: -Texto conserva el PARCIAL del costo economico (se valida en el codigo: el precio exige config) ---
    Chk 'ahorro: costo_economico propaga parcial' ((Get-Content (Join-Path $sc 'ahorro.ps1') -Raw) -match '\$ce\.parcial = @\(\$dinero\.Values')

    # --- Hallazgo 5: una fila de uso de prueba no se cruza con una ejecucion real ---
    $dec = J ([ordered]@{ id = 'ej-9'; fecha = $f2; tarea = 'codigo'; destino = 'codex'; resultado = 'fin'; seg = 30; tok = 0; origen = 'real'; sesion = 'chat-A' })
    $usoTest = J ([ordered]@{ fecha = $f2; destino = 'codex'; tok_in = 7; tok_out = 7; tok_estado = 'informado'; seg = 5; salida = 0; sesion = 'chat-A'; origen = 'test' })
    Escribir 'decisiones.jsonl' @($dec)
    Escribir 'uso.jsonl' @($usoTest)
    $t = (PS1 'trazabilidad.ps1' @('-Json')) | ConvertFrom-Json
    $fila9 = @(@($t.filas) + @($t) | Where-Object { $_.id -eq 'ej-9' })[0]
    Chk 'trazabilidad: sin -Todo la fila de prueba no se asigna a la ejecucion real' ($fila9 -and $null -eq $fila9.tok_uso) "tok_uso=$($fila9.tok_uso)"

    # --- 2.3.0: filas identicas SIN ej no se colapsan (dos registros legitimos del mismo segundo) ---
    $sinEj = J ([ordered]@{ fecha = $f1; destino = 'codex'; tok_in = 10; tok_out = 0; tok_estado = 'informado'; seg = 1; salida = 0; sesion = 'chat-B'; origen = 'real' })
    Escribir 'uso.jsonl' @($sinEj, $sinEj, $sinEj)
    $c3 = (PS1 'consumo.ps1') | ConvertFrom-Json
    Chk 'consumo: 3 filas identicas sin ej cuentan 3 veces (30)' ($c3.global.tok_total -eq 30) "tok_total=$($c3.global.tok_total)"
    # --- 2.3.0: Get-TokensPorHora separa codex y agy (grafico 24h por motor) ---
    $usoH = @(
        [pscustomobject]@{ fecha = (Get-Date).AddMinutes(-30).ToString('s'); destino = 'codex'; tok_in = 100; tok_out = 0 },
        [pscustomobject]@{ fecha = (Get-Date).AddMinutes(-20).ToString('s'); destino = 'agy'; tok_in = 40; tok_out = 2 })
    . (Join-Path $sc '_comun.ps1')
    $hx = @(Get-TokensPorHora -Mensajes @() -Uso $usoH)
    $sCx = ($hx | Measure-Object codex -Sum).Sum; $sAg = ($hx | Measure-Object agy -Sum).Sum; $sD = ($hx | Measure-Object deleg -Sum).Sum
    Chk 'Get-TokensPorHora: 24 franjas con codex y agy' ($hx.Count -eq 24 -and $null -ne $hx[0].codex -and $null -ne $hx[0].agy) "n=$($hx.Count)"
    Chk 'Get-TokensPorHora: codex 100 + agy 42 = delegado 142' ($sCx -eq 100 -and $sAg -eq 42 -and $sD -eq 142) "codex=$sCx agy=$sAg deleg=$sD"

    # --- Hallazgo 6: tokens desconocidos no dan «coincide» (necesita un registro del ejecutor: se valida en el codigo) ---
    $tz = Get-Content (Join-Path $sc 'trazabilidad.ps1') -Raw
    Chk 'trazabilidad: uso sin tokens informados da «incompleto»' ($tz -match "usoSinDato = .*Get-EstadoTokens" -and $tz -match "-not \`$u -or \`$usoSinDato\) \{ 'incompleto' \}")
} finally {
    $env:MULTIIA_DATOS = $envPrevio
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Chk 'no toco .multi-ia-orquestador real' ((Huella) -eq $antes)
Write-Host ("auditoria-metricas: {0} ok, {1} fallas" -f $script:ok, $script:mal)
if ($script:mal) { exit 1 }
