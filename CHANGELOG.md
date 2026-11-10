# Changelog (Community Edition)

## 3.1.0
- Cierre de la rama 2.3.x: el cierre de procesos (`matarVerificado`) identifica descendientes por PID + fecha de creación y no mata a ciegas si no puede verificar; estrés controlado (32 corridas × 23 pruebas, 0 fallas).
- `conexiones.ps1`: «Not logged in» gana a «logged in»; `-Probar` re-consulta la sesión; un `--version` fallido no se cachea 24 h.
- Un 401/UNAUTHENTICATED junto a «timed out» se clasifica como `autenticacion` (no reintentable); `-Aislar` revisa el contenido de archivos hasta 20 MB y no copia los más grandes.
- Configuración y datos de 2.3.x compatibles, sin migración. Solo Windows 10/11 con Windows PowerShell 5.1.

## 2.3.13
- La tarjeta «Ahorro por chat» se muestra como estimación exploratoria («≈ N % est.», caché al 10 %), no como medición ni cuota.

## 2.3.12
- Auditoría del ahorro: la métrica «Ahorro por chat» es una estimación (tokens de la CLI, que incluyen su contexto fijo de entrada, menos la coordinación); no mide la cuota de Claude y sobreestima en tareas chicas. Etiqueta corregida.
- Tests del panel más estables (el runner fija 5 s por test). `construir.ps1` mantiene la versión de plugin.json alineada con el desarrollo.

## 2.3.1 (preview, sin publicar)
- Primera Community Edition generada a partir del desarrollo privado 2.3.1 (`community\construir.ps1`).
- `/configurar`: asistente de primer uso. Detecta los requisitos y los motores, guía la instalación y el login oficiales, crea la configuración por defecto (intensidad Automático) sin pisar la existente y arranca las métricas vacías.
- Codex se detecta también cuando se instaló por npm (`@openai/codex`) o está en el `PATH`, no solo con la app de escritorio. `MULTIIA_CODEX_EXE` permite forzar la ruta.
- Datos del usuario en `%USERPROFILE%\.multi-ia-orquestador` (o `MULTIIA_DATOS`).
- Panel «Pixel Pro» (2.3.0): rediseño visual, estados accesibles y métricas con nivel de confianza.
- Sin rutas ni nombres personales y licencia MIT.
- Ícono propio (`.claude-plugin/icon.png`, 512×512), dibujado desde cero para esta edición. El ícono de la edición personal no se incluye.
- README: los documentos que hoy están solo en castellano se marcan **(ES)** y se explica cómo abrir el panel (`/panel-ia`, botón ⤢ Expandir).
- `MULTIIA_DATOS` tiene que ser una ruta absoluta; una relativa se ignora con aviso en `/configurar`.
- CI: también busca rutas personales (`C:\Users\<alguien>\`); `docs/COMPATIBILIDAD.md` aclara qué corre el CI.
- Panel: el fondo llena todo el alto, la cabecera del Centro de control se alinea con el contenido y la consola ya no corta los títulos.
