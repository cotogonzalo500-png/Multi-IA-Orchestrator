# Decide A QUIEN delegar y con que modelo/esfuerzo, segun el modo, la CALIDAD y el cupo. Imprime UN objeto JSON:
#   modo, calidad, destino, cuenta, perfil, modelo, esfuerzo, motivo, segundo (motor independiente para cruzar resultados; solo en calidad maxima).
#   .\elegir.ps1 -Tarea texto|trivial|razonar|opinion|codigo|revision [-Calidad economica|equilibrada|maxima] [-Critico] [-Dificil] [-ConCupo]
# destino: 'codex' | 'agy' | 'claude' (lo hace Claude: su propio cupo tiene margen) | 'pendiente' (no hay delegado ni margen en Claude: dejar pendiente y avisar).
# CALIDAD (modo automatico; por defecto la de config.json, 'equilibrada'):
#   economica   = lo mas barato que alcance (tareas faciles). OJO: un delegado flojo que Claude debe corregir cuesta MAS cupo de Claude que uno bueno.
#   equilibrada = buen motor, esfuerzo medio (recomendada para uso diario).
#   maxima      = el mejor motor de cada IA con esfuerzo alto + un SEGUNDO motor de otro proveedor para cruzar/revisar. Para proyectos criticos (dinero, seguridad).
#                 -Critico equivale a -Calidad maxima. En maxima NUNCA se baja de motor por falta de cupo: se avisa.
# MANUAL: devuelve lo que eligio el usuario; los delegados lo aplican siempre.
param(
    [Parameter(Mandatory)][ValidateSet('texto', 'trivial', 'razonar', 'opinion', 'codigo', 'revision', 'contenido', 'imagen')][string]$Tarea,
    [ValidateSet('economica', 'equilibrada', 'maxima')][string]$Calidad,
    [switch]$Critico, [switch]$Dificil, [switch]$ConCupo,
    [int]$Tamano = -1,        # caracteres de la tarea (prompt + archivos); -1 = no se sabe. Lo usa la politica de intensidad para no delegar lo chico
    [string]$Chat = '', [switch]$Forzar    # -Chat: id de la conversacion (por defecto la actual); -Forzar: ignora la politica de intensidad y delega igual
)
. (Join-Path $PSScriptRoot '_comun.ps1')
$cfg = Get-Config
if ($Critico) { $Calidad = 'maxima' } elseif (-not $Calidad) { $Calidad = if ($cfg.calidad -in 'economica', 'equilibrada', 'maxima') { $cfg.calidad } else { 'equilibrada' } }
if ($cfg.activo -eq $false) { [pscustomobject]@{ modo = $cfg.modo; calidad = $Calidad; destino = 'apagado'; cuenta = ''; perfil = ''; modelo = ''; esfuerzo = ''; motivo = 'Multi-IA está APAGADO (interruptor del panel o /multi-ia): no se delega, resolvelo vos directo'; segundo = $null } | ConvertTo-Json -Compress; exit 0 }
if ($Tarea -eq 'imagen') { [pscustomobject]@{ modo = $cfg.modo; calidad = $Calidad; destino = 'ninguno'; cuenta = ''; perfil = ''; modelo = ''; esfuerzo = ''; motivo = 'Imagen, video o audio: ningún motor delegado (Codex, Gemini, Claude y GPT-OSS vía Antigravity) los genera. Usar otra herramienta o decírselo al usuario.'; segundo = $null } | ConvertTo-Json -Compress; exit 0 }
$bloqueo = [int]$cfg.ahorro.umbral_bloqueo
# 2.3.7: una cuenta activa en la config NO alcanza: si el motor no esta instalado en ESTA PC no se lo elige (antes un usuario nuevo
# sin Codex veia un error crudo de PowerShell en vez de que Claude lo resolviera o se le explicara como instalarlo).
$codexCtas = if (Find-CodexExe) { @(Get-CuentasActivas $cfg 'codex') } else { @() }
$agyCtas = if (Find-AgyExe) { @(Get-CuentasActivas $cfg 'agy') } else { @() }

function Salida($destino, $cuenta, $perfil, $modelo, $esfuerzo, $motivo, $segundo) {
    # Factor de historial: con 3 o mas ejecuciones reales de este motor en esta tarea, se muestra su tasa de exito (solo informa; no cambia el motor).
    if ($destino -in 'codex', 'agy') {
        $h = Get-Historial -Destino $destino -Tarea $Tarea
        if ($h.n -ge 3) { $motivo += " · historial: $($h.pct_ok)% ok en $($h.n) ejecuciones, $($h.seg_medio) s promedio$(if ($h.pct_ok -lt 50) { ' ⚠ rinde mal acá: considerá revisar el resultado' })" }
    }
    # 2.2.0: intensidad alta pide revision cruzada; si el plan no trae segundo motor propio, se le asigna uno de otro proveedor y el motivo lo dice.
    if ($script:PolCruzar -and $destino -in 'codex', 'agy' -and -not $segundo) { $segundo = if ($destino -eq 'codex') { $cruce } elseif ($perfil -eq $cruce2.perfil) { $cruceCodex } else { $cruce2 }; $motivo += " · intensidad alta: revisión cruzada ($($segundo.motivo))" }
    if ($script:NotaCalidad) { $motivo += " · $($script:NotaCalidad)" }
    [pscustomobject]@{ modo = $cfg.modo; calidad = $Calidad; destino = $destino; cuenta = $cuenta; perfil = $perfil; modelo = $modelo; esfuerzo = $esfuerzo; motivo = $motivo; segundo = $segundo; intensidad = $int.valor; intensidad_origen = $int.origen; cruzar = [bool]$script:PolCruzar; paralelo = [bool]$script:PolParalelo } | ConvertTo-Json -Compress -Depth 4   # paralelo = SUGERENCIA para Claude (delegaciones independientes pueden lanzarse a la vez); delegar.ps1 corre una por vez
    exit 0
}
# Sin delegado disponible: lo hace Claude SOLO si su propio cupo tiene margen; si no, queda pendiente (no se gasta lo que se queria cuidar).
function SinDelegado($motivo) {
    $u = $null
    if (Test-Path -LiteralPath $script:ClaudeSnapshot) {
        $s = Get-Content -LiteralPath $script:ClaudeSnapshot -Raw -Encoding UTF8 | ConvertFrom-Json
        $ahora = (Get-Date).ToUniversalTime()
        $v = @($s.cinco_horas, $s.semanal | Where-Object { $_ -and $_.reinicia -and ([datetime]::Parse($_.reinicia, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal) -gt $ahora) } | ForEach-Object { [int]$_.usado })
        if ($v) { $u = ($v | Measure-Object -Maximum).Maximum }
    }
    if ($null -ne $u -and $u -ge $bloqueo) { Salida 'pendiente' '' '' '' '' "$motivo. El cupo de Claude también está al $u%: dejar pendiente y avisar al usuario" $null }
    Salida 'claude' '' '' '' '' "$motivo. La hace Claude$(if ($null -ne $u) { " (su cupo está al $u%)" } else { ' (cupo propio sin dato reciente)' }), avisando" $null
}
function Usado($filas, $ia, $v) { $x = @($filas | Where-Object { $_.ia -eq $ia -and $_.ventana -eq $v }) | Select-Object -First 1; if ($x) { [int]$x.usado } else { $null } }
function Maximo($valores) { $v = @($valores | Where-Object { $null -ne $_ }); if ($v) { ($v | Measure-Object -Maximum).Maximum } else { $null } }

# ---- INTENSIDAD DE DELEGACION (2.0). Se aplica SOLO en modo automatico de motores (en manual el usuario ya eligio y se respeta). Cada decision queda explicada en el motivo.
#   bajo        : Claude resuelve lo suyo; delega solo codigo/revision de tamano relevante, tareas dificiles/criticas o textos muy grandes.
#   medio       : delega todo salvo lo trivial o lo muy corto que no sea codigo/revision.
#   alto        : delega casi todo (salvo lo diminuto, para no crear llamadas artificiales), sube economica a equilibrada, pide revision cruzada en codigo/revision/razonar y marca paralelismo.
#   automatico  : no delega lo corto (cada llamada a Antigravity gasta ~6.800 tokens fijos); el resto va al motor que corresponde. Sin tamano conocido, delega como siempre.
$int = Get-Intensidad -Chat $Chat -Cfg $cfg
$script:PolCruzar = $false; $script:PolParalelo = $false; $script:NotaCalidad = ''
$origenTxt = if ($int.origen -eq 'chat') { 'elegida para este chat' } else { 'heredada de la global' }
$etq = "intensidad $($int.valor), $origenTxt"
if ($cfg.modo -ne 'manual' -and -not $Forzar) {
    $dura = $Critico -or $Dificil -or ($Calidad -eq 'maxima')   # 2.2.0: calidad maxima nunca se retiene
    $mantiene = $null
    switch ($int.valor) {
        'bajo' {
            $codeRev = $Tarea -in 'codigo', 'revision'
            $grande = ($Tamano -ge 15000) -or ($codeRev -and ($Tamano -lt 0 -or $Tamano -ge 4000))
            if (-not $dura -and -not $grande) { $mantiene = "Claude mantiene la tarea: no hay ventaja clara en delegarla ($etq)" }
        }
        'medio' {
            if (-not $dura -and ($Tarea -eq 'trivial' -or ($Tamano -ge 0 -and $Tamano -lt 800 -and $Tarea -notin 'codigo', 'revision'))) { $mantiene = "Claude mantiene la tarea por baja complejidad ($etq)" }
        }
        'alto' {
            if (-not $dura -and $Tamano -ge 0 -and $Tamano -lt 300 -and $Tarea -notin 'codigo', 'revision') { $mantiene = "Claude mantiene la tarea: es diminuta y delegarla sería trabajo artificial ($etq)" }
            else { $script:PolParalelo = $true; if ($Tarea -in 'codigo', 'revision', 'razonar') { $script:PolCruzar = $true } }
        }
        default {   # automatico
            if (-not $dura -and $Tamano -ge 0 -and $Tamano -lt 1200 -and $Tarea -in 'trivial', 'texto', 'opinion', 'contenido') { $mantiene = "Claude mantiene la tarea por baja complejidad: ~$Tamano caracteres, no compensa el arranque fijo del motor ($etq)" }
        }
    }
    if ($mantiene) { SinDelegado $mantiene }   # 2.2.0: la retencion pasa por la proteccion del cupo de Claude (si esta al limite, queda pendiente)
    if ($int.valor -eq 'alto' -and $Calidad -eq 'economica') { $Calidad = 'equilibrada'; $script:NotaCalidad = 'intensidad alta: se sube la calidad de económica a equilibrada' }
}
# ---- MANUAL
if ($cfg.modo -eq 'manual') {
    if ($Tarea -in 'codigo', 'revision' -and $codexCtas) { Salida 'codex' $codexCtas[0].id '' $cfg.manual.codex.modelo $cfg.manual.codex.esfuerzo 'modo manual: elegido por el usuario' $null }
    if ($agyCtas) { Salida 'agy' $agyCtas[0].id '' $cfg.manual.agy.modelo '' 'modo manual: elegido por el usuario' $null }
    SinDelegado 'Modo manual pero no hay cuenta delegada activa para esta tarea'
}

# ---- AUTOMATICO: motor por tarea y calidad. Modelos de Codex segun su catalogo (`codex debug models`): gpt-6-astra = "inteligencia de frontera para lo mas exigente",
# gpt-6.1-sol = el mejor para codigo (contexto 500k), gpt-6-luna = rapido y barato. En agy: gemini-4-argon (razonar), claude-opus-5-5 (opinion/revision), gemini-3.8-flash (texto).
$A = { param($p, $e, $why, $seg) @{ d = 'agy'; p = $p; e = $e; m = ''; why = $why; seg = $seg } }
$C = { param($m, $e, $why, $seg) @{ d = 'codex'; p = ''; m = $m; e = $e; why = $why; seg = $seg } }
$cruce = @{ destino = 'agy'; perfil = 'opus'; esfuerzo = 'high'; motivo = 'revisión cruzada: otro proveedor, Claude Opus por el cupo de Google' }
$cruceCodex = @{ destino = 'codex'; perfil = ''; modelo = 'gpt-6.1-sol'; esfuerzo = 'high'; motivo = 'revisión cruzada: otro proveedor, Codex gpt-6.1-sol' }
$cruce2 = @{ destino = 'agy'; perfil = 'razonar'; esfuerzo = 'high'; motivo = 'segundo motor independiente: Gemini 4 Argon' }
$tabla = @{
    economica = @{
        trivial = & $A 'texto' 'low' 'trivial: el motor más barato' $null
        texto = & $A 'texto' 'medium' 'resumen/redacción/traducción: Gemini Flash' $null
        razonar = & $A 'razonar' 'medium' 'análisis: Gemini 4 Argon' $null
        opinion = & $A 'sonnet' 'medium' 'segunda opinión barata: Claude Sonnet por el cupo de Google' $null
        codigo = & $C 'gpt-6-luna' 'medium' 'código fácil: Codex luna (rápido y barato)' $null
        revision = & $C 'gpt-6-luna' 'high' 'revisión rápida: Codex luna' $null
        contenido = & $A 'texto' 'medium' 'contenido: Gemini Flash' $null
    }
    equilibrada = @{
        trivial = & $A 'texto' 'low' 'trivial: el motor más barato' $null
        texto = & $A 'texto' 'medium' 'resumen/redacción/traducción: Gemini Flash' $null
        razonar = & $A 'razonar' 'high' 'análisis: Gemini 4 Argon con esfuerzo alto' $null
        opinion = & $A 'opus' 'medium' 'segunda opinión: Claude Opus por el cupo de Google' $null
        codigo = & $C 'gpt-6.1-sol' 'medium' 'código: Codex gpt-6.1-sol, el mejor para programar' $null
        revision = & $C 'gpt-6.1-sol' 'high' 'revisión de código: Codex gpt-6.1-sol con esfuerzo alto' $null
        contenido = & $A 'texto' 'high' 'contenido: Gemini Flash con esfuerzo alto' $null
    }
    maxima = @{
        trivial = & $A 'razonar' 'medium' 'calidad máxima: Gemini 4 Argon' $null
        texto = & $A 'razonar' 'high' 'calidad máxima: Gemini 4 Argon, esfuerzo alto' $null
        razonar = & $A 'opus' 'high' 'calidad máxima: Claude Opus esfuerzo alto' $cruce2
        opinion = & $A 'opus' 'high' 'calidad máxima: Claude Opus esfuerzo alto' $cruce2
        codigo = & $C 'gpt-6.1-sol' 'xhigh' 'calidad máxima: Codex gpt-6.1-sol, esfuerzo xhigh (en copia aislada)' $cruce
        contenido = & $A 'opus' 'high' 'calidad máxima: Claude Opus esfuerzo alto para redactar' $cruce2
        revision = & $C 'gpt-6-astra' 'xhigh' 'calidad máxima: Codex gpt-6-astra (inteligencia de frontera), esfuerzo xhigh' $cruce
    }
}
$plan = $tabla[$Calidad][$Tarea]
# APRENDIZAJE por resultados reales (sin reentrenar nada): si el motor planeado fallo mas de la mitad de las veces en esta tarea (5 o mas ejecuciones registradas),
# se sube UN escalon de calidad (economica -> equilibrada -> maxima) y el motivo lo explica. Se apaga con ahorro.aprender = false.
if ($cfg.ahorro.aprender -ne $false -and $Calidad -ne 'maxima' -and $plan) {
    $hp = Get-Historial -Destino $plan.d -Tarea $Tarea
    if ($hp.n -ge 5 -and $hp.pct_ok -lt 50) {
        $subida = if ($Calidad -eq 'economica') { 'equilibrada' } else { 'maxima' }
        $nuevo = $tabla[$subida][$Tarea]
        if ($nuevo) { $nuevo.why += " · aprendizaje: con el plan '$Calidad' rindió $($hp.pct_ok)% ok en $($hp.n) ejecuciones, se sube a '$subida'"; $plan = $nuevo; $Calidad = $subida }
    }
}
# -Dificil sube un escalon el esfuerzo en economica/equilibrada (en maxima ya es el mas alto razonable).
if ($Dificil -and $Calidad -ne 'maxima') { $plan.e = switch ($plan.e) { 'low' { 'medium' } 'medium' { 'high' } default { $plan.e } } }
$perfilModelo = @{ texto = 'gemini-3.8-flash'; razonar = 'gemini-4-argon'; opus = 'claude-opus-5-5'; sonnet = 'claude-sonnet-5-5' }
$pool = @{ texto = 'Antigravity · Gemini'; razonar = 'Antigravity · Gemini'; opus = 'Antigravity · Claude/GPT'; sonnet = 'Antigravity · Claude/GPT' }

if (-not $ConCupo) {
    if ($plan.d -eq 'codex') {
        if ($codexCtas) { Salida 'codex' $codexCtas[0].id '' $plan.m $plan.e $plan.why $plan.seg }
        if ($agyCtas) { Salida 'agy' $agyCtas[0].id 'razonar' ($perfilModelo['razonar'] + '-' + $plan.e) $plan.e ('Codex no está instalado o no tiene cuenta activa: se usa Antigravity (Gemini) · ' + $plan.why) $plan.seg }   # 2.3.7
        SinDelegado 'Codex no está instalado o no tiene cuenta activa (corré /configurar para ver cómo instalarlo)'
    }
    if ($agyCtas) { Salida 'agy' $agyCtas[0].id $plan.p ($perfilModelo[$plan.p] + '-' + $plan.e) $plan.e $plan.why $plan.seg }
    SinDelegado 'Antigravity no está instalado o no tiene cuenta activa (corré /configurar)'
}

# ---- con cupo real: la mejor opcion que no pase el umbral de bloqueo
$codexMap = [ordered]@{}; foreach ($c in $codexCtas) { $codexMap[(Get-NombreCuenta $cfg $c)] = Get-CupoCodex -CodexHome $c.home }
$agyCupo = if ($agyCtas) { Get-CupoAgy } else { @() }
$filas = @(Get-CupoGeneral -Codex $codexMap -Agy $agyCupo)

if ($plan.d -eq 'codex') {
    $mejor = $null; $mejorU = 999; $nota = ''
    foreach ($c in $codexCtas) {
        $n = Get-NombreCuenta $cfg $c
        $u5 = Usado $filas $n '5 h'; $us = Usado $filas $n 'Semanal'; $m = Maximo @($u5, $us)
        if ($null -ne $m -and $m -ge $bloqueo) { continue }
        $orden = if ($null -ne $u5) { $u5 } else { 50 }
        if ($orden -lt $mejorU) { $mejor = $c; $mejorU = $orden; $nota = if ($null -eq $m) { ' (cupo desconocido)' } else { " (cupo: $u5% en 5 h)" } }
    }
    if ($mejor) { Salida 'codex' $mejor.id '' $plan.m $plan.e ($plan.why + $nota) $plan.seg }
    SinDelegado "Codex está al $bloqueo% o más, o sin cuenta activa"
}
# agy: en calidad maxima NO se baja de motor por cupo (se avisa); en las otras se prueban alternativas de otro grupo.
if (-not $agyCtas) { SinDelegado 'Antigravity no está instalado o no tiene cuenta activa (corré /configurar)' }
$orden = if ($Calidad -eq 'maxima') { @($plan.p) } else { @($plan.p) + @('texto', 'razonar', 'sonnet', 'opus' | Where-Object { $_ -ne $plan.p -and $pool[$_] -ne $pool[$plan.p] }) }
foreach ($p in $orden) {
    $g = $pool[$p]
    $u = Maximo @((Usado $filas $g '5 h'), (Usado $filas $g 'Semanal'), $(if ($p -eq 'razonar') { Usado $filas 'Antigravity · Gemini 4 Argon' 'Semanal' }))
    if ($null -ne $u -and $u -ge $bloqueo) { continue }
    $txt = if ($p -eq $plan.p) { $plan.why } else { "$($plan.why), pero su cupo está al límite: se usa el grupo alternativo" }
    Salida 'agy' $agyCtas[0].id $p ($perfilModelo[$p] + '-' + $plan.e) $plan.e ($txt + $(if ($null -eq $u) { ' (cupo desconocido)' } else { " (cupo $g`: $u%)" })) $plan.seg
}
SinDelegado "$(if ($Calidad -eq 'maxima') { 'El motor de calidad máxima' } else { 'Todos los cupos de Antigravity' }) está en $bloqueo% o más"
