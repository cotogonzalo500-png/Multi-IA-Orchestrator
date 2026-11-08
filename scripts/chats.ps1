# Registro de chats y consumo POR CHAT (1.9.0). JSON por defecto, -Texto para leer.
#   .\chats.ps1 [-Chat <id>|actual] [-Estado todos|activos|anteriores] [-SinClaude] [-Texto]
# Reglas (no mostrar mas certeza de la que hay):
#   - ID del chat = CLAUDE_CODE_SESSION_ID (estable, persiste al reanudar: el historial de un id nunca se pierde). El titulo NUNCA es id.
#   - El registro se DERIVA de los archivos reales (uso, eventos, costo-claude, transcripts de Claude): no hay un indice aparte que pueda desincronizarse.
#   - Consumo separado por proveedor y nunca sumado entre proveedores (unidades y cuentas distintas):
#       Claude real      = tokens de los transcripts locales de ESE chat (VERIFICADO)         -> kind claude_real
#       Claude estimado  = ~4 caracteres/token de lo que costo coordinar delegaciones (ESTIMADO) -> subconjunto del real: NO se suma al real (sin doble conteo)
#       Codex / Antigravity = tok_in+tok_out que informo la CLI (VERIFICADO); filas sin dato => parcial, nunca 0
#   - Solo origen real cuenta. test/simulacion/benchmark/desarrollo/diagnostico se informan APARTE (no_real) y no entran a ningun total.
#   - Ejecuciones activas: por id de ejecucion de eventos reales (dos procesos != dos tareas). Sin evento reciente => 'ultimo observado', nunca 'inactivo'.
param([string]$Chat = '', [ValidateSet('todos', 'activos', 'anteriores')][string]$Estado = 'todos', [switch]$SinClaude, [switch]$Texto, [ValidateSet('json', 'md')][string]$Formato = 'json', [switch]$Guardar)
. (Join-Path $PSScriptRoot '_comun.ps1')
Initialize-Datos
# -Guardar: escribe el resultado en .multi-ia-orquestador\exportaciones (sin pisar exportaciones anteriores) y muestra solo la ruta.
function Salida([string]$texto, [string]$ext) {
    if (-not $Guardar) { $texto; return }
    $dir = Join-Path $script:DatosDir 'exportaciones'; New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $ruta = Join-Path $dir ("chats-{0}-{1}.{2}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $PID, $ext)
    [IO.File]::WriteAllText($ruta, $texto, (New-Object Text.UTF8Encoding($false)))
    "Exportado: $ruta"
}
if ($Chat -eq 'actual') { $Chat = [string]$env:CLAUDE_CODE_SESSION_ID }
$SIN = 'sin-sesion'

function Leer-Jsonl($nombre) {
    $f = Join-Path $script:DatosDir $nombre
    if (-not (Test-Path -LiteralPath $f)) { return @() }
    @(Get-Content -LiteralPath $f -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { $_ })
}
function Sid($x) { if ($x.sesion) { [string]$x.sesion } else { $SIN } }

$usoTodo = @(Get-Uso -Todo)
$ev = @(Leer-Jsonl $(if (Test-Path -LiteralPath (Join-Path $script:DatosDir 'eventos-hist.jsonl')) { 'eventos-hist.jsonl' } else { 'eventos.jsonl' }))
$costo = @(Leer-Jsonl 'costo-claude.jsonl')
$msgs = if ($SinClaude) { @() } else { @(Get-MensajesClaude) }
# Agrupar una sola vez (filtrar 7000 mensajes por cada chat con Where-Object tardaba ~8 s)
$msgPorChat = @{}
foreach ($m in $msgs) { $k = [string]$m.sesion_completa; if (-not $msgPorChat.ContainsKey($k)) { $msgPorChat[$k] = New-Object Collections.Generic.List[object] }; $msgPorChat[$k].Add($m) }

# --- Ejecuciones: una por id de evento (varios eventos del mismo id = UNA tarea). Estado por el ULTIMO evento y su frescura.
function Get-Ejecuciones($eventos) {
    $res = @()
    foreach ($g in (@($eventos | Where-Object { $_.id }) | Group-Object id)) {
        $f = @($g.Group | Sort-Object fecha); $u = $f[-1]
        # Un evento terminal (fin/error) manda sobre uno de la misma fecha (el orden de empates no es fiable)
        $term = @($f | Where-Object { $_.tipo -in 'fin', 'error' -and $_.fecha -ge $u.fecha } | Select-Object -Last 1)
        if ($term.Count) { $u = $term[0] }
        $fin = ($u.tipo -in 'fin', 'error')
        $fr = Get-Frescura -Fecha $u.fecha -Fuente 'evento'
        $estado = if ($fin) { if ($u.tipo -eq 'fin') { 'terminada' } else { 'con error' } } else { $fr.estado }   # abierta: la frescura dice si hay senal reciente
        $conf = @($f | Where-Object { $_.tipo -eq 'confirmado' -or $_.conf }).Count -gt 0
        $res += [ordered]@{
            id_ejecucion = [string]$g.Name; id_chat = (Sid $u); motor = [string]$u.destino; origen = [string]$(if ($u.origen) { $u.origen } else { 'real' })
            estado = $estado; abierta = (-not $fin); confirmada_por_cli = $conf; ultimo_evento = [string]$u.tipo; fecha = [string]$u.fecha
            frescura = $fr.estado; edad_seg = $fr.edad_seg; clase = [string]$u.clase; causa = [string]$u.causa
            tarea = [string](@($f | Where-Object { $_.tarea } | Select-Object -Last 1).tarea)
            modelo = [string](@($f | Where-Object { $_.modelo_conf } | Select-Object -Last 1).modelo_conf)
            inicio = [string]$f[0].fecha
            duracion_seg = $(if ($fin -and $u.seg) { [double]$u.seg } else { [math]::Round(((Get-Date) - [datetime]$f[0].fecha).TotalSeconds, 0) })
            duracion_nivel = $(if ($fin -and $u.seg) { 'OBSERVADO' } else { 'ESTIMADO' })   # abierta: ahora - inicio, no una medicion de la CLI
            fuente = 'eventos.jsonl (registrados por delegar.ps1)'
        }
    }
    $res
}
$ejec = @(Get-Ejecuciones $ev)
$ejecReal = @($ejec | Where-Object { $_.origen -eq 'real' })

# --- Ids de chat conocidos (de TODAS las fuentes reales)
$ids = @{}
foreach ($x in @($usoTodo) + @($ev) + @($costo)) { $ids[(Sid $x)] = $true }
foreach ($m in $msgs) { if (-not $m.sub -or $m.sesion_completa) { $ids[[string]$m.sesion_completa] = $true } }
if ($Chat) { $ids = @{ $Chat = $true } }

# 2.0.1: agrupar uso/eventos/costo/ejecuciones UNA vez por chat (antes cada chat los recorria enteros con Where-Object).
function Agrupar-PorChat($Items, [scriptblock]$Clave) {
    $h = @{}
    foreach ($i in $Items) { $k = [string](& $Clave $i); if (-not $h.ContainsKey($k)) { $h[$k] = New-Object Collections.Generic.List[object] }; $h[$k].Add($i) }
    $h
}
$usoPorChat = Agrupar-PorChat $usoTodo { param($x) Sid $x }
$evPorChat = Agrupar-PorChat $ev { param($x) Sid $x }
$costoPorChat = Agrupar-PorChat $costo { param($x) Sid $x }
$ejecPorChat = Agrupar-PorChat $ejecReal { param($x) $x.id_chat }
function De-Grupo($H, [string]$id) { if ($H.ContainsKey($id)) { return $H[$id].ToArray() } else { return @() } }

function Resumen-Chat([string]$id) {
    $uAll = @(De-Grupo $usoPorChat $id)
    $uReal = @($uAll | Where-Object { Test-Productivo $_ })
    $noReal = @($uAll | Where-Object { -not (Test-Productivo $_) })
    $eAll = @(De-Grupo $evPorChat $id)
    $cReal = @(De-Grupo $costoPorChat $id | Where-Object { Test-Productivo $_ })
    $mc = if ($msgPorChat.ContainsKey($id)) { $msgPorChat[$id].ToArray() } else { @() }

    $fechas = @(@($uReal | ForEach-Object { $_.fecha }) + @($eAll | Where-Object { Test-Productivo $_ } | ForEach-Object { $_.fecha }) + @($cReal | ForEach-Object { $_.fecha }) | Where-Object { $_ } | Sort-Object)
    # min/max lineal en vez de ordenar todos los mensajes del chat dos veces
    $tMin = $null; $tMax = $null
    foreach ($m in $mc) { if ($null -eq $tMin -or $m.t -lt $tMin) { $tMin = $m.t }; if ($null -eq $tMax -or $m.t -gt $tMax) { $tMax = $m.t } }
    $ultMsg = if ($mc.Count) { $tMax.ToLocalTime().ToString('s') } else { '' }
    $ultima = @($fechas + $ultMsg | Where-Object { $_ } | Sort-Object | Select-Object -Last 1)
    $primeraMsg = if ($mc.Count) { $tMin.ToLocalTime().ToString('s') } else { '' }
    $primera = @($fechas + $primeraMsg | Where-Object { $_ } | Sort-Object | Select-Object -First 1)

    $abiertas = @(De-Grupo $ejecPorChat $id | Where-Object { $_.abierta })
    $activasConf = @($abiertas | Where-Object { $_.frescura -eq 'activo confirmado' })
    $fr = Get-Frescura -Fecha ([string]$ultima[0]) -Fuente 'evento'
    $estadoChat = if ($activasConf.Count) { 'activo confirmado' } else { $fr.estado }

    $cod = @($uReal | Where-Object { $_.destino -eq 'codex' }); $agy = @($uReal | Where-Object { $_.destino -eq 'agy' })
    $real = $null
    if ($mc.Count) {
        $ent = [long](($mc | Measure-Object entrada -Sum).Sum); $cw = [long](($mc | Measure-Object cache_escritura -Sum).Sum)
        $cl = [long](($mc | Measure-Object cache_lectura -Sum).Sum); $sal = [long](($mc | Measure-Object salida -Sum).Sum)
        $real = [ordered]@{ valor = ($ent + $cw + $cl + $sal); unidad = 'tokens'; nivel = 'VERIFICADO'; mensajes = $mc.Count; entrada = $ent; cache_escritura = $cw; cache_lectura = $cl; salida = $sal
            fuente = 'transcripts locales de Claude Code (usage por mensaje), ultimos 8 dias'; aclaracion = 'Incluye lecturas de cache (relecturas del contexto), por eso supera a lo que "pesa" el chat. Ventana de 8 dias: un chat mas viejo puede estar incompleto' }
    } else { $real = [ordered]@{ valor = $null; unidad = 'tokens'; nivel = 'NO DISPONIBLE'; fuente = $(if ($SinClaude) { 'no consultado (-SinClaude)' } else { 'sin transcripts de este chat en los ultimos 8 dias' }) } }
    # 2.3.0 (auditoria Codex): solo filas con tok numerico; si falta en alguna, es PARCIAL; si falta en todas, no hay dato (no 0).
    $cNum = @($cReal | Where-Object { $null -ne $_.tok -and "$($_.tok)" -match '^\d+(\.\d+)?$' })
    $estClaude = if ($cNum.Count) { [ordered]@{ valor = [long](($cNum | Measure-Object tok -Sum).Sum); unidad = 'tokens'; nivel = 'ESTIMADO'; parcial = ($cNum.Count -lt $cReal.Count); delegaciones = $cReal.Count; fuente = 'costo-claude.jsonl (~4 caracteres/token de prompts y respuestas delegadas)'; aclaracion = 'Es parte del consumo real de Claude: NO se suma a el' } }
    else { [ordered]@{ valor = $null; unidad = 'tokens'; nivel = 'NO DISPONIBLE'; fuente = 'sin delegaciones registradas con este chat' } }

    [ordered]@{
        id_chat = $id; titulo = $null; titulo_nota = 'El titulo no se guarda: nunca se usa como id'
        primera = [string]$primera[0]; ultima = [string]$ultima[0]; estado = $estadoChat; frescura = $fr
        ejecuciones_activas = $abiertas.Count; ejecuciones_activas_confirmadas = $activasConf.Count
        delegaciones = $uReal.Count; errores = @($uReal | Where-Object { $_.salida -ne 0 }).Count
        consumo = [ordered]@{
            claude_real = $real; claude_estimado_delegaciones = $estClaude
            codex = (Get-TokensConNivel $cod); antigravity = (Get-TokensConNivel $agy)
            total = [ordered]@{ valor = $null; nivel = 'NO DISPONIBLE'; nota = 'No hay total unico: cada proveedor tiene su cuenta y su unidad de cupo; sumarlos mezclaria niveles de confiabilidad' }
        }
        no_real = [ordered]@{ filas = $noReal.Count; por_origen = @($noReal | Group-Object origen | ForEach-Object { "$($_.Name)=$($_.Count)" }); nota = 'Pruebas/simulaciones/diagnostico: informadas aparte, fuera de todo total' }
    }
}

$chats = @(foreach ($id in $ids.Keys) { Resumen-Chat $id })
$chats = @($chats | Sort-Object { $_.ultima } -Descending)
switch ($Estado) {
    'activos' { $chats = @($chats | Where-Object { $_.estado -eq 'activo confirmado' }) }
    'anteriores' { $chats = @($chats | Where-Object { $_.estado -ne 'activo confirmado' }) }
}
$actual = [string]$env:CLAUDE_CODE_SESSION_ID
$o = [ordered]@{
    generado = (Get-Date).ToString('s'); chat_actual = $(if ($actual) { $actual } else { $null }); filtro = $Estado
    chats = $chats
    ejecuciones_activas = @($ejecReal | Where-Object { $_.abierta })
    nota = 'Registro derivado de archivos reales. "activo confirmado" solo con una senal de los ultimos 120 s; sin senal = "ultimo observado" o "desactualizado", no "inactivo".'
}
# 1.9.1: diagnostico del parseo de transcripts. Lineas candidatas que NO se pudieron leer se informan (nunca una metrica de Claude sin aviso).
if (-not $SinClaude) {
    $dg = $script:DiagTranscripts
    $o.diagnostico_transcripts = [ordered]@{ esquema = $dg.esquema; cache = $dg.cache; candidatas = $dg.candidatas; contadas = $dg.contadas; descartadas = $dg.descartadas; motivos = $dg.motivos
        advertencia = $(if ($dg.descartadas -gt 0) { "$($dg.descartadas) linea(s) de transcript con uso de tokens no se pudieron leer ($(($dg.motivos.Keys | ForEach-Object { "$_=$($dg.motivos[$_])" }) -join ', ')): el total de Claude real puede estar SUBESTIMADO" } else { '' }) }
}
# Resumen GENERAL (suma por proveedor; nunca entre proveedores). Un chat sin dato NO suma 0: se cuenta aparte.
function Resumen-Proveedor($clave) {
    $con = @($chats | Where-Object { $null -ne $_.consumo.$clave.valor })
    $sin = $chats.Count - $con.Count
    [ordered]@{ valor = $(if ($con.Count) { [long](($con | ForEach-Object { [long]$_.consumo.$clave.valor } | Measure-Object -Sum).Sum) } else { $null })
        chats_con_dato = $con.Count; chats_sin_dato = $sin; niveles = @($con | ForEach-Object { $_.consumo.$clave.nivel } | Select-Object -Unique) }
}
$o.resumen_general = [ordered]@{
    chats = $chats.Count; chats_activos = @($chats | Where-Object { $_.estado -eq 'activo confirmado' }).Count
    delegaciones = [int](($chats | ForEach-Object { [int]$_.delegaciones } | Measure-Object -Sum).Sum); errores = [int](($chats | ForEach-Object { [int]$_.errores } | Measure-Object -Sum).Sum)
    claude_real = (Resumen-Proveedor 'claude_real'); claude_estimado_delegaciones = (Resumen-Proveedor 'claude_estimado_delegaciones')
    codex = (Resumen-Proveedor 'codex'); antigravity = (Resumen-Proveedor 'antigravity')
    nota = 'Suma por proveedor, nunca entre proveedores. Chats sin dato se cuentan aparte (no valen 0). Claude real cubre solo los ultimos 8 dias.'
}
$o.ejecuciones_activas_ahora = @($ejecReal | Where-Object { $_.abierta -and $_.frescura -eq 'activo confirmado' })
$o.ejecuciones_recientes = @($ejecReal | Sort-Object { $_.fecha } -Descending | Select-Object -First 40)   # para la consola del panel (filtrable por motor/estado/chat)
if ($Formato -eq 'md') {
    $r = $o.resumen_general
    $v = { param($x) if ($null -ne $x.valor) { "{0:N0} ({1})" -f $x.valor, (($x.niveles -join '/') + $(if ($x.chats_sin_dato) { "; $($x.chats_sin_dato) chats sin dato" } else { '' })) } else { 'NO DISPONIBLE' } }
    $md = @("# Multi-IA · Resumen de chats", "", "Generado: $($o.generado) · $($r.chats) chats · $($r.chats_activos) activos · $($r.delegaciones) delegaciones reales · $($r.errores) con error", "",
        "| Proveedor | Tokens | Detalle |", "|---|---|---|",
        "| Claude (real, transcripts) | $(& $v $r.claude_real) | VERIFICADO, ultimos 8 dias |",
        "| Claude (estimado en delegaciones) | $(& $v $r.claude_estimado_delegaciones) | ESTIMADO, parte del real: no se suma |",
        "| Codex | $(& $v $r.codex) | tokens informados por la CLI |",
        "| Antigravity | $(& $v $r.antigravity) | tokens informados por la CLI |", "", "## Por chat", "",
        "| Chat | Estado | Ultima | Claude real | Codex | Antigravity | Deleg. | Err. |", "|---|---|---|---|---|---|---|---|")
    foreach ($c in $chats) {
        $k = $c.consumo
        $f = { param($x) if ($null -ne $x.valor) { "{0:N0} [{1}]" -f $x.valor, $x.nivel } else { 's/d' } }
        $md += "| $($c.id_chat) | $($c.estado) | $($c.ultima) | $(& $f $k.claude_real) | $(& $f $k.codex) | $(& $f $k.antigravity) | $($c.delegaciones) | $($c.errores) |"
    }
    if ($o.diagnostico_transcripts -and $o.diagnostico_transcripts.advertencia) { $md += ""; $md += "> ⚠ $($o.diagnostico_transcripts.advertencia)" }
    $md += ""; $md += "_$($o.nota)_"
    Salida ($md -join "`n") 'md'; exit 0
}
if ($Texto) {
    foreach ($c in $chats) {
        $k = $c.consumo
        "{0}  [{1}]  ultima {2}" -f $c.id_chat, $c.estado, $c.ultima
        "   Claude real: {0} [{1}] · estimado deleg.: {2} [{3}] · Codex: {4} [{5}] · Antigravity: {6} [{7}]" -f `
            $(if ($null -ne $k.claude_real.valor) { $k.claude_real.valor } else { 's/d' }), $k.claude_real.nivel, `
            $(if ($null -ne $k.claude_estimado_delegaciones.valor) { $k.claude_estimado_delegaciones.valor } else { 's/d' }), $k.claude_estimado_delegaciones.nivel, `
            $(if ($null -ne $k.codex.valor) { $k.codex.valor } else { 's/d' }), $k.codex.nivel, `
            $(if ($null -ne $k.antigravity.valor) { $k.antigravity.valor } else { 's/d' }), $k.antigravity.nivel
    }
} else { Salida ($o | ConvertTo-Json -Depth 8 -Compress) 'json' }
exit 0
