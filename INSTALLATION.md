# Instalación / Installation

## 1. Requisitos
- Windows 10/11 con Windows PowerShell 5.1 (`$PSVersionTable.PSVersion`).
- Claude Code con soporte de plugins.
- Node.js 18 o superior en el `PATH` (`node --version`).
- Opcionales: el CLI de Codex y/o el CLI de Antigravity (`agy`).

## 2. Instalar el plugin
Desde Claude Code:
```text
/plugin marketplace add cotogonzalo500-png/Multi-IA-Orchestrator
/plugin install multi-ia-orquestador@multi-ia
```
O desde una terminal:
```bash
claude plugin marketplace add cotogonzalo500-png/Multi-IA-Orchestrator
claude plugin install multi-ia-orquestador@multi-ia
```
Para probar desde una copia local (sin GitHub): `claude plugin marketplace add "C:\ruta\a\multi-ia-orquestador"` (con comillas si la ruta tiene espacios).

Los comandos que empiezan con `/plugin` se escriben **dentro de Claude Code**; los de `claude plugin ...` van en una terminal. Reiniciá Claude Code para que cargue los hooks y el panel. Para comprobar que quedó instalado, escribí `/multi-ia-orquestador:configurar` (si no aparece, repetí `claude plugin install multi-ia-orquestador@multi-ia` y revisá el mensaje de error).
Si no tenés Claude Code o Node.js: Claude Code en https://code.claude.com/docs y Node.js (LTS) en https://nodejs.org. Comprobá con `claude --version` y `node --version`.

## 3. Primer inicio: `/configurar`
El asistente:
1. Comprueba Windows, PowerShell, Node.js y que se pueda escribir en la carpeta de datos (`%USERPROFILE%\.multi-ia-orquestador` o `MULTIIA_DATOS`).
2. Si no existe una configuración, crea la de por defecto: modo **automático**, intensidad **automático**, calidad **equilibrada**. Si ya existe, no la toca.
3. Arranca las métricas vacías: no inventa datos.
4. Detecta Codex y Antigravity (instalación, versión y autenticación cuando se puede saber sin gastar cupo).
5. Muestra los pasos que faltan y las limitaciones.

`/configurar probar` además le manda **una** tarea mínima real a cada motor instalado, y eso gasta un poco de su cupo.

## 4. Conectar los motores (opcional)
**Codex (OpenAI)**
```bash
npm install -g @openai/codex
codex login
codex login status
```
Si PowerShell no deja correr `codex` por la política de ejecución (error «la ejecución de scripts está deshabilitada»), usá `codex.cmd login` y `codex.cmd login status`: no hace falta cambiar ninguna política ni ser administrador. Si `npm` también está bloqueado, usá `npm.cmd install -g @openai/codex`. También vale la app de escritorio de Codex. Si `codex.exe` está en otro lugar, definí `MULTIIA_CODEX_EXE` con la ruta completa.

**Antigravity (Google)**: instalá la CLI con la guía oficial (https://antigravity.google/docs/getting-started?tab=cli; en PowerShell: `irm https://antigravity.google/cli/install.ps1 | iex`). Abrí `agy` una vez en una terminal: usa el llavero de Windows y, si no hay sesión, abre el navegador para el login de Google (en SSH muestra una URL y un código; también se admite GEMINI_API_KEY). No hay comando de login separado; `/logout` dentro de agy cierra la sesión. Para verificarlo, corré `/configurar probar`.

El login lo hace cada persona con su cuenta. El plugin no pide, no lee y no copia credenciales.

## 5. Actualizar
```text
/plugin marketplace update multi-ia
/plugin update multi-ia-orquestador@multi-ia
```
La carpeta de datos se conserva entre versiones.

## 6. Desinstalar
```text
/plugin uninstall multi-ia-orquestador@multi-ia
/plugin marketplace remove multi-ia
```
La carpeta de datos no se borra sola.

## 7. Problemas frecuentes
Ver la tabla «Solución de problemas» en [README.es.md](README.es.md).
