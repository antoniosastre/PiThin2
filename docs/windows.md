# Preparar el PC con Windows 11 Pro

Tres cosas: activar el Escritorio Remoto, instalar Tailscale y ajustar
el cortafuegos. Se hace una vez y no se vuelve a tocar.

Cuando algo no funciona, casi siempre es uno de estos tres puntos, no la
Raspberry.

---

## 1. Activar el Escritorio Remoto

**Solo funciona en Windows 11 Pro, Enterprise o Education.** La edición
Home no acepta conexiones RDP entrantes. Puedes comprobar tu edición en
Configuración → Sistema → Información.

1. Configuración → Sistema → **Escritorio remoto**
2. Activa **Escritorio remoto**
3. Despliega **Configuración avanzada** y deja marcado *Requerir que los
   equipos usen la autenticación a nivel de red* (NLA). FreeRDP la
   admite sin problemas y protege mejor.

Apunta el **nombre del equipo** que aparece ahí; lo necesitarás.

### Dos advertencias que conviene conocer de antemano

**La sesión es única.** Cuando te conectes desde la Raspberry, la
pantalla física del PC se bloqueará. No son dos sesiones en paralelo:
estás *tomando* la tuya. Al desconectar, vuelves a entrar en el PC
normalmente y las aplicaciones siguen donde estaban.

**El PC tiene que estar despierto.** Si Windows suspende, no hay
conexión posible y Tailscale no puede despertarlo. Como la Raspberry
estará fuera de casa, tampoco puede lanzar un Wake-on-LAN útil: haría
falta otro aparato encendido en tu red doméstica.

Lo simple es desactivar la suspensión:

Configuración → Sistema → **Inicio/apagado y batería** → Pantalla y
suspensión → *Suspender el dispositivo tras*: **Nunca**.

Puedes dejar que la pantalla se apague; lo que no puede es suspenderse
el equipo.

---

## 2. Instalar Tailscale en el PC

1. Descarga el instalador de Windows desde
   [tailscale.com/download](https://tailscale.com/download)
2. Instálalo e inicia sesión con tu cuenta
3. Comprueba que el PC aparece en
   [login.tailscale.com/admin/machines](https://login.tailscale.com/admin/machines)

Ese panel te da el dato que va en `pithin.conf`:

- El **nombre** de la máquina (por ejemplo `sobremesa-antonio`), o
- Su **IP** `100.x.y.z`

Cualquiera de los dos vale como `RDP_HOST`.

### Desactiva la caducidad de clave del PC

En el panel de máquinas, en el menú de tres puntos del PC:
**Disable key expiry**.

Si no lo haces, a los 180 días el PC se desconectará del tailnet y
tendrás que volver a autenticarlo a mano. Estando de viaje, eso deja la
Raspberry inservible.

---

## 3. Ajustar el cortafuegos de Windows

Este es el fallo más habitual: Tailscale conecta, pero el puerto 3389 no
responde.

Windows tiene reglas de cortafuegos distintas según el perfil de red
(privada, pública, dominio). El adaptador de Tailscale puede quedar
clasificado de una forma que bloquee el Escritorio Remoto.

Abre **PowerShell como administrador** y ejecuta:

```powershell
# Permitir RDP desde el rango de direcciones de Tailscale
New-NetFirewallRule -DisplayName "RDP desde Tailscale" `
  -Direction Inbound -Protocol TCP -LocalPort 3389 `
  -RemoteAddress 100.64.0.0/10 -Action Allow -Profile Any
```

`100.64.0.0/10` es el rango que usa Tailscale para todos los nodos.
Limitar la regla a ese rango es mejor que abrir el 3389 en general: si
algún día te conectas a una red pública, el puerto sigue cerrado para
todo lo que no venga del túnel.

Para comprobar que la regla ha quedado bien:

```powershell
Get-NetFirewallRule -DisplayName "RDP desde Tailscale" | Format-List DisplayName, Enabled, Profile
```

---

## 4. Crear la auth key para la Raspberry

La Raspberry necesita autenticarse en tu tailnet una sola vez. Se hace
con una *auth key* que dejas en la tarjeta y que se consume y se borra
en el primer arranque.

### Por qué hace falta una etiqueta (tag)

Las claves de nodo de Tailscale **caducan a los 180 días**. Si la
Raspberry se autentica sin etiqueta, medio año después se quedará fuera
del tailnet sin previo aviso, justo cuando la necesites en un hotel.

**Los dispositivos etiquetados tienen la caducidad desactivada por
defecto.** Por eso el procedimiento correcto pasa por definir una
etiqueta antes de generar la clave.

### Definir la etiqueta

En [login.tailscale.com/admin/acls](https://login.tailscale.com/admin/acls),
añade a tu fichero de ACL:

```jsonc
{
  "tagOwners": {
    "tag:pithin": ["autogroup:admin"],
  },
}
```

### Restringir lo que puede hacer la Raspberry (recomendado)

Ya que estás, limita el acceso: la Raspberry solo necesita llegar al
puerto 3389 de tu PC. Si algún día se pierde, no da acceso a nada más
de tu red.

```jsonc
{
  "tagOwners": {
    "tag:pithin": ["autogroup:admin"],
  },
  "acls": [
    // Regla para la Raspberry: solo Escritorio Remoto, solo a tu PC.
    {
      "action": "accept",
      "src":    ["tag:pithin"],
      "dst":    ["TU-PC:3389"],
    },
    // Tus demás dispositivos siguen funcionando con normalidad.
    {
      "action": "accept",
      "src":    ["autogroup:member"],
      "dst":    ["*:*"],
    },
  ],
}
```

Sustituye `TU-PC` por el nombre real del equipo en el panel de máquinas.

### Generar la clave

1. Ve a
   [login.tailscale.com/admin/settings/keys](https://login.tailscale.com/admin/settings/keys)
2. **Generate auth key**
3. Marca **Pre-approved** si tienes aprobación de dispositivos activada
4. En **Tags**, elige `tag:pithin`
5. Deja **Reusable** desactivado: se usa una vez y ya está
6. Copia la clave (empieza por `tskey-auth-`)

### Ponerla en la tarjeta

Crea el fichero `tailscale-authkey.txt` en la carpeta `pithin` de la
partición de arranque, con la clave como único contenido:

```
tskey-auth-kXXXXXXXXXXXXXX-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
```

En el primer arranque, PiThin la usa, la copia a un sitio privado y
**borra el fichero de la tarjeta**. La partición de arranque es FAT32 y
la lee cualquiera que meta la tarjeta en un ordenador; no debe quedarse
ahí.

Como alternativa, puedes autenticar a mano desde la Raspberry:

```bash
sudo tailscale up
```

y seguir el enlace que aparece en pantalla.

---

## 5. El usuario de Windows en `pithin.conf`

El formato depende del tipo de cuenta, y equivocarse aquí da un error de
credenciales que despista bastante:

| Tipo de cuenta | `RDP_USER` |
|---|---|
| Cuenta local de Windows | `Antonio` |
| Cuenta Microsoft | `MicrosoftAccount\\tu@correo.com` |
| Equipo en dominio | `Antonio` y además `RDP_DOMINIO="MIEMPRESA"` |

Las **dos barras invertidas** en el caso de cuenta Microsoft son
necesarias: el fichero se lee como texto y una sola barra se
interpretaría como escape.

Si usas cuenta Microsoft y aun así falla, prueba a crear un PIN de
Windows Hello en el PC y luego desactívalo: eso fuerza a Windows a
regenerar las credenciales locales, que es lo que RDP acaba usando.

---

## Comprobación final

Desde la Raspberry, con Tailscale ya levantado:

```bash
tailscale status              # ¿aparece tu PC?
tailscale ip -4 TU-PC         # ¿resuelve a 100.x.y.z?
```

Y el diagnóstico completo desde el menú de PiThin: **Diagnóstico →
Comprobarlo todo de arriba abajo**. Comprueba en orden la WiFi, el
túnel, la resolución del nombre y si el puerto 3389 responde, que es
justo la secuencia que suele romperse.
