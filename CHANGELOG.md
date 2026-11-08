# Changelog (Community Edition)

## 2.3.1 (preview, sin publicar)
- Primera Community Edition generada a partir del desarrollo privado 2.3.1 (`community\construir.ps1`).
- `/configurar`: asistente de primer uso. Detecta los requisitos y los motores, guía la instalación y el login oficiales, crea la configuración por defecto (intensidad Automático) sin pisar la existente y arranca las métricas vacías.
- Codex se detecta también cuando se instaló por npm (`@openai/codex`) o está en el `PATH`, no solo con la app de escritorio. `MULTIIA_CODEX_EXE` permite forzar la ruta.
- Datos del usuario en `%USERPROFILE%\.multi-ia-orquestador` (o `MULTIIA_DATOS`).
- Panel «Pixel Pro» (2.3.0): rediseño visual, estados accesibles y métricas con nivel de confianza.
- Sin rutas ni nombres personales, sin ícono (derechos sin documentar) y sin licencia definitiva.
