# Privacidad

- **Qué se guarda:** la configuración (`config.json`), el registro de uso (`uso.jsonl`: fecha, motor, modelo, duración, tokens si el motor los informa y resultado), la memoria compartida (`MEMORIA*.md`) y la caché de diagnóstico (`conexiones.json`).
- **Dónde:** solo en tu equipo, en `%USERPROFILE%\.multi-ia-orquestador` o en la carpeta que indique `MULTIIA_DATOS`. Nunca dentro del plugin.
- **Qué NO se guarda:** credenciales, tokens, cookies ni el contenido de tus sesiones de Claude.
- **A quién se envía:** a nadie más que a los motores que vos mismo instalaste y conectaste (Codex, Antigravity), y solo el texto de la tarea que Claude decide delegar. El plugin no tiene telemetría.
- **Cómo borrar todo:** desinstalá el plugin y borrá la carpeta de datos.
- **Ojo:** lo que se delega lo procesa el proveedor de ese motor, según sus propias condiciones. No delegues datos que no quieras compartir con ese proveedor.
