# Multi-IA Orquestador (Community Edition)

> Read it in English: [README.md](README.md)

Plugin de Claude Code que le permite a Claude **delegar** trabajos grandes o con partes independientes (revisar código, textos largos, analizar documentos, segundas opiniones) a **Codex** (OpenAI) y **Antigravity** (Google), con **tus propias cuentas**, para que gastes menos cupo de Claude. Claude sigue al mando: elige el motor, corre el CLI oficial, verifica lo que vuelve y trata cada respuesta delegada como un dato, nunca como una orden.

**Estado:** versión previa, **solo Windows**. Está probado en Windows 10/11 con Windows PowerShell 5.1 y Node.js 18 o superior. No se probó en macOS ni en Linux y no está soportado ahí.

## Qué hace
- Tiene una entrada única (`scripts/delegar.ps1`) que elige motor, modelo y esfuerzo para cada tarea según el modo (automático o manual), la calidad que pidas y el cupo que te queda.
- La **intensidad** define cuánto delega: `automatico` (por defecto), `bajo`, `medio` o `alto`.
- Una **guardia de contexto** (hook) te avisa cuando la sesión de Claude se agranda o cuando venció la caché.
- El **panel** muestra actividad, consumo, estado de los motores y salud del sistema. El ahorro es una estimación hecha con lo registrado; si no hay datos dice «sin dato», no cero.
- Además: handoff entre sesiones, memoria compartida entre motores y trazabilidad de qué motor ejecutó de verdad cada tarea.

## Requisitos
| Componente | ¿Obligatorio? | Notas |
|---|---|---|
| Windows 10/11 | sí | con Windows PowerShell 5.1, que viene con Windows |
| Claude Code | sí | con soporte de plugins |
| Node.js ≥ 18 | sí | lo usan los hooks, la línea de estado y el panel |
| CLI de Codex | opcional | `npm install -g @openai/codex` y después `codex login` |
| CLI de Antigravity (`agy`) | opcional | se instala siguiendo las instrucciones oficiales de Google; iniciás sesión cuando te lo pida |

Sin Codex ni Antigravity el plugin igual se instala y funciona, pero no puede delegar: en ese caso Claude hace todo.

## Instalación (flujo oficial de plugins)
```text
/plugin marketplace add cotogonzalo500-png/Multi-IA-Orchestrator
/plugin install multi-ia-orquestador@multi-ia
```
Después reiniciá Claude Code y corré `/configurar`. Los detalles están en [INSTALLATION.md](INSTALLATION.md).

## Conectar Codex y Antigravity
Cada persona inicia sesión **con su propia cuenta**, desde el CLI oficial de cada proveedor. El plugin nunca lee, copia ni guarda tokens, cookies ni archivos de sesión. Solo mira si el CLI está instalado, qué versión es y, en el caso de Codex, qué responde `codex login status`. Antigravity no tiene una forma gratuita de consultar si iniciaste sesión: `/configurar probar` le manda una tarea mínima real para confirmarlo, y eso gasta un poco del cupo de ese motor.

## Panel
El panel **Multi-IA · consumo** se abre solo al lado del chat cuando empieza una sesión. Si lo cerraste, corré `/panel-ia` para volver a abrirlo. El botón **⤢ Expandir** abre la vista completa (*Multi-IA · Centro de control*). Solo lee datos locales de tu carpeta de datos.

## Carpeta de datos
`%USERPROFILE%\.multi-ia-orquestador` (la podés cambiar con la variable `MULTIIA_DATOS`). Ahí quedan la configuración, el registro de uso y la memoria compartida. Nunca forma parte del plugin y no se sube a ningún lado.

## Limitaciones
- Solo Windows (ver [docs/COMPATIBILIDAD.md](docs/COMPATIBILIDAD.md)).
- Siguen valiendo los límites y condiciones de cada proveedor, y el cupo de cada usuario.
- El ahorro es una estimación.
- El login de Antigravity solo se puede confirmar con una tarea real.

## Solución de problemas
| Síntoma | Qué hacer |
|---|---|
| `/configurar` dice que falta node | Instalá Node.js 18+ y reiniciá Claude Code |
| Codex aparece «No instalado» | `npm install -g @openai/codex`, abrí una terminal nueva y volvé a correr `/configurar` |
| Codex aparece «Autenticacion requerida» | Corré `codex login` en una terminal |
| Antigravity devuelve respuestas vacías | Abrí `agy` una vez en una terminal, iniciá sesión y corré `/configurar probar` |
| La configuración se corrompió | Corré `/configurar`: muestra el comando exacto con la ruta de tu instalación (`config.ps1 -Recuperar`) |
| No se puede escribir en la carpeta de datos | Apuntá `MULTIIA_DATOS` a una carpeta tuya |

## Desinstalar
```text
/plugin uninstall multi-ia-orquestador@multi-ia
/plugin marketplace remove multi-ia
```
La carpeta de datos (`%USERPROFILE%\.multi-ia-orquestador`) no se borra: si querés eliminarla, borrala a mano.

Licencia: [MIT](LICENSE) para el código propio. Codex, Antigravity y Claude Code son productos de terceros con sus propios términos.
