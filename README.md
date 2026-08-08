# PiThin

**Tu ordenador de casa, en el bolsillo.**

PiThin convierte una **Raspberry Pi Zero 2 W** —unos 20 euros, del
tamaño de una tarjeta de crédito— en un cliente ligero de escritorio
remoto dedicado.

## El problema que resuelve

Estás fuera de casa y necesitas tu ordenador: tus programas, tus
ficheros, tus licencias, tu sesión tal como la dejaste. Llevar el
portátil no siempre compensa, y los ordenadores prestados no tienen lo
tuyo.

Con PiThin te llevas una Raspberry en el bolsillo. La enchufas a
cualquier pantalla con HDMI —un monitor de oficina, la tele de un hotel,
la pantalla de una sala de reuniones— le conectas un teclado y un ratón,
y estás delante de tu PC.

## Qué hace exactamente

Al encenderla, sin que tengas que teclear nada más que el PIN:

```
Encendido
  └─► Busca las redes WiFi que tienes guardadas en la tarjeta
        ├─ Encuentra una  ─► se conecta
        └─ No encuentra   ─► asistente en pantalla para elegir una nueva,
                             y la guarda para la próxima vez
  └─► Levanta un túnel cifrado (Tailscale / WireGuard) hasta tu PC
  └─► Te pide el PIN que desbloquea tu contraseña de Windows
  └─► Abre la sesión de tu PC a pantalla completa
```

Sin escritorio, sin gestor de ventanas y —por defecto— **sin siquiera un
servidor X**. Solo el cliente remoto, que es lo único que hace falta.

## Para quién es

- Quien tiene un PC potente en casa y quiere llegar a él desde
  cualquier sitio sin cargar con un portátil.
- Quien necesita un segundo puesto barato contra el mismo ordenador.
- Quien quiere reutilizar un monitor viejo como terminal.

**Para quién no es:** si vas a ver vídeo o jugar, este no es el aparato.
Ver [Rendimiento](#rendimiento-y-perfiles).

---

> ### ⚠️ Estado: sin probar en hardware real
>
> El código está completo y con 135 pruebas automáticas en verde, pero
> **todavía no se ha ejecutado en una Raspberry**. Todo lo verificado se
> ha verificado en entornos simulados. Espera tener que ajustar cosas en
> la primera puesta en marcha.

## Estado del proyecto

| Fase | Qué es | Estado |
|---|---|---|
| **A** | Aprovisionamiento sobre Raspberry Pi OS Lite | Hecha |
| **A.5** | Perfiles conmutables, SDL/KMSDRM, control de salida | Hecha |
| **B** | Imagen `.img.xz` flasheable (pi-gen + GitHub Actions) | Pendiente |

Se hizo primero el script y no la imagen a propósito: lo difícil no es
construir la imagen, sino que la sesión resulte usable con 512 MB de RAM
y descodificación por software, y eso exige iterar en minutos y no en
compilaciones de 40 minutos. Los mismos scripts se envolverán como fase
de pi-gen.

## Documentación

| Documento | Para qué |
|---|---|
| [docs/instalacion.md](docs/instalacion.md) | Paso a paso, con resolución de problemas |
| [docs/windows.md](docs/windows.md) | Preparar el PC: RDP, Tailscale, firewall, ACL |
| [docs/rendimiento.md](docs/rendimiento.md) | Por qué arm64, por qué sin X, quién reescala |
| [docs/seguridad.md](docs/seguridad.md) | Modelo de amenazas: qué protege y qué no |
| [docs/viabilidad.md](docs/viabilidad.md) | Análisis previo y decisiones de diseño |
| [CLAUDE.md](CLAUDE.md) | Notas de desarrollo: gotchas, errores resueltos, caminos descartados |

## Qué necesitas

- Raspberry Pi Zero 2 W, fuente de alimentación y tarjeta microSD (8 GB o más)
- Adaptador mini-HDMI y hub o adaptador micro-USB OTG para teclado y ratón
- Un PC con **Windows 11 Pro** (Home no acepta conexiones RDP entrantes)
- Una cuenta de Tailscale (el plan gratuito sobra)

## Instalación rápida

1. Flashea **Raspberry Pi OS Lite (64 bits)** con Raspberry Pi Imager.
   En los ajustes previos, activa SSH y configura tu WiFi: así podrás
   entrar por red para instalar.

2. Entra por SSH e instala:

   ```bash
   git clone https://github.com/antoniosastre/PiThin2.git
   cd PiThin2
   sudo ./install.sh
   ```

3. Edita la configuración y reinicia. Los detalles paso a paso están en
   [docs/instalacion.md](docs/instalacion.md), y la preparación del PC
   con Windows en [docs/windows.md](docs/windows.md).

## Configuración

Dos ficheros de texto en la partición de arranque, editables metiendo
la tarjeta en cualquier ordenador (Windows y macOS la ven como una
unidad normal):

| Fichero | Para qué |
|---|---|
| `pithin.conf` | PC de destino, usuario, resolución, códec, teclado |
| `redes.conf` | Redes WiFi conocidas y su prioridad |

Todo se puede cambiar también desde el menú en pantalla, sin sacar la
tarjeta.

## Rendimiento y perfiles

La Zero 2 W descodifica el vídeo remoto **por software**: no puede
acelerar H.264 por hardware. Aun así, RDP solo transmite lo que cambia
en pantalla, y eso cambia mucho la ecuación.

| Uso | Experiencia |
|---|---|
| Escribir, menús, Office, terminal, código | Fluido |
| Scroll largo, arrastrar ventanas | Aceptable |
| Redibujado a pantalla completa | ~5-15 fps |
| Vídeo y juegos | No es el caso de uso |

En vez de exponer los cinco ejes que afectan al rendimiento por
separado —lo que daría casi doscientas combinaciones imposibles de
probar— el menú ofrece cuatro **perfiles probados**:

| Perfil | Vídeo | Sesión | Salida HDMI | Quién escala |
|---|---|---|---|---|
| **Equilibrado** (defecto) | SDL/KMSDRM | 1280×720 | nativa | GPU |
| **Máxima nitidez** | SDL/KMSDRM | 1920×1080 | nativa | nadie |
| **Máxima fluidez** | SDL/KMSDRM | 1280×720 | 720p | el monitor |
| **Compatibilidad** | X11 | 1920×1080 | nativa | nadie |

Si notas la sesión pesada, prueba *Máxima fluidez*. Es el cambio que más
se nota, sobre todo porque la radio de la Zero 2 W es **solo 2,4 GHz**.

Los ajustes sueltos siguen en **Ajustes**; al tocar uno, el perfil pasa
a llamarse *personalizado*.

El razonamiento completo —por qué arm64, por qué sin servidor X, quién
debe reescalar y por qué no hay aceleración por hardware— está en
[docs/rendimiento.md](docs/rendimiento.md).

### Sin servidor X

Por defecto se usa `sdl-freerdp3` sobre **SDL3/KMSDRM**: el cliente
habla directamente con el controlador de pantalla del kernel, sin Xorg
por medio. Eso ahorra unos 50 MB de RAM y una pieza móvil entera, y
manda el reescalado a la GPU.

El cliente X11 se instala igualmente como respaldo conmutable desde el
menú. La primera sesión con un sistema de vídeo nuevo se abre **con
tiempo limitado** y luego se pregunta si respondía el teclado: el fallo
típico de KMSDRM es que se vea la imagen pero no funcione la entrada, y
en ese caso no habría forma de salir de la sesión desde dentro.

## Seguridad

- El túnel es **WireGuard vía Tailscale**. No hace falta abrir ningún
  puerto en el router. Exponer RDP directamente a Internet sería mala
  idea: el 3389 abierto es la vía de entrada nº1 de ransomware.
- La **contraseña de Windows se guarda cifrada** con Argon2id y
  desbloqueada por un PIN. La clave se deriva además del número de
  serie del SoC: una copia de la tarjeta en otro equipo no sirve.
- La **auth key de Tailscale se consume en el primer arranque y se
  borra** de la tarjeta.
- Las contraseñas WiFi sí quedan en claro en `redes.conf`: la partición
  de arranque es FAT32 y no admite otra cosa.

El modelo de amenazas completo, con lo que protege y lo que no, está en
[docs/seguridad.md](docs/seguridad.md).

## Uso diario

Enciendes. Tecleas el PIN. Estás en tu PC.

Para salir de la sesión y volver al menú: `Ctrl+Alt+Intro` sale de
pantalla completa, y cerrar la ventana termina la sesión.

Desde el menú puedes cambiar de red WiFi, ajustar la resolución,
cambiar el PIN, ver un diagnóstico o apagar.

## Estructura del repositorio

```
install.sh              Instalador idempotente
boot-ejemplo/           Plantillas de configuración para la SD
src/lib/                Módulos: config, perfiles, pantalla, cifrado,
                        wifi, vpn, rdp, interfaz
src/bin/                Órdenes: pithin-arranque, pithin-sesion, pithin-menu
pruebas/                Pruebas de los módulos, sin necesidad de Raspberry
docs/                   Documentación
CLAUDE.md               Notas de desarrollo
```

Todo está escrito en **shell**, en castellano, sin dependencias fuera de
lo que trae Raspberry Pi OS Lite más FreeRDP, Tailscale y `argon2`. La
interfaz usa `whiptail`, que ya viene instalado.

## Pruebas

```bash
./pruebas/todas.sh
```

135 pruebas más el análisis estático. No hace falta root ni una
Raspberry: montan un entorno aislado en un directorio temporal, con un
monitor y una partición de arranque simulados.

Cubren lo que puede romperse en silencio:

- El análisis de los dos ficheros de configuración, incluidos los
  finales de línea de Windows y las contraseñas con símbolos raros.
- El ciclo completo de cifrado con PIN, comprobando que la credencial
  **no** se descifra desde otro dispositivo.
- La manipulación de `cmdline.txt`, que es el código más peligroso del
  proyecto: un error ahí deja el equipo sin arrancar. Se verifica que
  se niega a escribir un `cmdline` sin `root=`, vacío o con saltos de
  línea, y que **no fuerza un modo de vídeo que el monitor no anuncie**.
- Perfiles, detección de configuración personalizada y reversión a la
  última que funcionaba.

Los scripts pasan `shellcheck` sin avisos.

## Órdenes útiles

```bash
pithin-menu                  # abrir el menú sin reiniciar
tail -f /var/log/pithin.log  # ver qué está pasando
sudo ./install.sh --solo-ficheros   # recargar scripts al iterar
sudo ./install.sh --desinstalar     # deshacer los cambios
```

## Licencia

MIT. Ver [LICENSE](LICENSE).
