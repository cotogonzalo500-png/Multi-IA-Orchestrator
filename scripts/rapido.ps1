# Lectura RAPIDA para el panel (sin consultar cupos): config, consola de eventos y contador total de tokens. Tarda ~1 s.
param([switch]$ConCache, [string]$Desde = '')
. (Join-Path $PSScriptRoot '_comun.ps1')
$cfg = Get-Config
$ev = @()
$f = Join-Path $script:DatosDir 'eventos.jsonl'
if (Test-Path -LiteralPath $f) { $ev = @(Get-Content -LiteralPath $f -Encoding UTF8 -Tail 45 | Where-Object { $_.Trim() } | ForEach-Object { try { $_ | ConvertFrom-Json } catch { $null } } | Where-Object { $_ }) }
$uso = Get-Uso
# Con -ConCache devuelve tambien la ultima lectura de cupos guardada (aunque sea vieja) para pintar el panel al instante.
$extra = [ordered]@{}
$cf = Join-Path $script:DatosDir 'limites-cache.json'
if (Test-Path -LiteralPath $cf) {
    $extra.cache_seg = [int]((Get-Date) - (Get-Item -LiteralPath $cf).LastWriteTime).TotalSeconds
    if ($ConCache) {
        try { $c = (Get-Content -LiteralPath $cf -Raw -Encoding UTF8) | ConvertFrom-Json; $extra.tarjetas = @($c.tarjetas); $extra.horas = @($c.horas); $extra.pesada = $c.pesada } catch { }
    }
}
$salida = [ordered]@{
    motores = @(Get-Motores)
    activo = ($cfg.activo -ne $false); calidad = $cfg.calidad; modo = $cfg.modo; manual = $cfg.manual
    deleg_total = [long](Sumar-Tok $uso); deleg_n = @($uso).Count; claude_costo = [long](Get-CostoClaude)
    eventos = @($ev | ForEach-Object { [ordered]@{ f = $_.fecha; t = $_.tipo; d = $_.destino; x = $_.detalle; m = $_.motivo; k = $_.tarea; tok = [long]$_.tok; s = $_.seg; i = [string]$_.id; c = [string]$_.conf; o = $(if ($_.origen) { [string]$_.origen } else { 'real' }) } })
}
# Con -Desde (inicio de la sesion actual): lo delegado y lo que costo a Claude desde entonces.
if ($Desde) {
    try {
        $d0 = [datetime]::Parse($Desde)
        $uso_s = @($uso | Where-Object { try { [datetime]::Parse($_.fecha) -ge $d0 } catch { $false } })
        $cs = 0L
        $cf2 = Join-Path $script:DatosDir 'costo-claude.jsonl'
        if (Test-Path -LiteralPath $cf2) {
            foreach ($l in (Get-Content -LiteralPath $cf2 -Encoding UTF8 | Where-Object { $_.Trim() })) {
                try { $o = $l | ConvertFrom-Json } catch { continue }
                if (-not (Test-Productivo $o)) { continue }
                try { if ([datetime]::Parse($o.fecha) -ge $d0) { $cs += [long]$o.tok } } catch { }
            }
        }
        $extra.ses_deleg = [long](Sumar-Tok $uso_s); $extra.ses_n = $uso_s.Count; $extra.ses_costo = $cs
    } catch { }
}
foreach ($k in $extra.Keys) { $salida[$k] = $extra[$k] }
# Consumo global compacto (tokens reportados por las CLI; detalle por sesion/modelo en consumo.ps1). Cada fila cuenta una sola vez.
$hoy0 = (Get-Date).Date
$salida.glob = [ordered]@{
    ses = @($uso | ForEach-Object { if ($_.sesion) { $_.sesion } else { 'sin-sesion' } } | Sort-Object -Unique).Count
    tin = [long](($uso | Measure-Object -Property tok_in -Sum).Sum); tout = [long](($uso | Measure-Object -Property tok_out -Sum).Sum)
    hoy = [long](Sumar-Tok @($uso | Where-Object { try { [datetime]::Parse($_.fecha) -ge $hoy0 } catch { $false } }))
    semana = [long](Sumar-Tok @($uso | Where-Object { try { [datetime]::Parse($_.fecha) -ge $hoy0.AddDays(-6) } catch { $false } }))
    mes = [long](Sumar-Tok @($uso | Where-Object { try { [datetime]::Parse($_.fecha) -ge $hoy0.AddDays(-29) } catch { $false } }))
    codex = [long](Sumar-Tok @($uso | Where-Object { $_.destino -eq 'codex' })); agy = [long](Sumar-Tok @($uso | Where-Object { $_.destino -eq 'agy' }))
    errores = @($uso | Where-Object { $_.salida -ne 0 }).Count
    sin_dato = @($uso | Where-Object { (Get-EstadoTokens $_) -ne 'informado' }).Count
    por_estado = (Get-ConteoEstadoTokens $uso)
}
# Serie diaria REAL de 30 dias (tokens delegados por motor segun uso.jsonl y costo estimado de coordinar a Claude segun costo-claude.jsonl). Dias sin registros = 0; nada inventado.
$dias = [ordered]@{}
for ($n = 29; $n -ge 0; $n--) { $dias[$hoy0.AddDays(-$n).ToString('yyyy-MM-dd')] = [ordered]@{ d = $hoy0.AddDays(-$n).ToString('MM-dd'); codex = 0L; agy = 0L; costo = 0L; n = 0 } }
foreach ($u in $uso) {
    try { $k = ([datetime]::Parse($u.fecha)).ToString('yyyy-MM-dd') } catch { continue }
    if (-not $dias.Contains($k)) { continue }
    $t = [long]$u.tok_in + [long]$u.tok_out
    if ($u.destino -eq 'codex') { $dias[$k].codex += $t } elseif ($u.destino -eq 'agy') { $dias[$k].agy += $t }
    $dias[$k].n++
}
$cf3 = Join-Path $script:DatosDir 'costo-claude.jsonl'
if (Test-Path -LiteralPath $cf3) {
    foreach ($l in (Get-Content -LiteralPath $cf3 -Encoding UTF8 | Where-Object { $_.Trim() })) {
        try { $o = $l | ConvertFrom-Json; if (-not (Test-Productivo $o)) { continue }; $k =([datetime]::Parse($o.fecha)).ToString('yyyy-MM-dd'); if ($dias.Contains($k)) { $dias[$k].costo += [long]$o.tok } } catch { }
    }
}
$salida.dias = @($dias.Values)
# Presupuesto diario (0 = sin tope), cache de resultados y victorias humanas de la arena.
$ah = $cfg.ahorro
$tope = if ($ah -and $ah.tope_diario_tok) { [long]$ah.tope_diario_tok } else { 0 }
$ganan = @{}
$af = Join-Path $script:DatosDir 'arena.jsonl'
if (Test-Path -LiteralPath $af) {
    foreach ($l in (Get-Content -LiteralPath $af -Encoding UTF8 | Where-Object { $_.Trim() })) { try { $o = $l | ConvertFrom-Json; if ($o.ganador) { $ganan[$o.ganador] = 1 + [int]$ganan[$o.ganador] } } catch { } }
}
$cd = Join-Path $script:DatosDir 'cache'
$salida.presup = [ordered]@{
    tope = $tope; hoy = $salida.glob.hoy; aviso = $(if ($ah -and $ah.aviso_pct) { [int]$ah.aviso_pct } else { 80 })
    cache = $(if (Test-Path -LiteralPath $cd) { @(Get-ChildItem -LiteralPath $cd -Filter *.json -ErrorAction SilentlyContinue).Count } else { 0 })
    arena = @($ganan.Keys | Sort-Object | ForEach-Object { "$_ $($ganan[$_])" }) -join ' · '
}
$salida | ConvertTo-Json -Depth 8 -Compress
exit 0