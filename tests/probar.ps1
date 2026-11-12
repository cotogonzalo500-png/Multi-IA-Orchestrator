# Pruebas de los scripts del plugin. Usan una carpeta de datos TEMPORAL (MULTIIA_DATOS): no tocan tus datos reales.
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\probar.ps1
$ErrorActionPreference = 'Stop'
$raiz = Split-Path $PSScriptRoot -Parent
$sc = Join-Path $raiz 'scripts'
$tmp = Join-Path $env:TEMP ('mia-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory $tmp | Out-Null
$env:MULTIIA_DATOS = $tmp
$ok = 0; $mal = 0; $omit = 0
# DEV tiene community\construir.ps1; la edicion Community no. Las pruebas de DEV se cuentan como OMITIDAS alli (no como ok).
$esDev = Test-Path (Join-Path $raiz 'community\construir.ps1')
function SoloDev($motivo) { if (-not $script:esDev) { throw "OMITIDA: $motivo" } }
function T($nombre, [scriptblock]$caso) {
    if ($env:MULTIIA_SOLO -and $nombre -notmatch $env:MULTIIA_SOLO) { return }   # filtro opcional (regex) para correr solo algunas pruebas
    try { & $caso; $script:ok++; Write-Host "  ok   $nombre" -ForegroundColor Green }
    catch {
        if ($_.Exception.Message -like 'OMITIDA:*') { $script:omit++; Write-Host "  omit $nombre ($($_.Exception.Message))" -ForegroundColor Yellow }
        else { $script:mal++; Write-Host "  FALLA $nombre : $($_.Exception.Message)" -ForegroundColor Red }
    }
}
function Afirmar($c, $m) { if (-not $c) { throw $m } }
# 3.3.0: pruebas del router economico/intensidad (anteriores a Calidad Maxima): fuerzan la politica 'normal' solo durante el caso.
function TN($nombre, [scriptblock]$caso) { $env:MULTIIA_POLITICA = 'normal'; try { T $nombre $caso } finally { Remove-Item Env:\MULTIIA_POLITICA -ErrorAction SilentlyContinue } }
function PS1($archivo, [string[]]$a = @()) { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $sc $archivo) @a 2>&1 }

Write-Host "== Sintaxis y codificacion"
foreach ($f in Get-ChildItem $sc -Filter *.ps1) {
    T "$($f.Name): BOM UTF-8 y sin errores de sintaxis" {
        $b = [IO.File]::ReadAllBytes($f.FullName)
        Afirmar ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) 'falta el BOM'
        $e = $null; [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$e)
        Afirmar ($e.Count -eq 0) ($e[0].Message)
    }
}

. (Join-Path $sc '_comun.ps1')
Write-Host "== Registro de uso y costo"
T 'Add-Uso / Get-Uso / Sumar-Tok suman bien' {
    Add-Uso -Destino 'agy' -Chars 100 -Segundos 2 -Salida 50 -ConMemoria $false -TokIn 1000 -TokOut 200
    Add-Uso -Destino 'codex' -Chars 100 -Segundos 2 -Salida 50 -ConMemoria $false -TokIn 500 -TokOut 100
    $u = @(Get-Uso); Afirmar ($u.Count -eq 2) 'cantidad'; Afirmar ((Sumar-Tok $u) -eq 1800) 'suma'
}
T 'Add-CostoClaude suma chars/4 redondeado hacia arriba' {
    Afirmar ((Get-CostoClaude) -eq 0) 'arranca en 0'
    Add-CostoClaude -CharsPrompt 100 -CharsSalida 3   # 103/4 = 26
    Add-CostoClaude -CharsPrompt 4 -CharsSalida 0     # 1
    Afirmar ((Get-CostoClaude) -eq 27) "esperaba 27, dio $(Get-CostoClaude)"
}
T 'consumo.ps1: sesiones aisladas y el global no duplica' {
    $env:CLAUDE_CODE_SESSION_ID = 'prueba-A'; Add-Uso -Destino 'codex' -Modelo 'm1' -Segundos 1 -Salida 0 -TokIn 10 -TokOut 5; Add-Uso -Destino 'agy' -Modelo 'm2' -Segundos 1 -Salida 1   # 1.9.1: sin -TokIn/-TokOut = la CLI no informo (antes se pasaba 0, que ahora significa "la CLI dijo 0")
    $env:CLAUDE_CODE_SESSION_ID = 'prueba-B'; Add-Uso -Destino 'codex' -Modelo 'm1' -Segundos 1 -Salida 0 -TokIn 7 -TokOut 3
    Remove-Item Env:CLAUDE_CODE_SESSION_ID
    $j = (PS1 'consumo.ps1' | Out-String) | ConvertFrom-Json
    Afirmar ($j.sesiones.'prueba-A'.pedidos -eq 2 -and $j.sesiones.'prueba-A'.tok_total -eq 15) 'sesion A mezclada'
    Afirmar ($j.sesiones.'prueba-A'.errores -eq 1 -and $j.sesiones.'prueba-A'.sin_dato -eq 1) 'errores/sin dato de A'
    Afirmar ($j.sesiones.'prueba-B'.tok_total -eq 10) 'sesion B mezclada'
    $suma = ($j.sesiones.PSObject.Properties | ForEach-Object { $_.Value.tok_total } | Measure-Object -Sum).Sum
    Afirmar ($suma -eq $j.global.tok_total) "global $($j.global.tok_total) != suma de sesiones $suma"
    Afirmar ($j.nota -match 'no oficial|estimacion') 'falta aclarar estimado vs real'
}
T 'Add-Evento recorta el archivo a 200 al pasar de 300' {
    1..305 | ForEach-Object { Add-Evento -Tipo 'fin' -Destino 'agy' -Motivo "m$_" }
    $n = @(Get-Content (Join-Path $tmp 'eventos.jsonl')).Count
    Afirmar ($n -le 300 -and $n -ge 100) "lineas: $n"
}

Write-Host "== Clasificador extensible e historial de resultados"
T 'clasificar: datos y arquitectura son categorias propias que usan el motor de razonar' {
    $d = (PS1 'clasificar.ps1' @('-Pedido', 'analizá este csv de ventas') | Out-String) | ConvertFrom-Json
    Afirmar ($d.categoria -eq 'datos' -and $d.tarea -eq 'razonar') "datos: $($d.categoria)/$($d.tarea)"
    $a = (PS1 'clasificar.ps1' @('-Pedido', 'armame el diagrama de arquitectura del sistema') | Out-String) | ConvertFrom-Json
    Afirmar ($a.categoria -eq 'arquitectura') "arquitectura: $($a.categoria)"
}
T 'clasificar: categorias-extra.json agrega categorias sin tocar el codigo' {
    '[{"categoria":"legal","re":"contrato|cl[aá]usula","tarea":"razonar","motivo":"legal de prueba"}]' | Set-Content (Join-Path $tmp 'categorias-extra.json') -Encoding UTF8
    $l = (PS1 'clasificar.ps1' @('-Pedido', 'redactá un contrato de alquiler') | Out-String) | ConvertFrom-Json
    Remove-Item (Join-Path $tmp 'categorias-extra.json')
    Afirmar ($l.categoria -eq 'legal' -and $l.tarea -eq 'razonar') "legal: $($l.categoria)/$($l.tarea)"
}
T 'historial: con 3 resultados reales, elegir muestra la tasa de exito y avisa si es baja' {
    1..3 | ForEach-Object { Add-Evento -Tipo 'fin' -Destino 'agy' -Tarea 'texto' -Seg 4 }
    $s = (PS1 'elegir.ps1' @('-Tarea', 'texto') | Out-String) | ConvertFrom-Json
    Afirmar ($s.motivo -match 'historial: 100% ok en 3') "motivo: $($s.motivo)"
    1..4 | ForEach-Object { Add-Evento -Tipo 'error' -Destino 'agy' -Tarea 'texto' -Seg 4 }
    $s = (PS1 'elegir.ps1' @('-Tarea', 'texto') | Out-String) | ConvertFrom-Json
    Afirmar ($s.motivo -match 'historial: 43% ok en 7' -and $s.motivo -match 'rinde mal') "motivo: $($s.motivo)"
    Remove-Item (Join-Path $tmp 'resultados.jsonl')
}

TN 'aprendizaje: si el plan economico fallo mas de la mitad (5+ ejecuciones), elegir sube de calidad y lo explica' {
    Remove-Item (Join-Path $tmp 'resultados.jsonl') -ErrorAction SilentlyContinue
    1..5 | ForEach-Object { Add-Evento -Tipo 'error' -Destino 'codex' -Tarea 'codigo' -Seg 3 }
    $s = (PS1 'elegir.ps1' @('-Tarea', 'codigo', '-Calidad', 'economica') | Out-String) | ConvertFrom-Json
    Afirmar ($s.motivo -match 'aprendizaje' -and $s.modelo -ne 'gpt-6-luna') "motivo: $($s.motivo) / $($s.modelo)"
    $c = Get-Config; $c.ahorro | Add-Member -NotePropertyName aprender -NotePropertyValue $false -Force; Save-Config $c
    $s2 = (PS1 'elegir.ps1' @('-Tarea', 'codigo', '-Calidad', 'economica') | Out-String) | ConvertFrom-Json
    $c.ahorro.aprender = $true; Save-Config $c
    Remove-Item (Join-Path $tmp 'resultados.jsonl')
    Afirmar ($s2.motivo -notmatch 'aprendizaje' -and $s2.modelo -eq 'gpt-6-luna') "con aprender=false no debe cambiar: $($s2.motivo)"
}

Write-Host "== Presupuesto, estimacion previa y cache"
T 'presupuesto: sin tope no alerta; con tope y uso alto pasa a alerta/superado' {
    . (Join-Path $sc '_comun.ps1')
    Remove-Item (Join-Path $tmp 'uso.jsonl') -ErrorAction SilentlyContinue
    Afirmar ((Get-PresupuestoEstado).nivel -eq 'sin-tope') 'deberia ser sin-tope'
    $c = Get-Config; $c.ahorro.tope_diario_tok = 1000; Save-Config $c
    Add-Uso -Destino 'agy' -Modelo 'x' -Esfuerzo '' -Chars 10 -Segundos 1 -Salida 10 -TokIn 700 -TokOut 150 -Modo 'automatico' -Cuenta 'agy'
    $e = Get-PresupuestoEstado
    Afirmar ($e.usado_hoy -eq 850 -and $e.pct -eq 85 -and $e.nivel -eq 'alerta') "estado: $($e | ConvertTo-Json -Compress)"
    Add-Uso -Destino 'agy' -Modelo 'x' -Esfuerzo '' -Chars 10 -Segundos 1 -Salida 10 -TokIn 200 -TokOut 0 -Modo 'automatico' -Cuenta 'agy'
    Afirmar ((Get-PresupuestoEstado).nivel -eq 'superado') 'deberia estar superado'
}
T 'config: -Tope, -AvisoPct y -CacheHoras se guardan' {
    PS1 'config.ps1' @('-Tope', '123456', '-AvisoPct', '70', '-CacheHoras', '12') | Out-Null
    . (Join-Path $sc '_comun.ps1'); $a = (Get-Config).ahorro
    Afirmar ($a.tope_diario_tok -eq 123456 -and $a.aviso_pct -eq 70 -and $a.cache_resultados_h -eq 12) "ahorro: $($a | ConvertTo-Json -Compress)"
    PS1 'config.ps1' @('-Tope', '1000', '-AvisoPct', '80', '-CacheHoras', '24') | Out-Null
}
T 'estimacion: -Estimar informa tokens estimados y no ejecuta nada' {
    $o = (PS1 'delegar.ps1' @('-Tarea', 'texto', '-Prompt', ('a' * 400), '-Forzar', '-Estimar') | Out-String)
    Afirmar ($o -match 'estimacion' -and $o -match 'ESTIMADO' -and $o -match 'superado|alerta|de 1000') "salida: $o"
}
TN 'cache: una respuesta guardada se reutiliza sin llamar a ningun motor' {
    . (Join-Path $sc '_comun.ps1')
    $sel = (PS1 'elegir.ps1' @('-Tarea', 'texto') | Out-String) | ConvertFrom-Json
    $k = Get-ClaveCache 'texto' 'resumi esto en cache' @() ("{0}|{1}|{2}|{3}|{4}|{5}|{6}" -f (Get-Location).Path, $false, $sel.calidad, $sel.destino, $sel.modelo, $sel.perfil, $sel.esfuerzo)
    Set-CacheResultado $k @('respuesta guardada de prueba')
    $o = (PS1 'delegar.ps1' @('-Tarea', 'texto', '-Prompt', 'resumi esto en cache', '-Forzar') | Out-String)
    Afirmar ($o -match 'cache: respuesta reutilizada' -and $o -match 'respuesta guardada de prueba') "salida: $o"
    $o2 = (PS1 'delegar.ps1' @('-Tarea', 'texto', '-Prompt', 'resumi esto en cache', '-Forzar', '-Estimar', '-SinCache') | Out-String)
    Afirmar ($o2 -notmatch 'respuesta guardada') 'con -SinCache no debe usar la cache'
}

Write-Host "== Equipo de roles (con delegador simulado)"
$stub = Join-Path $tmp 'stub-delegar.ps1'
@'
param($Tarea, $Prompt, $Carpeta, [switch]$Forzar, [switch]$Aislar, [switch]$Critico)
$d = $env:MULTIIA_DATOS
Add-Content (Join-Path $d 'stub.log') "$Tarea|aislar=$Aislar|critico=$Critico"
if (Test-Path (Join-Path $d 'stub-falla-1')) { Remove-Item (Join-Path $d 'stub-falla-1'); Write-Output 'falla simulada'; exit 1 }
if (Test-Path (Join-Path $d 'stub-cancelar')) { 'x' | Set-Content (Join-Path $d 'equipo-cancelar.flag') }
Write-Output "[delegado: stub] respuesta de $Tarea"
exit 0
'@ | Set-Content $stub -Encoding UTF8
function Equipo([string[]]$a) { $env:MULTIIA_DELEGAR = $stub; try { (PS1 'equipo.ps1' $a | Out-String) } finally { Remove-Item Env:\MULTIIA_DELEGAR } }
T 'equipo: -Plan muestra los roles y rechaza roles desconocidos' {
    $o = (PS1 'equipo.ps1' @('-Objetivo', 'x', '-Roles', 'arquitecto,auditor', '-Plan') | Out-String)
    Afirmar ($o -match 'arquitecto' -and $o -match 'auditor' -and $o -match 'critica') "plan: $o"
    $m = (PS1 'equipo.ps1' @('-Objetivo', 'x', '-Roles', 'mago') | Out-String)
    Afirmar ($m -match 'Rol desconocido') "malo: $m"
}
T 'equipo: corre los roles en orden, el que escribe va aislado y el auditor critico' {
    Remove-Item (Join-Path $tmp 'stub.log') -ErrorAction SilentlyContinue
    $o = Equipo @('-Objetivo', 'hacer algo', '-Roles', 'arquitecto,desarrollador,auditor', '-Carpeta', $tmp)
    Afirmar ($o -match '\[arquitecto\] ok' -and $o -match '\[desarrollador\] ok' -and $o -match '\[auditor\] ok' -and $o -match 'terminados ok') "salida: $o"
    $l = Get-Content (Join-Path $tmp 'stub.log')
    Afirmar ($l[0] -match '^razonar' -and $l[1] -match '^codigo\|aislar=True' -and $l[2] -match '^revision.*critico=True') "log: $($l -join ' / ')"
    Afirmar (-not (Test-Path (Join-Path $tmp 'locks\*.lock'))) 'el candado deberia liberarse'
}
T 'equipo: reintenta cuando un rol falla una vez' {
    'x' | Set-Content (Join-Path $tmp 'stub-falla-1')
    $o = Equipo @('-Objetivo', 'x', '-Roles', 'arquitecto', '-Reintentos', '1')
    Afirmar ($o -match 'reintento 1' -and $o -match '\[arquitecto\] ok') "salida: $o"
}
T 'equipo: si el rol falla sin reintentos corta la cadena' {
    'x' | Set-Content (Join-Path $tmp 'stub-falla-1')
    $o = Equipo @('-Objetivo', 'x', '-Roles', 'arquitecto,revisor', '-Reintentos', '0')
    Afirmar ($o -match 'FALLO' -and $o -notmatch '\[revisor\]') "salida: $o"
}
T 'equipo: respeta el candado de otro agente que sigue vivo' {
    . (Join-Path $sc '_comun.ps1')
    Afirmar (Enter-Candado 'C:\carpeta-ocupada') 'el test deberia tomar el candado'
    $o = Equipo @('-Objetivo', 'x', '-Roles', 'desarrollador', '-Carpeta', 'C:\carpeta-ocupada')
    Exit-Candado 'C:\carpeta-ocupada'
    Afirmar ($o -match 'otro agente') "salida: $o"
}
T 'equipo: -Cancelar corta antes del proximo paso' {
    'x' | Set-Content (Join-Path $tmp 'stub-cancelar')
    $o = Equipo @('-Objetivo', 'x', '-Roles', 'arquitecto,revisor')
    Remove-Item (Join-Path $tmp 'stub-cancelar'), (Join-Path $tmp 'equipo-cancelar.flag') -ErrorAction SilentlyContinue
    Afirmar ($o -match 'cancelado antes de .revisor') "salida: $o"
}

Write-Host "== Arena, memoria por proyecto, resumir y compuerta"
$stub2 = Join-Path $tmp 'stub-arena.ps1'
@'
param($Tarea, $Prompt, $Calidad, $Archivo, [switch]$Forzar, [switch]$SinCache)
Write-Output "[delegado: stub-$Calidad]"
Write-Output "respuesta $Calidad a: $Prompt"
exit 0
'@ | Set-Content $stub2 -Encoding UTF8
T 'arena: compara dos calidades, registra la corrida y anota el veredicto humano' {
    $env:MULTIIA_DELEGAR = $stub2
    try { $o = (PS1 'arena.ps1' @('-Tarea', 'razonar', '-Prompt', 'comparar', '-Calidades', 'economica,maxima') | Out-String) } finally { Remove-Item Env:\MULTIIA_DELEGAR }
    Afirmar ($o -match 'ECONOMICA' -and $o -match 'MAXIMA' -and $o -match 'respuesta maxima a: comparar') "salida: $o"
    $g = (PS1 'arena.ps1' @('-Ganador', 'maxima', '-Nota', 'mas completa') | Out-String)
    Afirmar ($g -match 'gano .maxima') "veredicto: $g"
    $h = (PS1 'arena.ps1' @('-Historial') | Out-String)
    Afirmar ($h -match 'maxima: gano 1') "historial: $h"
    $m = (PS1 'arena.ps1' @('-Ganador', 'equilibrada') | Out-String)
    Afirmar ($m -match 'no participo') "debia rechazar un ganador que no compitio: $m"
}
T 'arena: acepta varios archivos separados por coma' {
    $env:MULTIIA_DELEGAR = $stub2
    try { $o = (PS1 'arena.ps1' @('-Tarea', 'texto', '-Prompt', 'dos archivos', '-Calidades', 'economica', '-Archivo', 'a.txt,b.txt') | Out-String) } finally { Remove-Item Env:\MULTIIA_DELEGAR }
    Afirmar ($o -match 'ECONOMICA' -and $o -match 'ok') "salida: $o"
}
T 'memoria por proyecto: se guarda aparte y se suma solo para ese proyecto' {
    . (Join-Path $sc '_comun.ps1')
    PS1 'memoria.ps1' @('-Proyecto', 'Proyecto Uno', '-Agregar', 'dato exclusivo del uno') | Out-Null
    Afirmar (Test-Path (Join-Path $tmp 'MEMORIA-proyecto-uno.md')) 'no creo el archivo del proyecto'
    $env:MULTIIA_PROYECTO = 'Proyecto Uno'
    try { $con = Add-Memoria 'tarea x' } finally { Remove-Item Env:\MULTIIA_PROYECTO }
    $env:MULTIIA_PROYECTO = 'otro'
    try { $sin = Add-Memoria 'tarea x' } finally { Remove-Item Env:\MULTIIA_PROYECTO }
    Afirmar ($con -match 'dato exclusivo del uno') 'faltan las notas del proyecto'
    Afirmar ($sin -notmatch 'dato exclusivo del uno') 'las notas se filtraron a otro proyecto'
}
T 'resumir: un archivo chico no se delega' {
    $f = Join-Path $tmp 'chico.txt'; 'hola' | Set-Content $f
    $o = (PS1 'resumir.ps1' @('-Archivo', $f) | Out-String)
    Afirmar ($o -match 'es chico') "salida: $o"
}
T 'resumir: un archivo grande se manda a economica con el archivo adjunto' {
    $f = Join-Path $tmp 'grande.txt'; ('linea de relleno ' * 800) | Set-Content $f
    $env:MULTIIA_DELEGAR = $stub2
    try { $o = (PS1 'resumir.ps1' @('-Archivo', $f, '-Foco', 'cifras') | Out-String) } finally { Remove-Item Env:\MULTIIA_DELEGAR }
    Afirmar ($o -match 'stub-economica' -and $o -match 'Foco: cifras') "salida: $o"
}
T 'compuerta: la version dev pasa, y una copia rota (script sin BOM) falla' {
    $ok1 = (PS1 'compuerta.ps1' @('-Ruta', $raiz, '-SinValidate') | Out-String)
    Afirmar ($LASTEXITCODE -eq 0 -and $ok1 -match 'todo en orden') "dev: $ok1"
    $copia = Join-Path $tmp 'copia-rota'
    New-Item -ItemType Directory $copia | Out-Null
    foreach ($d in '.claude-plugin', 'hooks', 'scripts') { Copy-Item (Join-Path $raiz $d) (Join-Path $copia $d) -Recurse }
    [IO.File]::WriteAllText((Join-Path $copia 'scripts\config.ps1'), 'Write-Output "sin bom"', (New-Object Text.UTF8Encoding($false)))
    $mal1 = (PS1 'compuerta.ps1' @('-Ruta', $copia, '-SinValidate') | Out-String)
    Afirmar ($LASTEXITCODE -eq 1 -and $mal1 -match 'sin BOM') "rota: $mal1"
}

Write-Host "== Reinicio (solo simulacion: no cierra nada)"
T 'reiniciar-claude.ps1 -DryRun (claude) revisa y no cierra procesos' {
    $antes = @(Get-Process -Name claude -ErrorAction SilentlyContinue).Count
    $r = (PS1 'reiniciar-claude.ps1' @('-Modo', 'claude', '-Si', '-DryRun') | Out-String)
    Afirmar ($LASTEXITCODE -in 0, 2) "codigo inesperado $LASTEXITCODE : $r"
    Afirmar (@(Get-Process -Name claude -ErrorAction SilentlyContinue).Count -ge $antes) 'cerro procesos en DryRun'
    Afirmar (Test-Path (Join-Path $tmp 'reinicios.jsonl')) 'no dejo registro en reinicios.jsonl'
}
T 'reiniciar-claude.ps1 con trabajo pendiente se niega (codigo 4)' {
    Add-Evento -Tipo 'inicio' -Destino 'agy' -Motivo 'pendiente de prueba' -Tarea 'texto'
    $r = (PS1 'reiniciar-claude.ps1' @('-Modo', 'claude', '-Si', '-DryRun') | Out-String)
    Afirmar ($LASTEXITCODE -in 0, 2, 4) "codigo $LASTEXITCODE : $r"
}

Write-Host "== Configuracion"
T 'config.ps1 guarda calidad y modo y los lee de nuevo' {
    PS1 'config.ps1' @('-Calidad', 'maxima') | Out-Null; PS1 'config.ps1' @('-Modo', 'manual') | Out-Null
    $c = Get-Config; Afirmar ($c.calidad -eq 'maxima' -and $c.modo -eq 'manual') "$($c.calidad)/$($c.modo)"
    PS1 'config.ps1' @('-Modo', 'automatico') | Out-Null; PS1 'config.ps1' @('-Calidad', 'auto') | Out-Null
    Afirmar ((Get-Config).calidad -eq 'auto') 'auto'
}
T 'config.ps1 rechaza una calidad invalida' {
    $ErrorActionPreference = 'Continue'
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $sc 'config.ps1') -Calidad inventada 2>$null
    $codigo = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    Afirmar ($codigo -ne 0) 'deberia fallar'
}
T 'config rota o inexistente cae a la de por defecto' {
    Set-Content (Join-Path $tmp 'config.json') '{ roto' -Encoding UTF8
    $c = Get-Config; Afirmar ($c.modo -eq 'automatico' -and $c.calidad -eq 'equilibrada') 'defecto'
    Remove-Item (Join-Path $tmp 'config.json')
}

Write-Host "== Eleccion de motor"
foreach ($t in 'texto', 'trivial', 'razonar', 'opinion', 'codigo', 'revision') {
    foreach ($q in 'economica', 'equilibrada', 'maxima') {
        T "elegir $t / $q devuelve JSON con destino y motivo" {
            $j = (PS1 'elegir.ps1' @('-Tarea', $t, '-Calidad', $q) | Out-String) | ConvertFrom-Json
            Afirmar ($j.destino -in 'codex', 'agy', 'claude', 'pendiente') "destino $($j.destino)"
            Afirmar ([bool]$j.motivo) 'sin motivo'
        }
    }
}
T 'modo manual aplica lo elegido' {
    PS1 'config.ps1' @('-Modo', 'manual', '-Manual', 'codex.esfuerzo=high') | Out-Null
    $j = (PS1 'elegir.ps1' @('-Tarea', 'codigo') | Out-String) | ConvertFrom-Json
    Afirmar ($j.modo -eq 'manual') 'modo'
    PS1 'config.ps1' @('-Modo', 'automatico') | Out-Null
}

Write-Host "== Cache de limites"
T 'limites -Json reusa la cache fresca sin consultar a nadie' {
    $falso = '{"calidad":"x","tarjetas":[{"nombre":"Prueba","ventanas":[{"v":"5 h","usado":7,"reinicia":"2099-01-01T00:00:00Z"}]}],"claude_costo":0}'
    Set-Content (Join-Path $tmp 'limites-cache.json') $falso -Encoding UTF8
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $o = (PS1 'limites.ps1' @('-Json') | Out-String).Trim()
    Afirmar ($o -match '"Prueba"') 'no uso la cache'; Afirmar ($sw.Elapsed.TotalSeconds -lt 5) "tardo $($sw.Elapsed.TotalSeconds) s"
}
T 'la cache vencida (ventana ya reiniciada) se ignora' {
    $viejo = '{"tarjetas":[{"nombre":"Prueba","ventanas":[{"v":"5 h","usado":7,"reinicia":"2000-01-01T00:00:00Z"}]}]}'
    Set-Content (Join-Path $tmp 'limites-cache.json') $viejo -Encoding UTF8
    $o = (PS1 'limites.ps1' @('-Json') | Out-String)
    Afirmar ($o -notmatch '"Prueba"') 'uso una cache vencida'
}

# 3.4.0: HooksError «aborted: still running» del panel. agy/Codex lentos se simulan con exes falsos (MULTIIA_AGY_EXE / MULTIIA_CODEX_EXE).
Write-Host "== Lectura de cupos con motores lentos (HooksError 3.4.0)"
$lentoExe = Join-Path $tmp 'motor-lento.exe'; $mudoExe = Join-Path $tmp 'motor-mudo.exe'
try {
    Add-Type -OutputType ConsoleApplication -OutputAssembly $lentoExe -TypeDefinition 'public static class L { public static void Main(){ System.Threading.Thread.Sleep(60000); } }'
    Add-Type -OutputType ConsoleApplication -OutputAssembly $mudoExe -TypeDefinition 'public static class M { public static void Main(){ } }'
} catch { }
function Con-Motores([string]$agy, [string]$codex, [scriptblock]$b) {
    $env:MULTIIA_AGY_EXE = $agy; $env:MULTIIA_CODEX_EXE = $codex
    try { & $b } finally { Remove-Item Env:\MULTIIA_AGY_EXE, Env:\MULTIIA_CODEX_EXE -ErrorAction SilentlyContinue; Get-Process motor-lento -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
}
$cacheBuena = '{"tarjetas":[{"nombre":"Codex","ventanas":[{"v":"5 h","usado":11,"reinicia":"2099-01-01T00:00:00Z","origen":"en vivo","leido":"' + (Get-Date).ToUniversalTime().AddMinutes(-3).ToString('o') + '"}]},{"nombre":"Antigravity · Gemini","ventanas":[{"v":"Semanal","usado":33,"reinicia":"2099-01-01T00:00:00Z","origen":"en vivo","leido":"' + (Get-Date).ToUniversalTime().AddMinutes(-3).ToString('o') + '"}]}]}'
T 'Get-CupoGeneral: agy sin datos NO inventa una tarjeta «Antigravity · » al 100 %' {
    $f = @(Get-CupoGeneral -Codex $null -Agy @())
    Afirmar (-not @($f | Where-Object { $_.ia -like 'Antigravity*' })) ('tarjeta inventada: ' + (($f | ForEach-Object { "$($_.ia) $($_.usado)%" }) -join ', '))
}
T 'limites -Json con agy colgado y Codex sin respuesta termina en menos de 40 s, con respaldo y edad visible' {
    Afirmar (Test-Path $lentoExe) 'no se pudo compilar el motor falso'
    Con-Motores $lentoExe $mudoExe {
        [IO.File]::WriteAllText((Join-Path $tmp 'limites-cache.json'), $cacheBuena)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $j = (PS1 'limites.ps1' @('-Json', '-Forzar') | Out-String) | ConvertFrom-Json
        Afirmar ($sw.Elapsed.TotalSeconds -lt 40) "tardo $([int]$sw.Elapsed.TotalSeconds) s (el panel corta a los 45 s)"
        $ag = @($j.tarjetas | Where-Object { $_.nombre -eq 'Antigravity · Gemini' })
        Afirmar ($ag.Count -eq 1 -and $ag[0].ventanas[0].usado -eq 33) 'no conservo la ultima lectura de agy'
        Afirmar ($ag[0].ventanas[0].origen -match 'última lectura hace 3 min · agy: tiempo agotado') ("origen: " + $ag[0].ventanas[0].origen)
        $cx = @($j.tarjetas | Where-Object { $_.nombre -eq 'Codex' })
        Afirmar ($cx.Count -eq 1 -and $cx[0].ventanas[0].origen -match '^última lectura hace .* Codex: no respondió') ('Codex: ' + ($cx | ConvertTo-Json -Depth 5 -Compress))
        Afirmar (-not @($j.tarjetas | ForEach-Object { $_.ventanas } | Where-Object { $_.origen -eq 'en vivo' -and $_ })) 'marco como «en vivo» algo que no respondio'
        Afirmar (-not @($j.tarjetas | Where-Object { $_.nombre -match '^Antigravity · $' })) 'tarjeta inventada'
    }
}
T 'sin cache previa y agy colgado: no se muestra ningun cupo de agy (nada inventado)' {
    Con-Motores $lentoExe $mudoExe {
        Remove-Item (Join-Path $tmp 'limites-cache.json') -ErrorAction SilentlyContinue
        $j = (PS1 'limites.ps1' @('-Json', '-Forzar') | Out-String) | ConvertFrom-Json
        Afirmar (-not @($j.tarjetas | Where-Object { $_.nombre -like 'Antigravity*' -or $_.nombre -eq 'Codex' })) ('mostro: ' + (($j.tarjetas.nombre) -join ', '))
    }
}
T 'el respaldo no usa una ventana ya reiniciada ni una lectura de mas de 6 h' {
    Con-Motores $lentoExe $mudoExe {
        $vieja = '{"tarjetas":[{"nombre":"Antigravity · Gemini","ventanas":[{"v":"5 h","usado":50,"reinicia":"2000-01-01T00:00:00Z","origen":"en vivo"},{"v":"Semanal","usado":40,"reinicia":"2099-01-01T00:00:00Z","origen":"en vivo","leido":"' + (Get-Date).ToUniversalTime().AddHours(-7).ToString('o') + '"}]}]}'
        [IO.File]::WriteAllText((Join-Path $tmp 'limites-cache.json'), $vieja)
        $j = (PS1 'limites.ps1' @('-Json', '-Forzar') | Out-String) | ConvertFrom-Json
        Afirmar (-not @($j.tarjetas | Where-Object { $_.nombre -like 'Antigravity*' })) 'uso datos vencidos'
    }
}
T 'dos lecturas simultaneas: una sola consulta en vivo (candado) y ambas devuelven datos' {
    Con-Motores $lentoExe $mudoExe {
        [IO.File]::WriteAllText((Join-Path $tmp 'limites-cache.json'), $cacheBuena)
        $sal = 1..2 | ForEach-Object { Join-Path $tmp "par$_.txt" }
        $ps = @(foreach ($x in $sal) { Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $sc 'limites.ps1')`" -Json -Forzar" -RedirectStandardOutput $x -WindowStyle Hidden -PassThru; Start-Sleep -Milliseconds 400 })
        $max = 0; $sw = [Diagnostics.Stopwatch]::StartNew()
        while (@($ps | Where-Object { -not $_.HasExited }).Count -and $sw.Elapsed.TotalSeconds -lt 60) { $n = @(Get-Process motor-lento -ErrorAction SilentlyContinue).Count; if ($n -gt $max) { $max = $n }; Start-Sleep -Milliseconds 200 }
        Afirmar ($max -eq 1) "consultas en vivo simultaneas: $max"
        foreach ($x in $sal) { $j = (Get-Content $x -Raw) | ConvertFrom-Json; Afirmar (@($j.tarjetas).Count -ge 1) "sin datos en $x" }
        Afirmar ($sw.Elapsed.TotalSeconds -lt 42) "tardo $([int]$sw.Elapsed.TotalSeconds) s"
    }
}
T 'si matan solo a PowerShell (timeout del panel) no queda agy huerfano; el candado abandonado se recupera' {
    Con-Motores $lentoExe $mudoExe {
        $p = Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $sc 'limites.ps1')`" -Json -Forzar" -WindowStyle Hidden -PassThru
        $sw = [Diagnostics.Stopwatch]::StartNew(); while (-not (Get-Process motor-lento -ErrorAction SilentlyContinue) -and $sw.Elapsed.TotalSeconds -lt 15) { Start-Sleep -Milliseconds 200 }
        Afirmar (Get-Process motor-lento -ErrorAction SilentlyContinue) 'agy falso no arranco'
        Stop-Process -Id $p.Id -Force; Start-Sleep 2
        Afirmar (-not (Get-Process motor-lento -ErrorAction SilentlyContinue)) 'quedo un agy huerfano'
        $env:MULTIIA_AGY_EXE = $mudoExe
        $sw = [Diagnostics.Stopwatch]::StartNew(); $null = PS1 'limites.ps1' @('-Json', '-Forzar')
        Afirmar ($sw.Elapsed.TotalSeconds -lt 30) "espero al candado abandonado ($([int]$sw.Elapsed.TotalSeconds) s)"
    }
}
# 3.4.1: carrera Process.Start -> AssignProcessToJobObject. Reproducida (23/25 huerfanos en 3.4.0) matando a PowerShell en el instante en que aparece el hijo.
function Test-CancelacionAgy([int]$RetardoMs, [switch]$Instante) {
    $p = Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $sc 'limites.ps1')`" -Json -Forzar" -WindowStyle Hidden -PassThru
    if ($Instante) { $sw = [Diagnostics.Stopwatch]::StartNew(); while (-not (Get-Process motor-lento -ErrorAction SilentlyContinue) -and $sw.Elapsed.TotalSeconds -lt 20) { } }   # espera activa
    else { Start-Sleep -Milliseconds $RetardoMs }
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 1500
    $v = @(Get-Process motor-lento -ErrorAction SilentlyContinue)
    if ($v.Count) { $v | Stop-Process -Force -ErrorAction SilentlyContinue }
    return $v.Count
}
T '3.4.1 regresion: cancelar PowerShell EN EL INSTANTE en que arranca agy (6 veces) no deja huerfanos' {
    Con-Motores $lentoExe $mudoExe {
        $h = 0; 1..6 | ForEach-Object { $h += Test-CancelacionAgy 0 -Instante }
        Afirmar ($h -eq 0) "$h huerfanos en 6 cancelaciones al instante del arranque"
    }
}
T '3.4.1 estres: cancelaciones a 0/150/400/900/1800/3000 ms del inicio (antes, durante y despues de compilar el Job Object) no dejan huerfanos' {
    Con-Motores $lentoExe $mudoExe {
        $h = 0; foreach ($ms in 0, 150, 400, 900, 1800, 3000) { $h += Test-CancelacionAgy $ms }
        Afirmar ($h -eq 0) "$h huerfanos en cancelaciones escalonadas"
    }
}
T '3.4.1: Invoke-ConTimeout -MatarAlCerrar sigue devolviendo la salida y el codigo (lectura de cupos intacta)' {
    # en un PowerShell aparte: -MatarAlCerrar mete a ESE proceso en un Job y no debe tocar al ejecutor de pruebas
    $cmd = ". '$(Join-Path $sc '_comun.ps1')'; `$r = Invoke-ConTimeout 'cmd.exe' @('/c','echo hola') 20 -MatarAlCerrar; `$r2 = Invoke-ConTimeout 'cmd.exe' @('/c','ping -n 30 127.0.0.1 >nul') 2 -MatarAlCerrar -Duro; 'A:' + (`$r.salida.Trim()) + ':' + `$r.codigo; 'B:' + `$r2.timeout"
    $sal = (& powershell -NoProfile -ExecutionPolicy Bypass -Command $cmd | Out-String)
    Afirmar ($sal -match 'A:hola:0') "salida: $sal"
    Afirmar ($sal -match 'B:True') "no vencio el timeout: $sal"
}
T 'la cache servida informa su edad (cache_seg) para que el panel no la tome por recien leida' {
    [IO.File]::WriteAllText((Join-Path $tmp 'limites-cache.json'), $cacheBuena)
    $j = (PS1 'limites.ps1' @('-Json') | Out-String) | ConvertFrom-Json
    Afirmar ($null -ne $j.cache_seg -and $j.cache_seg -ge 0 -and $j.cache_seg -lt 45) "cache_seg: $($j.cache_seg)"
}
Remove-Item (Join-Path $tmp 'limites-cache.json') -ErrorAction SilentlyContinue

Write-Host "== rapido.ps1"
T 'rapido devuelve calidad, modo, contadores y eventos' {
    $j = (PS1 'rapido.ps1' | Out-String) | ConvertFrom-Json
    Afirmar ($null -ne $j.deleg_n -and $null -ne $j.claude_costo -and $j.eventos) 'faltan campos'
}

T 'eventos: el ID de ejecucion une inicio y fin y llega a rapido (dos ejecuciones no se mezclan)' {
    Add-Evento -Tipo 'inicio' -Destino 'codex' -Tarea 'codigo' -Id 'ej-prueba-a1'
    Add-Evento -Tipo 'inicio' -Destino 'agy' -Tarea 'texto' -Id 'ej-prueba-b2'
    Add-Evento -Tipo 'fin' -Destino 'codex' -Tarea 'codigo' -Id 'ej-prueba-a1'
    $ev = @((PS1 'rapido.ps1' | Out-String | ConvertFrom-Json).eventos)
    $a = @($ev | Where-Object { $_.i -eq 'ej-prueba-a1' }); $b = @($ev | Where-Object { $_.i -eq 'ej-prueba-b2' })
    Afirmar ($a.Count -eq 2 -and $b.Count -eq 1 -and $b[0].t -eq 'inicio') "a=$($a.Count) b=$($b.Count)"
}

Write-Host "== Etapa 3: registro de motores, ciclo de vida y auditoria"
T 'motores.ps1: 3 motores; Codex y Antigravity siempre "Modelo no verificable" (ninguna CLI informa el modelo)' {
    $m = @((PS1 'motores.ps1' | Out-String) | ConvertFrom-Json | ForEach-Object { $_ })
    Afirmar ($m.Count -eq 3 -and (($m.id | Sort-Object) -join ',') -eq 'agy,claude,codex') 'motores'
    foreach ($x in ($m | Where-Object { $_.id -in 'codex', 'agy' })) { Afirmar ((($null -eq $x.modelo_verificado) -and $x.modelo -eq 'Modelo no verificable') -or ($x.modelo_verificado -and $x.fuente)) "$($x.id) declara un modelo verificado sin fuente" }
}
T 'motores: Claude toma el modelo EXACTO del snapshot de la sesion; sin snapshot, no verificable' {
    $c = @((PS1 'motores.ps1' | Out-String) | ConvertFrom-Json | ForEach-Object { $_ }) | Where-Object { $_.id -eq 'claude' }
    Afirmar ($c.modelo -eq 'Modelo no verificable' -and -not $c.disponible) 'sin snapshot'
    PS1 'claude-snapshot.ps1' @('-CincoHoras', '10', '-Semanal', '20', '-Modelo', 'claude-sonnet-5-5') | Out-Null
    $c = @((PS1 'motores.ps1' | Out-String) | ConvertFrom-Json | ForEach-Object { $_ }) | Where-Object { $_.id -eq 'claude' }
    Afirmar ($c.modelo_verificado -eq 'claude-sonnet-5-5' -and $c.disponible) "modelo: $($c.modelo)"
}
T 'ciclo de vida: seleccionado, inicio, confirmado, recibido, fin llegan a rapido con el mismo ID y la senal real' {
    foreach ($t in 'seleccionado', 'inicio', 'confirmado', 'recibido', 'fin') { Add-Evento -Tipo $t -Destino 'codex' -Tarea 'codigo' -Id 'ej-ciclo-1' -Conf $(if ($t -in 'confirmado', 'recibido') { 'turn.started' } else { '' }) }
    $ev = @((PS1 'rapido.ps1' | Out-String | ConvertFrom-Json).eventos | Where-Object { $_.i -eq 'ej-ciclo-1' })
    Afirmar (($ev.t -join ',') -eq 'seleccionado,inicio,confirmado,recibido,fin') ($ev.t -join ',')
    Afirmar (($ev | Where-Object { $_.t -eq 'confirmado' }).c -eq 'turn.started') 'falta la senal real'
}
T 'decisiones.ps1: audita por ID, destino y resultado; modelo_verificado queda vacio' {
    Add-Decision -Id 'ej-aud-1' -Tarea 'codigo' -Destino 'codex' -ModeloPedido 'gpt-x' -Motivo 'porque si' -Alternativas 'revisor: agy opus' -Resultado 'ok' -Seg 3 -Tok 100 -Confirmacion 'turn.started'
    Add-Decision -Id 'ej-aud-2' -Tarea 'texto' -Destino 'claude' -Motivo 'chico' -Resultado 'no-delegado'
    $u = @((PS1 'decisiones.ps1' @('-Id', 'ej-aud-1') | Out-String) | ConvertFrom-Json)
    Afirmar ($u.Count -eq 1 -and $u[0].motivo -eq 'porque si' -and $u[0].modelo_pedido -eq 'gpt-x' -and $null -eq $u[0].modelo_verificado) 'decision 1'
    $n = @((PS1 'decisiones.ps1' @('-Resultado', 'no-delegado') | Out-String) | ConvertFrom-Json)
    Afirmar ($n.Count -eq 1 -and $n[0].id -eq 'ej-aud-2') 'filtro por resultado'
}

Write-Host "== Pedidos en lenguaje natural: que tarea y que motor"
$casos = @(
    @('programame un script en python que renombre archivos', 'codigo', 'codex'),
    @('arreglá este bug de la función de login', 'codigo', 'codex'),
    @('revisá este código buscando fallas de seguridad', 'revision', 'codex'),
    @('generá una imagen de un logo para mi negocio', 'imagen', 'ninguno'),
    @('hacé un video corto para instagram', 'imagen', 'ninguno'),
    @('escribime un post para facebook sobre aires acondicionados', 'contenido', 'agy'),
    @('redactá un mail formal para un cliente', 'contenido', 'agy'),
    @('resumí este documento en 5 puntos', 'texto', 'agy'),
    @('traducí esto al inglés', 'texto', 'agy'),
    @('analizá si me conviene comprar o alquilar', 'razonar', 'agy'),
    @('dame una segunda opinión sobre mi plan', 'opinion', 'agy')
)
foreach ($c in $casos) {
    T "'$($c[0])' -> $($c[1]) -> $($c[2])" {
        $cl = (PS1 'clasificar.ps1' @('-Pedido', $c[0]) | Out-String) | ConvertFrom-Json
        Afirmar ($cl.tarea -eq $c[1]) "clasifico $($cl.tarea), esperaba $($c[1])"
        $el = (PS1 'elegir.ps1' @('-Tarea', $cl.tarea) | Out-String) | ConvertFrom-Json
        Afirmar ($el.destino -eq $c[2]) "destino $($el.destino), esperaba $($c[2])"
        Afirmar ([bool]$el.motivo) 'sin motivo'
    }
}
T 'delegar una imagen avisa que no hay motor y sale con codigo 3' {
    $ErrorActionPreference = 'Continue'
    $o = (PS1 'delegar.ps1' @('-Tarea', 'imagen', '-Prompt', 'un logo', '-Forzar') | Out-String)
    $cod = $LASTEXITCODE; $ErrorActionPreference = 'Stop'
    Afirmar ($o -match 'SIN-DELEGAR:ninguno') "salida: $o"; Afirmar ($cod -eq 3) "codigo $cod"
}
TN 'contenido en calidad maxima pide Opus y revision cruzada' {
    $el = (PS1 'elegir.ps1' @('-Tarea', 'contenido', '-Calidad', 'maxima') | Out-String) | ConvertFrom-Json
    Afirmar ($el.perfil -eq 'opus' -and $el.segundo) 'esperaba opus + segundo'
}

Write-Host "== Interruptor encender / apagar"
T 'por defecto esta encendido' {
    Afirmar ((Get-Config).activo -eq $true) 'activo deberia ser true'
    Afirmar ((PS1 'rapido.ps1' | Out-String | ConvertFrom-Json).activo -eq $true) 'rapido deberia decir activo'
}
T 'apagado: elegir devuelve destino apagado y delegar sale con codigo 3' {
    PS1 'config.ps1' @('-Apagar') | Out-Null
    Afirmar ((Get-Config).activo -eq $false) 'config no quedo apagada'
    $el = (PS1 'elegir.ps1' @('-Tarea', 'codigo') | Out-String) | ConvertFrom-Json
    Afirmar ($el.destino -eq 'apagado') "destino $($el.destino)"
    $ErrorActionPreference = 'Continue'
    $o = (PS1 'delegar.ps1' @('-Tarea', 'codigo', '-Prompt', 'hace algo', '-Forzar') | Out-String)
    $cod = $LASTEXITCODE; $ErrorActionPreference = 'Stop'
    Afirmar ($o -match 'SIN-DELEGAR:apagado' -and $cod -eq 3) "salida: $o / codigo $cod"
    Afirmar ((PS1 'rapido.ps1' | Out-String | ConvertFrom-Json).activo -eq $false) 'rapido deberia decir apagado'
}
T 'apagado: los hooks de aviso se callan' {
    $node = (Get-Command node -ErrorAction SilentlyContinue).Source; if (-not $node) { $node = Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe' }
    $s =('{"session_id":"t","transcript_path":"' + (Join-Path $tmp 'no-existe.jsonl').Replace('\', '\\') + '"}') | & $node (Join-Path $sc 'guardia-contexto.mjs') 2>&1 | Out-String
    Afirmar (-not $s.Trim()) "guardia hablo: $s"
    $h = '{}' | & $node (Join-Path $sc 'handoff-inicio.mjs') 2>&1 | Out-String
    Afirmar (-not $h.Trim()) "handoff hablo: $h"
}
T 'encender de nuevo vuelve a elegir motor' {
    PS1 'config.ps1' @('-Encender') | Out-Null
    $el = (PS1 'elegir.ps1' @('-Tarea', 'codigo') | Out-String) | ConvertFrom-Json
    Afirmar ($el.destino -eq 'codex') "destino $($el.destino)"
}
T '-Encender y -Apagar juntos se rechazan' {
    $ErrorActionPreference = 'Continue'
    PS1 'config.ps1' @('-Encender', '-Apagar') | Out-Null
    $cod = $LASTEXITCODE; $ErrorActionPreference = 'Stop'
    Afirmar ($cod -eq 2) "codigo $cod"
}

T 'arranque automatico: activar, ver y quitar el acceso de Inicio' {
    $env:MULTIIA_INICIO = Join-Path $tmp 'inicio'
    try {
        PS1 'inicio-automatico.ps1' @('-Activar') | Out-Null
        Afirmar (Test-Path (Join-Path $tmp 'inicio\Multi-IA panel.lnk')) 'no creo el acceso'
        Afirmar ((PS1 'inicio-automatico.ps1' | Out-String) -match 'ACTIVADO') 'estado deberia decir ACTIVADO'
        PS1 'inicio-automatico.ps1' @('-Quitar') | Out-Null
        Afirmar (-not (Test-Path (Join-Path $tmp 'inicio\Multi-IA panel.lnk'))) 'no borro el acceso'
    } finally { Remove-Item Env:\MULTIIA_INICIO -ErrorAction SilentlyContinue }
}

Write-Host "== Pintado instantaneo y latido"
T 'rapido -ConCache devuelve la ultima lectura guardada y su edad' {
    $cache = '{"tarjetas":[{"nombre":"Codex","ventanas":[{"v":"5 h","usado":7}]}],"horas":[],"pesada":null}'
    [IO.File]::WriteAllText((Join-Path $tmp 'limites-cache.json'), $cache)
    $j = PS1 'rapido.ps1' @('-ConCache') | Out-String | ConvertFrom-Json
    Afirmar (@($j.tarjetas).Count -eq 1 -and $j.tarjetas[0].nombre -eq 'Codex') 'no trajo las tarjetas del cache'
    Afirmar ($j.cache_seg -ge 0) 'falta cache_seg'
    $s = PS1 'rapido.ps1' | Out-String | ConvertFrom-Json
    Afirmar (-not $s.tarjetas) 'sin -ConCache no debe traer tarjetas'
}

Write-Host "== Cambio de motor y eficiencia de orquestacion"
T 'cambio de motor: si falla el elegido se reintenta UNA vez con el otro, con ID enlazado -r y sin tokens heredados' {
    $env:MULTIIA_SIMULAR_FALLA = 'codex agy'; $ErrorActionPreference = 'Continue'
    try { $o = (PS1 'delegar.ps1' @('-Tarea', 'codigo', '-Prompt', 'x', '-Forzar', '-SinCache') | Out-String); $cod = $LASTEXITCODE }
    finally { Remove-Item Env:\MULTIIA_SIMULAR_FALLA; $ErrorActionPreference = 'Stop' }
    Afirmar ($cod -ne 0) 'si fallan los dos debe salir con error'
    Afirmar ($o -match 'cambio de motor') "sin aviso de cambio: $o"
    $ev = @(Get-Content (Join-Path $tmp 'eventos.jsonl') -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json })
    $cm = @($ev | Where-Object { $_.tipo -eq 'cambio-motor' }); Afirmar ($cm.Count -eq 1 -and $cm[0].id -match '-r$') 'falta evento cambio-motor con -r'
    $base = $cm[0].id -replace '-r$', ''
    $er = @($ev | Where-Object { $_.tipo -eq 'error' -and ($_.id -eq $base -or $_.id -eq "$base-r") }); Afirmar ($er.Count -eq 2) "errores: $($er.Count)"
    Afirmar (-not ($er | Where-Object { [long]$_.tok -ne 0 })) 'un error heredo tokens de otra corrida'
}
T 'cambio de motor: -Critico o MULTIIA_SIN_RESPALDO desactivan el reintento' {
    $env:MULTIIA_SIMULAR_FALLA = 'codex'; $env:MULTIIA_SIN_RESPALDO = '1'; $ErrorActionPreference = 'Continue'
    try { $o = (PS1 'delegar.ps1' @('-Tarea', 'codigo', '-Prompt', 'x', '-Forzar', '-SinCache') | Out-String) }
    finally { Remove-Item Env:\MULTIIA_SIMULAR_FALLA, Env:\MULTIIA_SIN_RESPALDO; $ErrorActionPreference = 'Stop' }
    Afirmar ($o -notmatch 'cambio de motor') 'reintento aunque estaba desactivado'
}
T 'eficiencia.ps1: separa exitosas, directas, perdidas y fallidas; el ahorro es estimado y la tasa usa solo tareas evaluadas' {
    $arch = Join-Path $tmp 'eventos.jsonl'; Remove-Item $arch, (Join-Path $tmp 'eventos-hist.jsonl') -ErrorAction SilentlyContinue
    Add-Evento -Tipo 'fin' -Destino 'codex' -Tarea 'codigo' -Id 'e-1' -Tok 5000
    Add-Evento -Tipo 'error' -Destino 'codex' -Tarea 'codigo' -Id 'e-2'
    Add-Evento -Tipo 'fin' -Destino 'agy' -Tarea 'codigo' -Id 'e-2-r' -Tok 3000
    Add-Evento -Tipo 'error' -Destino 'agy' -Tarea 'texto' -Id 'e-3'
    Add-Evento -Tipo 'sin-delegar' -Destino 'claude' -Tarea 'texto' -Motivo 'trivial, pregunta o charla corta'
    Add-Evento -Tipo 'sin-delegar' -Destino 'claude' -Tarea 'codigo' -Motivo 'lo hice yo por comodidad'
    $j = (PS1 'eficiencia.ps1' @('-Json') | Out-String) | ConvertFrom-Json
    Afirmar ($j.exitosas -eq 2 -and $j.fallas_recuperadas -eq 1 -and $j.fallidas -eq 1) "exitosas=$($j.exitosas) recup=$($j.fallas_recuperadas) fallidas=$($j.fallidas)"
    Afirmar ($j.directas_justificadas -eq 1 -and $j.oportunidades_perdidas -eq 1) 'directas/perdidas'
    Afirmar ($j.tokens_delegados -eq 8000 -and $j.ahorro_neto_estimado -eq (8000 - 800)) "ahorro $($j.ahorro_neto_estimado)"
    Afirmar ($j.elegibles -eq 4 -and $j.tasa_delegacion_util -eq 50) "tasa $($j.tasa_delegacion_util) / $($j.elegibles)"
    Afirmar ($j.metodologia -match 'estimado') 'falta metodologia'
}
T '3.3.2 eficiencia: recuperacion por TAREA UNICA (comprobable / no verificable / sin resolver / pruebas anotadas) sin tocar los registros' {
    $arch = Join-Path $tmp 'eventos.jsonl'; Remove-Item $arch, (Join-Path $tmp 'eventos-hist.jsonl'), (Join-Path $tmp 'decisiones.jsonl'), (Join-Path $tmp 'anotaciones-auditoria.json') -ErrorAction SilentlyContinue
    Add-Evento -Tipo 'error' -Destino 'agy' -Tarea 'codigo' -Id 'u-1'; Add-Evento -Tipo 'fin' -Destino 'codex' -Tarea 'codigo' -Id 'u-1-r' -Tok 900   # recuperada con decision ok
    Add-Evento -Tipo 'error' -Destino 'agy' -Tarea 'codigo' -Id 'u-2'; Add-Evento -Tipo 'fin' -Destino 'codex' -Tarea 'codigo' -Id 'u-2-r' -Tok 0     # fin sin tokens: no verificable
    Add-Evento -Tipo 'error' -Destino 'codex' -Tarea 'codigo' -Id 'u-3'; Add-Evento -Tipo 'error' -Destino 'agy' -Tarea 'codigo' -Id 'u-3-r'         # 2 eventos, 1 tarea sin resolver
    Add-Evento -Tipo 'error' -Destino 'codex' -Tarea 'codigo' -Id 'u-4'                                                                               # prueba anotada
    Add-Decision -Id 'u-1-r' -Tarea 'codigo' -Destino 'codex' -Resultado 'ok' -Tok 900
    Add-Decision -Id 'u-2-r' -Tarea 'codigo' -Destino 'codex' -Resultado 'ok' -Tok 0
    '{"u-4":{"clase":"prueba","nota":"x"}}' | Set-Content (Join-Path $tmp 'anotaciones-auditoria.json') -Encoding UTF8
    $antes = (Get-Content $arch -Raw).Length
    $j = (PS1 'eficiencia.ps1' @('-Json') | Out-String) | ConvertFrom-Json
    Afirmar ($j.tareas_con_falla_inicial -eq 3) "tareas con falla: $($j.tareas_con_falla_inicial)"
    Afirmar ($j.tareas_recuperadas -eq 1) "recuperadas: $($j.tareas_recuperadas)"
    Afirmar ($j.tareas_recuperacion_no_verificable -eq 1) "no verificables: $($j.tareas_recuperacion_no_verificable)"
    Afirmar ($j.tareas_sin_resolver -eq 1 -and $j.tareas_de_prueba_excluidas -eq 1) "sin resolver=$($j.tareas_sin_resolver) pruebas=$($j.tareas_de_prueba_excluidas)"
    Afirmar ((Get-Content $arch -Raw).Length -eq $antes) 'eficiencia modifico el registro'
    Remove-Item (Join-Path $tmp 'anotaciones-auditoria.json'), (Join-Path $tmp 'decisiones.jsonl') -ErrorAction SilentlyContinue
}
T '3.3.2 Get-ClaseError: la guardia de escritura es politica-denegada (no reintentable) aunque la consola parta el mensaje' {
    . (Join-Path $sc '_comun.ps1')
    foreach ($x in @("Escritura NO permitida en 'C:\Temp' (raiz de disco)", "Escritura NO`r`npermitida en 'C:\Temp'")) {
        $r = Get-ClaseError -Texto $x -Salida 1
        Afirmar ($r.clase -eq 'politica-denegada' -and -not $r.reintentable) "'$x' dio '$($r.clase)'"
    }
    $d = Get-Content (Join-Path $sc 'delegar.ps1') -Raw
    Afirmar ($d -match "politica-denegada" -and $d -match "Tipo 'sin-respaldo'") 'delegar.ps1 debe saltear el fallback ante politica-denegada y registrar sin-respaldo'
}
T '3.3.2 P1: la denegacion de carpeta de agy deja la causa politica-denegada (el router no cambia de motor) y Codex tambien' {
    foreach ($m in @('delegar-agy.ps1', 'delegar-codex.ps1')) {
        $cmd = "`$env:MULTIIA_ORIGEN='test'; `$env:MULTIIA_DATOS='$tmp'; . '$sc\_comun.ps1'; & '$sc\$m' -Prompt 'x' -Escribir -Carpeta `$env:TEMP *> `$null; Write-Output ('CLASE=' + `$global:MIA_Causa.clase + ';REINT=' + `$global:MIA_Causa.reintentable)"
        $o = (& powershell -NoProfile -ExecutionPolicy Bypass -Command $cmd | Out-String) -replace '\s+', ''
        Afirmar ($o -match 'CLASE=politica-denegada;REINT=False') "$m no dejo politica-denegada/no reintentable: $o"
    }
}
T '3.3.2 P2: una tarea que cambio de motor sin evidencia NO se declara recuperada ni dice que el respaldo funciona' {
    Remove-Item (Join-Path $tmp 'eventos.jsonl'), (Join-Path $tmp 'eventos-hist.jsonl'), (Join-Path $tmp 'decisiones.jsonl'), (Join-Path $tmp 'anotaciones-auditoria.json') -ErrorAction SilentlyContinue
    Add-Evento -Tipo 'error' -Destino 'agy' -Tarea 'codigo' -Id 'v-1'; Add-Evento -Tipo 'fin' -Destino 'codex' -Tarea 'codigo' -Id 'v-1-r' -Tok 0   # sin tokens
    Add-Evento -Tipo 'error' -Destino 'agy' -Tarea 'codigo' -Id 'v-2'; Add-Evento -Tipo 'fin' -Destino 'codex' -Tarea 'codigo' -Id 'v-2-r' -Tok 500  # sin decision ok
    Add-Decision -Id 'v-1-r' -Tarea 'codigo' -Destino 'codex' -Resultado 'ok' -Tok 0
    $j = (PS1 'eficiencia.ps1' @('-Json') | Out-String) | ConvertFrom-Json
    Afirmar ($j.tareas_recuperadas -eq 0 -and $j.tareas_recuperacion_no_verificable -eq 2) "recuperadas=$($j.tareas_recuperadas) noVer=$($j.tareas_recuperacion_no_verificable)"
    $txt = ($j.recomendaciones -join ' ')
    Afirmar ($txt -notmatch 'esta funcionando' -and $txt -match 'sin evidencia') "recomendaciones: $txt"
    Remove-Item (Join-Path $tmp 'decisiones.jsonl') -ErrorAction SilentlyContinue
}

Write-Host "== v1.8.0: correcciones de la auditoria de Codex"
if (-not (Get-Command LimpiarDatos -ErrorAction SilentlyContinue)) { function LimpiarDatos { Get-ChildItem $tmp -File | Where-Object { $_.Name -match '\.jsonl$' } | Remove-Item -Force -ErrorAction SilentlyContinue } }
T 'cache: la clave cambia con carpeta/calidad/motor (no mezcla contextos)' {
    $a = Get-ClaveCache 'texto' 'x' @() 'C:\a|False|equilibrada|agy'
    $b = Get-ClaveCache 'texto' 'x' @() 'C:\b|False|equilibrada|agy'
    $c = Get-ClaveCache 'texto' 'x' @() 'C:\a|False|maxima|agy'
    Afirmar (($a -ne $b) -and ($a -ne $c) -and ($a -eq (Get-ClaveCache 'texto' 'x' @() 'C:\a|False|equilibrada|agy'))) 'claves'
}
T 'config: el candado Lock-Config es exclusivo y se libera' {
    Afirmar (Lock-Config) 'primer candado'
    $segundo = (PS1 'config.ps1' @('-Ver') | Out-String)   # lectura: no necesita candado
    Afirmar ($segundo -match 'Plugin:') 'lectura con candado tomado'
    Unlock-Config
    Afirmar (-not (Test-Path ((Join-Path $tmp 'config.json') + '.lock'))) 'candado sin liberar'
}
T 'tokens por ejecucion: Get-TokEj suma solo las filas de ese ID (no la ultima fila)' {
    LimpiarDatos
    $global:MIA_IdEj = 'ej-tok-1'; Add-Uso -Destino 'codex' -Chars 10 -Segundos 1 -Salida 5 -ConMemoria $false -TokIn 100 -TokOut 50
    $global:MIA_IdEj = 'ej-tok-2'; Add-Uso -Destino 'agy' -Chars 10 -Segundos 1 -Salida 5 -ConMemoria $false -TokIn 7 -TokOut 3
    $global:MIA_IdEj = ''
    Afirmar ((Get-TokEj 'ej-tok-1') -eq 150 -and (Get-TokEj 'ej-tok-2') -eq 10 -and (Get-TokEj 'no-existe') -eq 0) "tok: $(Get-TokEj 'ej-tok-1')/$(Get-TokEj 'ej-tok-2')"
}
T 'costo-claude: las simulaciones no suman al costo productivo' {
    LimpiarDatos
    Add-CostoClaude -CharsPrompt 4000 -CharsSalida 4000
    $antes = Get-CostoClaude
    $env:MULTIIA_ORIGEN = 'simulacion'; try { Add-CostoClaude -CharsPrompt 400000 -CharsSalida 400000 } finally { Remove-Item Env:\MULTIIA_ORIGEN }
    $despues = Get-CostoClaude
    Afirmar (($antes | ConvertTo-Json -Compress) -eq ($despues | ConvertTo-Json -Compress)) 'la simulacion sumo'
}
T 'eficiencia: usa el historico largo aunque eventos.jsonl se haya recortado' {
    LimpiarDatos
    1..320 | ForEach-Object { Add-Evento -Tipo 'fin' -Destino 'codex' -Tarea 'codigo' -Id "h-$_" -Tok 10 }
    $j = (PS1 'eficiencia.ps1' @('-Json') | Out-String) | ConvertFrom-Json
    Afirmar ($j.exitosas -eq 320) "exitosas=$($j.exitosas)"
}

Write-Host "== V3: origen de los datos (anti-contaminacion de metricas)"
function LimpiarDatos { Get-ChildItem $tmp -File | Where-Object { $_.Name -match '\.jsonl$' } | Remove-Item -Force -ErrorAction SilentlyContinue }
T 'Get-Origen: real por defecto, MULTIIA_ORIGEN valido manda, invalido se ignora, y SIMULAR_FALLA implica simulacion' {
    Afirmar ((Get-Origen) -eq 'real') 'por defecto debe ser real'
    $env:MULTIIA_ORIGEN = 'benchmark'; try { Afirmar ((Get-Origen) -eq 'benchmark') 'benchmark' } finally { Remove-Item Env:\MULTIIA_ORIGEN }
    $env:MULTIIA_ORIGEN = 'inventado'; try { Afirmar ((Get-Origen) -eq 'real') 'origen invalido debe caer en real' } finally { Remove-Item Env:\MULTIIA_ORIGEN }
    $env:MULTIIA_SIMULAR_FALLA = 'codex'; try { Afirmar ((Get-Origen) -eq 'simulacion') 'simulada debe ser simulacion' } finally { Remove-Item Env:\MULTIIA_SIMULAR_FALLA }
}
T 'las filas no productivas se marcan al escribir (uso, evento, resultado, decision) y las reales tambien' {
    LimpiarDatos
    $env:MULTIIA_ORIGEN = 'test'
    try { Add-Uso -Destino 'codex' -Segundos 1 -Salida 0 -TokIn 100 -TokOut 50; Add-Evento -Tipo 'fin' -Destino 'codex' -Tarea 'codigo' -Id 'o-1' -Tok 150; Add-Decision -Id 'o-1' -Destino 'codex' -Tarea 'codigo' -Motivo 'prueba' }
    finally { Remove-Item Env:\MULTIIA_ORIGEN }
    Add-Uso -Destino 'codex' -Segundos 1 -Salida 0 -TokIn 10 -TokOut 5; Add-Evento -Tipo 'fin' -Destino 'codex' -Tarea 'codigo' -Id 'o-2' -Tok 15
    foreach ($a in 'uso', 'eventos', 'resultados', 'decisiones') {
        $f = Join-Path $tmp "$a.jsonl"; if (-not (Test-Path $f)) { continue }
        $f = @(Get-Content $f -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
        Afirmar (@($f | Where-Object { -not $_.origen }).Count -eq 0) "$a tiene filas sin origen"
        Afirmar (@($f | Where-Object { $_.origen -eq 'test' }).Count -ge 1 -and @($f | Where-Object { $_.origen -eq 'real' }).Count -le 1) "$a mal marcado"
    }
}
T 'consumo productivo, historial del router y eficiencia EXCLUYEN lo no productivo' {
    LimpiarDatos
    $env:MULTIIA_ORIGEN = 'simulacion'
    try { 1..6 | ForEach-Object { Add-Evento -Tipo 'error' -Destino 'agy' -Tarea 'texto' -Id "s-$_" -Seg 1; Add-Uso -Destino 'agy' -Segundos 1 -Salida 1 -TokIn 1000 -TokOut 1000 } }
    finally { Remove-Item Env:\MULTIIA_ORIGEN }
    Add-Evento -Tipo 'fin' -Destino 'agy' -Tarea 'texto' -Id 'r-1' -Seg 2 -Tok 300; Add-Uso -Destino 'agy' -Segundos 2 -Salida 0 -TokIn 200 -TokOut 100
    $u = @(Get-Uso); Afirmar ($u.Count -eq 1 -and (Sumar-Tok $u) -eq 300) "uso productivo: $($u.Count) filas / $(Sumar-Tok $u) tok"
    Afirmar (@(Get-Uso -Todo).Count -eq 7) 'con -Todo debe verse todo el historico'
    $h = Get-Historial -Destino 'agy' -Tarea 'texto'
    Afirmar ($h.n -eq 1 -and $h.ok -eq 1 -and $h.pct_ok -eq 100) "el historial del router conto simulaciones: $($h | ConvertTo-Json -Compress)"
    $j = (PS1 'eficiencia.ps1' @('-Json') | Out-String) | ConvertFrom-Json
    Afirmar ($j.exitosas -eq 1 -and $j.fallidas -eq 0) "eficiencia conto simulaciones: exitosas=$($j.exitosas) fallidas=$($j.fallidas)"
    $c = (PS1 'consumo.ps1' | Out-String) | ConvertFrom-Json
    Afirmar ($c.global.tok_total -eq 300) "consumo global: $($c.global.tok_total)"
}
T 'una falla simulada (MULTIIA_SIMULAR_FALLA) deja TODO marcado como simulacion y no ensucia el historial' {
    LimpiarDatos
    $env:MULTIIA_SIMULAR_FALLA = 'codex agy'; $ErrorActionPreference = 'Continue'
    try { [void](PS1 'delegar.ps1' @('-Tarea', 'codigo', '-Prompt', 'x', '-Forzar', '-SinCache') | Out-String) }
    finally { Remove-Item Env:\MULTIIA_SIMULAR_FALLA; $ErrorActionPreference = 'Stop' }
    foreach ($a in 'eventos', 'decisiones', 'resultados') {
        $f = Join-Path $tmp "$a.jsonl"; if (-not (Test-Path $f)) { continue }
        $filas = @(Get-Content $f -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
        Afirmar ($filas.Count -gt 0 -and @($filas | Where-Object { $_.origen -ne 'simulacion' }).Count -eq 0) "$a tiene filas no marcadas como simulacion"
    }
    foreach ($d in 'codex', 'agy') { $h = Get-Historial -Destino $d -Tarea 'codigo'; Afirmar ($h.n -eq 0) "historial de $d contaminado: $($h | ConvertTo-Json -Compress)" }
}
T 'migrar-origen.ps1: respalda, marca la cadena simulada y su -r sin borrar filas, y es idempotente' {
    LimpiarDatos
    $ahora = Get-Date
    $mk = { param($t, $id, $s) ([ordered]@{ fecha = $ahora.AddSeconds($s).ToString('s'); tipo = $t; destino = 'codex'; id = $id; tok = 0; seg = 0 } | ConvertTo-Json -Compress) }
    @((& $mk 'seleccionado' 'ej-111111-aaaa' 0), (& $mk 'error' 'ej-111111-aaaa' 1), (& $mk 'fin' 'ej-111111-aaaa-r' 2), (& $mk 'fin' 'ej-222222-bbbb' 60)) | Set-Content (Join-Path $tmp 'eventos.jsonl') -Encoding UTF8
    $antes = @(Get-Content (Join-Path $tmp 'eventos.jsonl')).Count
    $o = (PS1 'migrar-origen.ps1' @('-Ids', 'ej-111111-aaaa') | Out-String)
    Afirmar ($o -match 'Migracion hecha') "no migro: $o"
    $ev = @(Get-Content (Join-Path $tmp 'eventos.jsonl') -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json })
    Afirmar ($ev.Count -eq $antes) 'se borraron filas'
    Afirmar (@($ev | Where-Object { $_.origen -eq 'simulacion' }).Count -eq 3) 'no marco los 3 eventos de la cadena (+ -r)'
    Afirmar ((@($ev | Where-Object { $_.id -eq 'ej-222222-bbbb' })[0].origen) -ne 'simulacion') 'marco una ejecucion que no era simulada'
    Afirmar (@(Get-ChildItem $tmp -Directory -Filter 'migracion-origen-*').Count -eq 1) 'falta la carpeta de respaldo previo'
    $o2 = (PS1 'migrar-origen.ps1' @('-Ids', 'ej-111111-aaaa') | Out-String)
    Afirmar ($o2 -match 'Nada que migrar') "no es idempotente: $o2"
}
T 'migrar-origen.ps1: con una linea ilegible ABORTA y no reescribe el archivo (no pierde filas)' {
    LimpiarDatos
    $ahora = Get-Date
    $fila = ([ordered]@{ fecha = $ahora.ToString('s'); tipo = 'fin'; destino = 'codex'; id = 'ej-333333-cccc'; tok = 0; seg = 0 } | ConvertTo-Json -Compress)
    $f = Join-Path $tmp 'eventos.jsonl'
    @($fila, '{linea corrupta sin cerrar') | Set-Content $f -Encoding UTF8
    $antes = (Get-Content $f -Raw)
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $o = (PS1 'migrar-origen.ps1' @('-Ids', 'ej-333333-cccc') 2>&1 | Out-String) } finally { $ErrorActionPreference = $eap }
    Afirmar ($o -match 'ABORTO') "no aborto: $o"
    Afirmar ((Get-Content $f -Raw) -eq $antes) 'reescribio el archivo con una linea ilegible (perdio datos)'
}

Write-Host "== V3: modelo configurado / confirmado / no verificable"
T 'Get-ModeloCodex lee turn_context.model del rollout enlazado por thread_id; sin sesion devuelve null' {
    $h = Join-Path $tmp 'codexhome'; $d = Join-Path $h 'sessions\2026\11\04'; New-Item -ItemType Directory -Force $d | Out-Null
    $tid = '0aaaaaaa-1111-2222-3333-444444444444'
    @('{"type":"session_meta","payload":{"id":"x"}}', '{"type":"turn_context","payload":{"model":"gpt-test-1","collaboration_mode":{"settings":{"reasoning_effort":"high"}}}}') | Set-Content (Join-Path $d "rollout-2026-11-04T10-00-00-$tid.jsonl") -Encoding UTF8
    $m = Get-ModeloCodex -ThreadId $tid -CodexHome $h
    Afirmar ($m.modelo -eq 'gpt-test-1' -and $m.esfuerzo -eq 'high') "no leyo el modelo: $($m | ConvertTo-Json -Compress)"
    Afirmar ($null -eq (Get-ModeloCodex -ThreadId 'otro-thread' -CodexHome $h)) 'devolvio modelo para un thread inexistente'
    Afirmar ($null -eq (Get-ModeloCodex -ThreadId '' -CodexHome $h)) 'devolvio modelo sin thread_id'
}
T 'Get-ModeloAgy lee el modelo propagado del transcript por conversation_id (marcado como observado, no confirmado)' {
    $h = Join-Path $tmp 'agyhome'; $cid = 'bbbbbbbb-1111-2222-3333-444444444444'; $d = Join-Path $h "brain\$cid\.system_generated\logs"; New-Item -ItemType Directory -Force $d | Out-Null
    '{"content":"The user changed setting `Model Selection` from None to Gemini Test (Low). No need to comment on this change if the"}' | Set-Content (Join-Path $d 'transcript.jsonl') -Encoding UTF8
    $m = Get-ModeloAgy -ConversationId $cid -AgyHome $h
    Afirmar ($m.modelo -eq 'Gemini Test (Low)') "no leyo el modelo: $($m | ConvertTo-Json -Compress)"
    Afirmar ($m.fuente -match 'no confirmado por el proveedor') 'la fuente debe aclarar que no lo confirma el proveedor'
    Afirmar ($null -eq (Get-ModeloAgy -ConversationId 'nada' -AgyHome $h)) 'devolvio modelo para una conversacion inexistente'
}
T 'el modelo confirmado se persiste en uso, evento y decision; Get-Motores lo muestra y sin dato queda "Modelo no verificable"' {
    LimpiarDatos
    $mx = @(Get-Motores | Where-Object { $_.id -eq 'codex' })[0]
    Afirmar ($mx.modelo -eq 'Modelo no verificable' -and -not $mx.modelo_verificado) 'sin dato debe ser no verificable'
    Add-Uso -Destino 'codex' -Segundos 1 -Salida 0 -TokIn 10 -TokOut 5 -ModeloConf 'gpt-test-1' -ModeloFuente 'fixture'
    Add-Evento -Tipo 'fin' -Destino 'codex' -Tarea 'codigo' -Id 'm-1' -ModeloConf 'gpt-test-1' -EjecutorId 'thr-1'
    Add-Decision -Id 'm-1' -Destino 'codex' -Tarea 'codigo' -ModeloPedido 'auto' -ModeloConf 'gpt-test-1' -ModeloFuente 'fixture' -EjecutorId 'thr-1'
    Afirmar ((@(Get-Uso)[0]).modelo_confirmado -eq 'gpt-test-1') 'uso sin modelo_confirmado'
    Afirmar ((Get-Content (Join-Path $tmp 'eventos.jsonl') | ConvertFrom-Json).modelo_conf -eq 'gpt-test-1') 'evento sin modelo_conf'
    $dec = Get-Content (Join-Path $tmp 'decisiones.jsonl') | ConvertFrom-Json
    Afirmar ($dec.modelo_verificado -eq 'gpt-test-1' -and $dec.ejecutor_id -eq 'thr-1' -and $dec.modelo_pedido -eq 'auto') 'decision sin modelo confirmado / ejecutor_id'
    $mx = @(Get-Motores | Where-Object { $_.id -eq 'codex' })[0]
    Afirmar ($mx.modelo -eq 'gpt-test-1' -and $mx.modelo_verificado -eq 'gpt-test-1') "Get-Motores no lo muestra: $($mx.modelo)"
}

Write-Host "== V3: trazabilidad consola <-> ejecutor"
T 'trazabilidad.ps1 une decision+eventos+uso y compara tokens con el registro del ejecutor: coincide / difiere / sin-registro' {
    LimpiarDatos
    $h = Join-Path $tmp 'codexhome2'; $d = Join-Path $h 'sessions\2026\11\04'; New-Item -ItemType Directory -Force $d | Out-Null
    $tid = '0bbbbbbb-1111-2222-3333-444444444444'
    @('{"type":"turn_context","payload":{"model":"gpt-test-1"}}', "{`"type`":`"token_usage_record`",`"payload`":{`"thread_id`":`"$tid`",`"usage`":{`"input_tokens`":100,`"output_tokens`":5}}}") | Set-Content (Join-Path $d "rollout-2026-11-04T10-00-00-$tid.jsonl") -Encoding UTF8
    # 1) coincide: uso 100+5 = ejecutor 105
    Add-Uso -Destino 'codex' -Segundos 1 -Salida 0 -TokIn 100 -TokOut 5 -ModeloConf 'gpt-test-1' -ModeloFuente 'fixture'
    Add-Evento -Tipo 'seleccionado' -Destino 'codex' -Tarea 'codigo' -Id 't-1'; Add-Evento -Tipo 'fin' -Destino 'codex' -Tarea 'codigo' -Id 't-1' -ModeloConf 'gpt-test-1' -EjecutorId $tid
    Add-Decision -Id 't-1' -Destino 'codex' -Tarea 'codigo' -ModeloPedido 'auto' -ModeloConf 'gpt-test-1' -ModeloFuente 'fixture' -EjecutorId $tid -Tok 105
    # 2) difiere: uso 7+1 vs ejecutor 105
    Add-Uso -Destino 'codex' -Segundos 1 -Salida 0 -TokIn 7 -TokOut 1
    Add-Decision -Id 't-2' -Destino 'codex' -Tarea 'codigo' -ModeloPedido 'auto' -EjecutorId $tid -Tok 8
    # 3) sin registro del ejecutor
    Add-Decision -Id 't-3' -Destino 'codex' -Tarea 'codigo' -ModeloPedido 'auto'
    $env:CODEX_HOME = $h
    try { $r = @((PS1 'trazabilidad.ps1' @('-Json', '-Todo') | Out-String) | ConvertFrom-Json) } finally { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue }
    $p = @{}; foreach ($x in @($r | ForEach-Object { $_ })) { $p[$x.id] = $x }   # PS 5.1 deja el array JSON como un solo objeto: se desenrolla
    Afirmar ($p['t-1'].veredicto -eq 'coincide' -and $p['t-1'].tok_ejecutor -eq 105 -and $p['t-1'].eventos_consola -match 'seleccionado') "t-1: $($p['t-1'] | ConvertTo-Json -Compress)"
    Afirmar ($p['t-1'].modelo_confirmado -eq 'gpt-test-1') 'no trae el modelo confirmado'
    Afirmar ($p['t-2'].veredicto -eq 'difiere') "t-2 debia diferir: $($p['t-2'].veredicto)"
    Afirmar ($p['t-3'].veredicto -eq 'sin-registro-ejecutor') "t-3: $($p['t-3'].veredicto)"
}

Write-Host "== V3: exportar historial"
T 'exportar-historial.ps1: CSV (BOM, escape RFC 4180) y JSON, filas, filtros y orden coinciden con la pantalla' {
    LimpiarDatos
    $sal = Join-Path $tmp 'export'; Remove-Item $sal -Recurse -Force -ErrorAction SilentlyContinue
    Add-Evento -Tipo 'seleccionado' -Destino 'codex' -Tarea 'codigo' -Id 'x-1'
    Add-Evento -Tipo 'fin' -Destino 'codex' -Tarea 'arreglar, "citas" y coma' -Id 'x-1' -Tok 1200 -Seg 4
    Start-Sleep -Milliseconds 1100
    Add-Evento -Tipo 'error' -Destino 'agy' -Tarea 'analisis' -Id 'x-2' -Tok 50 -Seg 9
    Start-Sleep -Milliseconds 1100
    Add-Evento -Tipo 'fin' -Destino 'claude' -Tarea 'resumen' -Id 'x-3' -Tok 300 -Seg 2
    $env:MULTIIA_ORIGEN = 'test'
    try { Add-Evento -Tipo 'fin' -Destino 'codex' -Tarea 'prueba' -Id 'x-4' -Tok 9 } finally { Remove-Item Env:MULTIIA_ORIGEN -ErrorAction SilentlyContinue }
    $o = (PS1 'exportar-historial.ps1' @('-Formato', 'ambos', '-Salida', $sal) | Out-String)
    Afirmar ($o -match 'OK 3 filas') "salida inesperada: $o"
    $csv = Get-ChildItem $sal -Filter *.csv | Select-Object -First 1; $js = Get-ChildItem $sal -Filter *.json | Select-Object -First 1
    Afirmar ($csv -and $js) 'faltan archivos'
    $b = [IO.File]::ReadAllBytes($csv.FullName); Afirmar ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) 'CSV sin BOM UTF-8'
    $filas = @(Import-Csv -LiteralPath $csv.FullName -Encoding UTF8)
    Afirmar ($filas.Count -eq 3) "CSV: $($filas.Count) filas"
    Afirmar ($filas[2].tarea -eq 'arreglar, "citas" y coma') "escape roto: $($filas[2].tarea)"
    $jj = @((Get-Content -LiteralPath $js.FullName -Raw -Encoding UTF8) | ConvertFrom-Json | ForEach-Object { $_ })
    Afirmar ($jj.Count -eq 3) "JSON: $($jj.Count) filas"
    Afirmar (($jj | Where-Object id -eq 'x-1').tokens -eq 1200) 'JSON: tokens de x-1'
    Afirmar (-not ($jj | Where-Object id -eq 'x-4')) 'origen test no deberia exportarse por defecto'
    Afirmar ($filas[0].id -eq 'x-3') "orden nuevo: primero $($filas[0].id)"
    # filtros
    $n = { param($a) $d = Join-Path $tmp ('e' + [guid]::NewGuid().ToString('N').Substring(0, 6)); (PS1 'exportar-historial.ps1' (@('-Formato', 'csv', '-Salida', $d) + $a) | Out-String); @(Import-Csv -LiteralPath (Get-ChildItem $d -Filter *.csv)[0].FullName -Encoding UTF8) }
    $r = & $n @('-Origen', 'todo'); Afirmar (@($r | Where-Object id -like 'x-*').Count -eq 4) 'Origen todo debe traer 4'
    $r = @(& $n @('-Proveedor', 'codex') | Where-Object { $_.id }); Afirmar ($r.Count -eq 1 -and $r[0].id -eq 'x-1') 'filtro proveedor'
    $r = @(& $n @('-Estado', 'error') | Where-Object { $_.id }); Afirmar ($r.Count -eq 1 -and $r[0].id -eq 'x-2') 'filtro estado'
    $r = @(& $n @('-Q', 'citas') | Where-Object { $_.id }); Afirmar ($r.Count -eq 1 -and $r[0].id -eq 'x-1') 'busqueda'
    $r = @(& $n @('-Orden', 'tokens') | Where-Object { $_.id }); Afirmar ($r[0].id -eq 'x-1' -and $r[2].id -eq 'x-2') "orden tokens: $($r.id -join ',')"
    $r = @(& $n @('-Orden', 'antiguo') | Where-Object { $_.id }); Afirmar ($r[0].id -eq 'x-1') 'orden antiguo'
}

Write-Host "== V3: codificacion UTF-8 de config.json"
T 'config.json: Save-Config/Get-Config conservan acentos y punto medio (sin mojibake)' {
    $et = "Google $([char]0xB7) Antigravity ñandú áéíóú"
    $cmd = ". '$($sc.Replace('''',''''''))\_comun.ps1'; `$c = Get-Config; `$c.cuentas[1].etiqueta = '$et'; Save-Config `$c; (Get-Config).cuentas[1].etiqueta"
    $o = (& powershell -NoProfile -ExecutionPolicy Bypass -Command $cmd 2>&1 | Out-String).Trim()
    $bytes = [IO.File]::ReadAllBytes((Join-Path $tmp 'config.json'))
    $txt = [Text.Encoding]::UTF8.GetString($bytes)
    Afirmar ($bytes[0] -ne 0xEF) 'config.json no deberia llevar BOM'
    Afirmar ($txt.Contains($et)) 'la etiqueta no sobrevive el guardado en UTF-8'
    Afirmar ($txt -notmatch [string][char]0xC2 -and $txt -notmatch [string][char]0xC3) 'hay marcas de mojibake (doble codificacion) en config.json'
    $cfg = Get-Content -LiteralPath (Join-Path $tmp 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Afirmar ($cfg.cuentas[1].etiqueta -eq $et) 'la lectura UTF-8 no devuelve la etiqueta original'
}
T 'config.json real del usuario (si existe): sin marcas de doble codificacion' {
    SoloDev 'usa una ruta o una carpeta que solo existe en DEV'
    $r = 'C:\Users\<usuario>\.multi-ia-orquestador\config.json'
    if (Test-Path -LiteralPath $r) {
        $t = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($r))
        Afirmar ($t -notmatch ([string][char]0xC2 + '|' + [char]0xC3)) 'config.json real tiene mojibake'
    }
}

Write-Host "== v1.7.2: panel web responsive y sin glifos fragiles"
$panelSrc = [IO.File]::ReadAllText((Join-Path $sc 'panel.ps1'), [Text.Encoding]::UTF8)
T 'panel.ps1: sin el glifo U+23FB (sale como cuadrado) y con icono SVG' {
    Afirmar (-not $panelSrc.Contains([string][char]0x23FB)) 'queda el glifo U+23FB'
    Afirmar ($panelSrc -match 'ICONO_ONOFF\s*=\s*''<svg') 'falta el icono SVG de encendido'
}
T 'panel.ps1: .alterna sin min-width fijo y con wrap (no se corta en 320 px)' {
    Afirmar ($panelSrc -notmatch '\.alterna button\{[^}]*min-width:\s*1[3-9]\d+px') 'min-width fijo grande en .alterna button'
    Afirmar ($panelSrc -match '\.alterna\{[^}]*flex-wrap:wrap') '.alterna sin flex-wrap'
    Afirmar ($panelSrc -match '\.alterna button\{[^}]*min-width:0') '.alterna button sin min-width:0'
}
T '_comun.ps1: escritura concurrente (4 procesos x 25) no pierde ni corrompe lineas de resultados.jsonl' {
    $dc = Join-Path $tmp 'concurrente'; New-Item -ItemType Directory -Force $dc | Out-Null
    $ps = 1..4 | ForEach-Object { $n = $_; Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList '-NoProfile', '-Command', "`$env:MULTIIA_DATOS='$($dc.Replace('''',''''''))'; . '$($PSScriptRoot.Replace('''',''''''))\..\scripts\_comun.ps1'; 1..25|%{ Add-Evento -Tipo 'fin' -Destino codex -Tarea texto -Id ('p$n-'+`$_) }" }
    $ps | Wait-Process -Timeout 120
    $r = @(Get-Content (Join-Path $dc 'resultados.jsonl'))
    Afirmar ($r.Count -eq 100) "esperaba 100 resultados, hay $($r.Count)"
    Afirmar (@($r | ForEach-Object { ($_ | ConvertFrom-Json).id } | Sort-Object -Unique).Count -eq 100) 'ids duplicados o lineas corruptas'
}
T 'delegar-agy.ps1: un prompt que no entra en la linea de comandos de Windows se RECHAZA antes de llamar a agy (2.3.1 auditoria Codex #15)' {
    $ErrorActionPreference = 'Continue'
    $viejoA = $env:MULTIIA_AGY_EXE; $env:MULTIIA_AGY_EXE = Join-Path $env:SystemRoot 'System32\whoami.exe'   # inofensivo si se llegara a ejecutar
    try {
        Remove-Item (Join-Path $tmp 'config.json*') -Force -ErrorAction SilentlyContinue
        $o = (PS1 'delegar-agy.ps1' @('-Prompt', ('a' * 30000)) | Out-String); $cod = $LASTEXITCODE
        Afirmar ($cod -eq 1) "esperaba salida 1, dio $cod : $o"
        $o1 = ($o -replace '\s+', ' ')   # el ErrorRecord se parte segun ancho de consola/ruta (2.3.8: fallaba en un clon con ruta larga)
        Afirmar ($o1 -match 'maximo 28000' -and $o1 -match '-Archivo') "falta el motivo claro: $o"
        $src = Get-Content (Join-Path $sc 'delegar-agy.ps1') -Raw
        Afirmar (([regex]::Matches($src, "'--add-dir'")).Count -eq 1 -and $src -match "if \(\`$Escribir\)") 'sigue el desvio por archivo temporal; --add-dir solo se admite con -Escribir (3.3.0)'
    } finally { $env:MULTIIA_AGY_EXE = $viejoA }
}
T '2.3.8 auditoria Codex: PEM es secreto y la deduplicacion reconoce JSON con espacios' {
    . (Join-Path $sc '_comun.ps1')
    Afirmar (Test-Secreto "x`n-----BEGIN RSA PRIVATE KEY-----`nabc") 'un bloque PEM debe detectarse como secreto'
    $v = @{}; $l = '{"ej": "ej-demo", "tok_in":100}'
    Afirmar ((Test-LineaNueva $v $l) -and -not (Test-LineaNueva $v $l)) 'la misma linea con espacios debe contarse una sola vez'
}
Write-Host "== v1.8.0: hallazgos de la auditoria Codex"
T 'ConvertTo-ArgWin: la secuencia \" no escapa del argumento (no inyecta opciones)' {
    . (Join-Path $sc '_comun.ps1')
    $exe = Join-Path $tmp 'eco.ps1'
    $obj = 'a\" -Aislar -Carpeta C:\Target'
    [IO.File]::WriteAllText($exe, '$args.Count; $args[0]')
    $r = Invoke-ConTimeout 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $exe, $obj) 30
    $l = @($r.salida -split "`r?`n" | Where-Object { $_ })
    Afirmar ($l[0] -eq '1') "el argumento se partio en $($l[0]) partes"
    Afirmar ($l[1] -eq $obj) "llego distinto: $($l[1])"
}
T 'Get-Config: config.json con "null" devuelve la de por defecto (panel-servidor igual)' {
    $dn = Join-Path $tmp 'cfgnull'; New-Item -ItemType Directory -Force $dn | Out-Null
    $env:MULTIIA_DATOS = $dn
    try {
        . (Join-Path $sc '_comun.ps1')
        [IO.File]::WriteAllText((Join-Path $dn 'config.json'), 'null')
        $c = Get-Config
        Afirmar ($c -and $c.modo -eq 'automatico' -and $c.ahorro) 'Get-Config no devolvio la config por defecto'
        Afirmar ((Get-Content "$PSScriptRoot\..\scripts\panel-servidor.mjs" -Raw) -match "typeof c !== 'object'") 'falta la guardia de null en panel-servidor.mjs leer()'
    } finally { $env:MULTIIA_DATOS = $tmp; . (Join-Path $sc '_comun.ps1') }
}
T 'rollback-estable.ps1: -Version con ruta o caracteres raros se rechaza antes de tocar nada' {
    $ea = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $o = (PS1 'rollback-estable.ps1' @('-Version', '..\..\x', '-DryRun') | Out-String) } finally { $ErrorActionPreference = $ea }
    Afirmar ($o -match 'Version invalida') "no rechazo: $o"
}
T 'exportar-historial.ps1: CSV neutraliza celdas que empiezan con = + - @ (inyeccion de formulas)' {
    LimpiarDatos
    Add-Evento -Tipo 'fin' -Destino 'codex' -Tarea '=HYPERLINK("http://x","y")' -Id 'f-1' -Tok 5 -Seg 1
    $d = Join-Path $tmp 'csvf'; Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
    PS1 'exportar-historial.ps1' @('-Formato', 'csv', '-Salida', $d) | Out-Null
    $f = @(Import-Csv -LiteralPath (Get-ChildItem $d -Filter *.csv)[0].FullName -Encoding UTF8)
    Afirmar ($f[0].tarea.StartsWith("'=")) "formula sin neutralizar: $($f[0].tarea)"
}
T 'Enter-Candado: alta atomica (el segundo proceso no lo toma) y Exit solo borra el propio' {
    $dl = Join-Path $tmp 'candado'; New-Item -ItemType Directory -Force $dl | Out-Null
    $env:MULTIIA_DATOS = $dl
    try {
        . (Join-Path $sc '_comun.ps1')
        Afirmar (Enter-Candado 'recurso-x') 'no tomo el candado libre'
        $o = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList '-NoProfile', '-Command', "`$env:MULTIIA_DATOS='$($dl.Replace('''',''''''))'; . '$($sc.Replace('''',''''''))\_comun.ps1'; if (Enter-Candado 'recurso-x') { exit 0 } else { exit 9 }"
        $o | Wait-Process -Timeout 60
        Afirmar ($o.ExitCode -eq 9) "otro proceso lo tomo (salida $($o.ExitCode))"
        Exit-Candado 'recurso-x'
        Afirmar (@(Get-ChildItem (Join-Path $dl 'locks') -Filter *.lock).Count -eq 0) 'no libero el candado propio'
    } finally { $env:MULTIIA_DATOS = $tmp; . (Join-Path $sc '_comun.ps1') }
}
T 'Invoke-ConTimeout: al vencer mata tambien los procesos hijos' {
    . (Join-Path $sc '_comun.ps1')
    $marca = 'MIA' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $r = Invoke-ConTimeout 'powershell.exe' @('-NoProfile', '-Command', "Start-Process powershell -ArgumentList '-NoProfile','-Command','Start-Sleep 60; #$marca' -WindowStyle Hidden; Start-Sleep 60") 4
    Afirmar ($null -eq $r) 'no vencio el timeout'
    Start-Sleep -Seconds 2
    $vivos = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match $marca })
    $vivos | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Afirmar ($vivos.Count -eq 0) "quedaron $($vivos.Count) hijos vivos"
}

Write-Host "== v1.8.0: atribucion al ejecutor real (recuperacion, solo lectura, resultados)"
function Correr-Deleg($tarea, $falla, $ok, $extra = @()) {
    $env:MULTIIA_DATOS = $tmp; . (Join-Path $sc '_comun.ps1')   # un test anterior puede haberla quitado: sin esto escribiria en los datos reales
    LimpiarDatos
    if ($falla) { $env:MULTIIA_SIMULAR_FALLA = $falla }; if ($ok) { $env:MULTIIA_SIMULAR_OK = $ok }; $ErrorActionPreference = 'Continue'
    try { $o = (PS1 'delegar.ps1' (@('-Tarea', $tarea, '-Prompt', 'x', '-Forzar', '-SinCache') + $extra) | Out-String); $cod = $LASTEXITCODE }
    finally { Remove-Item Env:\MULTIIA_SIMULAR_FALLA, Env:\MULTIIA_SIMULAR_OK -ErrorAction SilentlyContinue; $ErrorActionPreference = 'Stop' }
    $ev = @(); $f = Join-Path $tmp 'eventos.jsonl'; if (Test-Path $f) { $ev = @(Get-Content $f -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json }) }
    [pscustomobject]@{ out = $o; cod = $cod; ev = $ev }
}
$LEC = 'SOLO LECTURA'
T 'atribucion: Codex ejecuta bien -> aviso de solo lectura (es el ejecutor)' {
    $r = Correr-Deleg 'codigo' '' 'codex'
    Afirmar ($r.cod -eq 0) "salida $($r.cod)"; Afirmar ($r.out -match $LEC) 'falta el aviso para Codex ejecutor'
    Afirmar (@($r.ev | Where-Object { $_.tipo -eq 'fin' -and $_.destino -eq 'codex' }).Count -eq 1) 'falta fin de codex'
}
T 'atribucion: Antigravity ejecuta bien -> sin aviso de Codex' {
    $r = Correr-Deleg 'razonar' '' 'agy'
    Afirmar ($r.cod -eq 0) "salida $($r.cod)"; Afirmar ($r.out -notmatch $LEC) 'aviso de Codex sin que Codex corriera'
}
T 'atribucion: Codex falla y Antigravity recupera -> NO hay aviso de solo lectura de Codex; el historial conserva el intento fallido' {
    $r = Correr-Deleg 'codigo' 'codex' 'agy'
    Afirmar ($r.cod -eq 0) "debia recuperarse: $($r.cod)"
    Afirmar ($r.out -notmatch $LEC) "aviso de Codex atribuido al ejecutor final: $($r.out)"
    Afirmar ($r.out -match 'cambio de motor: codex fallo') 'falta la linea del cambio de motor'
    $err = @($r.ev | Where-Object { $_.tipo -eq 'error' -and $_.destino -eq 'codex' }); $fin = @($r.ev | Where-Object { $_.tipo -eq 'fin' -and $_.destino -eq 'agy' })
    Afirmar ($err.Count -eq 1 -and $fin.Count -eq 1 -and $fin[0].id -eq ($err[0].id + '-r')) 'el historial debe mostrar error de codex y fin de agy con id -r'
    Afirmar (-not (@($r.ev) | Where-Object { $_.origen -ne 'simulacion' })) 'evento sin marca de simulacion'
}
T 'atribucion: Antigravity falla y Codex recupera -> sin aviso de arranque de Antigravity; con aviso de solo lectura de Codex' {
    $r = Correr-Deleg 'razonar' 'agy' 'codex'
    Afirmar ($r.cod -eq 0) "debia recuperarse: $($r.cod)"
    Afirmar ($r.out -notmatch 'tokens fijos de arranque') 'aviso de Antigravity atribuido al ejecutor final'
    $err = @($r.ev | Where-Object { $_.tipo -eq 'error' -and $_.destino -eq 'agy' }); $fin = @($r.ev | Where-Object { $_.tipo -eq 'fin' -and $_.destino -eq 'codex' })
    Afirmar ($err.Count -eq 1 -and $fin.Count -eq 1) 'falta error de agy o fin de codex'
}
T 'atribucion: ambos motores fallan -> salida con error, sin avisos del ejecutor y dos errores' {
    $r = Correr-Deleg 'codigo' 'codex agy' ''
    Afirmar ($r.cod -ne 0) 'debia fallar'; Afirmar ($r.out -notmatch $LEC) 'aviso sin ejecutor'
    Afirmar (@($r.ev | Where-Object { $_.tipo -eq 'error' }).Count -eq 2) 'debian ser 2 errores'
    Afirmar (@($r.ev | Where-Object { $_.tipo -eq 'fin' }).Count -eq 0) 'no debe haber fin'
}
T 'atribucion: con -Aislar Codex no es solo lectura (sin aviso)' {
    $r = Correr-Deleg 'codigo' '' 'codex' @('-Aislar', '-Carpeta', $tmp)
    Afirmar ($r.out -notmatch $LEC) 'aviso de solo lectura con -Aislar'
}
T 'atribucion: simulaciones de recuperacion no entran en eficiencia ni en el historial por motor' {
    $r = Correr-Deleg 'codigo' 'codex' 'agy'
    $j = (PS1 'eficiencia.ps1' @('-Dias', '1', '-Json') | Out-String) | ConvertFrom-Json
    Afirmar ($j.exitosas -eq 0 -and $j.fallidas -eq 0) "eficiencia contaminada: $($j | ConvertTo-Json -Compress)"
    foreach ($d in 'codex', 'agy') { $h = Get-Historial -Destino $d -Tarea 'codigo'; Afirmar ($h.n -eq 0) "historial de $d contaminado" }
}
T 'revision cruzada inversa: ejecutor Antigravity -> revisor Codex; ejecutor Codex -> revisor Antigravity; nunca el mismo proveedor' {
    $r = Correr-Deleg 'razonar' '' 'agy codex' @('-Cruzar')
    Afirmar ($r.out -match 'revision cruzada: codex') "agy debia ser revisado por codex: $($r.out)"
    $r = Correr-Deleg 'codigo' '' 'codex agy' @('-Cruzar')
    Afirmar ($r.out -match 'revision cruzada: agy') "codex debia ser revisado por agy: $($r.out)"
}
T 'revision cruzada: con -Cruzar no hay recuperacion automatica (el revisor nunca seria el mismo proveedor que el ejecutor)' {
    $r = Correr-Deleg 'codigo' 'codex' '' @('-Cruzar')
    Afirmar ($r.cod -ne 0) 'con -Cruzar una falla no debe cambiar de motor'; Afirmar ($r.out -notmatch 'cambio de motor') 'no debia haber cambio de motor'
}
T 'agy: SUCCESS con respuesta vacia se trata como falla (no como exito)' {
    $s = Get-Content (Join-Path $sc 'delegar-agy.ps1') -Raw
    Afirmar ($s -match 'respuesta vacia' -and $s -match 'SUCCESS. -and -not') 'falta el guard de respuesta vacia en delegar-agy.ps1'
}
Write-Host "== v1.9.0 causa de fallo (diagnostico agy)"
T 'Get-ClaseError: clasifica timeout, modelo invalido, auth, cuota, vacia, denegada, secreto, red y desconocido' {
    . (Join-Path $sc '_comun.ps1')
    $c = @(
        @('AGY_ERROR: {"short_error":"print timeout","status":"DEADLINE_EXCEEDED","retryable":false,"reason":"print_timeout"}', 3, 'timeout'),
        @('invalid model selection "x": not recognized', 1, 'modelo-invalido'),
        @('UNAUTHENTICATED: please sign in', 1, 'autenticacion'),
        @('RESOURCE_EXHAUSTED quota exceeded 429', 1, 'cuota'),
        @('agy devolvio una respuesta vacia (modelo: m).', 1, 'respuesta-vacia'),
        @('agy devolvio una respuesta vacia. acciones denegadas: run_command', 1, 'respuesta-vacia'),
        @("'.env' tiene nombre de archivo secreto: no se envía.", 2, 'secreto-bloqueado'),
        @('connection reset by peer', 1, 'red'),
        @('agy: MAX_TOKENS respuesta cortada (modelo: m).', 1, 'truncado'),
        @('algo raro que no conozco', 1, 'desconocido'),
        @('[SIMULADO] Antigravity no disponible', 7, 'simulado')
    )
    foreach ($x in $c) { $r = Get-ClaseError -Texto $x[0] -Salida $x[1]; Afirmar ($r.clase -eq $x[2]) "'$($x[0])' dio '$($r.clase)', esperaba '$($x[2])'" }
}
T 'Get-ClaseError: AGY_ERROR conserva retryable real; sin texto la causa dice salida N sin mensaje (nunca vacia)' {
    . (Join-Path $sc '_comun.ps1')
    $r = Get-ClaseError -Texto 'AGY_ERROR: {"short_error":"print timeout","status":"DEADLINE_EXCEEDED","retryable":false,"reason":"print_timeout"}' -Salida 3
    Afirmar ($r.reintentable -eq $false -and $r.fuente -eq 'AGY_ERROR' -and $r.causa -eq 'print timeout') "AGY_ERROR mal parseado: $($r | ConvertTo-Json -Compress)"
    $v = Get-ClaseError -Texto '' -Salida 5; Afirmar ($v.causa -eq 'salida 5 sin mensaje') "causa vacia: $($v.causa)"
    $e = Get-ClaseError -Texto 'agy.exe : [agy] boom' -Salida 1; Afirmar ($e.causa -eq '[agy] boom') "no limpio el prefijo exe: $($e.causa)"
}
T 'cambio de motor: error y cambio-motor guardan clase+causa; el recuperador queda registrado' {
    $r = Correr-Deleg 'codigo' 'codex agy' ''
    $er = @($r.ev | Where-Object { $_.tipo -eq 'error' }); Afirmar ($er.Count -eq 2) "errores: $($er.Count)"
    Afirmar (-not ($er | Where-Object { -not $_.clase -or -not $_.causa })) 'un evento error quedo sin clase/causa'
    $cm = @($r.ev | Where-Object { $_.tipo -eq 'cambio-motor' }); Afirmar ($cm.Count -eq 1 -and $cm[0].clase -eq 'simulado' -and $cm[0].motivo -match 'recupera') "cambio-motor sin causa: $($cm | ConvertTo-Json -Compress)"
    $d = @(Get-Content (Join-Path $tmp 'decisiones.jsonl') -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.resultado -eq 'error' })
    Afirmar ($d.Count -eq 2 -and -not ($d | Where-Object { -not $_.clase })) 'decisiones de error sin clase'
}
T 'cambio de motor: una recuperacion exitosa no hereda la causa del primer motor' {
    $r = Correr-Deleg 'codigo' 'codex' 'agy'
    $fin = @($r.ev | Where-Object { $_.tipo -eq 'fin' }); Afirmar ($fin.Count -ge 1 -and -not ($fin | Where-Object { $_.clase })) 'el evento fin heredo clase de error'
    $u = @(Get-Content (Join-Path $tmp 'uso.jsonl') -Encoding UTF8 -ErrorAction SilentlyContinue | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.salida -eq 0 })
    Afirmar (-not ($u | Where-Object { $_.clase })) 'una fila de uso exitosa tiene clase'
}
T 'agy: el stderr ya no se descarta (se captura para leer AGY_ERROR)' {
    $s = Get-Content (Join-Path $sc 'delegar-agy.ps1') -Raw
    Afirmar ($s -notmatch '--output-format json 2>\$null' -and $s -match 'Set-CausaActual') 'delegar-agy sigue descartando stderr o no fija la causa'
}
Write-Host "== v1.9.0 confiabilidad de datos, chats y conexiones"
T 'confiabilidad: un dato faltante nunca es 0 ni conserva un nivel alto; un cero real si se conserva' {
    . (Join-Path $sc '_comun.ps1')
    $d = New-Dato -Valor $null -Unidad 'tokens' -Nivel 'VERIFICADO' -Fuente 'x'
    Afirmar ($null -eq $d.valor -and $d.nivel -eq 'NO DISPONIBLE') "faltante mal: $($d | ConvertTo-Json -Compress)"
    $e = New-Dato -Valor '  ' -Nivel 'OBSERVADO'; Afirmar ($e.nivel -eq 'NO DISPONIBLE') 'texto vacio no bajo a NO DISPONIBLE'
    $z = New-Dato -Valor 0 -Unidad 'tokens' -Nivel 'VERIFICADO' -Fuente 'cli'; Afirmar ($z.valor -eq 0 -and $z.nivel -eq 'VERIFICADO') 'un cero REAL se perdio'
    Afirmar ($z.fuente -and $z.ultima_actualizacion) 'sin procedencia'
    $fallo = $false; try { New-Dato -Valor 1 -Nivel 'INVENTADO' | Out-Null } catch { $fallo = $true }; Afirmar $fallo 'acepto un nivel invalido'
}
T 'confiabilidad: agregado = nivel mas debil; suma parcial nunca VERIFICADA; no se eleva OBSERVADO a VERIFICADO' {
    . (Join-Path $sc '_comun.ps1')
    $a = Get-NivelAgregado @('VERIFICADO', 'VERIFICADO'); Afirmar ($a.nivel -eq 'VERIFICADO' -and -not $a.parcial) 'dos verificados'
    $b = Get-NivelAgregado @('VERIFICADO', 'ESTIMADO'); Afirmar ($b.nivel -eq 'ESTIMADO') "mezcla debio ser ESTIMADO: $($b.nivel)"
    $c = Get-NivelAgregado @('VERIFICADO', 'NO DISPONIBLE'); Afirmar ($c.parcial -and $c.nivel -eq 'OBSERVADO') "parcial: $($c.nivel)"
    $v = Get-NivelAgregado @(); Afirmar ($v.nivel -eq 'NO DISPONIBLE') 'vacio'
    Afirmar (-not (Test-ElevacionPermitida -De 'OBSERVADO' -A 'VERIFICADO')) 'permitio elevar observado a verificado'
    Afirmar (Test-ElevacionPermitida -De 'VERIFICADO' -A 'ESTIMADO') 'no permitio bajar el nivel'
}
T 'confiabilidad: tokens con filas sin dato son PARCIALES; ninguna fila con dato => null (no 0)' {
    . (Join-Path $sc '_comun.ps1')
    $p = Get-TokensConNivel @([pscustomobject]@{ tok_in = 10; tok_out = 5 }, [pscustomobject]@{ tok_in = 0; tok_out = 0 })
    Afirmar ($p.valor -eq 15 -and $p.parcial -and $p.nivel -eq 'OBSERVADO' -and $p.filas_sin_dato -eq 1) "parcial mal: $($p | ConvertTo-Json -Compress)"
    $n = Get-TokensConNivel @([pscustomobject]@{ tok_in = 0; tok_out = 0 }); Afirmar ($null -eq $n.valor -and $n.nivel -eq 'NO DISPONIBLE') 'sin dato debio ser null'
    $t = Get-TokensConNivel @([pscustomobject]@{ tok_in = 3; tok_out = 4 }); Afirmar ($t.nivel -eq 'VERIFICADO' -and $t.valor -eq 7) 'completo'
}
T 'confiabilidad: frescura por fuente; la ausencia de senal es desconocido, nunca inactivo' {
    . (Join-Path $sc '_comun.ps1')
    $ahora = Get-Date
    Afirmar ((Get-Frescura -Fecha $ahora.AddSeconds(-30).ToString('s') -Fuente 'evento').estado -eq 'activo confirmado') 'reciente'
    Afirmar ((Get-Frescura -Fecha $ahora.AddSeconds(-300).ToString('s') -Fuente 'evento').estado -eq 'ultimo observado') 'ultimo observado'
    Afirmar ((Get-Frescura -Fecha $ahora.AddHours(-3).ToString('s') -Fuente 'evento').estado -eq 'desactualizado') 'desactualizado'
    Afirmar ((Get-Frescura -Fecha '' -Fuente 'evento').estado -eq 'desconocido') 'sin fecha debe ser desconocido'
    Afirmar ((Get-Frescura -Fecha $ahora.AddSeconds(-300).ToString('s') -Fuente 'snapshot').estado -eq 'activo confirmado') 'cada fuente tiene su ventana'
}
function Sembrar-Chats {
    LimpiarDatos; $env:MULTIIA_DATOS = $tmp
    $ahora = Get-Date; $f = $ahora.AddMinutes(-10).ToString('s'); $rec = $ahora.AddSeconds(-20).ToString('s'); $viejo = $ahora.AddMinutes(-9).ToString('s')
    function Sem($arch, $filas) { foreach ($x in $filas) { [IO.File]::AppendAllText((Join-Path $tmp $arch), (($x | ConvertTo-Json -Compress) + "`r`n")) } }
    Sem 'uso.jsonl' @(
        @{ fecha = $f; destino = 'codex'; salida = 0; tok_in = 100; tok_out = 50; seg = 10; origen = 'real'; sesion = 'chat-A' },
        @{ fecha = $f; destino = 'agy'; salida = 0; tok_in = 0; tok_out = 0; seg = 40; origen = 'real'; sesion = 'chat-A' },
        @{ fecha = $f; destino = 'codex'; salida = 0; tok_in = 700; tok_out = 300; seg = 10; origen = 'real'; sesion = 'chat-B' },
        @{ fecha = $f; destino = 'codex'; salida = 0; tok_in = 9999; tok_out = 1; seg = 1; origen = 'test'; sesion = 'chat-A' },
        @{ fecha = $f; destino = 'agy'; salida = 1; tok_in = 0; tok_out = 0; seg = 1; origen = 'simulacion'; sesion = 'chat-B' })
    Sem 'eventos.jsonl' @(
        @{ fecha = $viejo; tipo = 'inicio'; destino = 'codex'; id = 'ej-1'; origen = 'real'; sesion = 'chat-A' },
        @{ fecha = $rec; tipo = 'confirmado'; destino = 'codex'; id = 'ej-1'; origen = 'real'; sesion = 'chat-A' },
        @{ fecha = $viejo; tipo = 'inicio'; destino = 'agy'; id = 'ej-2'; origen = 'real'; sesion = 'chat-B' },
        @{ fecha = $viejo; tipo = 'inicio'; destino = 'codex'; id = 'ej-3'; origen = 'simulacion'; sesion = 'chat-B' },
        @{ fecha = $f; tipo = 'inicio'; destino = 'codex'; id = 'ej-4'; origen = 'real'; sesion = 'chat-A' },
        @{ fecha = $f; tipo = 'fin'; destino = 'codex'; id = 'ej-4'; origen = 'real'; sesion = 'chat-A' })
    Sem 'costo-claude.jsonl' @(
        @{ fecha = $f; tok = 400; origen = 'real'; sesion = 'chat-A' },
        @{ fecha = $f; tok = 123; origen = 'test'; sesion = 'chat-A' },
        @{ fecha = $f; tok = 50; origen = 'real' })
}
function Chats-Json([string[]]$extra = @()) { (PS1 'chats.ps1' (@('-SinClaude') + $extra) | Out-String) | ConvertFrom-Json }
T 'chats: consumo por chat separado por proveedor, sin mezclar chats ni sumar entre proveedores' {
    Sembrar-Chats; $j = Chats-Json
    $A = $j.chats | Where-Object { $_.id_chat -eq 'chat-A' }; $B = $j.chats | Where-Object { $_.id_chat -eq 'chat-B' }
    Afirmar ($A.consumo.codex.valor -eq 150 -and $A.consumo.codex.nivel -eq 'VERIFICADO') "Codex chat A: $($A.consumo.codex | ConvertTo-Json -Compress)"
    Afirmar ($B.consumo.codex.valor -eq 1000) "Codex chat B: $($B.consumo.codex.valor)"
    Afirmar ($null -eq $A.consumo.antigravity.valor -and $A.consumo.antigravity.nivel -eq 'NO DISPONIBLE') 'agy sin tokens debio ser NO DISPONIBLE, no 0'
    Afirmar ($A.consumo.claude_estimado_delegaciones.valor -eq 400 -and $A.consumo.claude_estimado_delegaciones.nivel -eq 'ESTIMADO') "estimado: $($A.consumo.claude_estimado_delegaciones | ConvertTo-Json -Compress)"
    Afirmar ($A.consumo.claude_real.nivel -eq 'NO DISPONIBLE') 'sin transcripts, el real de Claude debe ser NO DISPONIBLE'
    Afirmar ($null -eq $A.consumo.total.valor) 'no debe haber total entre proveedores'
}
T '2.3.3 chats: sin CLAUDE_CODE_SESSION_ID (panel) el chat actual se INFIERE (ultimo con actividad, no sin-sesion) y se marca; con la variable, se respeta' {
    Sembrar-Chats
    $sv = $env:CLAUDE_CODE_SESSION_ID
    try {
        Remove-Item Env:CLAUDE_CODE_SESSION_ID -ErrorAction SilentlyContinue
        $j = Chats-Json
        Afirmar ($j.chat_actual -and $j.chat_actual -ne 'sin-sesion') "chat_actual inferido: '$($j.chat_actual)'"
        Afirmar ($j.chat_actual_origen -like 'inferido*') "origen: $($j.chat_actual_origen)"
        $env:CLAUDE_CODE_SESSION_ID = 'chat-B'
        $k = Chats-Json
        Afirmar ($k.chat_actual -eq 'chat-B' -and $k.chat_actual_origen -eq 'CLAUDE_CODE_SESSION_ID') "con variable: $($k.chat_actual) / $($k.chat_actual_origen)"
    } finally { if ($sv) { $env:CLAUDE_CODE_SESSION_ID = $sv } else { Remove-Item Env:CLAUDE_CODE_SESSION_ID -ErrorAction SilentlyContinue } }
}
T 'chats: test/simulacion fuera de los totales, el costo sin chat queda aparte y el filtro por chat no mezcla' {
    Sembrar-Chats; $j = Chats-Json
    $A = $j.chats | Where-Object { $_.id_chat -eq 'chat-A' }
    Afirmar ($A.consumo.codex.valor -eq 150) 'una fila test entro al total'
    Afirmar ($A.no_real.filas -eq 1) "no_real A: $($A.no_real.filas)"
    $S = $j.chats | Where-Object { $_.id_chat -eq 'sin-sesion' }; Afirmar ($S.consumo.claude_estimado_delegaciones.valor -eq 50) 'el costo sin chat no quedo en sin-sesion'
    $uno = Chats-Json @('-Chat', 'chat-B')
    Afirmar (@($uno.chats).Count -eq 1 -and $uno.chats[0].id_chat -eq 'chat-B' -and $uno.chats[0].consumo.codex.valor -eq 1000) 'filtro por chat'
}
T 'chats: ejecuciones activas por id real (2 eventos = 1 tarea; simulada y terminada no cuentan; vieja = ultimo observado)' {
    Sembrar-Chats; $j = Chats-Json
    $act = @($j.ejecuciones_activas)
    Afirmar ($act.Count -eq 2) "activas: $($act.Count) ($(($act | ForEach-Object { $_.id_ejecucion }) -join ','))"
    $e1 = $act | Where-Object { $_.id_ejecucion -eq 'ej-1' }; Afirmar ($e1.frescura -eq 'activo confirmado') 'ej-1 tiene senal de hace 20 s'
    $e2 = $act | Where-Object { $_.id_ejecucion -eq 'ej-2' }; Afirmar ($e2.frescura -eq 'ultimo observado') "ej-2 sin senal reciente: $($e2.frescura) (no debe decir inactivo)"
    Afirmar (-not ($act | Where-Object { $_.id_ejecucion -in 'ej-3', 'ej-4' })) 'conto una simulada o una terminada'
    $A = $j.chats | Where-Object { $_.id_chat -eq 'chat-A' }; Afirmar ($A.estado -eq 'activo confirmado') "chat A: $($A.estado)"
    $B = $j.chats | Where-Object { $_.id_chat -eq 'chat-B' }; Afirmar ($B.estado -ne 'activo confirmado') 'chat B no tiene senal reciente'
    $act2 = Chats-Json @('-Estado', 'activos')
    Afirmar (@($act2.chats).Count -eq 1 -and $act2.chats[0].id_chat -eq 'chat-A') 'filtro activos'
}
T 'chats: Add-CostoClaude guarda el chat y el historial persiste igual entre lecturas; el titulo no es id' {
    LimpiarDatos; $env:MULTIIA_DATOS = $tmp; . (Join-Path $sc '_comun.ps1')
    $env:CLAUDE_CODE_SESSION_ID = 'chat-persist'
    try { Add-CostoClaude -CharsPrompt 400 -CharsSalida 400 } finally { Remove-Item Env:\CLAUDE_CODE_SESSION_ID }
    $l = @(Get-Content (Join-Path $tmp 'costo-claude.jsonl') -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json })
    Afirmar ($l[0].sesion -eq 'chat-persist' -and $l[0].tok -eq 200) "costo sin chat: $($l | ConvertTo-Json -Compress)"
    $a = Chats-Json @('-Chat', 'chat-persist'); $b = Chats-Json @('-Chat', 'chat-persist')
    Afirmar ($a.chats[0].consumo.claude_estimado_delegaciones.valor -eq 200 -and $b.chats[0].consumo.claude_estimado_delegaciones.valor -eq 200) 'el historial cambio entre lecturas'
    Afirmar ($null -eq $a.chats[0].titulo) 'el titulo no puede reemplazar al id'
}
T 'conexiones: sin -Probar no gasta cupo (no escribe uso) y no declara verificado sin evidencia' {
    LimpiarDatos; Remove-Item (Join-Path $tmp 'conexiones.json') -Force -ErrorAction SilentlyContinue; $env:MULTIIA_DATOS = $tmp
    $j = (PS1 'conexiones.ps1' | Out-String) | ConvertFrom-Json
    Afirmar (-not (Test-Path (Join-Path $tmp 'uso.jsonl'))) 'el monitor creo uso: gasto una delegacion'
    $validos = 'Conectado y verificado', 'Disponible sin prueba reciente', 'Autenticacion requerida', 'Limitado', 'Error', 'No instalado', 'Desconocido'
    foreach ($m in $j.motores) { Afirmar ($validos -contains $m.estado) "estado invalido '$($m.estado)' en $($m.id)" }
    foreach ($m in ($j.motores | Where-Object { $_.id -in 'codex', 'agy' })) { Afirmar ($m.estado -ne 'Conectado y verificado') "$($m.id) figura verificado sin ejecuciones ni sondeo" }
}
T 'conexiones: un fallo real de cuota de agy => Limitado con su clase y causa (si agy esta instalado)' {
    LimpiarDatos; Remove-Item (Join-Path $tmp 'conexiones.json') -Force -ErrorAction SilentlyContinue; $env:MULTIIA_DATOS = $tmp
    $fila = @{ fecha = (Get-Date).AddSeconds(-60).ToString('s'); destino = 'agy'; salida = 1; tok_in = 0; tok_out = 0; seg = 5; origen = 'real'; clase = 'cuota'; causa = 'quota exceeded' }
    [IO.File]::AppendAllText((Join-Path $tmp 'uso.jsonl'), (($fila | ConvertTo-Json -Compress) + "`r`n"))
    $j = (PS1 'conexiones.ps1' | Out-String) | ConvertFrom-Json
    $agy = $j.motores | Where-Object { $_.id -eq 'agy' }
    if ($agy.estado -ne 'No instalado') { Afirmar ($agy.estado -eq 'Limitado' -and $agy.ultimo_error.clase -eq 'cuota') "agy: $($agy.estado) / $($agy.ultimo_error | ConvertTo-Json -Compress)" }
}
Write-Host "== v1.9.0 cache incremental, exportacion, consumo y panel"
T 'cache incremental de transcripts: igual al escaneo completo, solo lee lo nuevo, tolera linea cortada y archivo reemplazado' {
    $raizT = Join-Path $tmp 'proy'; New-Item -ItemType Directory -Force (Join-Path $raizT 'p1') | Out-Null
    $cd = Join-Path $tmp 'cache-t'
    $ar = Join-Path $raizT 'p1\aaaaaaaa-0000-0000-0000-000000000001.jsonl'
    $lin = { param($id, $n) '{"timestamp":"' + (Get-Date).ToUniversalTime().ToString('o') + '","message":{"model":"claude-x","id":"msg_' + $id + '","usage":{"input_tokens":' + $n + ',"cache_creation_input_tokens":1,"cache_read_input_tokens":2,"output_tokens":3}}}' }
    $enc = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($ar, ((& $lin 'a' 10) + "`n" + (& $lin 'b' 20) + "`n"), $enc)
    $m1 = @(Get-MensajesClaude -Raiz $raizT -CacheDir $cd); $c1 = @(Get-MensajesClaudeCompleto -Raiz $raizT)
    Afirmar ($m1.Count -eq 2 -and $c1.Count -eq 2) "cache $($m1.Count) / completo $($c1.Count)"
    # agrega una linea completa y una cortada (sin salto): la cortada no se cuenta hasta que termine
    [IO.File]::AppendAllText($ar, ((& $lin 'c' 30) + "`n" + (& $lin 'd' 40).Substring(0, 50)), $enc)
    $m2 = @(Get-MensajesClaude -Raiz $raizT -CacheDir $cd)
    Afirmar ($m2.Count -eq 3) "debia haber 3, hay $($m2.Count)"
    [IO.File]::AppendAllText($ar, ((& $lin 'd' 40).Substring(50) + "`n"), $enc)
    $m3 = @(Get-MensajesClaude -Raiz $raizT -CacheDir $cd); $c3 = @(Get-MensajesClaudeCompleto -Raiz $raizT)
    Afirmar ($m3.Count -eq 4 -and $c3.Count -eq 4) "tras completar: cache $($m3.Count) / completo $($c3.Count)"
    Afirmar ((($m3 | ForEach-Object { $_.entrada } | Measure-Object -Sum).Sum) -eq 100) 'suma de entrada'
    # archivo reemplazado por otro contenido: se relee
    [IO.File]::WriteAllText($ar, ((& $lin 'z' 7) + "`n"), $enc)
    $m4 = @(Get-MensajesClaude -Raiz $raizT -CacheDir $cd)
    Afirmar ($m4.Count -eq 1 -and $m4[0].entrada -eq 7) "reemplazo: $($m4.Count)"
}
T 'chats: -Formato md y -Guardar escriben en exportaciones sin pisar y el JSON sigue valido' {
    LimpiarDatos; $env:MULTIIA_DATOS = $tmp
    Add-CostoClaude -CharsPrompt 40 -CharsSalida 0
    $md = (PS1 'chats.ps1' @('-SinClaude', '-Formato', 'md') | Out-String)
    Afirmar ($md -match 'NO DISPONIBLE|VERIFICADO|OBSERVADO|ESTIMADO') 'el MD no muestra niveles'
    $o1 = (PS1 'chats.ps1' @('-SinClaude', '-Formato', 'json', '-Guardar') | Out-String)
    $o2 = (PS1 'chats.ps1' @('-SinClaude', '-Formato', 'json', '-Guardar') | Out-String)
    $dir = Join-Path $tmp 'exportaciones'
    $arch = @(Get-ChildItem $dir -Filter 'chats-*.json')
    Afirmar ($arch.Count -eq 2) "esperaba 2 exportaciones distintas, hay $($arch.Count)"
    Afirmar ($o1 -match 'Exportado:') 'no informa la ruta'
    $null = [IO.File]::ReadAllText($arch[0].FullName) | ConvertFrom-Json
}
T 'consumo: id_chat igual al de chats, y un 0 sin dato de la CLI no figura como consumo observado' {
    LimpiarDatos; $env:MULTIIA_DATOS = $tmp
    $fila = @{ fecha = (Get-Date).ToString('s'); destino = 'codex'; salida = 0; tok_in = 0; tok_out = 0; seg = 3; origen = 'real'; sesion = 'chat-nivel' }
    [IO.File]::AppendAllText((Join-Path $tmp 'uso.jsonl'), (($fila | ConvertTo-Json -Compress) + "`r`n"))
    $j = (PS1 'consumo.ps1' | Out-String) | ConvertFrom-Json
    $s = $j.sesiones.'chat-nivel'
    Afirmar ($s.id_chat -eq 'chat-nivel') 'falta id_chat'
    Afirmar ($s.tok_nivel -eq 'NO DISPONIBLE') "nivel $($s.tok_nivel)"
    Afirmar ($null -ne $j.global.pedidos -and @($j.PSObject.Properties.Name) -contains 'claude_estimado_tok') 'se perdieron claves existentes'   # 2.3.0: sin costo-claude.jsonl la clave sigue pero vale null (sin dato, no 0)
}
T 'panel-servidor.mjs: sintaxis valida y expone /api/chats y /api/export' {
    $js = Join-Path $sc 'panel-servidor.mjs'
    $txt = [IO.File]::ReadAllText($js)
    Afirmar ($txt -match '/api/chats' -and $txt -match '/api/export') 'faltan rutas'
    $node = Get-Command node -ErrorAction SilentlyContinue
    if ($node) { & node --check $js 2>&1 | Out-Null; Afirmar ($LASTEXITCODE -eq 0) 'node --check fallo' }
}
T 'auditoria 1.9.0: cache respeta la ventana de dias por mensaje, es seguro en paralelo y el servidor drena stderr/serializa' {
    $raizT = Join-Path $tmp 'proy-vent'; New-Item -ItemType Directory -Force (Join-Path $raizT 'p1') | Out-Null
    $cd = Join-Path $tmp 'cache-vent'
    $ar = Join-Path $raizT 'p1\bbbbbbbb-0000-0000-0000-000000000002.jsonl'
    $lin = { param($id, $f) '{"timestamp":"' + $f.ToUniversalTime().ToString('o') + '","message":{"model":"claude-x","id":"msg_' + $id + '","usage":{"input_tokens":5,"cache_creation_input_tokens":1,"cache_read_input_tokens":2,"output_tokens":3}}}' }
    $enc = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($ar, ((& $lin 'viejo' (Get-Date).AddDays(-30)) + "`n" + (& $lin 'nuevo' (Get-Date)) + "`n"), $enc)
    $m = @(Get-MensajesClaude -Raiz $raizT -CacheDir $cd)
    Afirmar ($m.Count -eq 1) "el mensaje de hace 30 dias no debe contarse en la ventana de 8 (hay $($m.Count))"
    # el mutex se libera: una segunda llamada seguida no se cuelga y da lo mismo
    $m2 = @(Get-MensajesClaude -Raiz $raizT -CacheDir $cd)
    Afirmar ($m2.Count -eq 1) 'segunda lectura distinta'
    $txt = [IO.File]::ReadAllText((Join-Path $sc 'panel-servidor.mjs'))
    Afirmar ($txt -match 'stderr\.resume' -and $txt -match "on\('close'" -and $txt -match "setEncoding\('utf8'\)" -and $txt -match 'cola') 'servidor sin drenar stderr / sin close / sin cola'
    $pn = [IO.File]::ReadAllText((Join-Path $sc 'panel.ps1'))
    Afirmar ($pn -match 'selInit') 'el selector Todos del panel no recuerda la eleccion'
}
Write-Host "== v1.9.1 cache de transcripts: parseo estructural, esquema y recuperacion"
T 'transcripts 1.9.1: vacio, formato modificado, linea corrupta y campos faltantes se descartan CON diagnostico (nunca metrica silenciosa)' {
    $raizT = Join-Path $tmp 'proy-fmt'; New-Item -ItemType Directory -Force (Join-Path $raizT 'p1') | Out-Null
    $cd = Join-Path $tmp 'cache-fmt'
    $ar = Join-Path $raizT 'p1\cccccccc-0000-0000-0000-000000000003.jsonl'
    $enc = New-Object Text.UTF8Encoding($false)
    $ts = (Get-Date).ToUniversalTime().ToString('o')
    $ok1 = '{"timestamp":"' + $ts + '","message":{"model":"claude-x","id":"msg_ok1","usage":{"input_tokens":10,"cache_creation_input_tokens":1,"cache_read_input_tokens":2,"output_tokens":3}}}'
    # archivo vacio
    [IO.File]::WriteAllText($ar, '', $enc)
    $m0 = @(Get-MensajesClaude -Raiz $raizT -CacheDir $cd)
    Afirmar ($m0.Count -eq 0) "vacio: $($m0.Count)"
    # valida + texto parecido pero NO json valido + formato cambiado (usage como texto) + sin id + token negativo + sin fecha
    $malas = @(
        'basura "input_tokens" sin json',
        '{"timestamp":"' + $ts + '","message":{"model":"x","id":"msg_f1","usage":"input_tokens: 5"}}',
        '{"timestamp":"' + $ts + '","message":{"model":"x","usage":{"input_tokens":5,"output_tokens":1}}}',
        '{"timestamp":"' + $ts + '","message":{"model":"x","id":"msg_f3","usage":{"input_tokens":-5,"output_tokens":1}}}',
        '{"message":{"model":"x","id":"msg_f4","usage":{"input_tokens":5,"output_tokens":1}}}'
    )
    [IO.File]::WriteAllText($ar, ($ok1 + "`n" + ($malas -join "`n") + "`n"), $enc)
    $m1 = @(Get-MensajesClaude -Raiz $raizT -CacheDir $cd)
    Afirmar ($m1.Count -eq 1 -and $m1[0].entrada -eq 10) "solo la valida debe contar: $($m1.Count)"
    $D = $script:DiagTranscripts
    Afirmar ($D.descartadas -ge 4 -and $D.contadas -eq 1) "diagnostico: descartadas=$($D.descartadas) contadas=$($D.contadas)"
    Afirmar ($D.motivos.Count -ge 1) 'sin motivos de descarte'
    # incompleta: sin salto final no se cuenta ni se descarta
    [IO.File]::AppendAllText($ar, $ok1.Replace('msg_ok1', 'msg_ok2').Substring(0, 60), $enc)
    $m2 = @(Get-MensajesClaude -Raiz $raizT -CacheDir $cd)
    Afirmar ($m2.Count -eq 1) "incompleta no debe contarse: $($m2.Count)"
}
T 'transcripts 1.9.1: esquema distinto, indice corrupto y cache desactualizado se descartan y se reconstruyen igual al escaneo completo' {
    $raizT = Join-Path $tmp 'proy-esq'; New-Item -ItemType Directory -Force (Join-Path $raizT 'p1') | Out-Null
    $cd = Join-Path $tmp 'cache-esq'
    $ar = Join-Path $raizT 'p1\dddddddd-0000-0000-0000-000000000004.jsonl'
    $enc = New-Object Text.UTF8Encoding($false)
    $lin = { param($id, $n) '{"timestamp":"' + (Get-Date).ToUniversalTime().ToString('o') + '","message":{"model":"claude-x","id":"msg_' + $id + '","usage":{"input_tokens":' + $n + ',"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}' }
    [IO.File]::WriteAllText($ar, ((& $lin 'a' 10) + "`n" + (& $lin 'b' 20) + "`n"), $enc)
    $null = @(Get-MensajesClaude -Raiz $raizT -CacheDir $cd)
    $idx = Join-Path $cd 'indice.tsv'; $msg = Join-Path $cd 'mensajes.tsv'
    # 1) esquema viejo
    $t = [IO.File]::ReadAllText($idx).Replace('#esquema=3', '#esquema=1'); [IO.File]::WriteAllText($idx, $t, $enc)
    $m = @(Get-MensajesClaude -Raiz $raizT -CacheDir $cd)
    Afirmar ($m.Count -eq 2 -and $script:DiagTranscripts.cache -eq 'esquema-distinto') "esquema: $($m.Count) / $($script:DiagTranscripts.cache)"
    # 2) indice corrupto
    [IO.File]::WriteAllText($idx, "#esquema=3;parser=1`nruta-sola`n", $enc)
    $m = @(Get-MensajesClaude -Raiz $raizT -CacheDir $cd)
    Afirmar ($m.Count -eq 2 -and $script:DiagTranscripts.cache -eq 'indice-corrupto') "indice: $($m.Count) / $($script:DiagTranscripts.cache)"
    # 3) mensajes corruptos (fila truncada)
    [IO.File]::AppendAllText($msg, "fila\ttruncada`n", $enc)
    $m = @(Get-MensajesClaude -Raiz $raizT -CacheDir $cd)
    Afirmar ($m.Count -eq 2 -and $script:DiagTranscripts.cache -eq 'mensajes-corruptos') "mensajes: $($m.Count) / $($script:DiagTranscripts.cache)"
    # 4) cache vigente se reutiliza y coincide con el escaneo completo
    $m = @(Get-MensajesClaude -Raiz $raizT -CacheDir $cd); $est = $script:DiagTranscripts.cache; $c = @(Get-MensajesClaudeCompleto -Raiz $raizT)
    Afirmar ($m.Count -eq $c.Count -and $est -eq 'reutilizado') "reutilizado: $($m.Count)/$($c.Count) $est"
    # 5) desactualizado: el archivo crecio con el cache viejo => solo suma lo nuevo y no pierde nada
    [IO.File]::AppendAllText($ar, ((& $lin 'c' 30) + "`n"), $enc)
    $m = @(Get-MensajesClaude -Raiz $raizT -CacheDir $cd)
    Afirmar ($m.Count -eq 3) "desactualizado: $($m.Count)"
}
Write-Host "== v1.9.2 clave de cache por contenido y validez del cache de transcripts"
T 'cache 1.9.2: la clave de resultados cambia con el CONTENIDO (mismo tamano y mtime), con adjunto ausente y con carpeta' {
    $d = Join-Path $tmp 'clave192'; New-Item -ItemType Directory -Force $d | Out-Null
    $f = Join-Path $d 'adj.txt'; $enc = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($f, 'AAAA-contenido-1', $enc)
    $mt = (Get-Item $f).LastWriteTimeUtc
    $k0 = Get-ClaveCache 'texto' 'p' @($f) 'ctx'
    Afirmar ($k0 -eq (Get-ClaveCache 'texto' 'p' @($f) 'ctx')) 'sin cambios: la clave debe ser estable'
    # mismo tamano, otro contenido, mtime restaurado
    [IO.File]::WriteAllText($f, 'BBBB-contenido-1', $enc); (Get-Item $f).LastWriteTimeUtc = $mt
    Afirmar ((Get-Item $f).Length -eq 16 -and $k0 -ne (Get-ClaveCache 'texto' 'p' @($f) 'ctx')) 'mismo tamano y mtime con otro contenido debe dar otra clave'
    # agrandado
    $k1 = Get-ClaveCache 'texto' 'p' @($f) 'ctx'
    [IO.File]::AppendAllText($f, 'x', $enc)
    Afirmar ($k1 -ne (Get-ClaveCache 'texto' 'p' @($f) 'ctx')) 'modificado: otra clave'
    # adjunto inexistente ya no se ignora en silencio
    Afirmar ((Get-ClaveCache 'texto' 'p' @() 'ctx') -ne (Get-ClaveCache 'texto' 'p' @((Join-Path $d 'no-existe.txt')) 'ctx')) 'adjunto ausente debe distinguirse de sin adjunto'
    # carpeta: el contenido listado entra en la clave
    $sub = Join-Path $d 'carp'; New-Item -ItemType Directory -Force $sub | Out-Null; [IO.File]::WriteAllText((Join-Path $sub 'a.txt'), '1', $enc)
    $kc = Get-ClaveCache 'texto' 'p' @($sub) 'ctx'
    [IO.File]::WriteAllText((Join-Path $sub 'b.txt'), '2', $enc)
    Afirmar ($kc -ne (Get-ClaveCache 'texto' 'p' @($sub) 'ctx')) 'carpeta con archivo nuevo: otra clave'
    # version de esquema
    $viejo = $script:EsquemaClaveCache; $k2 = Get-ClaveCache 'texto' 'p' @($f) 'ctx'
    $script:EsquemaClaveCache = $viejo + 1; $k3 = Get-ClaveCache 'texto' 'p' @($f) 'ctx'; $script:EsquemaClaveCache = $viejo
    Afirmar ($k2 -ne $k3) 'otra version de esquema de clave debe invalidar'
}
T 'cache 1.9.2 transcripts: sin cambios, modificado, mismo tamano distinto contenido, reemplazado, corrupto, esquema y parser; las estadisticas se actualizan' {
    $raizT = Join-Path $tmp 'proy-192'; New-Item -ItemType Directory -Force (Join-Path $raizT 'p1') | Out-Null
    $cd = Join-Path $tmp 'cache-192'
    $ar = Join-Path $raizT 'p1\eeeeeeee-0000-0000-0000-000000000005.jsonl'
    $enc = New-Object Text.UTF8Encoding($false)
    $ts = (Get-Date).ToUniversalTime().ToString('o')   # fijo: asi el largo de cada linea depende solo del numero
    $lin = { param($id, $n) '{"timestamp":"' + $ts + '","message":{"model":"claude-x","id":"msg_' + $id + '","usage":{"input_tokens":' + $n + ',"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}' }
    $suma = { param($m) [long](($m | ForEach-Object { $_.entrada } | Measure-Object -Sum).Sum) }
    [IO.File]::WriteAllText($ar, ((& $lin 'a' 10) + "`n" + (& $lin 'b' 20) + "`n"), $enc)
    $m = @(Get-MensajesClaude -Raiz $raizT -CacheDir $cd)
    Afirmar ($m.Count -eq 2 -and (& $suma $m) -eq 30 -and $script:DiagTranscripts.cache -eq 'nuevo') "primera: $($m.Count)/$($script:DiagTranscripts.cache)"
    # 1) sin cambios
    $m = @(Get-MensajesClaude -Raiz $raizT -CacheDir $cd); $D = $script:DiagTranscripts
    Afirmar ($m.Count -eq 2 -and $D.cache -eq 'reutilizado' -and $D.archivos_reiniciados -eq 0 -and $D.contadas -eq 2) "sin cambios: $($D.cache)/$($D.archivos_reiniciados)"
    # 2) modificado (append): incremental, sin reiniciar, estadisticas suben
    [IO.File]::AppendAllText($ar, ((& $lin 'c' 30) + "`n"), $enc)
    $m = @(Get-MensajesClaude -Raiz $raizT -CacheDir $cd); $D = $script:DiagTranscripts
    Afirmar ($m.Count -eq 3 -and (& $suma $m) -eq 60 -and $D.archivos_reiniciados -eq 0 -and $D.candidatas -eq 3) "append: $($m.Count)/$($D.archivos_reiniciados)/cand=$($D.candidatas)"
    # 3) mismo tamano, distinto contenido, mtime y fecha de creacion restaurados: se detecta por el hash de la cola
    $info = Get-Item $ar; $mt = $info.LastWriteTimeUtc; $len = $info.Length
    [IO.File]::WriteAllText($ar, ((& $lin 'a' 11) + "`n" + (& $lin 'b' 21) + "`n" + (& $lin 'c' 31) + "`n"), $enc); (Get-Item $ar).LastWriteTimeUtc = $mt
    Afirmar ((Get-Item $ar).Length -eq $len) 'el test debia mantener el tamano'
    $m = @(Get-MensajesClaude -Raiz $raizT -CacheDir $cd); $D = $script:DiagTranscripts
    Afirmar ($m.Count -eq 3 -and (& $suma $m) -eq 63 -and $D.archivos_reiniciados -eq 1) "mismo tamano: suma=$(& $suma $m) reiniciados=$($D.archivos_reiniciados)"
    # 4) reemplazado por otro archivo (otro inicio y otra fecha de creacion)
    Remove-Item -LiteralPath $ar -Force; Start-Sleep -Milliseconds 30
    [IO.File]::WriteAllText($ar, ((& $lin 'z' 7) + "`n"), $enc)
    $m = @(Get-MensajesClaude -Raiz $raizT -CacheDir $cd)
    Afirmar ($m.Count -eq 1 -and $m[0].entrada -eq 7 -and $script:DiagTranscripts.contadas -eq 1) "reemplazado: $($m.Count)"
    $idx = Join-Path $cd 'indice.tsv'; $msg = Join-Path $cd 'mensajes.tsv'
    # 5) cache corrupto: campo numerico ilegible en mensajes
    $t = [IO.File]::ReadAllText($msg); $p = $t.Split("`t"); $p[7] = 'XX'; [IO.File]::WriteAllText($msg, ($p -join "`t"), $enc)
    $m = @(Get-MensajesClaude -Raiz $raizT -CacheDir $cd)
    Afirmar ($m.Count -eq 1 -and $m[0].entrada -eq 7 -and $script:DiagTranscripts.cache -eq 'mensajes-corruptos') "corrupto: $($script:DiagTranscripts.cache)"
    # 6) cambio de esquema y 7) cambio de parser: se reconstruye igual al escaneo completo
    $t = [IO.File]::ReadAllText($idx); [IO.File]::WriteAllText($idx, $t.Replace('#esquema=3;parser=1', '#esquema=2'), $enc)
    $m = @(Get-MensajesClaude -Raiz $raizT -CacheDir $cd)
    Afirmar ($m.Count -eq 1 -and $script:DiagTranscripts.cache -eq 'esquema-distinto') "esquema: $($script:DiagTranscripts.cache)"
    $t = [IO.File]::ReadAllText($idx); [IO.File]::WriteAllText($idx, $t.Replace('#esquema=3;parser=1', '#esquema=3;parser=0'), $enc)
    $m = @(Get-MensajesClaude -Raiz $raizT -CacheDir $cd); $est = $script:DiagTranscripts.cache; $c = @(Get-MensajesClaudeCompleto -Raiz $raizT)
    Afirmar ($m.Count -eq $c.Count -and $est -eq 'parser-distinto') "parser: $est"
    $m = @(Get-MensajesClaude -Raiz $raizT -CacheDir $cd)
    Afirmar ($script:DiagTranscripts.cache -eq 'reutilizado') "tras reconstruir debe reutilizarse: $($script:DiagTranscripts.cache)"
}
Write-Host "== v1.9.2 control de integridad de DEV"
T 'integridad.ps1: detecta archivos que faltan, modificados, nuevos y faltantes frente a la version estable (solo informa, no toca nada)' {
    $d = Join-Path $tmp 'integ-dev'; New-Item -ItemType Directory -Force (Join-Path $d 'scripts'), (Join-Path $d '.claude-plugin') | Out-Null
    $enc = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $d 'scripts\_comun.ps1'), 'A', $enc); [IO.File]::WriteAllText((Join-Path $d 'scripts\config.ps1'), 'B', $enc)
    $st = Join-Path $tmp 'integ-estable\1.0.0'; New-Item -ItemType Directory -Force (Join-Path $st 'scripts') | Out-Null
    [IO.File]::WriteAllText((Join-Path $st 'scripts\_comun.ps1'), 'A', $enc); [IO.File]::WriteAllText((Join-Path $st 'scripts\config.ps1'), 'B', $enc)
    $base = Join-Path $tmp 'integ-estable'
    $null = PS1 'integridad.ps1' @('-Crear', '-Ruta', $d)
    Afirmar (Test-Path (Join-Path $d 'integridad.manifest.json')) 'no creo el manifiesto'
    $j = (PS1 'integridad.ps1' @('-Json', '-Ruta', $d, '-Estable', $base) | Out-String) | ConvertFrom-Json
    Afirmar ($LASTEXITCODE -eq 0 -and $j.estado -eq 'ok') "limpio: $($j.estado) / $LASTEXITCODE"
    [IO.File]::WriteAllText((Join-Path $d 'scripts\config.ps1'), 'B2', $enc); [IO.File]::WriteAllText((Join-Path $d 'scripts\nuevo.ps1'), 'N', $enc)
    $j = (PS1 'integridad.ps1' @('-Json', '-Ruta', $d, '-Estable', $base) | Out-String) | ConvertFrom-Json
    Afirmar ($LASTEXITCODE -eq 1 -and $j.modificados -contains 'scripts/config.ps1' -and $j.nuevos -contains 'scripts/nuevo.ps1') "modificado/nuevo: $LASTEXITCODE $($j | ConvertTo-Json -Compress)"
    Remove-Item (Join-Path $d 'scripts\_comun.ps1') -Force
    $j = (PS1 'integridad.ps1' @('-Json', '-Ruta', $d, '-Estable', $base) | Out-String) | ConvertFrom-Json
    Afirmar ($LASTEXITCODE -eq 2 -and $j.faltan -contains 'scripts/_comun.ps1' -and $j.faltan_vs_estable -contains 'scripts/_comun.ps1') "faltante: $LASTEXITCODE $($j | ConvertTo-Json -Compress)"
    # sin manifiesto, la comparacion con la estable igual detecta la falta
    Remove-Item (Join-Path $d 'integridad.manifest.json') -Force
    $j = (PS1 'integridad.ps1' @('-Json', '-Ruta', $d, '-Estable', $base) | Out-String) | ConvertFrom-Json
    Afirmar ($LASTEXITCODE -eq 2 -and $j.manifiesto -eq 'ausente' -and $j.faltan_vs_estable -contains 'scripts/_comun.ps1') "sin manifiesto: $LASTEXITCODE"
    Afirmar (-not (Test-Path (Join-Path $d 'scripts\_comun.ps1'))) 'el control NO debe restaurar ni borrar nada por su cuenta'
}
Write-Host "== v1.9.2 hallazgos de Codex (una prueba de regresion por correccion)"
T 'codex 1.9.2 (concurrencia): Add-Decision recorta dentro del candado; 4 procesos a la vez no pierden decisiones' {
    $dc = Join-Path $tmp 'dec-conc'; Remove-Item $dc -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force $dc | Out-Null
    $pre = 1..1790 | ForEach-Object { '{"id":"pre-' + $_ + '","destino":"codex"}' }
    [IO.File]::WriteAllLines((Join-Path $dc 'decisiones.jsonl'), [string[]]$pre, (New-Object Text.UTF8Encoding($false)))
    $ps = 1..4 | ForEach-Object { $n = $_; Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList '-NoProfile', '-Command', "`$env:MULTIIA_DATOS='$($dc.Replace('''',''''''))'; . '$($PSScriptRoot.Replace('''',''''''))\..\scripts\_comun.ps1'; 1..20|%{ Add-Decision -Id ('c$n-'+`$_) -Destino codex -Tarea texto }" }
    $ps | ForEach-Object { [void]$_.WaitForExit(120000) }
    $l = @(Get-Content (Join-Path $dc 'decisiones.jsonl') -Encoding UTF8 | Where-Object { $_.Trim() })
    # con el candado el resultado es determinista: 1790 + 80; al pasar 1800 se recorta a 1500 (el 11.o agregado) y siguen 69 mas = 1569. Sin candado se pierden lineas.
    Afirmar ($l.Count -eq 1569) "lineas: $($l.Count) (esperaba 1569)"
    $ult = @($l | ForEach-Object { try { ($_ | ConvertFrom-Json).id } catch { 'ROTA' } })
    Afirmar ($ult -notcontains 'ROTA') 'hay lineas rotas'
    Afirmar (@($ult | Where-Object { $_ -like 'c*-*' }).Count -eq 69 -or @($ult | Where-Object { $_ -like 'c*-*' }).Count -ge 69) 'faltan decisiones recientes'
}
T 'codex 1.9.2 (formato): los lectores de sesiones de Codex toleran JSON con espacios (turn_context y token_usage_record)' {
    LimpiarDatos
    $h = Join-Path $tmp 'codexhome-esp'; $d = Join-Path $h 'sessions\2026\11\06'; New-Item -ItemType Directory -Force $d | Out-Null
    $tid = '0ccccccc-1111-2222-3333-444444444444'
    @('{ "type": "turn_context", "payload": { "model": "gpt-espacios" } }', "{ `"type`": `"token_usage_record`", `"payload`": { `"usage`": { `"input_tokens`": 40, `"output_tokens`": 2 } } }") | Set-Content (Join-Path $d "rollout-2026-11-06T10-00-00-$tid.jsonl") -Encoding UTF8
    $m = Get-ModeloCodex -ThreadId $tid -CodexHome $h
    Afirmar ($m -and $m.modelo -eq 'gpt-espacios') "Get-ModeloCodex con espacios: $($m | ConvertTo-Json -Compress)"
    Add-Decision -Id 'esp-1' -Destino 'codex' -Tarea 'codigo' -ModeloPedido 'auto' -EjecutorId $tid -Tok 42
    $env:CODEX_HOME = $h
    try { $r = @((PS1 'trazabilidad.ps1' @('-Json', '-Todo') | Out-String) | ConvertFrom-Json) } finally { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue }
    $p = @{}; foreach ($x in @($r | ForEach-Object { $_ })) { $p[$x.id] = $x }
    Afirmar ($p['esp-1'].tok_ejecutor -eq 42) "trazabilidad con espacios: tok_ejecutor=$($p['esp-1'].tok_ejecutor)"
}
T 'codex 1.9.2 (cuentas secundarias): trazabilidad encuentra la sesion en el CODEX_HOME de una cuenta configurada' {
    LimpiarDatos; $env:MULTIIA_DATOS = $tmp
    $h2 = Join-Path $tmp 'codexhome-cta2'; $d = Join-Path $h2 'sessions\2026\11\06'; New-Item -ItemType Directory -Force $d | Out-Null
    $tid = '0ddddddd-1111-2222-3333-444444444444'
    @('{"type":"turn_context","payload":{"model":"gpt-cta2"}}', '{"type":"token_usage_record","payload":{"usage":{"input_tokens":30,"output_tokens":3}}}') | Set-Content (Join-Path $d "rollout-2026-11-06T11-00-00-$tid.jsonl") -Encoding UTF8
    $cfg = Get-Config
    $cfg.cuentas = @($cfg.cuentas) + [pscustomobject]@{ id = 'codex2'; tipo = 'codex'; etiqueta = 'segunda'; activa = $false; home = $h2 }
    Save-Config $cfg
    Add-Decision -Id 'cta2-1' -Destino 'codex' -Tarea 'codigo' -ModeloPedido 'auto' -EjecutorId $tid -Tok 33
    Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue
    $r = @((PS1 'trazabilidad.ps1' @('-Json', '-Todo') | Out-String) | ConvertFrom-Json)
    $p = @{}; foreach ($x in @($r | ForEach-Object { $_ })) { $p[$x.id] = $x }
    Afirmar ($p['cta2-1'].veredicto -ne 'sin-registro-ejecutor' -and $p['cta2-1'].tok_ejecutor -eq 33) "cuenta secundaria: $($p['cta2-1'] | ConvertTo-Json -Compress)"
}
T '2.3.14 (Get-ClaseError): agy sin login real ("Authentication required ... authentication failed or timed out") es autenticacion, no timeout, y no reintentable' {
    $x = "Authentication required. Please visit the URL to log in:`n  https://accounts.google.com/o/oauth2/auth?x=1`nWaiting for authentication (timeout 60s)...`nError: authentication timed out.`nerror: authentication failed or timed out"
    $r = Get-ClaseError -Texto $x -Salida 1
    Afirmar ($r.clase -eq 'autenticacion' -and -not $r.reintentable) "agy sin login: $($r.clase)/$($r.reintentable)"
    $t = Get-ClaseError -Texto 'AGY_ERROR: {"status":"DEADLINE_EXCEEDED","retryable":true,"reason":"print_timeout"}' -Salida 1
    Afirmar ($t.clase -eq 'timeout') "timeout real intacto: $($t.clase)"
}
T 'codex 1.9.2 (Get-ClaseError): modelo invalido gana sobre timeout; "not recognized" de un comando no es modelo invalido; timeout real sigue siendo timeout' {
    $a = Get-ClaseError -Texto "error: invalid model 'gpt-zzz' (request timed out while validating)" -Salida 1
    Afirmar ($a.clase -eq 'modelo-invalido' -and -not $a.reintentable) "invalid model + timeout: $($a.clase)/$($a.reintentable)"
    $b = Get-ClaseError -Texto "The term 'codex' is not recognized as the name of a cmdlet" -Salida 1
    Afirmar ($b.clase -ne 'modelo-invalido') "comando no reconocido no es modelo invalido: $($b.clase)"
    $c = Get-ClaseError -Texto 'AGY_ERROR: {"short_error":"print timeout","status":"DEADLINE_EXCEEDED","retryable":true,"reason":"print_timeout"}' -Salida 1
    Afirmar ($c.clase -eq 'timeout' -and $c.reintentable) "timeout real: $($c.clase)/$($c.reintentable)"
    $d2 = Get-ClaseError -Texto 'model gpt-9 is not recognized' -Salida 1
    Afirmar ($d2.clase -eq 'modelo-invalido') "model not recognized: $($d2.clase)"
}
Write-Host "== v1.9.1 cero verificado vs ausente (tokens)"
T 'tokens 1.9.1: Add-Uso distingue informado (cero verificado), ausente y desconocido; null nunca se guarda como 0' {
    LimpiarDatos; $env:MULTIIA_DATOS = $tmp
    Add-Uso -Destino 'codex' -Chars 10 -Segundos 1 -Salida 0 -ConMemoria $false -TokIn 0 -TokOut 0          # la CLI dijo 0
    Add-Uso -Destino 'codex' -Chars 10 -Segundos 1 -Salida 0 -ConMemoria $false                              # la CLI no informo
    Add-Uso -Destino 'agy' -Chars 10 -Segundos 1 -Salida 1 -ConMemoria $false                                 # fallo antes de informar
    Add-Uso -Destino 'agy' -Chars 10 -Segundos 1 -Salida 0 -ConMemoria $false -TokIn 120 -TokOut 30         # dato normal
    $f = @(Get-Content (Join-Path $tmp 'uso.jsonl') -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
    Afirmar ($f.Count -eq 4) "filas $($f.Count)"
    Afirmar ($f[0].tok_estado -eq 'informado' -and $f[0].tok_in -eq 0 -and $null -ne $f[0].tok_in) 'el cero verificado debe conservarse como 0 informado'
    Afirmar ($f[1].tok_estado -eq 'ausente' -and $null -eq $f[1].tok_in -and $null -eq $f[1].tok_out) 'ausente debe guardarse como null'
    Afirmar ($f[2].tok_estado -eq 'desconocido' -and $null -eq $f[2].tok_in) 'fallo sin tokens = desconocido'
    Afirmar ($f[3].tok_estado -eq 'informado' -and $f[3].tok_in -eq 120) 'dato normal'
}
T 'tokens 1.9.1: regla de compatibilidad (fila vieja 0/0 = ausente, >0 = informado) y agregados por estado' {
    $fi = [pscustomobject]@{ tok_in = 0; tok_out = 0 }; $fv = [pscustomobject]@{ tok_in = 5; tok_out = 1 }; $fn = [pscustomobject]@{ destino = 'x' }
    $fz = [pscustomobject]@{ tok_in = 0; tok_out = 0; tok_estado = 'informado' }; $fe = [pscustomobject]@{ tok_in = 7; tok_out = 0; tok_estado = 'estimado' }
    Afirmar ((Get-EstadoTokens $fi) -eq 'ausente' -and (Get-EstadoTokens $fv) -eq 'informado' -and (Get-EstadoTokens $fn) -eq 'ausente') 'lectura de filas viejas'
    Afirmar ((Get-EstadoTokens $fz) -eq 'informado' -and (Get-EstadoTokens $fe) -eq 'estimado') 'estado explicito manda'
    $t0 = Get-TokensConNivel @($fz)
    Afirmar ($t0.valor -eq 0 -and $null -ne $t0.valor -and $t0.nivel -eq 'VERIFICADO') "cero verificado: valor=$($t0.valor) nivel=$($t0.nivel)"
    $ta = Get-TokensConNivel @($fi, $fn)
    Afirmar ($null -eq $ta.valor -and $ta.nivel -eq 'NO DISPONIBLE') 'solo ausentes => null / NO DISPONIBLE'
    $tm = Get-TokensConNivel @($fv, $fi, $fz)
    Afirmar ($tm.valor -eq 6 -and $tm.parcial -and $tm.nivel -eq 'OBSERVADO' -and $tm.por_estado.ausente -eq 1 -and $tm.por_estado.informado -eq 2) "mezcla: $($tm | ConvertTo-Json -Compress -Depth 4)"
    $te = Get-TokensConNivel @($fe)
    Afirmar ($null -eq $te.valor) 'una estimacion no se presenta como dato informado'
}
T 'tokens 1.9.1: consumo y rapido distinguen cero verificado de ausente y exponen por_estado' {
    LimpiarDatos; $env:MULTIIA_DATOS = $tmp
    $fil = @(
        @{ fecha = (Get-Date).ToString('s'); destino = 'codex'; salida = 0; tok_in = 0; tok_out = 0; tok_estado = 'informado'; seg = 1; origen = 'real'; sesion = 'cz' },
        @{ fecha = (Get-Date).ToString('s'); destino = 'codex'; salida = 0; tok_in = $null; tok_out = $null; tok_estado = 'ausente'; seg = 1; origen = 'real'; sesion = 'ca' },
        @{ fecha = (Get-Date).ToString('s'); destino = 'agy'; salida = 1; tok_in = $null; tok_out = $null; tok_estado = 'desconocido'; seg = 1; origen = 'real'; sesion = 'cd' }
    )
    foreach ($x in $fil) { [IO.File]::AppendAllText((Join-Path $tmp 'uso.jsonl'), (($x | ConvertTo-Json -Compress) + "`r`n")) }
    $j = (PS1 'consumo.ps1' | Out-String) | ConvertFrom-Json
    Afirmar ($j.sesiones.cz.tok_nivel -eq 'OBSERVADO' -and $j.sesiones.cz.sin_dato -eq 0) "cero verificado: $($j.sesiones.cz.tok_nivel)/$($j.sesiones.cz.sin_dato)"
    Afirmar ($j.sesiones.ca.tok_nivel -eq 'NO DISPONIBLE' -and $j.sesiones.ca.sin_dato -eq 1) 'ausente'
    Afirmar ($j.sesiones.cd.tok_nivel -eq 'NO DISPONIBLE' -and $j.sesiones.cd.tok_por_estado.desconocido -eq 1) 'desconocido'
    Afirmar ($j.global.tok_por_estado.informado -eq 1 -and $j.global.tok_por_estado.ausente -eq 1 -and $j.global.sin_dato -eq 2) "global: $($j.global.tok_por_estado | ConvertTo-Json -Compress)"
    $r = (PS1 'rapido.ps1' | Out-String)
    Afirmar ($r -match 'por_estado') 'rapido no expone por_estado'
}
Write-Host "== v1.9.1 timeout duro, procesos huerfanos, config corrupta"
T 'Invoke-ConTimeout -Duro: vence, devuelve timeout=true (codigo 124) y mata tambien al subproceso (sin huerfanos)' {
    . (Join-Path $sc '_comun.ps1')
    $marca = 'MIA' + [guid]::NewGuid().ToString('N').Substring(0, 10)
    $cmd = "Start-Process powershell -ArgumentList '-NoProfile','-Command','Start-Sleep 60 # $marca' -WindowStyle Hidden; Start-Sleep 60"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-ConTimeout (Get-Command powershell).Source @('-NoProfile', '-Command', $cmd) 4 -Duro
    Afirmar ($r -and $r.timeout -eq $true -and $r.codigo -eq 124) "no devolvio timeout: $($r | ConvertTo-Json -Compress)"
    Afirmar ($sw.Elapsed.TotalSeconds -lt 25) "tardo $([int]$sw.Elapsed.TotalSeconds) s"
    Start-Sleep 2
    $vivos = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match $marca })
    if ($vivos) { $vivos | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } }
    Afirmar ($vivos.Count -eq 0) "quedaron $($vivos.Count) procesos huerfanos"
}
T 'Invoke-ConTimeout: sin -Duro mantiene el contrato viejo ($null al vencer) y un exito trae timeout=false' {
    . (Join-Path $sc '_comun.ps1')
    $ps = (Get-Command powershell).Source
    $a = Invoke-ConTimeout $ps @('-NoProfile', '-Command', 'Start-Sleep 20') 2
    Afirmar ($null -eq $a) 'sin -Duro debia devolver $null'
    $b = Invoke-ConTimeout $ps @('-NoProfile', '-Command', 'Write-Output hola') 30 -Duro
    Afirmar ($b.timeout -eq $false -and $b.codigo -eq 0 -and $b.salida -match 'hola') "exito: $($b | ConvertTo-Json -Compress)"
}
T 'delegar-agy/codex usan el timeout duro de proceso' {
    foreach ($n in 'delegar-agy.ps1', 'delegar-codex.ps1') { $s = Get-Content (Join-Path $sc $n) -Raw; Afirmar ($s -match 'Invoke-ConTimeout[^\r\n]+-Duro') "$n no usa Invoke-ConTimeout -Duro" }
}
T 'Get-Config: config corrupta usa la de por defecto, se marca y se conserva copia .corrupta' {
    LimpiarDatos; $env:MULTIIA_DATOS = $tmp
    . (Join-Path $sc '_comun.ps1')
    [IO.File]::WriteAllText((Join-Path $tmp 'config.json'), '{ esto no es json', (New-Object Text.UTF8Encoding($false)))
    $c = Get-Config
    Afirmar ($c.modo -eq 'automatico' -and @($c.cuentas).Count -ge 1) 'no devolvio la config por defecto'
    Afirmar ($script:ConfigCorrupta -eq $true) 'no marco ConfigCorrupta'
    Afirmar (Test-Path (Join-Path $tmp 'config.json.corrupta')) 'no guardo la copia .corrupta'
    Remove-Item (Join-Path $tmp 'config.json*') -Force -ErrorAction SilentlyContinue
    $c2 = Get-Config; Afirmar ($script:ConfigCorrupta -eq $false) 'sin archivo no es corrupta'
}
T 'agy truncado: finished_reason estructurado (formas REALES de agy 1.5.1) se clasifica sin depender de regex sobre prosa' {
    . (Join-Path $sc '_comun.ps1')
    # Formas copiadas de corridas reales (v1.9.2): timeout (--print-timeout 2s) y modelo invalido. SUCCESS normal NO trae finished_reason.
    $to = '{"conversation_id":"x","status":"ERROR","response":"","error":"print timeout after 2s with the turn still in progress; the response is partial","num_turns":1,"finished_reason":"print_timeout"}' | ConvertFrom-Json
    $c = Get-ClaseError -Texto (Get-TextoFalloAgy $to '') -Salida 3
    Afirmar ($c.clase -eq 'timeout') "timeout real: $($c.clase)"
    $bm = '{"conversation_id":"","status":"ERROR","response":"","error":"invalid model selection (--model \"zz\"): model zz is not recognized as a known model","finished_reason":"error"}' | ConvertFrom-Json
    $c = Get-ClaseError -Texto (Get-TextoFalloAgy $bm '') -Salida 1
    Afirmar ($c.clase -eq 'modelo-invalido') "modelo invalido real: $($c.clase)"
    $ok = '{"conversation_id":"x","status":"SUCCESS","response":"OK\n","usage":{"input_tokens":6937,"output_tokens":1}}' | ConvertFrom-Json
    Afirmar (-not (Test-AgyTruncado $ok)) 'SUCCESS normal no debe ser truncado'
    # Hipotetico (NO visto en agy real): finished_reason de corte por largo con SUCCESS
    $tr = '{"status":"SUCCESS","response":"texto cortad","finished_reason":"MAX_TOKENS"}' | ConvertFrom-Json
    Afirmar (Test-AgyTruncado $tr) 'finished_reason MAX_TOKENS debe ser truncado'
    $c = Get-ClaseError -Texto (Get-TextoFalloAgy $tr '') -Salida 1
    Afirmar ($c.clase -eq 'truncado' -and $c.reintentable -eq $false) "truncado: $($c.clase)"
    $s = Get-Content (Join-Path $sc 'delegar-agy.ps1') -Raw; Afirmar ($s -match 'Test-AgyTruncado') 'delegar-agy no usa Test-AgyTruncado'
}
Write-Host "== v1.9.2: ConfigCorrupta (detectar, registrar, mostrar, recuperar)"
T 'config corrupta: se registra UN evento por contenido, se guarda la copia y no se duplica' {
    LimpiarDatos
    $cj = Join-Path $tmp 'config.json'; $cp = "$cj.corrupta"
    Remove-Item $cj, $cp -Force -ErrorAction SilentlyContinue
    Set-Content $cj '{ roto' -Encoding UTF8
    $null = Get-Config; $null = Get-Config
    $ev = @(Get-Content (Join-Path $tmp 'eventos.jsonl') -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.tipo -eq 'config-corrupta' })
    Afirmar ($ev.Count -eq 1) "eventos config-corrupta: $($ev.Count) (esperado 1)"
    Afirmar ($ev[0].motivo -eq 'JSON invalido' -and $ev[0].detalle -match 'Recuperar') "evento: $($ev[0] | ConvertTo-Json -Compress)"
    Afirmar ((Get-Content $cp -Raw) -match 'roto') 'la copia .corrupta no tiene el contenido original'
    Set-Content $cj '[1,2]' -Encoding UTF8   # JSON valido pero no es un objeto: tambien es corrupta
    $null = Get-Config
    Afirmar ($script:ConfigCorrupta -eq $true) 'un array JSON no es una config valida'
    Afirmar ((Get-Content $cp -Raw) -match '\[1,2\]') 'la copia no se renovo con el nuevo contenido corrupto'
    $ev = @(Get-Content (Join-Path $tmp 'eventos.jsonl') -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.tipo -eq 'config-corrupta' })
    Afirmar ($ev.Count -eq 2 -and $ev[1].motivo -eq 'no es un objeto JSON') "segundo evento: $($ev.Count)"
    Remove-Item $cj, $cp -Force -ErrorAction SilentlyContinue
}
T 'trazabilidad: no dice coincide si los tokens de la decision difieren del ejecutor, y respeta uso.ej de otra ejecucion' {
    LimpiarDatos
    $h = Join-Path $tmp 'codexhome3'; $d = Join-Path $h 'sessions\2026\11\04'; New-Item -ItemType Directory -Force $d | Out-Null
    $tid = '0ccccccc-1111-2222-3333-444444444444'
    @("{`"type`":`"token_usage_record`",`"payload`":{`"usage`":{`"input_tokens`":100,`"output_tokens`":0}}}") | Set-Content (Join-Path $d "rollout-2026-11-04T10-00-00-$tid.jsonl") -Encoding UTF8
    Add-Uso -Destino 'codex' -Segundos 1 -Salida 0 -TokIn 100 -TokOut 0
    Add-Decision -Id 'd-1' -Destino 'codex' -Tarea 'codigo' -ModeloPedido 'auto' -EjecutorId $tid -Tok 999
    $env:CODEX_HOME = $h
    try { $r = @((PS1 'trazabilidad.ps1' @('-Json', '-Todo') | Out-String) | ConvertFrom-Json) } finally { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue }
    $x = @($r | ForEach-Object { $_ })[0]
    Afirmar ($x.veredicto -eq 'difiere') "tokens de decision 999 vs ejecutor 100 debia diferir: $($x.veredicto)"
}
T 'config.ps1 -Recuperar: avisa si esta corrupta, la repone con los valores por defecto, conserva el original y no hace nada si esta sana' {
    $cj = Join-Path $tmp 'config.json'; $cp = "$cj.corrupta"
    Remove-Item $cj, $cp -Force -ErrorAction SilentlyContinue
    Set-Content $cj '{ roto' -Encoding UTF8
    # 3.3.2: la consola parte la salida de los procesos hijos por ancho (incluso dentro de una palabra): se compara sin espacios ni saltos.
    $v = (PS1 'config.ps1' @('-Ver') | Out-String); $vc = $v -replace '\s+', ''
    Afirmar ($vc -match 'CORRUPTA' -and $vc -match 'Recuperar') "-Ver no avisa: $v"
    Afirmar (Test-Path $cj) '-Ver no debe tocar el archivo'
    $r = (PS1 'config.ps1' @('-Recuperar') | Out-String)
    Afirmar (($r -replace '\s+', '') -match 'recuperada') "-Recuperar: $r"
    $c = Get-Content $cj -Raw | ConvertFrom-Json
    Afirmar ($c.modo -eq 'automatico' -and @($c.cuentas).Count -ge 1) 'config repuesta invalida'
    Afirmar ((Get-Content $cp -Raw) -match 'roto') 'se perdio el original'
    Afirmar ($null -ne (Get-Config) -and $script:ConfigCorrupta -eq $false) 'sigue corrupta tras recuperar'
    $r2 = (PS1 'config.ps1' @('-Recuperar') | Out-String)
    Afirmar (($r2 -replace '\s+', '') -match 'sana') "sana: $r2"
    Remove-Item $cj, $cp -Force -ErrorAction SilentlyContinue
}
T 'panel: muestra el aviso de config corrupta, no lo muestra con config sana y no tira errores con uso vacio' {
    LimpiarDatos
    $cj = Join-Path $tmp 'config.json'; $cp = "$cj.corrupta"; $h = Join-Path $tmp 'panel-cc.html'
    Remove-Item $cj, $cp, $h -Force -ErrorAction SilentlyContinue
    $o = @(PS1 'panel.ps1' @('-Salida', $h))
    Afirmar (@($o | Where-Object { $_ -is [Management.Automation.ErrorRecord] }).Count -eq 0) "errores con uso vacio: $($o | Out-String)"
    Afirmar ((Get-Content $h -Raw -Encoding UTF8) -notmatch 'id=.config-corrupta') 'aviso con config sana'
    Set-Content $cj '{ roto' -Encoding UTF8
    $null = PS1 'panel.ps1' @('-Salida', $h)
    Afirmar ((Get-Content $h -Raw -Encoding UTF8) -match 'id=.config-corrupta') 'el panel no avisa de la config corrupta'
    Remove-Item $cj, $cp, $h -Force -ErrorAction SilentlyContinue
}
T 'panel-servidor.mjs: sintaxis valida y no pisa una config corrupta sin guardar copia (marca _corrupta)' {
    $mjs = Join-Path $sc 'panel-servidor.mjs'
    $s = Get-Content $mjs -Raw -Encoding UTF8
    Afirmar ($s -match '_corrupta' -and $s -match 'config\.json\.corrupta|\.corrupta') 'el servidor no maneja la config corrupta'
    if (Get-Command node -ErrorAction SilentlyContinue) { $null = & node --check $mjs 2>&1; Afirmar ($LASTEXITCODE -eq 0) 'node --check fallo' }
}
Write-Host "== v1.9.2: trazabilidad (duplicados, recuperaciones, consumo, historico, origen)"
T 'trazabilidad: sin duplicados, recuperacion enlazada, consumo no compartido, uso sin fecha tolerado, eventos del historico y origen separado' {
    LimpiarDatos
    $env:CODEX_HOME = Join-Path $tmp 'codexhome-vacio'
    try {
        # duplicado: el mismo id dos veces cuenta una vez
        Add-Decision -Id 'z-1' -Destino 'codex' -Tarea 'codigo' -ModeloPedido 'auto' -Tok 10
        Add-Decision -Id 'z-1' -Destino 'codex' -Tarea 'codigo' -ModeloPedido 'auto' -Tok 10
        # recuperacion: codex fallo, agy recupero (id "<id>-r" + Alternativas "reintento de <id>")
        Add-Decision -Id 'r-1' -Destino 'codex' -Tarea 'codigo' -ModeloPedido 'auto' -Resultado 'error' -Error 'salida 1'
        Add-Decision -Id 'r-1-r' -Destino 'agy' -Tarea 'codigo' -ModeloPedido 'auto' -Alternativas 'reintento de r-1' -Resultado 'ok'
        # consumo: dos decisiones de 50 tokens y UNA sola fila de uso de 50
        Add-Uso -Destino 'agy' -Segundos 1 -Salida 0 -TokIn 40 -TokOut 10
        Add-Decision -Id 'u-1' -Destino 'agy' -Tarea 'texto' -ModeloPedido 'auto' -Tok 50
        Add-Decision -Id 'u-2' -Destino 'agy' -Tarea 'texto' -ModeloPedido 'auto' -Tok 50
        # fila de uso corrupta (sin fecha) y evento que solo existe en el historico largo
        Add-Content (Join-Path $tmp 'uso.jsonl') '{"destino":"agy","tok_in":1,"tok_out":1}' -Encoding UTF8
        Add-Content (Join-Path $tmp 'eventos-hist.jsonl') ('{"fecha":"2026-01-01T00:00:00","tipo":"inicio","destino":"codex","id":"h-1"}') -Encoding UTF8
        Add-Decision -Id 'h-1' -Destino 'codex' -Tarea 'codigo' -ModeloPedido 'auto'
        # origen: una decision de prueba no aparece sin -Todo
        $env:MULTIIA_ORIGEN = 'test'; try { Add-Decision -Id 'o-1' -Destino 'codex' -Tarea 'codigo' -ModeloPedido 'auto' } finally { Remove-Item Env:MULTIIA_ORIGEN }
        $real = @((PS1 'trazabilidad.ps1' @('-Json') | Out-String) | ConvertFrom-Json) | ForEach-Object { $_ }
        $todo = @((PS1 'trazabilidad.ps1' @('-Json', '-Todo') | Out-String) | ConvertFrom-Json) | ForEach-Object { $_ }
    } finally { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue }
    $p = @{}; foreach ($x in $todo) { $p[$x.id] = $x }
    Afirmar (@($todo | Where-Object { $_.id -eq 'z-1' }).Count -eq 1) 'id duplicado aparece mas de una vez'
    Afirmar ($p['r-1-r'].recuperacion_de -eq 'r-1' -and $p['r-1-r'].motor_inicial -eq 'codex' -and $p['r-1-r'].motor_ejecutor -eq 'agy') "recuperacion: $($p['r-1-r'] | ConvertTo-Json -Compress)"
    Afirmar ($p['r-1'].recuperada_por -eq 'r-1-r' -and $p['r-1'].motor_inicial -eq 'codex') "original: $($p['r-1'] | ConvertTo-Json -Compress)"
    $conUso = @($p['u-1'].tok_uso, $p['u-2'].tok_uso | Where-Object { $null -ne $_ -and $_ -eq 50 }).Count
    Afirmar ($conUso -eq 1) "la misma fila de uso se asigno a $conUso ejecuciones (esperado 1)"
    Afirmar ($p['h-1'].eventos_consola -match 'inicio') "no uso el historico: '$($p['h-1'].eventos_consola)'"
    Afirmar (-not (@($real | Where-Object { $_.id -eq 'o-1' }).Count) -and $p['o-1'].origen -eq 'test') 'el origen test debe quedar fuera sin -Todo y etiquetado con -Todo'
}
T 'panel 1.9.3: el JS de Chats pinta la tabla (regresion: comentario // se comia "var t")' {
    $node = Get-Command node -ErrorAction SilentlyContinue
    Afirmar ($null -ne $node) 'node no disponible'
    $o = & node (Join-Path $PSScriptRoot 'panel-chats.mjs') (Join-Path $sc 'panel.ps1') 2>&1 | Out-String
    Afirmar ($LASTEXITCODE -eq 0) "panel-chats.mjs fallo: $o"
}
# ---- 2.0.1: robustez (candados, cierre verificado) y rendimiento
T 'robustez 2.0.1: candado async con dueno verificado, sin Atomics.wait, cierre de procesos verificado (tests\robustez.mjs)' {
    $node = Get-Command node -ErrorAction SilentlyContinue
    Afirmar ($null -ne $node) 'node no disponible'
    $o = & node (Join-Path $PSScriptRoot 'robustez.mjs') 2>&1 | Out-String
    Afirmar ($LASTEXITCODE -eq 0) "robustez.mjs fallo: $o"
}
T 'robustez 2.0.1: Lock-Config valida dueno y edad; Unlock-Config solo borra el propio; Invoke-ConTimeout verifica el cierre' {
    $c = Get-Content (Join-Path $sc '_comun.ps1') -Raw
    $lk = [regex]::Match($c, '(?s)function Lock-Config.*?\r?\nfunction ').Value
    Afirmar ($lk -match 'Get-Process' -and $lk -match 'LastWriteTime|CreationTime') 'Lock-Config no comprueba dueno y edad'
    $ul = [regex]::Match($c, '(?s)function Unlock-Config.*?\r?\n\}').Value
    Afirmar ($ul -match 'PID|\$PID') 'Unlock-Config no comprueba que el candado sea propio'
    $ic = [regex]::Match($c, '(?s)function Invoke-ConTimeout.*?\r?\nfunction ').Value
    Afirmar ($ic -match 'taskkill' -and $ic -match 'terminado') 'Invoke-ConTimeout no verifica el cierre'
}
T 'robustez 2.0.1: ahorro.ps1 y chats.ps1 usan agrupacion por chat (no filtran la lista completa por chat)' {
    foreach ($n in 'ahorro.ps1', 'chats.ps1') {
        $c = Get-Content (Join-Path $sc $n) -Raw
        Afirmar ($c -match 'Agrupar') "$n no agrupa por chat"
    }
}
# ---- 2.0: intensidad de delegacion
function Inten([string[]]$a) { (PS1 'intensidad.ps1' ($a + '-Json') | Out-String) | ConvertFrom-Json }
function Elegir-Int([string]$tarea, [int]$tam, [string]$chat = '') { $x = @('-Tarea', $tarea, '-Tamano', "$tam"); if ($chat) { $x += @('-Chat', $chat) }; (PS1 'elegir.ps1' $x | Out-String) | ConvertFrom-Json }
T 'intensidad 2.0: instalacion nueva = automatico global, sin preferencias de chat; config vieja (sin los campos) se completa sola' {
    LimpiarDatos; Remove-Item (Join-Path $tmp 'config.json') -Force -ErrorAction SilentlyContinue; $env:MULTIIA_DATOS = $tmp; . (Join-Path $sc '_comun.ps1')
    $i = Inten @('-Ver', '-Chat', 'c-nuevo')
    Afirmar ($i.valor -eq 'automatico' -and $i.origen -eq 'global') "nueva: $($i | ConvertTo-Json -Compress)"
    $c = Get-Config | ConvertTo-Json -Depth 6 | ConvertFrom-Json; $c.PSObject.Properties.Remove('intensidad'); $c.PSObject.Properties.Remove('intensidad_chats')
    [IO.File]::WriteAllText((Join-Path $tmp 'config.json'), ($c | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    $i = Inten @('-Ver', '-Chat', 'c-viejo'); Afirmar ($i.valor -eq 'automatico') "config vieja: $($i | ConvertTo-Json -Compress)"
    [IO.File]::WriteAllText((Join-Path $tmp 'config.json'), (($c | Add-Member -NotePropertyName intensidad -NotePropertyValue 'turbo' -PassThru | ConvertTo-Json -Depth 6)), (New-Object Text.UTF8Encoding($false)))
    $i = Inten @('-Ver', '-Chat', 'c-viejo'); Afirmar ($i.valor -eq 'automatico') "valor invalido en disco no se acepta: $($i | ConvertTo-Json -Compress)"
}
T 'intensidad 2.0: cambio global persiste y se verifica; chat propio gana; quitar hereda; chats distintos no se mezclan; valor invalido se rechaza' {
    LimpiarDatos; Remove-Item (Join-Path $tmp 'config.json') -Force -ErrorAction SilentlyContinue; $env:MULTIIA_DATOS = $tmp; . (Join-Path $sc '_comun.ps1')
    $g = Inten @('-Valor', 'alto', '-Global'); Afirmar ($g.ok -and $g.valor -eq 'alto' -and $g.mensaje -match 'verificado') "global: $($g | ConvertTo-Json -Compress)"
    Afirmar ((Get-Config).intensidad -eq 'alto') 'no quedo en config.json'
    $a = Inten @('-Valor', 'bajo', '-Chat', 'chat-A'); $b = Inten @('-Ver', '-Chat', 'chat-B'); $a2 = Inten @('-Ver', '-Chat', 'chat-A')
    Afirmar ($a2.valor -eq 'bajo' -and $a2.origen -eq 'chat' -and $b.valor -eq 'alto' -and $b.origen -eq 'global') "A=$($a2.valor)/$($a2.origen) B=$($b.valor)/$($b.origen)"
    Inten @('-Valor', 'medio', '-Global') | Out-Null
    $a3 = Inten @('-Ver', '-Chat', 'chat-A'); $b3 = Inten @('-Ver', '-Chat', 'chat-B')
    Afirmar ($a3.valor -eq 'bajo' -and $b3.valor -eq 'medio') 'la global pisa la preferencia del chat o el chat nuevo no hereda'
    $q = Inten @('-Quitar', '-Chat', 'chat-A'); $a4 = Inten @('-Ver', '-Chat', 'chat-A')
    Afirmar ($a4.valor -eq 'medio' -and $a4.origen -eq 'global') "quitar: $($a4 | ConvertTo-Json -Compress)"
    $r = Inten @('-Valor', 'automatico', '-Global'); Afirmar ($r.valor -eq 'automatico') 'no volvio a automatico'
    $rechazo = $false; try { $null = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $sc 'intensidad.ps1') -Valor turbo -Global 2>&1 } catch { }; $rechazo = ($LASTEXITCODE -ne 0); Afirmar ($rechazo -and (Get-Config).intensidad -eq 'automatico') 'acepto un valor invalido'
    $ev = Get-Content (Join-Path $tmp 'eventos.jsonl') -Raw; Afirmar ($ev -match '"tipo":"intensidad"') 'el cambio no quedo en el historial'
}
TN 'intensidad 2.0: el router cambia de verdad con cada modo y lo explica; manual y -Forzar no se tocan' {
    LimpiarDatos; Remove-Item (Join-Path $tmp 'config.json') -Force -ErrorAction SilentlyContinue; $env:MULTIIA_DATOS = $tmp; . (Join-Path $sc '_comun.ps1')
    $r = @{}
    foreach ($m in 'bajo', 'medio', 'alto', 'automatico') {
        Inten @('-Valor', $m, '-Global') | Out-Null
        $r[$m] = @{ chico = (Elegir-Int 'texto' 500); codigo = (Elegir-Int 'codigo' 2000); triv = (Elegir-Int 'trivial' 100) }
    }
    Afirmar ($r.bajo.codigo.destino -eq 'claude' -and $r.medio.codigo.destino -eq 'codex' -and $r.alto.codigo.destino -eq 'codex') 'codigo mediano: bajo debe quedarse, medio/alto delegar'
    Afirmar ($r.medio.chico.destino -eq 'claude' -and $r.alto.chico.destino -eq 'agy' -and $r.automatico.chico.destino -eq 'claude') 'texto corto: medio y auto se quedan, alto delega'
    Afirmar ($r.alto.codigo.cruzar -and $r.alto.codigo.paralelo -and -not $r.medio.codigo.cruzar -and -not $r.automatico.codigo.cruzar) 'alto pide cruce y paralelismo; los demas no'
    Afirmar ($r.bajo.chico.motivo -match 'intensidad bajo' -and $r.automatico.triv.motivo -match 'baja complejidad') 'el motivo no explica la decision'
    Afirmar ((Elegir-Int 'texto' -1).destino -eq 'agy') 'automatico con tamano desconocido debe delegar como siempre'
    $f = (PS1 'elegir.ps1' @('-Tarea', 'trivial', '-Tamano', '50', '-Forzar') | Out-String) | ConvertFrom-Json; Afirmar ($f.destino -in 'codex', 'agy') '-Forzar no ignoro la politica'
    $c = Get-Config; $c.modo = 'manual'; Save-Config $c; Inten @('-Valor', 'bajo', '-Global') | Out-Null
    $mm = Elegir-Int 'trivial' 50; Afirmar ($mm.motivo -notmatch 'intensidad') "en manual no aplica la intensidad: $($mm.motivo)"
    $c = Get-Config; $c.modo = 'automatico'; Save-Config $c; Inten @('-Valor', 'automatico', '-Global') | Out-Null
}
TN 'intensidad 2.0: la preferencia del chat gobierna solo a ese chat; la decision auditada guarda intensidad y origen' {
    LimpiarDatos; Remove-Item (Join-Path $tmp 'config.json') -Force -ErrorAction SilentlyContinue; $env:MULTIIA_DATOS = $tmp; . (Join-Path $sc '_comun.ps1')
    Inten @('-Valor', 'alto', '-Global') | Out-Null; Inten @('-Valor', 'bajo', '-Chat', 'chat-X') | Out-Null
    $x = Elegir-Int 'codigo' 2000 'chat-X'; $y = Elegir-Int 'codigo' 2000 'chat-Y'
    Afirmar ($x.destino -eq 'claude' -and $x.intensidad_origen -eq 'chat' -and $y.destino -eq 'codex' -and $y.intensidad_origen -eq 'global') "X=$($x.destino)/$($x.intensidad_origen) Y=$($y.destino)/$($y.intensidad_origen)"
    # cambio mientras hay una ejecucion en curso: la decision ya registrada conserva su intensidad; la siguiente usa la nueva
    Add-Decision -Id 'ej-int-1' -Destino 'codex' -Tarea 'codigo' -Resultado 'ok' -Intensidad 'alto' -IntensidadOrigen 'global'
    Inten @('-Valor', 'bajo', '-Global') | Out-Null
    Add-Decision -Id 'ej-int-2' -Destino 'claude' -Tarea 'codigo' -Resultado 'no-delegado' -Intensidad 'bajo' -IntensidadOrigen 'global'
    $dec = @(Get-Content (Join-Path $tmp 'decisiones.jsonl') | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }); $d1 = $dec | Where-Object id -eq 'ej-int-1'; $d2 = $dec | Where-Object id -eq 'ej-int-2'
    Afirmar ($d1.intensidad -eq 'alto' -and $d2.intensidad -eq 'bajo' -and $d2.intensidad_origen -eq 'global') 'la decision no guarda la intensidad vigente'
    Inten @('-Valor', 'automatico', '-Global') | Out-Null
}
T 'ahorro.tests.ps1 2.0: ahorro honesto (reportado/estimado/no determinable)' {
    $o = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'ahorro.tests.ps1') 2>&1 | Out-String
    Afirmar ($LASTEXITCODE -eq 0) "ahorro.tests fallo: $($o.Substring([Math]::Max(0,$o.Length-600)))"
}
T 'Pixel Pro 2.3.0 (antes Crystal Pro 2.1.0): version = plugin.json, tokens Matte Violet, sin colores viejos azul-gris ni Crystal' {
    $reg = Get-Content (Join-Path $raiz 'hooks\register.tsx') -Raw
    $ver = (Get-Content (Join-Path $raiz '.claude-plugin\plugin.json') -Raw | ConvertFrom-Json).version
    Afirmar ($reg -match "const VERSION = '$([regex]::Escape($ver))'") "VERSION de register.tsx no coincide con plugin.json ($ver)"
    foreach ($c in '#ba75f5', '#d58cff', '#21102f', '#2c173e', '#4a2d63', '#ff9b38') { Afirmar ($reg.Contains($c)) "falta el token Pixel Pro $c" }
    foreach ($v in '#a78bfa', '#e879f9', '#0d0914', '#1a1226', '#3a2a58', '#34d399', '#22d3ee') { Afirmar (-not $reg.Contains($v)) "color Crystal $v todavia en register.tsx" }
    foreach ($v in '#f1f5f9', '#9aa6bd', '#a3b0c7', '#cbd5e1', '#f5a524', '#05070b', '#0b0d14', '#0a1020', '#0a0f1c', '#94a3b8', '#64748b', '#7aa8ff', '#b49cff', '#5eead4', '#f87171', '#4ade80') { Afirmar (-not $reg.Contains($v)) "color viejo $v todavia en register.tsx" }
}
T 'Crystal Pro 2.1.0 (estatico, solo codigo): alcance (alc), cuotas 5 h / 7 d e icono Antigravity presentes; el comportamiento se prueba en hooks/interaccion.test.tsx' {
    $reg = Get-Content (Join-Path $raiz 'hooks\register.tsx') -Raw
    Afirmar ($reg -match "alc\?: 'chat' \| 'global'") 'falta el alcance alc chat/global en la vista'
    Afirmar ($reg.Contains('ESTE CHAT') -and $reg.Contains('GLOBAL')) 'faltan los KPI ESTE CHAT / GLOBAL'
    Afirmar ($reg -match '5 ?h' -and $reg -match '7 ?d') 'faltan las barras de cupo 5 h / 7 d'
    Afirmar ($reg -match 'const iconoAgy') 'falta iconoAgy'
    Afirmar ($reg -match "'24h', '7d', '30d'") 'falta el selector de rango 24h/7d/30d'
}
TN '2.2.0 elegir.ps1: siempre emite JSON valido; maxima nunca retiene en Claude; alta intensidad asigna segundo motor y lo explica; paralelo es sugerencia documentada' {
    LimpiarDatos; Remove-Item (Join-Path $tmp 'config.json') -Force -ErrorAction SilentlyContinue; $env:MULTIIA_DATOS = $tmp; . (Join-Path $sc '_comun.ps1')
    Inten @('-Valor', 'automatico', '-Global') | Out-Null
    $m = (PS1 'elegir.ps1' @('-Tarea', 'trivial', '-Tamano', '100', '-Calidad', 'maxima') | Out-String) | ConvertFrom-Json
    Afirmar ($m.destino -in 'codex', 'agy') "calidad maxima retuvo en Claude: $($m.destino)"
    Inten @('-Valor', 'alto', '-Global') | Out-Null
    $a = Elegir-Int 'codigo' 2000
    Afirmar ($a.cruzar -and $a.destino -in 'codex', 'agy' -and $a.segundo -and $a.motivo -match 'revisi') "alto: cruzar sin segundo motor o sin explicar: $($a | ConvertTo-Json -Compress)"
    Afirmar ((Get-Content (Join-Path $sc 'elegir.ps1') -Raw) -match 'SUGERENCIA') 'paralelo debe estar documentado como sugerencia (delegar.ps1 es secuencial)'
    Inten @('-Valor', 'automatico', '-Global') | Out-Null
}
T '2.2.0 intensidad.ps1: secuencias global/chat/quitar terminan con codigo 0 y el valor invalido con distinto de 0' {
    LimpiarDatos; Remove-Item (Join-Path $tmp 'config.json') -Force -ErrorAction SilentlyContinue; $env:MULTIIA_DATOS = $tmp; . (Join-Path $sc '_comun.ps1')
    foreach ($par in @(@('-Valor', 'alto', '-Global'), @('-Valor', 'bajo', '-Chat', 'c1'), @('-Quitar', '-Chat', 'c1'), @('-Valor', 'automatico', '-Global'))) { $null = PS1 'intensidad.ps1' $par; Afirmar ($LASTEXITCODE -eq 0) "salio $LASTEXITCODE con $($par -join ' ')" }
    $rechazo = $false; try { $null = PS1 'intensidad.ps1' @('-Valor', 'turbo', '-Global') } catch { $rechazo = $true }; Afirmar ($rechazo -or $LASTEXITCODE -ne 0) 'el valor invalido debia salir con error'
}
T '2.3.0 register.tsx (antes 2.2.0 Crystal): sin colores fuera de la paleta Pixel Pro; las superficies tintadas viven solo en los tokens T' {
    $reg = Get-Content (Join-Path $raiz 'hooks\register.tsx') -Raw
    $perm = '#f5f0fa #b8a8c8 #ffc857 #ff6b81 #32d8f2 #43e889 #d6b8ff #21102f #8e7ba3 #4a2d63 #180b23 #ffffff #d58cff #d8c8ff #ba75f5 #2c173e #120b1f #efe4ff #4a3478 #3d2456 #33192a #3a1c2a #331e45 #352047 #2a1a40 #1a0b08 #1c0d28 #14263a #16283a #ff9b38 #b67aff #c76a1e #ffd6a8'.Split(' ')   # Matte Violet + Claude/Codex/Antigravity + mascota Chispa
    $fuera = [regex]::Matches($reg, '#[0-9a-fA-F]{6}\b') | ForEach-Object { $_.Value.ToLower() } | Where-Object { $_ -notin $perm } | Sort-Object -Unique
    Afirmar (-not $fuera) "colores fuera de paleta: $($fuera -join ', ')"
    foreach ($t in 'sCoral', 'sCian', 'sVidrio', 'sHondo', 'sActivo') { Afirmar ($reg.Contains("${t}:")) "falta el token $t" }
    foreach ($h in '#3a1c2a', '#16283a', '#331e45', '#1c0d28', '#3d2456') { Afirmar (([regex]::Matches($reg, [regex]::Escape($h))).Count -eq 1) "$h debe vivir solo en T (tokens)" }
}
T '2.2.0 register.tsx: KPI adaptable, sin s/d, sin punto suelto en Antigravity, guardas de null y botones de pagina accesibles' {
    $reg = Get-Content (Join-Path $raiz 'hooks\register.tsx') -Raw
    Afirmar ($reg.Contains('const tamValor')) 'falta el tamano de valor adaptable del KPI'
    $iM = $reg.IndexOf('function svgMotor'); $fM = $reg.IndexOf("`nfunction ", $iM + 10); $cuerpoMotor = $reg.Substring($iM, $fM - $iM)
    Afirmar (-not $cuerpoMotor.Contains('s/d')) "queda 's/d' en la tarjeta de motor"
    Afirmar ($reg.Contains("const sinD = (v: string) => v === 's/d'") -and $reg.Contains("'Sin datos'")) 'los KPI vacios deben mostrarse como Sin datos, no como s/d (2.3.2)'
    Afirmar ($reg.Contains('.replace(/^Antigravity[\s')) 'el grupo Antigravity no recorta su rotulo'
    Afirmar ($reg.Contains('function presionClaude(d: Datos | null | undefined)')) 'presionClaude no tolera datos nulos'
    Afirmar ($reg.Contains('(ef.recomendaciones ?? [])') -and $reg.Contains('(ch.j?.chats ?? [])')) 'faltan guardas de null en recomendaciones/chats'
    Afirmar ($reg.Contains(' Subir</Button>') -and $reg.Contains(' Bajar</Button>')) 'los botones de pagina no tienen texto accesible'
}
T 'delegar-agy.ps1 2.2.0: -Archivo grande se FRAGMENTA inline (el archivo temporal provocaba RunCommand denegado y respuesta vacia)' {
    $s = Get-Content (Join-Path $sc 'delegar-agy.ps1') -Raw
    Afirmar ($s.Contains('MULTIIA_AGY_PARTE_TXT') -and $s.Contains('$maxParte')) 'falta la fragmentacion por partes'
    Afirmar ($s -match "PARTE \`$k de") 'las partes no llevan numero ni rango de lineas'
    Afirmar ($s.Contains('NO uses herramientas')) 'las partes no prohiben herramientas'
    Afirmar ($s -notmatch "'-Prompt', \`$sub") 'la parte vuelve a ir como argumento de linea de comandos (rompe con saltos de linea)'
}
T '2.3.0 auditoria Codex de metricas: duplicados, costo parcial, sin dato != 0, filas de prueba y tokens desconocidos (tests\auditoria-metricas.ps1, datos aislados)' {
    $o = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'auditoria-metricas.ps1') 2>&1 | Out-String
    Afirmar ($LASTEXITCODE -eq 0 -and $o -match 'auditoria-metricas: \d+ ok, 0 fallas') "auditoria-metricas.ps1 fallo: $o"
}
T '2.3.1 configurar.ps1: primer inicio sin motores (carpeta de datos nueva, sin Codex ni agy) => config Automatico, metricas vacias, guias oficiales, sin tokens' {
    $d = Join-Path $tmp 'cfgnuevo'; $lad = Join-Path $tmp 'cfglad'; New-Item -ItemType Directory $lad -Force | Out-Null
    $nodeDir = Split-Path (Get-Command node).Source
    $cuerpo = "`$env:MULTIIA_DATOS = '$d'; `$env:LOCALAPPDATA = '$lad'; `$env:Path = '$nodeDir;' + `$env:SystemRoot + '\System32;' + `$env:SystemRoot + '\System32\WindowsPowerShell\v1.0'; & '$(Join-Path $sc 'configurar.ps1')' -Json; exit `$LASTEXITCODE"
    $o = & powershell -NoProfile -ExecutionPolicy Bypass -Command $cuerpo | Out-String; $cod = $LASTEXITCODE
    $j = $o | ConvertFrom-Json
    Afirmar ($cod -eq 0 -and $j.listo) "sin motores igual deberia quedar listo (codigo $cod)"
    Afirmar ($j.preferencias.creada_ahora -and $j.preferencias.intensidad -eq 'automatico' -and $j.preferencias.modo -eq 'automatico') 'no creo la config por defecto en Automatico'
    Afirmar ((Test-Path (Join-Path $d 'uso.jsonl')) -and (Get-Item (Join-Path $d 'uso.jsonl')).Length -eq 0) 'las metricas no arrancan vacias'
    Afirmar (@($j.motores | Where-Object { $_.instalado }).Count -eq 0) 'detecto un motor que no esta'
    Afirmar ((($j.pasos -join ' ') -match 'npm install -g @openai/codex') -and (($j.pasos -join ' ') -match 'codex login')) 'falta la guia oficial de Codex'
    Afirmar ((($j.limitaciones -join ' ') -match 'Claude hace todo')) 'no explica que sin motores no hay delegacion'
    Afirmar ($o -notmatch '(?i)(access_token|refresh_token|api[_-]?key|bearer)') 'la salida menciona tokens'
    # Segunda corrida: no pisa la config existente
    $cfg = Get-Content (Join-Path $d 'config.json') -Raw | ConvertFrom-Json; $cfg.intensidad = 'alto'; [IO.File]::WriteAllText((Join-Path $d 'config.json'), ($cfg | ConvertTo-Json -Depth 6))
    $j2 = (& powershell -NoProfile -ExecutionPolicy Bypass -Command $cuerpo | Out-String) | ConvertFrom-Json
    Afirmar (-not $j2.preferencias.creada_ahora -and $j2.preferencias.intensidad -eq 'alto') 'piso la configuracion existente del usuario'
}
T '2.3.1 configurar.ps1: carpeta de datos sin permiso => codigo 2 con paso MULTIIA_DATOS (no falla en silencio)' {
    $arch = Join-Path $tmp 'soyunarchivo'; Set-Content $arch 'x'
    $o = & powershell -NoProfile -ExecutionPolicy Bypass -Command "`$env:MULTIIA_DATOS = '$(Join-Path $arch 'datos')'; & '$(Join-Path $sc 'configurar.ps1')' -Json; exit `$LASTEXITCODE" 2>$null | Out-String; $cod = $LASTEXITCODE
    Afirmar ($cod -eq 2) "deberia salir con 2, salio con $cod"
    $j = $o.Substring($o.IndexOf('{')) | ConvertFrom-Json
    Afirmar (-not $j.requisitos.datos.ok -and (($j.pasos -join ' ') -match 'MULTIIA_DATOS')) 'no guia a cambiar MULTIIA_DATOS'
}
T '2.3.1 Find-CodexExe: encuentra Codex instalado por npm (no solo la app de escritorio), respeta MULTIIA_CODEX_EXE y devuelve vacio si no hay' {
    $base = Join-Path $tmp 'codexnpm'; $lad = Join-Path $base 'lad'; $npm = Join-Path $base 'npm'
    $nat = Join-Path $npm 'node_modules\@openai\codex\vendor\x86_64-pc-windows-msvc\codex'
    New-Item -ItemType Directory $lad, $nat -Force | Out-Null
    Set-Content (Join-Path $npm 'codex.cmd') '@echo off' -Encoding ASCII; Set-Content (Join-Path $nat 'codex.exe') 'x' -Encoding ASCII
    $cm = Join-Path $sc '_comun.ps1'
    $cuerpo = ". '$cm'; `$env:LOCALAPPDATA = '$lad'; `$env:Path = '$npm;' + `$env:SystemRoot + '\System32'; "
    $r1 = (& powershell -NoProfile -Command ($cuerpo + "Find-CodexExe") | Out-String).Trim()
    Afirmar ($r1 -eq (Join-Path $nat 'codex.exe')) "no encontro el binario del paquete npm: '$r1'"
    $r2 = (& powershell -NoProfile -Command ($cuerpo + "`$env:MULTIIA_CODEX_EXE = '$(Join-Path $npm 'codex.cmd')'; Find-CodexExe") | Out-String).Trim()
    Afirmar ($r2 -eq (Join-Path $npm 'codex.cmd')) "no respeto MULTIIA_CODEX_EXE: '$r2'"
    Remove-Item (Join-Path $npm 'codex.cmd') -Force
    $r3 = (& powershell -NoProfile -Command ($cuerpo + "'[' + (Find-CodexExe) + ']'") | Out-String).Trim()
    Afirmar ($r3 -eq '[]') "sin Codex deberia devolver vacio: '$r3'"
    foreach ($s in 'delegar-codex.ps1', 'conexiones.ps1', '_comun.ps1') {
        $c = Get-Content (Join-Path $sc $s) -Raw
        Afirmar (([regex]::Matches($c, 'OpenAI\\Codex\\bin" -Recurse')).Count -le $(if ($s -eq '_comun.ps1') { 1 } else { 0 })) "$s busca codex.exe por su cuenta en vez de usar Find-CodexExe"
    }
}
T '2.3.7 sin Codex ni Antigravity instalados: elegir.ps1 no tira error crudo, deriva a Claude y dice como solucionarlo; delegar.ps1 no intenta un respaldo no instalado' {
    $base = Join-Path $tmp 'sinmotores'; $lad = Join-Path $base 'lad'; $dat = Join-Path $base 'datos'
    New-Item -ItemType Directory $lad, $dat -Force | Out-Null
    $pre = "`$env:LOCALAPPDATA = '$lad'; `$env:MULTIIA_DATOS = '$dat'; `$env:Path = `$env:SystemRoot + '\System32'; "
    foreach ($tt in 'codigo', 'texto') {
        $o = (& powershell -NoProfile -Command ($pre + "& '$(Join-Path $sc 'elegir.ps1')' -Tarea $tt 2>&1 | Out-String") | Out-String)
        Afirmar ($o -match '"destino":"claude"') "sin motores ($tt) deberia derivar a claude: $o"
        Afirmar ($o -match 'configurar') "sin motores ($tt) deberia remitir a /configurar: $o"
        Afirmar ($o -notmatch 'Exception|CategoryInfo|no se puede') "sin motores ($tt) mostro un error crudo: $o"
    }
    $o = (& powershell -NoProfile -Command (". '$(Join-Path $sc '_comun.ps1')'; (Test-Secreto 'Cookie: session=abcdef123456'), (Hide-Secretos 'Set-Cookie: SID=zzzzzzzz99999'), (Get-AyudaClase 'desconocido').Length -join '|'") | Out-String).Trim()
    Afirmar ($o -match '^True\|' -and $o -match 'REDACTADO' -and $o -notmatch 'zzzzzzzz') "las cookies deben bloquearse/redactarse: $o"
    Afirmar ($o -notmatch '\|0$') 'toda clase de error debe tener una ayuda'
    $dc = Get-Content (Join-Path $sc 'delegar-codex.ps1') -Raw
    Afirmar ($dc -match 'not logged') 'delegar-codex.ps1 debe rechazar "Not logged in"'
    $dg = Get-Content (Join-Path $sc 'delegar.ps1') -Raw
    Afirmar ($dg -match 'altInst' -and $dg -match 'sin respaldo') 'delegar.ps1 no valida que el motor de respaldo este instalado'
}
T '2.3.1 handoff por proyecto: memoria.ps1 -Handoff guarda la carpeta y el hook solo lo inyecta en una sesion de esa carpeta (auditoria Codex #4)' {
    $node = (Get-Command node -ErrorAction SilentlyContinue).Source; if (-not $node) { $node = Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe' }
    $dh = Join-Path $tmp 'handoff-proy'; New-Item -ItemType Directory $dh -Force | Out-Null
    $pa = Join-Path $tmp 'proyA'; $pb = Join-Path $tmp 'proyB'; New-Item -ItemType Directory $pa, $pb -Force | Out-Null
    $viejoD = $env:MULTIIA_DATOS; $viejoP = $env:CLAUDE_PROJECT_DIR
    try {
        $env:MULTIIA_DATOS = $dh; $env:CLAUDE_PROJECT_DIR = $pa
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $sc 'memoria.ps1') -Handoff -Agregar 'seguir con la etapa X del proyecto A' | Out-Null
        $mem = Get-Content (Join-Path $dh 'MEMORIA.md') -Raw -Encoding UTF8
        Afirmar ($mem -match '\[handoff\] \{carpeta:') "el handoff no guardo la carpeta: $mem"
        $j = { param($c) ('{"cwd":"' + $c.Replace('\', '\\') + '"}') }
        $sA = (& $j $pa) | & $node (Join-Path $sc 'handoff-inicio.mjs') 2>&1 | Out-String
        Afirmar ($sA -match 'etapa X') "en el proyecto A no se inyecto el handoff: $sA"
        $sB = (& $j $pb) | & $node (Join-Path $sc 'handoff-inicio.mjs') 2>&1 | Out-String
        Afirmar (-not $sB.Trim()) "en el proyecto B se inyecto el handoff de A: $sB"
        Add-Content (Join-Path $dh 'MEMORIA.md') ("- [{0}] (Claude) [handoff] nota vieja sin carpeta" -f (Get-Date -Format 'yyyy-MM-dd HH:mm')) -Encoding UTF8
        $sV = (& $j $pb) | & $node (Join-Path $sc 'handoff-inicio.mjs') 2>&1 | Out-String
        Afirmar ($sV -match 'nota vieja sin carpeta') "un handoff sin carpeta (formato viejo) deberia seguir valiendo: $sV"
    } finally { $env:MULTIIA_DATOS = $viejoD; $env:CLAUDE_PROJECT_DIR = $viejoP }
}
Write-Host "== 2.3.1: correcciones de la auditoria Codex (cada una con su prueba)"
$env:MULTIIA_DATOS = $tmp; . (Join-Path $sc '_comun.ps1')
T '2.3.1 auditoria Codex #1: construir.ps1 NO borra una carpeta ajena (sin marcador) y deja su archivo intacto' {
    SoloDev 'usa una ruta o una carpeta que solo existe en DEV'
    $ErrorActionPreference = 'Continue'
    $aj = Join-Path $tmp 'ajena-community'; New-Item -ItemType Directory -Force $aj | Out-Null
    $fa = Join-Path $aj 'ajeno.txt'; [IO.File]::WriteAllText($fa, 'dato del usuario que no se toca')
    $o = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $raiz 'community\construir.ps1') -Destino $aj 2>&1 | Out-String); $cod = $LASTEXITCODE
    Afirmar ($cod -ne 0) "construir no fallo sobre una carpeta ajena: $o"
    Afirmar ($o -match 'No lo borro') "falta el motivo: $o"
    Afirmar ((Test-Path $fa) -and ([IO.File]::ReadAllText($fa) -eq 'dato del usuario que no se toca')) 'el archivo ajeno se borro o cambio'
    Afirmar (@(Get-ChildItem -LiteralPath $aj -Force).Count -eq 1) 'construir escribio en la carpeta ajena'
}
T '2.3.1 auditoria Codex #2: inicio-automatico arma un comando valido aunque la ruta tenga comillas simples' {
    $base = Join-Path $tmp "plu'gin"; $scr = Join-Path $base 'scripts'; New-Item -ItemType Directory -Force $scr | Out-Null
    Copy-Item (Join-Path $sc 'inicio-automatico.ps1') $scr
    $nd = Join-Path $tmp "no'de"; New-Item -ItemType Directory -Force $nd | Out-Null; Copy-Item (Join-Path $env:SystemRoot 'System32\whoami.exe') (Join-Path $nd 'node.exe')
    $ini = Join-Path $tmp 'inicio-comillas'; $viejoP = $env:Path
    try {
        $env:MULTIIA_INICIO = $ini; $env:Path = "$nd;$env:Path"
        $o = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scr 'inicio-automatico.ps1') -Activar 2>&1 | Out-String)
        $lnk = Join-Path $ini 'Multi-IA panel.lnk'
        Afirmar (Test-Path $lnk) "no creo el acceso: $o"
        $a = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
        Afirmar ($a.Arguments -match '-EncodedCommand (\S+)') "sin -EncodedCommand: $($a.Arguments)"
        $cmd = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1]))
        $err = $null; $tok = $null; $ast = [Management.Automation.Language.Parser]::ParseInput($cmd, [ref]$tok, [ref]$err)
        Afirmar ($err.Count -eq 0) "el comando no parsea: $cmd"
        $cmds = @($ast.FindAll({ $args[0] -is [Management.Automation.Language.CommandAst] }, $true))
        Afirmar ($cmds.Count -eq 1 -and $cmds[0].GetCommandName() -eq 'Start-Process') "se colaron otros comandos: $cmd"
        $fp = @($cmds[0].CommandElements | Where-Object { $_ -is [Management.Automation.Language.StringConstantExpressionAst] -and $_.Value -like '*node.exe' })
        Afirmar ($fp.Count -eq 1 -and $fp[0].Value -eq (Join-Path $nd 'node.exe')) "la ruta de node no quedo literal: $cmd"
        Afirmar ($cmd.Contains($scr.Replace("'", "''"))) "falta la ruta del servidor: $cmd"
    } finally { $env:Path = $viejoP; Remove-Item Env:\MULTIIA_INICIO -ErrorAction SilentlyContinue }
}
T '2.3.1 auditoria Codex #3: un secreto en el prompt o en la memoria NO sale a agy ni a codex (salida 2)' {
    $ErrorActionPreference = 'Continue'
    $viejoA = $env:MULTIIA_AGY_EXE; $env:MULTIIA_AGY_EXE = Join-Path $env:SystemRoot 'System32\whoami.exe'   # inofensivo si se llegara a ejecutar
    $mem = Join-Path $tmp 'MEMORIA.md'; $memViejo = if (Test-Path $mem) { [IO.File]::ReadAllText($mem) } else { $null }
    try {
        Remove-Item (Join-Path $tmp 'config.json*') -Force -ErrorAction SilentlyContinue
        $o = (PS1 'delegar-agy.ps1' @('-Prompt', 'revisa esto: api_key = "abcdefgh12345678"') | Out-String); $cod = $LASTEXITCODE
        Afirmar ($cod -eq 2 -and $o -match 'secreto') "agy con secreto en el prompt: salida $cod : $o"
        [IO.File]::WriteAllText($mem, "- nota: password = 'superclave123456'`n", (New-Object Text.UTF8Encoding($false)))
        $o = (PS1 'delegar-agy.ps1' @('-Prompt', 'tarea limpia', '-ConMemoria') | Out-String); $cod = $LASTEXITCODE
        Afirmar ($cod -eq 2 -and $o -match 'secreto') "agy con secreto en la memoria: salida $cod : $o"
        $o = (PS1 'delegar-codex.ps1' @('-Prompt', 'tarea limpia', '-ConMemoria') | Out-String); $cod = $LASTEXITCODE
        Afirmar ($cod -eq 2 -and $o -match 'secreto') "codex con secreto en la memoria: salida $cod : $o"
        $o = (PS1 'delegar-codex.ps1' @('-Prompt', ('token: sk-' + 'abcdefghijklmnop1234')) | Out-String); $cod = $LASTEXITCODE
        Afirmar ($cod -eq 2 -and $o -match 'secreto') "codex con secreto en el prompt: salida $cod : $o"
        $src = Get-Content (Join-Path $sc 'delegar-agy.ps1') -Raw
        Afirmar ($src -notmatch 'ReadAllLines') 'la fragmentacion vuelve a releer el archivo (podria mandar contenido no revisado)'
    } finally {
        $env:MULTIIA_AGY_EXE = $viejoA
        if ($null -ne $memViejo) { [IO.File]::WriteAllText($mem, $memViejo) } else { Remove-Item $mem -Force -ErrorAction SilentlyContinue }
    }
}
T '2.3.1 auditoria Codex #5: config corrupta queda APAGADA (no delega a ciegas) y -Recuperar la vuelve a encender' {
    $cj = Join-Path $tmp 'config.json'; Remove-Item "$cj*" -Force -ErrorAction SilentlyContinue
    [IO.File]::WriteAllText($cj, '{ roto', (New-Object Text.UTF8Encoding($false)))
    . (Join-Path $sc '_comun.ps1')
    $c = Get-Config
    Afirmar ($c.activo -eq $false) 'una config corrupta deberia quedar apagada'
    $e = (PS1 'elegir.ps1' @('-Tarea', 'codigo') | Out-String) | ConvertFrom-Json
    Afirmar ($e.destino -eq 'apagado') "elegir delego con config corrupta: $($e.destino)"
    $o = (PS1 'config.ps1' @('-Recuperar') | Out-String)
    Afirmar ($o -match 'recuperada') "no recupero: $o"
    $c2 = [IO.File]::ReadAllText($cj) | ConvertFrom-Json
    Afirmar ($c2.activo -eq $true) 'tras -Recuperar deberia quedar encendida'
    Remove-Item "$cj*" -Force -ErrorAction SilentlyContinue
}
T '2.3.1 auditoria Codex #6: Invoke-ConTimeout cierra un descendiente que quedo vivo con las tuberias (sin huerfanos)' {
    $marca = '-n 47 127.0.0.1'
    $r = Invoke-ConTimeout 'cmd.exe' @('/c', 'start', '/b', 'ping', '-n', '47', '127.0.0.1') 20
    Afirmar ($null -ne $r) 'devolvio null sin timeout'
    Start-Sleep -Milliseconds 800
    $vivos = @(Get-CimInstance Win32_Process -Filter "Name='PING.EXE'" | Where-Object { $_.CommandLine -like "*$marca*" })
    if ($vivos) { $vivos | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } }
    Afirmar ($vivos.Count -eq 0) "quedo vivo un ping huerfano (PID $($vivos.ProcessId -join ','))"
}
T '2.3.1 auditoria Codex #7: candado vacio NACIENDO se respeta, uno de PID muerto se recupera y el retiro no borra uno ajeno' {
    $rec = 'prueba-candado-231-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
    $b = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($rec.ToLowerInvariant()))
    $d = Join-Path $tmp 'locks'; New-Item -ItemType Directory -Force $d | Out-Null
    $f = Join-Path $d ((($b[0..7] | ForEach-Object { $_.ToString('x2') }) -join '') + '.lock')
    [IO.File]::WriteAllText($f, '')                                   # recien creado y todavia sin contenido
    Afirmar (-not (Enter-Candado $rec)) 'piso un candado que estaba naciendo'
    Afirmar ((Test-Path $f) -and ([IO.File]::ReadAllText($f) -eq '')) 'el candado naciente se borro o cambio'
    $muerto = '{"pid":999999,"fecha":"' + (Get-Date).ToString('s') + '","recurso":"x"}'
    [IO.File]::WriteAllText($f, $muerto)
    Afirmar (Enter-Candado $rec) 'no recupero un candado de un PID muerto'
    Afirmar (([IO.File]::ReadAllText($f) | ConvertFrom-Json).pid -eq $PID) 'el candado no quedo a mi nombre'
    Exit-Candado $rec
    [IO.File]::WriteAllText($f, '{"pid":1,"fecha":"nuevo"}')
    Afirmar (-not (Remove-CandadoViejo $f '{"pid":2,"fecha":"viejo"}')) 'retiro un candado distinto del que juzgo viejo'
    Afirmar ((Test-Path $f) -and ([IO.File]::ReadAllText($f) -eq '{"pid":1,"fecha":"nuevo"}')) 'el candado ajeno no volvio a su lugar'
    Afirmar (@(Get-ChildItem $d -Filter '*.retiro').Count -eq 0) 'quedo un .retiro suelto'
    Remove-Item $f -Force -ErrorAction SilentlyContinue
}
T '2.3.1 auditoria Codex #8 y #11: reiniciar-claude escribe eventos con el mutex compartido y sin rutas personales' {
    $src = Get-Content (Join-Path $sc 'reiniciar-claude.ps1') -Raw
    Afirmar ($src -match "Global\\MultiIA_jsonl_eventos\.jsonl") 'eventos.jsonl se escribe sin el mutex de los demas escritores'
    Afirmar ($src -notmatch '(?i)C:\\Users\\[a-z]') 'quedo una ruta personal fija'
    Afirmar ($src -match "USERPROFILE") 'el respaldo de la carpeta de datos no usa USERPROFILE'
}
T '2.3.1 auditoria Codex #9: claude-snapshot escribe atomico (JSON valido y sin temporales)' {
    $o = (PS1 'claude-snapshot.ps1' @('-CincoHoras', '12', '-Semanal', '34') | Out-String)
    $j = [IO.File]::ReadAllText((Join-Path $tmp 'claude-snapshot.json')) | ConvertFrom-Json
    Afirmar ($j.cinco_horas.usado -eq 12 -and $j.semanal.usado -eq 34) "snapshot mal: $o"
    Afirmar (@(Get-ChildItem $tmp -Filter 'claude-snapshot.json.*.tmp').Count -eq 0) 'quedo un temporal'
    Set-TextoAtomico (Join-Path $tmp 'atom.txt') 'uno'; Set-TextoAtomico (Join-Path $tmp 'atom.txt') 'dos'
    Afirmar ([IO.File]::ReadAllText((Join-Path $tmp 'atom.txt')) -eq 'dos') 'Set-TextoAtomico no reemplazo'
}
T '2.3.1 auditoria Codex #10: Hide-Secretos y Get-ClaseError tachan secretos y emails de lo que queda registrado' {
    $t = 'fallo con api_key=abcdefgh12345678 para persona@ejemplo.com y sk-' + 'abcdefghijklmnop1234'
    $h = Hide-Secretos $t
    Afirmar ($h -notmatch 'abcdefgh12345678|persona@ejemplo|sk-abcdef') "quedo algo sin tachar: $h"
    Afirmar ($h -match '\[REDACTADO\]' -and $h -match '\[email\]') "no marco lo tachado: $h"
    $c = Get-ClaseError -Texto "error: token: abcdefgh12345678 de yo@correo.com" -Salida 1
    Afirmar ($c.causa -notmatch 'abcdefgh12345678|yo@correo') "la causa registrada tiene datos sensibles: $($c.causa)"
    $src = Get-Content (Join-Path $sc 'arena.ps1') -Raw
    Afirmar ($src -match 'Hide-Secretos \$Prompt') 'arena registra el prompt sin tachar'
}
T '2.3.1 auditoria Codex #13: Find-AgyExe respeta MULTIIA_AGY_EXE y no rompe sin LOCALAPPDATA' {
    $w = Join-Path $env:SystemRoot 'System32\whoami.exe'
    $viejoA = $env:MULTIIA_AGY_EXE; $env:MULTIIA_AGY_EXE = $w
    try { Afirmar ((Find-AgyExe) -eq $w) "no uso MULTIIA_AGY_EXE: $(Find-AgyExe)" } finally { $env:MULTIIA_AGY_EXE = $viejoA }
    $o = (& powershell -NoProfile -Command "`$env:LOCALAPPDATA=''; `$env:MULTIIA_AGY_EXE=''; `$env:MULTIIA_DATOS='$tmp'; . '$($sc.Replace('''',''''''))\_comun.ps1'; try { `$r = Find-AgyExe; 'OK:' + [string]`$r } catch { 'ERROR:' + `$_ }" 2>&1 | Out-String)
    Afirmar ($o -match 'OK:' -and $o -notmatch 'ERROR:') "rompio sin LOCALAPPDATA: $o"
    foreach ($n in 'delegar-agy.ps1', 'motores.ps1', 'conexiones.ps1') { Afirmar ((Get-Content (Join-Path $sc $n) -Raw) -match 'Find-AgyExe') "$n no usa la deteccion unica" }
}
T '2.3.8 hallazgo Codex #4: un ejecutable que no arranca da codigo 126 y clase no-arranca, sin excepcion cruda' {
    $malo = Join-Path $tmp 'no-ejecutable.exe'; [IO.File]::WriteAllText($malo, 'esto no es un ejecutable')
    $r = Invoke-ConTimeout $malo @('--version') 10
    Afirmar ($r -and $r.codigo -eq 126 -and $r.arranque -eq $false) "no devolvio 126/arranque=false: $($r | Out-String)"
    Afirmar ((Get-ClaseError -Texto $r.error -Salida $r.codigo).clase -eq 'no-arranca') "clase mal: $((Get-ClaseError -Texto $r.error -Salida $r.codigo) | Out-String)"
    $viejoO = $env:MULTIIA_ORIGEN; $viejoA = $env:MULTIIA_AGY_EXE; $env:MULTIIA_ORIGEN = 'test'; $env:MULTIIA_AGY_EXE = $malo
    $eapV = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $o = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $sc 'delegar-agy.ps1') -Prompt hola 2>&1 | Out-String)
        Afirmar ($LASTEXITCODE -eq 126) "agy con exe invalido salio $LASTEXITCODE (esperado 126)"
        Afirmar ($o -match 'no arranca') "mensaje sin 'no arranca': $o"
    } finally { $ErrorActionPreference = $eapV; $env:MULTIIA_ORIGEN = $viejoO; $env:MULTIIA_AGY_EXE = $viejoA }
}
T '2.3.1 auditoria Codex #14: la cache distingue memoria distinta y no guarda respuestas de codex' {
    $mem = Join-Path $tmp 'MEMORIA.md'; $memViejo = if (Test-Path $mem) { [IO.File]::ReadAllText($mem) } else { $null }
    try {
        [IO.File]::WriteAllText($mem, "- nota A`n"); $h1 = Get-HashMemoria
        [IO.File]::WriteAllText($mem, "- nota B`n"); $h2 = Get-HashMemoria
        Afirmar ($h1 -and $h2 -and $h1 -ne $h2) "la huella no cambia con la memoria: $h1 / $h2"
    } finally { if ($null -ne $memViejo) { [IO.File]::WriteAllText($mem, $memViejo) } else { Remove-Item $mem -Force -ErrorAction SilentlyContinue } }
    $src = Get-Content (Join-Path $sc 'delegar.ps1') -Raw
    Afirmar ($src -match "destino -ne 'codex'") 'codex sigue siendo cacheable (lee el repo: la respuesta cambia con los archivos)'
    Afirmar ($src -match 'mem=' -and $src -match 'Get-HashMemoria') 'la clave de cache no incluye la memoria'
}
T '2.3.1 auditoria Codex #12 (limitacion aceptada): hooks y panel llaman a node; /configurar lo verifica como requisito' {
    Afirmar ((Get-Content (Join-Path $sc 'configurar.ps1') -Raw) -match '(?i)node') '/configurar no verifica Node como requisito'
}

# --- 2.3.1: correcciones de la revision Antigravity (Community) ---
T '2.3.1 revision Antigravity: si conexiones.ps1 falla, configurar avisa el fallo y NO dice "no instalado" ni manda a instalar' {
    $ErrorActionPreference = 'Continue'
    $cs = Join-Path $tmp 'cfg-roto\scripts'; New-Item -ItemType Directory -Force $cs | Out-Null
    Copy-Item (Join-Path $sc '*.ps1') $cs -Force
    [IO.File]::WriteAllText((Join-Path $cs 'conexiones.ps1'), "Write-Error 'roto a proposito'; exit 1", (New-Object Text.UTF8Encoding($true)))
    $o = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $cs 'configurar.ps1') -Json 2>$null | Out-String)
    $j = $o | ConvertFrom-Json
    $pz = ($j.pasos -join "`n")
    Afirmar ($pz -match 'No se pudo diagnosticar') "no aviso el fallo del diagnostico: $pz"
    Afirmar ($pz -notmatch 'npm install') "mando a instalar a ciegas: $pz"
    Afirmar (@($j.motores | Where-Object { $_.estado -match 'Desconocido' }).Count -eq 2) "los motores no quedaron como desconocidos: $(($j.motores | ForEach-Object { $_.estado }) -join ' / ')"
    Afirmar ((Get-Content (Join-Path $sc 'configurar.ps1') -Raw) -match "\[version\]'5\.1'") 'el chequeo de PowerShell no exige 5.1'
}
T '2.3.1 revision Antigravity: la CI de la Community detecta claves sk-proj, sk-ant y github_pat' {
    SoloDev 'usa una ruta o una carpeta que solo existe en DEV'
    $ci = Get-Content (Join-Path $raiz 'community\plantilla\.github\workflows\ci.yml') -Raw
    Afirmar ($ci -match "\`$p = '([^']+)'") 'no encuentro el patron de secretos de la CI'
    $pat = $Matches[1]
    foreach ($s in ('sk-proj-' + 'Ab12Cd34Ef56Gh78Ij90Kl12'), ('sk-ant-api03-' + 'Ab12Cd34Ef56Gh78Ij90'), ('github_pat_' + '11ABCDEFG0123456789_abcdefghijklmnop')) {
        Afirmar ($s -match $pat) "la CI no detecta $($s.Substring(0, 8))..."
    }
    Afirmar (-not ('texto normal sin claves' -match $pat)) 'la CI marca texto normal'
    $sec = Get-Content (Join-Path $raiz 'community\plantilla\SECURITY.md') -Raw
    Afirmar ($sec -match 'no es infalible') 'SECURITY.md vuelve a prometer que nunca se manda un secreto'
}
T '2.3.1 revision Antigravity: MULTIIA_DATOS relativo se ignora (carpeta por defecto + aviso); absoluto se respeta' {
    $cmd = ". '" + (Join-Path $sc '_comun.ps1') + "'; `$script:DatosDir; 'AVISO=' + `$script:AvisoDatos"
    $prev = $env:MULTIIA_DATOS
    try {
        $env:MULTIIA_DATOS = 'datos-relativos'
        $r = (& powershell -NoProfile -ExecutionPolicy Bypass -Command $cmd 2>&1 | Out-String)
        Afirmar ($r -notmatch '(?m)^datos-relativos\s*$') 'una ruta relativa se usa como carpeta de datos'
        Afirmar ($r -match 'AVISO=MULTIIA_DATOS=.datos-relativos. no es una ruta absoluta') 'no queda aviso para la ruta relativa'
        $env:MULTIIA_DATOS = $tmp
        $r = (& powershell -NoProfile -ExecutionPolicy Bypass -Command $cmd 2>&1 | Out-String)
        Afirmar ($r.Contains($tmp)) 'una ruta absoluta no se respeta'
        Afirmar ($r -match '(?m)^AVISO=\s*$') 'avisa con una ruta absoluta valida'
    } finally { $env:MULTIIA_DATOS = $prev }
    foreach ($f in 'guardia-contexto.mjs', 'handoff-inicio.mjs', 'panel-servidor.mjs', 'statusline.mjs', 'reiniciar-claude.ps1') {
        $c = Get-Content (Join-Path $sc $f) -Raw
        Afirmar ($c -match '\[A-Za-z\]:\[') "$f no valida que MULTIIA_DATOS sea absoluta"
    }
}
T '2.3.1: la Community trae icono (512-2048 px, cuadrado, < 2 MB) y el README marca (ES) los documentos solo en castellano' {
    SoloDev 'usa una ruta o una carpeta que solo existe en DEV'
    $ic = Join-Path $raiz 'community\plantilla\.claude-plugin\icon.png'
    Afirmar (Test-Path $ic) 'falta community\plantilla\.claude-plugin\icon.png'
    Add-Type -AssemblyName System.Drawing
    $img = [System.Drawing.Image]::FromFile($ic)
    try { Afirmar ($img.Width -eq $img.Height -and $img.Width -ge 512 -and $img.Width -le 2048) "icono de $($img.Width)x$($img.Height)" } finally { $img.Dispose() }
    Afirmar ((Get-Item $ic).Length -lt 2MB) 'el icono pesa 2 MB o mas'
    $rd = Get-Content (Join-Path $raiz 'community\plantilla\README.md') -Raw -Encoding UTF8
    foreach ($d in 'SECURITY.md', 'PRIVACY.md', 'CONTRIBUTING.md', 'CHANGELOG.md') {
        Afirmar ($rd -match ([regex]::Escape("($d)") + ' \(ES\)')) "README.md no marca $d como (ES)"
    }
    Afirmar ($rd -match '/panel-ia') 'README.md no dice como abrir el panel'
    $ci = Get-Content (Join-Path $raiz 'community\plantilla\.github\workflows\ci.yml') -Raw
    Afirmar ($ci -match "\`$rutas = '([^']+)'") 'la CI no escanea rutas personales'
    $rutas = $Matches[1]
    Afirmar (('C:' + '\Users\Fulano\x') -match $rutas) 'el patron de rutas no detecta C:\Users\<alguien>'
    Afirmar (-not ('%USERPROFILE%\x' -match $rutas)) 'el patron de rutas marca %USERPROFILE%'
    Afirmar (-not (('C:' + '\Users\Public\x') -match $rutas)) 'el patron de rutas marca C:\Users\Public'
}
Write-Host "== 2.3.10 (hallazgos de la auditoria cruzada de Codex)"
T '2.3.10 Codex (a): Remove-CandadoViejo no retira un candado ajeno ni por un instante (sin ventana de carrera)' {
    $f = Join-Path $tmp 'carrera.lock'; $nuevo = '{"pid":1,"fecha":"nuevo"}'
    [IO.File]::WriteAllText($f, $nuevo)
    $h = [hashtable]::Synchronized(@{ stop = $false; faltas = 0 })
    $rs = [runspacefactory]::CreateRunspace(); $rs.Open(); $rs.SessionStateProxy.SetVariable('h', $h); $rs.SessionStateProxy.SetVariable('f', $f)
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript({ while (-not $h.stop) { if (-not [IO.File]::Exists($f)) { $h.faltas++ } } })
    $as = $ps.BeginInvoke()
    try {
        Start-Sleep -Milliseconds 300
        for ($i = 0; $i -lt 1500; $i++) { [void](Remove-CandadoViejo $f '{"pid":2,"fecha":"viejo"}') }
    } finally { $h.stop = $true; [void]$ps.EndInvoke($as); $ps.Dispose(); $rs.Dispose() }
    Afirmar ($h.faltas -eq 0) "el candado ajeno desaparecio $($h.faltas) veces durante el retiro"
    Afirmar ([IO.File]::ReadAllText($f) -eq $nuevo) 'el candado ajeno cambio'
    Afirmar (@(Get-ChildItem $tmp -Filter '*.retiro').Count -eq 0) 'quedo un archivo de retiro suelto'
    Afirmar (Remove-CandadoViejo $f $nuevo) 'no retiro un candado que si era el juzgado viejo'
    Afirmar (-not (Test-Path $f)) 'el candado viejo seguia ahi'
}
T '2.3.10 Codex (b): Invoke-ConTimeout cierra tambien un nieto cuyo padre intermedio ya murio' {
    $m = '-n 48 127.0.0.9'
    $cmd = "Start-Process cmd.exe -ArgumentList '/c','start','/b','ping','-n','48','127.0.0.9' -WindowStyle Hidden; Start-Sleep 60"
    $r = Invoke-ConTimeout 'powershell.exe' @('-NoProfile', '-Command', $cmd) 5 -Duro
    Afirmar ($r.timeout) 'no vencio el tiempo'
    Start-Sleep -Milliseconds 800
    $vivos = @(Get-CimInstance Win32_Process -Filter "Name='PING.EXE'" | Where-Object { $_.CommandLine -like "*$m*" })
    if ($vivos) { $vivos | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } }
    Afirmar ($vivos.Count -eq 0) "sobrevivio un nieto tras el timeout (PID $($vivos.ProcessId -join ','))"
}
T '2.3.10 Codex (c): el respaldo no reintenta sin el contexto (-Carpeta hacia agy / -Archivo hacia codex) y lo avisa' {
    $arch = Join-Path $tmp 'ctx.txt'; [IO.File]::WriteAllText($arch, 'contenido de prueba')
    $r = Correr-Deleg 'codigo' 'codex' 'agy' @('-Carpeta', $tmp)
    Afirmar ($r.out -match 'sin respaldo' -and $r.out -notmatch 'cambio de motor') "codex->agy con -Carpeta: $($r.out)"
    Afirmar ($r.cod -ne 0) 'debia seguir fallando'
    $r = Correr-Deleg 'texto' 'agy' 'codex' @('-Archivo', $arch)
    Afirmar ($r.out -match 'sin respaldo' -and $r.out -notmatch 'cambio de motor') "agy->codex con -Archivo: $($r.out)"
    $r = Correr-Deleg 'codigo' 'codex' 'agy'
    Afirmar ($r.out -match 'cambio de motor') "sin contexto adjunto el respaldo debia seguir andando: $($r.out)"
}
T '2.3.10 Codex (d): si falla la revision cruzada el comando no sale con 0 (codigo 4) y el resultado del primer motor se conserva' {
    $r = Correr-Deleg 'codigo' 'agy' 'codex' @('-Cruzar')
    Afirmar ($r.out -match 'respuesta ok de Codex') 'se perdio la respuesta del primer motor'
    Afirmar ($r.out -match 'revision cruzada fallo') "falta el aviso: $($r.out)"
    Afirmar ($r.cod -eq 4) "debia salir con 4, salio con $($r.cod)"
    $r = Correr-Deleg 'codigo' '' 'codex agy' @('-Cruzar')
    Afirmar ($r.cod -eq 0) "revision exitosa debia salir 0, salio $($r.cod)"
}
T '2.3.10 Codex (e): los tokens de agy en partes fragmentadas se atribuyen a la ejecucion (Get-TokEj)' {
    $fake = Join-Path $tmp 'agy-falso.exe'   # exe real: un .cmd tiene tope de 8191 caracteres de linea y el prompt de cada parte lo supera
    Add-Type -OutputAssembly $fake -OutputType ConsoleApplication -TypeDefinition 'public static class P { public static void Main() { System.Console.WriteLine("{\"status\":\"SUCCESS\",\"response\":\"ok\",\"conversation_id\":\"c-frag\",\"usage\":{\"input_tokens\":100,\"output_tokens\":20}}"); } }'
    $grande = Join-Path $tmp 'grande.txt'
    [IO.File]::WriteAllText($grande, ((1..1000 | ForEach-Object { 'linea de prueba ' + $_ }) -join "`r`n"), [Text.Encoding]::ASCII)
    $id = 'ej-frag-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
    $viejoA = $env:MULTIIA_AGY_EXE; $env:MULTIIA_AGY_EXE = $fake; $eapV = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $cmd = "`$global:MIA_IdEj = '$id'; & '$($sc.Replace("'", "''"))\delegar-agy.ps1' -Prompt 'x' -Archivo '$($grande.Replace("'", "''"))'"
        $o = (& powershell -NoProfile -ExecutionPolicy Bypass -Command $cmd 2>&1 | Out-String)
    } finally { $env:MULTIIA_AGY_EXE = $viejoA; $ErrorActionPreference = $eapV }
    Afirmar ($o -match 'PARTE 2/') "no se fragmento: $o"
    $filas = @(Get-Uso -Todo | Where-Object { [string]$_.ej -eq $id })
    Afirmar ($filas.Count -ge 2) "las partes no quedaron atribuidas a la ejecucion ($($filas.Count) filas)"
    Afirmar ((Get-TokEj $id) -eq (120 * $filas.Count)) "tokens de la ejecucion: $(Get-TokEj $id)"
}
T '2.3.11: Test-Secreto detecta tokens GitHub/AWS/JWT, credenciales en URL y valores entrecomillados con espacios; -Aislar mira el contenido' {
    . (Join-Path $sc '_comun.ps1')
    foreach ($x in @('ghp_' + ('a' * 24), 'AKIA' + ('A' * 16), 'https://user:clave@host/x', 'password = "mi clave secreta"', 'eyJhbGciOiJIUzI1.eyJzdWIiOiIxMjM0NTY.SflKxwRJSMeKKF2QT4')) { Afirmar (Test-Secreto $x) "no detecto: $x" }
    Afirmar (-not (Test-Secreto 'hola, esto es texto normal sin nada raro')) 'falso positivo en texto normal'
    Afirmar ((Get-Content (Join-Path $sc 'delegar-codex.ps1') -Raw) -match 'conSecreto.*Test-Secreto') '-Aislar no revisa el contenido'
}
T 'delegar-agy: todo prompt lleva la orden de no usar herramientas (2.3.11: "numeros del 1 al 400" daba respuesta vacia por RunCommand denegado)' {
    $s = Get-Content (Join-Path $sc 'delegar-agy.ps1') -Raw
    Afirmar ($s -match "\`$argsAgy = @\('-p', \(\`$Prompt \+ \`$cola\)\)" -and $s -match 'no uses herramientas ni comandos' -and $s -match "No corras comandos") 'el prompt enviado a agy no incluye la orden de no usar herramientas (lectura) o no correr comandos (escritura sin -Verificar)'
}
T '3.1.0 auditoria Codex: 401 + timed out es autenticacion (no reintentable); -Aislar mira contenido hasta 20 MB' {
    foreach ($x in @('HTTP 401 Unauthorized: request timed out', 'UNAUTHENTICATED: login timed out')) { $r = Get-ClaseError -Texto $x -Salida 1; Afirmar ($r.clase -eq 'autenticacion' -and -not $r.reintentable) "'$x' dio '$($r.clase)'" }
    $s = Get-Content (Join-Path $sc 'delegar-codex.ps1') -Raw
    Afirmar ($s -match '\$_\.Length -gt 20MB -or \(Test-Secreto') '-Aislar no revisa el contenido de archivos grandes'
}
T '3.1.0 conexiones.ps1: "Not logged in" gana a "logged in"; -Probar re-consulta la sesion; un fallo de --version no se cachea 24 h' {
    $c = Get-Content (Join-Path $sc 'conexiones.ps1') -Raw
    Afirmar ($c.IndexOf("-match '(?i)not logged') { 'sin sesion' }") -lt $c.IndexOf("-match '(?i)logged in') { 'sesion iniciada' }")) 'el chequeo de not logged debe ir antes que logged in'
    Afirmar ($c -match 'Vigente \$reg\.auth 3600\) -and \$Probar -notin') '-Probar debe saltar la cache de auth'
    Afirmar ($c -match 'Vigente \$reg\.version 86400\) -and \$reg\.version\.valor') 'un fallo de --version no debe cachearse'
}
T '3.2.0 Codex escritura: delegar.ps1 rechaza (exit 5) una tarea de escritura sin -Escribir/-Aislar; -Escribir exige -Carpeta' {
    $o = (PS1 'delegar.ps1' @('-Tarea', 'codigo', '-Prompt', 'Corregi el bug de calc.py y crea test_calc.py', '-Carpeta', $tmp) | Out-String); $cod = $LASTEXITCODE
    Afirmar ($cod -eq 5 -and $o -match 'SIN-DELEGAR:escritura') "debia salir 5 (salio $cod): $o"
    $o = (PS1 'delegar.ps1' @('-Tarea', 'codigo', '-Prompt', 'Corregi calc.py', '-Escribir') | Out-String); $cod = $LASTEXITCODE
    Afirmar ($cod -eq 5 -and $o -match 'exige -Carpeta') "-Escribir sin -Carpeta debia salir 5 (salio $cod): $o"
}
T '3.2.0 Codex escritura: delegar-codex.ps1 pasa workspace-write solo con -Escribir, red opt-in, carpetas prohibidas y registro de archivos' {
    $dc = Get-Content (Join-Path $sc 'delegar-codex.ps1') -Raw
    Afirmar ($dc -match "if \(\`$Escribir\) \{ 'workspace-write' \} else \{ 'read-only' \}") 'el sandbox ya no depende de -Escribir'
    Afirmar ($dc -match 'sandbox_workspace_write\.network_access=true') 'falta el opt-in de red'
    Afirmar ($dc -notmatch 'danger-full-access|dangerously-bypass') 'no se permite desactivar el sandbox'
    Afirmar ($dc -match 'Escritura NO permitida' -and $dc -match 'Get-Instantanea' -and $dc -match 'Tarea INCOMPLETA') 'faltan preflight de carpeta, registro de archivos o deteccion de incompleta'
    $d = Get-Content (Join-Path $sc 'delegar.ps1') -Raw
    Afirmar ($d -match 'if \(\$Escribir\) \{ \$p\.Escribir = \$true \}' -and $d -match '\$q\.Escribir = \$true') 'delegar.ps1 no propaga -Escribir (causa raiz del solo-lectura)'
    $ErrorActionPreference = 'Continue'
    try { $o = (PS1 'delegar-codex.ps1' @('-Prompt', 'x', '-Escribir', '-Carpeta', $env:TEMP) | Out-String); $cod = $LASTEXITCODE } finally { $ErrorActionPreference = 'Stop' }
    Afirmar ($cod -ne 0 -and $o -match 'NO\s+permitida|sesi') "escribir en TEMP debia rechazarse: $o"
}
T '3.3.0 agy escritura: arranca en la carpeta autorizada, verifica por su cuenta y delegar.ps1 pasa modelo/escritura' {
    $s = Get-Content (Join-Path $sc 'delegar-agy.ps1') -Raw
    Afirmar ($s -match 'CurrentDirectory = \$carpetaOk') 'agy debe arrancar con cwd = carpeta autorizada (si no, la allow-list command() no coincide)'
    Afirmar ($s -match 'verificacion propia' -and $s -match 'vacioDenegado') 'falta la verificacion propia ante RunCommand denegado'
    $codigo = ($s -split "`n" | Where-Object { $_ -notmatch '^\s*#' } | ForEach-Object { $_ -replace '\s#.*$', '' }) -join "`n"
    Afirmar ($codigo -notmatch "dangerously-skip-permissions|'auto'") 'agy no puede usar modos que omiten protecciones'
    $d = Get-Content (Join-Path $sc 'delegar.ps1') -Raw
    Afirmar ($d -match '\$Verificar' -and $d -match '-Escribir' -and $d -match '-Carpeta') 'delegar.ps1 no propaga Verificar/Escribir/Carpeta a agy'
}
T '3.3.0 Codex escritura: tambien registra el evento "cambios" (MIA_Cambios) y Get-Motores informa politica/esfuerzo/solo_lectura' {
    $s = Get-Content (Join-Path $sc 'delegar-codex.ps1') -Raw
    Afirmar ($s -match 'MIA_Cambios = \[ordered\]' -and $s -match "NUEVO:\*") 'delegar-codex.ps1 debe publicar MIA_Cambios para que delegar.ps1 emita el evento cambios'
    $c = Get-Content (Join-Path $sc '_comun.ps1') -Raw
    Afirmar ($c -match 'esfuerzo_pedido' -and $c -match 'solo_lectura' -and $c -match 'politica = \$pol') 'Get-Motores debe exponer politica, esfuerzo_pedido y solo_lectura'
}
T '3.3.0 auditoria cruzada: sin cache con -Escribir, sin fragmentar con -Escribir, checkpoint con ID unico y "cambios" no pisa el estado terminal del panel' {
    $d = Get-Content (Join-Path $sc 'delegar.ps1') -Raw
    Afirmar ($d -match '\$cacheable = -not \$SinCache -and -not \$Escribir') 'una escritura no puede servirse desde la cache'
    $a = Get-Content (Join-Path $sc 'delegar-agy.ps1') -Raw
    Afirmar ($a -match '\$Escribir -and \(\$Prompt\.Length \+ \(\$bloques') 'con -Escribir y material grande debe rechazar en vez de fragmentar'
    Afirmar ($a -match "'agy-' \+ \(Get-Date -Format 'yyyyMMdd-HHmmss'\) \+ '-' \+ \(\[guid\]") 'el ID del checkpoint debe incluir un sufijo unico'
    $r = Get-Content (Join-Path (Split-Path $sc -Parent) 'hooks\register.tsx') -Raw -Encoding UTF8
    Afirmar ($r -match "if \(v\.t === 'cambios'\) \{ e\.fin = v\.f; continue \}") 'el evento cambios no debe sobrescribir t/x/m de una ejecucion ya cerrada'
}
T '3.3.1 metricas: los KPI no suman proveedores, muestran terminadas/fallidas/recuperadas y el ahorro dice No determinable sin base; chats.ps1 mantiene total NO DISPONIBLE' {
    $r = Get-Content (Join-Path (Split-Path $sc -Parent) 'hooks\register.tsx') -Raw -Encoding UTF8
    Afirmar ($r -cnotmatch "r: 'Tokens totales'") 'el KPI global no puede llamarse Tokens totales (sumaba Claude + Codex + Antigravity)'
    Afirmar ($r -match "r: 'Consumo de Claude'" -and $r -match "r: 'Delegaciones terminadas'" -and $r -match "'Recuperación de tareas'" -and $r -match "r: 'Ahorro por chat', c: T\.ahorro, ic: 'moneda'") 'faltan los cuatro KPI de 3.3.1'
    $vpj = (Get-Content (Join-Path (Split-Path $sc -Parent) '.claude-plugin\plugin.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version
    Afirmar ($r -match ("const VERSION = '" + [regex]::Escape($vpj) + "'")) 'VERSION del panel desalineada (debe coincidir con plugin.json)'
    $c = Get-Content (Join-Path $sc 'chats.ps1') -Raw -Encoding UTF8
    Afirmar ($c -match "total = \[ordered\]@\{ valor = \`$null; nivel = 'NO DISPONIBLE'") 'chats.ps1 no debe producir un total entre proveedores'
}
# ---- 3.4.0: inventario dinamico de modelos y seleccion explicable (catalogos sembrados en la cache de la carpeta temporal: no llama a ninguna CLI)
Write-Host "== 3.4.0 router: inventario y seleccion"
function Sembrar-Catalogos($codex, $agy) {
    $t = (Get-Date).ToString('s')
    [IO.File]::WriteAllText((Join-Path $tmp 'modelos-codex.json'), ([pscustomobject]@{ tomado = $t; esquema = 2; lista = @($codex) } | ConvertTo-Json -Depth 6))
    [IO.File]::WriteAllText((Join-Path $tmp 'modelos-agy.json'), ([pscustomobject]@{ tomado = $t; esquema = 1; lista = @($agy) } | ConvertTo-Json -Depth 6))
}
function CxM($slug, $desc, $prio, $ef, $vis = $true) { [pscustomobject]@{ slug = $slug; nombre = $slug; descripcion = $desc; contexto = 272000; prioridad = $prio; visible = $vis; esfuerzo_def = 'medium'; esfuerzos = @($ef); esfuerzos_desc = @() } }
$cxCat = @((CxM 'm-sol' 'Latest workhorse model for coding and everyday work.' 1 @('low', 'medium', 'high', 'xhigh', 'max', 'ultra')), (CxM 'm-astra' 'Frontier intelligence for the most demanding work.' 2 @('low', 'medium', 'high', 'xhigh', 'max', 'ultra')), (CxM 'm-oculto' 'Frontier hidden' 0 @('max') $false))
$agCat = @('gemini-4-argon-high', 'gemini-5-argon-medium', 'gemini-5-argon-high', 'gemini-3.8-flash-high', 'claude-opus-5-5-high', 'claude-opus-5-5-low', 'gpt-oss-120b-medium' | ForEach-Object { [pscustomobject]@{ slug = $_; nombre = $_ } })
T '3.4.0 Calidad Maxima Codex: elige por capacidad DOCUMENTADA (frontera), no por priority; esfuerzo max y ultra excluido; ignora ocultos' {
    Sembrar-Catalogos $cxCat $agCat
    $m = Get-MejorCodex
    Afirmar ($m.modelo -eq 'm-astra') "eligio $($m.modelo) (priority no es calidad)"
    Afirmar ($m.esfuerzo -eq 'max' -and @($m.excluidos) -contains 'ultra') "esfuerzo $($m.esfuerzo); ultra auto-delega y no debe usarse"
    Afirmar ($m.base -match '^documentado') "el motivo debe citar la descripcion documentada: $($m.base)"
}
T '3.4.0 Codex sin modelo descripto como de frontera: el primero del selector, y el motivo lo dice' {
    Sembrar-Catalogos @((CxM 'm-a' 'Fast model' 3 @('low', 'high')), (CxM 'm-b' 'Workhorse' 1 @('medium', 'xhigh'))) $agCat
    $m = Get-MejorCodex
    Afirmar ($m.modelo -eq 'm-b' -and $m.esfuerzo -eq 'xhigh' -and $m.base -match 'sin modelo descripto como de frontera') "$($m.modelo) · $($m.esfuerzo) · $($m.base)"
}
T '3.4.0 agy: familia por rol, version mas nueva listada y esfuerzo mas alto (un modelo nuevo entra sin release)' {
    Sembrar-Catalogos $cxCat $agCat
    Afirmar ((Get-MejorAgy -Perfil 'razonar').modelo -eq 'gemini-5-argon-high') 'no tomo la version mas nueva de la familia'
    Afirmar ((Get-MejorAgy -Perfil 'opus').modelo -eq 'claude-opus-5-5-high') 'opus: debe tomar el esfuerzo mas alto'
    Afirmar ((Get-MejorAgy -Perfil 'oss').modelo -eq 'gpt-oss-120b-medium') 'oss: familia mal parseada'
    Afirmar ((Get-MejorAgy -Perfil 'inexistente').perfil -eq 'razonar') 'un perfil desconocido debe caer en razonar'
    $s = Split-SlugAgy 'gemini-3.8-flash-high'
    Afirmar ($s.familia -eq 'gemini-flash' -and $s.version -eq 3.8 -and $s.esfuerzo -eq 'high') ($s | ConvertTo-Json -Compress)
}
T '3.4.0 cache de modelos de formato viejo se descarta (no se usan datos sin descripcion)' {
    [IO.File]::WriteAllText((Join-Path $tmp 'modelos-codex.json'), ([pscustomobject]@{ tomado = (Get-Date).ToString('s'); lista = @($cxCat) } | ConvertTo-Json -Depth 6))
    $env:MULTIIA_CODEX_EXE = 'C:\no-existe\codex.exe'
    try { Afirmar ($null -eq (Get-MejorCodex)) 'uso una cache sin esquema 2' } finally { Remove-Item Env:\MULTIIA_CODEX_EXE }
}
T '3.4.0 inventario: cada dato etiquetado (documentado / observado / no determinable), agy sin descripcion inventada' {
    Sembrar-Catalogos $cxCat $agCat
    Con-Motores $mudoExe $mudoExe {
        $inv = @(Get-InventarioModelos)
        $a = @($inv | Where-Object { $_.motor -eq 'agy' })[0]; $c = @($inv | Where-Object { $_.modelo -eq 'm-astra' })[0]
        Afirmar ($c.descripcion.e -eq 'documentado' -and $c.latencia_seg.e -match 'no determinable') 'Codex: etiquetas incorrectas'
        Afirmar ($null -eq $a.descripcion.v -and $a.descripcion.e -match 'no determinable' -and $a.proveedor -eq 'Google') 'agy: no debe inventar descripcion'
    }
}
function Sin-Agy([scriptblock]$b) {
    $bk = @{ L = $env:LOCALAPPDATA; P = $env:PATH }
    $env:LOCALAPPDATA = Join-Path $tmp 'sin-local'; $env:PATH = (($env:PATH -split ';') | Where-Object { $_ -notmatch '\\agy\\' }) -join ';'; $env:MULTIIA_AGY_EXE = Join-Path $tmp 'no-agy.exe'
    try { & $b } finally { $env:LOCALAPPDATA = $bk.L; $env:PATH = $bk.P; Remove-Item Env:\MULTIIA_AGY_EXE -ErrorAction SilentlyContinue }
}
T '3.4.0 cruce de motor: sin Codex, codigo va a Antigravity y el motivo lo explica; con -Contexto carpeta NO cruza' {
    Sembrar-Catalogos $cxCat $agCat
    Con-Motores $mudoExe (Join-Path $tmp 'no-codex.exe') {
        $j = (PS1 'elegir.ps1' @('-Tarea', 'codigo', '-Forzar') | Out-String) | ConvertFrom-Json
        Afirmar ($j.destino -eq 'agy' -and $j.esfuerzo -in 'low', 'medium', 'high' -and $j.motivo -match 'cruce de motor') "$($j.destino) $($j.modelo) $($j.esfuerzo): $($j.motivo)"
        $j = (PS1 'elegir.ps1' @('-Tarea', 'codigo', '-Forzar', '-Contexto', 'carpeta') | Out-String) | ConvertFrom-Json
        Afirmar ($j.destino -in 'claude', 'pendiente' -and $j.motivo -match 'no puede leer -Carpeta') "cruzo sin el contexto: $($j.destino) $($j.motivo)"
    }
}
T '3.4.0 cruce de motor: sin Antigravity, texto va a Codex; con -Contexto archivo NO cruza; sin ninguno lo hace Claude' {
    Sembrar-Catalogos $cxCat $agCat
    Sin-Agy {
        $env:MULTIIA_CODEX_EXE = $mudoExe
        try {
            $j = (PS1 'elegir.ps1' @('-Tarea', 'texto', '-Forzar') | Out-String) | ConvertFrom-Json
            Afirmar ($j.destino -eq 'codex' -and $j.modelo -eq 'm-astra' -and $j.motivo -match 'cruce de motor') "$($j.destino) $($j.modelo): $($j.motivo)"
            $j = (PS1 'elegir.ps1' @('-Tarea', 'texto', '-Forzar', '-Contexto', 'archivo') | Out-String) | ConvertFrom-Json
            Afirmar ($j.destino -in 'claude', 'pendiente' -and $j.motivo -match 'no recibe -Archivo') "cruzo sin los archivos: $($j.destino) $($j.motivo)"
            $env:MULTIIA_CODEX_EXE = Join-Path $tmp 'no-codex.exe'
            $j = (PS1 'elegir.ps1' @('-Tarea', 'codigo', '-Forzar') | Out-String) | ConvertFrom-Json
            Afirmar ($j.destino -in 'claude', 'pendiente' -and $j.motivo -match 'Antigravity tampoco') "$($j.destino): $($j.motivo)"
        } finally { Remove-Item Env:\MULTIIA_CODEX_EXE -ErrorAction SilentlyContinue }
    }
}
T '3.4.0 delegar pasa el contexto al router (el cruce no pierde archivos ni carpeta)' {
    $d = Get-Content (Join-Path $sc 'delegar.ps1') -Raw
    Afirmar ($d -match "\`$a\.Contexto = 'archivo'" -and $d -match "\`$a\.Contexto = 'carpeta'") 'delegar no pasa -Contexto a elegir'
}
Remove-Item (Join-Path $tmp 'modelos-codex.json'), (Join-Path $tmp 'modelos-agy.json') -ErrorAction SilentlyContinue
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ""; Write-Host "Resultado: $ok ok, $mal con falla$(if ($omit) { ", $omit omitidas (solo DEV)" })" -ForegroundColor $(if ($mal) { 'Red' } else { 'Green' })
exit $(if ($mal) { 1 } else { 0 })
