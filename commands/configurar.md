---
description: Asistente de configuración de Multi-IA, para el primer uso o un diagnóstico. Detecta requisitos, Codex y Antigravity, guía la instalación y el login oficiales y deja la intensidad en Automático.
argument-hint: [probar]
---

Argumento recibido: `$ARGUMENTS`

1. Correr `powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/configurar.ps1"`. Si el argumento es `probar`, agregar `-Probar`, pero antes avisar en una línea que eso hace una tarea mínima real a cada motor y gasta un poco de su cupo.
2. Mostrar el resultado en pocas líneas: qué requisitos están bien, el estado de cada motor (Codex y Antigravity son opcionales), las preferencias y los pasos que faltan, numerados.
3. Si falta instalar o iniciar sesión en un motor, explicar el paso oficial que sugiere el script. El login lo hace la persona en su terminal o navegador con su propia cuenta. **Nunca** pedir, leer, copiar ni mostrar tokens, cookies, contraseñas o archivos de sesión.
   Para gente no técnica: aclarar que los comandos de instalación y login se pegan en una terminal de Windows (menú Inicio → escribir «PowerShell» → Enter), no en el chat de Claude; que `/configurar` sí se escribe en Claude; y que Codex y Antigravity son opcionales: se puede seguir usando solo Claude. Evitar jerga (CLI, PATH, hooks) salvo cuando ayude a resolver un paso. Si el login queda pendiente, decir cómo comprobarlo después: `/configurar` (Codex) o `/configurar probar` (Antigravity).
4. No instalar nada ni cambiar la configuración sin que el usuario lo pida. El script solo crea la configuración por defecto si no existía.
5. Cerrar con las limitaciones que imprime el script (solo Windows y demás), sin maquillarlas.
