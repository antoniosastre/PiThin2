# Rendimiento: por qué está montado así

Este documento recoge el análisis que llevó al diseño actual: qué
arquitectura, qué sistema de vídeo, quién reescala la imagen y por qué
no hay aceleración por hardware.

Si solo quieres que vaya más rápido, ve a **Menú → Perfil de sesión** y
prueba *Máxima fluidez*. Lo de abajo es el porqué.

---

## Los cuatro perfiles

| Perfil | Vídeo | Sesión | Salida HDMI | Quién escala | Color |
|---|---|---|---|---|---|
| **Equilibrado** | sdl | 1280×720 | nativa (1080p) | GPU | 32 |
| **Máxima nitidez** | sdl | 1920×1080 | nativa | nadie | 32 |
| **Máxima fluidez** | sdl | 1280×720 | 720p | el monitor | 16 |
| **Compatibilidad** | x11 | 1920×1080 | nativa | nadie | 32 |

Son cuatro combinaciones probadas, no cuatro puntos de un continuo. Los
cinco ejes por separado dan casi doscientas combinaciones: no se pueden
probar todas, y las que no se prueban acaban rotas justo cuando hacen
falta. Los ajustes sueltos siguen en **Ajustes**, pero al tocar uno el
perfil pasa a llamarse *personalizado* y deja de haber promesas.

---

## Arquitectura: por qué arm64 y no armhf

Con 512 MB, ahorrar RAM es tentador: **arm64 consume unos 90 MB más en
arranque**, casi un 18% del total. Pero hay un dato que le da la vuelta.

**Raspberry Pi OS de 32 bits no es el armhf de Debian.** Se compila para
**ARMv6 + VFP2** para seguir arrancando en la Pi 1 y la Zero original,
mientras que el armhf oficial de Debian parte de ARMv7 + VFP3. ARMv6
deja **NEON fuera de la línea base**.

Y aquí la carga principal es descodificar vídeo por software, que es
probablemente lo que más depende de NEON que existe. En arm64 no hay
duda: **ASIMD/NEON es obligatorio en ARMv8-A**, siempre está.

Un matiz que conviene no exagerar: FFmpeg y OpenH264 traen su NEON en
ensamblador y lo activan por **detección de CPU en tiempo de ejecución**,
así que la descodificación H.264 probablemente usaría NEON incluso en el
OS de 32 bits. Donde la línea base ARMv6 sí muerde es en las *primitives*
de FreeRDP (conversión de color y YUV→RGB del códec **progressive**, que
es justo el que usamos), donde NEON es una opción de compilación que una
build ARMv6 no activa. La conclusión (arm64) se sostiene —ISA más ancha,
registros de sobra, asm aarch64—, pero la ventaja concreta depende del
códec, y el `10-30%` de abajo es una horquilla orientativa, sin medir en
esta placa.

| | armhf (RPi OS) | arm64 |
|---|---|---|
| RAM extra en arranque | — | ~30-90 MB más (estimado) |
| SIMD garantizado | ❌ base ARMv6 | ✅ obligatorio |
| Trabajo intensivo de CPU | referencia | 10-30% más rápido (estimado) |

**La decisión depende de la descodificación, no al revés.** Mientras sea
por software, la CPU es el cuello de botella y gana arm64. Si algún día
se consigue descodificación por hardware, la CPU deja de importar, la
RAM pasa a ser la única restricción y **armhf pasaría a ser la buena**.

Por eso la Fase B publicará **las dos imágenes** desde el mismo código:
cuesta un parámetro en el workflow y deja la puerta abierta.

---

## Sistema de vídeo: SDL/KMSDRM en vez de un servidor X

`freerdp3-sdl` (3.15.0 en Trixie, disponible en armhf y arm64) habla con
el controlador de pantalla del kernel a través de SDL3, **sin servidor X
por medio**.

### Lo que se gana

- **~40-60 MB de RAM**: no hay proceso Xorg.
- **Una pieza móvil menos**: menos cosas que puedan fallar al arrancar.
- **El reescalado se va a la GPU**, que es lo que arregla el error
  descrito más abajo.

### Una precisión sobre las dependencias

`freerdp3-sdl` no depende de X11 ni de Wayland. Pero **`libsdl3-0` sí**:
arrastra `libx11-6`, `libxext6`, `libxrandr2`, `libxcursor1`,
`libwayland-client0` y `libdecor-0-0`.

O sea que las *bibliotecas* de X11 se instalan igualmente. Lo que no se
instala ni se ejecuta es el **servidor** Xorg, que es donde estaba el
coste de verdad. El titular correcto es "sin servidor X", no "sin
dependencias de X11".

Que `libsdl3-0` dependa además de `libdrm2` y `libgbm1` es lo que
confirma que el backend KMSDRM viene compilado.

### Los riesgos, que son reales

| Riesgo | Detalle |
|---|---|
| Versión justo anterior a la madurez | FreeRDP declaró el cliente SDL3 "ya no experimental" en la **3.16**. Trixie trae la **3.15.0** |
| KMSDRM en Raspberry Pi | Hay incidencias abiertas en SDL sobre este backend en Pi |
| **La entrada** | El fallo característico: la imagen aparece y el teclado no responde |
| `libudev1` | Solo figura como *recomendado* de libsdl3, y SDL lo necesita para detectar teclados. El instalador lo fuerza |

### Por eso existe la prueba con tiempo limitado

Si el teclado no funciona dentro de la sesión, **tampoco se puede salir
de ella**: no hay escapatoria desde dentro. Así que la primera sesión con
un backend nuevo se abre durante 45 segundos y se cierra sola. Al volver
a la consola de texto —donde el teclado sí funciona, porque es el del
kernel y no tiene nada que ver con SDL— se pregunta si respondía. Si no,
se revierte al otro backend.

Y por eso el perfil **Compatibilidad** existe y usa X11: es terreno
conocido al que volver en un clic.

---

## Quién reescala la imagen

### El error que había en la primera versión

La versión inicial añadía `/smart-sizing` siempre que la resolución de la
sesión no coincidía con la de la pantalla. **`/smart-sizing` escala por
software.**

Es decir: en el aparato con menos CPU del catálogo, se metía un
reescalado de 2,25× por fotograma en el procesador, comiéndose buena
parte del ahorro que justificaba bajar a 720p. Justo el trabajo en el
sitio equivocado.

### La regla correcta

| Situación | Qué se hace |
|---|---|
| La salida ya va a la resolución de la sesión | **No se escala nada** |
| Backend sdl, resoluciones distintas | `/smart-sizing` → lo hace la GPU |
| Backend x11, resoluciones distintas | `/smart-sizing` → lo hace la CPU, y se avisa en el registro |

Por eso el perfil *Compatibilidad* usa 1080p nativo: con X11 no hay forma
de escalar gratis, así que lo mejor es no escalar.

### Salida nativa o salida a la resolución de la sesión

Forzar la salida HDMI a 720p tiene una ventaja que no es evidente. CPU,
GPU y controlador de pantalla comparten el mismo bus de memoria, y el
escaneo de vídeo es tráfico **continuo y de prioridad alta**: hay que
leer el framebuffer entero sesenta veces por segundo, pase lo que pase.

| Salida | Framebuffer | Lectura a 60 Hz |
|---|---|---|
| 1920×1080 | 7,9 MiB | ~475 MiB/s |
| 1280×720 | 3,5 MiB | ~211 MiB/s |

Son del orden de **260 MiB/s de ancho de banda** que se le devuelven a la
CPU, más unos 9 MiB de RAM con doble búfer.

A cambio, reescala el monitor:

- **Calidad**: 720→1080 es 1,5×, no entero, así que difumina siempre.
  Cuánto, depende del escalador de tu monitor, y ahí hay de todo.
- **Latencia**: muchos televisores añaden 10-40 ms al reescalar.
- **Overscan**: los televisores recortan bordes con más frecuencia en
  720p que en 1080p.

Por eso el valor por defecto es **nativa**: no es la más rápida, es la
que funciona con cualquier pantalla que te encuentres. Si tu monitor
habitual escala bien, *Máxima fluidez* te da el empujón gratis.

Cambiar esto modifica `cmdline.txt` y **necesita reiniciar**: el modo KMS
se fija al arrancar el kernel.

> El módulo comprueba que el monitor anuncia el modo **antes** de
> escribirlo. Pedirle uno que no soporte dejaría la pantalla en negro,
> que a efectos prácticos es un equipo estropeado.

### Una tercera vía sin verificar

El VideoCore tiene un escalador en el propio pipeline de pantalla (el
HVS) que permitiría tener un framebuffer de 720p escaneado hacia un modo
de 1080p: ancho de banda de 720p, señal de 1080p, escalado gratis. Lo
mejor de ambas.

**No está implementado porque no se ha verificado que SDL3 lo aproveche.**
Lo normal es que su backend KMSDRM renderice a una superficie del tamaño
del modo, dejando el escalador sin usar. Conseguirlo exigiría configurar
el plano DRM a mano.

---

## Por qué no hay aceleración por hardware

La Zero 2 W **sí tiene** decodificador H.264 por hardware: el VPU del
BCM2835, expuesto por el kernel en `/dev/video10` a través de
`bcm2835-codec`. No se usa, y hay tres razones encadenadas.

### 1. La ruta VAAPI no existe en este chip

La aceleración de FreeRDP va por el hwaccel de FFmpeg, que es VAAPI. El
VideoCore IV no tiene driver VAAPI. Además FreeRDP tiene
`/dev/dri/renderD128` escrito a fuego en el código.

### 2. El envoltorio de FFmpeg está roto

`h264_v4l2m2m`, que sería el puente natural, **funciona en kernel 5.15 y
se cuelga en 6.6.63**. Raspberry Pi OS ya va por Linux 6.18. Está
reportado en `raspberrypi/linux#6554` y confirmado en OpenWrt para Pi 3
y Pi 4.

### 3. Pero el hardware está perfectamente

Esto es lo importante para el futuro. **ZeroPlay**, un reproductor
reciente, usa **V4L2 M2M por ioctls directos** —sin pasar por FFmpeg— y
saca por **DRM/KMS atómico con DMABUF zero-copy**, con soporte explícito
para Pi Zero 2 W sobre Raspberry Pi OS Lite Trixie en 32 y 64 bits.

O sea: el silicio y el driver del kernel funcionan. Lo que está roto es
el envoltorio de FFmpeg.

### Lo que sería tratable: un backend nuevo para FreeRDP

FreeRDP ya tiene la abstracción hecha. Su capa H.264 está organizada en
subsistemas intercambiables:

```c
g_Subsystem_OpenH264     // software
g_Subsystem_libavcodec   // software (y VAAPI)
g_Subsystem_mediacodec   // Android: decodificador hardware
g_Subsystem_MF           // Windows Media Foundation
```

Añadir `g_Subsystem_v4l2m2m` encaja en la arquitectura existente, y no se
parte de cero: **el backend de Android es la plantilla exacta** (mismo
problema: decodificador hardware externo, buffers que no son memoria
normal, formato de salida distinto), y ZeroPlay demuestra que la parte
V4L2+DRM funciona en este chip.

Estimación: entre 800 y 1.500 líneas de C. No es un fin de semana, pero
tampoco un proyecto de investigación.

### Pero antes conviene preguntarse si hace falta

**RDP con códec progressive tiene un coste proporcional a los píxeles que
cambian.** Escritorio quieto ≈ coste cero. El modo AVC/H.264 de RDP
(EGFX) también es dirigido por cambios —si nada se mueve, el servidor no
manda fotogramas—, así que la diferencia no es "continuo vs a demanda":
es el **coste por actualización**. Cuando algo cambia, progressive envía
y descodifica solo los *tiles* sucios, mientras que H.264 codifica y
descodifica el fotograma que cubre esa superficie completa.

Para escribir, navegar menús, Office, terminal y código —el caso de uso
de este aparato— *progressive* a 720p con escalado por GPU **debería**
rendir bien, y probablemente mejor que AVC420 por software. Frente a
AVC420 con descodificación *hardware* la comparación es menos clara: en
scroll o arrastre de ventanas se ensucia la pantalla entera (el propio
documento estima 5-15 fps ahí), y un decodificador hardware con DMABUF
zero-copy también ganaría en ese caso. "Quizá no haga falta" es
defendible; "rinde mejor siempre" iría más lejos de lo medido —y aquí
todavía no hay nada medido.

Escrito de otra forma: la descodificación por hardware resolvería un
problema que este aparato quizá no tenga.

---

## Alternativas descartadas

| Opción | Por qué no |
|---|---|
| **Escribir un cliente RDP propio** | RDP no es un protocolo, es una familia: CredSSP/NLA, licenciamiento, negociación de capacidades, EGFX, RemoteFX, progressive, formato de cable de AVC420/444, portapapeles, redirecciones. FreeRDP lleva 23.000 commits y 419 contribuidores |
| **Escribir el servidor de Windows** | Captura DXGI + NVENC/AMF/QSV + transporte con control de congestión + inyección de entrada. Meses para llegar a algo peor que Sunshine |
| **Sunshine + Moonlight-embedded** | Sí da descodificación hardware hoy, sin escribir nada. Pero peor nitidez de texto y 10-20 Mbps, que en una radio de solo 2,4 GHz duele. Queda como posible segundo perfil |

---

## Si algo va lento, por orden

1. **Perfil → Máxima fluidez.** Es lo que más se nota, con diferencia.
2. Comprueba que el códec es `progressive`. La Zero 2 W no acelera H.264,
   así que `avc420` suele ir **peor** aunque comprima mejor.
3. Baja el color a 16 bits.
4. Acércate al router. La radio es **solo 2,4 GHz**: en un entorno
   saturado, la señal manda más que cualquier ajuste.

---

## Fuentes

- [freerdp3-sdl en Trixie](https://packages.debian.org/trixie/freerdp3-sdl) ·
  [libsdl3-0 en Trixie](https://packages.debian.org/trixie/libsdl3-0)
- [FreeRDP 3.16: el cliente SDL3 deja de ser experimental](https://www.phoronix.com/news/FreeRDP-3.16-Released)
- [xfreerdp3(1)](https://manpages.debian.org/testing/freerdp3-x11/xfreerdp3.1.en.html)
- [raspberrypi/linux#6554 — h264_v4l2m2m roto en kernel 6.x](https://github.com/raspberrypi/linux/issues/6554)
- [ZeroPlay — V4L2 M2M + DRM/KMS en Pi Zero 2 W](https://github.com/HorseyofCoursey/zeroplay)
- [FreeRDP#12779 — renderD128 escrito a fuego](https://github.com/FreeRDP/FreeRDP/issues/12779)
- [SDL#12418 — kmsdrm en Raspberry Pi](https://github.com/libsdl-org/SDL/issues/12418)
- [Debian Wiki: RaspberryPi — base ARMv6](https://wiki.debian.org/RaspberryPi)
- [32 vs 64 bits en la Zero 2 W](https://docs.printercow.com/guide/32bit-vs-64bit.html)
- [Moonlight en SBC ARM](https://github.com/moonlight-stream/moonlight-docs/wiki/Installing-Moonlight-Qt-on-ARM%E2%80%90based-Single-Board-Computers)
