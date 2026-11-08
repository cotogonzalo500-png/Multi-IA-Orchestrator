---
description: Ver o cambiar el modo de elección de modelos del plugin Multi-IA (automático o manual) y las cuentas delegadas
argument-hint: [automatico|manual]
---

Argumento recibido: `$ARGUMENTS`

1. Si el argumento es `automatico` o `manual`, correr `${CLAUDE_PLUGIN_ROOT}/scripts/config.ps1 -Modo <argumento>`.
2. Si no hay argumento, correr `${CLAUDE_PLUGIN_ROOT}/scripts/config.ps1 -Ver`.
3. Mostrar el resultado en pocas líneas: el modo actual, las cuentas activas (máximo 3) y, si es manual, lo que eligió el usuario.
4. Explicar en una frase qué cambia: en **automático** Claude elige el motor y la intensidad de cada delegación para gastar lo menos posible de su cupo;
   en **manual** los delegados usan siempre lo que el usuario eligió (se cambia con el botón del panel, `iniciar-panel.cmd`, o con `config.ps1 -Manual ...`).
No cambiar nada más ni tocar cuentas sin que el usuario lo pida.
