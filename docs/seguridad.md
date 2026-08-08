# Modelo de seguridad

Qué protege PiThin, qué no protege, y por qué se ha decidido así.

Merece la pena leerlo entero antes de decidir si guardas la contraseña
de Windows en el equipo.

---

## El escenario

Una Raspberry pequeña que te llevas en la mochila y enchufas en sitios
que no controlas. La amenaza realista no es un atacante remoto: es
**perder el aparato, o que alguien te copie la tarjeta**.

Las tres cosas sensibles que hay dentro:

| Secreto | Dónde vive | Protección |
|---|---|---|
| Contraseñas WiFi | `redes.conf`, partición FAT32 | **Ninguna**, en texto plano |
| Auth key de Tailscale | `tailscale-authkey.txt`, FAT32 | Se borra tras el primer arranque |
| Contraseña de Windows | `/var/lib/pithin/`, partición ext4 | Cifrada con Argon2id + PIN + serie del SoC |

---

## Las dos particiones no son iguales

Esto explica muchas de las decisiones:

**La partición de arranque es FAT32.** Tiene que serlo: es la que lee el
firmware de la Raspberry. Cualquiera que meta la tarjeta en un Windows o
un Mac la ve montada al instante. Es donde están `pithin.conf` y
`redes.conf`, y por eso ahí no puede haber nada que merezca protección.

**La partición del sistema es ext4.** Windows y macOS no la montan sin
instalar herramientas específicas. No es cifrado ni pretende serlo —
cualquier Linux la lee — pero sí levanta una barrera real frente al
"meto la tarjeta en el portátil a ver qué hay". Por eso la credencial
cifrada vive ahí y no en la de arranque.

---

## Las contraseñas WiFi están en claro

No hay forma de evitarlo dentro del planteamiento del proyecto: querías
poder editar las redes metiendo la tarjeta en cualquier ordenador, y eso
obliga a que estén en la partición FAT32 en texto legible.

El impacto es limitado: quien tenga la tarjeta obtiene acceso a tu WiFi,
no a tu PC. Si te preocupa una red concreta, no la pongas en el fichero
y conéctate desde el asistente cuando la necesites.

---

## La auth key de Tailscale

Dejar una auth key en una partición FAT32 sería un problema serio: da
acceso a tu red privada. Por eso:

1. En el primer arranque se copia a `/var/lib/pithin/` con permisos
   `0600`
2. Se usa para autenticar
3. **Se borra de la partición de arranque**, sobrescribiéndola antes

Además, la documentación te pide generar la clave **con una etiqueta
ACL** que limite la Raspberry a `tcp/3389` de tu PC y nada más. Si algún
día pierdes el aparato, lo que un atacante consigue es la posibilidad de
llamar al puerto de Escritorio Remoto de un PC cuya contraseña no tiene.
El procedimiento está en [windows.md](windows.md#4-crear-la-auth-key-para-la-raspberry).

Si sospechas que has perdido el control del dispositivo, bórralo desde
el [panel de máquinas](https://login.tailscale.com/admin/machines): deja
de funcionar en el acto.

---

## La contraseña de Windows

Aquí está la decisión de diseño más interesante del proyecto.

### El problema de fondo

Un PIN corto tiene muy poca entropía. Cuatro dígitos son diez mil
combinaciones. Si alguien se lleva la tarjeta y prueba offline, las
recorre todas en un momento, por muy bueno que sea el cifrado. **La
longitud y variedad del PIN pesan más que el algoritmo.**

Cifrar con un PIN de cuatro dígitos y quedarse tranquilo sería
autoengaño. De ahí tres refuerzos que sí aportan algo real.

### Refuerzo 1: Argon2id

En vez de PBKDF2 —barato de paralelizar en tarjetas gráficas— se usa
**Argon2id**, que es *memory-hard*: cada intento exige 64 MB de memoria.
Eso arruina el paralelismo masivo, porque el cuello de botella pasa a
ser el ancho de banda de memoria, no los núcleos.

Parámetros: `m=64 MiB, t=3, p=1`. Se guardan junto al fichero cifrado,
así que se pueden subir en el futuro sin invalidar credenciales ya
creadas.

### Refuerzo 2: la clave depende de esta Raspberry

La clave no se deriva solo del PIN, sino de **PIN + número de serie del
SoC**:

```
clave = Argon2id(PIN ‖ 0x1F ‖ serie_del_SoC, sal)
```

Esto cambia el escenario más probable. Alguien que copie la tarjeta —o
te la coja prestada un rato— **no tiene el número de serie**, que solo
existe en el chip de tu Raspberry. Sin él no puede ni empezar a probar
PINs.

Para que el ataque offline sea posible hace falta llevarse el aparato
entero, no solo la tarjeta.

### Refuerzo 3: freno a los intentos en el propio equipo

Contra quien se siente delante del equipo encendido y empiece a probar,
hay una espera creciente: 5 segundos tras 3 fallos, 30 tras 5, 60 tras
8. No protege contra el ataque offline —para eso está Argon2id— pero
hace inviable el método a mano.

### Cuánto aguanta cada PIN

Órdenes de magnitud, suponiendo un atacante con la Raspberry en la mano
y equipo dedicado (~1.000 intentos por segundo contra Argon2id a 64 MB):

| PIN | Combinaciones | Tiempo hasta encontrarlo |
|---|---|---|
| `1234` (4 dígitos) | 10⁴ | **10 segundos** |
| `123456` (6 dígitos) | 10⁶ | **~17 minutos** |
| `casa42` (6 alfanuméricos) | ~2×10⁹ | **~25 días** |
| `casaverde` (9 letras) | ~5×10¹² | **siglos** |

Por eso el mínimo son 6 caracteres y por eso el programa insiste en que
metas alguna letra. `casa42` se teclea igual de rápido que `1234` y
cambia el resultado por completo.

Los números son estimaciones de orden de magnitud, no garantías: un
atacante con más recursos irá más rápido. La conclusión práctica —usa
letras— no cambia.

### Si prefieres no guardarla

Es una opción perfectamente válida y la más segura: deja el campo del
PIN vacío la primera vez, o borra la credencial desde **Menú →
Contraseña de Windows → Borrar**. Se te pedirá la contraseña en cada
conexión. Son unos segundos y el aparato deja de ser un riesgo.

---

## Decisiones deliberadas

### Todo corre como root

PiThin no crea un usuario sin privilegios. Es un aparato de un solo
propósito y un solo usuario físico: quien está delante del teclado ya
controla el equipo por completo. Separar privilegios exigiría sudoers,
reglas de polkit y pasar la contraseña descifrada entre dominios de
privilegio, y todo eso añadiría piezas móviles sin ganar seguridad real.

La consecuencia concreta es que Xorg corre como root. Es un coste
asumido y conocido.

### El disco no está cifrado

No hay cifrado completo del sistema. La razón es de fondo: la Raspberry
no tiene TPM ni elemento seguro donde guardar una clave, así que cifrar
la raíz obligaría a teclear una contraseña larga **antes** de que exista
ninguna interfaz para pedirla, en cada arranque. Eso rompe justo lo que
querías: encender y estar dentro.

La alternativa elegida —cifrar solo el secreto que importa, y atarlo al
hardware— da la mayor parte del beneficio a un coste de uso nulo.

### Se ignora el certificado del servidor

Por defecto, `IGNORAR_CERTIFICADO="si"`. Puede sonar mal, pero el tráfico
ya va cifrado extremo a extremo por WireGuard dentro de Tailscale, y el
certificado autofirmado que genera Windows no aporta autenticación
adicional que sirva de algo. Validarlo solo conseguiría que hubiera que
aceptarlo a mano en cada arranque.

Si prefieres validarlo, pon `IGNORAR_CERTIFICADO="no"`: se usa el modo
*trust on first use*, que acepta el certificado la primera vez y avisa
si cambia después.

### No se expone RDP a Internet

Se consideró y se descartó. Un 3389 abierto recibe ataques de
credenciales de forma continua desde el primer día y es la vía de
entrada nº1 de ransomware. Tailscale da el mismo resultado sin abrir
nada en el router.

---

## Dónde acaba la contraseña dentro del equipo

Merece un apartado porque es fácil filtrar un secreto sin querer:

- **No va en la línea de órdenes.** `/proc/PID/cmdline` lo puede leer
  cualquier proceso. Se usa `/args-from:` de FreeRDP 3, que lee los
  argumentos de un fichero con permisos `0600`.
- **No toca la tarjeta SD.** Ese fichero de argumentos y el de traspaso
  entre la consola y la sesión de X viven en `/run`, que es tmpfs: RAM
  pura, desaparece al apagar.
- **No aparece en el registro.** Los argumentos se censuran antes de
  escribirlos, y la salida de `tailscale up` se filtra para que la auth
  key no acabe en el fichero de log.
- **El fichero de traspaso se destruye al leerlo**, no al terminar la
  sesión.

Si instalas sobre un sistema donde solo hay FreeRDP 2, el instalador
avisa: esa versión no tiene `/args-from:` y la contraseña sí queda
visible en la lista de procesos.

---

## Qué hacer si pierdes la Raspberry

Por orden de urgencia:

1. **Borra el nodo** en el
   [panel de máquinas de Tailscale](https://login.tailscale.com/admin/machines).
   Deja de tener acceso a tu red al instante. Esto es lo importante.
2. **Cambia la contraseña de Windows** si la tenías guardada. El cifrado
   compra tiempo, no invulnerabilidad.
3. Cambia las contraseñas WiFi que estuvieran en `redes.conf` si alguna
   te importa.

El paso 1 corta el acceso aunque el atacante consiga todo lo demás: sin
pertenecer al tailnet no hay ruta hasta tu PC.
