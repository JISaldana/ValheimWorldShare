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

## Configuracion facil para amigos

Al abrir el programa por primera vez, pulsa **Configurar Google Drive**. Se
abrira el asistente oficial de rclone. Cada jugador debe iniciar sesion con su
propia cuenta y usar el mismo nombre de remoto, por ejemplo `gdrive`.

Despues escribe en **Remoto** la ruta compartida, por ejemplo:

```text
gdrive:ValheimWorldShare
```

Escribe el mismo nombre de mundo que usan los demas jugadores y pulsa
**Actualizar estado**. El programa guarda remoto y mundo en
`launcher.config.json`, un archivo local ignorado por Git. No compartas ese
archivo: la autenticacion de Google Drive es personal.

Todos los textos generados durante la ejecucion usan caracteres ASCII para
evitar problemas de lectura en consolas antiguas.

## Google Drive para escritorio

Para usuarios que no quieran configurar rclone, ejecuta:

```powershell
.\launch_valheim_drive.ps1
```

Instala Google Drive para escritorio, inicia sesion y marca la carpeta
compartida como disponible sin conexion. La carpeta puede estar en una unidad
montada como `G:\` o en cualquier otra ruta local sincronizada. En la interfaz
pulsa **Choose folder** y selecciona la carpeta local sincronizada. Todos los jugadores deben elegir
la misma carpeta compartida, usar el mismo nombre de mundo y pulsar **Test
folder** antes de iniciar.

Este modo usa la carpeta local de Google Drive para leer y escribir archivos.
Conserva el mismo archivo `server.lock` para evitar sesiones simultaneas. El
modo rclone permanece disponible en `launch_valheim.ps1` y no comparte codigo
de configuracion con este modo.