# **EspecificaciÃ³n TÃ©cnica: Valheim Auto-Sync Launcher (Google Drive)**

Este documento detalla los requerimientos y la lÃ³gica de implementaciÃ³n para un sistema de orquestaciÃ³n de servidores de Valheim basado en almacenamiento en la nube, diseÃ±ado para facilitar partidas cooperativas sin la necesidad de un servidor dedicado permanente.

# **1\. Arquitectura del Sistema**

## **Objetivo**

Eliminar la dependencia de un Ãºnico host "siempre activo" permitiendo que cualquier miembro de un grupo de juego inicie el mundo de Valheim, asegurando que el progreso se sincronice globalmente y evitando la corrupciÃ³n de datos por accesos simultÃ¡neos.

## **Mecanismo de Almacenamiento**

El sistema utiliza la infraestructura de Google Drive como repositorio central de archivos de guardado. Se recomienda el uso de **rclone** debido a su capacidad de gestiÃ³n de archivos remotos mediante lÃ­nea de comandos, permitiendo una integraciÃ³n transparente dentro de scripts de automatizaciÃ³n.

## **Componentes Clave**

| Componente | DescripciÃ³n |
| :---- | :---- |
| **Script de Lanzamiento** | Ejecutable principal (`launch_valheim.ps1`) encargado de la lÃ³gica de negocio y sincronizaciÃ³n. |
| **Archivos del Mundo** | Archivos binarios `.db` (base de datos) y `.fwl` (metadatos del mundo) que residen en la carpeta local de IronGate. |
| **SemÃ¡foro de Bloqueo** | Un archivo `server.lock` en la nube que actÃºa como sistema de exclusiÃ³n mutua (Mutex). |
| **Valheim Server Exec** | El binario original de Valheim configurado para ejecutarse en modo servidor local. |

# **2\. Diagrama de Flujo del Script**

La ejecuciÃ³n del script sigue un ciclo de vida estrictamente secuencial para garantizar la integridad de los datos:

## **Fase 1: VerificaciÃ³n de Bloqueo**

El script realiza una peticiÃ³n al almacenamiento remoto para buscar el archivo `server.lock`.

* **Si el archivo existe:** El script lee el contenido (que debe incluir el nombre del usuario actual) y muestra una alerta: *"El servidor estÃ¡ siendo hosteado por \[Nombre/Amigo\]. Por favor espera a que termine."*. El proceso se detiene inmediatamente.
* **Si el archivo no existe:** Se procede a la fase de comparaciÃ³n.

## **Fase 2: ComparaciÃ³n de Fechas y Descarga**

Se comparan los metadatos de los archivos locales en `%AppData%\LocalLow\IronGate\Valheim\worlds_local` con los archivos en Google Drive.

* Si la versiÃ³n remota posee una marca de tiempo mÃ¡s reciente, el script descarga y reemplaza los archivos locales.
* Se genera una copia de seguridad local (`.bak`) antes del reemplazo por seguridad.

## **Fase 3: CreaciÃ³n del Bloqueo Local y Subida**

Antes de iniciar el binario del juego, el script genera un nuevo archivo `server.lock` localmente que contiene el nombre del host actual y lo sube a la raÃ­z de la carpeta configurada en Google Drive. Esto notifica a otros usuarios que el mundo estÃ¡ "En Uso".

## **Fase 4: EjecuciÃ³n del Servidor**

Se invoca el ejecutable del servidor con los parÃ¡metros necesarios para la sesiÃ³n:

* Comando: `valheim_server.exe -nographics -batchmode -world "<span type="placeholder" placeholder-type="person"></span>" -password "<span type="placeholder" placeholder-type="person"></span>"`
* El script entra en estado de espera activa (`Wait-Process`) hasta que el usuario cierra el servidor o el proceso termina.

## **Fase 5: Subida de Cambios y LiberaciÃ³n**

Tras el cierre del proceso `valheim_server.exe`:

1. Se sincronizan los archivos `.db` y `.fwl` actualizados hacia la nube.
2. Se elimina el archivo `server.lock` del almacenamiento remoto.
3. Se muestra una confirmaciÃ³n visual de que la sesiÃ³n se ha guardado correctamente.

# **3\. Instrucciones de ConstrucciÃ³n para Agentes de IA**

Para la implementaciÃ³n automatizada, los agentes de IA deben seguir estas directrices tÃ©cnicas:

## **InstalaciÃ³n y AutenticaciÃ³n**

* **rclone Portable**: El script debe descargar una versiÃ³n portable de `rclone` si no se detecta en el sistema.
* **OAuth2 Flow**: Implementar una funciÃ³n de configuraciÃ³n inicial que guÃ­e al usuario para vincular su cuenta de Google Drive mediante el comando `rclone config` de forma guiada.

## **DiseÃ±o de la Interfaz GrÃ¡fica (GUI)**

La interfaz debe ser minimalista y utilizar cÃ³digos de color para estados de salud del sistema:

* **Panel de Estado**:
  * **Verde (\#22C55E)**: "Servidor disponible. Haz clic para iniciar."
  * **Rojo (\#EF4444)**: "Servidor ocupado por \[Nombre\]." (Bloquea el botÃ³n de inicio).
  * **Azul (\#3B82F6)**: "Sincronizando partida... No cierres la ventana."
* **Log de Eventos**: Una pequeÃ±a consola integrada que muestre el progreso de subida/descarga en bytes o porcentaje.

## **Manejo de Errores y Robustez**

* **Cierre Abrupto**: Si el script detecta que `server.lock` persiste pero el proceso no estÃ¡ corriendo (debido a un crash o falta de luz), debe ofrecer un botÃ³n de "LiberaciÃ³n Manual" tras una advertencia de riesgo de colisiÃ³n.
* **Timeout**: Implementar un tiempo de espera mÃ¡ximo para las peticiones de red para evitar que la interfaz se congele si Google Drive no responde.
* **VerificaciÃ³n de Hash**: Opcionalmente, comparar el hash MD5 de los archivos despuÃ©s de la subida para asegurar que no hubo corrupciÃ³n durante la transferencia.

File *Documento de Referencia de ParÃ¡metros de Valheim*
