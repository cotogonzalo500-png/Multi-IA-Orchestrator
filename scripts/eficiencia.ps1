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
# 3.3.2: RECUPERACION DE TAREAS por TAREA UNICA (no por evento/intento). Tarea = id base sin el sufijo '-r'.
#  recuperada comprobable = el reintento '<id>-r' tiene 'fin' CON tokens > 0 y su decision (decisiones.jsonl) dice ok. "Recuperada" = otro motor termino y devolvio respuesta; NO valida el contenido.
#  no verificable        = el reintento tiene 'fin' pero sin tokens o sin decision coincidente.
#  sin resolver          = la tarea fallo y ningun reintento termino. Las anotaciones NO destructivas (anotaciones-auditoria.json: {"<id>":{"clase":"prueba|historico","nota":"..."}}) separan pruebas mal etiquetadas (se excluyen) e historicas (se cuentan aparte). Los registros no se tocan.
$dec = @{}
$fd = Join-Path $script:DatosDir 'decisiones.jsonl'
if (Test-Path $fd) { foreach ($l in (Get-Content $fd -Encoding UTF8 -ErrorAction SilentlyContinue)) { if ($l.Trim()) { try { $x = $l | ConvertFrom-Json; if ($x.id) { $dec[[string]$x.id] = [string]$x.resultado } } catch { } } } }
$anot = @{}
$fa = Join-Path $script:DatosDir 'anotaciones-auditoria.json'
if (Test-Path $fa) { try { $aj = Get-Content $fa -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($p in $aj.PSObject.Properties) { $anot[$p.Name] = $p.Value } } catch { } }
$basesFalla = @($err | ForEach-Object { $_.id -replace '-r$', '' } | Sort-Object -Unique)
$tRecup = @(); $tNoVer = @(); $tSinRes = @(); $tPrueba = @(); $tHist = @()
foreach ($b in $basesFalla) {
    $a = $anot[$b]
    if ($a -and $a.clase -eq 'prueba') { $tPrueba += $b; continue }
    $fr = $finIds[$b + '-r']
    if ($fr) {
        if ([long]$fr.tok -gt 0 -and $dec[$b + '-r'] -eq 'ok') { $tRecup += $b } else { $tNoVer += $b }
    }
    elseif ($finIds.ContainsKey($b)) { }   # el primer intento figura terminado: no es una falla abierta
    else { $tSinRes += $b; if ($a -and $a.clase -eq 'historico') { $tHist += $b } }
}
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
if ($tRecup.Count -gt 0) { $rec += "$($tRecup.Count) tareas se recuperaron y terminaron bien tras cambiar de motor: el respaldo automatico esta funcionando." }
if ($tNoVer.Count -gt 0) { $rec += "$($tNoVer.Count) tareas cambiaron de motor sin evidencia comprobable de que terminaran bien (no cuentan como recuperadas)." }
if ($fin.Count -eq 0) { $rec += 'Sin delegaciones en el periodo: no hay datos para recomendar mas.' }
$o = [ordered]@{
    dias = $Dias; exitosas = $fin.Count; exitosas_con_tokens = $util.Count; directas_justificadas = $just.Count; oportunidades_perdidas = $perd.Count
    fallidas = $fallidas.Count; fallas_recuperadas = $recup.Count; tokens_delegados = $tokDeleg; sobrecosto_por_delegacion = $SOBRECOSTO
    tareas_con_falla_inicial = $basesFalla.Count - $tPrueba.Count; tareas_recuperadas = $tRecup.Count; tareas_recuperacion_no_verificable = $tNoVer.Count
    tareas_sin_resolver = $tSinRes.Count; tareas_sin_resolver_historicas = $tHist.Count; tareas_de_prueba_excluidas = $tPrueba.Count
    ahorro_neto_estimado = $neto; elegibles = $elegibles; tasa_delegacion_util = $tasa; recomendaciones = $rec
    metodologia = 'ahorro neto = tokens delegados exitosos - 400 x delegaciones - tokens de fallidas (estimado, no medido en Claude)'
}
if ($Json) { $o | ConvertTo-Json -Depth 4 -Compress } else {
    "EFICIENCIA DE ORQUESTACION (ultimos $Dias dias)"
    "A exitosas: $($fin.Count) ($($util.Count) con tokens)   B directas justificadas: $($just.Count)   C oportunidades perdidas: $($perd.Count)"
    "D fallidas: $($fallidas.Count) (recuperadas por cambio de motor: $($recup.Count))"
    "RECUPERACION (tareas unicas): con falla inicial $($basesFalla.Count - $tPrueba.Count) · recuperadas comprobables $($tRecup.Count) · no verificables $($tNoVer.Count) · sin resolver $($tSinRes.Count) (historicas $($tHist.Count)) · pruebas excluidas $($tPrueba.Count)"
    "E ahorro neto estimado: $neto tokens (delegados $tokDeleg - sobrecosto $($SOBRECOSTO * $fin.Count) - fallidas $tokFall)"
    "F tasa de delegacion util: $(if ($null -ne $tasa) { "$tasa % ($($util.Count)/$elegibles)" } else { 'sin datos' })"
    "G recomendaciones:"; $rec | ForEach-Object { " - $_" }
}
exit 0