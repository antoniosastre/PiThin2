# Instalación paso a paso

Instrucciones de la **Fase A**: aprovisionar una Raspberry Pi OS Lite
estándar. La Fase B producirá una imagen ya lista para flashear.

Antes de empezar, o en paralelo, prepara el PC con Windows siguiendo
[windows.md](windows.md).

---

## 1. Material

- Raspberry Pi Zero 2 W
- Tarjeta microSD de 8 GB o más (clase 10 o mejor: la tarjeta lenta se
  nota en el arranque)
- Fuente de alimentación micro-USB de 5 V y al menos 2,5 A
- Adaptador **mini-HDMI a HDMI**
- Adaptador **micro-USB OTG**, mejor si es un hub con varios puertos
  para teclado y ratón a la vez
- Pantalla HDMI

La Zero 2 W tiene dos conectores micro-USB. El de datos es el del
**centro** (marcado `USB`); el del borde es solo alimentación (`PWR`).
Confundirlos es el error más habitual al montarla.

---

## 2. Flashear el sistema

Descarga [Raspberry Pi Imager](https://www.raspberrypi.com/software/).

1. **Dispositivo**: Raspberry Pi Zero 2 W
2. **Sistema operativo**: Raspberry Pi OS (other) → **Raspberry Pi OS
   Lite (64-bit)**
3. **Almacenamiento**: tu tarjeta

Antes de grabar, pulsa el engranaje de **ajustes personalizados** y
configura:

- Nombre de host: `pithin` (o el que prefieras)
- Usuario y contraseña
- **Configurar la red WiFi**: pon aquí tu red de casa. Es la que usarás
  para instalar por SSH.
- **Activar SSH** con autenticación por contraseña
- Zona horaria y distribución de teclado

Graba y espera.

> **Por qué Lite y no la versión con escritorio:** la de escritorio
> ocupa unos 400 MB de RAM en reposo. Con 512 MB en total, no quedaría
> sitio para la sesión remota. PiThin instala solo el servidor X y el
> cliente RDP, sin gestor de ventanas.

---

## 3. Primer arranque e instalación

Mete la tarjeta, conecta la alimentación y espera un minuto. Desde otro
ordenador de la misma red:

```bash
ssh pi@pithin.local
```

Si `pithin.local` no resuelve, busca la IP en el router o prueba con
`ping pithin.local`.

Ya dentro:

```bash
sudo apt update && sudo apt full-upgrade -y
sudo reboot
```

Vuelve a entrar por SSH e instala PiThin:

```bash
git clone https://github.com/antoniosastre/PiThin2.git
cd PiThin2
sudo ./install.sh
```

Tarda unos minutos: descarga Xorg mínimo, FreeRDP, Tailscale y las
herramientas de cifrado.

### Opciones del instalador

| Opción | Para qué |
|---|---|
| `--sin-tailscale` | Omite Tailscale (si usas otra VPN) |
| `--sin-paquetes` | No toca apt; útil al reinstalar |
| `--solo-ficheros` | Solo copia los scripts. Es la que usarás al iterar |
| `--desinstalar` | Deshace los cambios |

Se puede ejecutar tantas veces como quieras: es idempotente y nunca
sobrescribe tu configuración.

---

## 4. Configurar el destino

Edita el fichero de configuración:

```bash
sudo nano /boot/firmware/pithin/pithin.conf
```

Lo mínimo imprescindible son dos líneas:

```ini
RDP_HOST="sobremesa-antonio"
RDP_USER="MicrosoftAccount\\tu@correo.com"
```

`RDP_HOST` es el nombre que aparece en el
[panel de máquinas de Tailscale](https://login.tailscale.com/admin/machines),
o su IP `100.x.y.z`. El formato de `RDP_USER` según el tipo de cuenta
está explicado en [windows.md](windows.md#5-el-usuario-de-windows-en-pithinconf).

Y las redes WiFi:

```bash
sudo nano /boot/firmware/pithin/redes.conf
```

```ini
[MiCasa]
clave = laClaveDeCasa
prioridad = 100

[Oficina]
clave = otraClave
prioridad = 80
```

Cuanto mayor sea la prioridad, antes se intenta esa red.

> Los dos ficheros están en la partición de arranque. Cuando estés fuera
> y necesites cambiar algo sin poder entrar por SSH, apaga, saca la
> tarjeta y edítalos desde cualquier ordenador: Windows y macOS la ven
> como una unidad normal.

---

## 5. Autenticar Tailscale

Deja la auth key en la tarjeta (ver
[windows.md](windows.md#4-crear-la-auth-key-para-la-raspberry) para
generarla con la etiqueta correcta):

```bash
sudo nano /boot/firmware/pithin/tailscale-authkey.txt
```

Pega la clave `tskey-auth-...` y guarda. Se usará en el próximo arranque
y el fichero se borrará solo.

O autentica ahora mismo a mano:

```bash
sudo tailscale up
```

Comprueba que ves tu PC:

```bash
tailscale status
```

---

## 6. Reiniciar y probar

```bash
sudo reboot
```

Ahora con la pantalla, el teclado y el ratón conectados. La secuencia
debería ser:

1. Logotipo de PiThin y mensajes de arranque
2. Conexión a la WiFi conocida
3. Túnel de Tailscale
4. Petición de la contraseña de Windows

La primera vez te preguntará si quieres guardarla cifrada con un PIN.
Si dices que sí, a partir de entonces solo tendrás que teclear el PIN.

**Usa al menos 6 caracteres y mete alguna letra.** `casa42` se teclea
igual de rápido que `1234` y protege muchísimo más; el porqué está en
[seguridad.md](seguridad.md).

---

## Cuando algo no funciona

Lo primero: menú de PiThin → **Diagnóstico → Comprobarlo todo de arriba
abajo**. Recorre en orden WiFi, túnel, resolución del nombre y puerto
3389, que es justo la cadena que suele romperse.

### No aparece nada en la pantalla

- Comprueba que el HDMI está en el conector **mini-HDMI del centro**
- Enchufa el HDMI antes de dar corriente
- Si el monitor es antiguo, prueba a forzar el modo en
  `/boot/firmware/config.txt`:
  ```ini
  hdmi_group=1
  hdmi_mode=16     # 1080p a 60 Hz
  ```

### El teclado y el ratón no responden

Casi siempre es el conector micro-USB: tiene que ser el del **centro**,
no el del borde. Y el adaptador tiene que ser **OTG**, no un cable de
carga.

### No se conecta a la WiFi

- La Zero 2 W es **solo 2,4 GHz**. Si tu router tiene el mismo nombre
  para 2,4 y 5 GHz, puede que esté intentando la banda equivocada:
  prueba a separar las bandas con nombres distintos.
- Revisa mayúsculas y minúsculas del SSID en `redes.conf`
- `sudo journalctl -u NetworkManager -b` da el detalle

### Tailscale no levanta

```bash
sudo tailscale status
sudo journalctl -u tailscaled -b --no-pager | tail -40
```

Si dice `NeedsLogin`, la auth key no llegó a aplicarse: vuelve a
ponerla en la tarjeta o ejecuta `sudo tailscale up`.

### Conecta pero la sesión no abre

Casi siempre es el cortafuegos de Windows. La regla concreta está en
[windows.md](windows.md#3-ajustar-el-cortafuegos-de-windows). Para
comprobarlo desde la Raspberry:

```bash
tailscale ip -4 TU-PC                 # ¿resuelve?
nc -vz $(tailscale ip -4 TU-PC) 3389  # ¿responde el puerto?
```

### Va lento

Por orden de impacto:

1. **Baja la resolución** a `1280x720` desde Ajustes. Es lo que más se
   nota, con diferencia.
2. Comprueba `CODEC="progressive"`. La Zero 2 W no puede acelerar H.264
   por hardware, así que `avc420` suele ir *peor* aunque comprima mejor.
3. Pon `PROFUNDIDAD_COLOR="16"`.
4. Acércate al router: en 2,4 GHz saturado la señal manda más que todo
   lo demás.

### Ver qué está pasando

```bash
tail -f /var/log/pithin.log        # registro de PiThin
cat /run/pithin/sesion.log         # última sesión de FreeRDP
cat /run/pithin/xorg.log           # arranque del servidor X
```

---

## Volver atrás

```bash
cd PiThin2
sudo ./install.sh --desinstalar
sudo reboot
```

Deja el sistema como estaba. Conserva tu configuración de
`/boot/firmware/pithin/` y la credencial cifrada de `/var/lib/pithin/`
por si quieres reinstalar; bórralas a mano si quieres dejarlo limpio.
