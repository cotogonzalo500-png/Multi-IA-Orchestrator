# Changelog (Community Edition)
## 2.3.14
- Corrección encontrada con agy REAL sin login (usuario local temporal, sin credenciales): agy imprime «Authentication required… authentication failed or timed out» y el router lo clasificaba como `timeout` (reintentable, ayuda «el motor tardó demasiado»). Ahora `Get-ClaseError` reconoce `authentication required|failed` / «visit the URL to log in» como `autenticacion` (no reintentable, con instrucciones de login) antes de evaluar timeout. Prueba de regresión con el texto real. Evidencia: `validacion\agy-sin-login-real\`.

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
