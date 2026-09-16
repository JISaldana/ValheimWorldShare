# ValheimWorldShare

Lanzador de sesiones de Valheim con sincronización de mundos mediante Google
Drive y [rclone](https://rclone.org/).

## Configuración

1. Instala PowerShell 5.1 o posterior y configura rclone con `rclone config`.
   El lanzador descargará una copia portable en `.tools/` si no encuentra
   `rclone.exe` en el sistema.
2. Edita los valores opcionales al ejecutar el script: `-Remote`, `-WorldName`,
   `-ServerExecutable` y `-WorldDirectory`.
3. Ejecuta:

   ```powershell
   .\launch_valheim.ps1
   ```

El archivo `server.lock` evita que dos jugadores inicien sesiones al mismo
tiempo. Si una sesión se cierra abruptamente, usa **Liberación manual** solo
después de confirmar que nadie está jugando. Los mundos locales se respaldan
antes de sobrescribirse y los logs quedan en `logs/`.

La interfaz muestra el mundo, remoto y ejecutable configurados, el estado del
bloqueo remoto, el progreso de la sesión y una consola de eventos. **Actualizar
estado** consulta el bloqueo sin iniciar una partida; **Liberar bloqueo** debe
usarse únicamente después de verificar que ningún jugador está conectado.

El remoto debe ser una ruta de rclone accesible por todos los jugadores, por
ejemplo `gdrive:valheim-world`. Los archivos `.db` y `.fwl` se guardan dentro
de una subcarpeta con el nombre del mundo.