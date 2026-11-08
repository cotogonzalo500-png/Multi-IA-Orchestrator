# Corré este archivo con PowerShell 5.1; no necesitás Pester ni cuotas externas.
$ErrorActionPreference = 'Stop'
$script:fallas = 0; $script:aserciones = 0
$ahorro = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\ahorro.ps1'
$temporal = Join-Path ([IO.Path]::GetTempPath()) ('mult ia-ahorro-' + [guid]::NewGuid().ToString('N'))
$anteriores = @{ MULTIIA_DATOS = $env:MULTIIA_DATOS; USERPROFILE = $env:USERPROFILE; CLAUDE_CODE_SESSION_ID = $env:CLAUDE_CODE_SESSION_ID }
function Verificar([bool]$Condicion, [string]$Mensaje) {
    $script:aserciones++
    if ($Condicion) { Write-Host "ok: $Mensaje" }
    else { Write-Host "FALLA: $Mensaje"; $script:fallas++ }
}
function Guardar-Jsonl([string]$Nombre, $Filas) {
    $lineas = @($Filas | ForEach-Object { $_ | ConvertTo-Json -Depth 10 -Compress })
    [IO.File]::WriteAllLines((Join-Path $env:MULTIIA_DATOS $Nombre), [string[]]$lineas, (New-Object Text.UTF8Encoding($false)))
}
function Uso([string]$ChatId = 'chat-a', $Out = 100, [string]$Origen = 'real', [string]$Destino = 'codex') {
    [ordered]@{ fecha = '2026-11-06T01:00:00'; destino = $Destino; modelo = 'fixture'; esfuerzo = 'medium'
        chars = 400; seg = 10; salida = 0; memoria = $false; tok_in = 200; tok_out = $Out
        tok_estado = $(if ($null -eq $Out) { 'ausente' } else { 'informado' }); origen = $Origen; sesion = $ChatId }
}
function Costo([string]$ChatId = 'chat-a', $Tok = 30, [string]$Origen = 'real') {
    [ordered]@{ fecha = '2026-11-06T01:00:00'; tok = $Tok; origen = $Origen; sesion = $ChatId; ventana = ''; instancia = '' }
}
function Ejecutar([string]$Id = '', [switch]$Texto) {
    $argumentos = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ahorro)
    if ($Id) { $argumentos += @('-Chat', $Id) }
    if ($Texto) { $argumentos += '-Texto' }
    $salida = & (Join-Path $PSHOME 'powershell.exe') @argumentos
    if ($LASTEXITCODE -ne 0) { throw "ahorro.ps1 termino con codigo $LASTEXITCODE" }
    if ($Texto) { return ($salida -join "`n") }
    ($salida -join "`n") | ConvertFrom-Json
}
try {
    New-Item -ItemType Directory -Path $temporal | Out-Null
    $env:MULTIIA_DATOS = Join-Path $temporal 'datos'
    $env:USERPROFILE = Join-Path $temporal 'perfil'
    New-Item -ItemType Directory -Path $env:MULTIIA_DATOS, (Join-Path $env:USERPROFILE '.claude\projects\fixture') -Force | Out-Null
    $env:CLAUDE_CODE_SESSION_ID = 'chat-a'
    $o = Ejecutar
    foreach ($nombre in 'tokens_proveedor', 'claude_reportado', 'claude_estimado', 'carga_delegada', 'ahorro_potencial', 'costo_economico', 'tiempo') {
        Verificar ($o.global.$nombre.nivel -eq 'NO DISPONIBLE' -and $null -eq $o.global.$nombre.valor) "sin datos: $nombre es NO DISPONIBLE y null"
    }
    Guardar-Jsonl 'uso.jsonl' @((Uso -Out $null))
    Guardar-Jsonl 'costo-claude.jsonl' @((Costo))
    $o = Ejecutar
    Verificar ($null -eq $o.global.ahorro_potencial.valor -and $o.global.ahorro_potencial.etiqueta -eq 'Ahorro no determinable') 'sin tok_out: ahorro no determinable, nunca cero'
    Verificar ($null -eq $o.global.carga_delegada.valor.tok_out.codex) 'salida ausente conserva null'
    Guardar-Jsonl 'uso.jsonl' @((Uso))
    Guardar-Jsonl 'costo-claude.jsonl' @()
    $o = Ejecutar
    Verificar ($null -eq $o.global.ahorro_potencial.valor) 'sin costo de coordinacion no se inventa ahorro'
    Guardar-Jsonl 'costo-claude.jsonl' @((Costo))
    $o = Ejecutar
    Verificar ($o.global.ahorro_potencial.valor.codex -eq 70 -and $o.global.ahorro_potencial.nivel -eq 'ESTIMADO') 'cota positiva calculada a mano: 100 - 30 = 70'
    Verificar ($o.global.tokens_proveedor.valor.codex -eq 300 -and $o.global.tokens_proveedor.por_proveedor.codex.nivel -eq 'VERIFICADO') 'CLI: 200 + 100 = 300 verificados'
    Verificar ($null -eq $o.global.tokens_proveedor.por_proveedor.antigravity.valor) 'proveedor sin filas conserva null'
    Verificar ($o.global.tiempo.valor.total -eq 10 -and $o.global.tiempo.valor.medio -eq 10) 'tiempo total y medio observados'
    Verificar ($o.global.claude_estimado.valor -eq 30) 'costo estimado se informa separado'
    Guardar-Jsonl 'costo-claude.jsonl' @((Costo -Tok 140))
    $o = Ejecutar
    Verificar ($o.global.ahorro_potencial.valor.codex -eq -40 -and $o.global.ahorro_potencial.por_proveedor.codex.etiqueta -eq 'sin ahorro neto estimado') 'cota negativa: 100 - 140 = -40, etiquetada'
    Guardar-Jsonl 'uso.jsonl' @((Uso), (Uso -Out 99999 -Origen 'test'), (Uso -Out 99999 -Origen 'simulacion'))
    Guardar-Jsonl 'costo-claude.jsonl' @((Costo), (Costo -Tok 99999 -Origen 'test'), (Costo -Tok 99999 -Origen 'simulacion'))
    $o = Ejecutar
    Verificar ($o.global.carga_delegada.valor.delegaciones -eq 1 -and $o.global.ahorro_potencial.valor.codex -eq 70) 'test y simulacion excluidos de uso y costo'
    Guardar-Jsonl 'uso.jsonl' @((Uso), (Uso -ChatId 'chat-b' -Out 800), (Uso -ChatId 'chat-b' -Out 90 -Destino 'agy'))
    Guardar-Jsonl 'costo-claude.jsonl' @((Costo), (Costo -ChatId 'chat-b' -Tok 500))
    $o = Ejecutar 'chat-a'
    Verificar ($o.chats.Count -eq 1 -and $o.chats[0].id_chat -eq 'chat-a' -and $o.chats[0].ahorro_potencial.valor.codex -eq 70 -and $o.chats[0].carga_delegada.valor.delegaciones -eq 1) 'por chat no mezcla uso ni costo de otro chat'
    Verificar ($o.global.carga_delegada.valor.delegaciones -eq 3 -and $o.global.tokens_proveedor.valor.codex -eq 1300 -and $o.global.tokens_proveedor.valor.antigravity -eq 290) 'global conserva proveedores separados aun filtrando un chat'
    $actual = Ejecutar 'actual'
    Verificar ($actual.chats[0].id_chat -eq 'chat-a' -and $actual.chats[0].ahorro_potencial.valor.codex -eq 70) '-Chat actual usa el id del entorno'
    Guardar-Jsonl 'uso.jsonl' @((Uso), (Uso -Out $null))
    Guardar-Jsonl 'costo-claude.jsonl' @((Costo), (Costo -Tok 20))
    $o = Ejecutar
    Verificar ($o.global.tokens_proveedor.por_proveedor.codex.parcial -and $o.global.tokens_proveedor.valor.codex -eq 300) 'CLI parcial suma solo filas completas, sin inventar cero'
    Verificar ($o.global.ahorro_potencial.valor.codex -eq 50 -and $o.global.ahorro_potencial.por_proveedor.codex.parcial) 'salida parcial: cota descuenta todo el costo: 100 - 50'
    Guardar-Jsonl 'uso.jsonl' @((Uso -Out 0))
    Guardar-Jsonl 'costo-claude.jsonl' @((Costo -Tok 0))
    $o = Ejecutar
    Verificar ($o.global.ahorro_potencial.valor.codex -eq 0 -and $o.global.ahorro_potencial.nivel -eq 'ESTIMADO') 'cero informado se distingue de dato ausente'
    Guardar-Jsonl 'uso.jsonl' @((Uso))
    Guardar-Jsonl 'costo-claude.jsonl' @((Costo -Tok $null))
    $o = Ejecutar
    Verificar ($null -eq $o.global.ahorro_potencial.valor) 'costo sin tok no se convierte en cero'
    Guardar-Jsonl 'costo-claude.jsonl' @((Costo))
    $transcript = [ordered]@{ timestamp = (Get-Date).ToUniversalTime().ToString('o'); message = @{
        id = 'msg_fixture'; model = 'fixture'; usage = @{ input_tokens = 10; cache_creation_input_tokens = 20; cache_read_input_tokens = 30; output_tokens = 40 } } }
    $rutaTranscript = Join-Path $env:USERPROFILE '.claude\projects\fixture\chat-a.jsonl'
    [IO.File]::WriteAllText($rutaTranscript, (($transcript | ConvertTo-Json -Depth 6 -Compress) + "`n"), (New-Object Text.UTF8Encoding($false)))
    $o = Ejecutar
    Verificar ($o.global.claude_reportado.valor -eq 100 -and $o.global.claude_reportado.nivel -eq 'VERIFICADO') 'parser real de transcript: 10 + 20 + 30 + 40 = 100'
    Verificar ($o.chats[0].claude_reportado.valor -eq 100 -and $o.chats[0].claude_estimado.valor -eq 30) 'reportado y estimado permanecen separados por chat'
    $sinFuente = Ejecutar 'inexistente'
    Verificar ($null -eq $sinFuente.chats[0].claude_reportado.valor -and $null -eq $sinFuente.chats[0].ahorro_potencial.valor) 'chat sin fuentes no hereda datos globales'
    # 2.2.0: precio sin moneda NO calcula costo (no se inventa la moneda)
    [IO.File]::WriteAllText((Join-Path $env:MULTIIA_DATOS 'config.json'), '{"ahorro":{"precio_por_mtok_codex":2}}')
    $o = Ejecutar
    Verificar ($null -eq $o.global.costo_economico.por_proveedor.codex.valor) 'precio sin moneda: no se calcula costo'
    [IO.File]::WriteAllText((Join-Path $env:MULTIIA_DATOS 'config.json'), '{"ahorro":{"precio_por_mtok_codex":2,"precio_moneda":"USD"}}')
    $o = Ejecutar
    Verificar ($o.global.costo_economico.valor.codex -eq 0.0006 -and $o.global.costo_economico.nivel -eq 'ESTIMADO' -and $null -eq $o.global.costo_economico.por_proveedor.antigravity.valor) 'precio explicito: 300 / 1000000 * 2, sin precio inventado para agy'
    foreach ($ambito in @($o.global) + @($o.chats)) {
        foreach ($nombre in 'tokens_proveedor', 'claude_reportado', 'claude_estimado', 'carga_delegada', 'ahorro_potencial', 'costo_economico', 'tiempo') {
            $m = $ambito.$nombre
            $campos = @('valor','unidad','nivel','fuente','metodo','fecha')
            $faltantes = @($campos | Where-Object { $_ -notin $m.PSObject.Properties.Name })
            Verificar ($faltantes.Count -eq 0 -and $m.nivel -in @('VERIFICADO','OBSERVADO','ESTIMADO','NO DISPONIBLE')) "esquema y nivel: $nombre"
        }
    }
    # Codex #5 (2.2.0): correlacion por id de ejecucion, sin doble conteo de recuperadas, delegado != ahorro.
    $fallo = Uso 'chat-r' 500 'real' 'codex'; $fallo.ej = 'e1'; $fallo.salida = 1
    $recup = Uso 'chat-r' 100 'real' 'antigravity'; $recup.ej = 'e1-r'
    $dup = Uso 'chat-r' 50 'real' 'codex'; $dup.ej = 'e2'
    $sinId = Uso 'chat-r' 10 'real' 'codex'; $sinId.fecha = '2026-11-06T02:00:00'
    Guardar-Jsonl 'uso.jsonl' @($fallo, $recup, $dup, $dup, $sinId)
    Guardar-Jsonl 'costo-claude.jsonl' @((Costo 'chat-r' 10), (Costo 'chat-r' 10), (Costo 'chat-r' 10))
    Remove-Item -LiteralPath (Join-Path $env:MULTIIA_DATOS 'config.json') -ErrorAction SilentlyContinue
    $c5 = (Ejecutar 'chat-r').chats[0]
    Verificar ($c5.carga_delegada.valor.delegaciones -eq 3) "#5: e1 + su recuperacion e1-r = 1 delegacion; total 3 (e1, e2, fila sin id), no 5"
    Verificar ($c5.carga_delegada.valor.intentos -eq 4) "#5: la linea duplicada identica de e2 se cuenta una vez (4 intentos, no 5)"
    Verificar ($c5.carga_delegada.valor.recuperadas -eq 1) '#5: una recuperacion exitosa registrada'
    Verificar ($c5.tokens_proveedor.valor.codex -eq 1160) '#5: tokens de codex incluyen el intento fallido (gasto real) pero no el duplicado: 700 + 250 + 210 = 1160'
    Verificar ($c5.carga_delegada.por_proveedor.codex.valor -eq 60) '#5: salida util de codex excluye el intento fallido (50 + 10, no 560)'
    Verificar ($c5.ahorro_potencial.valor.codex -eq 30 -and $c5.ahorro_potencial.valor.antigravity -eq 70) '#5: ahorro = salida util - coordinacion (60-30, 100-30), no salida total'
    Verificar ($c5.carga_delegada.metodo -match 'NO es ahorro' -and $c5.carga_delegada.nota -match 'no equivale a ahorro') '#5: carga delegada declara que delegado != ahorro'
    # Auditoria Codex 2.2.0: casos borde que antes pasaban sin estar cubiertos.
    $a1 = Uso 'chat-z' 40; $a1.ej = 'e3'
    $a2 = Uso 'chat-z' 40; $a2.ej = 'e3-rev'; $a2.fecha = '2026-11-06T01:01:00'
    $a3 = Uso 'chat-z' 40; $a3.ej = 'e4-r'; $a3.salida = $null; $a3.fecha = '2026-11-06T01:02:00'
    $a4 = Uso 'chat-z' 40; $a4.ej = 'e5-r'; $a4.fecha = '2026-11-06T01:03:00'
    $a5 = Uso 'chat-z' 40; $a5.ej = 'e5-r'; $a5.fecha = '2026-11-06T01:04:00'
    $a6 = Uso 'chat-z' 40; $a6.ej = 'e6'; $a6.fecha = '2026-11-06T01:05:00'
    $a7 = Uso 'chat-z' 40; $a7.ej = 'e6'; $a7.fecha = '2026-11-06T01:05:00'; $a7.seg = 11
    Guardar-Jsonl 'uso.jsonl' @($a1, $a2, $a3, $a4, $a5, $a6, $a7)
    $k1 = Costo 'chat-z' 5; $k1.ej = 'e3'; $k2 = Costo 'chat-z' 5; $k2.ej = 'e4-r'; $k3 = Costo 'chat-z' 5; $k3.ej = 'e5-r'; $k4 = Costo 'chat-z' 5; $k4.ej = 'e6'
    Guardar-Jsonl 'costo-claude.jsonl' @($k1, $k2, $k3, $k4)
    $cz = (Ejecutar 'chat-z').chats[0]
    Verificar ($cz.carga_delegada.valor.delegaciones -eq 4) 'auditoria: e3 y e3-rev son la misma delegacion (e3, e4, e5, e6 = 4)'
    Verificar ($cz.carga_delegada.valor.intentos -eq 7) 'auditoria: filas que solo difieren en seg no se deduplican (7 intentos)'
    Verificar ($cz.carga_delegada.valor.recuperadas -eq 1) 'auditoria: e4-r sin salida informada no es exito; e5-r con dos filas cuenta una vez'
    Verificar ($cz.carga_delegada.por_proveedor.codex.valor -eq 240) 'auditoria: salida util excluye la fila sin salida informada (6 x 40, no 7 x 40)'
    Verificar (-not $cz.claude_estimado.parcial -and $null -ne $cz.ahorro_potencial.valor) 'auditoria: con costo por id para cada delegacion la estimacion es completa'
    $k4.ej = 'e3'   # e6 sin costo y e3 con dos: contar filas da 4 = 4, cruzar por id detecta el faltante
    Guardar-Jsonl 'costo-claude.jsonl' @($k1, $k2, $k3, $k4)
    $cz = (Ejecutar 'chat-z').chats[0]
    Verificar ($cz.claude_estimado.parcial -and $null -eq $cz.ahorro_potencial.valor.codex) 'auditoria: delegacion sin costo por id vuelve parcial la estimacion y anula el ahorro'
    Verificar ($cz.ahorro_potencial.parcial) 'auditoria: ahorro_potencial global hereda PARCIAL'
    $texto = Ejecutar -Texto
    Verificar ($texto -match 'Ambito: global' -and $texto -match 'ahorro_potencial') '-Texto muestra categorias y ambitos'
    foreach ($archivo in @($ahorro, $PSCommandPath)) {
        $bytes = [IO.File]::ReadAllBytes($archivo)
        Verificar ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) "BOM UTF-8: $(Split-Path $archivo -Leaf)"
    }
} catch {
    Verificar $false ("error inesperado: " + $_.Exception.Message + ' en ' + $_.ScriptStackTrace)
} finally {
    foreach ($nombre in $anteriores.Keys) { [Environment]::SetEnvironmentVariable($nombre, $anteriores[$nombre], 'Process') }
    # Borrá unicamente la carpeta temporal creada por esta corrida.
    $raizTemporal = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resuelto = [IO.Path]::GetFullPath($temporal)
    if ($resuelto.StartsWith($raizTemporal, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resuelto -Leaf) -like 'mult ia-ahorro-*' -and (Test-Path -LiteralPath $resuelto)) {
        Remove-Item -LiteralPath $resuelto -Recurse -Force
    }
}
Write-Host "$script:aserciones aserciones; $script:fallas fallas"
if ($script:fallas) { exit 1 }
exit 0
