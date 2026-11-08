# Multi-IA Orquestador (Community Edition)

> Leelo en castellano: [README.es.md](README.es.md)

A Claude Code plugin that lets Claude **delegate** large or independent pieces of work (code review, long texts, document analysis, second opinions) to **Codex** (OpenAI) and **Antigravity** (Google), using **your own accounts**, so that you use up less of your Claude allowance. Claude stays in charge. It picks the engine, runs the official CLI, checks what comes back, and treats every delegated answer as data, never as instructions.

**Status:** pre-release, **Windows only**. The plugin is tested on Windows 10/11 with Windows PowerShell 5.1 and Node.js 18 or later. It has not been tested on macOS or Linux and is not supported there.

## What it does
- A single entry point (`scripts/delegar.ps1`) picks the engine, model and effort level for each task based on the mode (automatic or manual), the quality you ask for and the allowance you have left.
- **Intensity** controls how much it delegates: `automatico` (default), `bajo`, `medio`, `alto`.
- A **context guard** hook warns you when the Claude session gets large or the prompt cache has expired.
- A **dashboard** pane shows activity, usage, engine status and system health. Savings figures are estimates built from recorded runs, and missing data shows as "no data", never as zero.
- Session handoff, shared memory across engines, and an audit trail of which engine actually ran each task.

## Requirements
| Item | Required | Notes |
|---|---|---|
| Windows 10/11 | yes | Windows PowerShell 5.1, which ships with Windows |
| Claude Code | yes | with plugin support |
| Node.js ≥ 18 | yes | used by the hooks, the status line and the dashboard |
| Codex CLI | optional | `npm install -g @openai/codex`, then `codex login` |
| Antigravity CLI (`agy`) | optional | install it from Google's official instructions and sign in when it asks |

Without Codex and without Antigravity the plugin still installs and works, but it cannot delegate anything. Claude does all the work in that case.

## Install (official plugin flow)
```text
/plugin marketplace add cotogonzalo500-png/Multi-IA-Orchestrator
/plugin install multi-ia-orquestador@multi-ia
```
Then restart Claude Code and run `/configurar`. Details are in [INSTALLATION.md](INSTALLATION.md) (bilingual ES/EN headings; body in Spanish).

## Connect Codex and Antigravity
Each user signs in **with their own account**, using the vendor's official CLI. The plugin never reads, copies or stores tokens, cookies or session files. It only checks whether the CLI is installed, which version it is, and (for Codex) what `codex login status` reports. Antigravity has no free way to check whether you are signed in, so `/configurar probar` sends one minimal real task to confirm it. That costs a little of that engine's allowance.

## Dashboard
The pane **Multi-IA · consumo** opens by itself beside the chat when a session starts. If you closed it, run `/panel-ia` to open it again. Its **⤢ Expandir** button opens the full view (*Multi-IA · Centro de control*). It reads only local data from your data folder.

## Data folder
`%USERPROFILE%\.multi-ia-orquestador` (you can change it with the `MULTIIA_DATOS` environment variable). It holds the configuration, the usage log and the shared memory. It is never part of the plugin folder, and it is never uploaded anywhere.

## Limitations
- Windows only (see [docs/COMPATIBILIDAD.md](docs/COMPATIBILIDAD.md), in Spanish).
- Each engine's provider limits and terms still apply, and so does each user's quota.
- Savings figures are estimates.
- Antigravity's sign-in can only be confirmed with a real task.

## Troubleshooting
| Symptom | What to do |
|---|---|
| `/configurar` says node is missing | Install Node.js 18+ and restart Claude Code |
| Codex shows "No instalado" | `npm install -g @openai/codex`, open a new terminal, then run `/configurar` again |
| Codex shows "Autenticacion requerida" | Run `codex login` in a terminal |
| Antigravity returns empty answers | Open `agy` once in a terminal and sign in, then run `/configurar probar` |
| Corrupt configuration | Run `/configurar`: it prints the exact command with your install path (`config.ps1 -Recuperar`) |
| Data folder not writable | Set `MULTIIA_DATOS` to a folder you own |

## Uninstall
```text
/plugin uninstall multi-ia-orquestador@multi-ia
/plugin marketplace remove multi-ia
```
Your data folder (`%USERPROFILE%\.multi-ia-orquestador`) is left in place. Delete it by hand if you want it gone.

## More
[INSTALLATION.md](INSTALLATION.md) (ES) · [SECURITY.md](SECURITY.md) (ES) · [PRIVACY.md](PRIVACY.md) (ES) · [CONTRIBUTING.md](CONTRIBUTING.md) (ES) · [CHANGELOG.md](CHANGELOG.md) (ES)

> These documents are currently written in Spanish only (marked **(ES)**). English translations are welcome as contributions.

License: [MIT](LICENSE) for the original code. Codex, Antigravity and Claude Code are third-party products under their own terms.
