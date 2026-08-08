# PiThin

Cliente ligero de escritorio remoto para **Raspberry Pi Zero 2 W**.

Enchufas la Raspberry a cualquier pantalla HDMI, con un teclado y un
ratón. Arranca, se conecta a una WiFi conocida, levanta un túnel
Tailscale y abre a pantalla completa la sesión de tu PC con Windows 11.
Sin escritorio, sin gestor de ventanas, sin nada más.

Si no encuentra ninguna red conocida, muestra un asistente de texto para
conectarse a una nueva y la guarda para la próxima vez.

## Estado

**Fase A.5: aprovisionamiento sobre Raspberry Pi OS Lite**, con perfiles
conmutables y sin servidor X. Funciona instalando sobre un sistema
estándar. La Fase B empaquetará estos mismos scripts como imagen
`.img.xz` flasheable mediante pi-gen y GitHub Actions.

- Los límites del hardware y el porqué de este orden:
  [docs/viabilidad.md](docs/viabilidad.md)
- Arquitectura, sistema de vídeo, escalado y aceleración por hardware:
  [docs/rendimiento.md](docs/rendimiento.md)

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
install.sh              Instalador idempotente (Fase A)
boot-ejemplo/           Plantillas de configuración para la SD
src/lib/                Módulos: config, perfiles, pantalla, cifrado,
                        wifi, vpn, rdp, interfaz
src/bin/                Órdenes: pithin-arranque, pithin-sesion, pithin-menu
pruebas/                Pruebas de los módulos, sin necesidad de Raspberry
docs/                   Viabilidad, rendimiento, instalación, Windows,
                        seguridad
```

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
