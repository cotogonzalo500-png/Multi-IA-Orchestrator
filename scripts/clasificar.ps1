# Clasifica un pedido en lenguaje natural y dice que tarea es (para elegir.ps1/delegar.ps1) o si ningun motor delegado puede hacerlo.
#   .\clasificar.ps1 -Pedido "programame un script que ..."   -> JSON { tarea, motivo }   (tarea = 'imagen' significa: ningun motor delegado lo hace)
# Es una REGLA por palabras clave (rapida y gratis, sin gastar cupo). Si Claude duda, que elija la tarea a mano: el pedido real manda.
param([Parameter(Mandatory)][string]$Pedido, [switch]$Texto)
. (Join-Path $PSScriptRoot '_comun.ps1')
function Clasificar([string]$p) {
    $t = $p.ToLowerInvariant()
    $r = @(
        @{ k = 'revision'; re = 'revis[aá]|audit|code review|buscá (bugs|errores)|busca (bugs|errores)|encontr[aá] (bugs|errores)|segur[ií]dad del c[oó]digo'; m = 'revisar código: Codex con esfuerzo alto' }
        @{ k = 'codigo'; re = 'program[aá]|codific|c[oó]digo|script|funci[oó]n|\bbug\b|\bapi\b|python|javascript|typescript|powershell|\bsql\b|html|css|refactor|implement|desarroll|app de|bot de|\bscraper|\btest(s)?\b|compil'; m = 'programar: Codex es el motor especializado en código' }
        @{ k = 'imagen'; re = 'imagen|im[aá]genes|foto|dibuj|ilustraci|logo|logotipo|banner|flyer|afiche|poster|p[oó]ster|meme|render|v[ií]deo|video|animaci|audio|voz\b|locuci|m[uú]sica|canci[oó]n|podcast|thumbnail|miniatura'; m = 'imagen/video/audio: ningún motor delegado lo genera' }
        @{ k = 'opinion'; re = 'segunda opini|qu[eé] opin[aá]s|contrastar|otro punto de vista|me convenc|est[aá] bien (esto|mi)'; m = 'segunda opinión: otro proveedor (Claude Opus vía Antigravity)' }
        @{ k = 'razonar'; c = 'datos'; re = 'planilla|excel|\bcsv\b|dataset|base de datos|estad[ií]stic|m[eé]tricas|tabla de datos'; m = 'análisis de datos: Gemini 4 Argon' }
        @{ k = 'razonar'; c = 'arquitectura'; re = 'arquitectur|dise[ñn]o del sistema|diagrama|estructura del proyecto|c[oó]mo organizar'; m = 'arquitectura/diseño: Gemini 4 Argon' }
        @{ k = 'razonar'; re = 'analiz|estrategia|compar[aá]|plan(ific)?|decid|conviene|pros y contras|calcul|presupuesto|investig|diagn[oó]stic|por qu[eé]'; m = 'análisis/razonamiento: Gemini 4 Argon' }
        @{ k = 'contenido'; re = 'post|publicaci|caption|copy|anuncio|guion|gui[oó]n|art[ií]culo|blog|newsletter|campa[ñn]a|descripci[oó]n de producto|slogan|eslogan|historia|cuento|email|mail|carta|redact[aá]|escrib[ií]|contenido|mensaje de|texto para'; m = 'contenido/redacción: Gemini (rápido, buen texto)' }
        @{ k = 'texto'; re = 'resum|traduc|corrig|reformul|explic|list[aá]|ordena|clasific|extra[eé]|formate'; m = 'resumen/traducción/edición: Gemini Flash' }
    )
    # Categorias propias del usuario: [{ "categoria": "legal", "re": "contrato|clausula", "tarea": "razonar", "motivo": "..." }] en categorias-extra.json (se evaluan primero).
    $ex = Join-Path $script:DatosDir 'categorias-extra.json'
    if (Test-Path -LiteralPath $ex) {
        try {
            $r = @(@((Get-Content -LiteralPath $ex -Raw -Encoding UTF8) | ConvertFrom-Json) | Where-Object { $_.re -and $_.tarea } | ForEach-Object { @{ k = [string]$_.tarea; c = [string]$_.categoria; re = [string]$_.re; m = [string]$_.motivo } }) + $r
        } catch { }
    }
    foreach ($x in $r) { if ($t -match $x.re) { return [pscustomobject]@{ tarea = $x.k; categoria = $(if ($x.c) { $x.c } else { $x.k }); motivo = $x.m } } }
    if ($t.Length -lt 80) { return [pscustomobject]@{ tarea = 'trivial'; categoria = 'trivial'; motivo = 'pedido corto sin tema claro: lo más barato (o resolverlo directo)' } }
    [pscustomobject]@{ tarea = 'razonar'; categoria = 'razonar'; motivo = 'sin palabras clave claras: análisis general con Gemini 4 Argon' }
}
if ($MyInvocation.InvocationName -ne '.') { $o = Clasificar $Pedido; if ($Texto) { "$($o.tarea): $($o.motivo)" } else { $o | ConvertTo-Json -Compress } }
