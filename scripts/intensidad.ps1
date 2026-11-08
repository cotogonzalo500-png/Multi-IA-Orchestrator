# Intensidad de delegacion (2.0): bajo | medio | alto | automatico (por defecto). Global y por chat; la del chat gana y, si se quita, el chat hereda la global.
#   .\intensidad.ps1 -Ver [-Chat <id>]                     intensidad efectiva (y si es del chat o heredada)
#   .\intensidad.ps1 -Valor alto -Global                   cambia el valor por defecto de los chats nuevos y de los que no tengan uno propio
#   .\intensidad.ps1 -Valor bajo -Chat <id>                preferencia de ESE chat (sin -Chat usa el chat actual, CLAUDE_CODE_SESSION_ID)
#   .\intensidad.ps1 -Quitar -Chat <id>                    el chat vuelve a heredar la global
# Aplica a las PROXIMAS decisiones del router; las delegaciones ya iniciadas no se tocan. Solo informa "guardado" despues de releer config.json y comprobarlo.
param(
    [ValidateSet('bajo', 'medio', 'alto', 'automatico')][string]$Valor,
    [switch]$Global, [string]$Chat = '', [switch]$Quitar, [switch]$Ver, [switch]$Json
)
. (Join-Path $PSScriptRoot '_comun.ps1')
if (-not $Chat) { $Chat = [string]$env:CLAUDE_CODE_SESSION_ID }
function Salir($obj, [int]$codigo = 0) { if ($Json) { $obj | ConvertTo-Json -Compress -Depth 4 } else { $obj.mensaje }; exit $codigo }
function Falla($m) { if ($script:bloq) { Unlock-Config }; Write-Error $m; exit 2 }

$escribe = [bool]$Valor -or $Quitar
if ($Valor -and $Quitar) { Write-Error '-Valor y -Quitar a la vez no tiene sentido'; exit 2 }
if ($Valor -and -not $Global -and -not $Chat) { Write-Error 'Sin chat actual: indica -Chat <id> o -Global'; exit 2 }
if ($Quitar -and -not $Chat) { Write-Error '-Quitar necesita -Chat <id> (o ejecutarse dentro de un chat)'; exit 2 }
if ($Quitar -and $Global) { Write-Error '-Quitar es solo para chats: la global no se quita, se cambia'; exit 2 }

if (-not $escribe) {
    $i = Get-Intensidad -Chat $Chat
    $txt = if ($i.origen -eq 'chat') { "Intensidad de este chat: $($i.valor) (elegida para este chat; la global es $($i.global))" } else { "Intensidad: $($i.valor) (heredada de la global)" }
    Salir ([ordered]@{ ok = $true; valor = $i.valor; origen = $i.origen; chat = $i.chat; global = $i.global; mensaje = $txt })
}

$script:bloq = Lock-Config
if (-not $script:bloq) { Write-Error 'config.json esta ocupada por otro proceso; reintenta'; exit 2 }
$cfg = Get-Config
if ($script:ConfigCorrupta) { Falla 'config.json esta corrupta: no se guarda nada. Repararla con config.ps1 -Recuperar' }
$antes = Get-Intensidad -Chat $Chat -Cfg $cfg
if ($Valor -and $Global) { $cfg.intensidad = $Valor; $alcance = 'global' }
elseif ($Valor) { $cfg.intensidad_chats | Add-Member -NotePropertyName $Chat -NotePropertyValue $Valor -Force; $alcance = 'chat' }
else {
    if (-not $cfg.intensidad_chats.PSObject.Properties[$Chat]) { Unlock-Config; Salir ([ordered]@{ ok = $true; valor = $antes.valor; origen = $antes.origen; chat = $Chat; mensaje = "Este chat no tenia preferencia propia: ya hereda la global ($($antes.global))" }) }
    $cfg.intensidad_chats.PSObject.Properties.Remove($Chat); $alcance = 'chat'
}
Save-Config $cfg
Unlock-Config
# Verificacion: se relee del disco; solo si coincide se confirma.
$despues = Get-Intensidad -Chat $Chat
$esperado = if ($Valor) { $Valor } else { $despues.global }
$guardado = if ($alcance -eq 'global') { $despues.global -eq $esperado } else { ($despues.valor -eq $esperado) -and ($despues.origen -eq $(if ($Valor) { 'chat' } else { 'global' })) }   # global: se compara la global (un chat con preferencia propia no cuenta)
if (-not $guardado) { Write-Error "No se pudo comprobar el cambio en config.json (esperado $esperado, leido $($despues.valor))"; exit 2 }
$que = if ($alcance -eq 'global') { "global: $($antes.global) -> $($despues.global)" } else { "chat ${Chat}: $($antes.valor) ($($antes.origen)) -> $($despues.valor) ($($despues.origen))" }
Add-Evento -Tipo 'intensidad' -Destino 'claude' -Detalle $que -Motivo "cambio manual de intensidad de delegacion ($alcance)" -Tarea ''
$cuando = 'Rige desde la proxima decision del router; lo que ya esta delegado sigue como estaba.'
Salir ([ordered]@{ ok = $true; alcance = $alcance; valor = $despues.valor; origen = $despues.origen; chat = $Chat; global = $despues.global; mensaje = "Guardado y verificado ($que). $cuando" })
