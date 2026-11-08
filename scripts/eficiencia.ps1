# Eficiencia de orquestacion: mide con los eventos REALES (eventos.jsonl) cuanto rindio delegar. No inventa nada.
# Uso: eficiencia.ps1 [-Dias 30] [-Json]
# METODOLOGIA (documentada, ver CHANGELOG 1.6.0):
#  A exitosas      = ejecuciones con evento 'fin' (la CLI termino bien). No prueba que la tarea se cumplio: por eso F usa solo las que gastaron tokens > 0.
#  B directas      = 'sin-delegar' cuyo motivo dice trivial/chica/charla (verificable por el texto del motivo).
#  C perdidas      = 'sin-delegar' de tarea codigo/revision/resumen/analisis sin motivo de trivial/chica: se podia delegar y no se hizo.
#  D fallidas      = ejecuciones con 'error' que NO fueron recuperadas por un reintento '<id>-r' exitoso. Las recuperadas se cuentan aparte.
#  E ahorro neto   = tokens delegados exitosos - sobrecosto de orquestar (SOBRECOSTO tokens por delegacion, constante estimada) - tokens gastados en fallidas.
#                    Es una ESTIMACION: delegar no es ahorrar; asume que Claude habria gastado ~lo mismo haciendo la tarea.
#  F tasa util     = exitosas con tokens>0 / (exitosas + fallidas + perdidas). Solo cuenta tareas evaluadas, no las charlas triviales.
param([int]$Dias = 30, [switch]$Json)
. (Join-Path $PSScriptRoot '_comun.ps1')
$SOBRECOSTO = 400
# Fuente: historico largo (eventos-hist.jsonl) + eventos.jsonl (los anteriores al historico); sin duplicados. eventos.jsonl solo guarda 200-300 y subestimaria 30 dias.
$desde = (Get-Date).AddDays(-$Dias)
$todos = @(); $vistos = @{}
foreach ($nom in @('eventos-hist.jsonl', 'eventos.jsonl')) {
    $f = Join-Path $script:DatosDir $nom
    if (-not (Test-Path $f)) { continue }
    foreach ($l in (Get-Content $f -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if (-not $l.Trim()) { continue }
        try { $e = $l | ConvertFrom-Json } catch { continue }
        $k = "$($e.fecha)|$($e.tipo)|$($e.id)|$($e.destino)|$($e.tarea)|$($e.motivo)|$($e.detalle)"
        if ($vistos.ContainsKey($k)) { continue }
        $vistos[$k] = 1; $todos += $e
    }
}
# solo ejecuciones reales (origen real o sin campo) dentro del periodo
$ev = @($todos | Where-Object { (Test-Productivo $_) -and ((-not $_.fecha) -or ([datetime]$_.fecha -ge $desde)) })
$fin = @($ev | Where-Object { $_.tipo -eq 'fin' -and $_.id })
$err = @($ev | Where-Object { $_.tipo -eq 'error' -and $_.id })
$dir = @($ev | Where-Object { $_.tipo -eq 'sin-delegar' })
$finIds = @{}; foreach ($f in $fin) { $finIds[$f.id] = $f }
$recup = @($err | Where-Object { $finIds.ContainsKey($_.id + '-r') })
$fallidas = @($err | Where-Object { -not $finIds.ContainsKey($_.id + '-r') -and $_.id -notmatch '-r$' } ) + @($err | Where-Object { $_.id -match '-r$' })
$util = @($fin | Where-Object { [long]$_.tok -gt 0 })
$just = @($dir | Where-Object { $_.motivo -match '(?i)trivial|chica|charla|contexto de la charla' })
$perd = @($dir | Where-Object { $_.tarea -in @('codigo', 'revision', 'resumen', 'analisis') -and $_.motivo -notmatch '(?i)trivial|chica' })
$tokDeleg = [long](($util | Measure-Object tok -Sum).Sum)
$tokFall = [long](($err | Measure-Object tok -Sum).Sum)
$neto = $tokDeleg - ($SOBRECOSTO * $fin.Count) - $tokFall
$elegibles = $fin.Count + $fallidas.Count + $perd.Count
$tasa = if ($elegibles -gt 0) { [math]::Round(100.0 * $util.Count / $elegibles, 1) } else { $null }
$rec = @()
if ($perd.Count -gt 0) { $rec += "Hubo $($perd.Count) tareas de codigo/revision/resumen/analisis resueltas sin delegar: delegarlas con delegar.ps1." }
if ($fallidas.Count -gt 0) { $rec += "$($fallidas.Count) ejecuciones fallaron sin recuperarse: revisar la cuenta/CLI del proveedor." }
if ($recup.Count -gt 0) { $rec += "$($recup.Count) fallas se recuperaron cambiando de motor: el respaldo automatico esta funcionando." }
if ($fin.Count -eq 0) { $rec += 'Sin delegaciones en el periodo: no hay datos para recomendar mas.' }
$o = [ordered]@{
    dias = $Dias; exitosas = $fin.Count; exitosas_con_tokens = $util.Count; directas_justificadas = $just.Count; oportunidades_perdidas = $perd.Count
    fallidas = $fallidas.Count; fallas_recuperadas = $recup.Count; tokens_delegados = $tokDeleg; sobrecosto_por_delegacion = $SOBRECOSTO
    ahorro_neto_estimado = $neto; elegibles = $elegibles; tasa_delegacion_util = $tasa; recomendaciones = $rec
    metodologia = 'ahorro neto = tokens delegados exitosos - 400 x delegaciones - tokens de fallidas (estimado, no medido en Claude)'
}
if ($Json) { $o | ConvertTo-Json -Depth 4 -Compress } else {
    "EFICIENCIA DE ORQUESTACION (ultimos $Dias dias)"
    "A exitosas: $($fin.Count) ($($util.Count) con tokens)   B directas justificadas: $($just.Count)   C oportunidades perdidas: $($perd.Count)"
    "D fallidas: $($fallidas.Count) (recuperadas por cambio de motor: $($recup.Count))"
    "E ahorro neto estimado: $neto tokens (delegados $tokDeleg - sobrecosto $($SOBRECOSTO * $fin.Count) - fallidas $tokFall)"
    "F tasa de delegacion util: $(if ($null -ne $tasa) { "$tasa % ($($util.Count)/$elegibles)" } else { 'sin datos' })"
    "G recomendaciones:"; $rec | ForEach-Object { " - $_" }
}
exit 0