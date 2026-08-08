# CLAUDE.md — contexto del proyecto

Notas de trabajo para quien retome esto (persona o agente). El README es
para quien va a *usar* PiThin; esto es para quien va a *tocarlo*.

---

## Qué es

Convierte una **Raspberry Pi Zero 2 W** en un cliente ligero de
escritorio remoto. Arranca, se conecta a una WiFi conocida, levanta un
túnel Tailscale y abre a pantalla completa la sesión RDP de un PC con
Windows 11 Pro. Sin escritorio, sin gestor de ventanas y —por defecto—
sin servidor X.

Es un aparato de bolsillo: lo enchufas a cualquier pantalla con un
teclado y un ratón y tienes tu ordenador delante.

## Estado

| | |
|---|---|
| Fase A | Aprovisionamiento sobre Raspberry Pi OS Lite. **Hecha** |
| Fase A.5 | Perfiles, SDL/KMSDRM, control de salida. **Hecha** |
| Fase B | Imagen `.img.xz` con pi-gen + GitHub Actions. **Pendiente** |
| Verificación en hardware real | **NADA. Cero.** |

Lo último es importante y conviene no olvidarlo: **el proyecto entero
está sin probar en una Raspberry**. Todo lo verificado se ha verificado
en un contenedor x86 con entornos simulados.

---

## Cómo trabajar aquí

```bash
./pruebas/todas.sh          # 142 pruebas + shellcheck. Sin root, sin Raspberry
sudo ./install.sh           # instalación completa
sudo ./install.sh --solo-ficheros   # recarga scripts en segundos: para iterar
sudo ./install.sh --desinstalar
pithin-menu                 # abrir el menú sin reiniciar
```

`shellcheck` debe quedar **sin ningún aviso**. Está integrado en
`todas.sh`.

### Estructura

```
install.sh              Instalador idempotente
boot-ejemplo/           Plantillas para la partición de arranque
src/lib/                Módulos (se cargan con source)
src/bin/                Ejecutables
pruebas/                Pruebas + lanzador
docs/                   Viabilidad, rendimiento, instalación, Windows, seguridad
```

### Grafo de módulos

Importa el orden: `pithin-common.sh` fija las rutas y todos dependen de
él.

```
common ──┬── config ── pantalla
         ├── pantalla
         ├── crypto
         ├── wifi
         ├── vpn
         ├── rdp ── pantalla
         ├── tui ── crypto
         └── menus ── (tui, config, perfiles, pantalla, wifi, vpn, rdp)
                          └── perfiles ── config
```

Cada módulo se protege contra doble carga con `PITHIN_<X>_CARGADO`.

### Convenciones

- **Todo en castellano**: identificadores, mensajes y comentarios. Es
  deliberado y consistente.
- **Las librerías no usan `set -e`**; devuelven códigos y quien llama
  decide. Los ejecutables usan `set -uo pipefail`.
- **Todas las rutas se pueden sustituir desde el entorno**
  (`PITHIN_LIB`, `PITHIN_BOOT`, `PITHIN_VAR`, `PANTALLA_CMDLINE`,
  `PANTALLA_SYSFS`...). Es lo que permite probar sin instalar.
- Los comentarios explican **por qué**, no qué. Si algo parece raro,
  suele haber una razón escrita al lado.

---

## Decisiones y su justificación

### Por fases, no la imagen directamente

Lo difícil no es construir la imagen: es que la sesión resulte usable
con 512 MB y descodificación por software. Eso exige iterar en minutos.
Con pi-gen, cada ajuste de un parámetro de códec costaría 40 minutos de
build. Los mismos scripts se envolverán como fase de pi-gen en la B.

### arm64, no armhf

Contraintuitivo: armhf ahorraría ~90 MB (un 18% de la RAM total). Pero
**Raspberry Pi OS de 32 bits se compila para ARMv6 + VFP2**, no para el
ARMv7 + VFP3 del armhf de Debian, para seguir arrancando en la Pi 1. Eso
deja **NEON fuera de la línea base**, justo en un aparato cuya carga
principal es descodificar vídeo por software. En arm64, NEON es
obligatorio.

**La decisión es consecuencia de la descodificación, no al revés.** Si
algún día hubiera descodificación por hardware, la CPU dejaría de
importar y armhf pasaría a ser la buena. Por eso la Fase B publicará las
dos imágenes.

### SDL/KMSDRM en vez de servidor X

`freerdp3-sdl` habla con el controlador de pantalla del kernel a través
de SDL3. Ahorra 40-60 MB y una pieza móvil entera, y manda el reescalado
a la GPU.

Se instala **también** el cliente X11, conmutable desde el menú, porque
el fallo típico de KMSDRM es que la imagen aparezca y el teclado no
responda.

### Perfiles, no mandos sueltos

Cinco ejes (backend, resolución, salida, códec, color) dan casi
doscientas combinaciones. No se pueden probar, y las que no se prueban
acaban rotas justo cuando hacen falta. Cuatro perfiles probados como
puerta de entrada; los ajustes individuales siguen accesibles, pero al
tocar uno el perfil pasa a `personalizado` y se dejan de hacer promesas.

### Sesión de prueba con tiempo limitado

Si el teclado no funciona dentro de la sesión, **tampoco se puede salir
de ella**. No hay escapatoria desde dentro, así que la única defensa
posible es que se cierre sola. Primera sesión con un backend nuevo: 45
segundos, se cierra, y la consola de texto —donde el teclado sí funciona,
porque es el del kernel y no tiene nada que ver con SDL— pregunta si
respondía.

### Todo corre como root

Aparato de un solo propósito y un solo usuario físico: quien está
delante del teclado ya controla el equipo. Separar privilegios exigiría
sudoers, polkit y pasar la contraseña descifrada entre dominios de
privilegio. Complejidad sin ganancia real. La consecuencia asumida es
que Xorg corre como root cuando se usa el backend x11.

### Credencial: Argon2id + serial del SoC

Un PIN corto tiene poca entropía y **eso no lo arregla ningún
algoritmo**. Tres refuerzos:

1. **Argon2id** (m=64 MiB, t=3): memory-hard, arruina el paralelismo en
   GPU. Los parámetros se guardan junto al fichero para poder subirlos
   sin invalidar credenciales existentes.
2. **La clave se deriva del PIN Y del serial del SoC**. Copiar la
   tarjeta a otro equipo no sirve. Cubre el escenario realista.
3. Mínimo 6 caracteres, se recomiendan letras. Espera creciente tras
   fallos.

La credencial vive en **ext4**, no en la partición FAT32 de arranque.

### Tailscale, no RDP expuesto

El 3389 abierto a Internet es la vía de entrada nº1 de ransomware.
Tailscale da el mismo resultado sin abrir nada en el router.

La auth key **debe llevar etiqueta ACL**: los nodos etiquetados tienen
desactivada la caducidad de clave. Sin etiqueta, la Raspberry se sale
del tailnet a los 180 días sin avisar.

### Sin cifrado de disco completo

La Raspberry no tiene TPM ni elemento seguro, así que cifrar la raíz
obligaría a teclear una contraseña larga **antes** de que exista
interfaz para pedirla, en cada arranque. Rompe justo el objetivo del
aparato. Se cifra solo el secreto que importa y se ata al hardware.

---

## Errores encontrados y resueltos

Merece la pena leerlos: varios son trampas de bash que volverán a
aparecer.

### Colisión de ámbito dinámico *(la peor)*

`wifi_guardar_en_fichero` pasaba un callback a `_wifi_recorrer_fichero`
que comparaba contra `$ssid`. Pero **bash tiene ámbito dinámico**: dentro
del recorrido, `$ssid` resuelve a la variable local *del recorrido* —el
SSID que está parseando— no a la de quien llamó.

Resultado: toda red parecía existir ya y **ninguna red nueva llegaba a
guardarse jamás**. Silencioso, devolvía éxito.

Arreglado prefijando las variables (`nueva_ssid`, `nueva_clave`). Hay un
comentario en el código avisando. **Cuidado al añadir callbacks nuevos.**

### `PITHIN_LIB` sobrescrito

`pithin-common.sh` asignaba las rutas incondicionalmente, pisando lo que
hubiera en el entorno. Imposible ejecutar nada desde el árbol de fuentes
sin instalarlo antes. Ahora todas usan `${VAR:-defecto}`.

### `/smart-sizing` escalaba en la CPU

Error de diseño de la Fase A: se añadía siempre que la resolución de
sesión no coincidía con la de pantalla. `/smart-sizing` escala por
software, así que en el aparato con menos CPU del catálogo metía un
reescalado de 2,25× por fotograma en el procesador, comiéndose el ahorro
que justificaba bajar a 720p.

### `es_si` como última orden de un grupo

```bash
{ ...; es_si "$oculta" && printf '...'; } >>fichero || { error; return 1; }
```

Con `oculta="no"`, `es_si` devuelve 1, el grupo entero devuelve 1 y se
disparaba la rama de error aunque la escritura hubiera ido bien.
**Cuidado con dejar una condición como última orden de un bloque.**

### `tui_esperando` devolvía el código de whiptail

La orden corría dentro de una tubería hacia el `--gauge`, así que el
estado del conjunto era el de whiptail: siempre 0. Cualquier
comprobación de "¿ha conectado?" habría dicho que sí. Se traspasa por
un fichero en tmpfs.

### `_pithin_log` usaba `$2` tras `shift`

Se pretendía leer una prioridad y se estaba leyendo la segunda palabra
del mensaje. Ahora se deriva del nivel.

### `set -e` + `(( VAR )) && funcion`

En `install.sh`, con `--sin-paquetes` la condición aritmética devuelve 1,
la lista `&&` falla y `set -e` abortaba la instalación entera. Sustituido
por `if`.

### Otros

- `_wifi_definir_perfil` usaba `"${args[@]:6}"` — aritmética de índices
  frágil que además duplicaba el SSID.
- `asistente_wifi` mostraba una barra de progreso falsa y luego volvía a
  escanear para saber si la red pedía clave. Ahora cachea el escaneo.
- `RDP_ULTIMO_CODIGO` era código muerto.

---

## Gotchas

### bash y las herramientas

| | |
|---|---|
| **whiptail dibuja por stdout** | El resultado sale por stderr. Dentro de `$(...)` hay que usar `2>&1 1>/dev/tty`, **en ese orden**. Verificado empíricamente |
| **shellcheck SC2069** | Marca ese idioma como error. Es **falso positivo**; hay `disable` con explicación |
| **Comentarios que empiezan por "shellcheck"** | `# shellcheck no ve tal cosa` se parsea como directiva y da SC1072. No empezar comentarios con esa palabra |
| **shellcheck 0.9 y UTF-8** | Revienta con `commitBuffer: invalid argument` sin `LC_ALL=C.UTF-8`. Ya va en `todas.sh` |
| **SC2153 / SC2034 / SC2317** | Falsos positivos constantes por variables de configuración de otro módulo y callbacks indirectos |

### Ficheros peligrosos

| | |
|---|---|
| **`cmdline.txt`** | **Una sola línea.** Romperlo deja el equipo sin arrancar. `pithin-pantalla.sh` valida que siga habiendo `root=`, que no esté vacío y que no tenga saltos. Media suite de pruebas es sobre esto |
| **Modos de vídeo** | Forzar uno que el monitor no anuncie da **pantalla en negro**. Se comprueba contra `/sys/class/drm/*/modes` antes de escribir |
| **Partición de arranque** | FAT32, la lee cualquiera. Ahí no puede haber nada que merezca protección |

### Hardware

| | |
|---|---|
| WiFi | **Solo 2,4 GHz.** Ni rastro de 5 GHz |
| micro-USB | El de **datos es el del centro**; el del borde es solo alimentación. Error de montaje habitual |
| RAM | 512 MB y no ampliable |
| Descodificación | Por software. El VPU no es accesible desde FreeRDP |

### Windows

| | |
|---|---|
| Edición | **Pro o superior.** Home no acepta RDP entrante |
| Sesión única | Al conectar, la consola local se bloquea |
| Suspensión | Mata la conexión y Tailscale no puede despertar el equipo |
| Firewall | Hay que permitir 3389 desde `100.64.0.0/10` |
| Cuenta Microsoft | `MicrosoftAccount\\usuario@dominio`, con **doble** barra invertida en el fichero de configuración |

### Paquetes

| | |
|---|---|
| `freerdp3-sdl` | Sin dependencias de X11... pero **`libsdl3-0` sí las tiene** (`libx11-6`, `libxext6`, `libxrandr2`, `libxcursor1`, `libwayland-client0`, `libdecor-0-0`). Lo que se evita es el *servidor*, no las bibliotecas |
| `libudev1` | Solo **recomendado** de libsdl3. Con `--no-install-recommends` se queda fuera y **SDL se queda sin entrada**. El instalador lo fuerza |
| Versión | Trixie trae FreeRDP **3.15.0**; el cliente SDL3 dejó de ser experimental en la **3.16**. Una versión antes |
| Sintaxis de `/gfx` | Varía entre versiones. Hay reintento automático con configuración mínima si FreeRDP rechaza los argumentos |

### Este entorno de trabajo

El proxy del agente **bloquea escrituras de configuración de repositorio
y borrado de refs**:

```
PATCH /repos/{owner}/{repo}        → 403 settings writes not permitted
DELETE /repos/.../git/refs/heads/  → 403 write access not permitted
git push --delete                   → send-pack: unexpected disconnect
```

Cambiar la rama por defecto o borrar ramas lo tiene que hacer una
persona desde la web. Los `git push` normales sí funcionan.

---

## Caminos explorados y descartados

| Camino | Por qué no |
|---|---|
| **rpi-image-gen** | Más moderno que pi-gen, pero más reciente y menos rodado en CI. Queda como alternativa de repuesto |
| **Sunshine + Moonlight-embedded** | Sí da descodificación hardware **hoy**, sin escribir nada. Pero peor nitidez de texto y 10-20 Mbps, que en 2,4 GHz duele. Posible segundo perfil futuro |
| **Cliente RDP propio** | RDP no es un protocolo, es una familia: CredSSP/NLA, licenciamiento, negociación de capacidades, EGFX, RemoteFX, progressive, formato de cable de AVC420/444. FreeRDP lleva 23.000 commits y 419 contribuidores |
| **Servidor propio para Windows** | Captura DXGI + NVENC/AMF/QSV + transporte con control de congestión + inyección de entrada. Meses para llegar a algo peor que Sunshine |
| **Escalado por HVS** | El VideoCore puede escalar durante el escaneo: framebuffer de 720p, señal de 1080p, gratis. **Sin verificar** que SDL3 lo aproveche; su backend KMSDRM probablemente renderice al tamaño del modo |
| **Usuario sin privilegios** | Complejidad sin ganancia en un aparato de un solo usuario físico |
| **Exponer RDP a Internet** | Vía de entrada nº1 de ransomware |

### Aceleración por hardware: el estado real

Tres razones encadenadas, y la tercera es la esperanzadora:

1. **VAAPI no existe en este chip.** El hwaccel de FreeRDP es VAAPI; el
   VideoCore IV no tiene driver. Además FreeRDP tiene
   `/dev/dri/renderD128` escrito a fuego (`FreeRDP#12779`).
2. **`h264_v4l2m2m` está roto.** Funciona en kernel 5.15 y se cuelga en
   6.6.63 (`raspberrypi/linux#6554`, confirmado en OpenWrt). Raspberry Pi
   OS ya va por 6.18.
3. **Pero el hardware funciona.** *ZeroPlay* usa V4L2 M2M por ioctls
   directos —sin FFmpeg— y saca por DRM/KMS atómico con DMABUF
   zero-copy, con soporte explícito para Pi Zero 2 W sobre Trixie.

**Lo tratable:** añadir `g_Subsystem_v4l2m2m` a la capa H.264 de FreeRDP,
que ya tiene esa abstracción (`OpenH264`, `libavcodec`, `mediacodec`,
`MF`). **El backend de Android es la plantilla exacta**: mismo problema
de decodificador hardware externo con buffers que no son memoria normal.
Estimación 800-1500 líneas de C.

**Pero antes conviene preguntarse si hace falta.** RDP con códec
progressive cuesta en proporción a los **píxeles que cambian**; H.264
descodifica **fotogramas completos de forma continua**. Para trabajo de
escritorio, progressive a 720p con escalado por GPU probablemente rinda
mejor que AVC420 con hardware. La aceleración gana en vídeo y poco más.

---

## Dónde acaba la contraseña

Fácil de filtrar sin querer, así que conviene tenerlo presente al tocar
`pithin-rdp.sh` o `pithin-tui.sh`:

- **No va en argv.** `/proc/PID/cmdline` lo lee cualquier proceso. Se usa
  `/args-from:<fichero>` de FreeRDP 3 con permisos 0600.
- **No toca la SD.** Ese fichero y el de traspaso entre la consola y la
  sesión viven en `/run` (tmpfs).
- **No aparece en el registro.** Los argumentos se censuran antes de
  escribirlos y la salida de `tailscale up` se filtra para que la auth
  key no acabe en el log.
- **El fichero de traspaso se destruye al leerlo**, no al terminar.

Con FreeRDP 2 no hay `/args-from:` y la contraseña sí quedaría visible.
El instalador avisa si cae a esa versión.

---

## Qué NO está verificado

Que quede claro, porque es fácil leer "142 pruebas en verde" y confiarse.

**Verificado** (en contenedor x86, con entornos simulados): análisis de
los dos ficheros de configuración incluidos CRLF y símbolos raros; ciclo
completo de cifrado incluida la negativa a descifrar desde otro
dispositivo; manipulación y salvaguardas de `cmdline.txt`; perfiles y
reversión; mapeo de teclado.

**Sin verificar** (necesita la Raspberry):

- Que SDL/KMSDRM tome la pantalla
- **Que llegue la entrada de teclado y ratón** — el riesgo principal
- Que el escalado por GPU se comporte
- Las pantallas de whiptail sobre un monitor real
- NetworkManager, Tailscale y la sesión RDP de verdad
- La sintaxis exacta de `/gfx` en la 3.15.0
- **Las cifras de fluidez.** Son estimación, no medida

---

## Próximos pasos

1. **Probar en hardware.** Flashear Lite 64-bit, `sudo ./install.sh`,
   arrancar. Lo que decide la Fase B: ¿SDL da teclado? ¿720p escalado es
   suficiente?
2. **Fase B**: fase personalizada de pi-gen + workflow de GitHub Actions
   con matriz **arm64 + armhf**, publicando `.img.xz` como release.
3. **Opcionales**, en orden de coste: perfil Moonlight como segundo
   modo; verificar el escalado por HVS; el backend `v4l2m2m` para
   FreeRDP.
