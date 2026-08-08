# Análisis de viabilidad

Documento fundacional del proyecto. Recoge el análisis previo a la
implementación, los límites físicos del hardware y las decisiones tomadas.

## Objetivo

Una imagen flasheable para **Raspberry Pi Zero 2 W** que, arrancando con solo
pantalla HDMI, teclado y ratón conectados:

1. Se conecte a una red WiFi previamente configurada en un fichero de la SD.
2. Si no encuentra ninguna red conocida, permita conectarse a una nueva.
3. Levante un túnel Tailscale y abra una sesión RDP contra un PC con
   Windows 11 Pro.

Convertir la Pi en un cliente ligero de bolsillo: enchufarlo a cualquier
pantalla y tener el ordenador de casa delante.

## Veredicto

**Viable.** Ninguna pieza hay que inventarla; todo es software estándar y
mantenido. El riesgo no es que no funcione, sino que la fluidez a 1080p no
resulte satisfactoria. Se mitiga haciendo que la resolución sea un parámetro
de configuración desde el primer día.

## Límites del hardware

| Componente | Especificación | Implicación |
|---|---|---|
| SoC | BCM2710A1, 4× Cortex-A53 @ 1 GHz | Suficiente para escritorio; justo para vídeo |
| RAM | **512 MB**, no ampliable | El límite duro del proyecto |
| GPU | VideoCore IV | Tiene decodificador H.264 por hardware, pero FreeRDP no lo usa |
| WiFi | 802.11 b/g/n **solo 2.4 GHz** | ~20-40 Mbps reales; 10-15 en entornos congestionados |
| Vídeo | mini-HDMI, 1080p60 de salida | La salida no es el cuello de botella |

Dato de referencia: el Zero 2 W alcanza **~19 fps codificando 1080p** con su
codificador hardware dedicado. Decodificando por software el margen es menor.

### Sobre la aceleración por hardware

El VideoCore IV expone un decodificador H.264 vía V4L2 M2M, pero FreeRDP abre
el decodificador genérico de libavcodec (software) y no existe plumbing para
forzar el de hardware. **Este proyecto asume decodificación por software.**
No se intentará resolver esto.

## Expectativa realista de rendimiento

RDP es un protocolo **incremental**: solo transmite lo que cambia en pantalla.
Eso cambia radicalmente la ecuación frente a un streaming de vídeo.

| Uso | Experiencia a 1920×1080 |
|---|---|
| Escribir, menús, Office, terminal, código | Fluido. Perfectamente usable |
| Scroll de páginas largas, arrastrar ventanas | Aceptable, con arrastre visible |
| Redibujado a pantalla completa | ~5-15 fps, notable |
| Vídeo, animaciones, juegos | Malo. No es el caso de uso |

### Elección de códec

La documentación de FreeRDP advierte que la decodificación software de AVC
está **menos optimizada** que los códecs antiguos. Para esta clase de
hardware el ajuste correcto es RemoteFX Progressive en modo cliente ligero
(`/gfx:progressive` + `/gfx:thin-client`), **no** AVC420/444, que es lo que
Windows negociaría por defecto.

### Presupuesto de RAM estimado (1080p)

| Componente | Estimación |
|---|---|
| Raspberry Pi OS Lite en reposo | ~130 MB |
| Xorg sin gestor de ventanas | ~50 MB |
| xfreerdp3 con códec progressive | ~90-140 MB |
| **Total** | **~270-320 MB** |

Cabe en 512 MB sin margen para lujos. A 720p baja de forma notable. Se añade
zram como colchón para los picos.

## El lado Windows

Los puntos de fricción más frecuentes no están en la Raspberry.

| Asunto | Estado | Acción |
|---|---|---|
| Windows 11 **Pro** acepta RDP entrante | Sí (Home no) | Ninguna |
| **Sesión única** | Al conectar, la consola local se bloquea | Asumirlo por diseño |
| **PC suspendido** | No hay conexión posible | Desactivar suspensión (decidido) |
| **Firewall** | Bloqueo frecuente | Permitir 3389 desde `100.64.0.0/10` |
| Cuenta Microsoft | Formato de login especial | `MicrosoftAccount\usuario@dominio` |

Tailscale no puede despertar un equipo suspendido. Como la Pi estará fuera de
casa, tampoco puede emitir un Wake-on-LAN útil: haría falta otro dispositivo
siempre encendido en la LAN doméstica. **Decisión tomada: el PC se deja
siempre encendido**, lo que elimina el problema por completo.

## Transporte

| Opción | Veredicto |
|---|---|
| **Tailscale** | **Elegido.** WireGuard, atraviesa NAT sin abrir puertos, funciona desde cualquier red |
| Exponer RDP a Internet | Descartado. El 3389 abierto es la vía de entrada nº1 de ransomware |
| WireGuard puro / Headscale | Viable, pero exige resolver el NAT traversal o mantener un endpoint público |
| Cloudflare Tunnel | Posible, pero complica el lado cliente sin aportar nada aquí |

### Caducidad de claves

Las claves de nodo de Tailscale **caducan a los 180 días** por defecto: la Pi
se quedaría inaccesible sin previo aviso. Los **dispositivos etiquetados
(tagged) tienen la caducidad desactivada por defecto**, así que el diseño usa
una auth key con tag ACL. Ver `docs/windows.md` para el procedimiento.

La auth key se consume en el primer arranque, el estado persiste en
`/var/lib/tailscale`, y el fichero se borra de la partición de boot.

## Alternativa evaluada: Sunshine + Moonlight

|  | RDP (FreeRDP) | Sunshine + Moonlight |
|---|---|---|
| Decodificación HW en la Pi | No | Sí (V4L2) → mucho más fluido |
| Nitidez del texto | Excelente | Artefactos de compresión |
| Ancho de banda | Bajo (3-10 Mbps) | Alto (10-20 Mbps) — problemático en 2.4 GHz |
| Portapapeles, reconexión | Nativo | Limitado |
| Requiere sesión iniciada en Windows | No | Sí |

**Descartado como camino principal.** Es tentador por el decodificado
hardware, pero pierde justo donde se va a trabajar (nitidez de texto) y exige
más ancho de banda del que da la radio de 2.4 GHz. Queda como posible perfil
opcional en una fase posterior.

## Stack elegido

| Capa | Elección | Motivo |
|---|---|---|
| Base | Raspberry Pi OS **Lite** | ~130 MB en reposo, sin escritorio |
| Arquitectura | arm64 (armhf como plan B) | Mejor soporte de paquetes; 32 bits ahorra RAM si aprieta |
| Gráficos | **X11**: `xserver-xorg-core` + `xinit`, sin WM ni display manager | En Zero 2 W, Raspberry Pi OS usa X11 igualmente; Wayland es el defecto solo en Pi 4/5 |
| Cliente RDP | `freerdp3-x11` (`xfreerdp3`) | Estándar, disponible en repos |
| Red | NetworkManager + `nmcli` | Ya viene en la base |
| Interfaz | **`whiptail`** | Ya instalado, cero dependencias nuevas |
| Memoria | zram swap | Colchón para picos |

No se necesita aceleración 3D. Queda pendiente **medir en hardware real** si
sale más a cuenta el camino simple de framebuffer/`modesetting` que
`vc4-kms-v3d`, ahorrando CMA y complejidad.

## Flujo de arranque

```
Encendido
  └─► Sistema base + NetworkManager
        └─► Leer /boot/firmware/pithin/redes.conf
              └─► Importar perfiles a NetworkManager
                    ├─► ¿Hay red conocida al alcance?
                    │     SÍ ─► conectar
                    │     NO ─► TUI: escanear, elegir SSID, pedir clave
                    │            └─► (opcional) guardar para la próxima vez
                    └─► tailscale up
                          └─► ¿Windows accesible en el tailnet?
                                SÍ ─► startx ─► xfreerdp3 a pantalla completa
                                │       └─► al salir/caer: menú
                                NO ─► TUI: diagnóstico + opciones
```

## Camino de construcción

Se evaluaron tres opciones:

| Opción | Pros | Contras |
|---|---|---|
| **pi-gen** (oficial) | `.img.xz` reproducible; GitHub Action madura | Lento (~1 h con QEMU); requiere Docker privilegiado |
| **rpi-image-gen** (nuevo oficial) | Control fino de capas y particiones, paquetes binarios | Más reciente, menos rodado en CI |
| Script sobre RPi OS Lite | Iteración en segundos, depuración trivial | No es una imagen flasheable |

### Decisión: por fases

**Fase A — validar sobre hardware real.** Script de aprovisionamiento
idempotente sobre Raspberry Pi OS Lite estándar. Permite iterar en minutos
sobre lo que realmente es difícil: que el RDP y la interfaz sean usables con
512 MB. Construir imágenes desde el principio significaría esperar 40 minutos
por cada ajuste de un parámetro de códec.

**Fase B — empaquetar como imagen flasheable.** Los **mismos scripts** se
envuelven como *custom stage* de pi-gen, con un workflow de GitHub Actions que
publica el `.img.xz` como release. Cero trabajo duplicado: el script *es* el
stage.

Se elige pi-gen sobre rpi-image-gen porque su `stage2` da exactamente
Raspberry Pi OS Lite como base y el camino en CI está muy trillado.
rpi-image-gen queda como alternativa de repuesto.

La imagen no se puede construir en un contenedor sin privilegios (necesita
dispositivos loop). GitHub Actions será la granja de compilación.

## Modelo de seguridad

La partición de boot es FAT32: **cualquiera que meta la SD en un portátil la
lee**.

| Secreto | Tratamiento |
|---|---|
| Contraseñas WiFi | En claro en `redes.conf`. Inevitable, impacto bajo |
| Auth key de Tailscale | Se consume en el primer arranque y **se borra del boot**. Clave *tagged* + ACL que limite la Pi a `tcp/3389` del PC |
| **Contraseña de Windows** | **Cifrada, desbloqueada por PIN** |

### Credencial protegida por PIN

Un PIN de 4 dígitos son 10.000 combinaciones: la fuerza bruta offline es
cuestión de segundos por muy bueno que sea el cifrado. **La longitud del PIN
pesa más que el algoritmo.** De ahí tres refuerzos:

1. **Argon2id** como derivación de clave — memory-hard, resistente a GPU.
2. **Vinculación al dispositivo**: la clave se deriva combinando el PIN con el
   número de serie del SoC. La SD sola, sin esa Raspberry concreta, es
   inútil. Cubre el escenario más probable (SD copiada, prestada, olvidada).
3. **Mínimo 6 caracteres alfanuméricos** y bloqueo tras varios intentos.

Detalle completo en `docs/seguridad.md`.

## Riesgos y mitigaciones

| Riesgo | Probabilidad | Mitigación |
|---|---|---|
| 1080p resulta pesado | Media-alta | Perfil 720p conmutable; `/gfx:progressive`+`thin-client`; 16 bpp opcional |
| OOM con 512 MB | Media | zram, sin WM, ajuste de CMA, códec ligero |
| WiFi 2.4 GHz congestionado | Media | Bajar resolución/color: es el ajuste que más ancho de banda ahorra |
| Caducidad de clave Tailscale | Segura si no se previene | Auth key con tag ACL |
| Corrupción de SD por cortes de luz | Baja-media | Logs en RAM, apagado limpio desde el menú |
| PC suspendido | Eliminado | Decisión: PC siempre encendido |

## Fuentes consultadas

- [Trixie — the new version of Raspberry Pi OS](https://www.raspberrypi.com/news/trixie-the-new-version-of-raspberry-pi-os/)
- [Introducing rpi-image-gen](https://www.raspberrypi.com/news/introducing-rpi-image-gen-build-highly-customised-raspberry-pi-software-images/)
- [pi-gen (RPi-Distro)](https://github.com/RPi-Distro/pi-gen)
- [usimd/pi-gen-action](https://github.com/usimd/pi-gen-action)
- [xfreerdp3(1) — Debian Manpages](https://manpages.debian.org/testing/freerdp3-x11/xfreerdp3.1.en.html)
- [Tailscale — Key expiry](https://tailscale.com/docs/features/access-control/key-expiry)
- [Tailscale — Tagged nodes no longer require key renewal](https://tailscale.com/blog/tagged-key-expiry)
- [Tailscale — Access remote desktops using Windows RDP](https://tailscale.com/docs/solutions/access-remote-desktops-using-windows-rdp)
- [Raspberry Pi Zero 2 W Review — Hackster.io](https://www.hackster.io/news/raspberry-pi-zero-2-w-review-hands-on-with-the-fastest-zero-ever-b85b155905a5)
