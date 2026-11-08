# Contribuir

1. Trabajá en Windows con Windows PowerShell 5.1 y Node.js 18 o superior.
2. Los `.ps1` se guardan en **UTF-8 con BOM**: hay una prueba que lo exige.
3. Antes de mandar un cambio, corré:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File tests\probar.ps1
   claude plugin validate .
   claude plugin test .
   ```
   Usá una carpeta de datos aislada: `$env:MULTIIA_DATOS = "$env:TEMP\multiia-pruebas"`.
4. Cada corrección lleva su prueba de regresión. No borres ni debilites pruebas para que pasen.
5. Las pruebas no gastan cupo de los motores: usan `MULTIIA_SIMULAR_OK` y datos sembrados. Una prueba simulada no reemplaza una integración real; si probaste contra un motor real, decilo en el PR.
6. Nunca subas datos personales, rutas de tu máquina, tokens ni archivos de sesión. El CI rechaza los patrones de secretos más comunes.
7. Documentá los cambios en `CHANGELOG.md`.
