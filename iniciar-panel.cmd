@echo off
rem Abre el panel de uso con el boton de modo (servidor local en 127.0.0.1, nada sale de tu maquina). Cerrar esta ventana apaga el servidor.
rem El panel se actualiza cuando Claude lo regenera (panel.ps1); recargar la pagina para verlo.
start "" "http://127.0.0.1:8765/"
node "%~dp0scripts\panel-servidor.mjs"
pause
