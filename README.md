# PiThin

Cliente ligero de escritorio remoto para **Raspberry Pi Zero 2 W**.

Enchufas la Raspberry a cualquier pantalla HDMI, con un teclado y un
ratón. Arranca, se conecta a una WiFi conocida, levanta un túnel
Tailscale y abre a pantalla completa la sesión de tu PC con Windows 11.
Sin escritorio, sin gestor de ventanas, sin nada más.

Si no encuentra ninguna red conocida, muestra un asistente de texto para
conectarse a una nueva y la guarda para la próxima vez.

## Estado

**Fase A: aprovisionamiento sobre Raspberry Pi OS Lite.** Funciona
instalando sobre un sistema estándar. La Fase B empaquetará estos
mismos scripts como imagen `.img.xz` flasheable mediante pi-gen y
GitHub Actions.

El razonamiento detrás de este orden, y los límites reales del
hardware, están en [docs/viabilidad.md](docs/viabilidad.md).

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

## Rendimiento

La Zero 2 W descodifica el vídeo remoto **por software**: no puede
acelerar H.264 por hardware. Aun así, RDP solo transmite lo que cambia
en pantalla, y eso cambia mucho la ecuación.

| Uso | A 1920×1080 |
|---|---|
| Escribir, menús, Office, terminal, código | Fluido |
| Scroll largo, arrastrar ventanas | Aceptable |
| Redibujado a pantalla completa | ~5-15 fps |
| Vídeo y juegos | No es el caso de uso |

Si notas la sesión pesada, baja la resolución a `1280x720` desde
Ajustes: se transmiten menos de la mitad de píxeles y la imagen se
escala para seguir llenando la pantalla. Es el ajuste que más se nota,
sobre todo porque la radio de la Zero 2 W es **solo 2,4 GHz**.

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
src/lib/                Módulos: config, cifrado, wifi, vpn, rdp, interfaz
src/bin/                Órdenes: pithin-arranque, pithin-sesion, pithin-menu
pruebas/                Pruebas de los módulos, sin necesidad de Raspberry
docs/                   Viabilidad, instalación, Windows y seguridad
```

## Pruebas

```bash
./pruebas/prueba-modulos.sh
```

No hace falta root ni una Raspberry: monta un entorno aislado en un
directorio temporal. Cubre el análisis de los dos ficheros de
configuración —incluidos los finales de línea de Windows y las
contraseñas con símbolos raros— y el ciclo completo de cifrado con PIN,
comprobando que la credencial **no** se descifra desde otro dispositivo.

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
