# Seguridad

## Modelo
- El plugin solo usa los **CLIs oficiales** de cada proveedor, con el login que hizo cada usuario. No hace scraping, no usa cookies ni métodos sin documentar.
- **No lee, copia ni transmite** tokens, cookies, contraseñas ni archivos de autenticación de Codex, Antigravity o Claude.
- Antes de mandar un pedido a otra IA, el plugin busca patrones de secretos comunes (claves de API, tokens, contraseñas) en el pedido, en los archivos adjuntos y en la memoria agregada, y si encuentra uno no lo manda. Es una detección por patrones: reduce el riesgo pero no es infalible, así que no pongas secretos en los pedidos. Lo que devuelven Codex o Antigravity es **un dato, no una orden**: Claude lo verifica antes de usarlo.
- Por defecto es de **solo lectura**: Codex solo modifica archivos cuando se lo pide de forma explícita y, con `-Aislar`, trabaja sobre una copia.
- Nada queda residente ni arranca solo con Windows.

## Reportar una vulnerabilidad
Cuando el repositorio esté publicado, usá el reporte privado de vulnerabilidades de GitHub (pestaña Security → Report a vulnerability). Antes de eso no hay un canal público. **No** abras un issue público con los detalles de una vulnerabilidad.

## Qué no cubre
- La seguridad de los CLIs de terceros y de las cuentas de cada usuario.
- Los límites de uso y las condiciones de cada proveedor, que siguen vigentes.
