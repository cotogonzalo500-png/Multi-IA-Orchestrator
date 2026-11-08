# Pruebas FUNCIONALES con datos propios en una carpeta aislada (MULTIIA_DATOS temporal).
# No toca .multi-ia-orquestador real, ni la instalacion estable, ni otras sesiones. Corre los scripts reales (sin mocks).
$ErrorActionPreference = 'Stop'
$raiz = Split-Path $PSScriptRoot -Parent
$sc = Join-Path $raiz 'scripts'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('multiia-func-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp | Out-Null
$real = Join-Path $env:USERPROFILE '.multi-ia-orquestador'
function Huella { $h = ''; foreach ($f in 'uso.jsonl', 'config.json') { $p = Join-Path $real $f; if (Test-Path $p) { $h += (Get-FileHash $p).Hash } }; $h }
$antes = Huella
$env:MULTIIA_DATOS = $tmp
$env:CLAUDE_CODE_SESSION_ID = ''
$script:ok = 0; $script:mal = 0
function Chk($nombre, [bool]$cond, $detalle = '') {
    if ($cond) { $script:ok++; Write-Host "OK     $nombre" } else { $script:mal++; Write-Host "FALLA  $nombre $detalle" }
}
function PS1([string]$s, [string[]]$a = @()) { $ErrorActionPreference = 'Continue'; (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $sc $s) @a 2>&1 | Out-String) }
function Fecha($d) { (Get-Date).Date.AddDays(-$d).AddHours(10).ToString('s') }
function J($h) { $h | ConvertTo-Json -Compress }
$utf8 = New-Object Text.UTF8Encoding($false)
try {
    # Datos propios: chat-A y chat-B con consumos distintos repartidos en 25 dias.
    $uso = @(
        (J @{ fecha = (Fecha 2); destino = 'codex'; tok_in = 600; tok_out = 400; salida = 0; sesion = 'chat-A'; ej = 'ej-a1'; origen = 'real' }),
        (J @{ fecha = (Fecha 15); destino = 'codex'; tok_in = 3000; tok_out = 2000; salida = 0; sesion = 'chat-B'; ej = 'ej-b1'; origen = 'real' }),
        (J @{ fecha = (Fecha 25); destino = 'agy'; tok_in = 4000; tok_out = 3000; salida = 0; sesion = 'chat-B'; ej = 'ej-b2'; origen = 'real' })
    )
    [IO.File]::WriteAllLines("$tmp\uso.jsonl", $uso, $utf8)
    $evs = @()
    foreach ($e in @(@('chat-A', 'ej-a1', 'codex', 2), @('chat-B', 'ej-b1', 'codex', 15), @('chat-B', 'ej-b2', 'agy', 25))) {
        $f = Fecha $e[3]
        $evs += J @{ fecha = $f; tipo = 'inicio'; destino = $e[2]; id = $e[1]; tarea = 'codigo'; origen = 'real'; sesion = $e[0] }
        $evs += J @{ fecha = $f; tipo = 'fin'; destino = $e[2]; id = $e[1]; tarea = 'codigo'; tok = 1000; seg = 5; origen = 'real'; sesion = $e[0] }
    }
    # Evento de prueba que NO debe contaminar nada.
    $evs += J @{ fecha = (Get-Date).AddMinutes(-5).ToString('s'); tipo = 'fin'; destino = 'codex'; id = 'ej-test'; tarea = 'x'; tok = 99999; origen = 'test'; sesion = 'chat-A' }
    [IO.File]::WriteAllLines("$tmp\eventos.jsonl", $evs, $utf8)

    # 1) 7d vs 30d (rapido.ps1 real)
    $r = (PS1 'rapido.ps1') | ConvertFrom-Json
    $d = @($r.dias)
    $s7 = ($d | Select-Object -Last 7 | ForEach-Object { $_.codex + $_.agy } | Measure-Object -Sum).Sum
    $s30 = ($d | Select-Object -Last 30 | ForEach-Object { $_.codex + $_.agy } | Measure-Object -Sum).Sum
    Chk '7d suma solo los ultimos 7 dias (1000)' ($s7 -eq 1000) "s7=$s7"
    Chk '30d suma 1000 + 5000 + 7000 = 13000' ($s30 -eq 13000) "s30=$s30"
    Chk '7d y 30d dan resultados distintos' ($s7 -ne $s30)
    Chk 'serie diaria de 30 dias' ($d.Count -eq 30) "n=$($d.Count)"

    # 2) Este chat con datos propios (chats.ps1 real)
    $env:CLAUDE_CODE_SESSION_ID = 'chat-A'
    $raw = PS1 'chats.ps1' @('-Json')
    $c = $raw | ConvertFrom-Json
    Write-Host ('       chats.ps1 -> ' + ($raw.Substring(0, [Math]::Min(300, $raw.Length)) -replace "\s+", ' '))
    Chk 'el chat actual se detecta como chat-A' ($c.chat_actual -eq 'chat-A') "actual=$($c.chat_actual)"
    $ca = @($c.chats) | Where-Object { $_.id_chat -eq 'chat-A' }
    $cb = @($c.chats) | Where-Object { $_.id_chat -eq 'chat-B' }
    Chk 'chat-A: Codex 1000 y Antigravity sin consumo propio' ($ca -and $ca.consumo.codex.valor -eq 1000 -and $null -eq $ca.consumo.antigravity.valor) "codex=$($ca.consumo.codex.valor)"
    Chk 'chat-B: Codex 5000 y Antigravity 7000 (aislado de A)' ($cb -and $cb.consumo.codex.valor -eq 5000 -and $cb.consumo.antigravity.valor -eq 7000)
    Chk 'lo de origen test no entra en el consumo de ningun chat' ($ca.consumo.codex.valor -eq 1000 -and $ca.delegaciones -eq 1)
    $env:CLAUDE_CODE_SESSION_ID = ''

    # 3) Intensidad global y por chat (intensidad.ps1 real)
    foreach ($v in 'bajo', 'medio', 'alto', 'automatico') {
        $null = PS1 'intensidad.ps1' @('-Valor', $v, '-Global')
        $raw = PS1 'intensidad.ps1' @('-Ver', '-Chat', 'chat-A', '-Json')
        Write-Host ("       -Ver -> " + ($raw -replace "\s+", ' '))
        Chk "global $v : un chat sin preferencia hereda $v" ($raw -match $v)
    }
    $null = PS1 'intensidad.ps1' @('-Valor', 'alto', '-Global')
    $null = PS1 'intensidad.ps1' @('-Valor', 'bajo', '-Chat', 'chat-A')
    $ra = PS1 'intensidad.ps1' @('-Ver', '-Chat', 'chat-A', '-Json')
    $rb = PS1 'intensidad.ps1' @('-Ver', '-Chat', 'chat-B', '-Json')
    Write-Host ("       A -> " + ($ra -replace "\s+", ' '))
    Write-Host ("       B -> " + ($rb -replace "\s+", ' '))
    Chk 'chat-A con Bajo propio (gana a la global Alto)' ($ra -match 'bajo')
    Chk 'chat-B sigue heredando Alto (no se contamina)' ($rb -match 'alto' -and $rb -notmatch '"valor"\s*:\s*"bajo"')
    $null = PS1 'intensidad.ps1' @('-Quitar', '-Chat', 'chat-A')
    $ra2 = PS1 'intensidad.ps1' @('-Ver', '-Chat', 'chat-A', '-Json')
    Chk 'Heredar global: chat-A vuelve a Alto' ($ra2 -match 'alto' -and $ra2 -notmatch '"valor"\s*:\s*"bajo"')
    $mal1 = PS1 'intensidad.ps1' @('-Valor', 'extremo', '-Global')
    Chk 'un valor invalido se rechaza' ($mal1 -match 'extremo|Validate|v.lido|inv.lido')

    # 4) Apagar / Encender (config.ps1 real, config aislada)
    $null = PS1 'config.ps1' @('-Apagar')
    $off = (PS1 'rapido.ps1') | ConvertFrom-Json
    Chk 'Apagar: el panel lee activo=false' ($off.activo -eq $false) "activo=$($off.activo)"
    $null = PS1 'config.ps1' @('-Encender')
    $on = (PS1 'rapido.ps1') | ConvertFrom-Json
    Chk 'Encender: el panel lee activo=true' ($on.activo -eq $true) "activo=$($on.activo)"

    # 5) Exportar (exportar-historial.ps1 real)
    $sal = Join-Path $tmp 'export'
    $o = PS1 'exportar-historial.ps1' @('-Formato', 'csv', '-Origen', 'prod', '-Salida', $sal)
    $csv = Get-ChildItem $sal -Filter *.csv -ErrorAction SilentlyContinue | Select-Object -First 1
    Chk 'Exportar CSV crea el archivo' ($null -ne $csv) $o
    if ($csv) {
        $filas = @(Import-Csv $csv.FullName -Encoding UTF8 | Where-Object { $_.proveedor -in 'codex', 'agy' })
        if ($filas.Count -ne 3) { $filas | Format-Table id,origen,proveedor,estado | Out-String | Write-Host }
        Chk 'el CSV tiene las 3 ejecuciones delegadas reales y deja afuera la de prueba' ($filas.Count -eq 3 -and -not ($filas | Where-Object { ($_ | Out-String) -match 'ej-test' })) "filas=$($filas.Count)"
    }
    $null = PS1 'exportar-historial.ps1' @('-Formato', 'json', '-Origen', 'prod', '-Proveedor', 'agy', '-Salida', $sal)
    $js = Get-ChildItem $sal -Filter *.json -ErrorAction SilentlyContinue | Select-Object -First 1
    $nj = if ($js) { @(Get-Content $js.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).Count } else { -1 }
    Chk 'Exportar JSON filtrado por Antigravity trae 1 fila' ($nj -eq 1) "filas=$nj"

    # 6) Reiniciar: solo verificacion (-DryRun no cierra nada)
    $antesP = @(Get-Process -Name claude -ErrorAction SilentlyContinue).Count
    $rv = PS1 'reiniciar-claude.ps1' @('-DryRun')
    $despP = @(Get-Process -Name claude -ErrorAction SilentlyContinue).Count
    Chk 'Reiniciar -DryRun responde algo' ($rv.Trim().Length -gt 0)
    Chk "Reiniciar -DryRun no cerro procesos de Claude ($antesP -> $despP)" ($despP -ge $antesP)

    # 7) Lo real no se toco
    Chk '.multi-ia-orquestador real intacta (hash de uso.jsonl y config.json)' ($antes -eq (Huella))
}
finally {
    Remove-Item Env:\MULTIIA_DATOS -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_CODE_SESSION_ID -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
Write-Host ""
Write-Host "funcional: $($script:ok) ok, $($script:mal) con falla"
if ($script:mal) { exit 1 }
