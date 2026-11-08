# Ejemplos

## Delegar una revisión de código a Codex (solo lectura)
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<carpeta-del-plugin>\scripts\delegar.ps1" -Tarea revision -Carpeta C:\mi\proyecto -Prompt "Busca bugs en src\ y lista archivo:linea"
```

## Resumir un documento largo con Antigravity
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<carpeta-del-plugin>\scripts\delegar.ps1" -Tarea texto -Archivo C:\docs\informe.md -Prompt "Resumen en 10 puntos"
```

## Ver o cambiar la intensidad
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<carpeta-del-plugin>\scripts\config.ps1" -Ver
```

## Usar otra carpeta de datos (por ejemplo, para pruebas)
```powershell
$env:MULTIIA_DATOS = "$env:TEMP\multiia-pruebas"
```

En el uso normal no hace falta correr nada a mano: Claude decide cuándo delegar. `config.ejemplo.json` muestra la configuración por defecto.
