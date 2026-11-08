# Consumo agregado por sesion y global (JSON). Fuente: registro de uso (uso) + costo-claude.jsonl.
#   .\consumo.ps1 [-Sesion <id>] [-Texto]
# Honestidad de datos:
#   - tokens de los motores delegados (tok_in/tok_out): REPORTADOS por la CLI del proveedor (Codex / Antigravity). Si la CLI no los informo valen 0 y la fila se cuenta en 'sin_dato'.
#   - 'claude_estimado_tok': ESTIMACION local (~4 caracteres por token) de lo que le costo a Claude escribir/leer delegaciones. No es dato oficial.
#   - No hay costo en dinero: las suscripciones (ChatGPT Plus, Google, Claude) no exponen precio por token, asi que no se inventa uno.
#   - Cada fila de uso se cuenta UNA sola vez: el total global es la suma de las sesiones (sin_sesion incluida), asi no se duplica.
param([string]$Sesion = '', [switch]$Texto)
. (Join-Path $PSScriptRoot '_comun.ps1')

$uso = @(Get-Uso)
$ev = @()
$fe = Join-Path $script:DatosDir 'eventos.jsonl'
if (Test-Path -LiteralPath $fe) { $ev = @(Get-Content -LiteralPath $fe -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { $_ -and (Test-Productivo $_) }) }

function Resumir($filas) {
    $filas = @($filas)
    $ti = 0L; $to = 0L; $seg = 0.0; $err = 0; $sd = 0; $nSeg = 0
    foreach ($f in $filas) {
        $a = [long]$f.tok_in; $b = [long]$f.tok_out   # null => 0 solo para sumar: el estado (tok_estado) dice si es dato o faltante
        if ($null -ne $f.seg -and "$($f.seg)" -ne '') { $seg += [double]$f.seg; $nSeg++ }   # 2.3.0 (auditoria Codex): una duracion ausente no baja el promedio
        if ($f.salida -ne 0) { $err++ }
        if ((Get-EstadoTokens $f) -eq 'informado') { $ti += $a; $to += $b } else { $sd++ }
    }
    [ordered]@{
        pedidos = $filas.Count; tok_in = $ti; tok_out = $to; tok_total = $ti + $to
        seg_total = [math]::Round($seg, 1); seg_medio = $(if ($nSeg) { [math]::Round($seg / $nSeg, 1) } else { 0 })
        errores = $err; sin_dato = $sd
        # 1.9.0: nivel de confianza (un 0 con sin_dato = la CLI no informo, NO es consumo cero)
        tok_nivel = $(if ($filas.Count -eq 0 -or $sd -eq $filas.Count) { 'NO DISPONIBLE' } else { 'OBSERVADO' })
        tok_parcial = [bool]($sd -gt 0 -and $sd -lt $filas.Count)
        tok_por_estado = (Get-ConteoEstadoTokens $filas)   # 1.9.1: informado (incl. cero verificado) / estimado / ausente / desconocido / fuente-no-disponible
    }
}
function Agrupar($filas, [scriptblock]$clave) {
    $h = [ordered]@{}
    foreach ($g in (@($filas) | Group-Object -Property $clave | Sort-Object Name)) { $h[$(if ($g.Name) { $g.Name } else { 'sin-dato' })] = Resumir $g.Group }
    $h
}
function Desde($filas, [datetime]$d0) { @($filas | Where-Object { try { [datetime]::Parse($_.fecha) -ge $d0 } catch { $false } }) }

# Cada fila cuenta en UNA sola sesion ('sin-sesion' = filas viejas o delegaciones lanzadas fuera de Claude).
$ses = [ordered]@{}
$conId = @($uso | ForEach-Object { $_ | Add-Member -NotePropertyName sid -NotePropertyValue $(if ($_.sesion) { [string]$_.sesion } else { 'sin-sesion' }) -Force -PassThru })
foreach ($g in ($conId | Group-Object sid)) {
    $filas = @($g.Group)
    $r = Resumir $filas
    $r.ventana = [string](@($filas | Where-Object { $_.ventana } | Select-Object -Last 1).ventana)
    $r.instancia = [string](@($filas | Where-Object { $_.instancia } | Select-Object -Last 1).instancia)
    $r.primera = [string]($filas | Select-Object -First 1).fecha
    $r.ultima = [string]($filas | Select-Object -Last 1).fecha
    $r.por_motor = Agrupar $filas { $_.destino }
    $r.por_modelo = Agrupar $filas { $_.modelo }
    $r.cambios_de_motor = [math]::Max(0, @($filas | ForEach-Object { $_.destino } | Get-Unique).Count - 1)
    $r.errores_eventos = @($ev | Where-Object { $_.sesion -eq $g.Name -and $_.tipo -eq 'error' }).Count
    $r.id_chat = $g.Name   # 1.9.0: mismo id que chats.ps1 (CLAUDE_CODE_SESSION_ID); 'sin-sesion' = fuera de un chat
    $ses[$g.Name] = $r
}
if ($Sesion) { $ses = [ordered]@{ $Sesion = $ses[$Sesion] } }

$hoy = (Get-Date).Date
$global = Resumir $conId
$global.por_motor = Agrupar $conId { $_.destino }
$global.por_modelo = Agrupar $conId { $_.modelo }
$global.por_cuenta = Agrupar $conId { $_.cuenta }
$global.hoy = Resumir (Desde $conId $hoy)
$global.semana = Resumir (Desde $conId $hoy.AddDays(-6))
$global.mes = Resumir (Desde $conId $hoy.AddDays(-29))
$global.sesiones = $ses.Count

# Estimacion de lo que gasto Claude (no oficial).
$cc = $null; $fc = Join-Path $script:DatosDir 'costo-claude.jsonl'   # 2.3.0 (auditoria Codex): sin archivo = sin dato (null), no 0
if (Test-Path -LiteralPath $fc) { $cc = [long](Get-CostoClaude) }

$o = [ordered]@{
    generado = (Get-Date).ToString('s')
    nota = 'Tokens de motores delegados = reportados por la CLI del proveedor (0 = la CLI no los informo). claude_estimado_tok = estimacion local, no oficial. Sin costo en dinero: las suscripciones no exponen precio por token.'
    global = $global
    claude_estimado_tok = $cc
    sesiones = $ses
}
if ($Texto) {
    "CONSUMO GLOBAL: $($global.pedidos) pedidos · $($global.tok_total) tok (in $($global.tok_in) / out $($global.tok_out)) · $($global.sesiones) sesion(es) · errores $($global.errores) · sin dato de tokens: $($global.sin_dato)"
    "  hoy $($global.hoy.tok_total) · 7 dias $($global.semana.tok_total) · 30 dias $($global.mes.tok_total) · Claude (estimado) $(if ($null -eq $cc) { 'sin dato' } else { $cc })"
    foreach ($k in $ses.Keys) { $s = $ses[$k]; "  sesion $k : $($s.pedidos) pedidos · $($s.tok_total) tok · $($s.errores) err · $($s.seg_medio) s medio" }
} else { $o | ConvertTo-Json -Depth 8 -Compress }
exit 0
