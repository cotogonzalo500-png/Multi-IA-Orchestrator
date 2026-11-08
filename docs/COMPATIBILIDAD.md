# Compatibilidad

| Sistema | Estado | Evidencia |
|---|---|---|
| Windows 10 (LTSC 21H2, 10.0.19044) + Windows PowerShell 5.1 + Node 24 | **Probado** | suite `tests\probar.ps1`, `claude plugin test`, instalación limpia aislada |
| Windows 11 | Esperado, **no probado** localmente | mismo PowerShell 5.1; el CI corre en `windows-latest` (hoy Windows Server) |
| PowerShell 7 (`pwsh`) | **No probado** | los scripts se llaman con `powershell.exe` (5.1) |
| macOS | **No soportado** | depende de `powershell.exe`, `%LOCALAPPDATA%` y `%USERPROFILE%` |
| Linux | **No soportado** | igual que macOS |

## Por qué es solo Windows
- El panel y los hooks lanzan los scripts con `powershell -NoProfile -ExecutionPolicy Bypass -File`.
- La detección de los motores busca en `%LOCALAPPDATA%` (app de Codex, `agy`), en el `PATH` y en el paquete npm de Codex.
- Llevarlo a macOS o Linux implica portar los scripts a PowerShell 7 o a node, y probar cada camino. Hoy no está hecho.

## Qué corre el CI (`.github/workflows/ci.yml`)
- `windows-latest` con **Node 20** (la prueba local se hizo con Node 24; el mínimo es Node 18).
- Solo `tests\probar.ps1` con una carpeta de datos aislada, más un escaneo de secretos y de rutas personales (`C:\Users\<alguien>\`).
- **No** corre `claude plugin test` ni `tests\funcional.ps1` (necesitan Claude Code instalado); esas se corren a mano antes de publicar.
