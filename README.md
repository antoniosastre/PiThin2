# PiThin2

PiThin2 es un cliente ligero portátil que convierte una pequeña placa en un puesto de acceso a un ordenador remoto. Al arrancar, gestiona la red inalámbrica, establece un túnel privado y abre el escritorio remoto a pantalla completa; sus menús en castellano permiten configurar la conexión y resolver incidencias.

El repositorio contiene el instalador, los módulos de funcionamiento y las pruebas automáticas. La interfaz y la lógica pueden ejecutarse en un entorno local, pero la conexión completa, los periféricos y el rendimiento todavía requieren validación en el hardware de destino.

## Funciones principales

- Arranque automático y reconexión ante fallos recuperables de la sesión remota.
- Redes inalámbricas conocidas con prioridad y asistente para añadir otras.
- Cuatro perfiles de sesión: Equilibrado, Máxima nitidez, Máxima fluidez y Compatibilidad.
- Menús para ajustar destino, pantalla, resolución, códec, color y teclado.
- Credenciales cifradas con desbloqueo mediante PIN (número de identificación personal) y vinculación al dispositivo.
- Diagnóstico de red y conexión, consulta de registros y recuperación del último perfil que funcionó.

## Estado y alcance

La aplicación se identifica como **PiThin** en sus menús y órdenes. Este repositorio se llama **PiThin2**.

| Área | Estado verificable |
|---|---|
| Aprovisionamiento y arranque | Instalador y scripts implementados |
| Perfiles y control de pantalla | Implementados, con pruebas de lógica y configuración |
| Interfaz de texto | Ejecutable desde el árbol de fuentes en un entorno local aislado |
| Pruebas automáticas | 142 casos de módulos y pantalla; no sustituyen una prueba física |
| Hardware de destino y sesión completa | Pendientes de validación en el dispositivo |
| Imagen lista para grabar | Pendiente; se instala sobre un sistema base |

No hay mediciones de fluidez, latencia o consumo verificadas en el hardware de destino. Los perfiles son configuraciones implementadas; sus nombres no garantizan un rendimiento concreto. La descodificación utilizada por el proyecto es por software. No incluye un cliente de vídeo o juegos con aceleración específica.

## Tecnología

| Componente | Tecnología y función |
|---|---|
| Sistema base | [Raspberry Pi OS Lite](https://www.raspberrypi.com/software/operating-systems/), 64 bits |
| Scripts | [Bash](https://www.gnu.org/software/bash/), instalador y módulos en castellano |
| Interfaz | [whiptail / newt](https://pagure.io/newt), menús de texto |
| Escritorio remoto | [FreeRDP](https://www.freerdp.com/), cliente RDP (Remote Desktop Protocol) |
| Pantalla principal | [SDL 3 (Simple DirectMedia Layer)](https://www.libsdl.org/) con KMS/DRM (Kernel Mode Setting / Direct Rendering Manager), sin servidor gráfico intermedio |
| Pantalla alternativa | [X.Org](https://www.x.org/), servidor X11 (X Window System, versión 11) mínimo |
| Red inalámbrica | [NetworkManager](https://networkmanager.dev/), mediante `nmcli` |
| Túnel privado | [Tailscale](https://tailscale.com/), sobre [WireGuard](https://www.wireguard.com/) |
| Credenciales | [Argon2id](https://github.com/P-H-C/phc-winner-argon2) y [OpenSSL](https://www.openssl.org/) |
| Arranque y servicios | [systemd](https://systemd.io/) y compresión de memoria con zram cuando está disponible |
| Análisis estático | [ShellCheck](https://www.shellcheck.net/) |

El instalador intenta instalar FreeRDP 3 para los dos sistemas de vídeo. Si el cliente SDL no está disponible, queda la alternativa X11. También admite FreeRDP 2 como último recurso, con una limitación importante de privacidad descrita en Seguridad.

## Requisitos

- [Raspberry Pi Zero 2 W](https://www.raspberrypi.com/products/raspberry-pi-zero-2-w/), objetivo del proyecto, con 512 MB (megabytes) de memoria y red inalámbrica de 2,4 GHz (gigahercios).
- Tarjeta microSD de al menos 8 GB (gigabytes), fuente adecuada de 5 V (voltios) y 2,5 A (amperios), pantalla y adaptador mini-HDMI (High-Definition Multimedia Interface).
- Teclado y ratón conectados al puerto de datos mediante un adaptador micro-USB OTG (Universal Serial Bus On-The-Go). El puerto marcado `PWR` solo alimenta el equipo.
- Conexión a Internet para instalar paquetes y dar de alta el túnel.
- Un ordenador encendido con [Windows 11 Pro](https://www.microsoft.com/windows/business/windows-11-pro), Enterprise o Education, escritorio remoto activado y permiso para iniciar sesión. La edición Home no admite conexiones entrantes; consulta la [documentación oficial](https://learn.microsoft.com/windows-server/remote/remote-desktop-services/remotepc/remote-desktop-allow-access).
- Una cuenta de Tailscale y ambos dispositivos autorizados en la misma red privada.

El equipo remoto debe permanecer encendido y accesible. La conexión bloquea su consola local; este proyecto no proporciona dos sesiones independientes sobre el mismo equipo.

## Instalación desde cero

La instalación modifica el arranque y configura inicio automático como administrador del sistema. Utiliza una tarjeta y un equipo dedicados a esta función.

### 1. Preparar el ordenador remoto

Activa Escritorio remoto, conserva la autenticación a nivel de red e instala Tailscale. Autoriza únicamente el acceso necesario al equipo y al puerto 3389 en las reglas de la red privada y del cortafuegos. No es necesario publicar ese puerto en Internet.

La guía [Preparar el ordenador remoto](docs/windows.md) detalla el alta y los formatos de usuario. Comprueba la política de caducidad de los dispositivos en tu cuenta antes de utilizarlos fuera de la oficina.

### 2. Grabar y arrancar el sistema base

Graba Raspberry Pi OS Lite de 64 bits con [Raspberry Pi Imager](https://www.raspberrypi.com/software/). Configura un usuario propio, la red inalámbrica y SSH (Secure Shell) para la instalación inicial. Conecta la pantalla y los periféricos al dispositivo.

Desde otro ordenador, entra con el usuario y nombre que hayas configurado:

```bash
ssh usuario@pithin.local
```

### 3. Instalar

En el dispositivo:

```bash
sudo apt update
sudo apt full-upgrade -y
sudo apt install -y git
sudo reboot
```

Vuelve a conectar y ejecuta:

```bash
git clone https://github.com/antoniosastre/PiThin2.git
cd PiThin2
sudo ./install.sh
```

El instalador copia los programas, añade las plantillas que falten, instala dependencias y configura el arranque. Conserva los ficheros de configuración existentes. No ejecutes el instalador completo en el ordenador usado para desarrollar o revisar el repositorio.

### 4. Configurar el destino y las redes

Edita `/boot/firmware/pithin/pithin.conf` y `/boot/firmware/pithin/redes.conf`. En sistemas antiguos sin `/boot/firmware`, la carpeta es `/boot/pithin`.

Ejemplo para una cuenta local del ordenador remoto:

```ini
RDP_HOST="pc-remoto"
RDP_USER="usuario"
PERFIL="equilibrado"
BACKEND="sdl"
RESOLUCION="1280x720"
AUTOCONECTAR="si"
```

`pc-remoto` es un nombre de ejemplo: sustitúyelo por el nombre o la dirección del destino en tu red privada. No incluyas la contraseña del ordenador remoto en este fichero.

Ejemplo de una red inalámbrica:

```ini
[RedEjemplo]
clave = sustituir-por-la-clave-de-la-red
prioridad = 100
```

Elimina las redes de demostración de la plantilla. Cuanto mayor sea la prioridad, antes se intenta una red. La configuración completa está en [boot-ejemplo/pithin.conf](boot-ejemplo/pithin.conf) y [boot-ejemplo/redes.conf](boot-ejemplo/redes.conf).

### 5. Autorizar el túnel y reiniciar

La vía interactiva es:

```bash
sudo tailscale up
tailscale status
sudo reboot
```

Como alternativa, se puede provisionar `tailscale-authkey.txt` en la carpeta de arranque de PiThin. La aplicación intenta retirarlo tras procesarlo, pero no puede hacerlo si la partición está protegida contra escritura. Verifica su retirada y sigue las instrucciones de [seguridad](docs/seguridad.md).

En el primer uso se solicita la contraseña del ordenador remoto y se ofrece guardarla cifrada. La primera sesión con un sistema de vídeo nuevo tiene un límite configurable de 45 segundos por defecto para comprobar si responden el teclado y el ratón. Si la entrada no funciona, el menú permite volver a la alternativa X11.

## Perfiles y pantalla

| Perfil | Sistema de vídeo | Resolución de sesión | Salida de pantalla | Color |
|---|---|---|---|---|
| Equilibrado | SDL | 1280 × 720 | Nativa del monitor | 32 bits |
| Máxima nitidez | SDL | 1920 × 1080 | Nativa del monitor | 32 bits |
| Máxima fluidez | SDL | 1280 × 720 | Igual a la sesión | 16 bits |
| Compatibilidad | X11 | 1920 × 1080 | Nativa del monitor | 32 bits |

Los cuatro perfiles utilizan el códec `progressive`. Los ajustes individuales siguen disponibles y el perfil pasa a Personalizado cuando dejan de coincidir con una definición.

Forzar la salida a la resolución de sesión cambia `cmdline.txt` y requiere reiniciar. El código verifica que el monitor anuncie ese modo y protege la estructura del fichero. El comportamiento de escalado, la compatibilidad del monitor y la entrada de periféricos deben comprobarse físicamente antes de dar el puesto por operativo.

## Uso y mantenimiento

Al arrancar hay una ventana de cortesía para entrar al menú antes de conectar. También se puede abrir desde una consola:

```bash
pithin-menu
```

Desde ahí se accede a perfiles, pantalla, redes, conexión, credenciales, diagnóstico y apagado. La reconexión actúa sobre errores recuperables; un cierre de sesión remoto no se trata como una caída de red.

Para consultar registros:

```bash
tail -f /var/log/pithin.log
cat /run/pithin/sesion.log
```

Opciones del instalador:

| Opción | Alcance |
|---|---|
| `--solo-ficheros` | Copia los programas sin instalar paquetes ni configurar el sistema |
| `--sin-paquetes` | Omite los paquetes generales; Tailscale se controla por separado |
| `--sin-tailscale` | Omite la instalación de Tailscale |
| `--desinstalar` | Retira los programas y revierte los ajustes del sistema previstos por el instalador |

La desinstalación conserva la configuración, las credenciales y los paquetes instalados. No equivale a borrar la tarjeta. Para actualizar manualmente, revisa los cambios y vuelve a ejecutar el instalador; `--solo-ficheros` no aplica nuevas dependencias ni cambios de configuración del sistema.

## Seguridad y límites

- La contraseña remota se cifra con una clave derivada del PIN y del identificador del dispositivo. No es cifrado completo de disco; un PIN corto sigue ofreciendo poca resistencia y el formato no incluye autenticación criptográfica del contenido.
- Con FreeRDP 3, los argumentos sensibles se pasan por un fichero temporal de acceso restringido. Con FreeRDP 2, la contraseña puede quedar visible en la lista de procesos.
- Las claves de las redes inalámbricas se guardan en texto plano en la partición de arranque. Quien tenga la tarjeta puede leerlas.
- La configuración utiliza `IGNORAR_CERTIFICADO="si"` por defecto. Si se cambia el modelo de conexión, debe revisarse la validación del certificado del servidor; no presupongas la protección del túnel cuando no exista.
- Los programas funcionan con privilegios de administrador del sistema. El control físico del terminal forma parte del modelo de confianza.

Consulta el [modelo de seguridad](docs/seguridad.md) antes de guardar credenciales o entregar un equipo a otra persona.

## Pruebas

Las pruebas no requieren el dispositivo físico ni privilegios de administrador. Necesitan Bash, Argon2, OpenSSL y las utilidades habituales del sistema. El análisis estático se ejecuta solo si ShellCheck está disponible.

```bash
./pruebas/todas.sh
```

La suite contiene 66 casos de módulos y 76 de pantalla y perfiles. Cubre configuración, redes simuladas, cifrado y vinculación al dispositivo, teclado, modos de pantalla, preservación de `cmdline.txt` y restauración de perfiles.

El proyecto documentaba ShellCheck 0.9.0 como referencia. Con ShellCheck 0.11.0 aparecen avisos `SC2329` sobre funciones usadas indirectamente y la suite devuelve error; conviene revisar esa compatibilidad antes de actualizar el analizador. No se deben presentar las pruebas simuladas como validación del túnel, de una sesión remota o de la pantalla física.

## Estructura y documentación

```text
install.sh       Instalador y desinstalador
boot-ejemplo/    Plantillas de configuración
src/bin/         Arranque, sesión y menú
src/lib/         Red, pantalla, perfiles, cifrado y menús
pruebas/         Pruebas de módulos y pantalla
docs/            Instalación, destino remoto, seguridad y diseño
LICENSE.md       Licencia de esta distribución
LICENSES/        Aviso de licencia conservado del código previo
```

- [Instalación detallada y resolución de incidencias](docs/instalacion.md).
- [Preparación del ordenador remoto](docs/windows.md).
- [Modelo de seguridad](docs/seguridad.md).
- [Decisiones y estimaciones de rendimiento](docs/rendimiento.md).
- [Análisis de viabilidad](docs/viabilidad.md).

Las estimaciones de los documentos de diseño son hipótesis pendientes de medición. Los próximos pasos documentados son validar el equipo real y, después, preparar una imagen grabable mediante [pi-gen](https://github.com/RPi-Distro/pi-gen). La imagen y las alternativas de aceleración no forman parte de las funciones entregadas.

## Licencia y atribuciones

Esta distribución de PiThin2 se ofrece bajo la [GPL 3.0 (Licencia Pública General, versión 3)](LICENSE.md), cuyo [texto oficial](https://www.gnu.org/licenses/gpl-3.0.html) se incluye íntegro. Copyright © 2026 Antonio Sastre.

El código preexistente se publicó bajo la [licencia MIT (Massachusetts Institute of Technology)](https://opensource.org/license/mit). Su aviso y atribución se conservan íntegros en [LICENSES/MIT-original.txt](LICENSES/MIT-original.txt). Esta actualización no revoca los permisos concedidos sobre las versiones anteriores.

Los programas externos que instala o utiliza PiThin2 conservan sus licencias y titulares correspondientes; no se les atribuye la licencia de este repositorio. Sus fuentes no se incorporan al árbol del proyecto.
